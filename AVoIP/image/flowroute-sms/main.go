package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"embed"
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

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
)

//go:embed web/*
var webFiles embed.FS
var builtMode = "all"

const (
	maxRequestBytes = 1 << 20
	maxMediaBytes   = 750 << 10
	callbackPrefix  = "/flowroute/"
)

type inboundMessage struct {
	ID              string
	From            string
	To              string
	Body            *string
	Direction       string
	Timestamp       time.Time
	IsMMS           bool
	Media           []mediaAttachment
	MediaReferences int
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
		ID            string `json:"id"`
		Relationships struct {
			Media struct {
				Data []struct {
					ID   string `json:"id"`
					Type string `json:"type"`
				} `json:"data"`
			} `json:"media"`
		} `json:"relationships"`
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
    content bytea,
    object_key text,
    stored_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.flowroute_inbound_media ADD COLUMN IF NOT EXISTS object_key text;
ALTER TABLE public.flowroute_inbound_media ALTER COLUMN content DROP NOT NULL;
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
	routingMu       sync.RWMutex
	routingState    *sipCatalog
	routingDeadline time.Time
	pool            *pgxpool.Pool
	token           []byte
	logger          *slog.Logger
	mediaClient     *http.Client
	mediaStore      *mediaStore
	sendKey         string
	sendSecret      string
	sendClient      *http.Client
	sendMu          sync.Mutex
	lastSend        map[string]time.Time
}

type mediaFetchError struct {
	stage         string
	httpStatus    int
	mediaScheme   string
	mediaHost     string
	expectedMIME  string
	actualMIME    string
	expectedBytes int64
	actualBytes   int
}

func (e *mediaFetchError) Error() string {
	return e.stage
}

type mediaFetchResult struct {
	index   int
	content []byte
	err     error
}

