// continuum-agent — headless Clawdmeter execution-host daemon for Linux (R1 1B-b).
//
// Exposes the minimal AgentControl wire v30 surface the Mac hub probes on remote
// hosts: /health, /execution-hosts/self, and /sessions (empty until full agent
// runtimes ship on Linux).
package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	defaultPort        = 21731
	defaultWireVersion = 30
	agentVersion       = "0.1.0-linux"
)

type executionHost struct {
	ID                  string   `json:"id"`
	DisplayName         string   `json:"displayName"`
	Kind                string   `json:"kind"`
	PrimaryTransport    string   `json:"primaryTransport"`
	PreferredTransports []string `json:"preferredTransports"`
	Health              string   `json:"health"`
	RelayAlsoEnabled    bool     `json:"relayAlsoEnabled"`
	CloudProvider       *string  `json:"cloudProvider,omitempty"`
	CloudResourceID     *string  `json:"cloudResourceId,omitempty"`
	CloudRegion         *string  `json:"cloudRegion,omitempty"`
	OpencodeAvailable   bool     `json:"opencodeAvailable"`
	DaemonWireVersion   int      `json:"daemonWireVersion"`
}

type config struct {
	dataDir     string
	port        int
	hostID      string
	displayName string
	kind        string
	token       string
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("continuum-agent: ")

	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "serve":
		if err := runServe(); err != nil {
			log.Fatal(err)
		}
	case "pair":
		if err := runPair(); err != nil {
			log.Fatal(err)
		}
	case "show-token":
		if err := runShowToken(); err != nil {
			log.Fatal(err)
		}
	case "health":
		if err := runHealth(); err != nil {
			os.Exit(1)
		}
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, "usage: continuum-agent {serve|pair|show-token|health}\n")
}

func loadConfig() (config, error) {
	dataDir := os.Getenv("CLAWDMETER_DATA_DIR")
	if dataDir == "" {
		dataDir = filepath.Join(os.Getenv("HOME"), ".clawdmeter")
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return config{}, err
	}

	port := defaultPort
	if raw := strings.TrimSpace(os.Getenv("CLAWDMETER_HTTP_PORT")); raw != "" {
		var parsed int
		if _, err := fmt.Sscanf(raw, "%d", &parsed); err == nil && parsed > 0 {
			port = parsed
		}
	}

	hostID := strings.TrimSpace(os.Getenv("EXECUTION_HOST_ID"))
	displayName := strings.TrimSpace(os.Getenv("HOST_DISPLAY_NAME"))
	kind := strings.TrimSpace(os.Getenv("CLAWDMETER_HOST_KIND"))
	if kind == "" {
		kind = "vps"
	}
	if hostID == "" {
		hostID = readEnvFile("/etc/clawdmeter/env", "EXECUTION_HOST_ID")
	}
	if displayName == "" {
		displayName = readEnvFile("/etc/clawdmeter/env", "HOST_DISPLAY_NAME")
	}
	if displayName == "" {
		hostname, _ := os.Hostname()
		displayName = hostname
	}
	if hostID == "" {
		hostID = stableHostID(dataDir)
	}

	tokenPath := filepath.Join(dataDir, "agent-token")
	tokenBytes, err := os.ReadFile(tokenPath)
	if err != nil {
		token, genErr := generateToken()
		if genErr != nil {
			return config{}, genErr
		}
		if writeErr := os.WriteFile(tokenPath, []byte(token), 0o600); writeErr != nil {
			return config{}, writeErr
		}
		tokenBytes = []byte(token)
	}

	return config{
		dataDir:     dataDir,
		port:        port,
		hostID:      hostID,
		displayName: displayName,
		kind:        kind,
		token:       strings.TrimSpace(string(tokenBytes)),
	}, nil
}

func readEnvFile(path, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	prefix := key + "="
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return ""
}

func stableHostID(dataDir string) string {
	path := filepath.Join(dataDir, "host-id")
	if raw, err := os.ReadFile(path); err == nil {
		id := strings.TrimSpace(string(raw))
		if id != "" {
			return id
		}
	}
	id := randomUUID()
	_ = os.WriteFile(path, []byte(id), 0o644)
	return id
}

func randomUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func generateToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func runServe() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		writeJSON(w, map[string]any{
			"ok":            true,
			"serverVersion": agentVersion,
			"wireVersion":   defaultWireVersion,
		})
	})
	mux.HandleFunc("/execution-hosts/self", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !authorize(r, cfg.token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		writeJSON(w, selfHost(cfg))
	})
	mux.HandleFunc("/sessions", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !authorize(r, cfg.token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		writeJSON(w, []any{})
	})

	addr := fmt.Sprintf("127.0.0.1:%d", cfg.port)
	if strings.EqualFold(os.Getenv("CLAWDMETER_BIND_ALL"), "1") {
		addr = fmt.Sprintf("0.0.0.0:%d", cfg.port)
	}

	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("listening on %s (host=%s kind=%s wire=%d)", addr, cfg.hostID, cfg.kind, defaultWireVersion)
	return server.ListenAndServe()
}

func runPair() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	host := strings.TrimSpace(os.Getenv("CLAWDMETER_PAIR_HOST"))
	if host == "" {
		host, _ = os.Hostname()
	}
	port := cfg.port
	fmt.Printf("clawdmeter://%s:%d?token=%s\n\n", host, port, cfg.token)
	fmt.Println("Pair this host from Clawdmeter → Settings → Devices → Add execution host.")
	fmt.Println("Use the relay pairing flow on Mac; direct tailnet URLs require Tailscale on this box.")
	return nil
}

func runShowToken() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	fmt.Println(cfg.token)
	return nil
}

func runHealth() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	url := fmt.Sprintf("http://127.0.0.1:%d/health", cfg.port)
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("health check failed: %s", strings.TrimSpace(string(body)))
	}
	fmt.Println(string(body))
	return nil
}

func selfHost(cfg config) executionHost {
	host := executionHost{
		ID:                  cfg.hostID,
		DisplayName:         cfg.displayName,
		Kind:                cfg.kind,
		PrimaryTransport:    "relay",
		PreferredTransports: []string{"relay", "tailscaleDirect"},
		Health:              "healthy",
		RelayAlsoEnabled:    true,
		OpencodeAvailable:   false,
		DaemonWireVersion:   defaultWireVersion,
	}
	if cfg.kind == "byocAWS" {
		provider := "aws"
		host.CloudProvider = &provider
		if region := strings.TrimSpace(os.Getenv("AWS_REGION")); region != "" {
			host.CloudRegion = &region
		}
		if instanceID := strings.TrimSpace(os.Getenv("EC2_INSTANCE_ID")); instanceID != "" {
			host.CloudResourceID = &instanceID
		}
	}
	return host
}

func authorize(r *http.Request, token string) bool {
	if token == "" {
		return true
	}
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		return false
	}
	return strings.TrimPrefix(header, "Bearer ") == token
}

func writeJSON(w http.ResponseWriter, payload any) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(payload)
}

// Allow `go run . serve` with flags during local dev.
func init() {
	_ = flag.CommandLine
}
