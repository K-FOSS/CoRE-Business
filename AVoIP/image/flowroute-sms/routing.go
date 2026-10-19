package main

import (
	"crypto/subtle"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type verifiedCallerID struct {
	Number    string     `json:"number"`
	Evidence  string     `json:"evidence"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
}
type sipProvider struct {
	ID              string             `json:"id"`
	Host            string             `json:"host"`
	Name            string             `json:"name"`
	EgressPrefix    string             `json:"egress_prefix,omitempty"`
	SupportedCodecs []string           `json:"supported_codecs,omitempty"`
	CodecOrder      []string           `json:"codec_order,omitempty"`
	CIDRs           []string           `json:"cidrs"`
	Gateways        map[string]string  `json:"gateways"`
	CallerIDs       []verifiedCallerID `json:"verified_caller_ids"`
}
type didRoute struct {
	Number              string   `json:"number"`
	Providers           []string `json:"allowed_providers"`
	Site                string   `json:"site"`
	Kind                string   `json:"kind"`
	Destination         string   `json:"destination"`
	OutboundProvider    string   `json:"outbound_provider,omitempty"`
	CallerID            string   `json:"caller_id,omitempty"`
	FaxDetectionEnabled *bool    `json:"fax_detection_enabled,omitempty"`
	CodecOrder          []string `json:"codec_order,omitempty"`
}

func (d didRoute) detectFax() bool { return d.FaxDetectionEnabled == nil || *d.FaxDetectionEnabled }

type extensionRoute struct {
	Extension           string   `json:"extension"`
	DisplayName         string   `json:"display_name,omitempty"`
	AssignedUser        string   `json:"assigned_user,omitempty"`
	Enabled             *bool    `json:"enabled,omitempty"`
	OutboundEnabled     *bool    `json:"outbound_enabled,omitempty"`
	CallerID            string   `json:"caller_id"`
	Provider            string   `json:"provider"`
	Site                string   `json:"site"`
	AllowedDestinations []string `json:"allowed_destinations,omitempty"`
	BlockedDestinations []string `json:"blocked_destinations,omitempty"`
}

type outboundRoutePreviewRequest struct {
	Extension   string `json:"extension"`
	Destination string `json:"destination"`
	CallerID    string `json:"caller_id,omitempty"`
	Site        string `json:"site"`
}

type outboundRoutePreview struct {
	Allowed               bool                `json:"allowed"`
	DenialReason          string              `json:"denial_reason,omitempty"`
	Extension             string              `json:"extension"`
	Site                  string              `json:"site"`
	NormalizedDestination string              `json:"normalized_destination,omitempty"`
	NormalizedCallerID    string              `json:"normalized_caller_id,omitempty"`
	EligibleProviders     []string            `json:"eligible_providers"`
	RemovedProviders      []map[string]string `json:"removed_providers"`
	SelectedProvider      string              `json:"selected_provider,omitempty"`
	FailoverOrder         []string            `json:"failover_order"`
	EgressDestination     string              `json:"egress_destination,omitempty"`
	CodecOrder            []string            `json:"codec_order,omitempty"`
	PolicyRevision        int64               `json:"policy_revision"`
	ProviderHealth        string              `json:"provider_health"`
}

// Existing catalog entries predate these flags and remain enabled until an
// administrator explicitly disables them. Disabled entries stay in the live
// snapshot with a reason so Kamailio can reject them precisely and fail closed.
func (e extensionRoute) outboundAllowed() bool {
	return (e.Enabled == nil || *e.Enabled) && (e.OutboundEnabled == nil || *e.OutboundEnabled)
}

func (e extensionRoute) outboundDisabledReason() string {
	if e.Enabled != nil && !*e.Enabled {
		return "extension_disabled"
	}
	if e.OutboundEnabled != nil && !*e.OutboundEnabled {
		return "outbound_disabled"
	}
	return ""
}

type sipCatalog struct {
	Providers  []sipProvider    `json:"providers"`
	DIDs       []didRoute       `json:"dids"`
	Extensions []extensionRoute `json:"extensions"`
	Version    int64            `json:"version"`
	Source     string           `json:"source,omitempty"`
}
type siteTarget struct {
	Host string `json:"host"`
	Port int    `json:"port"`
}

var extensionID = regexp.MustCompile(`^[0-9]{2,12}$`)
var adminUserID = regexp.MustCompile(`^[A-Za-z0-9_.@:-]{1,128}$`)
var correlationID = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
var sipHost = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{0,252}$`)
var nanpE164 = regexp.MustCompile(`^\+1[2-9][0-9]{2}[2-9][0-9]{6}$`)
var upstreamCodecs = map[string]bool{"OPUS": true, "G722": true, "PCMU": true, "PCMA": true}

func validateCodecOrder(codecs []string) error {
	if len(codecs) > len(upstreamCodecs) {
		return errors.New("codec order has too many entries")
	}
	seen := make(map[string]bool, len(codecs))
	for _, codec := range codecs {
		if !upstreamCodecs[codec] || seen[codec] {
			return errors.New("codec order contains an unsupported or duplicate codec")
		}
		seen[codec] = true
	}
	return nil
}

func codecRTPEngineFlags(codecs []string) string {
	if len(codecs) == 0 {
		return ""
	}
	flags := []string{"codec-strip-all"}
	for _, codec := range codecs {
		flags = append(flags, "codec-offer-"+codec)
	}
	flags = append(flags, "codec-offer-telephone-event")
	return strings.Join(flags, " ")
}

// effectiveProviderCodecOrder uses an explicit Admin preference first. When
// an Admin codec capability list is present without a separate preference, its
// listed order is the fallback. Twilio Elastic SIP only guarantees PCMU/PCMA;
// use that documented baseline for legacy Twilio entries with no codec data.
func effectiveProviderCodecOrder(provider sipProvider) []string {
	if len(provider.CodecOrder) > 0 {
		return provider.CodecOrder
	}
	if len(provider.SupportedCodecs) > 0 {
		return provider.SupportedCodecs
	}
	if strings.HasSuffix(strings.ToLower(provider.Host), ".twilio.com") {
		return []string{"PCMU", "PCMA"}
	}
	return nil
}

func (c sipCatalog) validate() error {
	if len(c.Providers) > 50 || len(c.DIDs) > 1000 || len(c.Extensions) > 1000 {
		return errors.New("catalog too large")
	}
	providers := map[string]sipProvider{}
	prefixes := map[string][]netip.Prefix{}
	for _, p := range c.Providers {
		if !providerID.MatchString(p.ID) || !sipHost.MatchString(p.Host) || len(p.Name) > 100 || len(p.EgressPrefix) > 32 || (p.EgressPrefix != "" && !regexp.MustCompile(`^[0-9]+$`).MatchString(p.EgressPrefix)) || len(p.CIDRs) > 100 || len(p.CallerIDs) > 1000 || validateCodecOrder(p.SupportedCodecs) != nil || validateCodecOrder(p.CodecOrder) != nil || (len(p.CodecOrder) > 0 && !codecOrderSubset(p.CodecOrder, p.SupportedCodecs)) {
			return errors.New("invalid SIP provider")
		}
		if _, ok := providers[p.ID]; ok {
			return errors.New("duplicate SIP provider")
		}
		for _, cidr := range p.CIDRs {
			prefix, err := netip.ParsePrefix(cidr)
			if err != nil || prefix.Bits() == 0 {
				return errors.New("invalid or unrestricted signaling CIDR")
			}
			for id, previous := range prefixes {
				for _, other := range previous {
					if id != p.ID && prefix.Overlaps(other) {
						return errors.New("providers cannot have ambiguous overlapping signaling networks")
					}
				}
			}
			prefixes[p.ID] = append(prefixes[p.ID], prefix)
		}
		for site, gateway := range p.Gateways {
			if site != "yvr" && site != "yxl" || !providerID.MatchString(gateway) {
				return errors.New("invalid site or gateway")
			}
		}
		for _, v := range p.CallerIDs {
			if n, ok := normalizePhoneNumber(v.Number); !ok || n != v.Number || strings.TrimSpace(v.Evidence) == "" || len(v.Evidence) > 512 {
				return errors.New("verified caller ID needs canonical number and independent evidence")
			}
		}
		providers[p.ID] = p
	}
	verify := func(provider, number, site string) bool {
		p, ok := providers[provider]
		if !ok || p.Gateways[site] == "" {
			return false
		}
		for _, v := range p.CallerIDs {
			if v.Number == number && (v.ExpiresAt == nil || v.ExpiresAt.After(time.Now())) {
				return true
			}
		}
		return false
	}
	dids := map[string]bool{}
	for _, d := range c.DIDs {
		number, ok := normalizePhoneNumber(d.Number)
		if !ok || number != d.Number || dids[number] || len(d.Providers) == 0 || len(d.Providers) > 50 || validateCodecOrder(d.CodecOrder) != nil {
			return errors.New("invalid/duplicate DID or missing allowed providers")
		}
		dids[number] = true
		if d.Site != "yvr" && d.Site != "yxl" {
			return errors.New("DID destination site must be yvr or yxl")
		}
		for _, p := range d.Providers {
			provider, exists := providers[p]
			if !exists {
				return errors.New("DID refers to unknown provider")
			}
			verified := false
			for _, id := range provider.CallerIDs {
				if id.Number == d.Number && (id.ExpiresAt == nil || id.ExpiresAt.After(time.Now())) {
					verified = true
				}
			}
			if !verified {
				return errors.New("allowed DID provider needs current number-ownership verification evidence")
			}
		}
		if len(d.CodecOrder) > 0 {
			for _, provider := range providers {
				for _, callerID := range provider.CallerIDs {
					if callerID.Number == d.Number && (len(provider.SupportedCodecs) == 0 || !codecOrderSubset(d.CodecOrder, provider.SupportedCodecs)) {
						return errors.New("DID codec order must be supported by each outbound provider that verifies the DID")
					}
				}
			}
		}
		switch d.Kind {
		case "ivr":
			if d.Destination != "" {
				return errors.New("IVR destination must be empty")
			}
		case "extension":
			if !extensionID.MatchString(d.Destination) {
				return errors.New("invalid destination extension")
			}
		case "did":
			if n, ok := normalizePhoneNumber(d.Destination); !ok || n != d.Destination || !verify(d.OutboundProvider, d.CallerID, d.Site) {
				return errors.New("DID forwarding needs a valid destination and verified outbound caller ID")
			}
		case "sip":
			u, err := url.Parse(d.Destination)
			if err != nil || u.Scheme != "sips" || !regexp.MustCompile(`^sips:[A-Za-z0-9_.+-]+@[a-z0-9.-]+(:[0-9]{2,5})?$`).MatchString(d.Destination) {
				return errors.New("SIP destination must be an explicit SIPS endpoint without parameters")
			}
		default:
			return errors.New("unsupported DID destination kind")
		}
	}
	seen := map[string]bool{}
	for _, e := range c.Extensions {
		if !extensionID.MatchString(e.Extension) || len(e.DisplayName) > 120 || (e.AssignedUser != "" && !adminUserID.MatchString(e.AssignedUser)) || seen[e.Extension] || len(e.AllowedDestinations) > 100 || len(e.BlockedDestinations) > 100 {
			return errors.New("invalid or duplicate extension")
		}
		if !verify(e.Provider, e.CallerID, e.Site) {
			return errors.New("extension needs a unique identity and provider-verified caller ID at its egress site")
		}
		for _, destinations := range [][]string{e.AllowedDestinations, e.BlockedDestinations} {
			seenDestinations := make(map[string]bool, len(destinations))
			for _, destination := range destinations {
				normalized, valid := normalizePhoneNumber(destination)
				if !valid || normalized != destination || seenDestinations[destination] {
					return errors.New("extension destination restrictions must be unique canonical E.164 numbers")
				}
				seenDestinations[destination] = true
			}
		}
		seen[e.Extension] = true
	}
	return nil
}

func codecOrderSubset(requested, supported []string) bool {
	allowed := make(map[string]bool, len(supported))
	for _, codec := range supported {
		allowed[codec] = true
	}
	for _, codec := range requested {
		if !allowed[codec] {
			return false
		}
	}
	return true
}
func loadConfiguredCatalog() (sipCatalog, error) {
	c := sipCatalog{Providers: []sipProvider{}, DIDs: []didRoute{}, Extensions: []extensionRoute{}}
	raw := strings.TrimSpace(os.Getenv("AVOIP_SIP_JSON"))
	if raw == "" {
		return c, nil
	}
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.DisallowUnknownFields()
	if dec.Decode(&c) != nil || dec.Decode(new(any)) != io.EOF {
		return c, errors.New("invalid configured SIP catalog")
	}
	if err := c.validate(); err != nil {
		return c, err
	}
	c.Source = "config"
	return c, nil
}
func (s *server) catalog(r *http.Request) (sipCatalog, error) {
	config, err := loadConfiguredCatalog()
	if err != nil {
		return config, err
	}
	// A complete Git configuration is authoritative; omit it to delegate editing.
	if config.Source == "config" {
		return config, nil
	}
	var raw []byte
	var version int64
	err = s.pool.QueryRow(r.Context(), `SELECT configuration,version FROM public.avoip_catalog WHERE id=true`).Scan(&raw, &version)
	if errors.Is(err, pgx.ErrNoRows) {
		return config, nil
	}
	if err != nil {
		return config, err
	}
	if json.Unmarshal(raw, &config) != nil {
		return config, errors.New("invalid stored catalog")
	}
	config.Version = version
	config.Source = "admin"
	return config, nil
}
func (s *server) getCatalog(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, false) {
		return
	}
	c, err := s.catalog(r)
	if err != nil {
		http.Error(w, "routing unavailable", 503)
		return
	}
	writeJSON(w, c)
}
func (s *server) saveCatalog(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, true) {
		return
	}
	cfg, err := loadConfiguredCatalog()
	if err != nil {
		http.Error(w, "configuration unavailable", 503)
		return
	}
	if cfg.Source == "config" {
		http.Error(w, "SIP catalog is managed by configuration", 409)
		return
	}
	var c sipCatalog
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 512<<10))
	dec.DisallowUnknownFields()
	if dec.Decode(&c) != nil || dec.Decode(new(any)) != io.EOF {
		http.Error(w, "invalid catalog", 400)
		return
	}
	if err = c.validate(); err != nil {
		http.Error(w, err.Error(), 422)
		return
	}
	version := c.Version
	c.Version = 0
	c.Source = ""
	raw, _ := json.Marshal(c)
	tx, err := s.pool.Begin(r.Context())
	if err != nil {
		http.Error(w, "database unavailable", 503)
		return
	}
	defer tx.Rollback(r.Context())
	if version == 0 {
		err = tx.QueryRow(r.Context(), `INSERT INTO public.avoip_catalog(id,configuration,updated_by) VALUES(true,$1,$2) ON CONFLICT DO NOTHING RETURNING version`, raw, r.Header.Get("X-Authentik-Username")).Scan(&c.Version)
	} else {
		err = tx.QueryRow(r.Context(), `UPDATE public.avoip_catalog SET configuration=$1,version=version+1,updated_at=now(),updated_by=$2 WHERE id=true AND version=$3 RETURNING version`, raw, r.Header.Get("X-Authentik-Username"), version).Scan(&c.Version)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		http.Error(w, "catalog changed; reload before saving", 409)
		return
	}
	if err == nil {
		_, err = tx.Exec(r.Context(), `INSERT INTO public.avoip_admin_audit(actor,action,object_id) VALUES($1,'sip_catalog_saved','site')`, r.Header.Get("X-Authentik-Username"))
	}
	if err == nil {
		err = tx.Commit(r.Context())
	}
	if err != nil {
		http.Error(w, "save failed", 503)
		return
	}
	c.Source = "admin"
	s.cacheCatalog(c)
	writeJSON(w, c)
}

