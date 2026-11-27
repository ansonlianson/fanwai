// 番外 trial relay. It holds the DeepSeek key of the trial account so the app never does:
// the app sends a pass token, the relay checks the pass's quota, forwards the request to
// DeepSeek with the real key and writes down what it cost.
//
// Only the standard library. State is one JSON file; logs are one JSON line per event.
// Nothing here prints or stores the DeepSeek key or a pass token (tokens are kept as hashes).
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// ---------- configuration (re-read when the file changes) ----------

type Config struct {
	Enabled           bool            `json:"enabled"`           // the switch: false stops every trial lookup
	DailySongs        int             `json:"dailySongs"`        // charged lookups per Beijing day, all passes together
	DailyCostCNY      float64         `json:"dailyCostCNY"`      // estimated spend per Beijing day
	Model             string          `json:"model"`             // the only model the relay will ask for
	MaxTokens         int             `json:"maxTokens"`         // per chat call
	ChatPerRun        int             `json:"chatPerRun"`        // calls one lookup may make
	SearchPerRun      int             `json:"searchPerRun"`      //
	FetchPerRun       int             `json:"fetchPerRun"`       //
	RunsPerCharge     int             `json:"runsPerCharge"`     // retries of one song that ride on one charge
	ChargeMinutes     int             `json:"chargeMinutes"`     // how long a charge covers retries of the same song
	CacheDays         int             `json:"cacheDays"`         // search and page cache
	DevicesPerPass    int             `json:"devicesPerPass"`    // phones one code can be entered on
	RedeemPerIPHourly int             `json:"redeemPerIPHourly"` // wrong-code guesses
	App               json.RawMessage `json:"app"`               // served as-is at /v1/config
}

func defaultConfig() Config {
	return Config{Enabled: true, DailySongs: 150, DailyCostCNY: 15, Model: "deepseek-flash", MaxTokens: 4000,
		ChatPerRun: 10, SearchPerRun: 12, FetchPerRun: 6, RunsPerCharge: 3, ChargeMinutes: 15, CacheDays: 7,
		DevicesPerPass: 3, RedeemPerIPHourly: 12, App: json.RawMessage(`{}`)}
}

type configFile struct {
	path string
	mu   sync.Mutex
	mod  time.Time
	cur  Config
}

func (c *configFile) get() Config {
	c.mu.Lock()
	defer c.mu.Unlock()
	info, err := os.Stat(c.path)
	if err != nil {
		if c.mod.IsZero() {
			c.cur = defaultConfig()
		}
		return c.cur
	}
	if info.ModTime().Equal(c.mod) {
		return c.cur
	}
	data, err := os.ReadFile(c.path)
	next := defaultConfig()
	if err == nil && json.Unmarshal(data, &next) == nil {
		c.cur, c.mod = next, info.ModTime()
	} else {
		log.Printf("config: could not read %s, keeping the previous one", c.path)
		if c.mod.IsZero() {
			c.cur = defaultConfig()
		}
	}
	return c.cur
}

func (c *configFile) update(change func(*Config)) error {
	cfg := c.get()
	change(&cfg)
	data, _ := json.MarshalIndent(cfg, "", "  ")
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}

// ---------- state ----------

type Pass struct {
	Code     string    `json:"code"`
	Label    string    `json:"label"`
	Total    int       `json:"total"`
	Used     int       `json:"used"`
	Devices  []string  `json:"devices"` // sha256 of each token handed out
	Created  time.Time `json:"created"`
	LastUsed time.Time `json:"lastUsed,omitempty"`
	Disabled bool      `json:"disabled,omitempty"`
	CostCNY  float64   `json:"costCNY"`
	Source   string    `json:"source"` // "invite" now; "device" once device checks are in
}

type Day struct {
	Songs   int     `json:"songs"`
	CostCNY float64 `json:"costCNY"`
	Chat    int     `json:"chat"`
	Search  int     `json:"search"`
	Fetch   int     `json:"fetch"`
	Cached  int     `json:"cached"`
}

type State struct {
	Passes map[string]*Pass `json:"passes"`
	Days   map[string]*Day  `json:"days"`
}

// One lookup of one song by one pass. It is charged when its first call succeeds; until then it
// is pending, and still holds a place in the pass's quota.
type charge struct {
	created time.Time
	at      time.Time
	runs    map[string]*run
}
type run struct{ chat, search, fetch int }

