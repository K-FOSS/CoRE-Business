package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata"

	"github.com/jackc/pgx/v5"
)

const (
	callScheduled            = "Scheduled"
	callCallingYou           = "Calling you"
	callAwaitingConfirmation = "Awaiting confirmation"
	callCallingExtension     = "Calling extension"
	callConnected            = "Connected"
	callCompleted            = "Completed"
	callCancelled            = "Cancelled"
	callFailed               = "Failed"
	callNoAnswer             = "No answer"
	callBusy                 = "Busy"
)

var ianaTimezone = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_+.-]*(/[A-Za-z0-9_+.-]+)+$`)
var idempotencyKey = regexp.MustCompile(`^[A-Za-z0-9._:-]{8,160}$`)

type bridgedCallCreate struct {
	Mode                  string `json:"mode"`
	CallbackKind          string `json:"callback_kind"`
	CallbackDestinationID string `json:"callback_destination_id,omitempty"`
	CallbackNumber        string `json:"callback_number,omitempty"`
	CallbackLabel         string `json:"callback_label,omitempty"`
	Extension             string `json:"extension"`
	CallerID              string `json:"caller_id"`
	ScheduledAt           string `json:"scheduled_at,omitempty"`
	Timezone              string `json:"timezone"`
	ConfirmationRequired  *bool  `json:"confirmation_required,omitempty"`
	IdempotencyKey        string `json:"idempotency_key"`
}

type bridgedCall struct {
	ID                    string     `json:"id"`
	Owner                 string     `json:"owner,omitempty"`
	InitiatorDisplayName  string     `json:"-"`
	PromptFile            string     `json:"-"`
	CallbackKind          string     `json:"callback_kind"`
	CallbackDestination   string     `json:"callback_destination"`
	CallbackLabel         string     `json:"callback_label"`
	Extension             string     `json:"extension"`
	CallerID              string     `json:"caller_id"`
	ScheduledAt           time.Time  `json:"scheduled_at"`
	Timezone              string     `json:"timezone"`
	Status                string     `json:"status"`
	CancellationRequested bool       `json:"cancellation_requested"`
	FailureCode           string     `json:"failure_code,omitempty"`
	HangupCause           string     `json:"hangup_cause,omitempty"`
	CallbackUUID          string     `json:"callback_uuid,omitempty"`
	ExtensionUUID         string     `json:"extension_uuid,omitempty"`
	CreatedAt             time.Time  `json:"created_at"`
	StartedAt             *time.Time `json:"started_at,omitempty"`
	AnsweredAt            *time.Time `json:"answered_at,omitempty"`
	ConnectedAt           *time.Time `json:"connected_at,omitempty"`
	CompletedAt           *time.Time `json:"completed_at,omitempty"`
	CancelledAt           *time.Time `json:"cancelled_at,omitempty"`
}

func (s *server) requireUser(w http.ResponseWriter, r *http.Request, mutation bool) bool {
	if os.Getenv("AVOIP_BRIDGED_CALLS_ENABLED") != "true" {
		http.NotFound(w, r)
		return false
	}
	if strings.TrimSpace(r.Header.Get("X-Authentik-Username")) == "" || (mutation && !sameOrigin(r)) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return false
	}
	return true
}

func (s *server) bridgedCallsPage(w http.ResponseWriter, r *http.Request) {
	if !s.requireUser(w, r, false) {
		return
	}
	data, err := webFiles.ReadFile("web/bridged-calls.html")
	if err != nil {
		http.Error(w, "page unavailable", 500)
		return
	}
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'self'")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(data)
}

func (s *server) registerBridgedCalls(mux *http.ServeMux) {
	mux.HandleFunc("GET /calls", s.bridgedCallsPage)
	mux.HandleFunc("GET /api/calls/options", s.callOptions)
	mux.HandleFunc("POST /api/callback-destinations", s.saveCallbackDestination)
	mux.HandleFunc("GET /api/calls", s.listBridgedCalls)
	mux.HandleFunc("GET /api/calls/{id}", func(w http.ResponseWriter, r *http.Request) {
		if s.requireUser(w, r, false) {
			s.writeCallByID(w, r, r.PathValue("id"))
		}
	})
	mux.HandleFunc("POST /api/calls", s.createBridgedCall)
	mux.HandleFunc("POST /api/calls/{id}/cancel", s.cancelBridgedCall)
	mux.HandleFunc("POST /api/calls/{id}/reschedule", s.rescheduleBridgedCall)
	mux.HandleFunc("GET /metrics", s.bridgedCallMetrics)
}

func (s *server) bridgedCallMetrics(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	rows, err := s.pool.Query(r.Context(), `SELECT status,count(*) FROM public.avoip_bridged_calls GROUP BY status`)
	if err != nil {
		http.Error(w, "metrics unavailable", 503)
		return
	}
	defer rows.Close()
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	for rows.Next() {
		var status string
		var count int64
		if rows.Scan(&status, &count) == nil {
			fmt.Fprintf(w, "avoip_bridged_calls{status=%q} %d\n", status, count)
		}
	}
	var active int64
	if s.pool.QueryRow(r.Context(), `SELECT count(*) FROM public.avoip_bridged_calls WHERE status='Connected'`).Scan(&active) == nil {
		fmt.Fprintf(w, "avoip_bridged_active_bridges %d\n", active)
	}
}

func (s *server) saveCallbackDestination(w http.ResponseWriter, r *http.Request) {
	if !s.requireUser(w, r, true) {
		return
	}
	var input struct {
		Label       string `json:"label"`
		Kind        string `json:"kind"`
		Destination string `json:"destination"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 2048)).Decode(&input) != nil || len(strings.TrimSpace(input.Label)) < 1 || len(input.Label) > 80 {
		http.Error(w, "invalid callback destination", 400)
		return
	}
	value, ok := normalizePhoneNumber(input.Destination)
	if input.Kind == "internal" {
		value = strings.TrimSpace(input.Destination)
		ok = extensionID.MatchString(value)
	}
	if !ok || (input.Kind != "internal" && input.Kind != "external") {
		http.Error(w, "callback destination is not permitted", 400)
		return
	}
	if !s.isAdmin(r) && input.Kind == "external" && !containsString(numberVariants(s.allowedNumbers(r)), value) {
		http.Error(w, "callback destination is not permitted", 403)
		return
	}
	id := newUUID()
	_, err := s.pool.Exec(r.Context(), `INSERT INTO public.avoip_callback_destinations(id,owner,label,kind,destination) VALUES($1,$2,$3,$4,$5) ON CONFLICT(owner,label,destination) DO NOTHING`, id, r.Header.Get("X-Authentik-Username"), strings.TrimSpace(input.Label), input.Kind, value)
	if err != nil {
		http.Error(w, "callback destination could not be saved", 503)
		return
	}
	writeJSON(w, map[string]string{"id": id, "label": strings.TrimSpace(input.Label), "kind": input.Kind, "destination": value})
}

