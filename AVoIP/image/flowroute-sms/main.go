package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
)

const (
	maxRequestBytes = 1 << 20
	maxMediaBytes   = 750 << 10
	callbackPrefix  = "/flowroute/"
)

type inboundMessage struct {
	ID        string
	From      string
	To        string
	Body      *string
	Direction string
	Timestamp time.Time
	IsMMS     bool
	Media     []mediaAttachment
}

type mediaAttachment struct {
	ID         string `json:"id"`
	Type       string `json:"type"`
	Attributes struct {
		FileName string `json:"file_name"`
		FileSize int64  `json:"file_size"`
		MIMEType string `json:"mime_type"`
		URL      string `json:"url"`
	} `json:"attributes"`
}

type callbackEnvelope struct {
	Data struct {
		ID         string `json:"id"`
		Attributes struct {
			Body      *string `json:"body"`
			Direction string  `json:"direction"`
			From      string  `json:"from"`
			To        string  `json:"to"`
			Timestamp string  `json:"timestamp"`
			IsMMS     bool    `json:"is_mms"`
		} `json:"attributes"`
	} `json:"data"`
	Included  []mediaAttachment `json:"included"`
	ID        string            `json:"id"`
	Body      *string           `json:"body"`
	Direction string            `json:"direction"`
	From      string            `json:"from"`
	To        string            `json:"to"`
	IsMMS     bool              `json:"is_mms"`
}

const createMessagesTable = `
CREATE TABLE IF NOT EXISTS public.flowroute_inbound_messages (
    message_id text PRIMARY KEY,
    sender text NOT NULL,
    recipient text NOT NULL,
    body text,
    direction text NOT NULL,
    is_mms boolean NOT NULL DEFAULT false,
    received_at timestamptz NOT NULL,
    stored_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.flowroute_inbound_media (
    media_id text PRIMARY KEY,
    message_id text NOT NULL REFERENCES public.flowroute_inbound_messages(message_id) ON DELETE CASCADE,
    file_name text NOT NULL,
    mime_type text NOT NULL,
    content bytea NOT NULL,
    stored_at timestamptz NOT NULL DEFAULT now()
);
`

const createMessagesIndex = `
CREATE INDEX IF NOT EXISTS flowroute_inbound_messages_recipient_time_idx
    ON public.flowroute_inbound_messages (recipient, received_at DESC)
`

const createMediaIndex = `
CREATE INDEX IF NOT EXISTS flowroute_inbound_media_message_idx
    ON public.flowroute_inbound_media (message_id)
`

type server struct {
	pool        *pgxpool.Pool
	token       []byte
	logger      *slog.Logger
	mediaClient *http.Client
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := run(logger); err != nil {
		logger.Error("service stopped", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	databaseURL := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	callbackToken := os.Getenv("FLOWROUTE_CALLBACK_TOKEN")
	if databaseURL == "" || callbackToken == "" {
		return errors.New("DATABASE_URL and FLOWROUTE_CALLBACK_TOKEN are required")
	}
	if len(callbackToken) < 32 {
		return errors.New("FLOWROUTE_CALLBACK_TOKEN must contain at least 32 bytes")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	poolConfig, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return fmt.Errorf("parse PostgreSQL configuration: %w", err)
	}
	poolConfig.MaxConns = 5
	poolConfig.MinConns = 0
	poolConfig.MaxConnLifetime = 30 * time.Minute
	poolConfig.MaxConnIdleTime = 5 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return fmt.Errorf("create PostgreSQL pool: %w", err)
	}
	defer pool.Close()

	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		return fmt.Errorf("connect to PostgreSQL: %w", err)
	}
	if _, err := pool.Exec(pingCtx, createMessagesTable); err != nil {
		return fmt.Errorf("initialize inbound message table: %w", err)
	}
	if _, err := pool.Exec(pingCtx, createMessagesIndex); err != nil {
		return fmt.Errorf("initialize inbound message index: %w", err)
	}
	if _, err := pool.Exec(pingCtx, createMediaIndex); err != nil {
		return fmt.Errorf("initialize inbound media index: %w", err)
	}

	app := &server{pool: pool, token: []byte(callbackToken), logger: logger, mediaClient: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", app.health)
	mux.HandleFunc("GET /readyz", app.ready)
	mux.HandleFunc("POST /flowroute/", app.receive)
	mux.HandleFunc("GET /inbox", app.inbox)
	mux.HandleFunc("GET /api/messages", app.listMessages)
	mux.HandleFunc("GET /media/{id}", app.getMedia)

	address := os.Getenv("LISTEN_ADDRESS")
	if address == "" {
		address = ":8080"
	}
	httpServer := &http.Server{
		Addr:              address,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			logger.Error("HTTP shutdown failed", "error", err)
		}
	}()
	logger.Info("Flowroute SMS receiver started", "address", address)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve HTTP: %w", err)
	}
	return nil
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}

