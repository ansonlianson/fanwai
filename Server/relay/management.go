package main

import (
	"bytes"
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

//go:embed management.html
var managementPage []byte

const sessionCookie = "__Secure-fanwai-management"

// Management shares the relay's locked state, but never exposes the unauthenticated
// loopback admin listener. No password, session token, or request body is logged.
func (r *Relay) management() http.Handler {
	admin := http.NewServeMux()
	r.admin(admin)
	passwordHash := strings.TrimSpace(os.Getenv("FANWAI_ADMIN_PASSWORD_HASH"))
	var mu sync.Mutex
	sessions := map[string]time.Time{}
	var attempts []time.Time
	return http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Robots-Tag", "noindex, nofollow")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		if len(passwordHash) != 64 {
			fail(w, 503, "setup", "后台尚未配置登录口令")
			return
		}
		if q.URL.Path == "/manage/" && q.Method == http.MethodGet {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write(managementPage)
			return
		}
		if q.Method != http.MethodPost {
			fail(w, 405, "method", "请使用 POST")
			return
		}
		// JSON plus an exact same-origin check protects cookie-authenticated writes.
		origin, err := url.Parse(q.Header.Get("Origin"))
		if err != nil || origin.Scheme != "https" || origin.Host != q.Host || !strings.HasPrefix(q.Header.Get("Content-Type"), "application/json") {
			fail(w, 403, "origin", "请从后台页面操作")
			return
		}
		q.Body = http.MaxBytesReader(w, q.Body, 8192)
		now := time.Now()
		if q.URL.Path == "/manage/api/login" {
			mu.Lock()
			fresh := attempts[:0]
			for _, t := range attempts {
				if now.Sub(t) < 15*time.Minute {
					fresh = append(fresh, t)
				}
			}
			attempts = fresh
			if len(attempts) >= 30 {
				mu.Unlock()
				fail(w, 429, "login_limit", "登录尝试过多，请 15 分钟后再试")
				return
			}
			attempts = append(attempts, now)
			mu.Unlock()
			var b struct {
				Password string `json:"password"`
			}
			if json.NewDecoder(q.Body).Decode(&b) != nil || subtle.ConstantTimeCompare([]byte(hashToken(b.Password)), []byte(passwordHash)) != 1 {
				fail(w, 401, "login", "口令不正确")
				return
			}
			buf := make([]byte, 32)
			if _, err := rand.Read(buf); err != nil {
				fail(w, 500, "random", "暂时无法登录")
				return
			}
			token := hex.EncodeToString(buf)
			expires := now.Add(14 * 24 * time.Hour)
			mu.Lock()
			for k, expiry := range sessions {
				if now.After(expiry) {
					delete(sessions, k)
				}
			}
			if len(sessions) >= 100 {
				mu.Unlock()
				fail(w, 429, "sessions", "登录设备过多")
				return
			}
			sessions[hashToken(token)] = expires
			mu.Unlock()
			http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: token, Path: "/manage/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: 14 * 24 * 3600, Expires: expires})
			writeJSON(w, 200, map[string]bool{"ok": true})
			return
		}
		cookie, err := q.Cookie(sessionCookie)
		mu.Lock()
		valid := false
		if err == nil {
			expiry, ok := sessions[hashToken(cookie.Value)]
			valid = ok && now.Before(expiry)
		}
		mu.Unlock()
		if !valid {
			fail(w, 401, "login", "请先登录")
			return
		}
		if q.URL.Path == "/manage/api/logout" {
			mu.Lock()
			delete(sessions, hashToken(cookie.Value))
			mu.Unlock()
			http.SetCookie(w, &http.Cookie{Name: sessionCookie, Path: "/manage/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: -1})
			writeJSON(w, 200, map[string]bool{"ok": true})
			return
		}
		action := strings.TrimPrefix(q.URL.Path, "/manage/api/")
		if action == "feedback-list" || action == "feedback-detail" || action == "feedback-update" {
			r.manageFeedback(w, q, action)
			return
		}
		if action != "list" && action != "stats" && action != "new" && action != "grant" && action != "config" {
			fail(w, 404, "not_found", "没有这个操作")
			return
		}
		// Validate browser input separately; CLI compatibility stays intact.
		var body map[string]json.RawMessage
		if json.NewDecoder(q.Body).Decode(&body) != nil {
			fail(w, 400, "input", "请检查输入")
			return
		}
		allowed := map[string]map[string]bool{
			"list": {}, "stats": {},
			"new":    {"label": true, "total": true, "count": true},
			"grant":  {"code": true, "label": true, "remaining": true, "disabled": true},
			"config": {"enabled": true, "dailySongs": true, "dailyCostCNY": true},
		}
		for key := range body {
			if !allowed[action][key] {
				fail(w, 400, "input", "不支持的字段")
				return
			}
		}
		str := func(k string) string { var v string; _ = json.Unmarshal(body[k], &v); return strings.TrimSpace(v) }
		number := func(k string, min, max float64) bool {
			var n float64
			return json.Unmarshal(body[k], &n) == nil && n >= min && n <= max
		}
		integer := func(k string, min, max int) bool {
			var n int
			return json.Unmarshal(body[k], &n) == nil && n >= min && n <= max
		}
		invalid := false
		switch action {
		case "new":
			invalid = str("label") == "" || len(str("label")) > 240 || !integer("total", 1, 100000) || !integer("count", 1, 100)
		case "grant":
			invalid = str("code") == "" || len(body) == 1
			if _, ok := body["remaining"]; ok {
				invalid = invalid || !integer("remaining", 0, 100000)
			}
			if _, ok := body["label"]; ok {
				invalid = invalid || str("label") == "" || len(str("label")) > 240
			}
		case "config":
			if _, ok := body["dailySongs"]; ok {
				invalid = invalid || !integer("dailySongs", 1, 100000)
			}
			if _, ok := body["dailyCostCNY"]; ok {
				invalid = invalid || !number("dailyCostCNY", 0.01, 100000)
			}
		}
		for _, key := range []string{"disabled", "enabled"} {
			if raw, ok := body[key]; ok {
				var b bool
				if string(raw) == "null" || json.Unmarshal(raw, &b) != nil {
					invalid = true
				}
			}
		}
		if invalid {
			fail(w, 400, "input", "请检查名字、数量或额度")
			return
		}
		data, _ := json.Marshal(body)
		q2 := q.Clone(q.Context())
		u := *q.URL
		u.Path = "/admin/" + action
		q2.URL = &u
		q2.Body = http.NoBody
		if len(data) > 0 {
			q2.Body = io.NopCloser(bytes.NewReader(data))
		}
		// Buffer response until the changed state has been persisted.
		reply := &managementReply{header: http.Header{}, status: 200}
		admin.ServeHTTP(reply, q2)
		if reply.status == 200 && (action == "new" || action == "grant") {
			err := r.save()
			if err != nil {
				fail(w, 503, "save", "保存尚未完成，请刷新核对后再操作")
				return
			}
		}
		for key, values := range reply.header {
			for _, v := range values {
				w.Header().Add(key, v)
			}
		}
		w.WriteHeader(reply.status)
		_, _ = w.Write(reply.body.Bytes())
	})
}

type managementReply struct {
	header http.Header
	status int
	body   bytes.Buffer
}

func (w *managementReply) Header() http.Header         { return w.header }
func (w *managementReply) WriteHeader(status int)      { w.status = status }
func (w *managementReply) Write(b []byte) (int, error) { return w.body.Write(b) }
