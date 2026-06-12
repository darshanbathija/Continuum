package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"golang.org/x/net/websocket"
)

// startRelayClient dials the relay as the mac peer and proxies mux requests
// to the local continuum-agent HTTP server (R1 VPS relay path).
func startRelayClient(cfg config, pairing *relayPairing, localAddr string) {
	localBase := "http://" + strings.TrimPrefix(localAddr, "0.0.0.0:")
	if strings.HasPrefix(localAddr, "127.0.0.1") {
		localBase = "http://" + localAddr
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

	for {
		var msg string
		if err := websocket.Message.Receive(ws, &msg); err != nil {
			return err
		}
		if err := handleRelayInbound(ws, msg, localBase, cfg.token); err != nil {
			log.Printf("relay frame: %v", err)
		}
	}
}

func relayMacConnectURL(pairing *relayPairing) (string, error) {
	base := strings.TrimRight(pairing.RelayURL, "/")
	if !strings.HasPrefix(base, "ws") {
		return "", fmt.Errorf("invalid relay url")
	}
	return fmt.Sprintf("%s/v1/relay/sessions/%s/connect?token=%s&side=mac",
		base, url.PathEscape(pairing.SID), url.QueryEscape(pairing.MacToken)), nil
}

type relayPlaintext struct {
	Seq  int             `json:"seq"`
	Op   string          `json:"op"`
	Data json.RawMessage `json:"data"`
}

type muxFrame struct {
	OpID    string          `json:"opId"`
	Kind    string          `json:"kind"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

type muxRequest struct {
	Method string          `json:"method"`
	Path   string          `json:"path"`
	Body   json.RawMessage `json:"body,omitempty"`
}

type muxResponse struct {
	Status int             `json:"status"`
	Body   json.RawMessage `json:"body,omitempty"`
}

func handleRelayInbound(ws *websocket.Conn, msg string, localBase, bearer string) error {
	var frame relayPlaintext
	if err := json.Unmarshal([]byte(msg), &frame); err != nil {
		return err
	}
	if frame.Op != "mux" {
		return nil
	}
	var mux muxFrame
	if err := json.Unmarshal(frame.Data, &mux); err != nil {
		return err
	}
	if mux.Kind != "request" || mux.OpID == "" {
		return nil
	}
	var req muxRequest
	if err := json.Unmarshal(mux.Payload, &req); err != nil {
		return err
	}
	status, body, err := proxyLocalHTTP(localBase, req.Method, req.Path, req.Body, bearer)
	if err != nil {
		status = 502
		body = []byte(err.Error())
	}
	respPayload, _ := json.Marshal(muxResponse{Status: status, Body: body})
	outFrame := muxFrame{OpID: mux.OpID, Kind: "response", Payload: respPayload}
	outData, _ := json.Marshal(outFrame)
	out := relayPlaintext{Seq: frame.Seq, Op: "mux", Data: outData}
	raw, _ := json.Marshal(out)
	return websocket.Message.Send(ws, string(raw))
}

func proxyLocalHTTP(localBase, method, path string, body json.RawMessage, bearer string) (int, []byte, error) {
	target := localBase + path
	var reader io.Reader
	if len(body) > 0 && string(body) != "null" {
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
