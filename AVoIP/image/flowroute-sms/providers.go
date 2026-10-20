package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
)

const adminSchema = `
ALTER TABLE public.flowroute_inbound_messages ADD COLUMN IF NOT EXISTS provider_id text NOT NULL DEFAULT 'flowroute';
CREATE TABLE IF NOT EXISTS public.sms_deleted_messages(message_id text PRIMARY KEY,deleted_at timestamptz NOT NULL DEFAULT now(),deleted_by text NOT NULL);
CREATE TABLE IF NOT EXISTS public.sms_providers(id text PRIMARY KEY,configuration jsonb NOT NULL,version bigint NOT NULL DEFAULT 1,updated_at timestamptz NOT NULL DEFAULT now(),updated_by text NOT NULL);
CREATE TABLE IF NOT EXISTS public.avoip_catalog(id boolean PRIMARY KEY DEFAULT true CHECK(id),configuration jsonb NOT NULL,version bigint NOT NULL DEFAULT 1,updated_at timestamptz NOT NULL DEFAULT now(),updated_by text NOT NULL);
CREATE TABLE IF NOT EXISTS public.avoip_admin_audit(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,actor text NOT NULL,action text NOT NULL,object_id text NOT NULL,changed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.avoip_bridged_calls(
    id uuid PRIMARY KEY,
    owner text NOT NULL,
    callback_kind text NOT NULL,
    callback_destination text NOT NULL,
    callback_label text NOT NULL DEFAULT '',
    extension text NOT NULL,
    caller_id text NOT NULL,
    provider_id text NOT NULL,
    scheduled_at timestamptz NOT NULL,
    timezone text NOT NULL,
    status text NOT NULL,
    cancellation_requested boolean NOT NULL DEFAULT false,
    idempotency_key text NOT NULL,
    callback_uuid text NOT NULL,
    extension_uuid text NOT NULL,
    telephony_job_id text NOT NULL DEFAULT '',
    version bigint NOT NULL DEFAULT 1,
    failure_code text NOT NULL DEFAULT '',
    hangup_cause text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    answered_at timestamptz,
    connected_at timestamptz,
    completed_at timestamptz,
    cancelled_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(owner, idempotency_key)
);
CREATE INDEX IF NOT EXISTS avoip_bridged_calls_owner_schedule_idx ON public.avoip_bridged_calls(owner, scheduled_at DESC);
CREATE INDEX IF NOT EXISTS avoip_bridged_calls_dispatch_idx ON public.avoip_bridged_calls(status, scheduled_at);
CREATE TABLE IF NOT EXISTS public.avoip_bridged_call_events(
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    call_id uuid NOT NULL REFERENCES public.avoip_bridged_calls(id) ON DELETE CASCADE,
    event_type text NOT NULL,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.avoip_callback_destinations(
    id uuid PRIMARY KEY,
    owner text NOT NULL,
    label text NOT NULL,
    kind text NOT NULL,
    destination text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(owner, label, destination)
);
`

var providerID = regexp.MustCompile(`^[a-z][a-z0-9-]{0,39}$`)
var credentialName = regexp.MustCompile(`^SMS_PROVIDER_[A-Z0-9_]{1,100}$`)

type smsProvider struct {
	ID           string   `json:"id"`
	Type         string   `json:"type"`
	Name         string   `json:"name"`
	Numbers      []string `json:"numbers"`
	KeyEnv       string   `json:"key_env"`
	SecretEnv    string   `json:"secret_env"`
	PublicKeyEnv string   `json:"public_key_env"`
	WebhookURL   string   `json:"webhook_url"`
	Enabled      bool     `json:"enabled"`
	Version      int64    `json:"version"`
	Source       string   `json:"source"`
	CanSend      bool     `json:"can_send"`
	CanReceive   bool     `json:"can_receive"`
}

