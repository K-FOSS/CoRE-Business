package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestAdminGroupsAndOrigin(t *testing.T) {
	s := &server{}
	for _, tc := range []struct {
		groups, user, origin string
		want                 bool
	}{
		{`["AVoIP Admins"]`, "alice", "https://sms.example", true},
		{`["AVoIP Users"]`, "alice", "https://sms.example", false},
		{`["AVoIP Admins extra"]`, "alice", "https://sms.example", false},
		{`AVoIP Admins`, "alice", "https://sms.example", false},
		{`["AVoIP Admins", 1]`, "alice", "https://sms.example", false},
		{`["AVoIP Admins"]`, "", "https://sms.example", false},
		{`["AVoIP Admins"]`, "alice", "https://other.example", false},
	} {
		r := httptest.NewRequest("DELETE", "https://sms.example/api/messages/id", nil)
		r.Header.Set("X-Authentik-Username", tc.user)
		r.Header.Set("X-Auth-Groups", tc.groups)
		r.Header.Set("Origin", tc.origin)
		if s.requireAdmin(httptest.NewRecorder(), r, true) != tc.want {
			t.Errorf("authorization mismatch: %q", tc.groups)
		}
	}
	r := httptest.NewRequest("DELETE", "https://sms.example/api/messages/id", nil)
	r.Header.Set("X-Auth-Numbers", "+12065550100")
	w := httptest.NewRecorder()
	s.deleteMessage(w, r)
	if w.Code != 403 {
		t.Fatal("user reached deletion storage")
	}
}
func fixtureCatalog() sipCatalog {
	return sipCatalog{Providers: []sipProvider{{ID: "carrier", Host: "sip.carrier.example", CIDRs: []string{"192.0.2.0/24"}, Gateways: map[string]string{"yvr": "carrier-tls", "yxl": "carrier-tls"}, CallerIDs: []verifiedCallerID{{Number: "+12065550100", Evidence: "provider ownership review"}}}}, DIDs: []didRoute{{Number: "+12065550100", Providers: []string{"carrier"}, Site: "yvr", Kind: "extension", Destination: "7101"}}, Extensions: []extensionRoute{{Extension: "7101", CallerID: "+12065550100", Provider: "carrier", Site: "yvr"}}}
}

func TestOutboundRoutePreviewUsesCurrentAuthorization(t *testing.T) {
	catalog := fixtureCatalog()
	catalog.Version = 17
	catalog.Providers[0].EgressPrefix = "9"
	catalog.Providers[0].SupportedCodecs = []string{"PCMU", "PCMA"}
	catalog.Extensions[0].AllowedDestinations = []string{"+16505550123"}
	request := outboundRoutePreviewRequest{Extension: "7101", Destination: "+16505550123", CallerID: "+12065550100", Site: "yvr"}
	preview := previewOutboundRoute(catalog, request, "yvr")
	if !preview.Allowed || preview.SelectedProvider != "carrier" || preview.EgressDestination != "9*+16505550123" || preview.PolicyRevision != 17 || len(preview.FailoverOrder) != 1 || preview.ProviderHealth != "not_reported" {
		t.Fatalf("unexpected allowed preview: %+v", preview)
	}
	for _, tc := range []struct {
		name   string
		mutate func(*sipCatalog, *outboundRoutePreviewRequest)
		want   string
	}{
		{"disabled extension", func(c *sipCatalog, _ *outboundRoutePreviewRequest) {
			disabled := false
			c.Extensions[0].Enabled = &disabled
		}, "extension_disabled"},
		{"disabled outbound", func(c *sipCatalog, _ *outboundRoutePreviewRequest) {
			disabled := false
			c.Extensions[0].OutboundEnabled = &disabled
		}, "outbound_disabled"},
		{"blocked destination", func(c *sipCatalog, _ *outboundRoutePreviewRequest) {
			c.Extensions[0].BlockedDestinations = []string{"+16505550123"}
		}, "destination_blocked_for_extension"},
		{"outside allowlist", func(c *sipCatalog, r *outboundRoutePreviewRequest) { r.Destination = "+14155550123" }, "destination_not_in_extension_allowlist"},
		{"caller ID override", func(_ *sipCatalog, r *outboundRoutePreviewRequest) { r.CallerID = "+14155550100" }, "caller_id_not_authorized_for_extension"},
		{"wrong site", func(_ *sipCatalog, r *outboundRoutePreviewRequest) { r.Site = "yxl" }, "site_not_available_in_this_admin_context"},
		{"unsupported destination", func(_ *sipCatalog, r *outboundRoutePreviewRequest) { r.Destination = "+11005550100" }, "destination_not_supported_by_current_nanp_route"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, r := fixtureCatalog(), request
			c.Version = 17
			c.Providers[0].EgressPrefix = "9"
			c.Providers[0].SupportedCodecs = []string{"PCMU", "PCMA"}
			c.Extensions[0].AllowedDestinations = []string{"+16505550123"}
			tc.mutate(&c, &r)
			got := previewOutboundRoute(c, r, "yvr")
			if got.Allowed || got.DenialReason != tc.want {
				t.Fatalf("preview = %+v, want denial %q", got, tc.want)
			}
		})
	}
}