func previewOutboundRoute(c sipCatalog, request outboundRoutePreviewRequest, activeSite string) outboundRoutePreview {
	result := outboundRoutePreview{
		Extension: request.Extension, Site: request.Site,
		EligibleProviders: []string{}, RemovedProviders: []map[string]string{},
		FailoverOrder: []string{}, ProviderHealth: "not_reported",
		PolicyRevision: c.Version,
	}
	deny := func(reason string) outboundRoutePreview {
		result.Allowed = false
		result.DenialReason = reason
		return result
	}
	if !extensionID.MatchString(request.Extension) {
		return deny("invalid_extension")
	}
	if request.Site != "yvr" && request.Site != "yxl" {
		return deny("invalid_site")
	}
	if activeSite != "" && request.Site != activeSite {
		return deny("site_not_available_in_this_admin_context")
	}
	var extension *extensionRoute
	for i := range c.Extensions {
		if c.Extensions[i].Extension == request.Extension {
			extension = &c.Extensions[i]
			break
		}
	}
	if extension == nil {
		return deny("extension_not_configured")
	}
	if !extension.outboundAllowed() {
		return deny(extension.outboundDisabledReason())
	}
	if extension.Site != request.Site {
		return deny("extension_site_mismatch")
	}
	destination, validDestination := normalizePhoneNumber(request.Destination)
	if !validDestination || destination != request.Destination || !nanpE164.MatchString(destination) {
		return deny("destination_not_supported_by_current_nanp_route")
	}
	result.NormalizedDestination = destination
	if len(extension.AllowedDestinations) > 0 && !containsString(extension.AllowedDestinations, destination) {
		return deny("destination_not_in_extension_allowlist")
	}
	if containsString(extension.BlockedDestinations, destination) {
		return deny("destination_blocked_for_extension")
	}
	callerID := extension.CallerID
	if request.CallerID != "" {
		requested, valid := normalizePhoneNumber(request.CallerID)
		if !valid || requested != request.CallerID {
			return deny("invalid_caller_id")
		}
		callerID = requested
	}
	result.NormalizedCallerID = callerID
	if callerID != extension.CallerID {
		return deny("caller_id_not_authorized_for_extension")
	}
	var provider *sipProvider
	for i := range c.Providers {
		if c.Providers[i].ID == extension.Provider {
			provider = &c.Providers[i]
			break
		}
	}
	if provider == nil {
		result.RemovedProviders = append(result.RemovedProviders, map[string]string{"provider": extension.Provider, "reason": "provider_not_configured"})
		return deny("no_eligible_provider")
	}
	if provider.Gateways[request.Site] == "" {
		result.RemovedProviders = append(result.RemovedProviders, map[string]string{"provider": provider.ID, "reason": "site_gateway_missing"})
		return deny("no_eligible_provider")
	}
	verified := false
	for _, approval := range provider.CallerIDs {
		if approval.Number == callerID && (approval.ExpiresAt == nil || approval.ExpiresAt.After(time.Now())) {
			verified = true
			break
		}
	}
	if !verified {
		result.RemovedProviders = append(result.RemovedProviders, map[string]string{"provider": provider.ID, "reason": "caller_id_not_verified_for_provider"})
		return deny("no_eligible_provider")
	}
	result.Allowed = true
	result.EligibleProviders = append(result.EligibleProviders, provider.ID)
	result.SelectedProvider = provider.ID
	result.FailoverOrder = append(result.FailoverOrder, provider.ID)
	result.EgressDestination = destination
	if provider.EgressPrefix != "" {
		result.EgressDestination = provider.EgressPrefix + "*" + destination
	}
	result.CodecOrder = effectiveProviderCodecOrder(*provider)
	return result
}

