package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAuthorize(t *testing.T) {
	t.Parallel()
	req := httptest.NewRequest(http.MethodGet, "/sessions", nil)
	if authorize(req, "secret") {
		t.Fatal("expected unauthorized without header")
	}
	req.Header.Set("Authorization", "Bearer secret")
	if !authorize(req, "secret") {
		t.Fatal("expected authorized with matching bearer token")
	}
	req.Header.Set("Authorization", "Bearer wrong")
	if authorize(req, "secret") {
		t.Fatal("expected unauthorized with wrong token")
	}
}

func TestSelfHostVPS(t *testing.T) {
	t.Parallel()
	host := selfHost(config{
		hostID:      "abc-123",
		displayName: "VPS Test",
		kind:        "vps",
	})
	if host.ID != "abc-123" || host.Kind != "vps" {
		t.Fatalf("unexpected host: %+v", host)
	}
	if host.CloudProvider != nil {
		t.Fatal("vps host should not have cloud provider")
	}
	if !host.RelayAlsoEnabled || host.DaemonWireVersion != defaultWireVersion {
		t.Fatalf("unexpected defaults: %+v", host)
	}
}

func TestSelfHostByocAWS(t *testing.T) {
	prevRegion := os.Getenv("AWS_REGION")
	prevInstance := os.Getenv("EC2_INSTANCE_ID")
	t.Cleanup(func() {
		_ = os.Setenv("AWS_REGION", prevRegion)
		_ = os.Setenv("EC2_INSTANCE_ID", prevInstance)
	})
	_ = os.Setenv("AWS_REGION", "us-east-1")
	_ = os.Setenv("EC2_INSTANCE_ID", "i-deadbeef")
	host := selfHost(config{
		hostID:      "host-1",
		displayName: "AWS Runner",
		kind:        "byocAWS",
	})
	if host.CloudProvider == nil || *host.CloudProvider != "aws" {
		t.Fatalf("expected aws provider, got %+v", host.CloudProvider)
	}
	if host.CloudRegion == nil || *host.CloudRegion != "us-east-1" {
		t.Fatalf("expected region us-east-1, got %+v", host.CloudRegion)
	}
	if host.CloudResourceID == nil || *host.CloudResourceID != "i-deadbeef" {
		t.Fatalf("expected instance id, got %+v", host.CloudResourceID)
	}
}

func TestLoadConfigGeneratesTokenAndHostID(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLAWDMETER_DATA_DIR", dir)
	t.Setenv("HOST_DISPLAY_NAME", "Test Host")
	t.Setenv("CLAWDMETER_HOST_KIND", "vps")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.displayName != "Test Host" || cfg.kind != "vps" {
		t.Fatalf("unexpected config: %+v", cfg)
	}
	if cfg.token == "" {
		t.Fatal("expected generated token")
	}
	if cfg.hostID == "" {
		t.Fatal("expected generated host id")
	}

	tokenPath := filepath.Join(dir, "agent-token")
	raw, err := os.ReadFile(tokenPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(raw)) != cfg.token {
		t.Fatal("token file mismatch")
	}

	cfg2, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg2.token != cfg.token || cfg2.hostID != cfg.hostID {
		t.Fatal("expected stable token and host id on reload")
	}
}

func TestPostSessionsCreatesAgentSession(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLAWDMETER_DATA_DIR", dir)
	t.Setenv("HOST_DISPLAY_NAME", "VPS Test")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	store, err := newSessionStore(dir)
	if err != nil {
		t.Fatal(err)
	}

	body := []byte(`{"repoKey":"/tmp/test-repo","agent":"claude","planMode":false,"useWorktree":true}`)
	req := httptest.NewRequest(http.MethodPost, "/sessions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+cfg.token)
	rec := httptest.NewRecorder()
	handlePostSessions(rec, req, cfg, store, cfg.token)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"status":"running"`) {
		t.Fatalf("expected running session: %s", rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"executionHostId"`) {
		t.Fatalf("expected executionHostId: %s", rec.Body.String())
	}

	getReq := httptest.NewRequest(http.MethodGet, "/sessions", nil)
	getReq.Header.Set("Authorization", "Bearer "+cfg.token)
	getRec := httptest.NewRecorder()
	handleGetSessions(getRec, getReq, store, cfg.token)
	if getRec.Code != http.StatusOK {
		t.Fatalf("get status %d", getRec.Code)
	}
	if !strings.Contains(getRec.Body.String(), `"agent":"claude"`) {
		t.Fatalf("expected session in list: %s", getRec.Body.String())
	}
}

func TestHealthEndpoint(t *testing.T) {
	t.Parallel()
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"ok": true, "wireVersion": defaultWireVersion})
	})
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"wireVersion":30`) {
		t.Fatalf("unexpected body: %s", rec.Body.String())
	}
}
