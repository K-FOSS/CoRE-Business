package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestBridgedCallValidationPrimitives(t *testing.T) {
	if !ianaTimezone.MatchString("America/Vancouver") {
		t.Fatal("expected valid IANA timezone")
	}
	if ianaTimezone.MatchString("PST") || ianaTimezone.MatchString("../etc") {
		t.Fatal("accepted non-IANA timezone")
	}
	if idempotencyKey.MatchString("short") || !idempotencyKey.MatchString("browser-request:123456") {
		t.Fatal("idempotency validation mismatch")
	}
	loc, err := time.LoadLocation("America/Vancouver")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := time.ParseInLocation(time.RFC3339, "2025-03-09T02:30:00-08:00", loc); err != nil {
		t.Fatal("RFC3339 input should parse before policy comparison")
	}
	if _, err := parseScheduleLocal("2025-03-09T02:30", loc); err == nil {
		t.Fatal("accepted nonexistent DST time")
	}
	if _, err := parseScheduleLocal("2025-11-02T01:30", loc); err == nil {
		t.Fatal("accepted ambiguous DST time")
	}
	if _, err := parseScheduleLocal("2025-11-02T03:30", loc); err != nil {
		t.Fatal("rejected unambiguous DST time")
	}
}

func TestBridgedOriginateCommandIsStructured(t *testing.T) {
	call := bridgedCall{ID: "call-1", CallbackUUID: "callback-1", CallerID: "+16045550100", CallbackDestination: "+16045550101", Extension: "7101"}
	command := bridgedOriginateCommand(call, "carrier-gateway", "sofia/gateway/asterisk/7101", true)
	for _, value := range []string{"originate", "origination_uuid=callback-1", "bridged_call_id=call-1", "bridged_confirmation_required=true", "sip_h_X-Core-Extension=7101", "sip_h_X-Core-Call-Linkedid=call-1", "sip_h_X-Core-Origin-Uniqueid=callback-1", "sip_invite_extra_headers=X-Core-Extension: 7101\\nX-Core-Call-Linkedid: call-1\\nX-Core-Origin-Uniqueid: callback-1", "sofia/gateway/carrier-gateway/+16045550101", "bridged-call-callback XML public"} {
		if !strings.Contains(command, value) {
			t.Fatalf("command missing %q: %s", value, command)
		}
	}
	if strings.Contains(command, "&transfer(") || strings.Contains(command, "api ") || strings.Contains(command, "eval ") {
		t.Fatal("command unexpectedly contains an arbitrary control expression")
	}
	if !strings.HasSuffix(command, " bridged-call-callback XML public") {
		t.Fatalf("command did not specify the public callback context: %s", command)
	}
}

func TestBridgedCallDoesNotMarkNoAnswerBeforeCallbackRingWindow(t *testing.T) {
	started := time.Now().Add(-5 * time.Second)
	if bridgedCallMayFinalizeNoAnswer(started, "") {
		t.Fatal("call was allowed to finalize before the callback ring window elapsed")
	}
}

func TestBridgedCallCanFinalizeAfterCallbackRingWindow(t *testing.T) {
	started := time.Now().Add(-35 * time.Second)
	if !bridgedCallMayFinalizeNoAnswer(started, "") {
		t.Fatal("call was not allowed to finalize after the callback ring window elapsed")
	}
}

func TestBridgedCallStageAllowsImmediateTerminalMapping(t *testing.T) {
	started := time.Now()
	if !bridgedCallMayFinalizeNoAnswer(started, "calling_extension") {
		t.Fatal("observed call stage should allow terminal mapping")
	}
}

func TestAuthorizedExtensionHonorsDisablement(t *testing.T) {
	disabled := false
	catalog := sipCatalog{Extensions: []extensionRoute{{Extension: "7101", Enabled: &disabled}}}
	if _, err := authorizedExtension(catalog, "7101"); err == nil {
		t.Fatal("disabled extension was authorized")
	}
	enabled := true
	catalog.Extensions[0].Enabled = &enabled
	if _, err := authorizedExtension(catalog, "7101"); err != nil {
		t.Fatal(err)
	}
}

func TestFetchBridgedCallPromptRetriesTransientCacheFailure(t *testing.T) {
	var attempts atomic.Int32
	s := &server{
		logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		promptClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			if attempts.Add(1) == 1 {
				return &http.Response{StatusCode: http.StatusServiceUnavailable, Body: io.NopCloser(strings.NewReader("unavailable")), Header: make(http.Header)}, nil
			}
			return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(`{"path":"/usr/share/freeswitch/sounds/avoip-shared/tts-cache-test.wav"}`)), Header: make(http.Header)}, nil
		})},
	}
	t.Setenv("AVOIP_BRIDGED_TTS_CACHE_URL", "http://tts-cache.test")
	t.Setenv("AVOIP_BRIDGED_TTS_INTERNAL_TOKEN", "test-token")
	path, err := s.fetchBridgedCallPrompt(context.Background(), bridgedCall{ID: "call-test", InitiatorDisplayName: "August"})
	if err != nil {
		t.Fatalf("prompt request failed after transient cache error: %v", err)
	}
	if path != "/usr/share/freeswitch/sounds/avoip-shared/tts-cache-test.wav" || attempts.Load() != 2 {
		t.Fatalf("unexpected retry result path=%q attempts=%d", path, attempts.Load())
	}
}
