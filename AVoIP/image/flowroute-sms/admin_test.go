package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
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
			id, err := s.transmit(context.Background(), p, "+12065550100", "+12065550101", "fixture-message")
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
