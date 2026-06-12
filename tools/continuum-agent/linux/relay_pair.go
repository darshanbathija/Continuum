package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type relayPairing struct {
	RelayURL                     string                `json:"relayUrl"`
	SID                          string                `json:"sid"`
	MacToken                     string                `json:"macToken"`
	IosToken                     string                `json:"iosToken"`
	MacTokenHash                 string                `json:"macTokenHash"`
	IosTokenHash                 string                `json:"iosTokenHash"`
	TTLSeconds                   uint64                `json:"ttlSeconds"`
	CreationProof                *sessionCreationProof `json:"creationProof,omitempty"`
	DerivedSymmetricKeyBase64URL string                `json:"derivedSymmetricKeyBase64URL,omitempty"`
	OurPublicKeyBase64URL        string                `json:"ourPublicKeyBase64URL,omitempty"`
}

type sessionCreationProof struct {
	IssuedAtSeconds uint64 `json:"issuedAtSeconds"`
	Nonce           string `json:"nonce"`
	Signature       string `json:"signature"`
}

type creationGrantResponse struct {
	Creation       sessionCreationProof `json:"creation"`
	APNSSigningKey *string              `json:"apnsSigningKey,omitempty"`
}

const defaultRelayURL = "wss://clawdmeter-relay.continuumai.workers.dev"

func relayPairingPath(dataDir string) string {
	return filepath.Join(dataDir, "relay-pairing.json")
}

func loadRelayPairing(dataDir string) (*relayPairing, error) {
	raw, err := os.ReadFile(relayPairingPath(dataDir))
	if err != nil {
		return nil, err
	}
	var p relayPairing
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, err
	}
	return &p, nil
}

func saveRelayPairing(dataDir string, p relayPairing) error {
	raw, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(relayPairingPath(dataDir), raw, 0o600)
}

func randomToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func randomKey() (string, error) {
	return randomToken()
}

func sha256Hex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func runPairRelay() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	relayURL := strings.TrimSpace(os.Getenv("CLAWDMETER_RELAY_URL"))
	if relayURL == "" {
		relayURL = defaultRelayURL
	}
	macTok, err := randomToken()
	if err != nil {
		return err
	}
	iosTok, err := randomToken()
	if err != nil {
		return err
	}
	symKey, err := randomKey()
	if err != nil {
		return err
	}
	sid := randomUUID()
	ttl := uint64(time.Now().UTC().Add(30 * 24 * time.Hour).Unix())
	macHash := sha256Hex(macTok)
	iosHash := sha256Hex(iosTok)
	grant, err := issueCreationGrant(relayURL, sid, macHash, iosHash, ttl)
	if err != nil {
		return err
	}
	pairing := relayPairing{
		RelayURL:                     relayURL,
		SID:                          sid,
		MacToken:                     macTok,
		IosToken:                     iosTok,
		MacTokenHash:                 macHash,
		IosTokenHash:                 iosHash,
		TTLSeconds:                   ttl,
		CreationProof:                &grant.Creation,
		DerivedSymmetricKeyBase64URL: symKey,
	}
	if err := saveRelayPairing(cfg.dataDir, pairing); err != nil {
		return err
	}

	out := map[string]any{
		"relayUrl":                     relayURL,
		"sid":                          sid,
		"iosToken":                     iosTok,
		"pairingToken":                 iosTok,
		"macToken":                     macTok,
		"displayName":                  cfg.displayName,
		"hostId":                       cfg.hostID,
		"bearerToken":                  cfg.token,
		"derivedSymmetricKeyBase64URL": symKey,
		"ttlSeconds":                   ttl,
		"creationProof":                grant.Creation,
	}
	fmt.Println("=== Relay pairing bundle (paste into Mac Settings → Devices → Add VPS) ===")
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(out)
	fmt.Println()
	fmt.Printf("Mac token hash: %s\n", sha256Hex(macTok))
	fmt.Printf("iOS token hash: %s\n", sha256Hex(iosTok))
	fmt.Println("After pairing, `continuum-agent serve` dials relay as mac peer when relay-pairing.json exists.")
	return nil
}

func issueCreationGrant(relayURL, sid, macHash, iosHash string, ttl uint64) (creationGrantResponse, error) {
	token := strings.TrimSpace(os.Getenv("CLAWDMETER_RELAY_CREATION_GRANT_TOKEN"))
	if token == "" {
		return creationGrantResponse{}, fmt.Errorf("CLAWDMETER_RELAY_CREATION_GRANT_TOKEN is required for relay pairing")
	}
	grantURL, err := creationGrantURL(relayURL, sid)
	if err != nil {
		return creationGrantResponse{}, err
	}
	body, _ := json.Marshal(map[string]any{
		"macTokenHash":         macHash,
		"iosTokenHash":         iosHash,
		"ttlSeconds":           ttl,
		"senderMacFingerprint": nil,
	})
	req, err := http.NewRequest(http.MethodPost, grantURL, bytes.NewReader(body))
	if err != nil {
		return creationGrantResponse{}, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	client := http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return creationGrantResponse{}, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return creationGrantResponse{}, fmt.Errorf("creation grant failed: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	var grant creationGrantResponse
	if err := json.Unmarshal(data, &grant); err != nil {
		return creationGrantResponse{}, err
	}
	return grant, nil
}

func creationGrantURL(relayURL, sid string) (string, error) {
	u, err := url.Parse(strings.TrimRight(relayURL, "/"))
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "wss":
		u.Scheme = "https"
	case "ws":
		u.Scheme = "http"
	default:
		return "", fmt.Errorf("invalid relay url scheme %q", u.Scheme)
	}
	u.Path = "/v1/relay/sessions/" + url.PathEscape(sid) + "/creation-grant"
	u.RawQuery = ""
	return u.String(), nil
}
