package main

import (
	"strings"
	"testing"
)

func TestESLCommandUsesNativeBackgroundCommand(t *testing.T) {
	if command := eslWireCommand("bgapi originate test"); !strings.HasPrefix(command, "bgapi originate") {
		t.Fatalf("ESL command was %q", command)
	}
	if command := eslWireCommand("uuid_getvar abc bridged_call_stage"); command != "api uuid_getvar abc bridged_call_stage" {
		t.Fatalf("ESL API command was %q", command)
	}
}
