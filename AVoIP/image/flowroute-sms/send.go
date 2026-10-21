package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const flowrouteSendURL = "https://api.flowroute.com/v2.2/messages"

func validTwilioMediaURL(value string) bool {
	parsed, err := url.Parse(value)
	if err != nil || len(value) > 2048 || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil || parsed.Fragment != "" {
		return false
	}
	host := strings.ToLower(strings.TrimSuffix(parsed.Hostname(), "."))
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".internal") || strings.HasSuffix(host, ".cluster.local") {
		return false
	}
	if ip := net.ParseIP(host); ip != nil && (ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified()) {
		return false
	}
	return true
}

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
		From     string   `json:"from"`
		To       string   `json:"to"`
		Body     string   `json:"body"`
		Provider string   `json:"provider_id"`
		MediaIDs []string `json:"media_ids"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 32768)).Decode(&input); err != nil {
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
	if (strings.TrimSpace(input.Body) == "" && len(input.MediaIDs) == 0) || len(input.Body) > 1600 || len(input.MediaIDs) > 10 || from == to {
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
	if len(input.MediaIDs) > 0 && provider.Type != "twilio" {
		http.Error(w, "MMS media is currently supported for Twilio providers", 422)
		return
	}
	mediaURLs := make([]string, 0, len(input.MediaIDs))
	for _, mediaID := range input.MediaIDs {
		mediaURL, mediaErr := s.mediaURL(r.Context(), mediaID, identity)
		if mediaErr != nil {
			http.Error(w, "attachment unavailable", http.StatusBadRequest)
			return
		}
		mediaURLs = append(mediaURLs, mediaURL)
	}
	id, err := s.transmit(r.Context(), provider, from, to, input.Body, mediaURLs)
	if err != nil {
		s.logger.Warn("SMS send failed", "actor", identity, "provider_id", provider.ID)
		http.Error(w, err.Error(), 502)
		return
	}
	_, err = s.pool.Exec(r.Context(), `INSERT INTO public.flowroute_inbound_messages (message_id,sender,recipient,body,direction,is_mms,received_at,provider_id) VALUES ($1,$2,$3,$4,'outbound',$5,$6,$7) ON CONFLICT (message_id) DO NOTHING`, id, from, to, input.Body, len(mediaURLs) > 0, time.Now().UTC(), provider.ID)
	if err != nil {
		s.logger.Error("sent SMS could not be stored", "message_id", id, "user", identity, "from", from)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		json.NewEncoder(w).Encode(map[string]any{"id": id, "stored": false})
		return
	}
	if len(input.MediaIDs) > 0 {
		if _, err = s.pool.Exec(r.Context(), `UPDATE public.sms_outbound_media SET message_id=$1 WHERE owner=$2 AND id=ANY($3)`, id, identity, input.MediaIDs); err != nil {
			s.logger.Warn("sent SMS attachment association failed", "message_id", id, "user", identity)
		}
	}
	s.logger.Info("message sent", "message_id", id, "user", identity, "from", from, "to", to, "is_mms", len(mediaURLs) > 0, "media_count", len(mediaURLs))
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]any{"id": id, "stored": true})
}