func (s *server) callOptions(w http.ResponseWriter, r *http.Request) {
	if !s.requireUser(w, r, false) {
		return
	}
	catalog, _, err := s.cachedCatalog()
	if err != nil {
		http.Error(w, "routing policy unavailable", 503)
		return
	}
	user := r.Header.Get("X-Authentik-Username")
	admin := s.isAdmin(r)
	numbers := s.allowedNumbers(r)
	owned := map[string]bool{}
	for _, n := range numberVariants(numbers) {
		owned[n] = true
	}
	extensions := []map[string]string{}
	callerIDs := map[string]bool{}
	for _, e := range catalog.Extensions {
		if e.Enabled != nil && !*e.Enabled {
			continue
		}
		name := e.DisplayName
		if name == "" {
			name = "Extension " + e.Extension
		}
		extensions = append(extensions, map[string]string{"number": e.Extension, "name": name})
		for _, id := range e.callerIDs() {
			if admin || owned[id] || owned[strings.TrimPrefix(id, "+")] {
				callerIDs[id] = true
			}
		}
	}
	rows, err := s.pool.Query(r.Context(), `SELECT id::text,label,kind,destination FROM public.avoip_callback_destinations WHERE owner=$1 ORDER BY label`, user)
	if err != nil {
		http.Error(w, "options unavailable", 503)
		return
	}
	defer rows.Close()
	saved := []map[string]string{}
	for rows.Next() {
		var id, label, kind, destination string
		if rows.Scan(&id, &label, &kind, &destination) == nil {
			saved = append(saved, map[string]string{"id": id, "label": label, "kind": kind, "destination": destination})
		}
	}
	writeJSON(w, map[string]any{"extensions": extensions, "caller_ids": sortedCanonical(mapKeys(callerIDs)), "callback_numbers": sortedCanonical(numbers), "saved_destinations": saved, "timezone": defaultTimezone(r), "confirmation_required": true})
}

func mapKeys(values map[string]bool) []string {
	result := make([]string, 0, len(values))
	for value := range values {
		result = append(result, value)
	}
	return result
}

func defaultTimezone(r *http.Request) string {
	if value := strings.TrimSpace(r.Header.Get("X-User-Timezone")); ianaTimezone.MatchString(value) {
		return value
	}
	return "America/Vancouver"
}