type Relay struct {
	feedback *feedbackStore
	cfg      *configFile
	dataDir  string
	key      string
	upstream string
	client   *http.Client

	mu       sync.Mutex
	saveMu   sync.Mutex
	state    State
	byToken  map[string]string  // token hash -> code
	charges  map[string]*charge // code|song -> last charge
	redeems  map[string][]time.Time
	minute   map[string][]time.Time
	dirty    bool
	paused   time.Time // upstream refused the key or the account is empty: trial off until then
	pauseWhy string
	logMu    sync.Mutex
}

var beijing = time.FixedZone("CST", 8*3600)

func today() string { return time.Now().In(beijing).Format("2006-01-02") }

func hashToken(t string) string { s := sha256.Sum256([]byte(t)); return hex.EncodeToString(s[:]) }

func (r *Relay) load() {
	r.state = State{Passes: map[string]*Pass{}, Days: map[string]*Day{}}
	if data, err := os.ReadFile(filepath.Join(r.dataDir, "state.json")); err == nil {
		if err := json.Unmarshal(data, &r.state); err != nil {
			log.Fatalf("state.json is unreadable (%v); refusing to start over it", err)
		}
	}
	if r.state.Passes == nil {
		r.state.Passes = map[string]*Pass{}
	}
	if r.state.Days == nil {
		r.state.Days = map[string]*Day{}
	}
	r.byToken = map[string]string{}
	for code, p := range r.state.Passes {
		for _, d := range p.Devices {
			r.byToken[d] = code
		}
	}
}

func (r *Relay) save() error {
	r.saveMu.Lock()
	defer r.saveMu.Unlock()
	r.mu.Lock()
	if !r.dirty {
		r.mu.Unlock()
		return nil
	}
	data, _ := json.MarshalIndent(r.state, "", " ")
	r.dirty = false
	r.mu.Unlock()
	tmp := filepath.Join(r.dataDir, "state.json.tmp")
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		log.Printf("state: %v", err)
		r.mu.Lock()
		r.dirty = true
		r.mu.Unlock()
		return err
	}
	if err := os.Rename(tmp, filepath.Join(r.dataDir, "state.json")); err != nil {
		log.Printf("state: %v", err)
		r.mu.Lock()
		r.dirty = true
		r.mu.Unlock()
		return err
	}
	return nil
}

func (r *Relay) day() *Day {
	d := r.state.Days[today()]
	if d == nil {
		d = &Day{}
		r.state.Days[today()] = d
	}
	return d
}

// One JSON line per event. Never the key, never a token, never an address (the privacy page says so).
func (r *Relay) event(fields map[string]any) {
	fields["t"] = time.Now().In(beijing).Format("2006-01-02T15:04:05.000")
	line, _ := json.Marshal(fields)
	r.logMu.Lock()
	defer r.logMu.Unlock()
	dir := filepath.Join(r.dataDir, "log")
	_ = os.MkdirAll(dir, 0o750)
	f, err := os.OpenFile(filepath.Join(dir, today()+".jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.Write(append(line, '\n'))
}

// What was looked up is kept for 90 days (the privacy page says so); cached pages a little
// longer than they are served.
const logDays = 90

func (r *Relay) sweep() {
	if r.feedback != nil {
		r.feedback.sweep()
	}
	old := func(dir string, age time.Duration) {
		_ = filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
			if err == nil && !info.IsDir() && time.Since(info.ModTime()) > age {
				_ = os.Remove(path)
			}
			return nil
		})
	}
	old(filepath.Join(r.dataDir, "log"), logDays*24*time.Hour)
	old(filepath.Join(r.dataDir, "cache"), time.Duration(r.cfg.get().CacheDays+1)*24*time.Hour)
}

// ---------- prices (DeepSeek list prices, CNY) ----------

func peak(t time.Time) bool {
	t = t.In(beijing)
	if wd := t.Weekday(); wd == time.Saturday || wd == time.Sunday {
		return false
	}
	h := t.Hour()
	return (h >= 9 && h < 12) || (h >= 14 && h < 18)
}

// deepseek-flash: cache hit 0.04, miss 2, output 8 per million at peak; half off-peak.
func chatCost(hit, miss, out int, at time.Time) float64 {
	c := (float64(hit)*0.04 + float64(miss)*2 + float64(out)*8) / 1e6
	if !peak(at) {
		c /= 2
	}
	return c
}

