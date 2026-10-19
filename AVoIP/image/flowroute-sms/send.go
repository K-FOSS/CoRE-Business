package main

import (
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
	var input struct {
		From     string `json:"from"`
		To       string `json:"to"`
		Body     string `json:"body"`
		Provider string `json:"provider_id"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&input); err != nil {
		http.Error(w, "invalid request", 400)
		return
	}
	from, fromOK := normalizePhoneNumber(input.From)
	to, toOK := normalizePhoneNumber(input.To)
	numbers, accessErr := s.visibleNumbers(r)
	if accessErr != nil {
		http.Error(w, "numbers unavailable", 503)
		return
	}
	if !fromOK || !toOK || !authorizedNumber(from, numbers) {
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
	providers, err := s.providers(r.Context())
	if err != nil {
		http.Error(w, "providers unavailable", 503)
		return
	}
	provider, err := chooseProvider(providers, from, input.Provider)
	if err != nil {
		http.Error(w, err.Error(), 422)
		return
	}
	id, err := s.transmit(r.Context(), provider, from, to, input.Body)
	if err != nil {
		s.logger.Warn("SMS send failed", "actor", identity, "provider_id", provider.ID)
		http.Error(w, err.Error(), 502)
		return
	}
	_, err = s.pool.Exec(r.Context(), `INSERT INTO public.flowroute_inbound_messages (message_id,sender,recipient,body,direction,is_mms,received_at,provider_id) VALUES ($1,$2,$3,$4,'outbound',false,$5,$6) ON CONFLICT (message_id) DO NOTHING`, id, from, to, input.Body, time.Now().UTC(), provider.ID)
	if err != nil {
		s.logger.Error("sent SMS could not be stored", "message_id", id, "user", identity, "from", from)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		json.NewEncoder(w).Encode(map[string]any{"id": id, "stored": false})
		return
	}
	s.logger.Info("SMS sent", "message_id", id, "user", identity, "from", from, "to", to)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]any{"id": id, "stored": true})
}