func main() {
	level := slog.LevelInfo
	if strings.EqualFold(strings.TrimSpace(os.Getenv("FLOWROUTE_SMS_DIAGNOSTICS")), "true") {
		level = slog.LevelDebug
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
	if err := run(logger); err != nil {
		logger.Error("service stopped", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	mode := strings.TrimSpace(os.Getenv("SMS_SERVICE_MODE"))
	if mode == "fs-config" {
		return renderFreeSwitchConfig()
	}
	if builtMode != "all" && mode != builtMode {
		return errors.New("image mode does not match SMS_SERVICE_MODE")
	}
	if mode == "web" {
		mux := http.NewServeMux()
		app := &server{}
		mux.HandleFunc("GET /inbox", app.inbox)
		mux.HandleFunc("GET /assets/{name}", app.asset)
		mux.HandleFunc("GET /healthz", app.health)
		return http.ListenAndServe(":8080", mux)
	}
	databaseURL := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	callbackToken := os.Getenv("FLOWROUTE_CALLBACK_TOKEN")
	if mode == "media" {
		store, err := newMediaStore(context.Background())
		if err != nil {
			return err
		}
		mux := http.NewServeMux()
		mux.HandleFunc("GET /healthz", (&server{mediaStore: store}).health)
		mux.HandleFunc("GET /readyz", (&server{mediaStore: store}).mediaReady)
		mux.HandleFunc("GET /media/{token}", (&server{mediaStore: store}).serveProxyMedia)
		return http.ListenAndServe(":8080", mux)
	}
	if mode == "tts-cache" {
		return runTTSCache(logger)
	}
	if mode != "api" && mode != "webhook" && mode != "admin" {
		return errors.New("SMS_SERVICE_MODE must be api, web, webhook, admin, media, or tts-cache")
	}
	if databaseURL == "" || (mode == "webhook" && os.Getenv("FLOWROUTE_ENABLED") != "false" && callbackToken == "") {
		return errors.New("DATABASE_URL and webhook callback token are required for the selected mode")
	}
	if mode == "webhook" && os.Getenv("FLOWROUTE_ENABLED") != "false" && len(callbackToken) < 32 {
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
	if _, err := configuredProviders(); err != nil {
		return err
	}
	if _, err := loadConfiguredCatalog(); err != nil {
		return err
	}
	initTx, err := pool.Begin(pingCtx)
	if err != nil {
		return errors.New("schema initialization unavailable")
	}
	defer initTx.Rollback(ctx)
	if _, err = initTx.Exec(pingCtx, `SELECT pg_advisory_xact_lock(hashtext('avoip_sms_schema'))`); err == nil {
		_, err = initTx.Exec(pingCtx, createMessagesTable+";"+adminSchema+";"+createMessagesIndex+";"+createMediaIndex)
	}
	if err == nil {
		err = initTx.Commit(pingCtx)
	}
	if err != nil {
		return errors.New("schema initialization failed")
	}

	store, err := newOptionalMediaStore(ctx)
	if err != nil {
		return err
	}
	app := &server{pool: pool, mediaStore: store, token: []byte(callbackToken), logger: logger, mediaClient: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}, sendClient: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}, sendKey: os.Getenv("FLOWROUTE_SMS_ACCESS_KEY"), sendSecret: os.Getenv("FLOWROUTE_SMS_SECRET_KEY"), lastSend: make(map[string]time.Time)}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", app.health)
	mux.HandleFunc("GET /readyz", app.ready)
	if mode == "webhook" {
		if os.Getenv("FLOWROUTE_ENABLED") != "false" {
			mux.HandleFunc("POST /flowroute/", app.receive)
		}
		mux.HandleFunc("POST /providers/{id}/inbound", app.receiveProvider)
	}
	if mode == "api" {
		mux.HandleFunc("GET /api/messages", app.listMessages)
		mux.HandleFunc("GET /api/numbers", app.listNumbers)
		mux.HandleFunc("POST /api/messages", app.sendMessage)
		mux.HandleFunc("POST /api/media", app.uploadMedia)
		mux.HandleFunc("GET /media/{id}", app.getMedia)
		mux.HandleFunc("DELETE /api/messages/{id}", app.deleteMessage)
	}

	if mode == "api" || mode == "admin" {
		mux.HandleFunc("GET /api/providers", app.listProviders)
		mux.HandleFunc("PUT /api/providers/{id}", app.saveProvider)
		mux.HandleFunc("DELETE /api/providers/{id}", app.deleteProvider)
		app.registerAdmin(mux)
		mux.HandleFunc("GET /api/telephony", app.telephony)
		mux.HandleFunc("POST /api/telephony/hangup", app.hangupCall)
	}
	if mode == "admin" {
		go app.refreshCatalog(ctx)
		go app.bridgedCallWorker(ctx)
		internalMux := http.NewServeMux()
		internalMux.HandleFunc("GET /routing/readyz", app.routingReady)
		internalMux.HandleFunc("GET /routing/snapshot", app.routingSnapshot)
		internalMux.HandleFunc("POST /routing/freeswitch", app.freeSwitchRoute)
		internalServer := &http.Server{Addr: ":8081", Handler: internalMux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, MaxHeaderBytes: 16 << 10}
		go func() {
			<-ctx.Done()
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			internalServer.Shutdown(shutdownCtx)
		}()
		go func() {
			if err := internalServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				logger.Error("internal routing listener failed")
				stop()
			}
		}()
		mux.HandleFunc("GET /", app.adminPage)
		mux.HandleFunc("GET /assets/{name}", app.asset)
		app.registerBridgedCalls(mux)
	}

	address := os.Getenv("LISTEN_ADDRESS")
	if address == "" {
		address = ":8080"
	}
	httpServer := &http.Server{
		Addr:              address,
		Handler:           logWebhookPosts(logger, mode, mux),
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

type statusResponseWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusResponseWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusResponseWriter) Write(body []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(body)
}

func logWebhookPosts(logger *slog.Logger, mode string, next http.Handler) http.Handler {
	if mode != "webhook" {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			next.ServeHTTP(w, r)
			return
		}
		started := time.Now()
		tracked := &statusResponseWriter{ResponseWriter: w}
		defer func() {
			status := tracked.status
			if status == 0 {
				status = http.StatusOK
			}
			mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if err != nil {
				mediaType = "invalid"
			}
			logger.Debug("inbound HTTP POST received",
				"path_class", inboundPathClass(r.URL.Path),
				"content_type", mediaType,
				"content_length", r.ContentLength,
				"response_status", status,
				"duration_ms", time.Since(started).Milliseconds(),
			)
		}()
		next.ServeHTTP(tracked, r)
	})
}