func (s *server) previewOutboundRoute(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, false) {
		return
	}
	var request outboundRoutePreviewRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF {
		http.Error(w, "invalid routing preview request", http.StatusBadRequest)
		return
	}
	catalog, err := s.catalog(r)
	if err != nil || catalog.validate() != nil {
		http.Error(w, "routing policy unavailable or expired", http.StatusServiceUnavailable)
		return
	}
	result := previewOutboundRoute(catalog, request, strings.ToLower(os.Getenv("AVOIP_SITE")))
	writeJSON(w, result)
}
func routingAuthorized(r *http.Request) bool {
	token := os.Getenv("AVOIP_ROUTING_TOKEN")
	if user, password, ok := r.BasicAuth(); ok {
		return len(token) >= 16 && user == "routing" && subtle.ConstantTimeCompare([]byte(password), []byte(token)) == 1
	}
	return len(token) >= 16 && subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+token)) == 1
}
func (s *server) routingSnapshot(w http.ResponseWriter, r *http.Request) {
	if !routingAuthorized(r) {
		http.Error(w, "forbidden", 403)
		return
	}
	c, deadline, err := s.cachedCatalog()
	if err != nil {
		http.Error(w, "unavailable", 503)
		return
	}
	if err = c.validate(); err != nil {
		http.Error(w, "catalog invalid or caller-ID approval expired", 503)
		return
	}
	providers := []map[string]string{}
	dids := map[string]any{}
	extensions := map[string]any{}
	targets := map[string]siteTarget{}
	providerPrefixes := make(map[string]string, len(c.Providers))
	providerCodecs := make(map[string][]string, len(c.Providers))
	providerCodecFlags := make(map[string]string, len(c.Providers))
	if json.Unmarshal([]byte(os.Getenv("AVOIP_SITES_JSON")), &targets) != nil {
		http.Error(w, "site targets unavailable", 503)
		return
	}
	for _, p := range c.Providers {
		providerCodecsForRoute := effectiveProviderCodecOrder(p)
		providers = append(providers, map[string]string{"id": p.ID, "cidrs": strings.Join(p.CIDRs, ","), "host": p.Host, "caller_ids": verifiedNumbers(p.CallerIDs), "egress_prefix": p.EgressPrefix, "codec_flags": codecRTPEngineFlags(providerCodecsForRoute)})
		providerPrefixes[p.ID] = p.EgressPrefix
		providerCodecs[p.ID] = providerCodecsForRoute
		providerCodecFlags[p.ID] = codecRTPEngineFlags(providerCodecsForRoute)
	}
	for _, d := range c.DIDs {
		t, ok := targets[d.Site]
		if !ok || !sipHost.MatchString(t.Host) || t.Port < 1 || t.Port > 65535 {
			http.Error(w, "site target unavailable", 503)
			return
		}
		providerFlags := make(map[string]string, len(d.Providers))
		for _, providerID := range d.Providers {
			flags := providerCodecFlags[providerID]
			if len(d.CodecOrder) > 0 {
				flags = codecRTPEngineFlags(d.CodecOrder)
			}
			providerFlags[providerID] = flags
		}
		dids[strings.TrimPrefix(d.Number, "+")] = map[string]any{"providers": "," + strings.Join(d.Providers, ",") + ",", "site": d.Site, "kind": d.Kind, "destination": d.Destination, "host": t.Host, "port": t.Port, "codec_flags_by_provider": providerFlags}
	}
	for _, e := range c.Extensions {
		t, ok := targets[e.Site]
		if !ok || !sipHost.MatchString(t.Host) || t.Port < 1 || t.Port > 65535 {
			http.Error(w, "site target unavailable", 503)
			return
		}
		codecOrder := providerCodecs[e.Provider]
		for _, did := range c.DIDs {
			if did.Number == e.CallerID && containsString(did.Providers, e.Provider) && len(did.CodecOrder) > 0 {
				codecOrder = did.CodecOrder
				break
			}
		}
		route := map[string]any{"caller_id": e.CallerID, "provider": e.Provider, "site": e.Site, "host": t.Host, "port": t.Port, "egress_prefix": providerPrefixes[e.Provider], "codec_order": codecOrder, "codec_flags": codecRTPEngineFlags(codecOrder), "allowed_destinations": "," + strings.Join(e.AllowedDestinations, ",") + ",", "blocked_destinations": "," + strings.Join(e.BlockedDestinations, ",") + ","}
		if !e.outboundAllowed() {
			route["disabled_reason"] = e.outboundDisabledReason()
		}
		extensions[e.Extension] = route
	}
	for _, p := range c.Providers {
		for _, id := range p.CallerIDs {
			if id.ExpiresAt != nil && id.ExpiresAt.Before(deadline) {
				deadline = *id.ExpiresAt
			}
		}
	}
	writeJSON(w, map[string]any{"providers": providers, "dids": dids, "extensions": extensions, "version": c.Version, "valid_until": deadline.Unix(), "generated_at": time.Now().UTC(), "site": os.Getenv("AVOIP_SITE")})
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
func (s *server) audit(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, false) {
		return
	}
	rows, err := s.pool.Query(r.Context(), `SELECT actor,action,object_id,changed_at FROM public.avoip_admin_audit ORDER BY id DESC LIMIT 100`)
	if err != nil {
		http.Error(w, "audit unavailable", 503)
		return
	}
	defer rows.Close()
	result := []map[string]any{}
	for rows.Next() {
		var actor, action, object string
		var at time.Time
		if rows.Scan(&actor, &action, &object, &at) != nil {
			http.Error(w, "audit unavailable", 503)
			return
		}
		result = append(result, map[string]any{"actor": actor, "action": action, "object_id": object, "at": at})
	}
	if rows.Err() != nil {
		http.Error(w, "audit unavailable", 503)
		return
	}
	writeJSON(w, result)
}
func (s *server) registerAdmin(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/admin", func(w http.ResponseWriter, r *http.Request) {
		if !s.requireAdmin(w, r, false) {
			return
		}
		_, deadline, cacheErr := s.cachedCatalog()
		writeJSON(w, map[string]any{"snapshot_ready": cacheErr == nil, "snapshot_valid_until": deadline, "sms_enabled": os.Getenv("ADMIN_SMS_ENABLED") != "false", "site": os.Getenv("AVOIP_SITE"), "routing_enabled": os.Getenv("AVOIP_ROUTING_ENABLED") == "true"})
	})
	mux.HandleFunc("GET /api/sip", s.getCatalog)
	mux.HandleFunc("PUT /api/sip", s.saveCatalog)
	mux.HandleFunc("POST /api/routing/preview", s.previewOutboundRoute)
	mux.HandleFunc("GET /api/audit", s.audit)
}
func (s *server) adminPage(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r, false) {
		return
	}
	data, err := webFiles.ReadFile("web/admin.html")
	if err != nil {
		http.Error(w, "page unavailable", 500)
		return
	}
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; connect-src 'self'; frame-ancestors 'self'")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Write(data)
}