func (s *server) createBridgedCall(w http.ResponseWriter, r *http.Request) {
	if !s.requireUser(w, r, true) {
		return
	}
	user := r.Header.Get("X-Authentik-Username")
	displayName := authenticatedDisplayName(r)
	r.Body = http.MaxBytesReader(w, r.Body, 8192)
	var input bridgedCallCreate
	if json.NewDecoder(r.Body).Decode(&input) != nil || !idempotencyKey.MatchString(input.IdempotencyKey) {
		http.Error(w, "invalid request or idempotency key", 400)
		return
	}
	if input.Mode != "now" && input.Mode != "schedule" {
		http.Error(w, "mode must be now or schedule", 400)
		return
	}
	if input.Timezone == "" {
		input.Timezone = defaultTimezone(r)
	}
	if !ianaTimezone.MatchString(input.Timezone) {
		http.Error(w, "timezone must be an explicit IANA timezone", 400)
		return
	}
	var existingID string
	if err := s.pool.QueryRow(r.Context(), `SELECT id::text FROM public.avoip_bridged_calls WHERE owner=$1 AND idempotency_key=$2`, user, input.IdempotencyKey).Scan(&existingID); err == nil {
		s.writeCallByID(w, r, existingID)
		return
	}
	loc, err := time.LoadLocation(input.Timezone)
	if err != nil {
		http.Error(w, "invalid timezone", 400)
		return
	}
	executeAt := time.Now().UTC()
	if input.Mode == "schedule" {
		local, err := parseScheduleLocal(input.ScheduledAt, loc)
		if err != nil || local.Before(time.Now().In(loc).Add(30*time.Second)) {
			http.Error(w, "scheduled time is invalid, ambiguous, nonexistent, or in the past", 400)
			return
		}
		executeAt = local.UTC()
	}
	horizonDays := 30
	if value, err := strconv.Atoi(strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_SCHEDULING_HORIZON_DAYS"))); err == nil && value > 0 {
		horizonDays = value
	}
	if executeAt.After(time.Now().UTC().Add(time.Duration(horizonDays) * 24 * time.Hour)) {
		http.Error(w, "scheduled time exceeds the scheduling horizon", 400)
		return
	}
	limit := 2
	if value, err := strconv.Atoi(strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_PER_USER_CONCURRENCY"))); err == nil && value > 0 {
		limit = value
	}
	var active int
	if err := s.pool.QueryRow(r.Context(), `SELECT count(*) FROM public.avoip_bridged_calls WHERE owner=$1 AND status IN ('Scheduled','Calling you','Awaiting confirmation','Calling extension','Connected')`, user).Scan(&active); err == nil && active >= limit {
		http.Error(w, "your call limit is reached", 429)
		return
	}
	catalog, _, err := s.cachedCatalog()
	if err != nil {
		http.Error(w, "routing policy unavailable", 503)
		return
	}
	extension, err := authorizedExtension(catalog, input.Extension)
	if err != nil {
		http.Error(w, "extension is not available", 403)
		return
	}
	callback, provider, err := s.authorizeCallDestination(r, catalog, input, extension)
	if err != nil {
		http.Error(w, err.Error(), 403)
		return
	}
	if input.CallbackKind == "saved" {
		var kind string
		if err := s.pool.QueryRow(r.Context(), `SELECT kind FROM public.avoip_callback_destinations WHERE id=$1`, input.CallbackDestinationID).Scan(&kind); err == nil {
			input.CallbackKind = kind
		}
	}
	if !adminCanUseCallerID(s, r, extension, input.CallerID) {
		http.Error(w, "caller ID is not authorized", 403)
		return
	}
	callbackUUID := newUUID()
	extensionUUID := newUUID()
	callID := newUUID()
	status := callScheduled
	if input.Mode == "now" {
		status = callScheduled
		executeAt = time.Now().UTC()
	}
	query := `INSERT INTO public.avoip_bridged_calls(id,owner,initiator_display_name,callback_kind,callback_destination,callback_label,extension,caller_id,provider_id,scheduled_at,timezone,status,idempotency_key,callback_uuid,extension_uuid) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) ON CONFLICT(owner,idempotency_key) DO NOTHING RETURNING id`
	var inserted string
	err = s.pool.QueryRow(r.Context(), query, callID, user, displayName, input.CallbackKind, callback, input.CallbackLabel, extension.Extension, input.CallerID, provider.ID, executeAt, input.Timezone, status, input.IdempotencyKey, callbackUUID, extensionUUID).Scan(&inserted)
	if errors.Is(err, pgx.ErrNoRows) {
		if s.pool.QueryRow(r.Context(), `SELECT id::text FROM public.avoip_bridged_calls WHERE owner=$1 AND idempotency_key=$2`, user, input.IdempotencyKey).Scan(&inserted) == nil {
			s.writeCallByID(w, r, inserted)
			return
		}
		http.Error(w, "call already exists", 409)
		return
	}
	if err != nil {
		http.Error(w, "call could not be saved", 503)
		return
	}
	_, _ = s.pool.Exec(r.Context(), `INSERT INTO public.avoip_bridged_call_events(call_id,event_type,detail) VALUES($1,'created',$2)`, callID, json.RawMessage(`{"mode":"`+input.Mode+`"}`))
	if input.Mode == "now" {
		go s.dispatchBridgedCall(context.Background(), callID)
	}
	s.logger.Info("bridged call created", "call_id", callID, "owner", user, "extension", extension.Extension, "callback_kind", input.CallbackKind, "status", status)
	s.writeCallByID(w, r, inserted)
}

