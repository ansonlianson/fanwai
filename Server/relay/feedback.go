package main

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// Explicit, bounded schema: no request logs, credentials, library or settings dumps.
// It is separate from the trial ledger: reporting never charges a lookup.
type FeedbackWork struct {
	ID         string `json:"id"`
	Title      string `json:"title"`
	Creator    string `json:"creator"`
	Album      string `json:"album"`
	Kind       string `json:"kind"`
	ArtworkURL string `json:"artworkURL"`
	SourceURL  string `json:"sourceURL"`
}
type FeedbackSource struct {
	Title string `json:"title"`
	URL   string `json:"url"`
	Quote string `json:"quote"`
}
type FeedbackStory struct {
	Body      string           `json:"body"`
	Scope     string           `json:"scope"`
	SubjectID string           `json:"subjectID"`
	Sources   []FeedbackSource `json:"sources"`
}
type FeedbackCard struct {
	Work     FeedbackWork     `json:"work"`
	Relation string           `json:"relation"`
	Detail   string           `json:"detail"`
	Visible  bool             `json:"visible"`
	Path     []string         `json:"path"`
	Sources  []FeedbackSource `json:"sources"`
}
type FeedbackPage struct {
	State            string     `json:"state"`
	Phase            string     `json:"phase"`
	LastEvent        string     `json:"lastEvent"`
	StoryResult      string     `json:"storyResult"`
	StartedAt        *time.Time `json:"startedAt,omitempty"`
	ElapsedSeconds   *float64   `json:"elapsedSeconds,omitempty"`
	Failures         int        `json:"failures"`
	Searches         *int       `json:"searches,omitempty"`
	ReadURLs         []string   `json:"readURLs"`
	UnconfirmedCount int        `json:"unconfirmedCount"`
	ReadingPinned    bool       `json:"readingPinned"`
}
type FeedbackApp struct {
	Version          string     `json:"version"`
	Build            string     `json:"build"`
	SystemVersion    string     `json:"systemVersion"`
	ProcessorVersion string     `json:"processorVersion"`
	ReportVersion    *int       `json:"reportVersion,omitempty"`
	GeneratedAt      *time.Time `json:"generatedAt,omitempty"`
	Seconds          *float64   `json:"seconds,omitempty"`
	// Unknown is kept unknown. Current model settings cannot identify a cached result's model.
	Model string `json:"model"`
}
type FeedbackDiagnostic struct {
	Date           time.Time `json:"date"`
	Phase          string    `json:"phase"`
	Outcome        string    `json:"outcome"`
	Processor      string    `json:"processor"`
	Contract       string    `json:"contract"`
	Seconds        float64   `json:"seconds"`
	ReusedEvidence bool      `json:"reusedEvidence"`
	Facts          int       `json:"facts"`
	HasStory       bool      `json:"hasStory"`
}
type FeedbackSnapshot struct {
	CapturedAt       time.Time           `json:"capturedAt"`
	Subject          FeedbackWork        `json:"subject"`
	Story            *FeedbackStory      `json:"story,omitempty"`
	Cards            []FeedbackCard      `json:"cards"`
	Page             FeedbackPage        `json:"page"`
	App              FeedbackApp         `json:"app"`
	Platform         string              `json:"platform"`
	Diagnostic       *FeedbackDiagnostic `json:"diagnostic,omitempty"`
	ContentTruncated bool                `json:"contentTruncated"`
}
type FeedbackSubmission struct {
	SchemaVersion  int              `json:"schemaVersion"`
	ID             string           `json:"id"`
	InstallationID string           `json:"installationID"`
	Reasons        []string         `json:"reasons"`
	Note           string           `json:"note"`
	SubmittedAt    time.Time        `json:"submittedAt"`
	Snapshot       FeedbackSnapshot `json:"snapshot"`
}
type FeedbackRevision struct {
	ID          string    `json:"id"`
	Reasons     []string  `json:"reasons"`
	Note        string    `json:"note"`
	SubmittedAt time.Time `json:"submittedAt"`
	ReceivedAt  time.Time `json:"receivedAt"`
}
type FeedbackCase struct {
	ID               string             `json:"id"`
	InstallationHash string             `json:"installationHash"`
	Fingerprint      string             `json:"fingerprint"`
	CreatedAt        time.Time          `json:"createdAt"`
	UpdatedAt        time.Time          `json:"updatedAt"`
	Reasons          []string           `json:"reasons"`
	Status           string             `json:"status"`
	InternalNote     string             `json:"internalNote"`
	Snapshot         FeedbackSnapshot   `json:"snapshot"`
	Reports          []FeedbackRevision `json:"reports"`
}
type feedbackStore struct {
	mu      sync.Mutex
	path    string
	cases   []FeedbackCase
	loadErr error
	limits  map[string][]time.Time
}

