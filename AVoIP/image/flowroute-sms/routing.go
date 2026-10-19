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
	ID        string             `json:"id"`
	Host      string             `json:"host"`
	Name      string             `json:"name"`
	CIDRs     []string           `json:"cidrs"`
	Gateways  map[string]string  `json:"gateways"`
	CallerIDs []verifiedCallerID `json:"verified_caller_ids"`
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
}

func (d didRoute) detectFax() bool { return d.FaxDetectionEnabled == nil || *d.FaxDetectionEnabled }

type extensionRoute struct {
	Extension string `json:"extension"`
	CallerID  string `json:"caller_id"`
	Provider  string `json:"provider"`
	Site      string `json:"site"`
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
var sipHost = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{0,252}$`)

func (c sipCatalog) validate() error {
	if len(c.Providers) > 50 || len(c.DIDs) > 1000 || len(c.Extensions) > 1000 {
		return errors.New("catalog too large")
	}
	providers := map[string]sipProvider{}
	prefixes := map[string][]netip.Prefix{}
	for _, p := range c.Providers {
		if !providerID.MatchString(p.ID) || !sipHost.MatchString(p.Host) || len(p.Name) > 100 || len(p.CIDRs) > 100 || len(p.CallerIDs) > 1000 {
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
		if !ok || number != d.Number || dids[number] || len(d.Providers) == 0 || len(d.Providers) > 50 {
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
		if !extensionID.MatchString(e.Extension) || seen[e.Extension] || !verify(e.Provider, e.CallerID, e.Site) {
			return errors.New("extension needs a unique identity and provider-verified caller ID at its egress site")
		}
		seen[e.Extension] = true
	}
	return nil
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
	if json.Unmarshal([]byte(os.Getenv("AVOIP_SITES_JSON")), &targets) != nil {
		http.Error(w, "site targets unavailable", 503)
		return
	}
	for _, p := range c.Providers {
		providers = append(providers, map[string]string{"id": p.ID, "cidrs": strings.Join(p.CIDRs, ","), "host": p.Host, "caller_ids": verifiedNumbers(p.CallerIDs)})
	}
	for _, d := range c.DIDs {
		t, ok := targets[d.Site]
		if !ok || !sipHost.MatchString(t.Host) || t.Port < 1 || t.Port > 65535 {
			http.Error(w, "site target unavailable", 503)
			return
		}
		dids[strings.TrimPrefix(d.Number, "+")] = map[string]any{"providers": "," + strings.Join(d.Providers, ",") + ",", "site": d.Site, "kind": d.Kind, "destination": d.Destination, "host": t.Host, "port": t.Port}
	}
	for _, e := range c.Extensions {
		t, ok := targets[e.Site]
		if !ok || !sipHost.MatchString(t.Host) || t.Port < 1 || t.Port > 65535 {
			http.Error(w, "site target unavailable", 503)
			return
		}
		extensions[e.Extension] = map[string]any{"caller_id": e.CallerID, "provider": e.Provider, "site": e.Site, "host": t.Host, "port": t.Port}
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
	if context == "core-managed-outbound" && extensionID.MatchString(extension) {
		for _, e := range c.Extensions {
			if e.Extension == extension && e.Site == site {
				if _, ok := normalizePhoneNumber(destination); ok {
					callerID = e.CallerID
					for _, p := range c.Providers {
						if p.ID == e.Provider {
							gateway = p.Gateways[site]
						}
					}
					bridge = "sofia/gateway/" + gateway + "/" + destination
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
						}
					}
					bridge = "sofia/gateway/" + gateway + "/" + d.Destination
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

func verifiedNumbers(values []verifiedCallerID) string {
	result := ","
	for _, v := range values {
		if v.ExpiresAt == nil || v.ExpiresAt.After(time.Now()) {
			result += v.Number + ","
		}
	}
	return result
}