func authenticatedDisplayName(r *http.Request) string {
	value := strings.TrimSpace(r.Header.Get("X-Authentik-Name"))
	if value == "" {
		value = strings.TrimSpace(r.Header.Get("X-Authentik-Username"))
	}
	value = strings.Map(func(ch rune) rune {
		if ch < 0x20 || strings.ContainsRune(",={}\r\n", ch) {
			return -1
		}
		return ch
	}, value)
	value = strings.TrimSpace(value)
	if len(value) > 80 {
		value = value[:80]
	}
	if value == "" {
		return "CoRE user"
	}
	return value
}

func parseScheduleLocal(value string, loc *time.Location) (time.Time, error) {
	wall, err := time.ParseInLocation("2006-01-02T15:04", value, time.UTC)
	if err != nil {
		return time.Time{}, err
	}
	offsets := map[int]bool{}
	for delta := -36; delta <= 36; delta++ {
		_, offset := wall.Add(time.Duration(delta) * time.Hour).In(loc).Zone()
		offsets[offset] = true
	}
	var matches []time.Time
	for offset := range offsets {
		candidate := wall.Add(-time.Duration(offset) * time.Second)
		if candidate.In(loc).Format("2006-01-02T15:04") == value {
			matches = append(matches, candidate)
		}
	}
	if len(matches) != 1 {
		return time.Time{}, errors.New("ambiguous or nonexistent local time")
	}
	return matches[0], nil
}

func authorizedExtension(c sipCatalog, number string) (extensionRoute, error) {
	for _, e := range c.Extensions {
		if e.Extension == number && (e.Enabled == nil || *e.Enabled) {
			return e, nil
		}
	}
	return extensionRoute{}, errors.New("extension is not available")
}

func (s *server) authorizeCallDestination(r *http.Request, c sipCatalog, input bridgedCallCreate, extension extensionRoute) (string, sipProvider, error) {
	if input.CallbackKind == "internal" {
		if _, err := authorizedExtension(c, input.CallbackNumber); err != nil {
			return "", sipProvider{}, errors.New("callback endpoint is not authorized")
		}
		return input.CallbackNumber, sipProvider{ID: "asterisk"}, nil
	}
	var number string
	if input.CallbackKind == "saved" {
		var owner, kind string
		if err := s.pool.QueryRow(r.Context(), `SELECT owner,kind,destination FROM public.avoip_callback_destinations WHERE id=$1`, input.CallbackDestinationID).Scan(&owner, &kind, &number); err != nil || owner != r.Header.Get("X-Authentik-Username") {
			return "", sipProvider{}, errors.New("callback destination is not authorized")
		}
		if kind == "internal" {
			return number, sipProvider{ID: "asterisk"}, nil
		}
	} else {
		number = input.CallbackNumber
	}
	normalized, ok := normalizePhoneNumber(number)
	if !ok {
		return "", sipProvider{}, errors.New("callback number is invalid")
	}
	if !s.isAdmin(r) && !containsString(numberVariants(s.allowedNumbers(r)), normalized) {
		return "", sipProvider{}, errors.New("callback number is not authorized")
	}
	for _, p := range c.Providers {
		for _, candidate := range extension.providers() {
			if p.ID == candidate && p.Gateways[os.Getenv("AVOIP_SITE")] != "" {
				for _, id := range extension.callerIDs() {
					if id == input.CallerID {
						return normalized, p, nil
					}
				}
			}
		}
	}
	return "", sipProvider{}, errors.New("no authorized carrier route")
}