const toolCost = 0.005 // search or fetch, per successful call

// ---------- helpers ----------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// Errors look like DeepSeek's, so the app reads them the same way.
func fail(w http.ResponseWriter, status int, kind, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"type": kind, "code": kind, "message": message}})
}

func clientIP(q *http.Request) string {
	if f := q.Header.Get("X-Forwarded-For"); f != "" {
		return strings.TrimSpace(strings.Split(f, ",")[0])
	}
	return q.RemoteAddr
}

func bearer(q *http.Request) string {
	h := q.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return ""
	}
	return strings.TrimSpace(h[7:])
}

func within(list []time.Time, d time.Duration) []time.Time {
	cut := time.Now().Add(-d)
	out := list[:0]
	for _, t := range list {
		if t.After(cut) {
			out = append(out, t)
		}
	}
	return out
}

const codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789" // no 0 O 1 I L

func newCode() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	out := make([]byte, 8)
	for i, v := range b {
		out[i] = codeAlphabet[int(v)%len(codeAlphabet)]
	}
	return "FW-" + string(out[:4]) + "-" + string(out[4:])
}

// What people type: spaces, lower case and a missing dash are forgiven.
func normalCode(s string) string {
	s = strings.ToUpper(strings.TrimSpace(s))
	var b strings.Builder
	for _, c := range s {
		if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			b.WriteRune(c)
		}
	}
	v := b.String()
	v = strings.TrimPrefix(v, "FW")
	if len(v) != 8 {
		return ""
	}
	return "FW-" + v[:4] + "-" + v[4:]
}

// ---------- pass endpoints ----------

func (r *Relay) passView(p *Pass, cfg Config) map[string]any {
	d := r.day()
	capped := d.Songs >= cfg.DailySongs || d.CostCNY >= cfg.DailyCostCNY
	paused := time.Now().Before(r.paused)
	left := p.Total - p.Used
	if left < 0 {
		left = 0
	}
	return map[string]any{"total": p.Total, "used": p.Used, "remaining": left,
		"enabled": cfg.Enabled && !paused && !p.Disabled, "dailyCapReached": capped}
}

func (r *Relay) redeem(w http.ResponseWriter, q *http.Request) {
	cfg := r.cfg.get()
	var body struct {
		Code string `json:"code"`
	}
	if json.NewDecoder(io.LimitReader(q.Body, 4096)).Decode(&body) != nil {
		fail(w, 400, "bad_request", "请求格式不对")
		return
	}
	ip := clientIP(q)
	r.mu.Lock()
	defer r.mu.Unlock()
	r.redeems[ip] = within(r.redeems[ip], time.Hour)
	if len(r.redeems[ip]) >= cfg.RedeemPerIPHourly {
		fail(w, 429, "too_many_attempts", "试的次数太多，过一小时再来")
		return
	}
	code := normalCode(body.Code)
	p := r.state.Passes[code]
	if code == "" || p == nil {
		r.redeems[ip] = append(r.redeems[ip], time.Now())
		go r.event(map[string]any{"e": "redeem", "ok": false})
		fail(w, 404, "code_not_found", "没有这个体验码")
		return
	}
	if p.Disabled {
		fail(w, 403, "code_disabled", "这个体验码已停用")
		return
	}
	if len(p.Devices) >= cfg.DevicesPerPass {
		fail(w, 403, "code_devices", "这个体验码已经在 "+fmt.Sprint(cfg.DevicesPerPass)+" 台设备上用过")
		return
	}
	raw := make([]byte, 24)
	_, _ = rand.Read(raw)
	token := "fwt_" + hex.EncodeToString(raw)
	h := hashToken(token)
	p.Devices = append(p.Devices, h)
	r.byToken[h] = code
	r.dirty = true
	go r.event(map[string]any{"e": "redeem", "ok": true, "pass": p.Label, "devices": len(p.Devices)})
	view := r.passView(p, cfg)
	view["token"] = token
	writeJSON(w, 200, view)
}

func (r *Relay) passOf(q *http.Request) *Pass {
	t := bearer(q)
	if !strings.HasPrefix(t, "fwt_") {
		return nil
	}
	return r.state.Passes[r.byToken[hashToken(t)]]
}