func TestOutboundRoutePreviewRequiresAdmin(t *testing.T) {
	server := &server{}
	mux := http.NewServeMux()
	server.registerAdmin(mux)
	request := httptest.NewRequest(http.MethodPost, "/api/routing/preview", strings.NewReader(`{"extension":"7101","destination":"+16505550123","site":"yvr"}`))
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("unauthorized route preview returned %d", response.Code)
	}
}

func TestInboundRoutePreviewUsesConfiguredDIDAndProviderPolicy(t *testing.T) {
	catalog := fixtureCatalog()
	catalog.Version = 23
	request := inboundRoutePreviewRequest{DID: "+12065550100", InboundProvider: "carrier", Site: "yvr", SourceIP: "192.0.2.42"}
	preview := previewInboundRoute(catalog, request, "yvr")
	if !preview.Allowed || preview.NormalizedDID != request.DID || preview.DestinationKind != "extension" || preview.Destination != "7101" || preview.ProviderEligibility != "allowed" || preview.ProviderHealth != "not_reported" || preview.PolicyRevision != 23 {
		t.Fatalf("unexpected allowed inbound preview: %+v", preview)
	}

	for _, tc := range []struct {
		name   string
		mutate func(*inboundRoutePreviewRequest)
		want   string
	}{
		{"unknown DID", func(r *inboundRoutePreviewRequest) { r.DID = "+12065550101" }, "did_not_configured"},
		{"unassigned provider", func(r *inboundRoutePreviewRequest) { r.InboundProvider = "other" }, "provider_not_allowed_for_did"},
		{"wrong site", func(r *inboundRoutePreviewRequest) { r.Site = "yxl" }, "site_not_available_in_this_admin_context"},
		{"non-canonical DID", func(r *inboundRoutePreviewRequest) { r.DID = "12065550100" }, "invalid_did"},
		{"source outside provider network", func(r *inboundRoutePreviewRequest) { r.SourceIP = "198.51.100.12" }, "source_ip_not_allowed_for_provider"},
		{"invalid source IP", func(r *inboundRoutePreviewRequest) { r.SourceIP = "not-an-ip" }, "invalid_source_ip"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := request
			tc.mutate(&r)
			got := previewInboundRoute(catalog, r, "yvr")
			if got.Allowed || got.DenialReason != tc.want {
				t.Fatalf("preview = %+v, want denial %q", got, tc.want)
			}
		})
	}
}

func TestInboundRoutePreviewRequiresAdmin(t *testing.T) {
	server := &server{}
	mux := http.NewServeMux()
	server.registerAdmin(mux)
	request := httptest.NewRequest(http.MethodPost, "/api/routing/inbound-preview", strings.NewReader(`{"did":"+12065550100","inbound_provider":"carrier","site":"yvr"}`))
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("unauthorized inbound preview returned %d", response.Code)
	}
}

func freeSwitchActionData(t *testing.T, document, application string) string {
	t.Helper()
	var response struct {
		Sections []struct {
			Contexts []struct {
				Extensions []struct {
					Conditions []struct {
						Actions []struct {
							Application string `xml:"application,attr"`
							Data        string `xml:"data,attr"`
						} `xml:"action"`
					} `xml:"condition"`
				} `xml:"extension"`
			} `xml:"context"`
		} `xml:"section"`
	}
	if err := xml.Unmarshal([]byte(document), &response); err != nil {
		t.Fatalf("FreeSWITCH returned invalid XML: %v", err)
	}
	for _, section := range response.Sections {
		for _, context := range section.Contexts {
			for _, extension := range context.Extensions {
				for _, condition := range extension.Conditions {
					for _, action := range condition.Actions {
						if action.Application == application {
							return action.Data
						}
					}
				}
			}
		}
	}
	t.Fatalf("FreeSWITCH route did not contain a %s action", application)
	return ""
}
func TestCatalogOwnership(t *testing.T) {
	if err := fixtureCatalog().validate(); err != nil {
		t.Fatal(err)
	}
	for i, mutate := range []func(*sipCatalog){
		func(c *sipCatalog) { c.Providers[0].CallerIDs[0].Evidence = "" },
		func(c *sipCatalog) { past := time.Now().Add(-time.Hour); c.Providers[0].CallerIDs[0].ExpiresAt = &past },
		func(c *sipCatalog) { c.DIDs[0].Providers = []string{"unknown"} },
		func(c *sipCatalog) { c.Extensions[0].CallerID = "+12065550101" },
		func(c *sipCatalog) { c.Extensions[0].Site = "unknown" },
		func(c *sipCatalog) { c.Extensions[0].AssignedUser = "not a valid user id" },
		func(c *sipCatalog) { c.Extensions[0].AllowedDestinations = []string{"2065550101"} },
		func(c *sipCatalog) { c.Extensions[0].BlockedDestinations = []string{"+12065550100", "+12065550100"} },
		func(c *sipCatalog) {
			c.DIDs[0].Kind = "sip"
			c.DIDs[0].Destination = "sips:user@example.com;header=injected"
		},
		func(c *sipCatalog) { c.Providers[0].CIDRs = []string{"0.0.0.0/0"} },
	} {
		c := fixtureCatalog()
		mutate(&c)
		if c.validate() == nil {
			t.Errorf("invalid catalog %d accepted", i)
		}
	}
}

