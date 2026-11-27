package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func feedbackFixture() FeedbackSubmission {
	now := time.Now().UTC()
	return FeedbackSubmission{SchemaVersion: 1, ID: "11111111-1111-4111-8111-111111111111", InstallationID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", SubmittedAt: now, Reasons: []string{"relation"}, Note: "关联作品不对", Snapshot: FeedbackSnapshot{
		CapturedAt: now, Subject: FeedbackWork{ID: "itunes:song:123", Title: "测试歌曲", Creator: "测试艺人", Kind: "song", ArtworkURL: "https://example.org/cover.jpg"},
		Story: &FeedbackStory{Body: "当时屏幕上的故事", Sources: []FeedbackSource{{Title: "访谈", URL: "https://example.org/story", Quote: "用于核对的原文"}}},
		Cards: []FeedbackCard{{Work: FeedbackWork{ID: "local:film", Title: "关联电影", Kind: "film"}, Relation: "配乐出自", Detail: "来自电影配乐", Visible: true, Path: []string{"itunes:song:123", "local:film"}, Sources: []FeedbackSource{{Title: "作品条目", URL: "https://example.org/film", Quote: "原作证据"}}}},
		Page:  FeedbackPage{State: "ready", Phase: "done", ReadURLs: []string{}}, App: FeedbackApp{Version: "0.5.39", Build: "59", SystemVersion: "27.0", ProcessorVersion: "fixture"}, Platform: "apple"}}
}
func feedbackPost(h *harness, in any) (int, map[string]any) {
	status, out, _ := h.post(h.api, "/v1/feedback", "", map[string]string{"Content-Type": "application/json"}, in)
	return status, out
}
func TestFeedbackDurabilityDedupAndTrialIsolation(t *testing.T) {
	h := setup(t)
	code, _ := h.pass("unchanged", 10)
	before, _ := json.Marshal(h.relay.state)
	cfg, _ := json.Marshal(h.relay.cfg.get())
	in := feedbackFixture()
	status, out := feedbackPost(h, in)
	if status != 200 || out["received"] != true {
		t.Fatalf("receive %d %v", status, out)
	}
	in.Note = "重试不应覆盖原文"
	feedbackPost(h, in)
	in.ID = "22222222-2222-4222-8222-222222222222"
	in.Note = "第二次补充"
	feedbackPost(h, in)
	if len(h.relay.feedback.cases) != 1 || len(h.relay.feedback.cases[0].Reports) != 2 || h.relay.feedback.cases[0].Reports[0].Note != "关联作品不对" {
		t.Fatal("retry/merge history")
	}
	in.ID = "33333333-3333-4333-8333-333333333333"
	in.Snapshot.Story.Body = "更新后的另一份结果"
	feedbackPost(h, in)
	if len(h.relay.feedback.cases) != 2 {
		t.Fatal("different result was merged")
	}
	in.ID = "44444444-4444-4444-8444-444444444444"
	in.InstallationID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	feedbackPost(h, in)
	if len(h.relay.feedback.cases) != 3 {
		t.Fatal("two installations were merged")
	}
	reload := newFeedbackStore(h.relay.dataDir)
	if reload.loadErr != nil || len(reload.cases) != 3 || reload.cases[0].Snapshot.Cards[0].Sources[0].Quote != "原作证据" {
		t.Fatal("snapshot did not persist")
	}
	after, _ := json.Marshal(h.relay.state)
	afterCfg, _ := json.Marshal(h.relay.cfg.get())
	if !bytes.Equal(before, after) || !bytes.Equal(cfg, afterCfg) || h.used(code) != 0 || h.fake.chat != 0 || h.fake.search != 0 || h.fake.fetch != 0 {
		t.Fatal("feedback touched quota/model")
	}
}
func TestFeedbackManagementAuthenticationAndHandling(t *testing.T) {
	t.Setenv("FANWAI_ADMIN_PASSWORD_HASH", hashToken("feedback-test-password"))
	h := setup(t)
	in := feedbackFixture()
	feedbackPost(h, in)
	router := h.relay.routes()
	call := func(action string, body any, cookie *http.Cookie, origin string) *httptest.ResponseRecorder {
		raw, _ := json.Marshal(body)
		q := httptest.NewRequest("POST", "https://fanwai.xyz/manage/api/"+action, bytes.NewReader(raw))
		q.Header.Set("Origin", origin)
		q.Header.Set("Content-Type", "application/json")
		if cookie != nil {
			q.AddCookie(cookie)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, q)
		return w
	}
	for _, action := range []string{"feedback-list", "feedback-detail", "feedback-update"} {
		if call(action, map[string]any{"id": in.ID}, nil, "https://fanwai.xyz").Code != 401 {
			t.Fatal("public feedback management", action)
		}
	}
	login := call("login", map[string]any{"password": "feedback-test-password"}, nil, "https://fanwai.xyz")
	if login.Code != 200 {
		t.Fatal("login")
	}
	cookie := login.Result().Cookies()[0]
	if call("feedback-update", map[string]any{"id": in.ID, "status": "done"}, cookie, "https://evil.example").Code != 403 {
		t.Fatal("cross site")
	}
	update := call("feedback-update", map[string]any{"id": in.ID, "status": "done", "internalNote": "已定位到关系类型，59 修复"}, cookie, "https://fanwai.xyz")
	if update.Code != 200 {
		t.Fatal("update", update.Body.String())
	}
	detail := call("feedback-detail", map[string]any{"id": in.ID}, cookie, "https://fanwai.xyz")
	var c FeedbackCase
	if json.Unmarshal(detail.Body.Bytes(), &c) != nil || c.Status != "done" || c.Snapshot.Story.Body != in.Snapshot.Story.Body || c.InternalNote == "" {
		t.Fatal("detail")
	}
	reload := newFeedbackStore(h.relay.dataDir)
	if reload.cases[0].Status != "done" || reload.cases[0].InternalNote != c.InternalNote {
		t.Fatal("handling not persisted")
	}
	in.ID = "22222222-2222-4222-8222-222222222222"
	feedbackPost(h, in)
	list := call("feedback-list", map[string]any{}, cookie, "https://fanwai.xyz")
	var summaries []map[string]any
	json.Unmarshal(list.Body.Bytes(), &summaries)
	if list.Code != 200 || len(summaries) != 1 || summaries[0]["status"] != "new" || summaries[0]["reports"] != float64(2) {
		t.Fatal("new revision not reopened")
	}

}
func TestFeedbackSanitizesOnlyAllowedSnapshotFields(t *testing.T) {
	h := setup(t)
	in := feedbackFixture()
	in.Note = "sk-notarealtestkey123 user@example.org Bearer fixtureToken123456"
	in.Snapshot.Subject.SourceURL = "https://user:pass@example.org/song?id=12&token=private#secret"
	in.Snapshot.Subject.ArtworkURL = "file:///private/device.jpg"
	in.Snapshot.Story.Sources[0].URL = "https://example.org/a?api_key=secret&v=good"
	in.Snapshot.Story.Sources[0].Quote = "Bearer testSecretToken1234"
	if status, _ := feedbackPost(h, in); status != 200 {
		t.Fatal("sanitized receive", status)
	}
	b, _ := os.ReadFile(filepath.Join(h.relay.dataDir, "feedback.json"))
	for _, secret := range []string{"notarealtestkey123", "user@example.org", "fixtureToken123456", "testSecretToken1234", "user:pass", "token=private", "file:///", "api_key"} {
		if bytes.Contains(b, []byte(secret)) {
			t.Fatal("retained private field", secret)
		}
	}
	if !bytes.Contains(b, []byte("id=12")) {
		t.Fatal("lost safe identity")
	}
	raw, _ := json.Marshal(in)
	var extra map[string]any
	json.Unmarshal(raw, &extra)
	extra["apiKey"] = "fixture-only"
	if status, _ := feedbackPost(h, extra); status != 400 {
		t.Fatal("unknown credential field allowed")
	}
	in.Note = strings.Repeat("字", 501)
	if status, _ := feedbackPost(h, in); status != 400 {
		t.Fatal("long note")
	}
	in.Note = ""
	in.Reasons = []string{"invented"}
	if status, _ := feedbackPost(h, in); status != 400 {
		t.Fatal("unknown reason")
	}
	in.Reasons = nil
	in.ID = "not-uuid"
	if status, _ := feedbackPost(h, in); status != 400 {
		t.Fatal("invalid id")
	}
}
func TestFeedbackStorageFailureNeverAcknowledgesOrOverwrites(t *testing.T) {
	h := setup(t)
	in := feedbackFixture()
	path := h.relay.feedback.path
	if err := os.Mkdir(path+".tmp", 0700); err != nil {
		t.Fatal(err)
	}
	if status, out := feedbackPost(h, in); status != 503 || out["received"] == true || len(h.relay.feedback.cases) != 0 {
		t.Fatal("acknowledged a failed save")
	}
	os.Remove(path + ".tmp")
	if status, _ := feedbackPost(h, in); status != 200 {
		t.Fatal("retry after save failure")
	}
	corrupt := []byte("{broken feedback storage")
	os.WriteFile(path, corrupt, 0600)
	h.relay.feedback = newFeedbackStore(h.relay.dataDir)
	if status, _ := feedbackPost(h, in); status != 503 {
		t.Fatal("corruption acknowledged")
	}
	h.relay.feedback.sweep()
	after, _ := os.ReadFile(path)
	if !bytes.Equal(after, corrupt) {
		t.Fatal("corrupted file overwritten")
	}
}
func TestFeedbackConcurrentRetryAndResultIdentity(t *testing.T) {
	h := setup(t)
	in := feedbackFixture()
	var wg sync.WaitGroup
	codes := make(chan int, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			raw, _ := json.Marshal(in)
			res, err := http.Post(h.api.URL+"/v1/feedback", "application/json", bytes.NewReader(raw))
			if err != nil {
				codes <- 0
				return
			}
			res.Body.Close()
			codes <- res.StatusCode
		}()
	}
	wg.Wait()
	close(codes)
	for code := range codes {
		if code != 200 {
			t.Fatal("concurrent receive", code)
		}
	}
	if len(h.relay.feedback.cases) != 1 || len(h.relay.feedback.cases[0].Reports) != 1 {
		t.Fatal("concurrent retry duplicated")
	}
	in.InstallationID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	if status, _ := feedbackPost(h, in); status != 409 {
		t.Fatal("id collision returned someone else's receipt")
	}
	in.InstallationID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	in.ID = "22222222-2222-4222-8222-222222222222"
	in.Snapshot.Page.LastEvent = "http-503"
	feedbackPost(h, in)
	if len(h.relay.feedback.cases) != 2 {
		t.Fatal("changed error state merged")
	}
}
func TestFeedbackRetentionAndRateLimit(t *testing.T) {
	h := setup(t)
	in := feedbackFixture()
	feedbackPost(h, in)
	h.relay.feedback.cases[0].CreatedAt = time.Now().Add(-91 * 24 * time.Hour)
	h.relay.feedback.save()
	h.relay.feedback.sweep()
	if len(newFeedbackStore(h.relay.dataDir).cases) != 0 {
		t.Fatal("old feedback retained")
	}
	for i := 0; i < 30; i++ {
		in.ID = fmt.Sprintf("%08x-1111-4111-8111-111111111111", i+100)
		in.InstallationID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
		if status, _ := feedbackPost(h, in); status != 200 {
			t.Fatal("too early limit", i, status)
		}
	}
	in.ID = "99999999-9999-4999-8999-999999999999"
	if status, _ := feedbackPost(h, in); status != 429 {
		t.Fatal("installation limit")
	}
}
