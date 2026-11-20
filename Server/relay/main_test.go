package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

const realKey = "sk-test-real-key-that-must-stay-on-the-server"

// A stand-in for DeepSeek: counts calls, remembers what it was sent, can be told to fail.
type fakeDeepSeek struct {
	mu       sync.Mutex
	chat     int32
	search   int32
	fetch    int32
	lastChat map[string]any
	auth     []string
	status   int32 // 0 = fine
	server   *httptest.Server
}

func newFake() *fakeDeepSeek {
	f := &fakeDeepSeek{}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		f.mu.Lock()
		f.auth = append(f.auth, q.Header.Get("Authorization"))
		f.mu.Unlock()
		body, _ := io.ReadAll(q.Body)
		if s := atomic.LoadInt32(&f.status); s != 0 {
			w.WriteHeader(int(s))
			_, _ = w.Write([]byte(`{"error":{"message":"Insufficient Balance"}}`))
			return
		}
		switch q.URL.Path {
		case "/chat/completions":
			atomic.AddInt32(&f.chat, 1)
			var m map[string]any
			_ = json.Unmarshal(body, &m)
			f.mu.Lock()
			f.lastChat = m
			f.mu.Unlock()
			_, _ = w.Write([]byte(`{"model":"deepseek-flash","choices":[{"message":{"content":"{}"}}],"usage":{"prompt_tokens":9000,"completion_tokens":700,"prompt_cache_hit_tokens":1000,"prompt_cache_miss_tokens":8000}}`))
		case "/v1/tools/search":
			atomic.AddInt32(&f.search, 1)
			_, _ = w.Write([]byte(`{"results":[{"url":"https://example.org/a","title":"a","content":"text"}]}`))
		case "/v1/tools/fetch":
			atomic.AddInt32(&f.fetch, 1)
			_, _ = w.Write([]byte(`{"title":"a","content":"` + strings.Repeat("x", 200) + `"}`))
		default:
			w.WriteHeader(404)
		}
	}))
	return f
}

type harness struct {
	t     *testing.T
	relay *Relay
	fake  *fakeDeepSeek
	api   *httptest.Server
	admin *httptest.Server
}

func setup(t *testing.T) *harness {
	dir := t.TempDir()
	fake := newFake()
	r := newRelay(filepath.Join(dir, "config.json"), dir, realKey, fake.server.URL)
	adminMux := http.NewServeMux()
	r.admin(adminMux)
	h := &harness{t: t, relay: r, fake: fake, api: httptest.NewServer(r.routes()), admin: httptest.NewServer(adminMux)}
	t.Cleanup(func() { h.api.Close(); h.admin.Close(); fake.server.Close() })
	return h
}