func TestProviderEgressPrefix(t *testing.T) {
	catalog := fixtureCatalog()
	catalog.Providers[0].EgressPrefix = "12345678"
	if err := catalog.validate(); err != nil {
		t.Fatalf("valid provider prefix rejected: %v", err)
	}
	encoded, err := json.Marshal(catalog)
	if err != nil {
		t.Fatal(err)
	}
	var stored sipCatalog
	if err := json.Unmarshal(encoded, &stored); err != nil || stored.Providers[0].EgressPrefix != "12345678" {
		t.Fatalf("provider prefix did not survive catalog persistence encoding: %v", err)
	}
	for _, invalid := range []string{"123*456", "123;rewrite", "123456789012345678901234567890123"} {
		catalog := fixtureCatalog()
		catalog.Providers[0].EgressPrefix = invalid
		if catalog.validate() == nil {
			t.Errorf("invalid egress prefix accepted: %q", invalid)
		}
	}
}

func TestProviderAndDIDCodecOrder(t *testing.T) {
	catalog := fixtureCatalog()
	catalog.Providers[0].SupportedCodecs = []string{"PCMU", "G722"}
	catalog.Providers[0].CodecOrder = []string{"PCMU", "G722"}
	catalog.DIDs[0].CodecOrder = []string{"G722", "PCMU"}
	if err := catalog.validate(); err != nil {
		t.Fatalf("valid codec preferences rejected: %v", err)
	}
	if got := codecRTPEngineFlags(catalog.DIDs[0].CodecOrder); got != "codec-strip-all codec-offer-G722 codec-offer-PCMU codec-offer-telephone-event" {
		t.Fatalf("unexpected ordered RTPEngine flags: %q", got)
	}
	catalog.DIDs[0].CodecOrder = []string{"OPUS"}
	if catalog.validate() == nil {
		t.Fatal("DID override outside provider codec set accepted")
	}
	catalog = fixtureCatalog()
	catalog.DIDs[0].CodecOrder = []string{"PCMU"}
	if catalog.validate() == nil {
		t.Fatal("DID codec override accepted without an explicit provider capability set")
	}
	for _, invalid := range [][]string{{"PCMU", "PCMU"}, {"PCMU;codec-offer-PCMA"}, {"G729"}} {
		catalog := fixtureCatalog()
		catalog.Providers[0].SupportedCodecs = []string{"PCMU", "PCMA"}
		catalog.Providers[0].CodecOrder = invalid
		if catalog.validate() == nil {
			t.Errorf("invalid provider codec order accepted: %#v", invalid)
		}
	}
}

