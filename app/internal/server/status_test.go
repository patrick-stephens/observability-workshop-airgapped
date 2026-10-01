package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/alerts"
	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/chaos"
	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/logging"
	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/telemetry"
	"go.opentelemetry.io/otel"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
)

func get(t *testing.T, url string) (int, string) {
	t.Helper()
	response, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return response.StatusCode, string(body)
}

func TestStatusReportsModeAndRecentRequests(t *testing.T) {
	server := httptest.NewServer(NewHandler(Config{
		ServiceName: "backend",
		Chaos:       chaos.New(),
		Logger:      logging.NewWithWriter("backend", io.Discard),
	}))
	defer server.Close()

	get(t, server.URL+"/chaos?mode=error")
	for range 12 {
		get(t, server.URL+"/")
	}

	code, body := get(t, server.URL+"/status")
	if code != http.StatusOK {
		t.Fatalf("status code = %d", code)
	}
	var status Status
	if err := json.Unmarshal([]byte(body), &status); err != nil {
		t.Fatal(err)
	}
	if status.Service != "backend" || status.Mode != "error" {
		t.Fatalf("status = %+v", status)
	}
	if len(status.Requests) != recentRequestLimit {
		t.Fatalf("recent requests = %d, want %d", len(status.Requests), recentRequestLimit)
	}
	if status.Requests[0].Status != http.StatusInternalServerError {
		t.Fatalf("latest request status = %d", status.Requests[0].Status)
	}
}

func TestIndexHTMLOnlyServedWhenConfigured(t *testing.T) {
	withPage := httptest.NewServer(NewHandler(Config{
		ServiceName: "frontend",
		Logger:      logging.NewWithWriter("frontend", io.Discard),
		IndexHTML:   []byte("<html>status</html>"),
	}))
	defer withPage.Close()
	if code, body := get(t, withPage.URL+"/index.html"); code != http.StatusOK || !strings.Contains(body, "status") {
		t.Fatalf("index.html = %d %q", code, body)
	}

	withoutPage := httptest.NewServer(NewHandler(Config{
		ServiceName: "api",
		Logger:      logging.NewWithWriter("api", io.Discard),
	}))
	defer withoutPage.Close()
	if code, _ := get(t, withoutPage.URL+"/index.html"); code != http.StatusNotFound {
		t.Fatalf("index.html without page = %d, want 404", code)
	}
}

func TestScrapeMetricsExcludeBusinessCounters(t *testing.T) {
	server := httptest.NewServer(NewHandler(Config{
		ServiceName: "backend",
		Logger:      logging.NewWithWriter("backend", io.Discard),
	}))
	defer server.Close()
	get(t, server.URL+"/")

	_, body := get(t, server.URL+"/metrics")
	for _, wanted := range []string{"app_http_requests_total", "app_http_request_duration_seconds", `app_chaos_mode{mode="ok",service="backend"} 1`} {
		if !strings.Contains(body, wanted) {
			t.Fatalf("/metrics is missing %q", wanted)
		}
	}
	for _, unwanted := range []string{"torpedoes", "countermeasure", "sonar"} {
		if strings.Contains(body, unwanted) {
			t.Fatalf("/metrics exposes OTLP-only business metric %q", unwanted)
		}
	}
}

func TestCountermeasuresOnlyLaunchInErrorMode(t *testing.T) {
	reader := sdkmetric.NewManualReader()
	provider := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	defer provider.Shutdown(context.Background())
	otel.SetMeterProvider(provider)
	business, err := telemetry.NewBusinessMetrics()
	if err != nil {
		t.Fatal(err)
	}

	server := httptest.NewServer(NewHandler(Config{
		ServiceName: "backend",
		Logger:      logging.NewWithWriter("backend", io.Discard),
		Business:    business,
	}))
	defer server.Close()

	get(t, server.URL+"/")
	get(t, server.URL+"/chaos?mode=error")
	get(t, server.URL+"/")
	get(t, server.URL+"/")
	get(t, server.URL+"/chaos?mode=ok")
	get(t, server.URL+"/")

	var collected metricdata.ResourceMetrics
	if err := reader.Collect(context.Background(), &collected); err != nil {
		t.Fatal(err)
	}
	totals := map[string]int64{}
	for _, scope := range collected.ScopeMetrics {
		if scope.Scope.Name != "demo" {
			continue
		}
		for _, item := range scope.Metrics {
			for _, point := range item.Data.(metricdata.Sum[int64]).DataPoints {
				totals[item.Name] += point.Value
			}
		}
	}
	if totals["torpedoes.detected"] != 0 || totals["countermeasure.launches"] != 2 {
		t.Fatalf("business totals = %v, want 0 request-driven torpedoes and 2 countermeasures", totals)
	}
}

func TestTorpedoModeRaisesSensorRateWithoutRequestImpact(t *testing.T) {
	reader := sdkmetric.NewManualReader()
	provider := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	defer provider.Shutdown(context.Background())
	otel.SetMeterProvider(provider)
	business, err := telemetry.NewBusinessMetrics()
	if err != nil {
		t.Fatal(err)
	}
	controller := chaos.New()
	server := httptest.NewServer(NewHandler(Config{
		ServiceName: "backend",
		Chaos:       controller,
		Logger:      logging.NewWithWriter("backend", io.Discard),
		Business:    business,
	}))
	defer server.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go RunTorpedoSensor(ctx, controller, business, 50*time.Millisecond, time.Millisecond)

	count := func() int64 {
		var collected metricdata.ResourceMetrics
		if err := reader.Collect(context.Background(), &collected); err != nil {
			t.Fatal(err)
		}
		for _, scope := range collected.ScopeMetrics {
			for _, item := range scope.Metrics {
				if item.Name == "torpedoes.detected" {
					return item.Data.(metricdata.Sum[int64]).DataPoints[0].Value
				}
			}
		}
		return 0
	}

	time.Sleep(300 * time.Millisecond)
	baseline := count()
	get(t, server.URL+"/chaos?mode=torpedo")
	time.Sleep(300 * time.Millisecond)
	attack := count() - baseline
	if attack < 5*baseline || attack < 20 {
		t.Fatalf("torpedo mode detections = %d over the same window as baseline %d", attack, baseline)
	}
	if code, _ := get(t, server.URL+"/"); code != http.StatusOK {
		t.Fatalf("torpedo mode request status = %d, want 200", code)
	}
}

func TestStatusIncludesWebhookEvents(t *testing.T) {
	server := httptest.NewServer(NewHandler(Config{
		ServiceName: "frontend",
		Logger:      logging.NewWithWriter("frontend", io.Discard),
		Alerts:      alerts.NewStore(),
	}))
	defer server.Close()

	payload := `{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"PreflightTest"},"fingerprint":"p1"}]}`
	response, err := http.Post(server.URL+"/webhook/alertmanager", "application/json", strings.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("webhook status = %d", response.StatusCode)
	}

	_, body := get(t, server.URL+"/status")
	var status Status
	if err := json.Unmarshal([]byte(body), &status); err != nil {
		t.Fatal(err)
	}
	if len(status.Events) != 1 || status.Events[0].AlertName != "PreflightTest" || len(status.Firing) != 1 {
		t.Fatalf("status = %+v", status)
	}
}
