package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/chaos"
	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/logging"
	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/telemetry"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

const wrongBackendHostname = "backend.typo.svc.cluster.local"

type Config struct {
	ServiceName string
	NextURL     string
	Chaos       *chaos.Controller
	Client      *http.Client
	Logger      *slog.Logger
}

type service struct {
	name    string
	nextURL string
	chaos   *chaos.Controller
	client  *http.Client
	logger  *slog.Logger
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

	current := &service{
		name:    config.ServiceName,
		nextURL: config.NextURL,
		chaos:   config.Chaos,
		client:  config.Client,
		logger:  config.Logger,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", current.root)
	mux.HandleFunc("GET /healthz", health)
	mux.HandleFunc("GET /readyz", health)
	mux.HandleFunc("GET /chaos", current.setChaos)
	mux.Handle("GET /metrics", promhttp.Handler())

	return otelhttp.NewHandler(mux, config.ServiceName)
}

func NewHTTPClient() *http.Client {
	return &http.Client{
		Transport: otelhttp.NewTransport(http.DefaultTransport),
		Timeout:   15 * time.Second,
	}
}

func Run(serviceName, nextURL string) error {
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
		Handler:           NewHandler(Config{ServiceName: serviceName, NextURL: nextURL, Logger: logger}),
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
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]string{"mode": mode})
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