func (s *server) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.pool.Ping(ctx); err != nil {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (s *server) receive(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		s.reply(w, r, "", "rejected", http.StatusMethodNotAllowed)
		return
	}
	if !validTokenPath(r.URL.Path, s.token) {
		s.reply(w, r, "", "unauthorized", http.StatusNotFound)
		return
	}
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	jsonMediaType := mediaType == "application/json" || (strings.HasPrefix(mediaType, "application/") && strings.HasSuffix(mediaType, "+json"))
	if err != nil || !jsonMediaType {
		s.reply(w, r, "", "invalid_content_type", http.StatusUnsupportedMediaType)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRequestBytes))
	if err != nil {
		s.reply(w, r, "", "invalid_payload", http.StatusRequestEntityTooLarge)
		return
	}
	message, err := parseMessage(body)
	if err != nil {
		s.reply(w, r, "", "invalid_payload", http.StatusBadRequest)
		return
	}
	if message.Direction != "" && !strings.EqualFold(message.Direction, "inbound") {
		s.reply(w, r, message.ID, "ignored_non_inbound", http.StatusOK)
		return
	}
	var alreadyStored bool
	if err := s.pool.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM public.flowroute_inbound_messages WHERE message_id=$1)`, message.ID).Scan(&alreadyStored); err != nil {
		s.reply(w, r, message.ID, "database_error", http.StatusServiceUnavailable)
		return
	}
	if alreadyStored {
		s.reply(w, r, message.ID, "duplicate", http.StatusOK)
		return
	}
	maxTextBytes := 65536
	if message.IsMMS {
		maxTextBytes = maxMediaBytes
	}
	if len(message.ID) > 200 || len(message.From) > 64 || len(message.To) > 64 || (message.Body != nil && len(*message.Body) > maxTextBytes) || len(message.Media) > 10 {
		s.reply(w, r, message.ID, "invalid_payload", http.StatusBadRequest)
		return
	}
	mediaContent := make([][]byte, len(message.Media))
	mediaErrors := make(chan error, len(message.Media))
	semaphore := make(chan struct{}, 4)
	var mediaWait sync.WaitGroup
	for i, media := range message.Media {
		mediaWait.Add(1)
		go func(index int, attachment mediaAttachment) {
			defer mediaWait.Done()
			semaphore <- struct{}{}
			defer func() { <-semaphore }()
			content, err := s.downloadMedia(r.Context(), attachment)
			if err != nil {
				mediaErrors <- err
				return
			}
			mediaContent[index] = content
		}(i, media)
	}
	mediaWait.Wait()
	close(mediaErrors)
	for err := range mediaErrors {
		if err != nil {
			s.logger.Warn("MMS attachment fetch failed", "message_id", message.ID)
			s.reply(w, r, message.ID, "media_fetch_failed", http.StatusBadGateway)
			return
		}
	}
	mediaTotal := 0
	for _, content := range mediaContent {
		mediaTotal += len(content)
	}
	if message.Body != nil && len(*message.Body)+mediaTotal > maxMediaBytes {
		s.reply(w, r, message.ID, "invalid_payload", http.StatusBadRequest)
		return
	}
	if message.Timestamp.IsZero() {
		message.Timestamp = time.Now().UTC()
	}

	var inserted bool
	tx, err := s.pool.Begin(r.Context())
	if err != nil {
		s.reply(w, r, message.ID, "database_error", http.StatusServiceUnavailable)
		return
	}
	defer tx.Rollback(r.Context())
	err = tx.QueryRow(r.Context(), `
INSERT INTO public.flowroute_inbound_messages
    (message_id, sender, recipient, body, direction, is_mms, received_at)
