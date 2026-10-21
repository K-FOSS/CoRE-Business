package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
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

func runTTSCache(logger *slog.Logger) error {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("POST /v1/tts", func(w http.ResponseWriter, r *http.Request) { handleTTSRequest(logger, w, r) })
	return http.ListenAndServe(":8080", mux)
}

func handleTTSRequest(logger *slog.Logger, w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	if r.Header.Get("X-AVoIP-TTS-Internal") != os.Getenv("AVOIP_BRIDGED_TTS_INTERNAL_TOKEN") || os.Getenv("AVOIP_BRIDGED_TTS_INTERNAL_TOKEN") == "" {
		logger.Warn("tts cache request rejected", "failure_stage", "internal_auth", "response_status", http.StatusForbidden)
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var input ttsRequest
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&input) != nil || strings.TrimSpace(input.Text) == "" || len(input.Text) > 240 {
		logger.Warn("tts cache request rejected", "failure_stage", "validate_request", "response_status", http.StatusBadRequest)
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
		logger.Error("tts cache request failed", "failure_stage", "validate_configuration", "error_class", "missing_model_or_voice", "response_status", http.StatusServiceUnavailable)
		http.Error(w, "tts configuration unavailable", http.StatusServiceUnavailable)
		return
	}
	name := "tts-cache-" + cacheKey(input.Text, model, voice) + ".wav"
	key := strings.TrimSuffix(strings.TrimPrefix(name, "tts-cache-"), ".wav")
	base := strings.TrimRight(strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_AUDIO_LIBRARY_URL")), "/")
	if base == "" {
		logger.Error("tts cache request failed", "failure_stage", "validate_audio_library", "cache_key", key, "response_status", http.StatusServiceUnavailable)
		http.Error(w, "audio library unavailable", http.StatusServiceUnavailable)
		return
	}
	logger.Debug("tts cache request started", "cache_key", key, "model", model, "voice", voice, "text_bytes", len(input.Text))
	ctx, cancel := context.WithTimeout(r.Context(), 35*time.Second)
	defer cancel()
	client := &http.Client{Timeout: 30 * time.Second}
	cacheCheckStarted := time.Now()
	cacheErr := libraryRequest(ctx, client, http.MethodHead, base+"/"+name, nil, "")
	if cacheErr == nil {
		logger.Info("tts cache hit", "cache_key", key, "model", model, "voice", voice, "duration_ms", time.Since(cacheCheckStarted).Milliseconds(), "total_duration_ms", time.Since(started).Milliseconds())
		writeJSON(w, ttsResponse{Path: "/usr/share/freeswitch/sounds/avoip-shared/" + name})
		return
	}
	logger.Debug("tts cache miss", "cache_key", key, "duration_ms", time.Since(cacheCheckStarted).Milliseconds(), "error_class", fmt.Sprintf("%T", cacheErr))
	ttsURL := strings.TrimRight(strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_TTS_URL")), "/")
	if ttsURL == "" {
		logger.Error("tts cache request failed", "failure_stage", "validate_tts_endpoint", "cache_key", key, "response_status", http.StatusServiceUnavailable)
		http.Error(w, "tts endpoint unavailable", http.StatusServiceUnavailable)
		return
	}
	body, _ := json.Marshal(map[string]string{"model": model, "input": input.Text, "voice": voice, "response_format": "wav"})
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, ttsURL, bytes.NewReader(body))
	if err != nil {
		logger.Error("tts cache request failed", "failure_stage", "build_gpu_request", "cache_key", key, "error_class", fmt.Sprintf("%T", err), "response_status", http.StatusBadGateway)
		http.Error(w, "tts request failed", http.StatusBadGateway)
		return
	}
	request.Header.Set("Content-Type", "application/json")
	if token := strings.TrimSpace(os.Getenv("AVOIP_BRIDGED_TTS_TOKEN")); token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	gpuStarted := time.Now()
	response, err := client.Do(request)
	if err != nil || response.StatusCode < 200 || response.StatusCode >= 300 {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		logger.Error("tts GPUStack request failed", "failure_stage", "gpu_request", "cache_key", key, "model", model, "voice", voice, "http_status", status, "duration_ms", time.Since(gpuStarted).Milliseconds(), "error_class", errorClass(err))
		if response != nil {
			response.Body.Close()
		}
		http.Error(w, "tts request failed", http.StatusBadGateway)
		return
	}
	audio, readErr := io.ReadAll(io.LimitReader(response.Body, 2<<20))
	response.Body.Close()
	if readErr != nil || len(audio) < 44 || !bytes.Equal(audio[:4], []byte("RIFF")) || !bytes.Equal(audio[8:12], []byte("WAVE")) {
		logger.Error("tts GPUStack response invalid", "failure_stage", "validate_audio", "cache_key", key, "model", model, "voice", voice, "audio_bytes", len(audio), "duration_ms", time.Since(gpuStarted).Milliseconds(), "error_class", errorClass(readErr))
		http.Error(w, "tts returned invalid audio", http.StatusBadGateway)
		return
	}
	storeStarted := time.Now()
	if err := libraryRequest(ctx, client, http.MethodPut, base+"/"+name, bytes.NewReader(audio), "audio/wav"); err != nil {
		logger.Error("tts audio cache write failed", "failure_stage", "store_audio", "cache_key", key, "audio_bytes", len(audio), "duration_ms", time.Since(storeStarted).Milliseconds(), "error_class", fmt.Sprintf("%T", err))
		http.Error(w, "audio cache failed", http.StatusBadGateway)
		return
	}
	logger.Info("tts cache generated", "cache_key", key, "model", model, "voice", voice, "audio_bytes", len(audio), "gpu_duration_ms", time.Since(gpuStarted).Milliseconds(), "store_duration_ms", time.Since(storeStarted).Milliseconds(), "total_duration_ms", time.Since(started).Milliseconds())
	writeJSON(w, ttsResponse{Path: "/usr/share/freeswitch/sounds/avoip-shared/" + name})
}

func errorClass(err error) string {
	if err == nil {
		return ""
	}
	return fmt.Sprintf("%T", err)
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
