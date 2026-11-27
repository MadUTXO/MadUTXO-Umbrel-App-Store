package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAllowedIP(t *testing.T) {
	tests := []struct {
		ip   string
		want bool
	}{
		{"10.21.0.1", true},
		{"127.0.0.1", true},
		{"::1", true},
		{"10.21.0.2", false},
		{"192.168.1.10", false},
		{"not-an-ip", false},
	}
	for _, tt := range tests {
		if got := allowedIP(tt.ip); got != tt.want {
			t.Errorf("allowedIP(%q) = %v, want %v", tt.ip, got, tt.want)
		}
	}
}

func TestPatterns(t *testing.T) {
	if !appIDPattern.MatchString("madutxo-torlink") {
		t.Error("expected app id to match")
	}
	if appIDPattern.MatchString("-bad") {
		t.Error("expected leading dash to fail")
	}
	if !requestIDPattern.MatchString("0123456789abcdef0123456789abcdef") {
		t.Error("expected request id to match")
	}
	if requestIDPattern.MatchString("0123456789abcdef") {
		t.Error("expected short request id to fail")
	}
	onion := strings.Repeat("a", 56) + ".onion"
	if !onionPattern.MatchString(onion) {
		t.Error("expected onion to match")
	}
	if onionPattern.MatchString(strings.Repeat("a", 55) + ".onion") {
		t.Error("expected short onion to fail")
	}
}

