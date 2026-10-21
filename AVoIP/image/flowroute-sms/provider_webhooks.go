package main

import (
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
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

type twilioInboundMedia struct {
	sid         string
	contentType string
	fileName    string
	content     []byte
}

func validTwilioSID(value, prefix string) bool {
	if len(value) != 34 || !strings.HasPrefix(value, prefix) {
		return false
	}
	for _, char := range value[2:] {
		if !(char >= '0' && char <= '9' || char >= 'a' && char <= 'f' || char >= 'A' && char <= 'F') {
			return false
		}
	}
	return true
}

func twilioMediaFromWebhook(values url.Values, accountSID, messageSID string, count int) ([]twilioInboundMedia, error) {
	if count < 0 || count > 10 || count > 0 && (!validTwilioSID(accountSID, "AC") || !(validTwilioSID(messageSID, "SM") || validTwilioSID(messageSID, "MM"))) {
		return nil, errors.New("invalid Twilio media identifiers")
	}
	result := make([]twilioInboundMedia, 0, count)
	for index := 0; index < count; index++ {
		urlValues := values["MediaUrl"+strconv.Itoa(index)]
		typeValues := values["MediaContentType"+strconv.Itoa(index)]
		if len(urlValues) != 1 || len(typeValues) != 1 {
			return nil, errors.New("missing or repeated Twilio media fields")
		}
		mediaURL := urlValues[0]
		contentType, _, err := mime.ParseMediaType(typeValues[0])
		parsed, parseErr := url.Parse(mediaURL)
		if err != nil || parseErr != nil || !strings.HasPrefix(strings.ToLower(contentType), "image/") || parsed == nil ||
			!strings.EqualFold(parsed.Scheme, "https") || !strings.EqualFold(parsed.Hostname(), "api.twilio.com") ||
			parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Port() != "" && parsed.Port() != "443") {
			return nil, errors.New("invalid Twilio media URL or content type")
		}
		parts := strings.Split(strings.Trim(parsed.Path, "/"), "/")
		if len(parts) != 7 || parts[0] != "2010-04-01" || parts[1] != "Accounts" || parts[2] != accountSID || parts[3] != "Messages" || parts[4] != messageSID || parts[5] != "Media" || !validTwilioSID(parts[6], "ME") {
			return nil, errors.New("Twilio media URL does not match message")
		}
		result = append(result, twilioInboundMedia{sid: parts[6], contentType: contentType})
	}
	return result, nil
}

func (s *server) downloadTwilioMedia(ctx context.Context, accountSID, authToken, messageSID string, media *twilioInboundMedia) error {
	mediaURL := "https://api.twilio.com/2010-04-01/Accounts/" + accountSID + "/Messages/" + messageSID + "/Media/" + media.sid
	requestURL := mediaURL
	var resp *http.Response
	for redirect := 0; redirect < 4; redirect++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
		if err != nil {
			return &twilioMediaDownloadError{stage: "build_request"}
		}
		if redirect == 0 {
			req.SetBasicAuth(accountSID, authToken)
		}
		resp, err = s.mediaClient.Do(req)
		if err != nil {
			return &twilioMediaDownloadError{stage: "request"}
		}
		if resp.StatusCode < http.StatusMultipleChoices || resp.StatusCode >= http.StatusBadRequest {
			break
		}
		location := resp.Header.Get("Location")
		resp.Body.Close()
		parsed, parseErr := url.Parse(location)
		if parseErr != nil || !allowedTwilioMediaRedirect(parsed) {
			return &twilioMediaDownloadError{stage: "redirect", host: safeTwilioMediaHost(parsed)}
		}
		requestURL = parsed.String()
	}
	if resp == nil {
		return &twilioMediaDownloadError{stage: "request"}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return &twilioMediaDownloadError{stage: "response", status: resp.StatusCode, host: safeTwilioMediaHostFromResponse(resp)}
	}
	responseType, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if err != nil || (responseType != "" && !strings.EqualFold(responseType, media.contentType) && responseType != "application/octet-stream") {
		return &twilioMediaDownloadError{stage: "content_type", host: safeTwilioMediaHostFromResponse(resp), contentType: responseType, expectedType: media.contentType}
	}
	content, err := io.ReadAll(io.LimitReader(resp.Body, maxMediaBytes+1))
	if err != nil || len(content) == 0 || len(content) > maxMediaBytes {
		return &twilioMediaDownloadError{stage: "read_body", host: safeTwilioMediaHostFromResponse(resp)}
	}
	detectedType, _, err := mime.ParseMediaType(http.DetectContentType(content))
	if err != nil || !strings.HasPrefix(detectedType, "image/") || !strings.EqualFold(detectedType, media.contentType) {
		return &twilioMediaDownloadError{stage: "content_validation", host: safeTwilioMediaHostFromResponse(resp), contentType: detectedType, expectedType: media.contentType}
	}
	media.content = content
	if extensions, err := mime.ExtensionsByType(media.contentType); err == nil && len(extensions) > 0 {
		media.fileName = "twilio-" + media.sid + filepath.Ext(extensions[0])
	} else {
		media.fileName = "twilio-" + media.sid
	}
	return nil
}

type twilioMediaDownloadError struct {
	stage        string
	status       int
	host         string
	contentType  string
	expectedType string
}

func (e *twilioMediaDownloadError) Error() string { return "Twilio media download failed" }

