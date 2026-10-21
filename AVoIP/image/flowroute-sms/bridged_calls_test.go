package main

import (
	"strings"
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
	call := bridgedCall{ID: "call-1", CallbackUUID: "callback-1", CallerID: "+16045550100", CallbackDestination: "+16045550101"}
	command := bridgedOriginateCommand(call, "carrier-gateway", "sofia/gateway/asterisk/7101", true)
	for _, value := range []string{"originate", "origination_uuid=callback-1", "bridged_call_id=call-1", "bridged_confirmation_required=true", "sofia/gateway/carrier-gateway/+16045550101", "bridged-call-callback XML public"} {
		if !strings.Contains(command, value) {
			t.Fatalf("command missing %q: %s", value, command)
		}
	}
	if strings.Contains(command, "api ") || strings.Contains(command, "eval ") {
		t.Fatal("command unexpectedly contains an arbitrary control expression")
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
