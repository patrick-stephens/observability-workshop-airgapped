package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

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
	if totals["torpedoes.detected"] != 4 || totals["countermeasure.launches"] != 2 {
		t.Fatalf("business totals = %v, want 4 torpedoes and 2 countermeasures", totals)
	}
}