func (r *Relay) passStatus(w http.ResponseWriter, q *http.Request) {
	cfg := r.cfg.get()
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.passOf(q)
	if p == nil {
		fail(w, 401, "invalid_api_key", "体验码失效了")
		return
	}
	writeJSON(w, 200, r.passView(p, cfg))
}

// What the app found, reported once a lookup ends: the relay cannot tell from the calls alone.
func (r *Relay) outcome(w http.ResponseWriter, q *http.Request) {
	var body struct {
		Song    string  `json:"song"`
		Title   string  `json:"title"`
		Cards   int     `json:"cards"`
		Story   bool    `json:"story"`
		Failed  string  `json:"failed"`
		Seconds float64 `json:"seconds"`
		Build   string  `json:"build"`
	}
	if json.NewDecoder(io.LimitReader(q.Body, 8192)).Decode(&body) != nil {
		fail(w, 400, "bad_request", "请求格式不对")
		return
	}
	r.mu.Lock()
	p := r.passOf(q)
	r.mu.Unlock()
	if p == nil {
		fail(w, 401, "invalid_api_key", "体验码失效了")
		return
	}
	title := body.Title
	if len(title) > 200 {
		title = title[:200]
	}
	r.event(map[string]any{"e": "outcome", "pass": p.Label, "song": body.Song, "title": title, "cards": body.Cards,
		"story": body.Story, "failed": body.Failed, "seconds": body.Seconds, "build": body.Build})
	w.WriteHeader(204)
}

// ---------- the DeepSeek-shaped endpoints ----------

type admitted struct {
	pass  *Pass
	label string
	song  string
	runID string
	title string
}

// Decides whether this request may go upstream, and counts it against its lookup.
func (r *Relay) admit(w http.ResponseWriter, q *http.Request, kind string, cfg Config) *admitted {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.passOf(q)
	if p == nil {
		fail(w, 401, "invalid_api_key", "体验码失效了")
		return nil
	}
	if !cfg.Enabled || time.Now().Before(r.paused) {
		fail(w, 503, "trial_off", "免费体验暂停了")
		return nil
	}
	if p.Disabled {
		fail(w, 403, "code_disabled", "这个体验码已停用")
		return nil
	}
	// 「歌的编号.这一次查找的编号」: retries of one song ride on its charge for a while.
	parts := strings.SplitN(q.Header.Get("X-Fanwai-Song"), ".", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" || len(parts[0]) > 64 || len(parts[1]) > 32 {
		fail(w, 400, "bad_request", "缺少歌曲编号")
		return nil
	}
	song, runID := parts[0], parts[1]
	r.minute[p.Code] = within(r.minute[p.Code], time.Minute)
	if len(r.minute[p.Code]) >= 120 {
		fail(w, 429, "rate_limited", "请求太快")
		return nil
	}
	r.minute[p.Code] = append(r.minute[p.Code], time.Now())

	key := p.Code + "|" + song
	window := time.Duration(cfg.ChargeMinutes) * time.Minute
	live := func(c *charge) bool {
		if c.at.IsZero() {
			return time.Since(c.created) < window
		}
		return time.Since(c.at) < window
	}
	c := r.charges[key]
	covered := c != nil && live(c)
	if covered && c.runs[runID] == nil && len(c.runs) >= cfg.RunsPerCharge {
		covered = false
	}
	if !covered {
		// A new lookup: it needs quota left, for this pass and for the day. Lookups that have
		// started but not yet been charged count, so two songs cannot share the last one.
		pending := 0
		for k, other := range r.charges {
			if other.at.IsZero() && live(other) && strings.HasPrefix(k, p.Code+"|") {
				pending++
			}
		}
		if p.Used+pending >= p.Total {
			fail(w, 402, "trial_exhausted", "免费的次数用完了")
			return nil
		}
		d := r.day()
		if d.Songs >= cfg.DailySongs || d.CostCNY >= cfg.DailyCostCNY {
			fail(w, 429, "trial_daily_cap", "今天的免费额度用完了")
			return nil
		}
		c = &charge{created: time.Now(), runs: map[string]*run{}} // charged in settle
		r.charges[key] = c
	}
	ru := c.runs[runID]
	if ru == nil {
		ru = &run{}
		c.runs[runID] = ru
	}
	var n *int
	var limit int
	switch kind {
	case "chat":
		n, limit = &ru.chat, cfg.ChatPerRun
	case "search":
		n, limit = &ru.search, cfg.SearchPerRun
	default:
		n, limit = &ru.fetch, cfg.FetchPerRun
	}
	if *n >= limit {
		fail(w, 429, "trial_song_cap", "这首歌的查找次数到上限了")
		return nil
	}
	*n++
	title, _ := url.QueryUnescape(q.Header.Get("X-Fanwai-Title"))
	if len(title) > 200 {
		title = title[:200]
	}
	return &admitted{pass: p, label: p.Label, song: song, runID: runID, title: title}
}

