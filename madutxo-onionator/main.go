package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"html/template"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	appID            = "madutxo-onionator"
	maxPending       = 5
	maxBodyBytes     = 64 << 10
	maxProgressBytes = 4096
	progressMaxAge   = 10 * time.Minute
	csrfCookieName   = "madutxo_onionator_csrf"
	csrfFormField    = "csrf"
	csrfMaxAge       = 3600
)

var (
	appIDPattern     = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`)
	requestIDPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)
	onionPattern     = regexp.MustCompile(`^[a-z2-7]{56}\.onion$`)
	errBusy          = errors.New("busy")
)

//go:embed web/index.html web/progress.html web/app.css web/fonts/*
var webFS embed.FS

type meta struct {
	TorEnabled  bool      `json:"tor_enabled"`
	RefreshedAt string    `json:"refreshed_at"`
	Apps        []appInfo `json:"apps"`
}

type appInfo struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Running       bool   `json:"running"`
	HasOnion      bool   `json:"has_onion"`
	HasAppProxy   bool   `json:"has_app_proxy"`
	LastRotatedAt string `json:"last_rotated_at,omitempty"`
	CooldownUntil string `json:"cooldown_until,omitempty"`
}

type rotationRequest struct {
	RequestID   string `json:"request_id"`
	AppID       string `json:"app_id"`
	RequestedAt string `json:"requested_at"`
}

type rotationResult struct {
	RequestID  string `json:"request_id"`
	AppID      string `json:"app_id"`
	Code       string `json:"code"`
	StartedAt  string `json:"started_at"`
	FinishedAt string `json:"finished_at"`
}

type progress struct {
	Active    bool   `json:"active"`
	Phase     string `json:"phase"`
	AppID     string `json:"app_id,omitempty"`
	AppName   string `json:"app_name,omitempty"`
	Code      string `json:"code,omitempty"`
	StartedAt string `json:"started_at,omitempty"`
	UpdatedAt string `json:"updated_at,omitempty"`
	Message   string `json:"message,omitempty"`
}

type appView struct {
	ID            string
	Name          string
	Running       bool
	HasOnion      bool
	HasAppProxy   bool
	LastRotatedAt string
	CooldownUntil string
	Cooldown      bool
	Disabled      bool
}

type pendingView struct {
	RequestID   string
	AppID       string
	AppName     string
	RequestedAt string
}

type resultView struct {
	AppID      string
	AppName    string
	Code       string
	CodeText   string
	FinishedAt string
}

type progressView struct {
	Active    bool
	Phase     string
	PhaseText string
	AppID     string
	AppName   string
	Code      string
	CodeText  string
	StartedAt string
	UpdatedAt string
	Message   string
	Success   bool
}

type pageData struct {
	CSRF           string
	TorEnabled     bool
	RefreshedAt    string
	DashboardOnion string
	Apps           []appView
	Pending        []pendingView
	Results        []resultView
	Notice         string
	Error          string
	MaxPending     int
}

type server struct {
	dataDir   string
	templates *template.Template
	now       func() time.Time
}

func newServer(dataDir string) (*server, error) {
	tmpl, err := template.New("index").Funcs(template.FuncMap{
		"codeText":    codeText,
		"displayTime": displayTime,
		"phaseText":   phaseText,
	}).ParseFS(webFS, "web/index.html", "web/progress.html")
	if err != nil {
		return nil, err
	}
	return &server{
		dataDir:   dataDir,
		templates: tmpl,
		now:       time.Now,
	}, nil
}

func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/progress", s.handleProgress)
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/static/app.css", s.handleCSS)
	mux.HandleFunc("/static/fonts/", s.handleFont)
	mux.HandleFunc("/rotate", s.handleRotate)
	mux.HandleFunc("/cancel", s.handleCancel)
	return s.securityHeaders(s.sourceIP(mux))
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if p := s.readProgress(); p.Active {
		http.Redirect(w, r, "/progress", http.StatusSeeOther)
		return
	}
	csrf := s.ensureCSRF(w, r)
	if csrf == "" {
		return
	}

	m := s.readMeta()
	now := s.now().UTC()
	names := make(map[string]string, len(m.Apps))
	apps := make([]appView, 0, len(m.Apps))
	for _, a := range m.Apps {
		names[a.ID] = a.Name
		if !a.Running || !a.HasOnion || !a.HasAppProxy {
			continue
		}
		cooldown := cooldownActive(a.CooldownUntil, now)
		apps = append(apps, appView{
			ID:            a.ID,
			Name:          a.Name,
			Running:       a.Running,
			HasOnion:      a.HasOnion,
			HasAppProxy:   a.HasAppProxy,
			LastRotatedAt: a.LastRotatedAt,
			CooldownUntil: a.CooldownUntil,
			Cooldown:      cooldown,
			Disabled:      !m.TorEnabled || !a.Running || !a.HasOnion || !a.HasAppProxy || cooldown,
		})
	}
	sort.Slice(apps, func(i, j int) bool {
		return strings.ToLower(apps[i].Name) < strings.ToLower(apps[j].Name)
	})

	pending := s.readPending()
	pendingViews := make([]pendingView, 0, len(pending))
	for _, p := range pending {
		name := names[p.AppID]
		if name == "" {
			name = p.AppID
		}
		pendingViews = append(pendingViews, pendingView{
			RequestID:   p.RequestID,
			AppID:       p.AppID,
			AppName:     name,
			RequestedAt: p.RequestedAt,
		})
	}

	results := s.readResults()
	resultViews := make([]resultView, 0, len(results))
	for _, res := range results {
		name := names[res.AppID]
		if name == "" {
			name = res.AppID
		}
		resultViews = append(resultViews, resultView{
			AppID:      res.AppID,
			AppName:    name,
			Code:       res.Code,
			CodeText:   codeText(res.Code),
			FinishedAt: res.FinishedAt,
		})
	}

	data := pageData{
		CSRF:           csrf,
		TorEnabled:     m.TorEnabled,
		RefreshedAt:    m.RefreshedAt,
		DashboardOnion: s.readDashboardOnion(),
		Apps:           apps,
		Pending:        pendingViews,
		Results:        resultViews,
		MaxPending:     maxPending,
	}

	q := r.URL.Query()
	switch q.Get("queued") {
	case "1":
		data.Notice = "Rotation requests queued. Restart Onionator from Umbrel to apply them; this page will show progress while it runs."
	}
	switch q.Get("canceled") {
	case "1":
		data.Notice = "Pending request canceled."
	}
	switch q.Get("error") {
	case "limit":
		data.Error = "You can queue at most 5 apps at a time."
	case "select":
		data.Error = "Select at least one app."
	case "invalid":
		data.Error = "The selection was invalid."
	case "cooldown":
		data.Error = "One of the selected apps is in its 10-minute cooldown."
	case "busy":
		data.Error = "A rotation is already running. Wait for it to finish before queueing more."
	case "unavailable":
		data.Error = "One of the selected apps is not running, has no onion, or is not supported."
	case "tor_disabled":
		data.Error = "Remote Tor access is disabled. Enable it in Umbrel Settings, then restart this app."
	default:
		if q.Get("error") != "" {
			data.Error = "Request failed."
		}
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.templates.ExecuteTemplate(w, "index.html", data); err != nil {
		slog.Error("render index", "error", err)
	}
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || r.URL.Path != "/healthz" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = io.WriteString(w, "ok\n")
}

func (s *server) handleProgress(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || r.URL.Path != "/progress" {
		http.NotFound(w, r)
		return
	}
	p := s.readProgress()
	if !p.Active && p.Code == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	view := progressView{
		Active:    p.Active,
		Phase:     p.Phase,
		PhaseText: phaseText(p.Phase),
		AppID:     p.AppID,
		AppName:   p.AppName,
		Code:      p.Code,
		CodeText:  codeText(p.Code),
		StartedAt: p.StartedAt,
		UpdatedAt: p.UpdatedAt,
		Message:   p.Message,
		Success:   p.Code == "success",
	}
	if view.AppName == "" {
		view.AppName = view.AppID
	}
	if p.Active {
		w.Header().Set("Refresh", "2")
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.templates.ExecuteTemplate(w, "progress.html", view); err != nil {
		slog.Error("render progress", "error", err)
	}
}

func (s *server) handleCSS(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || r.URL.Path != "/static/app.css" {
		http.NotFound(w, r)
		return
	}
	css, err := webFS.ReadFile("web/app.css")
	if err != nil {
		http.Error(w, "Not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "text/css; charset=utf-8")
	_, _ = w.Write(css)
}

func (s *server) handleFont(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/static/fonts/")
	switch name {
	case "source-sans-pro-400.woff2", "source-sans-pro-600.woff2":
	default:
		http.NotFound(w, r)
		return
	}
	data, err := webFS.ReadFile("web/fonts/" + name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "font/woff2")
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	_, _ = w.Write(data)
}

func (s *server) handleRotate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.URL.Path != "/rotate" {
		http.NotFound(w, r)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if !s.checkCSRF(w, r) {
		return
	}

	m := s.readMeta()
	if !m.TorEnabled {
		redirectError(w, r, "tor_disabled")
		return
	}

	unlock, err := lockPendingDir(s.pendingDir())
	if err != nil {
		if errors.Is(err, errBusy) {
			redirectError(w, r, "busy")
			return
		}
		slog.Error("lock pending queue", "error", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	defer unlock()

	if p := s.readProgress(); p.Active {
		redirectError(w, r, "busy")
		return
	}

	pending := s.readPending()
	if len(pending) >= maxPending {
		redirectError(w, r, "limit")
		return
	}

	selected := make([]string, 0, len(r.PostForm["app_id"]))
	seen := make(map[string]bool)
	for _, id := range r.PostForm["app_id"] {
		if !appIDPattern.MatchString(id) || id == appID {
			redirectError(w, r, "invalid")
			return
		}
		if seen[id] {
			continue
		}
		seen[id] = true
		selected = append(selected, id)
	}
	if len(selected) == 0 {
		redirectError(w, r, "select")
		return
	}
	if len(pending)+len(selected) > maxPending {
		redirectError(w, r, "limit")
		return
	}

	byID := make(map[string]appInfo, len(m.Apps))
	for _, a := range m.Apps {
		byID[a.ID] = a
	}
	now := s.now().UTC()
	for _, id := range selected {
		a, ok := byID[id]
		if !ok || !a.Running || !a.HasOnion || !a.HasAppProxy {
			redirectError(w, r, "unavailable")
			return
		}
		if cooldownActive(a.CooldownUntil, now) {
			redirectError(w, r, "cooldown")
			return
		}
	}

	for _, id := range selected {
		requestID, err := randomToken()
		if err != nil {
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}
		req := rotationRequest{
			RequestID:   requestID,
			AppID:       id,
			RequestedAt: now.Format(time.RFC3339),
		}
		if err := writeJSONAtomic(s.pendingDir(), requestID+".json", req, 0o600); err != nil {
			slog.Error("queue rotation request", "app", id, "error", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}
	}

	http.Redirect(w, r, "/?queued=1", http.StatusSeeOther)
}

func (s *server) handleCancel(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.URL.Path != "/cancel" {
		http.NotFound(w, r)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if !s.checkCSRF(w, r) {
		return
	}
	requestID := r.PostForm.Get("request_id")
	if !requestIDPattern.MatchString(requestID) {
		redirectError(w, r, "invalid")
		return
	}
	unlock, err := lockPendingDir(s.pendingDir())
	if err != nil {
		if errors.Is(err, errBusy) {
			redirectError(w, r, "busy")
			return
		}
		slog.Error("lock pending queue", "error", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	defer unlock()
	if err := os.Remove(filepath.Join(s.pendingDir(), requestID+".json")); err != nil && !errors.Is(err, os.ErrNotExist) {
		slog.Error("cancel rotation request", "error", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/?canceled=1", http.StatusSeeOther)
}

func (s *server) ensureCSRF(w http.ResponseWriter, r *http.Request) string {
	if c, err := r.Cookie(csrfCookieName); err == nil && requestIDPattern.MatchString(c.Value) {
		return c.Value
	}
	token, err := randomToken()
	if err != nil {
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return ""
	}
	http.SetCookie(w, &http.Cookie{
		Name:     csrfCookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   isHTTPS(r),
		SameSite: http.SameSiteStrictMode,
		MaxAge:   csrfMaxAge,
	})
	return token
}

func (s *server) checkCSRF(w http.ResponseWriter, r *http.Request) bool {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return false
	}
	cookie, err := r.Cookie(csrfCookieName)
	if err != nil || !requestIDPattern.MatchString(cookie.Value) {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return false
	}
	form := r.PostForm.Get(csrfFormField)
	if len(form) != len(cookie.Value) || subtle.ConstantTimeCompare([]byte(form), []byte(cookie.Value)) != 1 {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return false
	}
	return true
}

func (s *server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; font-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func (s *server) sourceIP(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !allowedIP(remoteIP(r)) {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *server) readMeta() meta {
	path := filepath.Join(s.dataDir, "meta.json")
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return meta{}
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return meta{}
	}
	var m meta
	if err := json.Unmarshal(b, &m); err != nil {
		return meta{}
	}
	return m
}

func (s *server) readDashboardOnion() string {
	path := filepath.Join(s.dataDir, "dashboard-onion")
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	value := strings.TrimSpace(string(b))
	if !onionPattern.MatchString(value) {
		return ""
	}
	return value
}

func (s *server) readPending() []rotationRequest {
	dir := s.pendingDir()
	fi, err := os.Lstat(dir)
	if err != nil || !fi.IsDir() || fi.Mode()&os.ModeSymlink != 0 {
		return nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	requests := make([]rotationRequest, 0, len(entries))
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".json")
		if !requestIDPattern.MatchString(id) {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			continue
		}
		var req rotationRequest
		if err := json.Unmarshal(b, &req); err != nil {
			continue
		}
		if req.RequestID != id || !appIDPattern.MatchString(req.AppID) || req.AppID == appID {
			continue
		}
		requests = append(requests, req)
	}
	sort.Slice(requests, func(i, j int) bool {
		if requests[i].RequestedAt == requests[j].RequestedAt {
			return requests[i].RequestID < requests[j].RequestID
		}
		return requests[i].RequestedAt < requests[j].RequestedAt
	})
	return requests
}

func (s *server) readResults() []rotationResult {
	dir := filepath.Join(s.dataDir, "results")
	fi, err := os.Lstat(dir)
	if err != nil || !fi.IsDir() || fi.Mode()&os.ModeSymlink != 0 {
		return nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	results := make([]rotationResult, 0, len(entries))
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".json")
		if !requestIDPattern.MatchString(id) {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			continue
		}
		var res rotationResult
		if err := json.Unmarshal(b, &res); err != nil {
			continue
		}
		if res.RequestID != id || !appIDPattern.MatchString(res.AppID) || res.Code == "" {
			continue
		}
		results = append(results, res)
	}
	sort.Slice(results, func(i, j int) bool {
		return results[i].FinishedAt > results[j].FinishedAt
	})
	if len(results) > 20 {
		results = results[:20]
	}
	return results
}

func (s *server) readProgress() progress {
	path := filepath.Join(s.dataDir, "progress.json")
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > maxProgressBytes {
		return progress{}
	}
	b, err := os.ReadFile(path)
	if err != nil || len(b) > maxProgressBytes {
		return progress{}
	}
	var p progress
	if err := json.Unmarshal(b, &p); err != nil {
		return progress{}
	}
	if p.AppID != "" && (!appIDPattern.MatchString(p.AppID) || p.AppID == appID) {
		return progress{}
	}
	switch p.Phase {
	case "checking", "stopping", "moving", "starting", "waiting", "final":
	default:
		return progress{}
	}
	if p.Active {
		if p.UpdatedAt == "" {
			return progress{}
		}
		updated, err := time.Parse(time.RFC3339, p.UpdatedAt)
		if err != nil || time.Since(updated) > progressMaxAge {
			return progress{}
		}
		return p
	}
	if p.Code == "" {
		return progress{}
	}
	return p
}

func (s *server) pendingDir() string {
	return filepath.Join(s.dataDir, "pending")
}

func lockPendingDir(path string) (func(), error) {
	if fi, err := os.Lstat(path); err == nil {
		if !fi.IsDir() || fi.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("unsafe pending directory")
		}
	} else if errors.Is(err, os.ErrNotExist) {
		if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return nil, err
		}
		fi, err := os.Lstat(path)
		if err != nil || !fi.IsDir() || fi.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("unsafe pending directory")
		}
	} else {
		return nil, err
	}

	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = syscall.Close(fd)
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, errBusy
		}
		return nil, err
	}
	return func() {
		_ = syscall.Flock(fd, syscall.LOCK_UN)
		_ = syscall.Close(fd)
	}, nil
}

func writeJSONAtomic(dir, name string, value any, perm os.FileMode) error {
	if fi, err := os.Lstat(dir); err == nil {
		if !fi.IsDir() || fi.Mode()&os.ModeSymlink != 0 {
			return errors.New("unsafe data directory")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmp)
		}
	}()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err := enc.Encode(value); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp, perm); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(dir, name)); err != nil {
		return err
	}
	cleanup = false
	return nil
}

func randomToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func cooldownActive(until string, now time.Time) bool {
	if until == "" {
		return false
	}
	t, err := time.Parse(time.RFC3339, until)
	if err != nil {
		return false
	}
	return now.Before(t)
}

func remoteIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return strings.Trim(r.RemoteAddr, "[]")
}

func allowedIP(value string) bool {
	ip := net.ParseIP(value)
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || ip.Equal(net.ParseIP("10.21.0.1"))
}

func isHTTPS(r *http.Request) bool {
	return r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

func redirectError(w http.ResponseWriter, r *http.Request, code string) {
	http.Redirect(w, r, "/?error="+code, http.StatusSeeOther)
}

func displayTime(value string) string {
	if value == "" {
		return ""
	}
	t, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return value
	}
	return t.UTC().Format("2006-01-02 15:04 UTC")
}

func phaseText(phase string) string {
	switch phase {
	case "checking":
		return "Checking queued requests"
	case "stopping":
		return "Stopping the Tor sidecar"
	case "moving":
		return "Moving the onion data"
	case "starting":
		return "Starting the Tor sidecar"
	case "waiting":
		return "Waiting for the new onion address"
	case "final":
		return "Finished"
	default:
		return "Working"
	}
}

func codeText(code string) string {
	switch code {
	case "success":
		return "Rotated"
	case "tor_disabled":
		return "Remote Tor access is disabled"
	case "unknown_app":
		return "App not found"
	case "self_not_allowed":
		return "This app cannot rotate itself"
	case "not_running":
		return "App is not running"
	case "no_app_proxy":
		return "App has no Umbrel app proxy"
	case "no_onion":
		return "App has no onion address"
	case "no_tor_server":
		return "App has no Tor sidecar"
	case "docker_unavailable":
		return "Docker is unavailable"
	case "cooldown":
		return "Cooldown is active"
	case "busy":
		return "Another rotation is in progress"
	case "failed_stop":
		return "Could not stop the Tor sidecar"
	case "failed_start":
		return "Could not start the Tor sidecar"
	case "failed_move":
		return "Could not move the onion data"
	case "no_new_hostname":
		return "No new onion address appeared"
	case "rollback_ok":
		return "Rotation failed; old address restored"
	case "rollback_failed":
		return "Rotation failed; manual recovery needed"
	case "expired":
		return "Request expired"
	case "invalid_request":
		return "Invalid request"
	case "recovered":
		return "Recovered after an interrupted rotation"
	default:
		return "Unknown result"
	}
}

func healthcheck() int {
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:3068/healthz")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

func main() {
	addr := flag.String("addr", "0.0.0.0:3068", "listen address")
	dataDir := flag.String("data", "/data", "data directory")
	check := flag.Bool("healthcheck", false, "check the local health endpoint and exit")
	flag.Parse()

	if *check {
		os.Exit(healthcheck())
	}

	s, err := newServer(*dataDir)
	if err != nil {
		slog.Error("load templates", "error", err)
		os.Exit(1)
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           s.handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	slog.Info("listening", "addr", *addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("serve", "error", err)
		os.Exit(1)
	}
}
