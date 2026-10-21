package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestAuthorizedNumber(t *testing.T) {
	allowed := []string{"+12065550100", "12065550100", "+12065550101", "12065550101"}
	if !authorizedNumber("12065550100", allowed) || !authorizedNumber("+12065550101", allowed) {
		t.Fatal("personal and group numbers should be authorized")
	}
	if authorizedNumber("+12065550102", allowed) || authorizedNumber("+1206-555-0100", allowed) {
		t.Fatal("unassigned or malformed numbers must be rejected")
	}
}

func TestSameOrigin(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "https://sms.resolvemy.host/api/messages", nil)
	r.Header.Set("Origin", "https://sms.resolvemy.host")
	if !sameOrigin(r) {
		t.Fatal("same origin send should pass")
	}
	r.Header.Set("Origin", "https://evil.example")
	if sameOrigin(r) {
		t.Fatal("cross origin send should fail")
	}
}

func TestInboxEscapesBodiesInClient(t *testing.T) {
	app := &server{}
	w := httptest.NewRecorder()
	app.inbox(w, httptest.NewRequest(http.MethodGet, "/inbox", nil))
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "/assets/app.js") {
		t.Fatal("inbox shell unavailable")
	}
	asset := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/assets/app.js", nil)
	r.SetPathValue("name", "app.js")
	app.asset(asset, r)
	if asset.Code != http.StatusOK || !strings.Contains(asset.Body.String(), "textContent=text") {
		t.Fatal("message client must render untrusted text through textContent")
	}
}

func TestBridgedCallsAssetIsServed(t *testing.T) {
	app := &server{}
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/assets/bridged-calls.js", nil)
	r.SetPathValue("name", "bridged-calls.js")
	app.asset(w, r)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "loadCalls") {
		t.Fatal("bridged calls client asset must be served")
	}
}

func TestAllowedFlowrouteMediaURL(t *testing.T) {
	tests := []struct {
		name string
		url  string
		want bool
	}{
		{name: "documented media host", url: "https://mms-media-prod.s3.amazonaws.com/object?signature=redacted", want: true},
		{name: "regional S3 media host", url: "https://s3.us-west-2.amazonaws.com/bucket/object?signature=redacted", want: true},
		{name: "host is case insensitive", url: "HTTPS://S3.US-WEST-2.AMAZONAWS.COM/object", want: true},
		{name: "explicit HTTPS port", url: "https://s3.us-west-2.amazonaws.com:443/object", want: true},
		{name: "other region rejected", url: "https://s3.us-east-1.amazonaws.com/bucket/object", want: false},
		{name: "suffix spoof rejected", url: "https://s3.us-west-2.amazonaws.com.attacker.example/object", want: false},
		{name: "HTTP rejected", url: "http://s3.us-west-2.amazonaws.com/object", want: false},
		{name: "nonstandard port rejected", url: "https://s3.us-west-2.amazonaws.com:8443/object", want: false},
		{name: "userinfo rejected", url: "https://user@s3.us-west-2.amazonaws.com/object", want: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			parsed, err := url.Parse(test.url)
			if err != nil {
				t.Fatal(err)
			}
			if got := allowedFlowrouteMediaURL(parsed); got != test.want {
				t.Fatalf("allowedFlowrouteMediaURL(%q) = %t, want %t", test.url, got, test.want)
			}
		})
	}
}

func TestParseMessageFlowrouteEnvelope(t *testing.T) {
	payload := `{"data":{"id":"mdr2-test-redacted","type":"message","attributes":{"body":"test message","direction":"inbound","from":"sender-test","to":"recipient-test","timestamp":"2026-10-18T12:34:56Z","is_mms":false}}}`
	message, err := parseMessage([]byte(payload))
	if err != nil {
		t.Fatal(err)
	}
	if message.ID != "mdr2-test-redacted" || message.From != "sender-test" || message.To != "recipient-test" || message.Body == nil || *message.Body != "test message" {
		t.Fatalf("parsed message fields did not match fixture: %#v", message)
	}
	if message.Direction != "inbound" || message.Timestamp.IsZero() || message.IsMMS {
		t.Fatalf("parsed metadata did not match fixture: %#v", message)
	}
}

func TestParseMessageLegacyFlatPayload(t *testing.T) {
	message, err := parseMessage([]byte(`{"id":"mdr1-test-redacted","body":"test","from":"sender-test","to":"recipient-test"}`))
	if err != nil {
		t.Fatal(err)
	}
	if message.ID != "mdr1-test-redacted" || message.Body == nil || *message.Body != "test" {
		t.Fatalf("legacy payload was not parsed: %#v", message)
	}
}

func TestParseMessageRejectsMissingSMSBody(t *testing.T) {
	_, err := parseMessage([]byte(`{"data":{"id":"mdr2-test-redacted","attributes":{"direction":"inbound","from":"sender-test","to":"recipient-test","is_mms":false}}}`))
	if err == nil || !strings.Contains(err.Error(), "body") {
		t.Fatalf("expected missing SMS body error, got %v", err)
	}
}

func TestParseMessageMMSIncludesMediaMetadata(t *testing.T) {
	payload := `{"data":{"id":"mdr2-test-redacted","attributes":{"body":"photo","direction":"inbound","from":"sender-test","to":"recipient-test","is_mms":true},"relationships":{"media":{"data":[{"id":"media-test-redacted","type":"media"}]}}},"included":[{"id":"media-test-redacted","type":"media","attributes":{"file_name":"image.jpg","file_size":12,"mime_type":"image/jpeg","url":"https://mms-media-prod.s3.amazonaws.com/object?signature=redacted"}}]}`
	message, err := parseMessage([]byte(payload))
	if err != nil {
		t.Fatal(err)
	}
	if !message.IsMMS || len(message.Media) != 1 || message.Media[0].ID != "media-test-redacted" || message.Media[0].Attributes.MIMEType != "image/jpeg" {
		t.Fatalf("MMS media metadata was not parsed: %#v", message)
	}
}

func TestAllowedNumbersRejectsInvalidValues(t *testing.T) {
	app := &server{}
	r := httptest.NewRequest("GET", "/api/messages", nil)
	r.Header.Set("X-Auth-Numbers", "12065550100,not-a-number,+1206-555-0101")
	numbers := app.allowedNumbers(r)
	if len(numbers) != 2 || numbers[0] != "+12065550100" || numbers[1] != "12065550100" {
		t.Fatalf("unexpected authorized number set: %#v", numbers)
	}
}

func TestValidTokenPath(t *testing.T) {
	token := []byte("0123456789abcdef0123456789abcdef")
	if !validTokenPath(callbackPrefix+string(token), token) {
		t.Fatal("expected token path to match")
	}
	for _, path := range []string{"/flowroute/other", "/flowroute/", "/flowroute/0123456789abcdef0123456789abcdef/extra", "/unrelated/0123456789abcdef0123456789abcdef"} {
		if validTokenPath(path, token) {
			t.Fatalf("unexpected token path match: %s", path)
		}
	}
}
