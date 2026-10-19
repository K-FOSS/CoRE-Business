package main

import (
	"encoding/json"
	"net/http"
	"os"
	"sort"
	"strings"
)

func (s *server) groups(r *http.Request) []string {
	var groups []string
	// Both headers are supplied by the trusted Authentik authorization response.
	// The standard header also works for sessions issued before custom mappings.
	_ = json.Unmarshal([]byte(r.Header.Get("X-Auth-Groups")), &groups)
	if raw := r.Header.Get("X-Authentik-Groups"); raw != "" {
		groups = append(groups, strings.Split(raw, "|")...)
	}
	seen := map[string]bool{}
	result := []string{}
	for _, group := range groups {
		if group != "" && !seen[group] {
			seen[group] = true
			result = append(result, group)
		}
	}
	return result
}
func (s *server) isAdmin(r *http.Request) bool {
	if r.Header.Get("X-Authentik-Username") == "" {
		return false
	}
	name := os.Getenv("SMS_ADMIN_GROUP")
	if name == "" {
		name = "AVoIP Admins"
	}
	for _, group := range s.groups(r) {
		if group == name {
			return true
		}
	}
	return false
}
func (s *server) requireAdmin(w http.ResponseWriter, r *http.Request, mutation bool) bool {
	if !s.isAdmin(r) || (mutation && !sameOrigin(r)) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return false
	}
	return true
}
func numberVariants(numbers []string) []string {
	seen := map[string]bool{}
	result := []string{}
	for _, value := range numbers {
		if number, ok := normalizePhoneNumber(value); ok {
			for _, v := range []string{number, strings.TrimPrefix(number, "+")} {
				if !seen[v] {
					seen[v] = true
					result = append(result, v)
				}
			}
		}
	}
	return result
}
func (s *server) visibleNumbers(r *http.Request) ([]string, error) {
	if r.Header.Get("X-Authentik-Username") == "" {
		return nil, nil
	}
	if !s.isAdmin(r) {
		return s.allowedNumbers(r), nil
	}
	rows, err := s.pool.Query(r.Context(), `SELECT DISTINCT CASE WHEN direction='outbound' THEN sender ELSE recipient END FROM public.flowroute_inbound_messages`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	values := s.allowedNumbers(r)
	for rows.Next() {
		var n string
		if err = rows.Scan(&n); err != nil {
			return nil, err
		}
		values = append(values, n)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	providers, err := s.providers(r.Context())
	if err != nil {
		return nil, err
	}
	for _, p := range providers {
		values = append(values, p.Numbers...)
	}
	return numberVariants(values), nil
}
func (s *server) deleteMessage(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, true) {
		return
	}
	id := r.PathValue("id")
	if id == "" || len(id) > 200 {
		http.Error(w, "invalid message", 400)
		return
	}
	tx, err := s.pool.Begin(r.Context())
	if err != nil {
		http.Error(w, "database unavailable", 503)
		return
	}
	defer tx.Rollback(r.Context())
	_, err = tx.Exec(r.Context(), `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, id)
	if err == nil {
		_, err = tx.Exec(r.Context(), `INSERT INTO public.sms_deleted_messages(message_id,deleted_by) SELECT message_id,$2 FROM public.flowroute_inbound_messages WHERE message_id=$1 ON CONFLICT DO NOTHING`, id, r.Header.Get("X-Authentik-Username"))
	}
	if err == nil {
		_, err = tx.Exec(r.Context(), `DELETE FROM public.flowroute_inbound_messages WHERE message_id=$1`, id)
	}
	if err == nil {
		_, err = tx.Exec(r.Context(), `INSERT INTO public.avoip_admin_audit(actor,action,object_id) VALUES($1,'message_deleted',$2)`, r.Header.Get("X-Authentik-Username"), id)
	}
	if err == nil {
		err = tx.Commit(r.Context())
	}
	if err != nil {
		http.Error(w, "delete failed", 503)
		return
	}
	s.logger.Info("SMS message deleted", "message_id", id, "actor", r.Header.Get("X-Authentik-Username"))
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
func sortedCanonical(values []string) []string {
	result := []string{}
	for _, v := range numberVariants(values) {
		if strings.HasPrefix(v, "+") {
			result = append(result, v)
		}
	}
	sort.Strings(result)
	return result
}

func (s *server) adminURL(r *http.Request) string {
	if s.isAdmin(r) {
		return os.Getenv("AVOIP_ADMIN_URL")
	}
	return ""
}
