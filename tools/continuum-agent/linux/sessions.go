package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type agentSession struct {
	ID                 string  `json:"id"`
	RepoKey            *string `json:"repoKey"`
	RepoDisplayName    string  `json:"repoDisplayName"`
	Agent              string  `json:"agent"`
	Model              *string `json:"model,omitempty"`
	Goal               *string `json:"goal,omitempty"`
	WorktreePath       *string `json:"worktreePath,omitempty"`
	TmuxWindowID       *string `json:"tmuxWindowId,omitempty"`
	TmuxPaneID         *string `json:"tmuxPaneId,omitempty"`
	Status             string  `json:"status"`
	PlanText           *string `json:"planText,omitempty"`
	CreatedAt          string  `json:"createdAt"`
	LastEventAt        string  `json:"lastEventAt"`
	LastEventSeq       uint64  `json:"lastEventSeq"`
	Mode               string  `json:"mode"`
	ParentSessionID    *string `json:"parentSessionId,omitempty"`
	Kind               string  `json:"kind"`
	DeepResearch       bool    `json:"deepResearch"`
	TerminalPanes      []any   `json:"terminalPanes"`
	ScheduledFollowUps []any   `json:"scheduledFollowUps"`
	OwnsWorktree       bool    `json:"ownsWorktree"`
	ExecutionHostID    *string `json:"executionHostId,omitempty"`
	ExecutionHostLabel *string `json:"executionHostLabel,omitempty"`
	PID                *int    `json:"pid,omitempty"`
	LogPath            *string `json:"logPath,omitempty"`
}

type newSessionRequest struct {
	RepoKey         string  `json:"repoKey"`
	Agent           string  `json:"agent"`
	Model           *string `json:"model"`
	PlanMode        bool    `json:"planMode"`
	Goal            *string `json:"goal"`
	UseWorktree     bool    `json:"useWorktree"`
	TargetHostID    *string `json:"targetHostId"`
	ParentSessionID *string `json:"parentSessionId"`
	SessionID       *string `json:"sessionId"`
	SourceRemoteURL *string `json:"sourceRemoteURL"`
	SourceBranch    *string `json:"sourceBranch"`
	SourceCommit    *string `json:"sourceCommit"`
}

type sessionStore struct {
	mu       sync.RWMutex
	path     string
	sessions map[string]agentSession
	seq      uint64
}

func newSessionStore(dataDir string) (*sessionStore, error) {
	path := filepath.Join(dataDir, "sessions.json")
	store := &sessionStore{
		path:     path,
		sessions: map[string]agentSession{},
	}
	if raw, err := os.ReadFile(path); err == nil {
		var list []agentSession
		if json.Unmarshal(raw, &list) == nil {
			for _, s := range list {
				store.sessions[s.ID] = s
			}
		}
	}
	return store, nil
}

func (s *sessionStore) persist() error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	list := make([]agentSession, 0, len(s.sessions))
	for _, session := range s.sessions {
		list = append(list, session)
	}
	raw, err := json.Marshal(list)
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, raw, 0o600)
}

func (s *sessionStore) list() []agentSession {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]agentSession, 0, len(s.sessions))
	for _, session := range s.sessions {
		out = append(out, session)
	}
	return out
}

func (s *sessionStore) add(session agentSession) error {
	s.mu.Lock()
	s.sessions[session.ID] = session
	s.mu.Unlock()
	return s.persist()
}

func (s *sessionStore) get(id string) (agentSession, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	session, ok := s.sessions[id]
	return session, ok
}

func (s *sessionStore) update(session agentSession) error {
	s.mu.Lock()
	s.sessions[session.ID] = session
	s.mu.Unlock()
	return s.persist()
}

func isoNow() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
}

func repoDisplayName(repoKey string) string {
	base := filepath.Base(strings.TrimSuffix(repoKey, string(filepath.Separator)))
	if base == "" || base == "." {
		return repoKey
	}
	return base
}

func handleGetSessions(w http.ResponseWriter, r *http.Request, store *sessionStore, token string) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !authorize(r, token) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	writeJSON(w, store.list())
}

