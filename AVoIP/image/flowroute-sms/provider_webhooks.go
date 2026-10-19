package main

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"time"
)

type providerWebhookStatusWriter struct {
	http.ResponseWriter
	status int
}

func (w *providerWebhookStatusWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *providerWebhookStatusWriter) Write(body []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(body)
}

func safeWebhookProviderID(value string) string {
	if providerID.MatchString(value) {
		return value
	}
	return "unknown"
}

func validTwilioSignature(p smsProvider, r *http.Request, body []byte) bool {
	_, token := p.credentials()
	if token == "" || p.WebhookURL == "" || r.URL.RawQuery != "" {
		return false
	}
	values, err := urlValues(body)
	if err != nil {
		return false
	}
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	signed := p.WebhookURL
	for _, k := range keys {
		seen := map[string]bool{}
		sort.Strings(values[k])
		for _, v := range values[k] {
			if !seen[v] {
				signed += k + v
				seen[v] = true
			}
		}
	}
	mac := hmac.New(sha1.New, []byte(token))
	mac.Write([]byte(signed))
	supplied, err := base64.StdEncoding.DecodeString(r.Header.Get("X-Twilio-Signature"))
	return err == nil && hmac.Equal(supplied, mac.Sum(nil))
}
func validTelnyxSignature(p smsProvider, r *http.Request, body []byte) bool {
	publicKey, err := base64.StdEncoding.DecodeString(os.Getenv(p.PublicKeyEnv))
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		return false
	}
	timestamp := r.Header.Get("Telnyx-Timestamp")
	seconds, err := strconv.ParseInt(timestamp, 10, 64)
	if err != nil || time.Since(time.Unix(seconds, 0)) > 5*time.Minute || time.Until(time.Unix(seconds, 0)) > 5*time.Minute {
		return false
	}
	signature, err := base64.StdEncoding.DecodeString(r.Header.Get("Telnyx-Signature-Ed25519"))
	return err == nil && ed25519.Verify(publicKey, append([]byte(timestamp+"|"), body...), signature)
}
func (s *server) receiveProvider(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	response := &providerWebhookStatusWriter{ResponseWriter: w}
	providerKey := safeWebhookProviderID(r.PathValue("id"))
	providerType := "unknown"
	stage := "provider_configuration"
	outcome := "rejected"
	defer func() {
		status := response.status
		if status == 0 {
			status = http.StatusOK
		}
		if s.logger != nil {
			level := slog.LevelInfo
			if status >= http.StatusBadRequest {
				level = slog.LevelWarn
			}
			s.logger.Log(r.Context(), level, "provider webhook completed",
				"provider_id", providerKey,
				"provider_type", providerType,
				"outcome", outcome,
				"stage", stage,
				"response_status", status,
				"duration_ms", time.Since(started).Milliseconds(),
			)
		}
	}()
	w = response
	providers, err := s.providers(r.Context())
	if err != nil {
		stage = "provider_configuration"
		http.Error(w, "unavailable", 503)
		return
	}
	var p smsProvider
	for _, candidate := range providers {
		if candidate.ID == r.PathValue("id") {
			p = candidate
		}
	}
	if p.ID != "" {
		providerKey = p.ID
		providerType = p.Type
	}
	if !p.CanReceive || p.Type == "flowroute" {
		stage = "provider_not_receivable"
		http.NotFound(w, r)
		return
	}
	stage = "read_payload"
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRequestBytes))
	if err != nil {
		http.Error(w, "invalid request", 413)
		return
	}
	contentType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	var id, from, to, text string
	var isMMS bool
	occurred := time.Now().UTC()
	if p.Type == "twilio" {
		stage = "twilio_signature"
		if contentType != "application/x-www-form-urlencoded" || !validTwilioSignature(p, r, body) {
			http.Error(w, "invalid signature", 403)
			return
		}
		stage = "twilio_account"
		values, err := urlValues(body)
		if err != nil {
			http.Error(w, "invalid request", 400)
			return
		}
		key, _ := p.credentials()
		if values.Get("AccountSid") != key {
			http.Error(w, "invalid account", 403)
			return
		}
		id = values.Get("MessageSid")
		from = values.Get("From")
		to = values.Get("To")
		text = values.Get("Body")
		isMMS = values.Get("NumMedia") != "" && values.Get("NumMedia") != "0"
	} else {
		stage = "telnyx_signature"
		if contentType != "application/json" || !validTelnyxSignature(p, r, body) {
			http.Error(w, "invalid signature", 403)
			return
		}
		var event struct {
			Data struct {
				EventType  string    `json:"event_type"`
				OccurredAt time.Time `json:"occurred_at"`
				Payload    struct {
					ID   string `json:"id"`
					Type string `json:"type"`
					Text string `json:"text"`
					From struct {
						Number string `json:"phone_number"`
					} `json:"from"`
					To []struct {
						Number string `json:"phone_number"`
					} `json:"to"`
					Media []json.RawMessage `json:"media"`
				} `json:"payload"`
			} `json:"data"`
		}
		stage = "parse_payload"
		if json.Unmarshal(body, &event) != nil {
			http.Error(w, "invalid event", 400)
			return
		}
		if event.Data.EventType != "message.received" {
			stage = "ignore_event"
			outcome = "ignored"
			w.WriteHeader(200)
			return
		}
		if len(event.Data.Payload.To) != 1 {
			stage = "validate_recipients"
			http.Error(w, "invalid recipients", 422)
			return
		}
		id = event.Data.Payload.ID
		from = event.Data.Payload.From.Number
		to = event.Data.Payload.To[0].Number
		text = event.Data.Payload.Text
		isMMS = event.Data.Payload.Type == "MMS" || len(event.Data.Payload.Media) > 0
		if !event.Data.OccurredAt.IsZero() {
			occurred = event.Data.OccurredAt
		}
	}
	// Additional adapters explicitly support SMS; never acknowledge and discard MMS.
	if isMMS {
		stage = "unsupported_mms"
		http.Error(w, "MMS is not supported for this provider", 415)
		return
	}
	var ok bool
	stage = "normalize_numbers"
	from, ok = normalizePhoneNumber(from)
	if !ok {
		http.Error(w, "invalid sender", 422)
		return
	}
	to, ok = normalizePhoneNumber(to)
	if !ok || !authorizedNumber(to, p.Numbers) || id == "" || len(id) > 140 || len(text) > 65536 {
		stage = "validate_message"
		http.Error(w, "invalid message or destination", 422)
		return
	}
	id = p.ID + ":" + id
	stage = "database_begin"
	tx, err := s.pool.Begin(r.Context())
	if err != nil {
		http.Error(w, "unavailable", 503)
		return
	}
	defer tx.Rollback(r.Context())
	_, err = tx.Exec(r.Context(), `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, id)
	if err == nil {
		stage = "database_insert"
		_, err = tx.Exec(r.Context(), `INSERT INTO public.flowroute_inbound_messages(message_id,sender,recipient,body,direction,is_mms,received_at,provider_id) SELECT $1,$2,$3,$4,'inbound',false,$5,$6 WHERE NOT EXISTS(SELECT 1 FROM public.sms_deleted_messages WHERE message_id=$1) ON CONFLICT DO NOTHING`, id, from, to, text, occurred, p.ID)
	}
	if err == nil {
		stage = "database_commit"
		err = tx.Commit(r.Context())
	}
	if err != nil {
		http.Error(w, "unavailable", 503)
		return
	}
	if p.Type == "twilio" {
		stage = "acknowledge"
		outcome = "accepted"
		w.Header().Set("Content-Type", "text/xml")
		io.WriteString(w, "<Response/>")
	} else {
		stage = "acknowledge"
		outcome = "accepted"
		w.WriteHeader(200)
	}
}

func urlValues(body []byte) (url.Values, error) { return url.ParseQuery(string(body)) }