func inboundPathClass(path string) string {
	if path == "/flowroute" || strings.HasPrefix(path, callbackPrefix) {
		return "/flowroute/{redacted}"
	}
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 3 && parts[0] == "providers" && parts[2] == "inbound" && parts[1] != "" {
		return "/providers/{id}/inbound"
	}
	return "/unmatched"
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}

func (s *server) mediaReady(w http.ResponseWriter, _ *http.Request) {
	if s.mediaStore == nil {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
		return
	}
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
		s.logger.Debug("callback rejected", "failure_stage", "content_type", "content_type", mediaType, "response_status", http.StatusUnsupportedMediaType)
		s.reply(w, r, "", "invalid_content_type", http.StatusUnsupportedMediaType)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRequestBytes))
	if err != nil {
		s.logger.Debug("callback rejected", "failure_stage", "read_payload", "response_status", http.StatusRequestEntityTooLarge)
		s.reply(w, r, "", "invalid_payload", http.StatusRequestEntityTooLarge)
		return
	}
	message, err := parseMessage(body)
	if err != nil {
		s.logger.Debug("callback payload rejected", "failure_stage", "parse_payload", "error_class", fmt.Sprintf("%T", err), "response_status", http.StatusBadRequest)
		s.reply(w, r, "", "invalid_payload", http.StatusBadRequest)
		return
	}
	s.logger.Debug("callback payload parsed", "message_id", message.ID, "is_mms", message.IsMMS, "attachment_reference_count", message.MediaReferences, "included_attachment_count", len(message.Media), "message_body_bytes", bodyLength(message.Body), "content_type", mediaType)
	if message.MediaReferences != len(message.Media) {
		s.logger.Warn("MMS attachment references do not match included media", "message_id", message.ID, "failure_stage", "compare_media_references", "attachment_reference_count", message.MediaReferences, "included_attachment_count", len(message.Media))
	}
	if message.IsMMS && message.MediaReferences == 0 && len(message.Media) == 0 {
		s.logger.Warn("MMS callback has no media attachments", "message_id", message.ID, "failure_stage", "missing_media")
	}
	if message.Direction != "" && !strings.EqualFold(message.Direction, "inbound") {
		s.reply(w, r, message.ID, "ignored_non_inbound", http.StatusOK)
		return
	}
	from, fromOK := normalizePhoneNumber(message.From)
	to, toOK := normalizePhoneNumber(message.To)
	if !fromOK || !toOK {
		s.logger.Debug("callback payload rejected", "message_id", message.ID, "failure_stage", "normalize_phone_numbers", "response_status", http.StatusBadRequest)
		s.reply(w, r, message.ID, "invalid_payload", http.StatusBadRequest)
		return
	}
	message.From = from
	message.To = to
	var alreadyStored bool
	if err := s.pool.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM public.flowroute_inbound_messages WHERE message_id=$1 UNION ALL SELECT 1 FROM public.sms_deleted_messages WHERE message_id=$1)`, message.ID).Scan(&alreadyStored); err != nil {
		s.logger.Warn("callback duplicate check failed", "message_id", message.ID, "failure_stage", "check_duplicate", "response_status", http.StatusServiceUnavailable)
		s.reply(w, r, message.ID, "database_error", http.StatusServiceUnavailable)
		return
	}
	if alreadyStored {
		s.logger.Debug("callback duplicate ignored", "message_id", message.ID, "attachment_count", len(message.Media), "response_status", http.StatusOK)
		s.reply(w, r, message.ID, "duplicate", http.StatusOK)
		return
	}
	maxTextBytes := 65536
	if message.IsMMS {
		maxTextBytes = maxMediaBytes
	}
	if len(message.ID) > 200 || len(message.From) > 64 || len(message.To) > 64 || (message.Body != nil && len(*message.Body) > maxTextBytes) || len(message.Media) > 10 {
		s.logger.Debug("callback payload rejected", "message_id", message.ID, "failure_stage", "payload_limits", "is_mms", message.IsMMS, "attachment_count", len(message.Media), "message_body_bytes", bodyLength(message.Body), "response_status", http.StatusBadRequest)
		s.reply(w, r, message.ID, "invalid_payload", http.StatusBadRequest)
		return
	}
	mediaContent := make([][]byte, len(message.Media))
	mediaResults := make(chan mediaFetchResult, len(message.Media))
	semaphore := make(chan struct{}, 4)
	var mediaWait sync.WaitGroup
	for i, media := range message.Media {
		mediaWait.Add(1)
		go func(index int, attachment mediaAttachment) {
			defer mediaWait.Done()
			semaphore <- struct{}{}
			defer func() { <-semaphore }()
			content, err := s.downloadMedia(r.Context(), attachment)
			mediaResults <- mediaFetchResult{index: index, content: content, err: err}
		}(i, media)
	}
	mediaWait.Wait()
	close(mediaResults)
	for result := range mediaResults {
		if result.err != nil {
			fields := []any{"attachment_index", result.index, "response_status", http.StatusBadGateway}
			var fetchErr *mediaFetchError
			if errors.As(result.err, &fetchErr) {
				fields = append(fields, "failure_stage", fetchErr.stage)
				if fetchErr.httpStatus != 0 {
					fields = append(fields, "media_http_status", fetchErr.httpStatus)
				}
				if fetchErr.mediaScheme != "" {
					fields = append(fields, "media_url_scheme", fetchErr.mediaScheme)
				}
				if fetchErr.mediaHost != "" {
					fields = append(fields, "media_url_host", fetchErr.mediaHost)
				}
				if fetchErr.expectedMIME != "" {
					fields = append(fields, "expected_mime_type", fetchErr.expectedMIME)
				}
				if fetchErr.actualMIME != "" {
					fields = append(fields, "actual_mime_type", fetchErr.actualMIME)
				}
				if fetchErr.expectedBytes != 0 || fetchErr.stage == "validate_metadata" {
					fields = append(fields, "declared_bytes", fetchErr.expectedBytes)
				}
				if fetchErr.actualBytes != 0 || fetchErr.stage == "read_or_size_limit" || fetchErr.stage == "validate_image_content" {
					fields = append(fields, "actual_bytes", fetchErr.actualBytes)
				}
			} else {
				fields = append(fields, "failure_stage", "unknown")
			}
			fields = append(fields, "message_id", message.ID, "is_mms", message.IsMMS)
			s.logger.Warn("MMS attachment fetch failed", fields...)
			s.reply(w, r, message.ID, "media_fetch_failed", http.StatusBadGateway)
			return
		}
		mediaContent[result.index] = result.content
		s.logger.Debug("MMS attachment fetched", "message_id", message.ID, "attachment_index", result.index, "media_id", message.Media[result.index].ID, "mime_type", message.Media[result.index].Attributes.MIMEType, "declared_bytes", message.Media[result.index].Attributes.FileSize, "downloaded_bytes", len(result.content))
	}
	mediaTotal := 0
	for _, content := range mediaContent {
		mediaTotal += len(content)
	}
	if message.Body != nil && len(*message.Body)+mediaTotal > maxMediaBytes {
		s.logger.Debug("callback payload rejected", "message_id", message.ID, "failure_stage", "combined_media_size_limit", "attachment_count", len(message.Media), "attachment_bytes", mediaTotal, "message_body_bytes", bodyLength(message.Body), "response_status", http.StatusBadRequest)
		s.reply(w, r, message.ID, "invalid_payload", http.StatusBadRequest)
		return
	}
	if message.Timestamp.IsZero() {
		message.Timestamp = time.Now().UTC()
	}
	mediaKeys := make([]string, len(message.Media))
	for i, media := range message.Media {
		key, storeErr := s.storeInboundMedia(r.Context(), media.ID, media.Attributes.FileName, media.Attributes.MIMEType, mediaContent[i])
		if storeErr != nil {
			s.logger.Error("MMS attachment storage failed", "message_id", message.ID, "attachment_index", i, "failure_stage", "store_media")
			s.reply(w, r, message.ID, "media_storage_failed", http.StatusBadGateway)
			return
		}
		mediaKeys[i] = key
	}

	var inserted bool
	tx, err := s.pool.Begin(r.Context())
	if err != nil {
		s.logger.Warn("message persistence failed", "message_id", message.ID, "failure_stage", "begin_transaction", "response_status", http.StatusServiceUnavailable)
		s.reply(w, r, message.ID, "database_error", http.StatusServiceUnavailable)
		return
	}
	defer tx.Rollback(r.Context())

	if _, err = tx.Exec(r.Context(), `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, message.ID); err != nil {
		s.reply(w, r, message.ID, "database_error", 503)
		return
	}
	var deleted bool
	if err = tx.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM public.sms_deleted_messages WHERE message_id=$1)`, message.ID).Scan(&deleted); err != nil {
		s.reply(w, r, message.ID, "database_error", 503)
		return
	}
	if deleted {
		s.reply(w, r, message.ID, "duplicate", 200)
		return
	}
	err = tx.QueryRow(r.Context(), `