// After a call that worked: charge the lookup if it has not been charged, add up the cost.
func (r *Relay) settle(a *admitted, kind string, cost float64, cached bool) (remaining int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	d := r.day()
	if c := r.charges[a.pass.Code+"|"+a.song]; c != nil && c.at.IsZero() {
		c.at = time.Now()
		a.pass.Used++
		d.Songs++
		go r.event(map[string]any{"e": "charge", "pass": a.label, "song": a.song, "title": a.title,
			"used": a.pass.Used, "total": a.pass.Total})
	}
	a.pass.CostCNY += cost
	a.pass.LastUsed = time.Now()
	d.CostCNY += cost
	switch {
	case cached:
		d.Cached++
	case kind == "chat":
		d.Chat++
	case kind == "search":
		d.Search++
	default:
		d.Fetch++
	}
	r.dirty = true
	if left := a.pass.Total - a.pass.Used; left > 0 {
		return left
	}
	return 0
}

func (r *Relay) cachePath(kind, key string) string {
	s := sha256.Sum256([]byte(key))
	return filepath.Join(r.dataDir, "cache", kind, hex.EncodeToString(s[:])+".json")
}

func (r *Relay) cacheRead(kind, key string, days int) []byte {
	p := r.cachePath(kind, key)
	info, err := os.Stat(p)
	if err != nil || time.Since(info.ModTime()) > time.Duration(days)*24*time.Hour {
		return nil
	}
	data, _ := os.ReadFile(p)
	return data
}

func (r *Relay) cacheWrite(kind, key string, data []byte) {
	p := r.cachePath(kind, key)
	_ = os.MkdirAll(filepath.Dir(p), 0o750)
	tmp := p + ".tmp"
	if os.WriteFile(tmp, data, 0o640) == nil {
		_ = os.Rename(tmp, p)
	}
}