// XML dialplan lookup is bound to an authenticated internal source, never a
// public dialplan URL. Only finite configured targets can become bridge strings.
func (s *server) freeSwitchRoute(w http.ResponseWriter, r *http.Request) {
	if !routingAuthorized(r) {
		http.Error(w, "forbidden", 403)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 65536)
	if r.ParseForm() != nil {
		http.Error(w, "invalid lookup", 400)
		return
	}
	if r.Body == nil {
		http.Error(w, "invalid lookup", 400)
		return
	}
	context := r.Form.Get("Caller-Context")
	if context != "core-managed-outbound" && context != "core-managed-inbound" {
		w.Header().Set("Content-Type", "text/xml")
		io.WriteString(w, `<document type="freeswitch/xml"><section name="result"><result status="not found"/></section></document>`)
		return
	}
	c, _, err := s.cachedCatalog()
	if err != nil || c.validate() != nil {
		http.Error(w, "unavailable", 503)
		return
	}
	site := os.Getenv("AVOIP_SITE")
	destination := r.Form.Get("Caller-Destination-Number")
	extension := r.Form.Get("variable_sip_h_X-Core-Extension")
	bridge := ""
	transfer := ""
	detectFax := false
	callerID := ""
	gateway := ""
	providerID := ""
	codecOrder := []string(nil)
	callLinkedID := safeCorrelationID(r.Form.Get("variable_sip_h_X-Core-Call-Linkedid"))
	originUniqueID := safeCorrelationID(r.Form.Get("variable_sip_h_X-Core-Origin-Uniqueid"))
	if context == "core-managed-outbound" && extensionID.MatchString(extension) {
		for _, e := range c.Extensions {
			if e.Extension == extension && e.Site == site {
				if _, ok := normalizePhoneNumber(destination); ok {
					callerID = e.CallerID
					providerID = e.Provider
					for _, p := range c.Providers {
						if p.ID == e.Provider {
							gateway = p.Gateways[site]
							codecOrder = effectiveProviderCodecOrder(p)
						}
					}
					for _, d := range c.DIDs {
						if d.Number == e.CallerID && containsString(d.Providers, e.Provider) && len(d.CodecOrder) > 0 {
							codecOrder = d.CodecOrder
							break
						}
					}
					bridge = managedGatewayBridge(gateway, destination)
				}
			}
		}
	}
	if context == "core-managed-inbound" {
		did, _ := normalizePhoneNumber(r.Form.Get("variable_sip_h_X-Core-Original-DID"))
		for _, d := range c.DIDs {
			if d.Number == did && d.Site == site {
				detectFax = d.detectFax()
				switch d.Kind {
				case "ivr":
					transfer = "silent-ivr-entry XML public"
				case "extension":
					bridge = "sofia/gateway/asterisk/" + d.Destination
				case "sip":
					bridge = "sofia/flowroute/" + d.Destination
				case "did":
					callerID = d.CallerID
					for _, p := range c.Providers {
						if p.ID == d.OutboundProvider {
							gateway = p.Gateways[site]
							codecOrder = effectiveProviderCodecOrder(p)
						}
					}
					if len(d.CodecOrder) > 0 {
						codecOrder = d.CodecOrder
					}
					bridge = managedGatewayBridge(gateway, d.Destination)
				}
			}
		}
	}
	w.Header().Set("Content-Type", "text/xml")
	if bridge == "" && transfer == "" {
		io.WriteString(w, `<document type="freeswitch/xml"><section name="result"><result status="not found"/></section></document>`)
		return
	}
	escape := func(v string) string { var b strings.Builder; xml.EscapeText(&b, []byte(v)); return b.String() }
	text := `<document type="freeswitch/xml"><section name="dialplan"><context name="` + escape(context) + `"><extension name="managed"><condition field="destination_number" expression="^.+$">`
	if callerID != "" {
		text += `<action application="set" data="effective_caller_id_number=` + escape(callerID) + `"/>`
	}
	if context == "core-managed-outbound" {
		text += `<action application="log" data="INFO AVoIP outbound route selected extension=` + escape(extension) + ` site=` + escape(site) + ` provider=` + escape(providerID) + ` codecs=` + escape(strings.Join(codecOrder, ",")) + ` policy_revision=` + strconv.FormatInt(c.Version, 10) + ` destination-class=nanp call_id=${sip_call_id} linkedid=` + escape(callLinkedID) + ` origin_uniqueid=` + escape(originUniqueID) + ` uuid=${uuid}"/>`
	}
	if len(codecOrder) > 0 {
		text += `<action application="export" data="nolocal:absolute_codec_string=` + escape(strings.Join(codecOrder, ",")) + `"/>`
	}
	if context == "core-managed-outbound" {
		if callLinkedID != "" {
			text += `<action application="export" data="nolocal:sip_h_X-Core-Call-Linkedid=` + escape(callLinkedID) + `"/>`
		}
		if originUniqueID != "" {
			text += `<action application="export" data="nolocal:sip_h_X-Core-Origin-Uniqueid=` + escape(originUniqueID) + `"/>`
		}
	}
	if context == "core-managed-inbound" {
		text += `<action application="set" data="fax_original_destination=` + escape(destination) + `"/>`
		if detectFax {
			text += `<action application="set" data="execute_on_answer=execute_extension did-post-answer XML public"/>`
		}
	}
	if transfer != "" {
		text += `<action application="transfer" data="` + escape(transfer) + `"/>`
	} else {
		text += `<action application="set" data="hangup_after_bridge=true"/><action application="bridge" data="` + escape(bridge) + `"/>`
	}
	text += `</condition></extension></context></section></document>`
	io.WriteString(w, text)
}

func managedGatewayBridge(gateway, destination string) string {
	return "sofia/gateway/" + gateway + "/" + destination
}

func safeCorrelationID(value string) string {
	if correlationID.MatchString(value) {
		return value
	}
	return ""
}

func verifiedNumbers(values []verifiedCallerID) string {
	result := ","
	for _, v := range values {
		if v.ExpiresAt == nil || v.ExpiresAt.After(time.Now()) {
			result += v.Number + ","
		}
	}
	return result
}
