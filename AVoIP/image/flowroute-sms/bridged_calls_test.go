package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

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