func (h *harness) post(server *httptest.Server, path, token string, headers map[string]string, body any) (int, map[string]any, http.Header) {
	data, _ := json.Marshal(body)
	q, _ := http.NewRequest("POST", server.URL+path, bytes.NewReader(data))
	if token != "" {
		q.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		q.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(q)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, out, resp.Header
}

// A code with `total` lookups, already entered on one phone.
func (h *harness) pass(label string, total int) (code, token string) {
	data, _ := json.Marshal(map[string]any{"label": label, "total": total})
	resp, _ := http.Post(h.admin.URL+"/admin/new", "application/json", bytes.NewReader(data))
	var made []Pass
	_ = json.NewDecoder(resp.Body).Decode(&made)
	resp.Body.Close()
	code = made[0].Code
	status, out, _ := h.post(h.api, "/v1/trial/redeem", "", nil, map[string]any{"code": strings.ToLower(strings.ReplaceAll(code, "-", " "))})
	if status != 200 {
		h.t.Fatalf("redeem: %d %v", status, out)
	}
	return code, out["token"].(string)
}

func song(id, run string) map[string]string {
	return map[string]string{"X-Fanwai-Song": id + "." + run, "X-Fanwai-Title": "Lemon%20%E2%80%94%20%E7%B1%B3%E6%B4%A5%E7%8E%84%E5%B8%AB"}
}

func errType(out map[string]any) string {
	e, _ := out["error"].(map[string]any)
	s, _ := e["type"].(string)
	return s
}

func (h *harness) used(code string) int {
	h.relay.mu.Lock()
	defer h.relay.mu.Unlock()
	return h.relay.state.Passes[code].Used
}

func TestCodesAreForgivingAndGuessesAreLimited(t *testing.T) {
	h := setup(t)
	code, token := h.pass("老王", 10)
	if !strings.HasPrefix(token, "fwt_") || !strings.HasPrefix(code, "FW-") {
		t.Fatalf("code %q token %q", code, token)
	}
	if status, out, _ := h.post(h.api, "/v1/trial/redeem", "", nil, map[string]any{"code": "FW-AAAA-AAAA"}); status != 404 || errType(out) != "code_not_found" {
		t.Fatalf("wrong code: %d %v", status, out)
	}
	// Three phones per code, then no more.
	h.post(h.api, "/v1/trial/redeem", "", nil, map[string]any{"code": code})
	h.post(h.api, "/v1/trial/redeem", "", nil, map[string]any{"code": code})
	if status, out, _ := h.post(h.api, "/v1/trial/redeem", "", nil, map[string]any{"code": code}); status != 403 || errType(out) != "code_devices" {
		t.Fatalf("fourth phone: %d %v", status, out)
	}
	for i := 0; i < 12; i++ {
		h.post(h.api, "/v1/trial/redeem", "", nil, map[string]any{"code": "FW-ZZZZ-ZZZ" + fmt.Sprint(i%10)})
	}
	if status, out, _ := h.post(h.api, "/v1/trial/redeem", "", nil, map[string]any{"code": code}); status != 429 {
		t.Fatalf("after many wrong guesses: %d %v", status, out)
	}
}

func TestOneLookupIsOneChargeHoweverManyCallsItMakes(t *testing.T) {
	h := setup(t)
	code, token := h.pass("a", 10)
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			status, out, _ := h.post(h.api, "/ds/v1/tools/search", token, song("s1", "r1"), map[string]any{"query": fmt.Sprint("q", i), "count": 8, "need_content": true})
			if status != 200 {
				t.Errorf("search %d: %d %v", i, status, out)
			}
		}(i)
	}
	wg.Wait()
	for i := 0; i < 3; i++ {
		status, _, header := h.post(h.api, "/ds/chat/completions", token, song("s1", "r1"), map[string]any{"model": "x", "messages": []any{}})
		if status != 200 || header.Get("X-Fanwai-Remaining") != "9" {
			t.Fatalf("chat: %d remaining %q", status, header.Get("X-Fanwai-Remaining"))
		}
	}
	if got := h.used(code); got != 1 {
		t.Fatalf("used = %d, want 1", got)
	}
	// 重查 of the same song soon after rides on the same charge; the fourth run does not.
	h.post(h.api, "/ds/chat/completions", token, song("s1", "r2"), map[string]any{"messages": []any{}})
	h.post(h.api, "/ds/chat/completions", token, song("s1", "r3"), map[string]any{"messages": []any{}})
	if got := h.used(code); got != 1 {
		t.Fatalf("after two retries used = %d, want 1", got)
	}
	h.post(h.api, "/ds/chat/completions", token, song("s1", "r4"), map[string]any{"messages": []any{}})
	if got := h.used(code); got != 2 {
		t.Fatalf("after the fourth run used = %d, want 2", got)
	}
	// Another song is another charge.
	h.post(h.api, "/ds/v1/tools/search", token, song("s2", "r1"), map[string]any{"query": "other"})
	if got := h.used(code); got != 3 {
		t.Fatalf("second song used = %d, want 3", got)
	}
}

func TestTheKeyStaysOnTheServerAndTheRequestIsCutToSize(t *testing.T) {
	h := setup(t)
	_, token := h.pass("a", 10)
	status, _, _ := h.post(h.api, "/ds/chat/completions", token, song("s1", "r1"), map[string]any{
		"model": "deepseek-v4-pro", "stream": true, "max_tokens": 999999, "tools": []any{map[string]any{"type": "function"}},
		"messages": []any{map[string]any{"role": "user", "content": "hi"}}, "response_format": map[string]any{"type": "json_object"}})
	if status != 200 {
		t.Fatal(status)
	}
	h.fake.mu.Lock()
	defer h.fake.mu.Unlock()
	sent := h.fake.lastChat
	if sent["model"] != "deepseek-flash" || sent["stream"] != false || sent["tools"] != nil || sent["max_tokens"].(float64) != 4000 || sent["response_format"] == nil {
		t.Fatalf("sent upstream: %v", sent)
	}
	for _, a := range h.fake.auth {
		if a != "Bearer "+realKey {
			t.Fatalf("upstream saw %q", a)
		}
	}
}

func TestQuotaRunsOutAndTwoSongsCannotShareTheLastOne(t *testing.T) {
	h := setup(t)
	code, token := h.pass("a", 2)
	h.post(h.api, "/ds/chat/completions", token, song("s1", "r1"), map[string]any{"messages": []any{}})
	// One left: two songs start at once, before either has been charged.
	results := make(chan int, 2)
	for _, id := range []string{"s2", "s3"} {
		go func(id string) {
			status, _, _ := h.post(h.api, "/ds/v1/tools/search", token, song(id, "r1"), map[string]any{"query": id})
			results <- status
		}(id)
	}
	a, b := <-results, <-results
	if !(a == 200 && b == 402) && !(a == 402 && b == 200) {
		t.Fatalf("two songs on the last lookup: %d and %d", a, b)
	}
	if got := h.used(code); got != 2 {
		t.Fatalf("used = %d, want 2", got)
	}
	status, out, _ := h.post(h.api, "/ds/v1/tools/search", token, song("s9", "r1"), map[string]any{"query": "more"})
	if status != 402 || errType(out) != "trial_exhausted" {
		t.Fatalf("after the quota: %d %v", status, out)
	}
	// 多给几首: the same code goes on working.
	h.post(h.admin, "/admin/grant", "", nil, map[string]any{"code": code, "add": 5})
	if status, _, header := h.post(h.api, "/ds/v1/tools/search", token, song("s9", "r1"), map[string]any{"query": "more"}); status != 200 || header.Get("X-Fanwai-Remaining") != "4" {
		t.Fatalf("after a grant: %d remaining %q", status, header.Get("X-Fanwai-Remaining"))
	}
	if status, out, _ := h.post(h.api, "/v1/trial/pass", token, nil, nil); status != 405 && out["remaining"] == nil {
		t.Fatalf("pass status: %d %v", status, out)
	}
}