func adminCanUseCallerID(s *server, r *http.Request, e extensionRoute, caller string) bool {
	if !plusOneNumber.MatchString(caller) {
		return false
	}
	if !containsString(e.callerIDs(), caller) {
		return false
	}
	return s.isAdmin(r) || containsString(numberVariants(s.allowedNumbers(r)), caller) || containsString(numberVariants(s.allowedNumbers(r)), strings.TrimPrefix(caller, "+"))
}

func (s *server) listBridgedCalls(w http.ResponseWriter, r *http.Request) {
	if !s.requireUser(w, r, false) {
		return
	}
	user := r.Header.Get("X-Authentik-Username")
	query := `SELECT id::text,owner,initiator_display_name,callback_kind,callback_destination,callback_label,extension,caller_id,scheduled_at,timezone,status,cancellation_requested,failure_code,hangup_cause,created_at,started_at,answered_at,connected_at,completed_at,cancelled_at,callback_uuid,extension_uuid FROM public.avoip_bridged_calls WHERE owner=$1`
	args := []any{user}
	if s.isAdmin(r) && r.URL.Query().Get("all") == "true" {
		query = `SELECT id::text,owner,initiator_display_name,callback_kind,callback_destination,callback_label,extension,caller_id,scheduled_at,timezone,status,cancellation_requested,failure_code,hangup_cause,created_at,started_at,answered_at,connected_at,completed_at,cancelled_at,callback_uuid,extension_uuid FROM public.avoip_bridged_calls`
		args = nil
	}
	query += ` ORDER BY scheduled_at DESC LIMIT 100`
	rows, err := s.pool.Query(r.Context(), query, args...)
	if err != nil {
		http.Error(w, "calls unavailable", 503)
		return
	}
	defer rows.Close()
	result := []bridgedCall{}
	for rows.Next() {
		var call bridgedCall
		if rows.Scan(&call.ID, &call.Owner, &call.InitiatorDisplayName, &call.CallbackKind, &call.CallbackDestination, &call.CallbackLabel, &call.Extension, &call.CallerID, &call.ScheduledAt, &call.Timezone, &call.Status, &call.CancellationRequested, &call.FailureCode, &call.HangupCause, &call.CreatedAt, &call.StartedAt, &call.AnsweredAt, &call.ConnectedAt, &call.CompletedAt, &call.CancelledAt, &call.CallbackUUID, &call.ExtensionUUID) == nil {
			result = append(result, call)
		}
	}
	writeJSON(w, result)
}

func (s *server) bridgedCallWorker(ctx context.Context) {
	if rows, err := s.pool.Query(ctx, `SELECT id::text FROM public.avoip_bridged_calls WHERE status IN ('Calling you','Awaiting confirmation','Calling extension','Connected')`); err == nil {
		for rows.Next() {
			var id string
			if rows.Scan(&id) == nil {
				go s.reconcileBridgedCall(id)
			}
		}
		rows.Close()
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			rows, err := s.pool.Query(ctx, `WITH claimed AS (SELECT id FROM public.avoip_bridged_calls WHERE status=$1 AND scheduled_at <= now() AND scheduled_at >= now() - interval '15 minutes' ORDER BY scheduled_at FOR UPDATE SKIP LOCKED LIMIT 8) UPDATE public.avoip_bridged_calls c SET status=$2,started_at=COALESCE(started_at,now()),updated_at=now(),version=version+1 FROM claimed WHERE c.id=claimed.id RETURNING c.id::text`, callScheduled, callCallingYou)
			if err != nil {
				s.logger.Error("bridged call scheduler claim failed", "reason", safeInterfaceError(err))
				continue
			}
			ids := []string{}
			for rows.Next() {
				var id string
				if rows.Scan(&id) == nil {
					ids = append(ids, id)
				}
			}
			rows.Close()
			for _, id := range ids {
				go s.dispatchClaimedBridgedCall(ctx, id)
			}
			_, _ = s.pool.Exec(ctx, `UPDATE public.avoip_bridged_calls SET status=$1,failure_code='missed',completed_at=now(),updated_at=now(),version=version+1 WHERE status=$2 AND scheduled_at < now() - interval '15 minutes'`, callFailed, callScheduled)
		}
	}
}
func (s *server) dispatchClaimedBridgedCall(ctx context.Context, id string) {
	s.dispatchBridgedCall(ctx, id)
}

