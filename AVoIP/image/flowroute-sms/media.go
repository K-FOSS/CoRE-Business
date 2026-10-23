package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

const maxUploadBytes = 750 << 10

type mediaStore struct {
	client    *s3.Client
	bucket    string
	secret    []byte
	proxyBase string
}

func newOptionalMediaStore(ctx context.Context) (*mediaStore, error) {
	if strings.TrimSpace(os.Getenv("MEDIA_S3_ENDPOINT")) == "" {
		return nil, nil
	}
	return newMediaStore(ctx)
}

func newMediaStore(ctx context.Context) (*mediaStore, error) {
	endpoint := strings.TrimSpace(os.Getenv("MEDIA_S3_ENDPOINT"))
	bucket := strings.TrimSpace(os.Getenv("MEDIA_S3_BUCKET"))
	region := strings.TrimSpace(os.Getenv("MEDIA_S3_REGION"))
	accessKey := os.Getenv("MEDIA_S3_ACCESS_KEY")
	secretKey := os.Getenv("MEDIA_S3_SECRET_KEY")
	proxySecret := os.Getenv("MEDIA_PROXY_SECRET")
	missing := make([]string, 0, 6)
	if endpoint == "" {
		missing = append(missing, "MEDIA_S3_ENDPOINT")
	}
	if bucket == "" {
		missing = append(missing, "MEDIA_S3_BUCKET")
	}
	if region == "" {
		missing = append(missing, "MEDIA_S3_REGION")
	}
	if accessKey == "" {
		missing = append(missing, "MEDIA_S3_ACCESS_KEY")
	}
	if secretKey == "" {
		missing = append(missing, "MEDIA_S3_SECRET_KEY")
	}
	if len(proxySecret) < 32 {
		missing = append(missing, "MEDIA_PROXY_SECRET (minimum 32 bytes)")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("media S3 and proxy configuration is incomplete: missing %s", strings.Join(missing, ", "))
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(region), awsconfig.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(accessKey, secretKey, "")))
	if err != nil {
		return nil, fmt.Errorf("load media S3 configuration: %w", err)
	}
	client := s3.NewFromConfig(cfg, func(options *s3.Options) {
		options.BaseEndpoint = aws.String(endpoint)
		options.UsePathStyle = true
	})
	return &mediaStore{client: client, bucket: bucket, secret: []byte(proxySecret), proxyBase: strings.TrimRight(strings.TrimSpace(os.Getenv("MEDIA_PROXY_BASE_URL")), "/")}, nil
}

func (s *server) uploadMedia(w http.ResponseWriter, r *http.Request) {
	if s.mediaStore == nil || strings.TrimSpace(r.Header.Get("X-Authentik-Username")) == "" || !sameOrigin(r) {
		http.Error(w, "media upload unavailable", http.StatusForbidden)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBytes+32<<10)
	if err := r.ParseMultipartForm(maxUploadBytes); err != nil {
		http.Error(w, "attachment is too large", http.StatusRequestEntityTooLarge)
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "attachment is required", http.StatusBadRequest)
		return
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, maxUploadBytes+1))
	if err != nil || len(content) == 0 || len(content) > maxUploadBytes {
		http.Error(w, "attachment is too large", http.StatusRequestEntityTooLarge)
		return
	}
	mimeType := mime.TypeByExtension(strings.ToLower(filepath.Ext(header.Filename)))
	if mimeType == "" {
		mimeType = http.DetectContentType(content)
	}
	if !strings.HasPrefix(mimeType, "image/") {
		http.Error(w, "only image attachments are supported", http.StatusUnsupportedMediaType)
		return
	}
	id := newUUID()
	key := "sms-media/" + id
	if _, err = s.mediaStore.client.PutObject(r.Context(), &s3.PutObjectInput{Bucket: aws.String(s.mediaStore.bucket), Key: aws.String(key), Body: bytes.NewReader(content), ContentType: aws.String(mimeType)}); err != nil {
		http.Error(w, "attachment storage unavailable", http.StatusBadGateway)
		return
	}
	name := filepath.Base(header.Filename)
	if name == "." || name == "/" || name == "" {
		name = id
	}
	_, err = s.pool.Exec(r.Context(), `INSERT INTO public.sms_outbound_media(id,owner,object_key,file_name,mime_type,size_bytes) VALUES($1,$2,$3,$4,$5,$6)`, id, r.Header.Get("X-Authentik-Username"), key, name, mimeType, len(content))
	if err != nil {
		_, _ = s.mediaStore.client.DeleteObject(r.Context(), &s3.DeleteObjectInput{Bucket: aws.String(s.mediaStore.bucket), Key: aws.String(key)})
		http.Error(w, "attachment could not be recorded", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, map[string]any{"id": id, "file_name": name, "mime_type": mimeType, "size": len(content)})
}