func (r *Relay) proxy(kind, upstreamPath string, timeout time.Duration) http.HandlerFunc {
	return func(w http.ResponseWriter, q *http.Request) {
		cfg := r.cfg.get()
		if q.Method != http.MethodPost {
			fail(w, 405, "bad_request", "只接受 POST")
			return
		}
		raw, err := io.ReadAll(io.LimitReader(q.Body, 600_000))
		if err != nil || len(raw) >= 600_000 {
			fail(w, 413, "bad_request", "请求太大")
			return
		}
		var body map[string]any
		if json.Unmarshal(raw, &body) != nil {
			fail(w, 400, "bad_request", "请求格式不对")
			return
		}
		a := r.admit(w, q, kind, cfg)
		if a == nil {
			return
		}
		started := time.Now()
		cacheKey := ""
		switch kind {
		case "chat":
			// Only what a lookup needs, on the one model, without streaming or tools.
			clean := map[string]any{"model": cfg.Model, "stream": false, "thinking": map[string]any{"type": "disabled"}}
			for _, k := range []string{"messages", "response_format", "temperature", "top_p"} {
				if v, ok := body[k]; ok {
					clean[k] = v
				}
			}
			limit := float64(cfg.MaxTokens)
			if v, ok := body["max_tokens"].(float64); ok && v > 0 && v < limit {
				limit = v
			}
			clean["max_tokens"] = int(limit)
			body = clean
		case "search":
			query, _ := body["query"].(string)
			if strings.TrimSpace(query) == "" || len(query) > 600 {
				fail(w, 400, "bad_request", "搜索词不对")
				return
			}
			count := 8.0
			if v, ok := body["count"].(float64); ok && v >= 1 && v <= 10 {
				count = v
			}
			clean := map[string]any{"query": query, "count": int(count), "need_content": body["need_content"] == true}
			if v, ok := body["ori_question"].(string); ok && len(v) <= 600 {
				clean["ori_question"] = v
			}
			body = clean
			cacheKey = fmt.Sprintf("%s|%d|%v", query, int(count), clean["need_content"])
		default:
			target, _ := body["url"].(string)
			u, err := url.Parse(target)
			if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || len(target) > 2000 {
				fail(w, 400, "bad_request", "网址不对")
				return
			}
			body = map[string]any{"url": target}
			cacheKey = target
		}
		if cacheKey != "" {
			if data := r.cacheRead(kind, cacheKey, cfg.CacheDays); data != nil {
				left := r.settle(a, kind, 0, true)
				r.event(map[string]any{"e": kind, "pass": a.label, "song": a.song, "run": a.runID, "status": 200, "cached": true})
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("X-Fanwai-Remaining", fmt.Sprint(left))
				w.WriteHeader(200)
				_, _ = w.Write(data)
				return
			}
		}
		payload, _ := json.Marshal(body)
		ctx, cancel := context.WithTimeout(q.Context(), timeout)
		defer cancel()
		up, _ := http.NewRequestWithContext(ctx, http.MethodPost, r.upstream+upstreamPath, bytes.NewReader(payload))
		up.Header.Set("Authorization", "Bearer "+r.key)
		up.Header.Set("Content-Type", "application/json")
		resp, err := r.client.Do(up)
		if err != nil {
			r.event(map[string]any{"e": kind, "pass": a.label, "song": a.song, "run": a.runID, "status": 0,
				"ms": time.Since(started).Milliseconds(), "error": "upstream unreachable"})
			fail(w, 502, "upstream_unreachable", "连不上模型服务")
			return
		}
		defer resp.Body.Close()
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 6_000_000))
		ms := time.Since(started).Milliseconds()
		if resp.StatusCode == 401 || resp.StatusCode == 402 {
			// The trial account itself: its key is refused or its balance is gone. Nobody's
			// fault on the phone; the trial pauses and the reason goes to the log, not the app.
			r.mu.Lock()
			r.paused, r.pauseWhy = time.Now().Add(10*time.Minute), map[int]string{401: "key refused", 402: "balance empty"}[resp.StatusCode]
			r.mu.Unlock()
			r.event(map[string]any{"e": "paused", "why": r.pauseWhy, "status": resp.StatusCode})
			fail(w, 503, "trial_off", "免费体验暂停了")
			return
		}
		ev := map[string]any{"e": kind, "pass": a.label, "song": a.song, "run": a.runID, "status": resp.StatusCode, "ms": ms}
		left := -1
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			cost := toolCost
			if kind == "chat" {
				var reply struct {
					Usage struct {
						Prompt int `json:"prompt_tokens"`
						Out    int `json:"completion_tokens"`
						Hit    int `json:"prompt_cache_hit_tokens"`
						Miss   int `json:"prompt_cache_miss_tokens"`
					} `json:"usage"`
				}
				_ = json.Unmarshal(data, &reply)
				hit, miss := reply.Usage.Hit, reply.Usage.Miss
				if hit+miss == 0 {
					miss = reply.Usage.Prompt
				}
				cost = chatCost(hit, miss, reply.Usage.Out, started)
				ev["in"], ev["hit"], ev["out"] = hit+miss, hit, reply.Usage.Out
			} else if worthKeeping(kind, data) {
				r.cacheWrite(kind, cacheKey, data)
			}
			ev["cost"] = float64(int(cost*100000+0.5)) / 100000
			left = r.settle(a, kind, cost, false)
		}
		r.event(ev)
		w.Header().Set("Content-Type", "application/json")
		if left >= 0 {
			w.Header().Set("X-Fanwai-Remaining", fmt.Sprint(left))
		}
		w.WriteHeader(resp.StatusCode)
		_, _ = w.Write(data)
	}
}

// An empty answer may be the search having a bad moment; only answers with something in them are kept.
func worthKeeping(kind string, data []byte) bool {
	if kind == "search" {
		var reply struct {
			Results []json.RawMessage `json:"results"`
		}
		return json.Unmarshal(data, &reply) == nil && len(reply.Results) > 0
	}
	var page struct {
		Content string `json:"content"`
	}
	return json.Unmarshal(data, &page) == nil && len(page.Content) >= 160
}

// ---------- admin (127.0.0.1 only; reached through the fanwai command on the server) ----------