var feedbackUUID = regexp.MustCompile(`(?i)^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)
var feedbackSecret = regexp.MustCompile(`(?i)\b(?:sk-[a-z0-9_-]{8,}|bearer\s+[a-z0-9._~+/-]{8,}|fw_[a-z0-9_-]{12,})`)
var feedbackEmail = regexp.MustCompile(`(?i)[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}`)
var feedbackReasons = map[string]bool{"story": true, "relation": true, "artwork": true, "missing": true, "loading": true, "other": true}

func feedbackText(v string, limit int) string {
	v = feedbackSecret.ReplaceAllString(v, "[已隐去]")
	v = feedbackEmail.ReplaceAllString(v, "[邮箱已隐去]")
	v = strings.Map(func(r rune) rune {
		if r < 32 && r != '\n' && r != '\t' {
			return -1
		}
		return r
	}, v)
	return string([]rune(v)[:min(utf8.RuneCountInString(v), limit)])
}
func feedbackURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" {
		return ""
	}
	u.User = nil
	u.Fragment = ""
	q := url.Values{}
	for _, k := range []string{"id", "v", "title", "curid", "oldid", "country", "lang", "t"} {
		if v := u.Query().Get(k); v != "" && len(v) < 300 && !feedbackSecret.MatchString(v) && !feedbackEmail.MatchString(v) {
			q.Set(k, v)
		}
	}
	u.RawQuery = q.Encode()
	if feedbackSecret.MatchString(u.Path) || feedbackEmail.MatchString(u.Path) || len(u.String()) > 2048 {
		return ""
	}
	return u.String()
}
func sanitizeFeedbackWork(w *FeedbackWork) {
	w.ID = feedbackText(w.ID, 240)
	w.Title = feedbackText(w.Title, 500)
	w.Creator = feedbackText(w.Creator, 500)
	w.Album = feedbackText(w.Album, 500)
	w.Kind = feedbackText(w.Kind, 40)
	w.ArtworkURL = feedbackURL(w.ArtworkURL)
	w.SourceURL = feedbackURL(w.SourceURL)
}
func sanitizeFeedback(s *FeedbackSubmission) error {
	if s.SchemaVersion != 1 || !feedbackUUID.MatchString(s.ID) || !feedbackUUID.MatchString(s.InstallationID) || s.Snapshot.CapturedAt.IsZero() || s.SubmittedAt.IsZero() || s.Snapshot.Subject.ID == "" || strings.TrimSpace(s.Snapshot.Subject.Title) == "" {
		return errors.New("schema")
	}
	if len(s.Reasons) > 6 || utf8.RuneCountInString(s.Note) > 500 || len(s.Snapshot.Cards) > 80 || len(s.Snapshot.Page.ReadURLs) > 40 {
		return errors.New("size")
	}
	seen := map[string]bool{}
	reasons := []string{}
	for _, r := range s.Reasons {
		if !feedbackReasons[r] {
			return errors.New("reason")
		}
		if !seen[r] {
			reasons = append(reasons, r)
			seen[r] = true
		}
	}
	s.Reasons = reasons
	s.ID = strings.ToLower(s.ID)
	s.InstallationID = strings.ToLower(s.InstallationID)
	s.Note = feedbackText(s.Note, 500)
	v := &s.Snapshot
	sanitizeFeedbackWork(&v.Subject)
	if v.Story != nil {
		if len(v.Story.Sources) > 16 {
			return errors.New("sources")
		}
		v.Story.Body = feedbackText(v.Story.Body, 16000)
		v.Story.Scope = feedbackText(v.Story.Scope, 200)
		v.Story.SubjectID = feedbackText(v.Story.SubjectID, 240)
		for i := range v.Story.Sources {
			v.Story.Sources[i].Title = feedbackText(v.Story.Sources[i].Title, 500)
			v.Story.Sources[i].URL = feedbackURL(v.Story.Sources[i].URL)
			v.Story.Sources[i].Quote = feedbackText(v.Story.Sources[i].Quote, 2000)
		}
	}
	for i := range v.Cards {
		c := &v.Cards[i]
		sanitizeFeedbackWork(&c.Work)
		c.Relation = feedbackText(c.Relation, 120)
		c.Detail = feedbackText(c.Detail, 1500)
		if len(c.Path) > 16 {
			return errors.New("path")
		}
		for j := range c.Path {
			c.Path[j] = feedbackText(c.Path[j], 240)
		}
		if len(c.Sources) > 12 {
			return errors.New("sources")
		}
		for j := range c.Sources {
			c.Sources[j].Title = feedbackText(c.Sources[j].Title, 500)
			c.Sources[j].URL = feedbackURL(c.Sources[j].URL)
			c.Sources[j].Quote = feedbackText(c.Sources[j].Quote, 2000)
		}
	}
	p := &v.Page
	p.State = feedbackText(p.State, 40)
	p.Phase = feedbackText(p.Phase, 40)
	p.LastEvent = feedbackText(p.LastEvent, 200)
	p.StoryResult = feedbackText(p.StoryResult, 40)
	for i, u := range p.ReadURLs {
		p.ReadURLs[i] = feedbackURL(u)
	}
	a := &v.App
	a.Version = feedbackText(a.Version, 40)
	a.Build = feedbackText(a.Build, 40)
	a.SystemVersion = feedbackText(a.SystemVersion, 80)
	a.ProcessorVersion = feedbackText(a.ProcessorVersion, 120)
	a.Model = feedbackText(a.Model, 120)
	v.Platform = feedbackText(v.Platform, 30)
	if d := v.Diagnostic; d != nil {
		d.Phase = feedbackText(d.Phase, 80)
		d.Outcome = feedbackText(d.Outcome, 100)
		d.Processor = feedbackText(d.Processor, 120)
		d.Contract = feedbackText(d.Contract, 120)
	}
	return nil
}
func newFeedbackStore(dir string) *feedbackStore {
	s := &feedbackStore{path: filepath.Join(dir, "feedback.json"), cases: []FeedbackCase{}, limits: map[string][]time.Time{}}
	b, e := os.ReadFile(s.path)
	if e == nil {
		s.loadErr = json.Unmarshal(b, &s.cases)
	} else if !os.IsNotExist(e) {
		s.loadErr = e
	}
	if s.cases == nil {
		s.cases = []FeedbackCase{}
	}
	return s
}

// Lock held. Acknowledge only after durable replacement. The caller rolls memory back on error.
func (s *feedbackStore) save() error {
	if s.loadErr != nil {
		return s.loadErr
	}
	b, e := json.Marshal(s.cases)
	if e != nil {
		return e
	}
	if len(b) > 32<<20 {
		return errors.New("feedback capacity")
	}
	tmp := s.path + ".tmp"
	f, e := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	if _, e = f.Write(b); e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e == nil {
		e = closeErr
	}
	if e == nil {
		e = os.Rename(tmp, s.path)
	}
	if e != nil {
		_ = os.Remove(tmp)
	}
	return e
}
func feedbackFingerprint(v FeedbackSnapshot) string {
	// Timing and capture date change between taps. Content, page state and app build define a result.
	b, _ := json.Marshal(struct {
		Subject                                                         FeedbackWork
		Story                                                           *FeedbackStory
		Cards                                                           []FeedbackCard
		State, Phase, LastEvent, StoryResult, Version, Build, Processor string
	}{v.Subject, v.Story, v.Cards, v.Page.State, v.Page.Phase, v.Page.LastEvent, v.Page.StoryResult, v.App.Version, v.App.Build, v.App.ProcessorVersion})
	return hashToken(string(b))
}
func (r *Relay) receiveFeedback(w http.ResponseWriter, q *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if q.Method != "POST" {
		fail(w, 405, "method", "请使用 POST")
		return
	}
	if !strings.HasPrefix(q.Header.Get("Content-Type"), "application/json") {
		fail(w, 415, "content", "请使用 JSON")
		return
	}
	// Browser submissions must come from our own origin; native requests have no Origin.
	if o := q.Header.Get("Origin"); o != "" && o != "https://fanwai.xyz" && o != "https://api.fanwai.xyz" {
		fail(w, 403, "origin", "不支持的来源")
		return
	}
	s := r.feedback
	now := time.Now().UTC()
	ip := clientIP(q)
	if host, _, err := net.SplitHostPort(ip); err == nil {
		ip = host
	}
	bucket := "ip:" + hashToken(ip)
	s.mu.Lock()
	allowed := s.allow(bucket, now, 120)
	s.mu.Unlock()
	if !allowed {
		w.Header().Set("Retry-After", "3600")
		fail(w, 429, "limit", "反馈较多，请稍后再试")
		return
	}
	q.Body = http.MaxBytesReader(w, q.Body, 128<<10)
	var input FeedbackSubmission
	dec := json.NewDecoder(q.Body)
	dec.DisallowUnknownFields()
	if dec.Decode(&input) != nil || dec.Decode(&struct{}{}) != io.EOF || sanitizeFeedback(&input) != nil {
		fail(w, 400, "input", "请更新后重试反馈")
		return
	}
	// Do not hold the store lock while reading an untrusted request body.
	s.mu.Lock()
	defer s.mu.Unlock()
	install := hashToken(input.InstallationID)
	if s.loadErr != nil {
		fail(w, 503, "save", "反馈暂时无法保存")
		return
	}
	for _, c := range s.cases {
		if now.Sub(c.CreatedAt) >= 90*24*time.Hour {
			continue
		}
		for _, p := range c.Reports {
			if p.ID == input.ID {
				if c.InstallationHash != install {
					fail(w, 409, "id", "反馈编号重复")
					return
				}
				writeJSON(w, 200, map[string]any{"id": c.ID, "received": true})
				return
			}
		}
	}
	if !s.allow("install:"+install, now, 30) {
		w.Header().Set("Retry-After", "3600")
		fail(w, 429, "limit", "反馈较多，请稍后再试")
		return
	}
	old := s.cases
	// Copy before mutation so a storage failure cannot masquerade as a successful retry.
	next := make([]FeedbackCase, 0, len(old)+1)
	for _, c := range old {
		if now.Sub(c.CreatedAt) < 90*24*time.Hour {
			next = append(next, c)
		}
	}
	fingerprint := feedbackFingerprint(input.Snapshot)
	index := -1
	for i, c := range next {
		if c.InstallationHash == install && c.Fingerprint == fingerprint {
			index = i
			break
		}
	}
	if index < 0 {
		if len(next) >= 3000 {
			fail(w, 503, "capacity", "反馈暂时无法保存")
			return
		}
		next = append(next, FeedbackCase{ID: input.ID, InstallationHash: install, Fingerprint: fingerprint, CreatedAt: now, Status: "new", Snapshot: input.Snapshot, Reasons: []string{}, Reports: []FeedbackRevision{}})
		index = len(next) - 1
	}
	c := next[index]
	// Retain each user's revision; a retry is handled above and never adds a revision.
	if len(c.Reports) >= 50 {
		fail(w, 429, "revisions", "这份结果的反馈已收到")
		return
	}
	c.Reports = append(append([]FeedbackRevision{}, c.Reports...), FeedbackRevision{input.ID, input.Reasons, input.Note, input.SubmittedAt, now})
	c.Reasons = append([]string{}, c.Reasons...)
	for _, v := range input.Reasons {
		found := false
		for _, a := range c.Reasons {
			found = found || a == v
		}
		if !found {
			c.Reasons = append(c.Reasons, v)
		}
	}
	c.UpdatedAt = now
	c.Status = "new"
	next[index] = c
	s.cases = next
	if e := s.save(); e != nil {
		s.cases = old
		fail(w, 503, "save", "反馈暂时无法保存")
		return
	}
	writeJSON(w, 200, map[string]any{"id": c.ID, "received": true})
}
func (s *feedbackStore) allow(k string, now time.Time, maxCount int) bool {
	if len(s.limits) > 4096 {
		for key, times := range s.limits {
			if len(times) == 0 || now.Sub(times[len(times)-1]) > time.Hour {
				delete(s.limits, key)
			}
		}
		if len(s.limits) > 8192 {
			return false
		}
	}
	kept := []time.Time{}
	for _, t := range s.limits[k] {
		if now.Sub(t) < time.Hour {
			kept = append(kept, t)
		}
	}
	if len(kept) >= maxCount {
		return false
	}
	s.limits[k] = append(kept, now)
	return true
}
func (r *Relay) manageFeedback(w http.ResponseWriter, q *http.Request, action string) {
	s := r.feedback
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.loadErr != nil {
		fail(w, 503, "save", "反馈数据暂时无法读取")
		return
	}
	var in struct {
		ID           string `json:"id"`
		Status       string `json:"status"`
		InternalNote string `json:"internalNote"`
	}
	dec := json.NewDecoder(q.Body)
	dec.DisallowUnknownFields()
	if dec.Decode(&in) != nil || dec.Decode(&struct{}{}) != io.EOF {
		fail(w, 400, "input", "请检查输入")
		return
	}
	if action == "feedback-list" {
		list := []map[string]any{}
		for _, c := range s.cases {
			if time.Since(c.CreatedAt) > 90*24*time.Hour {
				continue
			}
			notes := []string{}
			for _, p := range c.Reports {
				if p.Note != "" {
					notes = append(notes, p.Note)
				}
			}
			list = append(list, map[string]any{"id": c.ID, "createdAt": c.CreatedAt, "updatedAt": c.UpdatedAt, "subject": c.Snapshot.Subject, "reasons": c.Reasons, "note": strings.Join(notes, "\n"), "version": c.Snapshot.App.Version, "build": c.Snapshot.App.Build, "status": c.Status, "reports": len(c.Reports)})
		}
		sort.Slice(list, func(i, j int) bool { return list[i]["updatedAt"].(time.Time).After(list[j]["updatedAt"].(time.Time)) })
		writeJSON(w, 200, list)
		return
	}
	for i, c := range s.cases {
		if c.ID == in.ID && time.Since(c.CreatedAt) <= 90*24*time.Hour {
			if action == "feedback-detail" {
				writeJSON(w, 200, c)
				return
			}
			if action == "feedback-update" {
				if (in.Status != "new" && in.Status != "done" && in.Status != "wontfix") || utf8.RuneCountInString(in.InternalNote) > 2000 {
					fail(w, 400, "input", "请检查状态或备注")
					return
				}
				c.Status = in.Status
				c.InternalNote = feedbackText(in.InternalNote, 2000)
				old := s.cases[i]
				s.cases[i] = c
				if s.save() != nil {
					s.cases[i] = old
					fail(w, 503, "save", "暂时无法保存处理记录")
					return
				}
				writeJSON(w, 200, c)
				return
			}
		}
	}
	fail(w, 404, "not_found", "没有这条反馈")
}

// Purge on the relay's existing hourly sweep, including quiet periods.
func (s *feedbackStore) sweep() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.loadErr != nil {
		return
	}
	old := s.cases
	kept := make([]FeedbackCase, 0, len(old))
	for _, c := range old {
		if time.Since(c.CreatedAt) <= 90*24*time.Hour {
			kept = append(kept, c)
		}
	}
	if len(kept) != len(old) {
		s.cases = kept
		if s.save() != nil {
			s.cases = old
		}
	}
}