func inboundMediaObjectKey(mediaID string) string {
	digest := sha256.Sum256([]byte(mediaID))
	return "sms-media/inbound/" + fmt.Sprintf("%x", digest[:])
}

func (s *server) storeInboundMedia(ctx context.Context, mediaID, fileName, mimeType string, content []byte) (string, error) {
	if s.mediaStore == nil {
		return "", fmt.Errorf("media S3 is not configured")
	}
	key := inboundMediaObjectKey(mediaID)
	_, err := s.mediaStore.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(s.mediaStore.bucket),
		Key:         aws.String(key),
		Body:        bytes.NewReader(content),
		ContentType: aws.String(mimeType),
		Metadata:    map[string]string{"file-name": safeFileName(fileName)},
	})
	return key, err
}

func (s *server) mediaURL(ctx context.Context, id, owner string) (string, error) {
	if s.mediaStore == nil || s.mediaStore.proxyBase == "" {
		return "", fmt.Errorf("media proxy is not configured")
	}
	var key, mimeType string
	if err := s.pool.QueryRow(ctx, `SELECT object_key,mime_type FROM public.sms_outbound_media WHERE id=$1 AND owner=$2`, id, owner).Scan(&key, &mimeType); err != nil {
		return "", err
	}
	expires := time.Now().Add(15 * time.Minute).Unix()
	payload := strconv.FormatInt(expires, 10) + "\n" + key + "\n" + mimeType
	encoded := base64.RawURLEncoding.EncodeToString([]byte(payload))
	mac := hmac.New(sha256.New, s.mediaStore.secret)
	mac.Write([]byte(encoded))
	signature := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return s.mediaStore.proxyBase + "/media/" + encoded + "." + signature, nil
}

func (s *server) serveProxyMedia(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	stage := "validate_store"
	outcome := "failed"
	status := http.StatusNotFound
	objectKeyHash := ""
	errorType := ""
	defer func() {
		if s.logger == nil {
			return
		}
		attrs := []any{
			"stage", stage,
			"outcome", outcome,
			"response_status", status,
			"duration_ms", time.Since(started).Milliseconds(),
			"token_bytes", len(r.PathValue("token")),
		}
		if errorType != "" {
			attrs = append(attrs, "error_type", errorType)
		}
		if objectKeyHash != "" {
			attrs = append(attrs, "object_key_hash", objectKeyHash)
		}
		if outcome == "success" {
			s.logger.Log(r.Context(), slog.LevelDebug, "SMS media proxy request completed", attrs...)
		} else {
			s.logger.Warn("SMS media proxy request failed", attrs...)
		}
	}()
	notFound := func(nextStage string) {
		stage = nextStage
		http.NotFound(w, r)
	}
	if s.mediaStore == nil {
		notFound("validate_store")
		return
	}
	stage = "validate_token"
	parts := strings.Split(r.PathValue("token"), ".")
	if len(parts) != 2 {
		notFound("validate_token_format")
		return
	}
	mac := hmac.New(sha256.New, s.mediaStore.secret)
	mac.Write([]byte(parts[0]))
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || !hmac.Equal(signature, mac.Sum(nil)) {
		notFound("validate_signature")
		return
	}
	stage = "decode_payload"
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		notFound("decode_payload")
		return
	}
	fields := strings.Split(string(payload), "\n")
	if len(fields) != 3 || len(fields[1]) == 0 || len(fields[2]) == 0 {
		notFound("validate_payload")
		return
	}
	objectDigest := sha256.Sum256([]byte(fields[1]))
	objectKeyHash = fmt.Sprintf("%x", objectDigest[:6])
	stage = "validate_expiry"
	expires, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil || time.Now().After(time.Unix(expires, 0)) {
		notFound("validate_expiry")
		return
	}
	stage = "s3_get_object"
	object, err := s.mediaStore.client.GetObject(r.Context(), &s3.GetObjectInput{Bucket: aws.String(s.mediaStore.bucket), Key: aws.String(fields[1])})
	if err != nil {
		errorType = fmt.Sprintf("%T", err)
		notFound("s3_get_object")
		return
	}
	defer object.Body.Close()
	stage = "stream_object"
	w.Header().Set("Content-Type", fields[2])
	w.Header().Set("Cache-Control", "private, max-age=60")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	bytesWritten, copyErr := io.CopyN(w, object.Body, maxUploadBytes)
	if copyErr != nil && !errors.Is(copyErr, io.EOF) {
		if s.logger != nil {
			s.logger.Warn("SMS media proxy stream failed", "stage", "stream_object", "error_type", fmt.Sprintf("%T", copyErr), "bytes", bytesWritten, "object_key_hash", objectKeyHash)
		}
		return
	}
	status = http.StatusOK
	outcome = "success"
}
