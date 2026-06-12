package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/net/websocket"
)

// startRelayClient dials the relay as the mac peer and proxies mux requests
// to the local continuum-agent HTTP server (R1 VPS relay path).
func startRelayClient(cfg config, pairing *relayPairing, localAddr string) {
	localBase := "http://" + localAddr
	if strings.HasPrefix(localAddr, "0.0.0.0:") {
		localBase = "http://127.0.0.1:" + strings.TrimPrefix(localAddr, "0.0.0.0:")
	}
	for {
		if err := relayClientOnce(cfg, pairing, localBase); err != nil {
			log.Printf("relay client: %v (retry in 5s)", err)
		}
		time.Sleep(5 * time.Second)
	}
}

func relayClientOnce(cfg config, pairing *relayPairing, localBase string) error {
	connectURL, err := relayMacConnectURL(pairing)
	if err != nil {
		return err
	}
	u, err := url.Parse(connectURL)
	if err != nil {
		return err
	}
	wsURL := "ws://" + u.Host + u.Path + "?" + u.RawQuery
	if strings.HasPrefix(pairing.RelayURL, "wss://") {
		wsURL = "wss://" + u.Host + u.Path + "?" + u.RawQuery
	}
	ws, err := websocket.Dial(wsURL, "", "http://localhost/")
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer ws.Close()
	log.Printf("relay connected sid=%s", pairing.SID)

	key, err := relaySymmetricKey(pairing)
	if err != nil {
		return err
	}
	state := relayCryptoState{key: key, outboundSeq: 1}
	for {
		if err := handleRelayInbound(ws, localBase, cfg.token, &state); err != nil {
			log.Printf("relay frame: %v", err)
		}
	}
}

func relayMacConnectURL(pairing *relayPairing) (string, error) {
	base := strings.TrimRight(pairing.RelayURL, "/")
	parsed, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	if parsed.Scheme != "ws" && parsed.Scheme != "wss" {
		return "", fmt.Errorf("invalid relay url scheme %q", parsed.Scheme)
	}
	if parsed.Host == "" {
		return "", fmt.Errorf("invalid relay url host")
	}
	query := url.Values{}
	query.Set("token", pairing.MacToken)
	query.Set("side", "mac")
	if bundle := pairing.authBundleParam(); bundle != "" {
		query.Set("bundle", bundle)
	}
	return fmt.Sprintf("%s/v1/relay/sessions/%s/connect?%s",
		base, url.PathEscape(pairing.SID), query.Encode()), nil
}

type relayPlaintext struct {
	Seq  uint64          `json:"seq"`
	Op   string          `json:"op"`
	Data json.RawMessage `json:"data"`
}

type relayEnvelopeHeader struct {
	V    int    `json:"v"`
	From string `json:"from"`
	Type string `json:"type"`
}

type muxFrame struct {
	OpID    string  `json:"opId"`
	Kind    string  `json:"kind"`
	Payload *string `json:"payload,omitempty"`
}

type muxRequest struct {
	Method string  `json:"method"`
	Path   string  `json:"path"`
	Body   *string `json:"body,omitempty"`
}

type muxResponse struct {
	Status int     `json:"status"`
	Body   *string `json:"body,omitempty"`
}

type relayCryptoState struct {
	key         []byte
	inboundSeq  uint64
	outboundSeq uint64
}

func handleRelayInbound(ws *websocket.Conn, localBase, bearer string, state *relayCryptoState) error {
	var headerText string
	if err := websocket.Message.Receive(ws, &headerText); err != nil {
		return err
	}
	var header relayEnvelopeHeader
	if err := json.Unmarshal([]byte(headerText), &header); err != nil {
		return err
	}
	if header.V != 1 {
		return fmt.Errorf("unsupported relay frame version %d", header.V)
	}
	if header.Type == "control" {
		return nil
	}
	if header.Type != "ciphertext" {
		return fmt.Errorf("unsupported relay frame type %q", header.Type)
	}
	var body []byte
	if err := websocket.Message.Receive(ws, &body); err != nil {
		return err
	}
	plaintext, err := openRelayBody(body, state.key)
	if err != nil {
		return err
	}
	var frame relayPlaintext
	if err := json.Unmarshal(plaintext, &frame); err != nil {
		return err
	}
	if frame.Op != "mux" {
		return nil
	}
	if frame.Seq <= state.inboundSeq {
		return nil
	}
	state.inboundSeq = frame.Seq
	var mux muxFrame
	if err := json.Unmarshal(frame.Data, &mux); err != nil {
		return err
	}
	if mux.Kind != "request" || mux.OpID == "" {
		return nil
	}
	if mux.Payload == nil {
		return fmt.Errorf("mux request missing payload")
	}
	payload, err := base64.StdEncoding.DecodeString(*mux.Payload)
	if err != nil {
		return fmt.Errorf("mux request payload base64: %w", err)
	}
	var req muxRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		return err
	}
	reqBody, err := requestBody(req.Body)
	if err != nil {
		statusPayload, _ := responsePayload(400, []byte(err.Error()))
		return sendMuxResponse(ws, mux.OpID, statusPayload, state)
	}
	status, responseBody, err := proxyLocalHTTP(localBase, req.Method, req.Path, reqBody, bearer)
	if err != nil {
		status = 502
		responseBody = []byte(err.Error())
	}
	respPayload, _ := responsePayload(status, responseBody)
	return sendMuxResponse(ws, mux.OpID, respPayload, state)
}

