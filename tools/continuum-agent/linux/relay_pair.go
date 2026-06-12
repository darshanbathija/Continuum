package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type relayPairing struct {
	RelayURL                     string `json:"relayUrl"`
	SID                          string `json:"sid"`
	MacToken                     string `json:"macToken"`
	IosToken                     string `json:"iosToken"`
	DerivedSymmetricKeyBase64URL string `json:"derivedSymmetricKeyBase64URL,omitempty"`
	OurPublicKeyBase64URL        string `json:"ourPublicKeyBase64URL,omitempty"`
}

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
		relayURL = "wss://relay.clawdmeter.com"
	}
	macTok, err := randomToken()
	if err != nil {
		return err
	}
	iosTok, err := randomToken()
	if err != nil {
		return err
	}
	sid := randomUUID()
	pairing := relayPairing{
		RelayURL:  relayURL,
		SID:       sid,
		MacToken:  macTok,
		IosToken:  iosTok,
	}
	if err := saveRelayPairing(cfg.dataDir, pairing); err != nil {
		return err
	}

	out := map[string]string{
		"relayUrl":    relayURL,
		"sid":         sid,
		"iosToken":    iosTok,
		"macToken":    macTok,
		"displayName": cfg.displayName,
		"hostId":      cfg.hostID,
		"bearerToken": cfg.token,
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
