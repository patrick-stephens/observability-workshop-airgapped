package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/chaos"
	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/logging"
	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/telemetry"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

const (
	wrongBackendHostname = "backend.typo.svc.cluster.local"
	recentRequestLimit   = 10
)

// Scrape-path metrics: hand-picked, stable names served on /metrics from the default registry.
var (
	requestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "app_http_requests_total",
		Help: "Requests served on the API path, by service and HTTP status code.",
	}, []string{"service", "code"})
	requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "app_http_request_duration_seconds",
		Help:    "Latency of requests on the API path, by service.",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
	}, []string{"service"})
	chaosModeGauge = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "app_chaos_mode",
		Help: "1 for the service's active chaos mode, 0 for the others.",
	}, []string{"service", "mode"})
)

type Config struct {
	ServiceName string
	NextURL     string
	Chaos       *chaos.Controller
	Client      *http.Client
	Logger      *slog.Logger
	IndexHTML   []byte
	Business    *telemetry.BusinessMetrics
}

type RecentRequest struct {
	Time       time.Time `json:"time"`
	Status     int       `json:"status"`
	DurationMS float64   `json:"duration_ms"`
}

type Status struct {
	Service  string          `json:"service"`
	Mode     string          `json:"mode"`
	Requests []RecentRequest `json:"requests"`
}

type service struct {
	name      string
	nextURL   string
	chaos     *chaos.Controller
	client    *http.Client
	logger    *slog.Logger
	indexHTML []byte
	business  *telemetry.BusinessMetrics

	recentMutex sync.Mutex
	recent      []RecentRequest
}

func NewHandler(config Config) http.Handler {
	if config.Chaos == nil {
		config.Chaos = chaos.New()
	}
	if config.Client == nil {
		config.Client = NewHTTPClient()
	}
	if config.Logger == nil {
		config.Logger = logging.New(config.ServiceName)
	}
	if config.Business == nil {
		business, err := telemetry.NewBusinessMetrics()
		if err != nil {
			config.Logger.Warn("business metrics could not be created", "error", err)
		}
		config.Business = business
	}

	current := &service{
		name:      config.ServiceName,
		nextURL:   config.NextURL,
		chaos:     config.Chaos,
		client:    config.Client,
		logger:    config.Logger,
		indexHTML: config.IndexHTML,
		business:  config.Business,
	}
	current.publishChaosMode()
	if current.business != nil && current.name == "backend" {
		// Creates the series at zero so the countermeasure panel shows a flat line before the first error.
		current.business.CountermeasureLaunches.Add(context.Background(), 0)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", current.instrument(current.root))
	mux.HandleFunc("GET /healthz", health)
	mux.HandleFunc("GET /readyz", health)
	mux.HandleFunc("GET /chaos", current.setChaos)
	mux.HandleFunc("GET /status", current.status)
	if len(current.indexHTML) > 0 {
		mux.HandleFunc("GET /index.html", current.index)
	}
	mux.Handle("GET /metrics", promhttp.Handler())

	return otelhttp.NewHandler(mux, config.ServiceName)
}

func NewHTTPClient() *http.Client {
	return &http.Client{
		Transport: otelhttp.NewTransport(http.DefaultTransport),
		Timeout:   15 * time.Second,
	}
}

func Run(serviceName, nextURL string, indexHTML []byte) error {
	if configuredName := strings.TrimSpace(os.Getenv("OTEL_SERVICE_NAME")); configuredName != "" {
		serviceName = configuredName
	}

	logger := logging.New(serviceName)
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdownTelemetry, err := telemetry.Setup(ctx, serviceName, logger)
	if err != nil {
		return fmt.Errorf("initialise telemetry: %w", err)
	}
	defer func() {
		shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := shutdownTelemetry(shutdownContext); err != nil {
			logger.WarnContext(context.Background(), "telemetry shutdown failed", "error", err)
		}
	}()

	address := strings.TrimSpace(os.Getenv("LISTEN_ADDR"))
	if address == "" {
		address = ":8080"
	}

	httpServer := &http.Server{
		Addr:              address,
		Handler:           NewHandler(Config{ServiceName: serviceName, NextURL: nextURL, Logger: logger, IndexHTML: indexHTML}),
		ReadHeaderTimeout: 5 * time.Second,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelError),
	}

	serveErrors := make(chan error, 1)
	go func() {
		serveErrors <- httpServer.ListenAndServe()
	}()
	logger.InfoContext(ctx, "service listening", "address", address)

	select {
	case err := <-serveErrors:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("serve HTTP: %w", err)
	case <-ctx.Done():
		shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownContext); err != nil {
			return fmt.Errorf("shut down HTTP server: %w", err)
		}
		logger.Info("service stopped")
		return nil
	}
}