VALUES ($1, $2, $3, $4, 'inbound', $5, $6)
ON CONFLICT (message_id) DO NOTHING
RETURNING true`, message.ID, message.From, message.To, nullableBody(message.Body), message.IsMMS, message.Timestamp).Scan(&inserted)
	if errors.Is(err, pgx.ErrNoRows) {
		inserted, err = false, nil
	}
	if err == nil && inserted {
		for i, media := range message.Media {
			if _, err = tx.Exec(r.Context(), `INSERT INTO public.flowroute_inbound_media (media_id,message_id,file_name,mime_type,content) VALUES ($1,$2,$3,$4,$5) ON CONFLICT (media_id) DO NOTHING`, media.ID, message.ID, safeFileName(media.Attributes.FileName), media.Attributes.MIMEType, mediaContent[i]); err != nil {
				break
			}
		}
	}
	if err == nil {
		err = tx.Commit(r.Context())
	}
	if err != nil {
		s.logger.Error("message persistence failed", "message_id", message.ID)
		s.reply(w, r, message.ID, "database_error", http.StatusServiceUnavailable)
		return
	}
	branch := "duplicate"
	if inserted {
		branch = "stored"
	}
	s.reply(w, r, message.ID, branch, http.StatusOK)
}

func (s *server) reply(w http.ResponseWriter, r *http.Request, messageID, branch string, status int) {
	relayResult := "not_attempted"
	switch branch {
	case "stored":
		relayResult = "inserted"
	case "duplicate":
		relayResult = "duplicate"
	case "database_error":
		relayResult = "failed"
	}
	contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil {
		contentType = "invalid"
	}
	s.logger.Info("callback processed", "message_id", messageID, "method", r.Method, "content_type", contentType, "selected_branch", branch, "relay_result", relayResult, "response_status", status)
	w.WriteHeader(status)
}

func validTokenPath(path string, token []byte) bool {
	provided := strings.TrimPrefix(path, callbackPrefix)
	if provided == path || strings.Contains(provided, "/") || provided == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(provided), token) == 1
}

func parseMessage(raw []byte) (inboundMessage, error) {
	var payload callbackEnvelope
	if err := json.Unmarshal(raw, &payload); err != nil {
		return inboundMessage{}, fmt.Errorf("decode callback: %w", err)
	}
	message := inboundMessage{}
	if payload.Data.ID != "" || payload.Data.Attributes.From != "" || payload.Data.Attributes.To != "" {
		message.ID = payload.Data.ID
		message.From = payload.Data.Attributes.From
		message.To = payload.Data.Attributes.To
		message.Body = payload.Data.Attributes.Body
		message.Direction = payload.Data.Attributes.Direction
		message.IsMMS = payload.Data.Attributes.IsMMS
		message.Media = payload.Included
		if payload.Data.Attributes.Timestamp != "" {
			parsed, err := time.Parse(time.RFC3339Nano, payload.Data.Attributes.Timestamp)
			if err != nil {
				return inboundMessage{}, errors.New("invalid timestamp")
			}
			message.Timestamp = parsed
		}
	} else {
		message.ID = payload.ID
		message.From = payload.From
		message.To = payload.To
		message.Body = payload.Body
		message.Direction = payload.Direction
		message.IsMMS = payload.IsMMS
	}
	if strings.TrimSpace(message.ID) == "" || strings.TrimSpace(message.From) == "" || strings.TrimSpace(message.To) == "" {
		return inboundMessage{}, errors.New("required callback fields are missing")
	}
	if message.Body == nil && !message.IsMMS {
		return inboundMessage{}, errors.New("SMS body is missing")
	}
	return message, nil
}

func (s *server) downloadMedia(ctx context.Context, media mediaAttachment) ([]byte, error) {
	parsed, err := url.Parse(media.Attributes.URL)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() != "mms-media-prod.s3.amazonaws.com" || parsed.User != nil {
		return nil, errors.New("invalid Flowroute media URL")
	}
	if media.ID == "" || !strings.HasPrefix(media.Attributes.MIMEType, "image/") || media.Attributes.FileSize < 0 || media.Attributes.FileSize > maxMediaBytes {
		return nil, errors.New("invalid media metadata")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.mediaClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("media server returned %d", resp.StatusCode)
	}
	contentType, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if err != nil || !strings.EqualFold(contentType, media.Attributes.MIMEType) {
		return nil, errors.New("media type mismatch")
	}
	content, err := io.ReadAll(io.LimitReader(resp.Body, maxMediaBytes+1))
	if err != nil || len(content) > maxMediaBytes {
		return nil, errors.New("media exceeds size limit")
	}
	detectedType, _, err := mime.ParseMediaType(http.DetectContentType(content))
	if err != nil || !strings.HasPrefix(detectedType, "image/") {
		return nil, errors.New("download is not an image")
	}
	return content, nil
}

func safeFileName(name string) string {
	name = strings.ReplaceAll(name, "\\", "/")
	name = name[strings.LastIndex(name, "/")+1:]
	if name == "" {
		return "attachment"
	}
	return name
}

func (s *server) allowedNumbers(r *http.Request) []string {
	// This header is populated by the Authentik-backed gateway policy. Direct
	// pod access is disabled by the chart; never trust an unprotected route.
	parts := strings.Split(r.Header.Get("X-Auth-Numbers"), ",")
	allowed := make([]string, 0, len(parts))
	for _, number := range parts {
		number = strings.TrimSpace(number)
		if len(number) > 2 && number[0] == '+' {
			valid := true
			for _, ch := range number[1:] {
				if ch < '0' || ch > '9' {
					valid = false
					break
				}
			}
			if valid {
				allowed = append(allowed, number)
			}
		}
	}
	return allowed
}

func (s *server) inbox(w http.ResponseWriter, r *http.Request) {
	if len(s.allowedNumbers(r)) == 0 {
		http.Error(w, "no authorized numbers", http.StatusForbidden)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>SMS Inbox</title><main><h1>Messages</h1><div id="messages">Loading…</div></main><script>
fetch('/api/messages').then(r=>{if(!r.ok)throw Error('Unable to load messages');return r.json()}).then(rows=>{const root=document.querySelector('#messages');root.replaceChildren();for(const m of rows){const article=document.createElement('article'),h=document.createElement('h2'),p=document.createElement('p'),time=document.createElement('time');h.textContent=m.sender+' → '+m.recipient;p.textContent=m.body||'';time.textContent=new Date(m.received_at).toLocaleString();article.append(h,time,p);for(const a of m.media||[]){if(a.mime_type.startsWith('image/')){const img=document.createElement('img');img.src='/media/'+encodeURIComponent(a.id);img.alt=a.file_name;img.loading='lazy';img.style.maxWidth='100%';article.append(img)}else{const link=document.createElement('a');link.href='/media/'+encodeURIComponent(a.id);link.textContent=a.file_name;article.append(link)}}root.append(article)}}).catch(e=>document.querySelector('#messages').textContent=e.message)
</script>`)
}

