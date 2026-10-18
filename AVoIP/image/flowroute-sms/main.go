package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
)

const (
	maxRequestBytes = 1 << 20
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
	ID        string  `json:"id"`
	Body      *string `json:"body"`
	Direction string  `json:"direction"`
	From      string  `json:"from"`
	To        string  `json:"to"`
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
`

const createMessagesIndex = `
CREATE INDEX IF NOT EXISTS flowroute_inbound_messages_recipient_time_idx
    ON public.flowroute_inbound_messages (recipient, received_at DESC)
`

type server struct {
	pool   *pgxpool.Pool
	token  []byte
	logger *slog.Logger
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

	app := &server{pool: pool, token: []byte(callbackToken), logger: logger}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", app.health)
	mux.HandleFunc("GET /readyz", app.ready)
	mux.HandleFunc("POST /flowroute/", app.receive)

	address := os.Getenv("LISTEN_ADDRESS")
	if address == "" {
		address = ":8080"
	}
	httpServer := &http.Server{
		Addr:              address,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
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
	if len(message.ID) > 200 || len(message.From) > 64 || len(message.To) > 64 || (message.Body != nil && len(*message.Body) > 65536) {
		s.reply(w, r, message.ID, "invalid_payload", http.StatusBadRequest)
		return
	}
	if message.Timestamp.IsZero() {
		message.Timestamp = time.Now().UTC()
	}

	var inserted bool
	err = s.pool.QueryRow(r.Context(), `
INSERT INTO public.flowroute_inbound_messages
    (message_id, sender, recipient, body, direction, is_mms, received_at)
VALUES ($1, $2, $3, $4, 'inbound', $5, $6)
ON CONFLICT (message_id) DO NOTHING
RETURNING true`, message.ID, message.From, message.To, nullableBody(message.Body), message.IsMMS, message.Timestamp).Scan(&inserted)
	if errors.Is(err, pgx.ErrNoRows) {
		inserted, err = false, nil
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
	}
	if strings.TrimSpace(message.ID) == "" || strings.TrimSpace(message.From) == "" || strings.TrimSpace(message.To) == "" {
		return inboundMessage{}, errors.New("required callback fields are missing")
	}
	if message.Body == nil && !message.IsMMS {
		return inboundMessage{}, errors.New("SMS body is missing")
	}
	return message, nil
}

func nullableBody(body *string) any {
	if body == nil {
		return nil
	}
	return *body
}