func (s *server) writeCallByID(w http.ResponseWriter, r *http.Request, id string) {
	var call bridgedCall
	err := s.pool.QueryRow(r.Context(), `SELECT id::text,owner,initiator_display_name,callback_kind,callback_destination,callback_label,extension,caller_id,scheduled_at,timezone,status,cancellation_requested,failure_code,hangup_cause,created_at,started_at,answered_at,connected_at,completed_at,cancelled_at,callback_uuid,extension_uuid FROM public.avoip_bridged_calls WHERE id=$1 AND (owner=$2 OR $3)`, id, r.Header.Get("X-Authentik-Username"), s.isAdmin(r)).Scan(&call.ID, &call.Owner, &call.InitiatorDisplayName, &call.CallbackKind, &call.CallbackDestination, &call.CallbackLabel, &call.Extension, &call.CallerID, &call.ScheduledAt, &call.Timezone, &call.Status, &call.CancellationRequested, &call.FailureCode, &call.HangupCause, &call.CreatedAt, &call.StartedAt, &call.AnsweredAt, &call.ConnectedAt, &call.CompletedAt, &call.CancelledAt, &call.CallbackUUID, &call.ExtensionUUID)
	if err != nil {
		http.Error(w, "call unavailable", 404)
		return
	}
	writeJSON(w, call)
}

func (s *server) cancelBridgedCall(w http.ResponseWriter, r *http.Request) {
	if !s.requireUser(w, r, true) {
		return
	}
	id := r.PathValue("id")
	user := r.Header.Get("X-Authentik-Username")
	tag := s.isAdmin(r)
	tx, err := s.pool.Begin(r.Context())
	if err != nil {
		http.Error(w, "database unavailable", 503)
		return
	}
	defer tx.Rollback(r.Context())
	var callback, extension, status string
	err = tx.QueryRow(r.Context(), `SELECT callback_uuid,extension_uuid,status FROM public.avoip_bridged_calls WHERE id=$1 AND (owner=$2 OR $3) FOR UPDATE`, id, user, tag).Scan(&callback, &extension, &status)
	if err != nil {
		http.Error(w, "call not found", 404)
		return
	}
	if status == callScheduled {
		_, err = tx.Exec(r.Context(), `UPDATE public.avoip_bridged_calls SET status=$2,cancelled_at=now(),completed_at=now(),version=version+1,updated_at=now() WHERE id=$1`, id, callCancelled)
	} else if status != callCompleted && status != callCancelled && status != callFailed && status != callNoAnswer && status != callBusy {
		_, err = tx.Exec(r.Context(), `UPDATE public.avoip_bridged_calls SET cancellation_requested=true,version=version+1,updated_at=now() WHERE id=$1`, id)
	}
	if err == nil {
		err = tx.Commit(r.Context())
	}
	if err != nil {
		http.Error(w, "cancel failed", 503)
		return
	}
	s.logger.Info("bridged call cancellation requested", "call_id", id, "owner", user)
	go s.killCallLegs(callback, extension)
	s.writeCallByID(w, r, id)
}

func (s *server) rescheduleBridgedCall(w http.ResponseWriter, r *http.Request) {
	if !s.requireUser(w, r, true) {
		return
	}
	var body struct{ ScheduledAt, Timezone string }
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 2048)).Decode(&body) != nil {
		http.Error(w, "invalid schedule", 400)
		return
	}
	loc, err := time.LoadLocation(body.Timezone)
	if err != nil {
		http.Error(w, "invalid timezone", 400)
		return
	}
	at, err := parseScheduleLocal(body.ScheduledAt, loc)
	if err != nil || at.Before(time.Now().Add(30*time.Second)) {
		http.Error(w, "invalid schedule", 400)
		return
	}
	horizonDays := 30
	if value, parseErr := strconv.Atoi(strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_SCHEDULING_HORIZON_DAYS"))); parseErr == nil && value > 0 {
		horizonDays = value
	}
	if at.After(time.Now().Add(time.Duration(horizonDays) * 24 * time.Hour)) {
		http.Error(w, "scheduled time exceeds the scheduling horizon", 400)
		return
	}
	tag := s.isAdmin(r)
	_, err = s.pool.Exec(r.Context(), `UPDATE public.avoip_bridged_calls SET scheduled_at=$1,timezone=$2,status=$3,version=version+1,updated_at=now() WHERE id=$4 AND (owner=$5 OR $6) AND status=$7`, at.UTC(), body.Timezone, callScheduled, r.PathValue("id"), r.Header.Get("X-Authentik-Username"), tag, callScheduled)
	if err != nil {
		http.Error(w, "reschedule failed or call is no longer pending", 409)
		return
	}
	s.writeCallByID(w, r, r.PathValue("id"))
}

func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		fallback := fmt.Sprintf("%032x", time.Now().UnixNano())
		return fallback[0:8] + "-" + fallback[8:12] + "-4" + fallback[13:16] + "-8" + fallback[17:20] + "-" + fallback[20:32]
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%s-%s-%s-%s-%s", hex.EncodeToString(b[:4]), hex.EncodeToString(b[4:6]), hex.EncodeToString(b[6:8]), hex.EncodeToString(b[8:10]), hex.EncodeToString(b[10:]))
}