func safeTwilioMediaHost(parsed *url.URL) string {
	if parsed == nil {
		return ""
	}
	return strings.ToLower(strings.TrimSuffix(parsed.Hostname(), "."))
}

func safeTwilioMediaHostFromResponse(resp *http.Response) string {
	if resp == nil || resp.Request == nil {
		return ""
	}
	return safeTwilioMediaHost(resp.Request.URL)
}

func allowedTwilioMediaRedirect(parsed *url.URL) bool {
	if parsed == nil || !strings.EqualFold(parsed.Scheme, "https") || parsed.User != nil || parsed.Fragment != "" {
		return false
	}
	if port := parsed.Port(); port != "" && port != "443" {
		return false
	}
	host := strings.ToLower(strings.TrimSuffix(parsed.Hostname(), "."))
	if ip := net.ParseIP(host); ip != nil {
		return !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() && !ip.IsLinkLocalMulticast() && !ip.IsMulticast() && !ip.IsUnspecified()
	}
	return host == "mms-media-prod.s3.amazonaws.com" || host == "s3.us-west-2.amazonaws.com" || host == "api.twilio.com" || host == "mms.twiliocdn.com" || host == "media.twiliocdn.com" || strings.HasSuffix(host, ".twilio.com")
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
	var media []twilioInboundMedia
	var accountSID, authToken string
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
		accountSID, authToken = p.credentials()
		if values.Get("AccountSid") != accountSID {
			http.Error(w, "invalid account", 403)
			return
		}
		id = values.Get("MessageSid")
		from = values.Get("From")
		to = values.Get("To")
		text = values.Get("Body")
		mediaCount := 0
		if rawCount := values.Get("NumMedia"); rawCount != "" {
			mediaCount, err = strconv.Atoi(rawCount)
			if err != nil {
				stage = "validate_media_count"
				http.Error(w, "invalid media count", 422)
				return
			}
		}
		media, err = twilioMediaFromWebhook(values, accountSID, id, mediaCount)
		if err != nil {
			stage = "validate_media_metadata"
			http.Error(w, "invalid media metadata", 422)
			return
		}
		isMMS = mediaCount > 0
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
	// Telnyx currently has no inbound media downloader. Never acknowledge and
	// discard its MMS payload.
	if isMMS && p.Type != "twilio" {
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
	if !ok || !authorizedNumber(to, p.Numbers) || id == "" || len(id) > 140 || len(text) > 65536 || (!isMMS && strings.TrimSpace(text) == "") || len(media) > 10 {
		stage = "validate_message"
		http.Error(w, "invalid message or destination", 422)
		return
	}
	if p.Type == "twilio" && len(media) > 0 {
		stage = "download_twilio_media"
		type mediaResult struct {
			index int
			err   error
		}
		results := make(chan mediaResult, len(media))
		for index := range media {
			go func(index int) {
				results <- mediaResult{index: index, err: s.downloadTwilioMedia(r.Context(), accountSID, authToken, id, &media[index])}
			}(index)
		}
		mediaTotal := 0
		for range media {
			result := <-results
			if result.err != nil {
				stage = "download_twilio_media_failed"
				if s.logger != nil {
					fields := []any{"message_id", id, "attachment_index", result.index}
					var downloadErr *twilioMediaDownloadError
					if errors.As(result.err, &downloadErr) {
						fields = append(fields, "download_stage", downloadErr.stage, "response_status", downloadErr.status, "media_host", downloadErr.host)
					}
					s.logger.Warn("Twilio MMS media download failed", fields...)
				}
				http.Error(w, "media unavailable", 502)
				return
			}
			mediaTotal += len(media[result.index].content)
		}
		if mediaTotal+len(text) > maxMediaBytes {
			stage = "validate_media_total_size"
			http.Error(w, "media exceeds size limit", 413)
			return
		}
	}
	mediaKeys := make([]string, len(media))
	for index, attachment := range media {
		key, storeErr := s.storeInboundMedia(r.Context(), id+":"+attachment.sid, attachment.fileName, attachment.contentType, attachment.content)
		if storeErr != nil {
			stage = "store_twilio_media"
			http.Error(w, "media unavailable", http.StatusBadGateway)
			return
		}
		mediaKeys[index] = key
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
		var inserted bool
		err = tx.QueryRow(r.Context(), `INSERT INTO public.flowroute_inbound_messages(message_id,sender,recipient,body,direction,is_mms,received_at,provider_id) SELECT $1,$2,$3,$4,'inbound',$5,$6,$7 WHERE NOT EXISTS(SELECT 1 FROM public.sms_deleted_messages WHERE message_id=$1) ON CONFLICT DO NOTHING RETURNING true`, id, from, to, text, isMMS, occurred, p.ID).Scan(&inserted)
		if errors.Is(err, pgx.ErrNoRows) {
			err = nil
		}
		if err == nil && inserted {
			for index, attachment := range media {
				stage = "database_insert_media"
				mediaID := id + ":" + attachment.sid
				if _, err = tx.Exec(r.Context(), `INSERT INTO public.flowroute_inbound_media(media_id,message_id,file_name,mime_type,content,object_key) VALUES($1,$2,$3,$4,NULL,$5)`, mediaID, id, attachment.fileName, attachment.contentType, mediaKeys[index]); err != nil {
					break
				}
			}
		}
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
