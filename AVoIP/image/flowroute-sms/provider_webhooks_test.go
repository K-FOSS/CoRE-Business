package main

import (
	"net/url"
	"testing"
)

func TestAllowedTwilioMediaRedirect(t *testing.T) {
	allowed, _ := url.Parse("https://mms-media-prod.s3.amazonaws.com/object")
	if !allowedTwilioMediaRedirect(allowed) {
		t.Fatal("Twilio S3 media redirect should be allowed")
	}
	for _, raw := range []string{"https://mms.twiliocdn.com/object", "https://media.twiliocdn.com/object"} {
		parsed, _ := url.Parse(raw)
		if !allowedTwilioMediaRedirect(parsed) {
			t.Fatalf("Twilio CDN media redirect %q should be allowed", raw)
		}
	}
	for _, raw := range []string{
		"http://mms-media-prod.s3.amazonaws.com/object",
		"https://127.0.0.1/object",
		"https://attacker.example/object",
	} {
		parsed, _ := url.Parse(raw)
		if allowedTwilioMediaRedirect(parsed) {
			t.Fatalf("redirect %q should be rejected", raw)
		}
	}
}

func TestInboundMediaObjectKeyIsStableAndNamespaced(t *testing.T) {
	first := inboundMediaObjectKey("SM123:ME456")
	if first != inboundMediaObjectKey("SM123:ME456") {
		t.Fatal("media object key should be stable")
	}
	if len(first) != len("sms-media/inbound/")+64 || first[:len("sms-media/inbound/")] != "sms-media/inbound/" {
		t.Fatalf("unexpected media object key %q", first)
	}
}