func (r *Relay) admin(mux *http.ServeMux) {
	mux.HandleFunc("/admin/new", func(w http.ResponseWriter, q *http.Request) {
		var b struct {
			Label string `json:"label"`
			Total int    `json:"total"`
			Count int    `json:"count"`
		}
		_ = json.NewDecoder(q.Body).Decode(&b)
		if b.Total <= 0 {
			b.Total = 10
		}
		if b.Count <= 0 {
			b.Count = 1
		}
		r.mu.Lock()
		defer r.mu.Unlock()
		var made []*Pass
		for i := 0; i < b.Count; i++ {
			code := newCode()
			for r.state.Passes[code] != nil {
				code = newCode()
			}
			label := b.Label
			if b.Count > 1 {
				label = fmt.Sprintf("%s-%02d", b.Label, i+1)
			}
			p := &Pass{Code: code, Label: label, Total: b.Total, Created: time.Now(), Source: "invite"}
			r.state.Passes[code] = p
			made = append(made, p)
		}
		r.dirty = true
		writeJSON(w, 200, made)
	})
	mux.HandleFunc("/admin/grant", func(w http.ResponseWriter, q *http.Request) {
		var b struct {
			Code      string  `json:"code"`
			Add       int     `json:"add"`
			Disabled  *bool   `json:"disabled"`
			Remaining *int    `json:"remaining"`
			Label     *string `json:"label"`
		}
		_ = json.NewDecoder(q.Body).Decode(&b)
		r.mu.Lock()
		defer r.mu.Unlock()
		p := r.find(b.Code)
		if p == nil {
			fail(w, 404, "code_not_found", "no such code or label")
			return
		}
		if b.Remaining != nil {
			if *b.Remaining < 0 || *b.Remaining > 100000 {
				fail(w, 400, "quota", "剩余额度须在 0–100000 首之间")
				return
			}
			p.Total = p.Used + *b.Remaining
		} else {
			p.Total += b.Add
		}
		if b.Label != nil {
			p.Label = strings.TrimSpace(*b.Label)
		}
		if p.Total < p.Used {
			p.Total = p.Used
		}
		if b.Disabled != nil {
			p.Disabled = *b.Disabled
		}
		r.dirty = true
		writeJSON(w, 200, p)
	})
	mux.HandleFunc("/admin/list", func(w http.ResponseWriter, q *http.Request) {
		r.mu.Lock()
		defer r.mu.Unlock()
		list := make([]*Pass, 0, len(r.state.Passes))
		for _, p := range r.state.Passes {
			list = append(list, p)
		}
		sort.Slice(list, func(i, j int) bool { return list[i].Created.Before(list[j].Created) })
		writeJSON(w, 200, list)
	})
	mux.HandleFunc("/admin/stats", func(w http.ResponseWriter, q *http.Request) {
		cfg := r.cfg.get()
		r.mu.Lock()
		defer r.mu.Unlock()
		used, total, cost := 0, 0, 0.0
		for _, p := range r.state.Passes {
			used += p.Used
			total += p.Total
			cost += p.CostCNY
		}
		pause := ""
		if time.Now().Before(r.paused) {
			pause = r.pauseWhy
		}
		writeJSON(w, 200, map[string]any{"enabled": cfg.Enabled, "paused": pause, "dailySongs": cfg.DailySongs,
			"dailyCostCNY": cfg.DailyCostCNY, "passes": len(r.state.Passes), "songsUsed": used, "songsGranted": total,
			"costCNY": cost, "days": r.state.Days})
	})
	mux.HandleFunc("/admin/config", func(w http.ResponseWriter, q *http.Request) {
		var b struct {
			Enabled      *bool    `json:"enabled"`
			DailySongs   *int     `json:"dailySongs"`
			DailyCostCNY *float64 `json:"dailyCostCNY"`
		}
		_ = json.NewDecoder(q.Body).Decode(&b)
		err := r.cfg.update(func(c *Config) {
			if b.Enabled != nil {
				c.Enabled = *b.Enabled
			}
			if b.DailySongs != nil {
				c.DailySongs = *b.DailySongs
			}
			if b.DailyCostCNY != nil {
				c.DailyCostCNY = *b.DailyCostCNY
			}
		})
		if err != nil {
			fail(w, 500, "config", err.Error())
			return
		}
		writeJSON(w, 200, r.cfg.get())
	})
}