func TestFreeSwitchOutboundDialplanAppliesProviderAndDIDCodecOrder(t *testing.T) {
	t.Setenv("AVOIP_ROUTING_TOKEN", "fixture-routing-token-not-a-production-secret")
	t.Setenv("AVOIP_SITE", "yvr")
	catalog := fixtureCatalog()
	catalog.Providers[0].SupportedCodecs = []string{"PCMU", "PCMA"}
	catalog.Providers[0].CodecOrder = []string{"PCMU", "PCMA"}
	catalog.DIDs[0].CodecOrder = []string{"PCMA", "PCMU"}
	s := &server{}
	s.cacheCatalog(catalog)

	lookup := func() string {
		t.Helper()
		form := url.Values{
			"Caller-Context":                        {"core-managed-outbound"},
			"Caller-Destination-Number":             {"+12065550101"},
			"variable_sip_h_X-Core-Extension":       {"7101"},
			"variable_sip_h_X-Core-Call-Linkedid":   {"avoip-asterisk-1792442113.215"},
			"variable_sip_h_X-Core-Origin-Uniqueid": {"avoip-asterisk-1792442113.216"},
		}
		r := httptest.NewRequest(http.MethodPost, "http://local/routing/freeswitch", strings.NewReader(form.Encode()))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.SetBasicAuth("routing", os.Getenv("AVOIP_ROUTING_TOKEN"))
		w := httptest.NewRecorder()
		s.freeSwitchRoute(w, r)
		if w.Code != http.StatusOK {
			t.Fatalf("FreeSWITCH dialplan status %d: %s", w.Code, w.Body.String())
		}
		return w.Body.String()
	}

	xml := lookup()
	if got := freeSwitchActionData(t, xml, "bridge"); got != "sofia/gateway/carrier-tls/+12065550101" {
		t.Fatalf("DID codec order was not applied to the FreeSWITCH upstream bridge: %s", xml)
	}
	if got := freeSwitchActionData(t, xml, "export"); got != "nolocal:absolute_codec_string=PCMA,PCMU" {
		t.Fatalf("DID codec order was not exported to the FreeSWITCH upstream leg: %s", xml)
	}
	if !strings.Contains(xml, "provider=carrier codecs=PCMA,PCMU") {
		t.Fatalf("FreeSWITCH route selection diagnostics did not include provider and codec order: %s", xml)
	}
	if !strings.Contains(xml, `data="nolocal:sip_h_X-Core-Call-Linkedid=avoip-asterisk-1792442113.215"`) || !strings.Contains(xml, `data="nolocal:sip_h_X-Core-Origin-Uniqueid=avoip-asterisk-1792442113.216"`) {
		t.Fatalf("FreeSWITCH B-leg did not inherit the trusted Asterisk correlation identifiers: %s", xml)
	}

	catalog.DIDs[0].CodecOrder = nil
	s.cacheCatalog(catalog)
	xml = lookup()
	if got := freeSwitchActionData(t, xml, "export"); got != "nolocal:absolute_codec_string=PCMU,PCMA" {
		t.Fatalf("provider codec order was not applied when the DID has no override: %s", xml)
	}
}