func TestReadDashboardOnion(t *testing.T) {
	dir := t.TempDir()
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.readDashboardOnion(); got != "" {
		t.Fatalf("missing file = %q", got)
	}
	onion := strings.Repeat("b", 56) + ".onion"
	if err := os.WriteFile(filepath.Join(dir, "dashboard-onion"), []byte(onion+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := s.readDashboardOnion(); got != onion {
		t.Fatalf("readDashboardOnion() = %q, want %q", got, onion)
	}
	if err := os.WriteFile(filepath.Join(dir, "dashboard-onion"), []byte("not-an-onion\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := s.readDashboardOnion(); got != "" {
		t.Fatalf("invalid onion = %q", got)
	}
}

func TestWriteJSONAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pending")
	req := rotationRequest{
		RequestID:   "0123456789abcdef0123456789abcdef",
		AppID:       "foo",
		RequestedAt: time.Now().UTC().Format(time.RFC3339),
	}
	if err := writeJSONAtomic(path, req.RequestID+".json", req, 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(path, req.RequestID+".json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o, want 600", info.Mode().Perm())
	}
}

func TestIndexRejectsNonGateway(t *testing.T) {
	s, err := newServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://example/", nil)
	req.RemoteAddr = "10.21.0.2:1234"
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}

func TestIndexAllowsGateway(t *testing.T) {
	s, err := newServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://example/", nil)
	req.RemoteAddr = "10.21.0.1:1234"
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "Onionator") {
		t.Fatal("expected page title")
	}
	if len(rec.Result().Cookies()) == 0 {
		t.Fatal("expected csrf cookie")
	}
}

func TestIndexShowsOnlyEligibleApps(t *testing.T) {
	dir := t.TempDir()
	metaJSON := `{"tor_enabled":true,"refreshed_at":"2026-11-21T00:00:00Z","apps":[
		{"id":"foo","name":"Eligible","running":true,"has_onion":true,"has_app_proxy":true},
		{"id":"pihole","name":"Pi-hole","running":true,"has_onion":true,"has_app_proxy":false},
		{"id":"noonion","name":"No Onion","running":true,"has_onion":false,"has_app_proxy":true},
		{"id":"stopped","name":"Stopped","running":false,"has_onion":true,"has_app_proxy":true}
	]}`
	if err := os.WriteFile(filepath.Join(dir, "meta.json"), []byte(metaJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://example/", nil)
	req.RemoteAddr = "10.21.0.1:1234"
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	body := rec.Body.String()
	if !strings.Contains(body, "Eligible") {
		t.Fatal("eligible app missing")
	}
	for _, name := range []string{"Pi-hole", "No Onion", "Stopped"} {
		if strings.Contains(body, name) {
			t.Fatalf("%s should be hidden", name)
		}
	}
}

func TestHealthAllowsLoopback(t *testing.T) {
	s, err := newServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://example/healthz", nil)
	req.RemoteAddr = "127.0.0.1:1234"
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if rec.Body.String() != "ok\n" {
		t.Fatalf("body = %q", rec.Body.String())
	}
}

func TestRotateQueuesRequest(t *testing.T) {
	dir := t.TempDir()
	meta := `{"tor_enabled":true,"refreshed_at":"2026-11-21T00:00:00Z","apps":[{"id":"foo","name":"Foo","running":true,"has_onion":true,"has_app_proxy":true}]}`
	if err := os.WriteFile(filepath.Join(dir, "meta.json"), []byte(meta), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}

	get := httptest.NewRequest(http.MethodGet, "http://example/", nil)
	get.RemoteAddr = "10.21.0.1:1234"
	getRec := httptest.NewRecorder()
	s.handler().ServeHTTP(getRec, get)
	if getRec.Code != http.StatusOK {
		t.Fatalf("get status = %d", getRec.Code)
	}
	var token string
	for _, c := range getRec.Result().Cookies() {
		if c.Name == csrfCookieName {
			token = c.Value
		}
	}
	if token == "" {
		t.Fatal("missing csrf token")
	}

	form := url.Values{csrfFormField: {token}, "app_id": {"foo"}}
	post := httptest.NewRequest(http.MethodPost, "http://example/rotate", strings.NewReader(form.Encode()))
	post.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	post.RemoteAddr = "10.21.0.1:1234"
	post.AddCookie(&http.Cookie{Name: csrfCookieName, Value: token})
	postRec := httptest.NewRecorder()
	s.handler().ServeHTTP(postRec, post)
	if postRec.Code != http.StatusSeeOther {
		t.Fatalf("post status = %d, body = %s", postRec.Code, postRec.Body.String())
	}

	pending := s.readPending()
	if len(pending) != 1 {
		t.Fatalf("pending = %d, want 1", len(pending))
	}
	if pending[0].AppID != "foo" {
		t.Fatalf("app = %q", pending[0].AppID)
	}
}

func TestRotateRejectsMissingCSRF(t *testing.T) {
	s, err := newServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	post := httptest.NewRequest(http.MethodPost, "http://example/rotate", strings.NewReader("app_id=foo"))
	post.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	post.RemoteAddr = "10.21.0.1:1234"
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, post)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}

func TestCooldownActive(t *testing.T) {
	now := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	if cooldownActive("", now) {
		t.Fatal("empty cooldown should be inactive")
	}
	if !cooldownActive(now.Add(time.Minute).Format(time.RFC3339), now) {
		t.Fatal("future cooldown should be active")
	}
	if cooldownActive(now.Add(-time.Minute).Format(time.RFC3339), now) {
		t.Fatal("past cooldown should be inactive")
	}
}

func TestCancelRemovesPending(t *testing.T) {
	dir := t.TempDir()
	req := rotationRequest{
		RequestID:   "11111111111111111111111111111111",
		AppID:       "foo",
		RequestedAt: time.Now().UTC().Format(time.RFC3339),
	}
	if err := writeJSONAtomic(filepath.Join(dir, "pending"), req.RequestID+".json", req, 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	get := httptest.NewRequest(http.MethodGet, "http://example/", nil)
	get.RemoteAddr = "10.21.0.1:1234"
	getRec := httptest.NewRecorder()
	s.handler().ServeHTTP(getRec, get)
	var token string
	for _, c := range getRec.Result().Cookies() {
		if c.Name == csrfCookieName {
			token = c.Value
		}
	}
	if token == "" {
		t.Fatal("missing csrf token")
	}
	form := url.Values{csrfFormField: {token}, "request_id": {req.RequestID}}
	post := httptest.NewRequest(http.MethodPost, "http://example/cancel", strings.NewReader(form.Encode()))
	post.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	post.RemoteAddr = "10.21.0.1:1234"
	post.AddCookie(&http.Cookie{Name: csrfCookieName, Value: token})
	postRec := httptest.NewRecorder()
	s.handler().ServeHTTP(postRec, post)
	if postRec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d", postRec.Code)
	}
	if got := s.readPending(); len(got) != 0 {
		t.Fatalf("pending = %d, want 0", len(got))
	}
}

func TestReadMetaRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "meta-target.json")
	if err := os.WriteFile(target, []byte(`{"tor_enabled":true,"apps":[{"id":"foo"}]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "meta.json")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.readMeta(); got.TorEnabled || len(got.Apps) != 0 {
		t.Fatalf("readMeta followed symlink: %+v", got)
	}
}

func TestReadDashboardOnionRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "dashboard-target")
	onion := strings.Repeat("c", 56) + ".onion"
	if err := os.WriteFile(target, []byte(onion+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "dashboard-onion")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.readDashboardOnion(); got != "" {
		t.Fatalf("readDashboardOnion followed symlink: %q", got)
	}
}

func TestReadPendingRejectsSymlinkedDir(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "pending-target")
	req := rotationRequest{
		RequestID:   "22222222222222222222222222222222",
		AppID:       "foo",
		RequestedAt: time.Now().UTC().Format(time.RFC3339),
	}
	if err := writeJSONAtomic(target, req.RequestID+".json", req, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "pending")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.readPending(); len(got) != 0 {
		t.Fatalf("readPending followed symlink: %d", len(got))
	}
}

func TestReadResultsRejectsSymlinkedDir(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "results-target")
	res := rotationResult{
		RequestID:  "33333333333333333333333333333333",
		AppID:      "foo",
		Code:       "success",
		FinishedAt: time.Now().UTC().Format(time.RFC3339),
	}
	if err := writeJSONAtomic(target, res.RequestID+".json", res, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "results")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.readResults(); len(got) != 0 {
		t.Fatalf("readResults followed symlink: %d", len(got))
	}
}

func TestLockPendingDirBusy(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "pending")
	unlock, err := lockPendingDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockPendingDir(dir); !errors.Is(err, errBusy) {
		t.Fatalf("second lock error = %v, want busy", err)
	}
	unlock()
	unlock2, err := lockPendingDir(dir)
	if err != nil {
		t.Fatalf("lock after unlock: %v", err)
	}
	unlock2()
}

func TestReadProgress(t *testing.T) {
	dir := t.TempDir()
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	writeProgress(t, dir, progress{
		Active:    true,
		Phase:     "stopping",
		AppID:     "foo",
		AppName:   "Foo",
		StartedAt: now.Format(time.RFC3339),
		UpdatedAt: now.Format(time.RFC3339),
	})
	got := s.readProgress()
	if !got.Active || got.Phase != "stopping" || got.AppName != "Foo" {
		t.Fatalf("readProgress() = %+v", got)
	}

	writeProgress(t, dir, progress{
		Active:    true,
		Phase:     "waiting",
		UpdatedAt: now.Add(-time.Hour).Format(time.RFC3339),
	})
	if got := s.readProgress(); got.Active || got.Code != "" {
		t.Fatalf("stale progress accepted: %+v", got)
	}

	writeProgress(t, dir, progress{
		Active:    false,
		Phase:     "final",
		Code:      "success",
		UpdatedAt: now.Format(time.RFC3339),
	})
	got = s.readProgress()
	if got.Active || got.Code != "success" {
		t.Fatalf("final progress = %+v", got)
	}
}

func TestReadProgressRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "progress-target.json")
	if err := os.WriteFile(target, []byte(`{"active":true,"phase":"checking","updated_at":"2026-11-26T00:00:00Z"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "progress.json")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.readProgress(); got.Active || got.Code != "" {
		t.Fatalf("readProgress followed symlink: %+v", got)
	}
}

func TestIndexRedirectsToProgress(t *testing.T) {
	dir := t.TempDir()
	writeProgress(t, dir, progress{
		Active:    true,
		Phase:     "checking",
		UpdatedAt: time.Now().UTC().Format(time.RFC3339),
	})
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://example/", nil)
	req.RemoteAddr = "10.21.0.1:1234"
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	if got := rec.Header().Get("Location"); got != "/progress" {
		t.Fatalf("location = %q", got)
	}
}

func TestProgressPage(t *testing.T) {
	dir := t.TempDir()
	now := time.Now().UTC()
	writeProgress(t, dir, progress{
		Active:    true,
		Phase:     "stopping",
		AppID:     "foo",
		AppName:   "Foo",
		StartedAt: now.Format(time.RFC3339),
		UpdatedAt: now.Format(time.RFC3339),
	})
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://example/progress", nil)
	req.RemoteAddr = "10.21.0.1:1234"
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	if got := rec.Header().Get("Refresh"); got != "2" {
		t.Fatalf("refresh = %q", got)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Foo") || !strings.Contains(body, "Stopping the Tor sidecar") {
		t.Fatalf("unexpected body: %s", body)
	}

	writeProgress(t, dir, progress{
		Active:    false,
		Phase:     "final",
		AppID:     "foo",
		AppName:   "Foo",
		Code:      "success",
		UpdatedAt: now.Format(time.RFC3339),
	})
	rec = httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("final status = %d", rec.Code)
	}
	if rec.Header().Get("Refresh") != "" {
		t.Fatal("final page should not refresh")
	}
	if !strings.Contains(rec.Body.String(), "Rotated") {
		t.Fatalf("final body missing result: %s", rec.Body.String())
	}
}

func TestProgressPageMissingRedirects(t *testing.T) {
	s, err := newServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://example/progress", nil)
	req.RemoteAddr = "10.21.0.1:1234"
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/" {
		t.Fatalf("status = %d location = %q", rec.Code, rec.Header().Get("Location"))
	}
}