// By code, or by label when it is unique.
func (r *Relay) find(s string) *Pass {
	if p := r.state.Passes[normalCode(s)]; p != nil {
		return p
	}
	var found *Pass
	for _, p := range r.state.Passes {
		if p.Label == s {
			if found != nil {
				return nil
			}
			found = p
		}
	}
	return found
}

// ---------- main ----------

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func newRelay(configPath, dataDir, key, upstream string) *Relay {
	r := &Relay{cfg: &configFile{path: configPath}, dataDir: dataDir, key: key,
		upstream: strings.TrimRight(upstream, "/"), client: &http.Client{Timeout: 130 * time.Second},
		charges: map[string]*charge{}, redeems: map[string][]time.Time{}, minute: map[string][]time.Time{}}
	r.load()
	r.feedback = newFeedbackStore(dataDir)
	return r
}

func (r *Relay) routes() http.Handler {
	public := http.NewServeMux()
	public.Handle("/manage/", r.management())
	public.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	public.HandleFunc("/v1/feedback", r.receiveFeedback)
	public.HandleFunc("/v1/config", func(w http.ResponseWriter, _ *http.Request) {
		cfg := r.cfg.get()
		app := map[string]any{}
		_ = json.Unmarshal(cfg.App, &app)
		r.mu.Lock()
		paused := time.Now().Before(r.paused)
		r.mu.Unlock()
		// deviceCheck: free lookups without a code need the phone itself checked
		// (App Attest + DeviceCheck). Not built yet, and this says so.
		app["trial"] = map[string]any{"enabled": cfg.Enabled && !paused, "deviceCheck": false}
		w.Header().Set("Cache-Control", "public, max-age=300")
		writeJSON(w, 200, app)
	})
	public.HandleFunc("/v1/trial/redeem", r.redeem)
	public.HandleFunc("/v1/trial/pass", r.passStatus)
	public.HandleFunc("/v1/trial/outcome", r.outcome)
	public.HandleFunc("/v1/trial/device", func(w http.ResponseWriter, _ *http.Request) {
		fail(w, 501, "not_implemented", "设备校验还没接通")
	})
	public.HandleFunc("/ds/chat/completions", r.proxy("chat", "/chat/completions", 110*time.Second))
	public.HandleFunc("/ds/v1/tools/search", r.proxy("search", "/v1/tools/search", 14*time.Second))
	public.HandleFunc("/ds/v1/tools/fetch", r.proxy("fetch", "/v1/tools/fetch", 12*time.Second))
	public.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) { fail(w, 404, "not_found", "没有这个地址") })
	return public
}

func main() {
	if len(os.Args) > 1 && os.Args[1] != "serve" {
		os.Exit(cli(os.Args[1:]))
	}
	log.SetFlags(log.LstdFlags | log.LUTC)
	key := strings.TrimSpace(os.Getenv("DEEPSEEK_API_KEY"))
	_ = os.Unsetenv("DEEPSEEK_API_KEY")
	if key == "" {
		log.Fatal("DEEPSEEK_API_KEY is not set")
	}
	r := newRelay(env("FANWAI_CONFIG", "/etc/fanwai/config.json"), env("FANWAI_DATA", "/var/lib/fanwai"), key,
		env("FANWAI_UPSTREAM", "https://api.deepseek.com"))
	adminMux := http.NewServeMux()
	r.admin(adminMux)

	go func() {
		for range time.Tick(3 * time.Second) {
			r.save()
		}
	}()
	go func() {
		// Lookups older than a day are of no use to anyone.
		for range time.Tick(time.Hour) {
			r.mu.Lock()
			for k, c := range r.charges {
				if time.Since(c.created) > 24*time.Hour {
					delete(r.charges, k)
				}
			}
			r.mu.Unlock()
			r.sweep()
		}
	}()
	srv := &http.Server{Addr: env("FANWAI_LISTEN", "127.0.0.1:8787"), Handler: r.routes(), ReadHeaderTimeout: 10 * time.Second}
	adm := &http.Server{Addr: env("FANWAI_ADMIN", "127.0.0.1:8788"), Handler: adminMux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := adm.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	log.Printf("fanwai relay listening on %s (admin %s), %d passes", srv.Addr, adm.Addr, len(r.state.Passes))
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	_ = adm.Shutdown(ctx)
	r.mu.Lock()
	r.dirty = true
	r.mu.Unlock()
	r.save()
}
