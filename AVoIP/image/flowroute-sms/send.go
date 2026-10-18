package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const flowrouteSendURL = "https://api.flowroute.com/v2.2/messages"

func authorizedNumber(number string, allowed []string) bool {
	canonical, ok := normalizePhoneNumber(number)
	if !ok {
		return false
	}
	for _, value := range allowed {
		if value == canonical {
			return true
		}
	}
	return false
}

func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	parsed, err := url.Parse(origin)
	return err == nil && origin != "" && parsed.Scheme == "https" && strings.EqualFold(parsed.Host, r.Host)
}

func (s *server) sendMessage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !sameOrigin(r) {
		http.Error(w, "invalid origin", http.StatusForbidden)
		return
	}
	if s.sendKey == "" || s.sendSecret == "" {
		http.Error(w, "sending unavailable", http.StatusServiceUnavailable)
		return
	}
	var input struct {
		From string `json:"from"`
		To   string `json:"to"`
		Body string `json:"body"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&input); err != nil {
		http.Error(w, "invalid request", 400)
		return
	}
	from, fromOK := normalizePhoneNumber(input.From)
	to, toOK := normalizePhoneNumber(input.To)
	if !fromOK || !toOK || !authorizedNumber(from, s.allowedNumbers(r)) {
		http.Error(w, "number unavailable", 403)
		return
	}
	if strings.TrimSpace(input.Body) == "" || len(input.Body) > 1600 || from == to {
		http.Error(w, "invalid message", 400)
		return
	}
	identity := r.Header.Get("X-Authentik-Username")
	if identity == "" {
		http.Error(w, "identity unavailable", 403)
		return
	}
	s.sendMu.Lock()
	if time.Since(s.lastSend[identity]) < time.Second {
		s.sendMu.Unlock()
		http.Error(w, "wait before sending again", 429)
		return
	}
	s.lastSend[identity] = time.Now()
	s.sendMu.Unlock()
	payload, _ := json.Marshal(map[string]any{"data": map[string]any{"type": "message", "attributes": map[string]string{"from": from, "to": to, "body": input.Body}}})
	req, err := http.NewRequestWithContext(r.Context(), "POST", flowrouteSendURL, bytes.NewReader(payload))
	if err != nil {
		http.Error(w, "send unavailable", 502)
		return
	}
	req.SetBasicAuth(s.sendKey, s.sendSecret)
	req.Header.Set("Content-Type", "application/vnd.api+json")
	req.Header.Set("Accept", "application/vnd.api+json")
	resp, err := s.sendClient.Do(req)
	if err != nil {
		s.logger.Warn("SMS send failed", "user", identity, "from", from, "reason", "provider_connection")
		http.Error(w, "send failed", 502)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		s.logger.Warn("SMS send rejected", "user", identity, "from", from, "status", resp.StatusCode)
		http.Error(w, "provider rejected message", 502)
		return
	}
	var result struct {
		Data struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&result); err != nil || result.Data.ID == "" {
		http.Error(w, "provider response invalid", 502)
		return
	}
	_, err = s.pool.Exec(r.Context(), `INSERT INTO public.flowroute_inbound_messages (message_id,sender,recipient,body,direction,is_mms,received_at) VALUES ($1,$2,$3,$4,'outbound',false,$5) ON CONFLICT (message_id) DO NOTHING`, result.Data.ID, from, to, input.Body, time.Now().UTC())
	if err != nil {
		s.logger.Error("sent SMS could not be stored", "message_id", result.Data.ID, "user", identity, "from", from)
		http.Error(w, "sent but history unavailable", 502)
		return
	}
	s.logger.Info("SMS sent", "message_id", result.Data.ID, "user", identity, "from", from, "to", to)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"id": result.Data.ID})
}