func TestRotateRejectsActiveProgress(t *testing.T) {
	dir := t.TempDir()
	metaJSON := `{"tor_enabled":true,"apps":[{"id":"foo","name":"Foo","running":true,"has_onion":true,"has_app_proxy":true}]}`
	if err := os.WriteFile(filepath.Join(dir, "meta.json"), []byte(metaJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	writeProgress(t, dir, progress{
		Active:    true,
		Phase:     "waiting",
		UpdatedAt: time.Now().UTC().Format(time.RFC3339),
	})
	s, err := newServer(dir)
	if err != nil {
		t.Fatal(err)
	}
	token := "0123456789abcdef0123456789abcdef"
	form := url.Values{csrfFormField: {token}, "app_id": {"foo"}}
	post := httptest.NewRequest(http.MethodPost, "http://example/rotate", strings.NewReader(form.Encode()))
	post.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	post.RemoteAddr = "10.21.0.1:1234"
	post.AddCookie(&http.Cookie{Name: csrfCookieName, Value: token})
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, post)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d", rec.Code)
	}
	if got := rec.Header().Get("Location"); got != "/?error=busy" {
		t.Fatalf("location = %q", got)
	}
	if got := s.readPending(); len(got) != 0 {
		t.Fatalf("pending = %d, want 0", len(got))
	}
}