func (s *server) killCallLegs(callback, extension string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	address, secret := telephonyEnv("AVOIP_ESL_ADDRESS"), telephonyEnv("AVOIP_ESL_SECRET")
	if address == "" {
		return
	}
	if callback != "" {
		_ = freeSwitchHangup(ctx, address, secret, callback)
	}
	if extension != "" {
		_ = freeSwitchHangup(ctx, address, secret, extension)
	}
}

func (s *server) dispatchBridgedCall(ctx context.Context, id string) {
	var call bridgedCall
	var gateway string
	var confirmation bool = true
	err := s.pool.QueryRow(ctx, `UPDATE public.avoip_bridged_calls SET status=$2,started_at=COALESCE(started_at,now()),updated_at=now(),version=version+1 WHERE id=$1 AND status IN ($3,$4) AND telephony_job_id='' AND scheduled_at <= now() RETURNING id::text,initiator_display_name,callback_destination,callback_kind,extension,caller_id,callback_uuid,extension_uuid,provider_id`, id, callCallingYou, callScheduled, callCallingYou).Scan(&call.ID, &call.InitiatorDisplayName, &call.CallbackDestination, &call.CallbackKind, &call.Extension, &call.CallerID, &call.CallbackUUID, &call.ExtensionUUID, &gateway)
	if err != nil {
		return
	}
	catalog, _, err := s.cachedCatalog()
	if err != nil {
		s.logger.Warn("bridged call dispatch policy lookup failed", "call_id", id, "reason", safeInterfaceError(err))
		s.failCall(ctx, id, "policy_unavailable")
		return
	}
	e, err := authorizedExtension(catalog, call.Extension)
	if err != nil {
		s.logger.Warn("bridged call extension authorization failed", "call_id", id, "reason", safeInterfaceError(err))
		s.failCall(ctx, id, "extension_not_authorized")
		return
	}
	for _, p := range catalog.Providers {
		if p.ID == gateway {
			gateway = p.Gateways[os.Getenv("AVOIP_SITE")]
		}
	}
	if call.CallbackKind == "internal" {
		gateway = "asterisk"
	}
	if gateway == "" {
		s.failCall(ctx, id, "provider_unavailable")
		return
	}
	if v := os.Getenv("AVOIP_BRIDGED_CONFIRMATION_REQUIRED"); v == "false" {
		confirmation = false
	}
	if call.CallbackKind == "internal" && os.Getenv("AVOIP_BRIDGED_INTERNAL_CONFIRMATION_REQUIRED") == "false" {
		confirmation = false
	}
	if confirmation {
		prompt, err := fetchBridgedCallPrompt(ctx, call)
		if err != nil {
			s.logger.Error("bridged call prompt generation failed", "call_id", id, "reason", telephonyErrorClass(err))
			s.failCall(ctx, id, "confirmation_prompt_unavailable")
			return
		}
		call.PromptFile = prompt
	}
	target := "sofia/gateway/asterisk/" + e.Extension
	command := bridgedOriginateCommand(call, gateway, target, confirmation)
	result, err := eslCommand(ctx, telephonyEnv("AVOIP_ESL_ADDRESS"), telephonyEnv("AVOIP_ESL_SECRET"), "bgapi "+command)
	if err != nil {
		s.logger.Error("bridged call origination failed", "call_id", id, "reason", telephonyErrorClass(err), "detail", safeInterfaceError(err))
		s.failCall(ctx, id, "origination_failed")
		return
	}
	job := strings.TrimSpace(result)
	s.logger.Info("bridged call origination accepted", "call_id", id, "callback_uuid", call.CallbackUUID, "provider_id", gateway)
	_, _ = s.pool.Exec(ctx, `UPDATE public.avoip_bridged_calls SET telephony_job_id=$2,status=$3,updated_at=now(),version=version+1 WHERE id=$1 AND telephony_job_id=''`, id, job, callCallingYou)
	_, _ = s.pool.Exec(ctx, `INSERT INTO public.avoip_bridged_call_events(call_id,event_type,detail) VALUES($1,'origination_accepted',$2)`, id, json.RawMessage(`{"job":"`+job+`"}`))
	go s.reconcileBridgedCall(id)
}