func TestAFailedLookupIsNotCharged(t *testing.T) {
	h := setup(t)
	code, token := h.pass("a", 3)
	atomic.StoreInt32(&h.fake.status, 500)
	if status, _, _ := h.post(h.api, "/ds/v1/tools/search", token, song("s1", "r1"), map[string]any{"query": "q"}); status != 500 {
		t.Fatalf("status %d", status)
	}
	if got := h.used(code); got != 0 {
		t.Fatalf("used = %d after a failure, want 0", got)
	}
}

func TestDailyCapSwitchAndAnEmptyTrialAccount(t *testing.T) {
	h := setup(t)
	_, token := h.pass("a", 50)
	h.post(h.admin, "/admin/config", "", nil, map[string]any{"dailySongs": 1})
	h.post(h.api, "/ds/v1/tools/search", token, song("s1", "r1"), map[string]any{"query": "q"})
	if status, out, _ := h.post(h.api, "/ds/v1/tools/search", token, song("s2", "r1"), map[string]any{"query": "q2"}); status != 429 || errType(out) != "trial_daily_cap" {
		t.Fatalf("over the daily cap: %d %v", status, out)
	}
	h.post(h.admin, "/admin/config", "", nil, map[string]any{"dailySongs": 100, "enabled": false})
	if status, out, _ := h.post(h.api, "/ds/v1/tools/search", token, song("s3", "r1"), map[string]any{"query": "q3"}); status != 503 || errType(out) != "trial_off" {
		t.Fatalf("switched off: %d %v", status, out)
	}
	h.post(h.admin, "/admin/config", "", nil, map[string]any{"enabled": true})
	atomic.StoreInt32(&h.fake.status, 402)
	if status, out, _ := h.post(h.api, "/ds/v1/tools/search", token, song("s4", "r1"), map[string]any{"query": "q4"}); status != 503 || errType(out) != "trial_off" {
		t.Fatalf("trial account empty: %d %v", status, out)
	}
	atomic.StoreInt32(&h.fake.status, 0)
	if status, _, _ := h.post(h.api, "/ds/v1/tools/search", token, song("s5", "r1"), map[string]any{"query": "q5"}); status != 503 {
		t.Fatalf("still paused for a while: %d", status)
	}
}

func TestSearchesAreCachedAndCallsPerLookupAreCapped(t *testing.T) {
	h := setup(t)
	_, token := h.pass("a", 10)
	_, other := h.pass("b", 10)
	h.post(h.api, "/ds/v1/tools/search", token, song("s1", "r1"), map[string]any{"query": "same", "count": 8, "need_content": true})
	h.post(h.api, "/ds/v1/tools/search", other, song("s1", "r1"), map[string]any{"query": "same", "count": 8, "need_content": true})
	if got := atomic.LoadInt32(&h.fake.search); got != 1 {
		t.Fatalf("upstream searches = %d, want 1 (the second is cached)", got)
	}
	last := 0
	for i := 0; i < 12; i++ {
		last, _, _ = h.post(h.api, "/ds/chat/completions", token, song("s1", "r1"), map[string]any{"messages": []any{}})
	}
	if last != 429 {
		t.Fatalf("after the per-lookup cap: %d", last)
	}
	if status, _, _ := h.post(h.api, "/ds/chat/completions", "fwt_nope", song("s1", "r1"), map[string]any{}); status != 401 {
		t.Fatalf("unknown token: %d", status)
	}
	if status, _, _ := h.post(h.api, "/ds/chat/completions", token, nil, map[string]any{}); status != 400 {
		t.Fatalf("no song header: %d", status)
	}
}

func TestNothingSecretIsWrittenDown(t *testing.T) {
	h := setup(t)
	_, token := h.pass("a", 10)
	h.post(h.api, "/ds/chat/completions", token, song("s1", "r1"), map[string]any{"messages": []any{}})
	h.post(h.api, "/v1/trial/outcome", token, nil, map[string]any{"song": "s1", "title": "Lemon — 米津玄師", "cards": 3, "story": true})
	h.relay.mu.Lock()
	h.relay.dirty = true
	h.relay.mu.Unlock()
	h.relay.save()
	_ = filepath.Walk(h.relay.dataDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		data, _ := os.ReadFile(path)
		if bytes.Contains(data, []byte(realKey)) || bytes.Contains(data, []byte(token)) {
			t.Errorf("%s contains the key or a token", path)
		}
		return nil
	})
}