func (p smsProvider) credentials() (string, string) {
	if p.Source == "legacy" {
		return os.Getenv("FLOWROUTE_SMS_ACCESS_KEY"), os.Getenv("FLOWROUTE_SMS_SECRET_KEY")
	}
	return os.Getenv(p.KeyEnv), os.Getenv(p.SecretEnv)
}
func (p *smsProvider) validate() error {
	if !providerID.MatchString(p.ID) || len(p.Name) > 100 {
		return errors.New("invalid provider ID or name")
	}
	switch p.Type {
	case "flowroute", "twilio", "telnyx":
	default:
		return errors.New("unsupported provider type")
	}
	if len(p.Numbers) > 1000 {
		return errors.New("too many numbers")
	}
	for _, n := range p.Numbers {
		if v, ok := normalizePhoneNumber(n); !ok || v != n {
			return errors.New("numbers must be canonical E.164")
		}
	}
	p.Numbers = sortedCanonical(p.Numbers)
	for _, name := range []string{p.KeyEnv, p.SecretEnv, p.PublicKeyEnv} {
		if name != "" && !credentialName.MatchString(name) {
			return errors.New("credentials must reference SMS_PROVIDER_ environment names")
		}
	}
	if p.KeyEnv == "" || ((p.Type == "twilio" || p.Type == "flowroute") && p.SecretEnv == "") {
		return errors.New("credential references required")
	}
	if p.WebhookURL != "" {
		u, err := url.Parse(p.WebhookURL)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "/providers/"+p.ID+"/inbound" {
			return errors.New("webhook URL must be HTTPS with the provider inbound path and no query")
		}
	}
	if p.Type == "telnyx" && p.WebhookURL != "" && p.PublicKeyEnv == "" {
		return errors.New("Telnyx webhook public-key reference required")
	}
	if p.ID == "flowroute" {
		return errors.New("flowroute is reserved for the legacy configured account; use another ID")
	}
	return nil
}
func configuredProviders() ([]smsProvider, error) {
	result := []smsProvider{}
	raw := strings.TrimSpace(os.Getenv("SMS_PROVIDERS_JSON"))
	if raw != "" {
		dec := json.NewDecoder(strings.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&result); err != nil || dec.Decode(new(any)) != io.EOF {
			return nil, errors.New("invalid SMS_PROVIDERS_JSON")
		}
	}
	seen := map[string]bool{}
	for i := range result {
		if err := result[i].validate(); err != nil {
			return nil, err
		}
		if seen[result[i].ID] {
			return nil, errors.New("duplicate configured provider")
		}
		seen[result[i].ID] = true
		result[i].Source = "config"
	}
	if os.Getenv("FLOWROUTE_ENABLED") != "false" {
		result = append(result, smsProvider{ID: "flowroute", Type: "flowroute", Name: "Flowroute (existing account)", Enabled: true, Source: "legacy", Numbers: sortedCanonical(strings.Split(os.Getenv("SMS_LOCAL_NUMBERS"), ","))})
	}
	return result, nil
}
func (s *server) providers(ctx context.Context) ([]smsProvider, error) {
	config, err := configuredProviders()
	if err != nil {
		return nil, err
	}
	result := map[string]smsProvider{}
	for _, p := range config {
		result[p.ID] = p
	}
	rows, err := s.pool.Query(ctx, `SELECT configuration,version FROM public.sms_providers ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var data []byte
		var p smsProvider
		var version int64
		if err = rows.Scan(&data, &version); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(data, &p); err != nil {
			return nil, errors.New("invalid stored provider")
		}
		if err = p.validate(); err != nil {
			return nil, errors.New("invalid stored provider")
		}
		if _, exists := result[p.ID]; exists {
			continue
		}
		p.Version = version
		p.Source = "admin"
		result[p.ID] = p
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	providers := make([]smsProvider, 0, len(result))
	for _, p := range result {
		key, secret := p.credentials()
		p.CanSend = p.Enabled && key != "" && (p.Type == "telnyx" || secret != "")
		p.CanReceive = p.Enabled && p.WebhookURL != "" && (p.Type == "twilio" && secret != "" || p.Type == "telnyx" && os.Getenv(p.PublicKeyEnv) != "")
		providers = append(providers, p)
	}
	sort.Slice(providers, func(i, j int) bool { return providers[i].ID < providers[j].ID })
	return providers, nil
}
func (s *server) listProviders(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, false) {
		return
	}
	p, err := s.providers(r.Context())
	if err != nil {
		http.Error(w, "providers unavailable", 503)
		return
	}
	writeJSON(w, p)
}
func (s *server) saveProvider(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, true) {
		return
	}
	var p smsProvider
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536))
	dec.DisallowUnknownFields()
	if dec.Decode(&p) != nil || dec.Decode(new(any)) != io.EOF || p.ID != r.PathValue("id") {
		http.Error(w, "invalid provider", 400)
		return
	}
	if err := p.validate(); err != nil {
		http.Error(w, err.Error(), 422)
		return
	}
	cfg, err := configuredProviders()
	if err != nil {
		http.Error(w, "configuration unavailable", 503)
		return
	}
	for _, c := range cfg {
		if c.ID == p.ID {
			http.Error(w, "provider is managed by configuration", 409)
			return
		}
	}
	version := p.Version
	p.Source = ""
	p.Version = 0
	p.CanSend = false
	p.CanReceive = false
	data, _ := json.Marshal(p)
	tx, err := s.pool.Begin(r.Context())
	if err != nil {
		http.Error(w, "database unavailable", 503)
		return
	}
	defer tx.Rollback(r.Context())
	if version == 0 {
		err = tx.QueryRow(r.Context(), `INSERT INTO public.sms_providers(id,configuration,updated_by) VALUES($1,$2,$3) ON CONFLICT DO NOTHING RETURNING version`, p.ID, data, r.Header.Get("X-Authentik-Username")).Scan(&p.Version)
	} else {
		err = tx.QueryRow(r.Context(), `UPDATE public.sms_providers SET configuration=$2,version=version+1,updated_at=now(),updated_by=$3 WHERE id=$1 AND version=$4 RETURNING version`, p.ID, data, r.Header.Get("X-Authentik-Username"), version).Scan(&p.Version)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		http.Error(w, "provider changed; reload before saving", 409)
		return
	}
	if err == nil {
		_, err = tx.Exec(r.Context(), `INSERT INTO public.avoip_admin_audit(actor,action,object_id) VALUES($1,'provider_saved',$2)`, r.Header.Get("X-Authentik-Username"), p.ID)
	}
	if err == nil {
		err = tx.Commit(r.Context())
	}
	if err != nil {
		http.Error(w, "save failed", 503)
		return
	}
	p.Source = "admin"
	writeJSON(w, p)
}
func (s *server) deleteProvider(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, true) {
		return
	}
	id := r.PathValue("id")
	if !providerID.MatchString(id) {
		http.Error(w, "invalid provider", 400)
		return
	}
	config, err := configuredProviders()
	if err != nil {
		http.Error(w, "configuration unavailable", 503)
		return
	}
	for _, p := range config {
		if p.ID == id {
			http.Error(w, "provider is managed by configuration", 409)
			return
		}
	}
	tx, err := s.pool.Begin(r.Context())
	if err != nil {
		http.Error(w, "database unavailable", 503)
		return
	}
	defer tx.Rollback(r.Context())
	_, err = tx.Exec(r.Context(), `DELETE FROM public.sms_providers WHERE id=$1`, id)
	if err == nil {
		_, err = tx.Exec(r.Context(), `INSERT INTO public.avoip_admin_audit(actor,action,object_id) VALUES($1,'provider_deleted',$2)`, r.Header.Get("X-Authentik-Username"), id)
	}
	if err == nil {
		err = tx.Commit(r.Context())
	}
	if err != nil {
		http.Error(w, "delete failed", 503)
		return
	}
	w.WriteHeader(204)
}
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}
func chooseProvider(providers []smsProvider, from, requested string) (smsProvider, error) {
	matches := []smsProvider{}
	specific := false
	var legacy smsProvider
	for _, p := range providers {
		if p.ID != "flowroute" && authorizedNumber(from, p.Numbers) {
			specific = true
		}
		if p.ID == "flowroute" {
			legacy = p
		}
		if p.Enabled && authorizedNumber(from, p.Numbers) && (requested == "" || p.ID == requested) {
			matches = append(matches, p)
		}
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	if len(matches) > 1 {
		return smsProvider{}, errors.New("choose a provider for this number")
	}
	if !specific && (requested == "" || requested == "flowroute") && legacy.Enabled {
		return legacy, nil
	}
	return smsProvider{}, errors.New("provider unavailable for this number")
}
func (s *server) transmit(ctx context.Context, p smsProvider, from, to, body string, mediaURLs []string) (string, error) {
	key, secret := p.credentials()
	if key == "" || p.Type != "telnyx" && secret == "" {
		return "", errors.New("provider credentials unavailable")
	}
	endpoint := flowrouteSendURL
	contentType := "application/vnd.api+json"
	var payload []byte
	switch p.Type {
	case "flowroute":
		payload, _ = json.Marshal(map[string]any{"data": map[string]any{"type": "message", "attributes": map[string]string{"from": from, "to": to, "body": body}}})
	case "twilio":
		if !regexp.MustCompile(`^AC[0-9a-fA-F]{32}$`).MatchString(key) {
			return "", errors.New("invalid Twilio account")
		}
		endpoint = "https://api.twilio.com/2010-04-01/Accounts/" + key + "/Messages.json"
		contentType = "application/x-www-form-urlencoded"
		form := url.Values{"From": {from}, "To": {to}}
		if body != "" {
			form.Set("Body", body)
		}
		for _, mediaURL := range mediaURLs {
			form.Add("MediaUrl", mediaURL)
		}
		payload = []byte(form.Encode())
	case "telnyx":
		endpoint = "https://api.telnyx.com/v2/messages"
		contentType = "application/json"
		payload, _ = json.Marshal(map[string]string{"from": from, "to": to, "text": body})
	default:
		return "", errors.New("unsupported provider")
	}
	req, err := http.NewRequestWithContext(ctx, "POST", endpoint, bytes.NewReader(payload))
	if err != nil {
		return "", errors.New("provider request unavailable")
	}
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("Accept", "application/json")
	if p.Type == "telnyx" {
		req.Header.Set("Authorization", "Bearer "+key)
	} else {
		req.SetBasicAuth(key, secret)
	}
	resp, err := s.sendClient.Do(req)
	if err != nil {
		return "", errors.New("provider connection failed; acceptance unknown, do not automatically resend")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 && resp.StatusCode != 201 && resp.StatusCode != 202 {
		return "", fmt.Errorf("provider rejected message (HTTP %d)", resp.StatusCode)
	}
	var response struct {
		SID  string `json:"sid"`
		Data struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 65536)).Decode(&response) != nil {
		return "", errors.New("provider response invalid; acceptance unknown")
	}
	id := response.Data.ID
	if p.Type == "twilio" {
		id = response.SID
	}
	if id == "" || len(id) > 140 {
		return "", errors.New("provider response missing ID; acceptance unknown")
	}
	if p.ID != "flowroute" {
		id = p.ID + ":" + id
	}
	return id, nil
}