func (s *service) root(w http.ResponseWriter, r *http.Request) {
	s.countBusinessEvents(r.Context())
	switch s.chaos.Mode() {
	case chaos.ModeSlow:
		timer := time.NewTimer(2 * time.Second)
		defer timer.Stop()
		select {
		case <-r.Context().Done():
			return
		case <-timer.C:
		}
	case chaos.ModeError:
		if s.business != nil && s.name == "backend" {
			s.business.CountermeasureLaunches.Add(r.Context(), 1)
		}
		err := errors.New("upstream dependency failed")
		s.logger.ErrorContext(r.Context(), "chaos mode returned HTTP 500", "error", err)
		http.Error(w, "upstream dependency is unavailable", http.StatusInternalServerError)
		return
	case chaos.ModeDNS:
		lookupContext, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if _, err := net.DefaultResolver.LookupHost(lookupContext, wrongBackendHostname); err != nil {
			s.logger.ErrorContext(r.Context(), "chaos DNS lookup failed", "hostname", wrongBackendHostname, "error", err)
			http.Error(w, "upstream DNS resolution failed", http.StatusBadGateway)
			return
		}
	}

	if s.nextURL == "" {
		writeJSON(w, http.StatusOK, map[string]string{"service": s.name, "status": "ok"})
		return
	}

	request, err := http.NewRequestWithContext(r.Context(), http.MethodGet, s.nextURL, nil)
	if err != nil {
		s.logger.ErrorContext(r.Context(), "create upstream request", "error", err)
		http.Error(w, "upstream request could not be created", http.StatusBadGateway)
		return
	}

	response, err := s.client.Do(request)
	if err != nil {
		s.logger.ErrorContext(r.Context(), "upstream request failed", "upstream", s.nextURL, "error", err)
		http.Error(w, "upstream service is unavailable", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()

	for name, values := range response.Header {
		for _, value := range values {
			w.Header().Add(name, value)
		}
	}
	w.WriteHeader(response.StatusCode)
	if _, err := io.Copy(w, response.Body); err != nil {
		s.logger.ErrorContext(r.Context(), "copy upstream response", "error", err)
	}
}

func (s *service) setChaos(w http.ResponseWriter, r *http.Request) {
	mode := r.URL.Query().Get("mode")
	if err := s.chaos.Set(mode); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	s.logger.InfoContext(r.Context(), "chaos mode updated", "mode", mode)
	s.publishChaosMode()
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]string{"mode": mode})
}

// countBusinessEvents emits the OTLP-only business counters for one API-path request.
func (s *service) countBusinessEvents(ctx context.Context) {
	if s.business == nil {
		return
	}
	switch s.name {
	case "backend":
		s.business.TorpedoesDetected.Add(ctx, 1)
	case "api":
		s.business.SonarContactsDetected.Add(ctx, 1)
		// 1 in 3 surface and 1 in 5 submarine gives the intended 5:3 surface-to-submarine mix.
		if rand.IntN(3) == 0 {
			s.business.SurfaceShipContactsDetected.Add(ctx, 1)
		}
		if rand.IntN(5) == 0 {
			s.business.SubmarineContactsDetected.Add(ctx, 1)
		}
	}
}

func (s *service) publishChaosMode() {
	current := s.chaos.Mode()
	for _, mode := range []chaos.Mode{chaos.ModeOK, chaos.ModeSlow, chaos.ModeError, chaos.ModeDNS} {
		value := 0.0
		if mode == current {
			value = 1
		}
		chaosModeGauge.WithLabelValues(s.name, string(mode)).Set(value)
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	if r.status == 0 {
		r.status = status
	}
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(body []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(body)
}

func (s *service) instrument(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		recorder := &statusRecorder{ResponseWriter: w}
		next(recorder, r)
		if recorder.status == 0 {
			recorder.status = http.StatusOK
		}
		elapsed := time.Since(started)
		requestsTotal.WithLabelValues(s.name, strconv.Itoa(recorder.status)).Inc()
		requestDuration.WithLabelValues(s.name).Observe(elapsed.Seconds())

		s.recentMutex.Lock()
		s.recent = append([]RecentRequest{{
			Time:       started.UTC(),
			Status:     recorder.status,
			DurationMS: float64(elapsed.Microseconds()) / 1000,
		}}, s.recent...)
		if len(s.recent) > recentRequestLimit {
			s.recent = s.recent[:recentRequestLimit]
		}
		s.recentMutex.Unlock()
	}
}

func (s *service) status(w http.ResponseWriter, _ *http.Request) {
	s.recentMutex.Lock()
	requests := append([]RecentRequest{}, s.recent...)
	s.recentMutex.Unlock()

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, Status{Service: s.name, Mode: string(s.chaos.Mode()), Requests: requests})
}

func (s *service) index(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(s.indexHTML)
}

func health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "ok\n")
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Error("write JSON response", "error", err)
	}
}
