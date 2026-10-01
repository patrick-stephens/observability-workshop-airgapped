package alerts

import (
	"bytes"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestTranslate(t *testing.T) {
	cases := []struct {
		name, status, severity, wantText, wantSeverity string
	}{
		{"TorpedoDetected", StatusFiring, "critical", "TORPEDO DETECTED", SeverityCritical},
		{"TorpedoDetected", StatusResolved, "critical", "CLEAR — TORPEDO DETECTED", SeverityOK},
		{"DemoHighErrorRate", StatusFiring, "warning", "Contact lost — elevated error rate", SeverityWarning},
		{"BrandNewRule", StatusFiring, "critical", "BrandNewRule", SeverityWarning},
	}
	for _, c := range cases {
		text, severity := Translate(c.name, c.status, c.severity)
		if text != c.wantText || severity != c.wantSeverity {
			t.Errorf("Translate(%q, %q) = %q, %q; want %q, %q", c.name, c.status, text, severity, c.wantText, c.wantSeverity)
		}
	}
}

func TestStoreIsBoundedNewestFirstAndDeduplicatesFiring(t *testing.T) {
	store := NewStore()
	for i := range Capacity + 10 {
		store.Add(Event{AlertName: fmt.Sprintf("A%d", i), Status: StatusResolved})
	}
	events := store.Events()
	if len(events) != Capacity || events[0].AlertName != fmt.Sprintf("A%d", Capacity+9) {
		t.Fatalf("got %d events, newest %q", len(events), events[0].AlertName)
	}

	store = NewStore()
	firing := Event{AlertName: "TorpedoDetected", Fingerprint: "f1", Status: StatusFiring, Severity: SeverityCritical}
	store.Add(firing)
	store.Add(firing)
	if len(store.Events()) != 1 || len(store.Firing()) != 1 {
		t.Fatalf("repeat firing notification was not deduplicated: %+v", store.Events())
	}
	store.Add(Event{AlertName: "TorpedoDetected", Fingerprint: "f1", Status: StatusResolved, Severity: SeverityOK})
	if len(store.Events()) != 2 || len(store.Firing()) != 0 {
		t.Fatalf("resolve did not clear the active alert: %+v", store.Firing())
	}
}

func TestStoreConcurrentUse(t *testing.T) {
	store := NewStore()
	var wait sync.WaitGroup
	for i := range 8 {
		wait.Add(2)
		go func() {
			defer wait.Done()
			for j := range 200 {
				store.Add(Event{AlertName: fmt.Sprintf("A%d-%d", i, j), Status: StatusFiring})
			}
		}()
		go func() {
			defer wait.Done()
			for range 200 {
				_ = store.Events()
				_ = store.Firing()
			}
		}()
	}
	wait.Wait()
}

func post(t *testing.T, handler http.Handler, contentType string, body io.Reader) int {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/webhook/alertmanager", body)
	request.Header.Set("Content-Type", contentType)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder.Code
}

func TestWebhookHandler(t *testing.T) {
	store := NewStore()
	handler := NewWebhookHandler(store, slog.New(slog.NewTextHandler(io.Discard, nil)))
	valid := `{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"TorpedoDetected","severity":"critical"},
		"annotations":{"summary":"Torpedo contact"},"startsAt":"2026-10-01T00:00:00Z","fingerprint":"abc"}]}`

	if code := post(t, handler, "text/plain", strings.NewReader(valid)); code != http.StatusUnsupportedMediaType {
		t.Errorf("wrong content type: %d", code)
	}
	if code := post(t, handler, "application/json", bytes.NewReader(make([]byte, MaxBodyBytes+1))); code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized body: %d", code)
	}
	for _, malformed := range []string{`{`, `[]`, `{"status":"firing"}`, `{"alerts":"nope"}`, ``} {
		if code := post(t, handler, "application/json", strings.NewReader(malformed)); code != http.StatusBadRequest {
			t.Errorf("malformed %q: %d", malformed, code)
		}
	}
	if code := post(t, handler, "application/json; charset=utf-8", strings.NewReader(valid)); code != http.StatusOK {
		t.Fatalf("valid payload: %d", code)
	}
	events := store.Events()
	if len(events) != 1 || events[0].Text != "TORPEDO DETECTED" || events[0].Severity != SeverityCritical ||
		events[0].Summary != "Torpedo contact" || events[0].Fingerprint != "abc" {
		t.Fatalf("unexpected events: %+v", events)
	}
}