func TestSafeCorrelationID(t *testing.T) {
	for _, tc := range []struct {
		input, want string
	}{
		{"avoip-asterisk-1792442113.215", "avoip-asterisk-1792442113.215"},
		{"", ""},
		{"call\r\nX-Injected: yes", ""},
		{"call;header=value", ""},
		{strings.Repeat("a", 129), ""},
	} {
		if got := safeCorrelationID(tc.input); got != tc.want {
			t.Errorf("safeCorrelationID(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

func TestFreeSwitchTwilioLegacyRouteDefaultsToSupportedG711(t *testing.T) {
	t.Setenv("AVOIP_ROUTING_TOKEN", "fixture-routing-token-not-a-production-secret")
	t.Setenv("AVOIP_SITE", "yvr")
	catalog := fixtureCatalog()
	catalog.Providers[0].Host = "coreinc-yvr.pstn.umatilla.twilio.com"
	catalog.Providers[0].Gateways["yvr"] = "twilio-west"
	if order := effectiveProviderCodecOrder(catalog.Providers[0]); strings.Join(order, ",") != "PCMU,PCMA" {
		t.Fatalf("legacy Twilio provider default = %q, want PCMU,PCMA", strings.Join(order, ","))
	}
	s := &server{}
	s.cacheCatalog(catalog)
	form := url.Values{
		"Caller-Context":                  {"core-managed-outbound"},
		"Caller-Destination-Number":       {"+12065550101"},
		"variable_sip_h_X-Core-Extension": {"7101"},
	}
	r := httptest.NewRequest(http.MethodPost, "http://local/routing/freeswitch", strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.SetBasicAuth("routing", os.Getenv("AVOIP_ROUTING_TOKEN"))
	w := httptest.NewRecorder()
	s.freeSwitchRoute(w, r)
	if w.Code != http.StatusOK || freeSwitchActionData(t, w.Body.String(), "export") != "nolocal:absolute_codec_string=PCMU,PCMA" {
		t.Fatalf("legacy Twilio route did not constrain its upstream SDP to G.711: status=%d body=%s", w.Code, w.Body.String())
	}
	if got := freeSwitchActionData(t, w.Body.String(), "bridge"); got != "sofia/gateway/twilio-west/+12065550101" {
		t.Fatalf("legacy Twilio route did not select the configured upstream gateway: %s", w.Body.String())
	}
}

func TestExtensionOutboundEnablement(t *testing.T) {
	legacy := extensionRoute{Extension: "7101", CallerID: "+12065550100", Provider: "carrier", Site: "yvr"}
	if !legacy.outboundAllowed() || legacy.outboundDisabledReason() != "" {
		t.Fatal("legacy extension entries must preserve their current authorization")
	}
	disabled := false
	legacy.Enabled = &disabled
	if legacy.outboundAllowed() || legacy.outboundDisabledReason() != "extension_disabled" {
		t.Fatal("disabled extension must be excluded from outbound routing")
	}
	enabled := true
	legacy.Enabled = &enabled
	legacy.OutboundEnabled = &disabled
	if legacy.outboundAllowed() || legacy.outboundDisabledReason() != "outbound_disabled" {
		t.Fatal("extension with outbound disabled must be excluded from outbound routing")
	}
	legacy.OutboundEnabled = &enabled
	if !legacy.outboundAllowed() || legacy.outboundDisabledReason() != "" {
		t.Fatal("enabled extension with outbound permission must remain routable")
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestSMSProviderProtocols(t *testing.T) {
	t.Setenv("SMS_PROVIDER_KEY", "fixture-key")
	t.Setenv("SMS_PROVIDER_SECRET", "fixture-secret")
	for _, kind := range []string{"flowroute", "twilio", "telnyx"} {
		t.Run(kind, func(t *testing.T) {
			if kind == "twilio" {
				t.Setenv("SMS_PROVIDER_KEY", "AC"+strings.Repeat("a", 32))
			} else {
				t.Setenv("SMS_PROVIDER_KEY", "fixture-key")
			}
			s := &server{sendClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				body, _ := io.ReadAll(r.Body)
				if r.Method != "POST" || !strings.Contains(string(body), "fixture-message") {
					t.Fatal("unexpected payload")
				}
				if kind == "twilio" {
					form, _ := url.ParseQuery(string(body))
					if r.URL.Host != "api.twilio.com" || form.Get("From") != "+12065550100" {
						t.Fatal("incorrect Twilio request")
					}
				}
				if kind == "telnyx" && (r.URL.Host != "api.telnyx.com" || r.Header.Get("Authorization") != "Bearer fixture-key") {
					t.Fatal("incorrect Telnyx request")
				}
				if kind == "flowroute" && r.URL.String() != flowrouteSendURL {
					t.Fatal("Flowroute endpoint changed")
				}
				return &http.Response{StatusCode: 201, Body: io.NopCloser(strings.NewReader(`{"sid":"SMfixture","data":{"id":"fixture-id"}}`))}, nil
			})}}
			p := smsProvider{ID: kind + "-test", Type: kind, KeyEnv: "SMS_PROVIDER_KEY", SecretEnv: "SMS_PROVIDER_SECRET"}
			id, err := s.transmit(context.Background(), p, "+12065550100", "+12065550101", "fixture-message", nil)
			if err != nil || !strings.HasPrefix(id, p.ID+":") {
				t.Fatal("adapter failed", err)
			}
		})
	}
	if _, err := chooseProvider([]smsProvider{{ID: "flowroute", Enabled: true}, {ID: "twilio", Numbers: []string{"+12065550100"}}}, "+12065550100", ""); err == nil {
		t.Fatal("disabled provider silently fell back")
	}
}
func TestWebhookIntegrity(t *testing.T) {
	t.Setenv("SMS_PROVIDER_SECRET", "fixture-token")
	p := smsProvider{SecretEnv: "SMS_PROVIDER_SECRET", WebhookURL: "https://sms.example/providers/twilio/inbound"}
	body := []byte("Body=hello&From=%2B12065550100&To=%2B12065550101")
	mac := hmac.New(sha1.New, []byte("fixture-token"))
	mac.Write([]byte(p.WebhookURL + "BodyhelloFrom+12065550100To+12065550101"))
	r := httptest.NewRequest("POST", p.WebhookURL, nil)
	r.Header.Set("X-Twilio-Signature", base64.StdEncoding.EncodeToString(mac.Sum(nil)))
	if !validTwilioSignature(p, r, body) || validTwilioSignature(p, r, append(body, 'x')) {
		t.Fatal("Twilio integrity failed")
	}
	r.URL.RawQuery = "injected=true"
	if validTwilioSignature(p, r, body) {
		t.Fatal("unconfigured webhook query accepted")
	}
	public, private, _ := ed25519.GenerateKey(nil)
	t.Setenv("SMS_PROVIDER_PUBLIC", base64.StdEncoding.EncodeToString(public))
	p.PublicKeyEnv = "SMS_PROVIDER_PUBLIC"
	stamp := strconv.FormatInt(time.Now().Unix(), 10)
	r.Header.Set("Telnyx-Timestamp", stamp)
	r.Header.Set("Telnyx-Signature-Ed25519", base64.StdEncoding.EncodeToString(ed25519.Sign(private, append([]byte(stamp+"|"), body...))))
	if !validTelnyxSignature(p, r, body) || validTelnyxSignature(p, r, append(body, 'x')) {
		t.Fatal("Telnyx integrity failed")
	}
	old := strconv.FormatInt(time.Now().Add(-time.Hour).Unix(), 10)
	r.Header.Set("Telnyx-Timestamp", old)
	r.Header.Set("Telnyx-Signature-Ed25519", base64.StdEncoding.EncodeToString(ed25519.Sign(private, append([]byte(old+"|"), body...))))
	if validTelnyxSignature(p, r, body) {
		t.Fatal("expired webhook accepted")
	}
}
func TestAdminDatabase(t *testing.T) {
	dsn := os.Getenv("SMS_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires disposable localhost *_test PostgreSQL")
	}
	u, err := url.Parse(dsn)
	if err != nil || !strings.HasSuffix(u.Path, "_test") || (u.Hostname() != "127.0.0.1" && u.Hostname() != "localhost") {
		t.Fatal("only disposable localhost *_test database allowed")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if _, err = pool.Exec(ctx, createMessagesTable+adminSchema); err != nil {
		t.Fatal(err)
	}
	if _, err = pool.Exec(ctx, `TRUNCATE public.sms_providers,public.sms_deleted_messages,public.flowroute_inbound_media,public.flowroute_inbound_messages,public.avoip_catalog,public.avoip_admin_audit RESTART IDENTITY CASCADE`); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SMS_PROVIDERS_JSON", "")
	t.Setenv("AVOIP_SIP_JSON", "")
	s := &server{pool: pool, logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	request := func(method, path string, payload any) *http.Request {
		var body io.Reader
		if payload != nil {
			b, _ := json.Marshal(payload)
			body = bytes.NewReader(b)
		}
		r := httptest.NewRequest(method, "https://sms.example"+path, body)
		r.Header.Set("X-Authentik-Username", "fixture-admin")
		r.Header.Set("X-Auth-Groups", `["AVoIP Admins"]`)
		r.Header.Set("Origin", "https://sms.example")
		return r
	}
	p := smsProvider{ID: "twilio-fixture", Type: "twilio", KeyEnv: "SMS_PROVIDER_KEY", SecretEnv: "SMS_PROVIDER_SECRET", Numbers: []string{"+12065550100"}, Enabled: true}
	save := func(p smsProvider) *httptest.ResponseRecorder {
		r := request("PUT", "/api/providers/"+p.ID, p)
		r.SetPathValue("id", p.ID)
		w := httptest.NewRecorder()
		s.saveProvider(w, r)
		return w
	}
	w := save(p)
	if w.Code != 200 {
		t.Fatal("create", w.Code, w.Body.String())
	}
	json.Unmarshal(w.Body.Bytes(), &p)
	p.Name = "Updated"
	if w = save(p); w.Code != 200 {
		t.Fatal("update", w.Code, w.Body.String())
	}
	if w = save(p); w.Code != 409 {
		t.Fatal("stale version accepted", w.Code)
	}
	c := fixtureCatalog()
	r := request("PUT", "/api/sip", c)
	w = httptest.NewRecorder()
	s.saveCatalog(w, r)
	if w.Code != 200 {
		t.Fatal("catalog create", w.Code, w.Body.String())
	}
	json.Unmarshal(w.Body.Bytes(), &c)
	c.DIDs[0].Site = "yxl"
	r = request("PUT", "/api/sip", c)
	w = httptest.NewRecorder()
	s.saveCatalog(w, r)
	if w.Code != 200 {
		t.Fatal("catalog update", w.Code, w.Body.String())
	}
	_, err = pool.Exec(ctx, `INSERT INTO public.flowroute_inbound_messages(message_id,sender,recipient,body,direction,received_at) VALUES('fixture-message','+12065550101','+12065550100','fixture','inbound',now()); INSERT INTO public.flowroute_inbound_media(media_id,message_id,file_name,mime_type,content) VALUES('fixture-media','fixture-message','image.png','image/png','fixture')`)
	if err != nil {
		t.Fatal(err)
	}
	r = request("GET", "/api/numbers", nil)
	w = httptest.NewRecorder()
	s.listNumbers(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "+12065550100") {
		t.Fatal("admin inventory", w.Code, w.Body.String())
	}
	r = request("DELETE", "/api/messages/fixture-message", nil)
	r.SetPathValue("id", "fixture-message")
	w = httptest.NewRecorder()
	s.deleteMessage(w, r)
	if w.Code != 204 {
		t.Fatal("delete", w.Code, w.Body.String())
	}
	var count int
	pool.QueryRow(ctx, `SELECT count(*) FROM public.flowroute_inbound_media WHERE message_id='fixture-message'`).Scan(&count)
	if count != 0 {
		t.Fatal("attachments remain")
	}
	pool.QueryRow(ctx, `SELECT count(*) FROM public.sms_deleted_messages WHERE message_id='fixture-message'`).Scan(&count)
	if count != 1 {
		t.Fatal("tombstone missing")
	}

	// A replay of the existing Flowroute callback must not resurrect a deletion.
	s.token = []byte("fixture-callback-token-32-bytes-long")
	callback := httptest.NewRequest("POST", "https://sms.example/flowroute/"+string(s.token), strings.NewReader(`{"id":"fixture-message","from":"+12065550101","to":"+12065550100","body":"fixture"}`))
	callback.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	s.receive(w, callback)
	if w.Code != 200 {
		t.Fatal("deleted callback replay", w.Code)
	}
	pool.QueryRow(ctx, `SELECT count(*) FROM public.flowroute_inbound_messages WHERE message_id='fixture-message'`).Scan(&count)
	if count != 0 {
		t.Fatal("deleted callback was resurrected")
	}
	// Signed Twilio callbacks use their own namespace and deduplicate in PostgreSQL.
	account := "AC" + strings.Repeat("a", 32)
	t.Setenv("SMS_PROVIDER_ACCOUNT", account)
	t.Setenv("SMS_PROVIDER_TOKEN", "fixture-webhook-token")
	provider := smsProvider{ID: "twilio-inbound", Type: "twilio", KeyEnv: "SMS_PROVIDER_ACCOUNT", SecretEnv: "SMS_PROVIDER_TOKEN", Numbers: []string{"+12065550100"}, WebhookURL: "https://sms.example/providers/twilio-inbound/inbound", Enabled: true}
	config, _ := json.Marshal([]smsProvider{provider})
	t.Setenv("SMS_PROVIDERS_JSON", string(config))
	form := url.Values{"AccountSid": {account}, "MessageSid": {"SMfixture"}, "From": {"+12065550101"}, "To": {"+12065550100"}, "Body": {"fixture SMS"}, "NumMedia": {"0"}}
	signed := provider.WebhookURL
	for _, key := range []string{"AccountSid", "Body", "From", "MessageSid", "NumMedia", "To"} {
		signed += key + form.Get(key)
	}
	mac := hmac.New(sha1.New, []byte("fixture-webhook-token"))
	mac.Write([]byte(signed))
	signature := base64.StdEncoding.EncodeToString(mac.Sum(nil))
	for i := 0; i < 2; i++ {
		callback = httptest.NewRequest("POST", provider.WebhookURL, strings.NewReader(form.Encode()))
		callback.SetPathValue("id", provider.ID)
		callback.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		callback.Header.Set("X-Twilio-Signature", signature)
		w = httptest.NewRecorder()
		s.receiveProvider(w, callback)
		if w.Code != 200 {
			t.Fatal("signed callback", w.Code, w.Body.String())
		}
	}
	pool.QueryRow(ctx, `SELECT count(*) FROM public.flowroute_inbound_messages WHERE message_id='twilio-inbound:SMfixture'`).Scan(&count)
	if count != 1 {
		t.Fatal("provider callback duplicate count", count)
	}
	r = request("GET", "/api/messages", nil)
	r.Header.Set("X-Auth-Groups", `["AVoIP Users"]`)
	w = httptest.NewRecorder()
	s.listMessages(w, r)
	if w.Code != 403 {
		t.Fatal("unassigned user got admin access")
	}
}

func TestRoutingCacheFailsClosedWithoutDatabase(t *testing.T) {
	t.Setenv("AVOIP_ROUTING_TOKEN", "fixture-routing-token-not-a-production-secret")
	s := &server{}
	r := httptest.NewRequest("GET", "http://local/routing/snapshot", nil)
	r.Header.Set("Authorization", "Bearer "+os.Getenv("AVOIP_ROUTING_TOKEN"))
	w := httptest.NewRecorder()
	s.routingSnapshot(w, r)
	if w.Code != 503 {
		t.Fatal("cold snapshot must fail closed")
	}
	s.cacheCatalog(fixtureCatalog())
	s.routingDeadline = time.Now().Add(-time.Second)
	w = httptest.NewRecorder()
	s.routingSnapshot(w, r)
	if w.Code != 503 {
		t.Fatal("expired snapshot must not access a database on request")
	}
	w = httptest.NewRecorder()
	s.adminPage(w, r)
	if w.Code != 403 {
		t.Fatal("machine token must not grant UI administration")
	}
}

func TestRoutingSnapshotIncludesOrderedProviderDIDCodecs(t *testing.T) {
	t.Setenv("AVOIP_ROUTING_TOKEN", "fixture-routing-token-not-a-production-secret")
	t.Setenv("AVOIP_SITE", "yvr")
	t.Setenv("AVOIP_SITES_JSON", `{"yvr":{"host":"yvr.example","port":5061},"yxl":{"host":"yxl.example","port":5061}}`)
	catalog := fixtureCatalog()
	catalog.Providers[0].SupportedCodecs = []string{"PCMU", "G722"}
	catalog.Providers[0].CodecOrder = []string{"PCMU", "G722"}
	catalog.DIDs[0].CodecOrder = []string{"G722", "PCMU"}
	catalog.Extensions[0].AssignedUser = "august@example.test"
	catalog.Extensions[0].AllowedDestinations = []string{"+12065550101"}
	catalog.Extensions[0].BlockedDestinations = []string{"+12065550102"}
	s := &server{}
	s.cacheCatalog(catalog)
	r := httptest.NewRequest("GET", "http://local/routing/snapshot", nil)
	r.Header.Set("Authorization", "Bearer "+os.Getenv("AVOIP_ROUTING_TOKEN"))
	w := httptest.NewRecorder()
	s.routingSnapshot(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("snapshot status %d: %s", w.Code, w.Body.String())
	}
	var snapshot struct {
		Providers  []map[string]string       `json:"providers"`
		DIDs       map[string]map[string]any `json:"dids"`
		Extensions map[string]map[string]any `json:"extensions"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Providers[0]["codec_flags"] != "codec-strip-all codec-offer-PCMU codec-offer-G722 codec-offer-telephone-event" {
		t.Fatalf("provider codec order missing from snapshot: %#v", snapshot.Providers[0])
	}
	didFlags := snapshot.DIDs["12065550100"]["codec_flags_by_provider"].(map[string]any)["carrier"]
	if didFlags != "codec-strip-all codec-offer-G722 codec-offer-PCMU codec-offer-telephone-event" {
		t.Fatalf("DID codec override missing from snapshot: %#v", didFlags)
	}
	extensionFlags := snapshot.Extensions["7101"]["codec_flags"]
	if extensionFlags != didFlags {
		t.Fatalf("extension should inherit the caller-ID DID order: %#v", extensionFlags)
	}
	extension := snapshot.Extensions["7101"]
	if _, leaksUserIdentity := extension["assigned_user"]; leaksUserIdentity || extension["allowed_destinations"] != ",+12065550101," || extension["blocked_destinations"] != ",+12065550102," {
		t.Fatalf("destination restrictions missing or user identity leaked into routing snapshot: %#v", extension)
	}
}

func TestUnmanagedXMLFallbackWithoutDatabase(t *testing.T) {
	t.Setenv("AVOIP_ROUTING_TOKEN", "fixture-token-not-production")
	s := &server{}
	r := httptest.NewRequest("POST", "http://internal/routing/freeswitch", strings.NewReader("Caller-Context=default"))
	r.SetBasicAuth("routing", "fixture-token-not-production")
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	s.freeSwitchRoute(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `status="not found"`) {
		t.Fatal("unmanaged contexts must fall back without the routing cache")
	}
}

func TestCanonicalNumberCountryPrefix(t *testing.T) {
	badPrefix := "0" + strings.TrimPrefix("+12065550100", "+1")
	for _, input := range []string{"+" + badPrefix, badPrefix, "+" + strings.Repeat("0", 8)} {
		if _, ok := normalizePhoneNumber(input); ok {
			t.Errorf("invalid country prefix accepted: %q", input)
		}
	}
	if number, ok := normalizePhoneNumber("12065550100"); !ok || number != "+12065550100" {
		t.Fatal("valid canonical fixture rejected")
	}
}

func TestStandardAuthentikGroups(t *testing.T) {
	s := &server{}
	for _, tc := range []struct {
		groups string
		admin  bool
	}{{"AVoIP Users|AVoIP Admins", true}, {"AVoIP Admins extra|AVoIP Users", false}, {"", false}} {
		r := httptest.NewRequest("GET", "https://sms.example/api/numbers", nil)
		r.Header.Set("X-Authentik-Username", "fixture-user")
		r.Header.Set("X-Authentik-Groups", tc.groups)
		if s.isAdmin(r) != tc.admin {
			t.Fatal("incorrect standard group authorization")
		}
	}
}

func TestVerifiedGroupsOverrideCustomHeaders(t *testing.T) {
	s := &server{}
	for _, verified := range []string{"AVoIP Users", ""} {
		r := httptest.NewRequest("GET", "https://sms.example/api/numbers", nil)
		r.Header.Set("X-Authentik-Username", "fixture-user")
		r.Header.Set("X-Authentik-Groups", verified)
		r.Header.Set("X-Auth-Groups", `["AVoIP Admins"]`)
		if s.isAdmin(r) {
			t.Fatal("custom header overrode authoritative membership")
		}
	}
}