INSERT INTO public.flowroute_inbound_messages
    (message_id, sender, recipient, body, direction, is_mms, received_at)
VALUES ($1, $2, $3, $4, 'inbound', $5, $6)
ON CONFLICT (message_id) DO NOTHING
RETURNING true`, message.ID, message.From, message.To, nullableBody(message.Body), message.IsMMS, message.Timestamp).Scan(&inserted)
	if errors.Is(err, pgx.ErrNoRows) {
		inserted, err = false, nil
	}
	persistStage := "insert_message"
	if err == nil && inserted {
		for i, media := range message.Media {
			persistStage = "insert_media"
			if _, err = tx.Exec(r.Context(), `INSERT INTO public.flowroute_inbound_media (media_id,message_id,file_name,mime_type,content,object_key) VALUES ($1,$2,$3,$4,NULL,$5) ON CONFLICT (media_id) DO NOTHING`, media.ID, message.ID, safeFileName(media.Attributes.FileName), media.Attributes.MIMEType, mediaKeys[i]); err != nil {
				break
			}
		}
	}
	if err == nil {
		persistStage = "commit_transaction"
		err = tx.Commit(r.Context())
	}
	if err != nil {
		s.logger.Error("message persistence failed", "message_id", message.ID, "failure_stage", persistStage, "is_mms", message.IsMMS, "attachment_count", len(message.Media), "attachment_bytes", mediaTotal, "response_status", http.StatusServiceUnavailable)
		s.reply(w, r, message.ID, "database_error", http.StatusServiceUnavailable)
		return
	}
	s.logger.Debug("callback message persisted", "message_id", message.ID, "is_mms", message.IsMMS, "attachment_count", len(message.Media), "attachment_bytes", mediaTotal)
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
		message.MediaReferences = len(payload.Data.Relationships.Media.Data)
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
		message.MediaReferences = len(payload.Included)
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
	if err != nil {
		return nil, &mediaFetchError{stage: "parse_url"}
	}
	if !allowedFlowrouteMediaURL(parsed) {
		return nil, &mediaFetchError{stage: "validate_url_policy", mediaScheme: parsed.Scheme, mediaHost: parsed.Hostname()}
	}
	if media.ID == "" || !strings.HasPrefix(media.Attributes.MIMEType, "image/") || media.Attributes.FileSize < 0 || media.Attributes.FileSize > maxMediaBytes {
		return nil, &mediaFetchError{stage: "validate_metadata", expectedMIME: media.Attributes.MIMEType, expectedBytes: media.Attributes.FileSize}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return nil, &mediaFetchError{stage: "build_request", expectedMIME: media.Attributes.MIMEType, expectedBytes: media.Attributes.FileSize}
	}
	resp, err := s.mediaClient.Do(req)
	if err != nil {
		return nil, &mediaFetchError{stage: "request_media", expectedMIME: media.Attributes.MIMEType, expectedBytes: media.Attributes.FileSize}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, &mediaFetchError{stage: "media_http_status", httpStatus: resp.StatusCode, expectedMIME: media.Attributes.MIMEType, expectedBytes: media.Attributes.FileSize}
	}
	contentType, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if err != nil || !strings.EqualFold(contentType, media.Attributes.MIMEType) {
		if err != nil {
			contentType = "invalid"
		}
		return nil, &mediaFetchError{stage: "validate_response_content_type", expectedMIME: media.Attributes.MIMEType, actualMIME: contentType, expectedBytes: media.Attributes.FileSize}
	}
	content, err := io.ReadAll(io.LimitReader(resp.Body, maxMediaBytes+1))
	if err != nil || len(content) > maxMediaBytes {
		return nil, &mediaFetchError{stage: "read_or_size_limit", expectedMIME: media.Attributes.MIMEType, actualMIME: contentType, expectedBytes: media.Attributes.FileSize, actualBytes: len(content)}
	}
	detectedType, _, err := mime.ParseMediaType(http.DetectContentType(content))
	if err != nil || !strings.HasPrefix(detectedType, "image/") {
		if err != nil {
			detectedType = "invalid"
		}
		return nil, &mediaFetchError{stage: "validate_image_content", expectedMIME: media.Attributes.MIMEType, actualMIME: detectedType, expectedBytes: media.Attributes.FileSize, actualBytes: len(content)}
	}
	return content, nil
}

func allowedFlowrouteMediaURL(parsed *url.URL) bool {
	if parsed == nil || !strings.EqualFold(parsed.Scheme, "https") || parsed.User != nil {
		return false
	}
	if port := parsed.Port(); port != "" && port != "443" {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	return host == "mms-media-prod.s3.amazonaws.com" || host == "s3.us-west-2.amazonaws.com"
}

func bodyLength(body *string) int {
	if body == nil {
		return 0
	}
	return len(*body)
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
	allowed := make([]string, 0, len(parts)*2)
	seen := make(map[string]struct{}, len(parts)*2)
	for _, number := range parts {
		canonical, valid := normalizePhoneNumber(number)
		if !valid {
			continue
		}
		for _, lookupValue := range []string{canonical, strings.TrimPrefix(canonical, "+")} {
			if _, exists := seen[lookupValue]; exists {
				continue
			}
			seen[lookupValue] = struct{}{}
			allowed = append(allowed, lookupValue)
		}
	}
	return allowed
}

func normalizePhoneNumber(value string) (string, bool) {
	value = strings.TrimSpace(value)
	digits := strings.TrimPrefix(value, "+")
	if len(digits) < 8 || len(digits) > 15 || digits[0] == '0' {
		return "", false
	}
	for _, digit := range digits {
		if digit < '0' || digit > '9' {
			return "", false
		}
	}
	return "+" + digits, true
}

func (s *server) inbox(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'self' "+os.Getenv("SMS_FRAME_ANCESTOR"))
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	data, err := webFiles.ReadFile("web/index.html")
	if err != nil {
		http.Error(w, "page unavailable", 500)
		return
	}
	w.Write(data)
}

func (s *server) asset(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if name != "admin.js" && name != "app.css" && name != "app.js" && name != "attachments.js" && name != "bridged-calls.js" && name != "Roboto-Regular.ttf" && name != "Roboto-Medium.ttf" && name != "Roboto-Bold.ttf" {
		http.NotFound(w, r)
		return
	}
	data, err := webFiles.ReadFile("web/" + name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if strings.HasSuffix(name, ".ttf") {
		w.Header().Set("Content-Type", "font/ttf")
	} else if strings.HasSuffix(name, ".css") {
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
	} else {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	}
	w.Write(data)
}

func (s *server) listNumbers(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("X-Authentik-Username") == "" {
		http.Error(w, "forbidden", 403)
		return
	}
	values, err := s.visibleNumbers(r)
	if err != nil {
		http.Error(w, "numbers unavailable", 503)
		return
	}
	providers, err := s.providers(r.Context())
	if err != nil {
		http.Error(w, "providers unavailable", 503)
		return
	}
	senders := []map[string]string{}
	canSend := false
	for _, number := range sortedCanonical(values) {
		specific := false
		for _, p := range providers {
			if p.ID != "flowroute" && authorizedNumber(number, p.Numbers) {
				specific = true
			}
		}
		for _, p := range providers {
			if p.CanSend && (authorizedNumber(number, p.Numbers) || p.ID == "flowroute" && !specific) {
				senders = append(senders, map[string]string{"number": number, "provider_id": p.ID, "provider_type": p.Type})
				canSend = true
			}
		}
	}
	receiveOnly := false
	for _, p := range providers {
		if p.Enabled && !p.CanSend && (p.CanReceive || p.ID == "flowroute") {
			receiveOnly = true
			break
		}
	}
	writeJSON(w, map[string]any{"numbers": sortedCanonical(values), "groups": s.groups(r), "is_admin": s.isAdmin(r), "can_delete": s.isAdmin(r), "admin_url": s.adminURL(r), "can_send": canSend, "senders": senders, "receive_only": receiveOnly})
}

func (s *server) listMessages(w http.ResponseWriter, r *http.Request) {
	numbers, accessErr := s.visibleNumbers(r)
	if accessErr != nil {
		http.Error(w, "access unavailable", 503)
		return
	}
	if len(numbers) == 0 && s.isAdmin(r) {
		writeJSON(w, []any{})
		return
	}
	if len(numbers) == 0 {
		s.logger.Debug("inbox message list denied", "failure_stage", "missing_authorized_numbers", "response_status", http.StatusForbidden)
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var before time.Time
	if raw := r.URL.Query().Get("before"); raw != "" {
		var err error
		before, err = time.Parse(time.RFC3339Nano, raw)
		if err != nil || r.URL.Query().Get("before_id") == "" {
			http.Error(w, "invalid cursor", 400)
			return
		}
	}
	rows, err := s.pool.Query(r.Context(), `SELECT message_id,sender,recipient,body,received_at,is_mms,direction FROM public.flowroute_inbound_messages WHERE ((direction='inbound' AND recipient = ANY($1)) OR (direction='outbound' AND sender = ANY($1))) AND ($2::timestamptz IS NULL OR (received_at, message_id) < ($2::timestamptz, $3)) ORDER BY received_at DESC, message_id DESC LIMIT 200`, numbers, nullableTime(before), r.URL.Query().Get("before_id"))
	if err != nil {
		s.logger.Warn("inbox message list failed", "failure_stage", "query_messages", "response_status", http.StatusServiceUnavailable)
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
		Direction  string      `json:"direction"`
		Media      []mediaInfo `json:"media"`
	}
	result := make([]inboxMessage, 0)
	for rows.Next() {
		var item inboxMessage
		if err := rows.Scan(&item.ID, &item.Sender, &item.Recipient, &item.Body, &item.ReceivedAt, &item.IsMMS, &item.Direction); err != nil {
			s.logger.Warn("inbox message list failed", "failure_stage", "scan_message", "response_status", http.StatusInternalServerError)
			http.Error(w, "database error", http.StatusInternalServerError)
			return
		}
		if normalized, ok := normalizePhoneNumber(item.Sender); ok {
			item.Sender = normalized
		}
		if normalized, ok := normalizePhoneNumber(item.Recipient); ok {
			item.Recipient = normalized
		}
		item.Media = []mediaInfo{}
		result = append(result, item)
	}
	if rows.Err() != nil {
		s.logger.Warn("inbox message list failed", "failure_stage", "read_messages", "response_status", http.StatusInternalServerError)
		http.Error(w, "database error", http.StatusInternalServerError)
		return
	}
	messageIndexes := make(map[string]int, len(result))
	messageIDs := make([]string, 0, len(result))
	for i := range result {
		messageIndexes[result[i].ID] = i
		messageIDs = append(messageIDs, result[i].ID)
	}
	if len(messageIDs) > 0 {
		mediaRows, err := s.pool.Query(r.Context(), `SELECT message_id,media_id,file_name,mime_type FROM public.flowroute_inbound_media WHERE message_id=ANY($1) UNION ALL SELECT message_id,id,file_name,mime_type FROM public.sms_outbound_media WHERE message_id=ANY($1) ORDER BY media_id`, messageIDs)
		if err != nil {
			s.logger.Warn("inbox message list failed", "failure_stage", "query_media_metadata", "message_count", len(messageIDs), "response_status", http.StatusInternalServerError)
			http.Error(w, "database error", http.StatusInternalServerError)
			return
		}
		defer mediaRows.Close()
		for mediaRows.Next() {
			var messageID string
			var item mediaInfo
			if err := mediaRows.Scan(&messageID, &item.ID, &item.FileName, &item.MIMEType); err != nil {
				s.logger.Warn("inbox message list failed", "failure_stage", "scan_media_metadata", "message_count", len(messageIDs), "response_status", http.StatusInternalServerError)
				http.Error(w, "database error", http.StatusInternalServerError)
				return
			}
			if i, ok := messageIndexes[messageID]; ok {
				result[i].Media = append(result[i].Media, item)
			}
		}
		if mediaRows.Err() != nil {
			s.logger.Warn("inbox message list failed", "failure_stage", "read_media_metadata", "message_count", len(messageIDs), "response_status", http.StatusInternalServerError)
			http.Error(w, "database error", http.StatusInternalServerError)
			return
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(result); err != nil {
		s.logger.Warn("inbox message list response failed", "failure_stage", "encode_response", "message_count", len(result), "response_status", http.StatusOK)
		return
	}
	s.logger.Debug("inbox message list served", "message_count", len(result), "response_status", http.StatusOK)
}

func (s *server) getMedia(w http.ResponseWriter, r *http.Request) {
	numbers, accessErr := s.visibleNumbers(r)
	if accessErr != nil {
		http.Error(w, "access unavailable", 503)
		return
	}
	if len(numbers) == 0 {
		s.logger.Debug("MMS media request denied", "failure_stage", "missing_authorized_numbers", "response_status", http.StatusForbidden)
		http.Error(w, "forbidden", 403)
		return
	}
	var mimeType, fileName, objectKey string
	var content []byte
	err := s.pool.QueryRow(r.Context(), `SELECT mime_type,file_name,object_key,content FROM (
SELECT m.media_id,m.mime_type,m.file_name,COALESCE(m.object_key,'') AS object_key,m.content,msg.direction,msg.sender,msg.recipient
FROM public.flowroute_inbound_media m JOIN public.flowroute_inbound_messages msg USING(message_id)
UNION ALL
SELECT m.id,m.mime_type,m.file_name,m.object_key,NULL,msg.direction,msg.sender,msg.recipient
FROM public.sms_outbound_media m JOIN public.flowroute_inbound_messages msg ON msg.message_id=m.message_id
) media WHERE media.media_id=$1 AND ((direction='inbound' AND recipient=ANY($2)) OR (direction='outbound' AND sender=ANY($2)))`, r.PathValue("id"), numbers).Scan(&mimeType, &fileName, &objectKey, &content)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			s.logger.Debug("MMS media not found or unauthorized", "response_status", http.StatusNotFound)
			http.NotFound(w, r)
			return
		}
		s.logger.Warn("MMS media lookup failed", "failure_stage", "query_media", "response_status", http.StatusServiceUnavailable)
		http.Error(w, "media unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", mimeType)
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("inline", map[string]string{"filename": safeFileName(fileName)}))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	var source io.Reader = bytes.NewReader(content)
	var object io.ReadCloser
	if objectKey != "" {
		if s.mediaStore == nil {
			http.Error(w, "media unavailable", http.StatusServiceUnavailable)
			return
		}
		stored, storeErr := s.mediaStore.client.GetObject(r.Context(), &s3.GetObjectInput{Bucket: aws.String(s.mediaStore.bucket), Key: aws.String(objectKey)})
		if storeErr != nil {
			http.Error(w, "media unavailable", http.StatusNotFound)
			return
		}
		object = stored.Body
		defer object.Close()
		source = object
	}
	written, err := io.CopyN(w, source, maxMediaBytes+1)
	if err == io.EOF {
		err = nil
	}
	if err != nil {
		s.logger.Warn("MMS media response failed", "media_id", r.PathValue("id"), "failure_stage", "stream_media", "mime_type", mimeType, "content_bytes", len(content), "bytes_written", written, "response_status", http.StatusOK)
		return
	}
	s.logger.Debug("MMS media served", "media_id", r.PathValue("id"), "mime_type", mimeType, "content_bytes", len(content), "bytes_written", written, "response_status", http.StatusOK)
}

func nullableBody(body *string) any {
	if body == nil {
		return nil
	}
	return *body
}

func nullableTime(value time.Time) any {
	if value.IsZero() {
		return nil
	}
	return value
}