func bridgedOriginateCommand(call bridgedCall, gateway, target string, confirmation bool) string {
	timeout := strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_CALLBACK_RING_TIMEOUT_SECONDS"))
	if timeout == "" {
		timeout = "30"
	}
	return fmt.Sprintf(`originate {origination_uuid=%s,origination_caller_id_number=%s,origination_caller_id_name=CoRE,originate_timeout=%s,bridged_call_id=%s,bridged_call_target=%s,bridged_call_prompt_file=%s,bridged_confirmation_required=%t}sofia/gateway/%s/%s bridged-call-callback XML public`, call.CallbackUUID, call.CallerID, timeout, call.ID, target, call.PromptFile, confirmation, gateway, call.CallbackDestination)
}

func fetchBridgedCallPrompt(ctx context.Context, call bridgedCall) (string, error) {
	endpoint := strings.TrimRight(strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_TTS_CACHE_URL")), "/")
	token := strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_TTS_INTERNAL_TOKEN"))
	if endpoint == "" || token == "" {
		return "", errors.New("tts cache is not configured")
	}
	body, err := json.Marshal(map[string]string{"text": fmt.Sprintf("To accept a call from %s, press 1.", call.InitiatorDisplayName)})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/v1/tts", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-AVoIP-TTS-Internal", token)
	client := &http.Client{Timeout: 35 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", fmt.Errorf("tts cache returned status %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 4096))
	if err != nil {
		return "", err
	}
	var result struct {
		Path string `json:"path"`
	}
	if json.Unmarshal(data, &result) != nil || !strings.HasPrefix(result.Path, "/usr/share/freeswitch/sounds/avoip-shared/tts-cache-") || !strings.HasSuffix(result.Path, ".wav") {
		return "", errors.New("tts cache returned invalid path")
	}
	return result.Path, nil
}

func (s *server) failCall(ctx context.Context, id, reason string) {
	_, _ = s.pool.Exec(ctx, `UPDATE public.avoip_bridged_calls SET status=$2,failure_code=$3,completed_at=now(),updated_at=now(),version=version+1 WHERE id=$1 AND status NOT IN ('Completed','Cancelled','Failed','Busy','No answer')`, id, callFailed, reason)
}
func (s *server) reconcileBridgedCall(id string) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	deadline := time.NewTimer(2 * time.Hour)
	defer deadline.Stop()
	for {
		select {
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			var callback, extension, status string
			err := s.pool.QueryRow(ctx, `SELECT callback_uuid,extension_uuid,status FROM public.avoip_bridged_calls WHERE id=$1`, id).Scan(&callback, &extension, &status)
			if err != nil || status == callCancelled || status == callCompleted || status == callFailed || status == callNoAnswer || status == callBusy {
				cancel()
				return
			}
			stage, _ := freeSwitchVariable(ctx, telephonyEnv("AVOIP_ESL_ADDRESS"), telephonyEnv("AVOIP_ESL_SECRET"), callback, "bridged_call_stage")
			stage = strings.TrimSpace(stage)
			stageStatus := map[string]string{"awaiting_confirmation": callAwaitingConfirmation, "calling_extension": callCallingExtension, "connected": callConnected}[stage]
			if stageStatus != "" {
				_, _ = s.pool.Exec(ctx, `UPDATE public.avoip_bridged_calls SET status=$2,answered_at=COALESCE(answered_at,now()),connected_at=CASE WHEN $2='Connected' THEN COALESCE(connected_at,now()) ELSE connected_at END,updated_at=now(),version=version+1 WHERE id=$1 AND status NOT IN ('Completed','Cancelled','Failed','Busy','No answer')`, id, stageStatus)
			}
			callbackExists, callbackErr := freeSwitchUUIDExists(ctx, telephonyEnv("AVOIP_ESL_ADDRESS"), telephonyEnv("AVOIP_ESL_SECRET"), callback)
			extensionExists, extensionErr := freeSwitchUUIDExists(ctx, telephonyEnv("AVOIP_ESL_ADDRESS"), telephonyEnv("AVOIP_ESL_SECRET"), extension)
			if callbackErr != nil || extensionErr != nil {
				cancel()
				continue
			}
			if !callbackExists && !extensionExists {
				_, _ = s.pool.Exec(ctx, `UPDATE public.avoip_bridged_calls SET status=CASE WHEN cancellation_requested THEN $2 WHEN status='Connected' THEN $3 ELSE $4 END,completed_at=now(),cancelled_at=CASE WHEN cancellation_requested THEN now() ELSE cancelled_at END,updated_at=now(),version=version+1 WHERE id=$1 AND status NOT IN ('Completed','Cancelled','Failed','Busy','No answer')`, id, callCancelled, callCompleted, callNoAnswer)
			}
			cancel()
		case <-deadline.C:
			return
		}
	}
}