func handlePostSessions(w http.ResponseWriter, r *http.Request, cfg config, store *sessionStore, token string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !authorize(r, token) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	// Cap request bodies at 1 MiB so a hostile/runaway client can't OOM the daemon.
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	var req newSessionRequest
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	repoKey := strings.TrimSpace(req.RepoKey)
	if repoKey == "" {
		http.Error(w, "repoKey required", http.StatusBadRequest)
		return
	}
	agent := strings.TrimSpace(req.Agent)
	if agent == "" {
		agent = "claude"
	}

	sessionID := randomUUID()
	if req.SessionID != nil && strings.TrimSpace(*req.SessionID) != "" {
		sessionID = strings.TrimSpace(*req.SessionID)
	}

	workDir, err := prepareWorkspace(cfg.dataDir, workspaceSpec{
		RepoKey:         repoKey,
		SourceRemoteURL: stringValue(req.SourceRemoteURL),
		SourceBranch:    stringValue(req.SourceBranch),
		SourceCommit:    stringValue(req.SourceCommit),
		UseWorktree:     req.UseWorktree,
		IsHandoff:       req.ParentSessionID != nil,
	})
	if err != nil {
		http.Error(w, fmt.Sprintf("workspace: %v", err), http.StatusInternalServerError)
		return
	}

	status := "running"
	if req.PlanMode {
		status = "planning"
	}
	now := isoNow()
	hostID := cfg.hostID
	hostLabel := cfg.displayName
	mode := "local"
	var worktreePath *string
	if req.UseWorktree {
		mode = "worktree"
		worktreePath = &workDir
	}

	start, err := startAgentProcess(
		workDir,
		agent,
		stringValue(req.Model),
		req.PlanMode,
		stringValue(req.Goal),
		sessionID,
	)
	if err != nil {
		http.Error(w, fmt.Sprintf("spawn: %v", err), http.StatusInternalServerError)
		return
	}
	var pidPtr *int
	if start.PID > 0 {
		pid := start.PID
		pidPtr = &pid
	}
	var logPathPtr *string
	if start.LogPath != "" {
		logPath := start.LogPath
		logPathPtr = &logPath
	}
	tmuxName := "continuum-" + sessionID[:8]
	if start.TmuxName != "" {
		tmuxName = start.TmuxName
	}

	store.mu.Lock()
	store.seq++
	seq := store.seq
	store.mu.Unlock()

	session := agentSession{
		ID:                 sessionID,
		RepoKey:            &repoKey,
		RepoDisplayName:    repoDisplayName(repoKey),
		Agent:              agent,
		Model:              req.Model,
		Goal:               req.Goal,
		WorktreePath:       worktreePath,
		TmuxWindowID:       strPtr(tmuxName),
		TmuxPaneID:         strPtr(tmuxName),
		Status:             status,
		CreatedAt:          now,
		LastEventAt:        now,
		LastEventSeq:       seq,
		Mode:               mode,
		ParentSessionID:    req.ParentSessionID,
		Kind:               "code",
		TerminalPanes:      []any{},
		ScheduledFollowUps: []any{},
		ExecutionHostID:    &hostID,
		ExecutionHostLabel: &hostLabel,
		PID:                pidPtr,
		LogPath:            logPathPtr,
	}
	if err := store.add(session); err != nil {
		http.Error(w, "persist failed", http.StatusInternalServerError)
		return
	}
	writeJSON(w, session)
}

func handleSessionByID(w http.ResponseWriter, r *http.Request, store *sessionStore, token string) {
	if !authorize(r, token) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	id := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/sessions/"))
	if id == "" {
		http.Error(w, "session id required", http.StatusBadRequest)
		return
	}
	switch r.Method {
	case http.MethodDelete:
		handleDeleteSession(w, id, store)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func handleDeleteSession(w http.ResponseWriter, id string, store *sessionStore) {
	session, ok := store.get(id)
	if !ok {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err := stopAgentProcess(session); err != nil {
		http.Error(w, fmt.Sprintf("stop: %v", err), http.StatusInternalServerError)
		return
	}
	now := isoNow()
	session.Status = "done"
	session.LastEventAt = now
	store.mu.Lock()
	store.seq++
	session.LastEventSeq = store.seq
	store.mu.Unlock()
	if err := store.update(session); err != nil {
		http.Error(w, "persist failed", http.StatusInternalServerError)
		return
	}
	writeJSON(w, session)
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return strings.TrimSpace(*value)
}

func strPtr(s string) *string { return &s }
