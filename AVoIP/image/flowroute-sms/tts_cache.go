package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

type ttsRequest struct {
	Text  string `json:"text"`
	Model string `json:"model,omitempty"`
	Voice string `json:"voice,omitempty"`
}

type ttsResponse struct {
	Path string `json:"path"`
}

func runTTSCache() error {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("POST /v1/tts", handleTTSRequest)
	return http.ListenAndServe(":8080", mux)
}

func handleTTSRequest(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("X-AVoIP-TTS-Internal") != os.Getenv("AVOIP_BRIDGED_TTS_INTERNAL_TOKEN") || os.Getenv("AVOIP_BRIDGED_TTS_INTERNAL_TOKEN") == "" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var input ttsRequest
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&input) != nil || strings.TrimSpace(input.Text) == "" || len(input.Text) > 240 {
		http.Error(w, "invalid tts request", http.StatusBadRequest)
		return
	}
	model := strings.TrimSpace(input.Model)
	if model == "" {
		model = strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_TTS_MODEL"))
	}
	voice := strings.TrimSpace(input.Voice)
	if voice == "" {
		voice = strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_TTS_VOICE"))
	}
	if model == "" || voice == "" {
		http.Error(w, "tts configuration unavailable", http.StatusServiceUnavailable)
		return
	}
	name := "tts-cache-" + cacheKey(input.Text, model, voice) + ".wav"
	base := strings.TrimRight(strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_AUDIO_LIBRARY_URL")), "/")
	if base == "" {
		http.Error(w, "audio library unavailable", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 35*time.Second)
	defer cancel()
	client := &http.Client{Timeout: 30 * time.Second}
	if libraryRequest(ctx, client, http.MethodHead, base+"/"+name, nil, "") == nil {
		writeJSON(w, ttsResponse{Path: "/usr/share/freeswitch/sounds/avoip-shared/" + name})
		return
	}
	ttsURL := strings.TrimRight(strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_TTS_URL")), "/")
	if ttsURL == "" {
		http.Error(w, "tts endpoint unavailable", http.StatusServiceUnavailable)
		return
	}
	body, _ := json.Marshal(map[string]string{"model": model, "input": input.Text, "voice": voice, "response_format": "wav"})
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, ttsURL, bytes.NewReader(body))
	if err != nil {
		http.Error(w, "tts request failed", http.StatusBadGateway)
		return
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil || response.StatusCode < 200 || response.StatusCode >= 300 {
		if response != nil {
			response.Body.Close()
		}
		http.Error(w, "tts request failed", http.StatusBadGateway)
		return
	}
	audio, readErr := io.ReadAll(io.LimitReader(response.Body, 2<<20))
	response.Body.Close()
	if readErr != nil || len(audio) < 44 || !bytes.Equal(audio[:4], []byte("RIFF")) || !bytes.Equal(audio[8:12], []byte("WAVE")) {
		http.Error(w, "tts returned invalid audio", http.StatusBadGateway)
		return
	}
	if err := libraryRequest(ctx, client, http.MethodPut, base+"/"+name, bytes.NewReader(audio), "audio/wav"); err != nil {
		http.Error(w, "audio cache failed", http.StatusBadGateway)
		return
	}
	writeJSON(w, ttsResponse{Path: "/usr/share/freeswitch/sounds/avoip-shared/" + name})
}

func cacheKey(text, model, voice string) string {
	sum := sha256.Sum256([]byte(text + "\x00" + model + "\x00" + voice))
	return hex.EncodeToString(sum[:])[:32]
}

func libraryRequest(ctx context.Context, client *http.Client, method, url string, body io.Reader, contentType ...string) error {
	request, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return err
	}
	if len(contentType) > 0 {
		request.Header.Set("Content-Type", contentType[0])
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("audio library returned %d", response.StatusCode)
	}
	return nil
}