func (s *server) listMessages(w http.ResponseWriter, r *http.Request) {
	numbers := s.allowedNumbers(r)
	if len(numbers) == 0 {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	rows, err := s.pool.Query(r.Context(), `SELECT message_id,sender,recipient,body,received_at,is_mms FROM public.flowroute_inbound_messages WHERE recipient = ANY($1) ORDER BY received_at DESC LIMIT 200`, numbers)
	if err != nil {
		http.Error(w, "database unavailable", http.StatusServiceUnavailable)
		return
	}
	defer rows.Close()
	type mediaInfo struct {
		ID       string `json:"id"`
		FileName string `json:"file_name"`
		MIMEType string `json:"mime_type"`
	}
	type inboxMessage struct {
		ID         string      `json:"id"`
		Sender     string      `json:"sender"`
		Recipient  string      `json:"recipient"`
		Body       *string     `json:"body"`
		ReceivedAt time.Time   `json:"received_at"`
		IsMMS      bool        `json:"is_mms"`
		Media      []mediaInfo `json:"media"`
	}
	result := make([]inboxMessage, 0)
	for rows.Next() {
		var item inboxMessage
		if err := rows.Scan(&item.ID, &item.Sender, &item.Recipient, &item.Body, &item.ReceivedAt, &item.IsMMS); err != nil {
			http.Error(w, "database error", 500)
			return
		}
		item.Media = []mediaInfo{}
		result = append(result, item)
	}
	if rows.Err() != nil {
		http.Error(w, "database error", 500)
		return
	}
	messageIndexes := make(map[string]int, len(result))
	messageIDs := make([]string, 0, len(result))
	for i := range result {
		messageIndexes[result[i].ID] = i
		messageIDs = append(messageIDs, result[i].ID)
	}
	if len(messageIDs) > 0 {
		mediaRows, err := s.pool.Query(r.Context(), `SELECT message_id,media_id,file_name,mime_type FROM public.flowroute_inbound_media WHERE message_id=ANY($1) ORDER BY media_id`, messageIDs)
		if err != nil {
			http.Error(w, "database error", 500)
			return
		}
		defer mediaRows.Close()
		for mediaRows.Next() {
			var messageID string
			var item mediaInfo
			if err := mediaRows.Scan(&messageID, &item.ID, &item.FileName, &item.MIMEType); err != nil {
				http.Error(w, "database error", 500)
				return
			}
			if i, ok := messageIndexes[messageID]; ok {
				result[i].Media = append(result[i].Media, item)
			}
		}
		if mediaRows.Err() != nil {
			http.Error(w, "database error", 500)
			return
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func (s *server) getMedia(w http.ResponseWriter, r *http.Request) {
	numbers := s.allowedNumbers(r)
	if len(numbers) == 0 {
		http.Error(w, "forbidden", 403)
		return
	}
	var mimeType, fileName string
	var content []byte
	err := s.pool.QueryRow(r.Context(), `SELECT m.mime_type,m.file_name,m.content FROM public.flowroute_inbound_media m JOIN public.flowroute_inbound_messages msg USING(message_id) WHERE m.media_id=$1 AND msg.recipient=ANY($2)`, r.PathValue("id"), numbers).Scan(&mimeType, &fileName, &content)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", mimeType)
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("inline", map[string]string{"filename": safeFileName(fileName)}))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	io.Copy(w, bytes.NewReader(content))
}

func nullableBody(body *string) any {
	if body == nil {
		return nil
	}
	return *body
}
