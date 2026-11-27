package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

func TestManagementLoginQuotaAndLiveUsage(t *testing.T) {
	t.Setenv("FANWAI_ADMIN_PASSWORD_HASH", hashToken("management-test-password"))
	h := setup(t)
	web := httptest.NewServer(h.relay.routes())
	defer web.Close()
	call := func(action string, body any, cookie *http.Cookie, origin string) (int, []byte, []*http.Cookie) {
		data, _ := json.Marshal(body)
		q, _ := http.NewRequest("POST", web.URL+"/manage/api/"+action, bytes.NewReader(data))
		q.Header.Set("Content-Type", "application/json")
		q.Header.Set("Origin", origin)
		if cookie != nil {
			q.AddCookie(cookie)
		}
		resp, err := http.DefaultClient.Do(q)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, raw, resp.Cookies()
	}
	origin := "https://" + web.Listener.Addr().String()
	if status, _, _ := call("list", map[string]any{}, nil, origin); status != 401 {
		t.Fatal("unauthenticated list", status)
	}
	if status, _, _ := call("login", map[string]string{"password": "bad"}, nil, origin); status != 401 {
		t.Fatal("bad password", status)
	}
	status, _, cookies := call("login", map[string]string{"password": "management-test-password"}, nil, origin)
	if status != 200 || len(cookies) != 1 {
		t.Fatal("login", status)
	}
	cookie := cookies[0]
	if !cookie.Secure || !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode {
		t.Fatal("unsafe cookie")
	}
	if status, _, _ := call("new", map[string]any{"label": "forged", "count": 1, "total": 1}, cookie, "https://other.example"); status != 403 {
		t.Fatal("cross-origin write", status)
	}
	status, raw, _ := call("new", map[string]any{"label": "朋友", "count": 1, "total": 2}, cookie, origin)
	var made []Pass
	_ = json.Unmarshal(raw, &made)
	if status != 200 || len(made) != 1 {
		t.Fatalf("new: %d %s", status, raw)
	}
	code := made[0].Code
	// An app lookup updates the same state the browser reads, with no paid request.
	_, out, _ := h.post(h.api, "/v1/trial/redeem", "", nil, map[string]any{"code": code})
	token := out["token"].(string)
	h.post(h.api, "/ds/chat/completions", token, song("management-song", "r1"), map[string]any{"messages": []any{}})
	status, raw, _ = call("list", map[string]any{}, cookie, origin)
	var list []Pass
	_ = json.Unmarshal(raw, &list)
	if status != 200 || len(list) != 1 || list[0].Used != 1 {
		t.Fatalf("live usage %d %s", status, raw)
	}
	status, raw, _ = call("grant", map[string]any{"code": code, "label": "阿明", "remaining": 25}, cookie, origin)
	var updated Pass
	_ = json.Unmarshal(raw, &updated)
	if status != 200 || updated.Used != 1 || updated.Total != 26 || updated.Label != "阿明" || updated.CostCNY <= 0 {
		t.Fatalf("quota/history %d %s", status, raw)
	}
	// Accepted changes must survive an immediate reload, not just a later timer.
	reloaded := newRelay(filepath.Join(h.relay.dataDir, "config.json"), h.relay.dataDir, realKey, h.fake.server.URL)
	if p := reloaded.state.Passes[code]; p == nil || p.Total != 26 || p.Used != 1 {
		t.Fatal("change not persisted")
	}
	for _, v := range []any{-1, 1.5, "100"} {
		if status, _, _ := call("grant", map[string]any{"code": code, "remaining": v}, cookie, origin); status != 400 {
			t.Fatal("bad quota accepted", v, status)
		}
	}
	call("grant", map[string]any{"code": code, "disabled": true}, cookie, origin)
	if status, _, _ := h.post(h.api, "/ds/chat/completions", token, song("other", "r1"), map[string]any{"messages": []any{}}); status != 403 {
		t.Fatal("disabled code", status)
	}
	call("grant", map[string]any{"code": code, "disabled": false, "remaining": 0}, cookie, origin)
	if status, _, _ := h.post(h.api, "/ds/chat/completions", token, song("other", "r1"), map[string]any{"messages": []any{}}); status != 402 {
		t.Fatal("zero quota", status)
	}
	call("config", map[string]any{"dailySongs": 200, "dailyCostCNY": 20}, cookie, origin)
	if cfg := h.relay.cfg.get(); cfg.DailySongs != 200 || cfg.DailyCostCNY != 20 {
		t.Fatal("daily config not saved")
	}
	// Bulk creation uses the same authenticated, durable state as single creation.
	status, raw, _ = call("new", map[string]any{"label": "首批体验", "count": 3, "total": 10}, cookie, origin)
	var batch []Pass
	if json.Unmarshal(raw, &batch) != nil || status != 200 || len(batch) != 3 {
		t.Fatalf("batch: status=%d", status)
	}
	reloaded = newRelay(filepath.Join(h.relay.dataDir, "config.json"), h.relay.dataDir, realKey, h.fake.server.URL)
	seen := map[string]bool{}
	for i, p := range batch {
		wantLabel := []string{"首批体验-01", "首批体验-02", "首批体验-03"}[i]
		if p.Label != wantLabel || p.Total != 10 || p.Used != 0 || seen[p.Code] || reloaded.state.Passes[p.Code] == nil {
			t.Fatal("batch numbering, quota, uniqueness or persistence")
		}
		seen[p.Code] = true
	}
	if p := reloaded.state.Passes[code]; p == nil || p.Label != "阿明" || p.Used != updated.Used || p.CostCNY != updated.CostCNY {
		t.Fatal("batch changed prior usage")
	}
	if status, _, _ := call("new", map[string]any{"label": "超量", "count": 101, "total": 10}, cookie, origin); status != 400 {
		t.Fatal("batch limit", status)
	}
	call("logout", map[string]any{}, cookie, origin)
	if status, _, _ := call("list", map[string]any{}, cookie, origin); status != 401 {
		t.Fatal("logout retained session", status)
	}
}

func TestPublicAdminEndpointsStayClosed(t *testing.T) {
	t.Setenv("FANWAI_ADMIN_PASSWORD_HASH", hashToken("test-password"))
	h := setup(t)
	for _, path := range []string{"/admin/list", "/admin/new", "/manage/api/list"} {
		res, err := http.Get(h.api.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode == 200 {
			t.Fatal("public endpoint", path)
		}
	}
	res, err := http.Get(h.api.URL + "/manage/")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 || res.Header.Get("Cache-Control") != "no-store" {
		t.Fatal("management page headers")
	}
}
