package server

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/chaos"
	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/logging"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	oteltrace "go.opentelemetry.io/otel/trace"
)

func TestChaosModeTakesEffectAndCanBeReset(t *testing.T) {
	handler := NewHandler(Config{
		ServiceName: "backend",
		Chaos:       chaos.New(),
		Logger:      logging.NewWithWriter("backend", io.Discard),
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	response, err := http.Get(server.URL + "/chaos?mode=error")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("chaos status = %d, want %d", response.StatusCode, http.StatusOK)
	}

	response, err = http.Get(server.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	body, readErr := io.ReadAll(response.Body)
	response.Body.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	if response.StatusCode != http.StatusInternalServerError {
		t.Fatalf("error mode status = %d, want %d", response.StatusCode, http.StatusInternalServerError)
	}
	if !strings.Contains(string(body), "upstream dependency is unavailable") {
		t.Fatalf("error body = %q", body)
	}

	response, err = http.Get(server.URL + "/chaos?mode=ok")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	response, err = http.Get(server.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("reset mode status = %d, want %d", response.StatusCode, http.StatusOK)
	}
}

func TestTraceContextPropagatesToNextService(t *testing.T) {
	provider := sdktrace.NewTracerProvider()
	defer provider.Shutdown(context.Background())
	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.TraceContext{})

	backendSpan := make(chan oteltrace.SpanContext, 1)
	backend := httptest.NewServer(otelhttp.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		backendSpan <- oteltrace.SpanFromContext(r.Context()).SpanContext()
		w.WriteHeader(http.StatusOK)
	}), "backend"))
	defer backend.Close()

	api := httptest.NewServer(NewHandler(Config{
		ServiceName: "api",
		NextURL:     backend.URL,
		Logger:      logging.NewWithWriter("api", io.Discard),
	}))
	defer api.Close()

	ctx, frontendSpan := otel.Tracer("frontend").Start(context.Background(), "frontend request")
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, api.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := NewHTTPClient().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	frontendSpan.End()

	select {
	case backendContext := <-backendSpan:
		if !backendContext.IsValid() {
			t.Fatal("backend span context is invalid")
		}
		if backendContext.TraceID() != frontendSpan.SpanContext().TraceID() {
			t.Fatalf("backend trace ID = %s, want frontend trace ID %s", backendContext.TraceID(), frontendSpan.SpanContext().TraceID())
		}
	case <-ctx.Done():
		t.Fatalf("request context ended before backend received the request: %v", ctx.Err())
	}
}
