package main

import (
	"bufio"
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

func TestReadESLFrameReturnsReplyTextWithoutBody(t *testing.T) {
	frame := "Content-Type: command/reply\r\nReply-Text: +OK accepted\r\n\r\n"
	got, err := readESLFrame(bufio.NewReader(strings.NewReader(frame)))
	if err != nil {
		t.Fatalf("readESLFrame returned error: %v", err)
	}
	if got != "+OK accepted" {
		t.Fatalf("readESLFrame returned %q", got)
	}
}
