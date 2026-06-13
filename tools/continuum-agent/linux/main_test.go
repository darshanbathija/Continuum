package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
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
	repoDir := filepath.Join(dir, "repo")
	if err := os.MkdirAll(repoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	fakeBin := installFakeAgent(t, dir, "claude")
	t.Setenv("PATH", fakeBin)
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

	body := []byte(`{"repoKey":"` + repoDir + `","agent":"claude","planMode":false,"useWorktree":true}`)
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
	var created agentSession
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.PID == nil || *created.PID <= 0 {
		t.Fatalf("expected pid for real process: %+v", created)
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

	deleteReq := httptest.NewRequest(http.MethodDelete, "/sessions/"+created.ID, nil)
	deleteReq.Header.Set("Authorization", "Bearer "+cfg.token)
	deleteRec := httptest.NewRecorder()
	handleSessionByID(deleteRec, deleteReq, store, cfg.token)
	if deleteRec.Code != http.StatusOK {
		t.Fatalf("delete status %d body %s", deleteRec.Code, deleteRec.Body.String())
	}
	if !strings.Contains(deleteRec.Body.String(), `"status":"done"`) {
		t.Fatalf("expected done after delete: %s", deleteRec.Body.String())
	}
}

func TestPostSessionsRejectsMissingAgentBinary(t *testing.T) {
	dir := t.TempDir()
	repoDir := filepath.Join(dir, "repo")
	if err := os.MkdirAll(repoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", t.TempDir())
	t.Setenv("CLAWDMETER_DATA_DIR", dir)
	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	store, err := newSessionStore(dir)
	if err != nil {
		t.Fatal(err)
	}

	body := []byte(`{"repoKey":"` + repoDir + `","agent":"claude","planMode":false,"useWorktree":true}`)
	req := httptest.NewRequest(http.MethodPost, "/sessions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+cfg.token)
	rec := httptest.NewRecorder()
	handlePostSessions(rec, req, cfg, store, cfg.token)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "claude binary not found") {
		t.Fatalf("expected missing binary error: %s", rec.Body.String())
	}
	if got := store.list(); len(got) != 0 {
		t.Fatalf("missing binary should not persist session: %+v", got)
	}
}

func TestPrepareWorkspaceHandoffRequiresRemoteSource(t *testing.T) {
	_, err := prepareWorkspace(t.TempDir(), workspaceSpec{
		RepoKey:   "/does/not/exist",
		IsHandoff: true,
	})
	if err == nil || !strings.Contains(err.Error(), "handoff requires sourceRemoteURL") {
		t.Fatalf("expected handoff source error, got %v", err)
	}
}

func TestAgentCommandUsesProviderNonInteractiveGoalArgs(t *testing.T) {
	dir := t.TempDir()
	binDir := installFakeAgent(t, dir, "claude")
	installFakeAgent(t, dir, "codex")
	installFakeAgent(t, dir, "opencode")
	t.Setenv("PATH", binDir)

	_, claudeArgs, err := agentCommand("claude", "sonnet", true, "fix the failing test")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(claudeArgs, " ") != "-p --model sonnet --permission-mode plan" {
		t.Fatalf("unexpected claude args: %#v", claudeArgs)
	}

	_, codexArgs, err := agentCommand("codex", "gpt-5.5", false, "fix the failing test")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(codexArgs, " ") != "exec --model gpt-5.5" {
		t.Fatalf("unexpected codex args: %#v", codexArgs)
	}

	_, opencodeArgs, err := agentCommand("opencode", "anthropic/claude-sonnet", false, "fix the failing test")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(opencodeArgs, " ") != "run --model anthropic/claude-sonnet fix the failing test" {
		t.Fatalf("unexpected opencode args: %#v", opencodeArgs)
	}
}

func TestDefaultRelayURLMatchesAppleProductionRelay(t *testing.T) {
	if defaultRelayURL != "wss://clawdmeter-relay.continuumai.workers.dev" {
		t.Fatalf("unexpected default relay url: %s", defaultRelayURL)
	}
}

func TestRelayMacConnectURLIncludesAuthBundle(t *testing.T) {
	pairing := &relayPairing{
		RelayURL:     "wss://relay.example.com",
		SID:          "sid-test-123",
		MacToken:     "mac-token",
		IosToken:     "ios-token",
		MacTokenHash: "mac-hash",
		IosTokenHash: "ios-hash",
		TTLSeconds:   123,
		CreationProof: &sessionCreationProof{
			IssuedAtSeconds: 1,
			Nonce:           "nonce",
			Signature:       "sig",
		},
	}
	raw, err := relayMacConnectURL(pairing)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(raw, "token=mac-token") {
		t.Fatalf("expected mac token in url: %s", raw)
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	bundleParam := parsed.Query().Get("bundle")
	decoded, err := base64.StdEncoding.DecodeString(bundleParam)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(decoded), `"macTokenHash":"mac-hash"`) ||
		!strings.Contains(string(decoded), `"iosTokenHash":"ios-hash"`) ||
		!strings.Contains(string(decoded), `"creation"`) {
		t.Fatalf("unexpected bundle: %s", decoded)
	}
}

func TestRelayMacConnectURLRejectsInvalidScheme(t *testing.T) {
	_, err := relayMacConnectURL(&relayPairing{
		RelayURL: "wsnot://relay.example.com",
		SID:      "sid",
		MacToken: "token",
	})
	if err == nil || !strings.Contains(err.Error(), "invalid relay url scheme") {
		t.Fatalf("expected invalid scheme error, got %v", err)
	}
}

func TestRelaySymmetricKeyRequired(t *testing.T) {
	_, err := relaySymmetricKey(&relayPairing{})
	if err == nil || !strings.Contains(err.Error(), "derivedSymmetricKeyBase64URL") {
		t.Fatalf("expected missing key error, got %v", err)
	}
}

func TestRelaySymmetricKeyRejectsWrongLength(t *testing.T) {
	short := base64.RawURLEncoding.EncodeToString([]byte("short"))
	_, err := relaySymmetricKey(&relayPairing{DerivedSymmetricKeyBase64URL: short})
	if err == nil || !strings.Contains(err.Error(), "relay symmetric key must be") {
		t.Fatalf("expected wrong key length error, got %v", err)
	}
}

func installFakeAgent(t *testing.T, dir, name string) string {
	t.Helper()
	binDir := filepath.Join(dir, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(binDir, name)
	script := "#!/bin/sh\n" +
		"echo \"$@\" > \"" + filepath.Join(dir, name+"-args") + "\"\n" +
		"/bin/sleep 60\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return binDir
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