func TestFontHandler(t *testing.T) {
	s, err := newServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://example/static/fonts/source-sans-pro-400.woff2", nil)
	req.RemoteAddr = "10.21.0.1:1234"
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "font/woff2" {
		t.Fatalf("content-type = %q", got)
	}
	if !strings.HasPrefix(rec.Body.String(), "wOF2") {
		t.Fatal("body is not a woff2 file")
	}
	if csp := rec.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "font-src 'self'") {
		t.Fatalf("csp = %q", csp)
	}

	req = httptest.NewRequest(http.MethodGet, "http://example/static/fonts/unknown.woff2", nil)
	req.RemoteAddr = "10.21.0.1:1234"
	rec = httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unknown font status = %d", rec.Code)
	}
}

func writeProgress(t *testing.T, dir string, p progress) {
	t.Helper()
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "progress.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestWriteJSONAtomicRejectsSymlinkedDir(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "pending-target")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "pending")
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	req := rotationRequest{
		RequestID:   "44444444444444444444444444444444",
		AppID:       "foo",
		RequestedAt: time.Now().UTC().Format(time.RFC3339),
	}
	if err := writeJSONAtomic(link, req.RequestID+".json", req, 0o600); err == nil {
		t.Fatal("writeJSONAtomic accepted a symlinked directory")
	}
	if _, err := os.Stat(filepath.Join(target, req.RequestID+".json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("symlink target was written: %v", err)
	}
}
