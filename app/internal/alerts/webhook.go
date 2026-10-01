package alerts

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"time"
)

const MaxBodyBytes = 1 << 20

type webhookAlert struct {
	Status      string            `json:"status"`
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
	StartsAt    time.Time         `json:"startsAt"`
	EndsAt      time.Time         `json:"endsAt"`
	Fingerprint string            `json:"fingerprint"`
}

type webhookPayload struct {
	Status string          `json:"status"`
	Alerts *[]webhookAlert `json:"alerts"`
}

// NewWebhookHandler accepts Alertmanager webhook notifications and records one event per alert.
func NewWebhookHandler(store *Store, logger *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil || mediaType != "application/json" {
			http.Error(w, "Content-Type must be application/json", http.StatusUnsupportedMediaType)
			return
		}

		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBodyBytes))
		if err != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				http.Error(w, "payload exceeds 1MB", http.StatusRequestEntityTooLarge)
				return
			}
			logger.WarnContext(r.Context(), "could not read Alertmanager webhook body", "error", err)
			http.Error(w, "could not read payload", http.StatusBadRequest)
			return
		}

		var payload webhookPayload
		if err := json.Unmarshal(body, &payload); err != nil {
			logger.WarnContext(r.Context(), "malformed Alertmanager webhook payload", "error", err)
			http.Error(w, "malformed Alertmanager payload", http.StatusBadRequest)
			return
		}
		if payload.Alerts == nil {
			logger.WarnContext(r.Context(), "malformed Alertmanager webhook payload", "error", "missing alerts array")
			http.Error(w, "malformed Alertmanager payload: missing alerts", http.StatusBadRequest)
			return
		}

		received := time.Now().UTC()
		for _, alert := range *payload.Alerts {
			alertName := alert.Labels["alertname"]
			if alertName == "" {
				alertName = "UnnamedAlert"
			}
			status := StatusFiring
			if alert.Status == StatusResolved {
				status = StatusResolved
			}
			text, severity := Translate(alertName, status, alert.Labels["severity"])
			store.Add(Event{
				Timestamp:   received,
				Severity:    severity,
				Text:        text,
				AlertName:   alertName,
				Status:      status,
				Fingerprint: alert.Fingerprint,
				Summary:     alert.Annotations["summary"],
			})
		}

		logger.InfoContext(r.Context(), "Alertmanager notification received",
			"status", payload.Status, "alerts", len(*payload.Alerts))
		w.WriteHeader(http.StatusOK)
	}
}
