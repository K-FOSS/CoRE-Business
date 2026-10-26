package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

const telnyxAPIBase = "https://api.telnyx.com/v2"

var telnyxResourceID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$`)

type telnyxESIMPurchase struct {
	Amount          int      `json:"amount"`
	Product         string   `json:"product,omitempty"`
	SIMCardGroupID  string   `json:"sim_card_group_id,omitempty"`
	Status          string   `json:"status,omitempty"`
	Tags            []string `json:"tags,omitempty"`
	WhitelabelName  string   `json:"whitelabel_name,omitempty"`
}

func telnyxAPIKey() string {
	return strings.TrimSpace(getenv("SMS_PROVIDER_TELNYX_KEY"))
}

func getenv(name string) string {
	// Kept as a small seam so the API client never needs to pass credentials
	// through request data or browser-visible configuration.
	return strings.TrimSpace(strings.Trim(osGetenv(name), "\x00"))
}

var osGetenv = func(name string) string {
	return os.Getenv(name)
}

func (s *server) telnyxRequest(w http.ResponseWriter, r *http.Request, method, path string, body []byte) {
	status, data, err := s.telnyxFetch(r, method, path, body)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

func (s *server) telnyxFetch(r *http.Request, method, path string, body []byte) (int, []byte, error) {
	key := telnyxAPIKey()
	if key == "" {
		return http.StatusServiceUnavailable, nil, fmt.Errorf("Telnyx API key is not configured")
	}
	if !strings.HasPrefix(path, "/sim_cards") && !strings.HasPrefix(path, "/sim_card_groups") && !strings.HasPrefix(path, "/actions/purchase/esims") {
		return http.StatusInternalServerError, nil, fmt.Errorf("unsupported Telnyx resource")
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, method, telnyxAPIBase+path, bytes.NewReader(body))
	if err != nil {
		return http.StatusServiceUnavailable, nil, fmt.Errorf("Telnyx request unavailable")
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Bearer "+key)
	if len(body) > 0 {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := (&http.Client{Timeout: 20 * time.Second}).Do(request)
	if err != nil {
		return http.StatusBadGateway, nil, fmt.Errorf("Telnyx request failed")
	}
	defer response.Body.Close()
	data, readErr := io.ReadAll(io.LimitReader(response.Body, maxRequestBytes))
	if readErr != nil {
		return http.StatusBadGateway, nil, fmt.Errorf("Telnyx response unavailable")
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		message := strings.TrimSpace(string(data))
		if message == "" {
			message = "Telnyx request failed"
		}
		return response.StatusCode, nil, fmt.Errorf("%s", message)
	}
	return response.StatusCode, data, nil
}

func (s *server) listESIMs(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, false) {
		return
	}
	query := r.URL.Query()
	pageSize := query.Get("page[size]")
	if pageSize == "" {
		pageSize = "250"
	}
	if pageSize != "250" {
		pageSize = "100"
	}
	s.telnyxRequest(w, r, http.MethodGet, "/sim_cards?page[size]="+pageSize, nil)
}

func (s *server) listESIMGroups(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, false) {
		return
	}
	query := r.URL.Query()
	pageSize := query.Get("page[size]")
	if pageSize == "" {
		pageSize = "250"
	}
	if pageSize != "250" {
		pageSize = "100"
	}
	s.telnyxRequest(w, r, http.MethodGet, "/sim_card_groups?page[size]="+pageSize, nil)
}

func (s *server) purchaseESIMs(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, true) {
		return
	}
	var purchase telnyxESIMPurchase
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxRequestBytes))
	if err := decoder.Decode(&purchase); err != nil {
		http.Error(w, "invalid eSIM purchase request", http.StatusBadRequest)
		return
	}
	if purchase.Amount < 1 || purchase.Amount > 100 {
		http.Error(w, "amount must be between 1 and 100", http.StatusBadRequest)
		return
	}
	if purchase.Product != "" && purchase.Product != "whitelabel" {
		http.Error(w, "unsupported eSIM product", http.StatusBadRequest)
		return
	}
	if purchase.Status != "" && purchase.Status != "enabled" && purchase.Status != "disabled" && purchase.Status != "standby" {
		http.Error(w, "invalid eSIM status", http.StatusBadRequest)
		return
	}
	if len(purchase.SIMCardGroupID) > 0 && !telnyxResourceID.MatchString(purchase.SIMCardGroupID) {
		http.Error(w, "invalid SIM card group ID", http.StatusBadRequest)
		return
	}
	if len(purchase.WhitelabelName) > 100 || strings.ContainsAny(purchase.WhitelabelName, "\r\n") {
		http.Error(w, "invalid white-label name", http.StatusBadRequest)
		return
	}
	if len(purchase.Tags) > 50 {
		http.Error(w, "too many eSIM tags", http.StatusBadRequest)
		return
	}
	for _, tag := range purchase.Tags {
		if len(tag) > 100 || strings.ContainsAny(tag, "\r\n") {
			http.Error(w, "invalid eSIM tag", http.StatusBadRequest)
			return
		}
	}
	body, err := json.Marshal(purchase)
	if err != nil {
		http.Error(w, "invalid eSIM purchase request", http.StatusBadRequest)
		return
	}
	s.telnyxRequest(w, r, http.MethodPost, "/actions/purchase/esims", body)
}

func (s *server) esimActivationCode(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, false) {
		return
	}
	id := r.PathValue("id")
	if !telnyxResourceID.MatchString(id) {
		http.Error(w, "invalid SIM card ID", http.StatusBadRequest)
		return
	}
	s.telnyxRequest(w, r, http.MethodGet, "/sim_cards/"+id+"/activation_code", nil)
}

func (s *server) esimActivationQR(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, false) {
		return
	}
	id := r.PathValue("id")
	if !telnyxResourceID.MatchString(id) {
		http.Error(w, "invalid SIM card ID", http.StatusBadRequest)
		return
	}
	status, data, err := s.telnyxFetch(r, http.MethodGet, "/sim_cards/"+id+"/activation_code", nil)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}
	var response struct {
		Data struct {
			ActivationCode string `json:"activation_code"`
		} `json:"data"`
	}
	if err := json.Unmarshal(data, &response); err != nil || strings.TrimSpace(response.Data.ActivationCode) == "" {
		http.Error(w, "Telnyx returned no eSIM activation code", http.StatusBadGateway)
		return
	}
	image, err := qrcode.Encode(response.Data.ActivationCode, qrcode.Medium, 512)
	if err != nil {
		http.Error(w, "unable to generate eSIM QR code", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "image/png")
	_, _ = w.Write(image)
}

func (s *server) esimAction(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, true) {
		return
	}
	id := r.PathValue("id")
	if !telnyxResourceID.MatchString(id) {
		http.Error(w, "invalid SIM card ID", http.StatusBadRequest)
		return
	}
	action := r.PathValue("action")
	if action != "enable" && action != "disable" && action != "set_standby" {
		http.Error(w, "unsupported SIM card action", http.StatusBadRequest)
		return
	}
	s.telnyxRequest(w, r, http.MethodPost, "/sim_cards/"+id+"/actions/"+action, nil)
}