func requestBody(encoded *string) ([]byte, error) {
	if encoded == nil || *encoded == "" {
		return nil, nil
	}
	body, err := base64.StdEncoding.DecodeString(*encoded)
	if err != nil {
		return nil, fmt.Errorf("request body base64: %w", err)
	}
	return body, nil
}

func responsePayload(status int, body []byte) ([]byte, error) {
	var encoded *string
	if len(body) > 0 {
		value := base64.StdEncoding.EncodeToString(body)
		encoded = &value
	}
	return json.Marshal(muxResponse{Status: status, Body: encoded})
}

func sendMuxResponse(ws *websocket.Conn, opID string, payload []byte, state *relayCryptoState) error {
	payloadB64 := base64.StdEncoding.EncodeToString(payload)
	outFrame := muxFrame{OpID: opID, Kind: "response", Payload: &payloadB64}
	outData, _ := json.Marshal(outFrame)
	out := relayPlaintext{Seq: state.outboundSeq, Op: "mux", Data: outData}
	state.outboundSeq++
	raw, _ := json.Marshal(out)
	sealed, err := sealRelayPlaintext(raw, state.key)
	if err != nil {
		return err
	}
	header := relayEnvelopeHeader{V: 1, From: "mac", Type: "ciphertext"}
	headerData, _ := json.Marshal(header)
	if err := websocket.Message.Send(ws, string(headerData)); err != nil {
		return err
	}
	return websocket.Message.Send(ws, sealed)
}

func proxyLocalHTTP(localBase, method, path string, body []byte, bearer string) (int, []byte, error) {
	target := localBase + path
	var reader io.Reader
	if len(body) > 0 {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, target, reader)
	if err != nil {
		return 0, nil, err
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	if reader != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	client := &http.Client{Timeout: 45 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	return resp.StatusCode, data, err
}

func relaySymmetricKey(pairing *relayPairing) ([]byte, error) {
	raw := strings.TrimSpace(pairing.DerivedSymmetricKeyBase64URL)
	if raw == "" {
		return nil, fmt.Errorf("relay pairing missing derivedSymmetricKeyBase64URL; rerun pair-relay")
	}
	key, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, err
	}
	if len(key) != chacha20poly1305.KeySize {
		return nil, fmt.Errorf("relay symmetric key must be %d bytes, got %d", chacha20poly1305.KeySize, len(key))
	}
	return key, nil
}

func openRelayBody(body, key []byte) ([]byte, error) {
	if len(body) <= chacha20poly1305.NonceSizeX {
		return nil, fmt.Errorf("ciphertext body too small")
	}
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	nonce := body[:chacha20poly1305.NonceSizeX]
	sealed := body[chacha20poly1305.NonceSizeX:]
	return aead.Open(nil, nonce, sealed, []byte("clawdmeter.relay.frame.v1"))
}

func sealRelayPlaintext(plaintext, key []byte) ([]byte, error) {
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, chacha20poly1305.NonceSizeX)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	sealed := aead.Seal(nil, nonce, plaintext, []byte("clawdmeter.relay.frame.v1"))
	out := make([]byte, 0, len(nonce)+len(sealed))
	out = append(out, nonce...)
	out = append(out, sealed...)
	return out, nil
}

func (p relayPairing) authBundleParam() string {
	if p.CreationProof == nil || p.MacTokenHash == "" || p.IosTokenHash == "" || p.TTLSeconds == 0 {
		return ""
	}
	bundle := map[string]any{
		"creation": map[string]any{
			"issuedAtSeconds": p.CreationProof.IssuedAtSeconds,
			"nonce":           p.CreationProof.Nonce,
			"signature":       p.CreationProof.Signature,
		},
		"iosTokenHash": p.IosTokenHash,
		"macTokenHash": p.MacTokenHash,
		"ttlSeconds":   p.TTLSeconds,
	}
	data, err := json.Marshal(bundle)
	if err != nil {
		return ""
	}
	return base64.StdEncoding.EncodeToString(data)
}
