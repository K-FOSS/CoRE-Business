package main

import (
	"net/http/httptest"
	"strings"
	"testing"
)

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
	r.Header.Set("X-Auth-Numbers", "+12065550100,not-a-number,+1206-555-0101")
	numbers := app.allowedNumbers(r)
	if len(numbers) != 1 || numbers[0] != "+12065550100" {
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
