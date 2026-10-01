package telemetry

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const meterName = "demo"

// Business counters travel OTLP only; they are deliberately absent from /metrics.
type BusinessMetrics struct {
	TorpedoesDetected           metric.Int64Counter
	SonarContactsDetected       metric.Int64Counter
	SurfaceShipContactsDetected metric.Int64Counter
	SubmarineContactsDetected   metric.Int64Counter
	CountermeasureLaunches      metric.Int64Counter
}

func Meter() metric.Meter {
	return otel.Meter(meterName)
}

func NewBusinessMetrics() (*BusinessMetrics, error) {
	meter := Meter()
	var err error
	metrics := &BusinessMetrics{}
	if metrics.TorpedoesDetected, err = meter.Int64Counter("torpedoes.detected",
		metric.WithUnit("{torpedo}"), metric.WithDescription("Torpedoes detected by command and control.")); err != nil {
		return nil, err
	}
	if metrics.SonarContactsDetected, err = meter.Int64Counter("sonar.contacts.detected",
		metric.WithUnit("{contact}"), metric.WithDescription("Sonar contacts processed.")); err != nil {
		return nil, err
	}
	if metrics.SurfaceShipContactsDetected, err = meter.Int64Counter("surface.ship.contacts.detected",
		metric.WithUnit("{contact}"), metric.WithDescription("Sonar contacts classified as surface ships.")); err != nil {
		return nil, err
	}
	if metrics.SubmarineContactsDetected, err = meter.Int64Counter("submarine.contacts.detected",
		metric.WithUnit("{contact}"), metric.WithDescription("Sonar contacts classified as submarines.")); err != nil {
		return nil, err
	}
	if metrics.CountermeasureLaunches, err = meter.Int64Counter("countermeasure.launches",
		metric.WithUnit("{launch}"), metric.WithDescription("Countermeasures launched while the backend is failing.")); err != nil {
		return nil, err
	}
	return metrics, nil
}

func Setup(ctx context.Context, serviceName string, logger interface {
	WarnContext(context.Context, string, ...any)
}) (func(context.Context) error, error) {
	serviceResource := resource.NewWithAttributes("", attribute.String("service.name", serviceName))
	traceOptions := []trace.TracerProviderOption{trace.WithResource(serviceResource)}
	meterOptions := []sdkmetric.Option{sdkmetric.WithResource(serviceResource)}
	var connection *grpc.ClientConn

	endpoint := strings.TrimSpace(os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"))
	if endpoint == "" {
		logger.WarnContext(ctx, "OTLP export is disabled because OTEL_EXPORTER_OTLP_ENDPOINT is unset")
	} else {
		var err error
		connection, err = newOTLPConnection(endpoint)
		if err != nil {
			logger.WarnContext(ctx, "OTLP connection could not be initialised", "error", err)
		} else {
			// The Go SDK has one exporter type per signal; both share this single OTLP gRPC connection.
			traceExporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithGRPCConn(connection))
			if err != nil {
				logger.WarnContext(ctx, "OTLP trace exporter could not be initialised", "error", err)
			} else {
				traceOptions = append(traceOptions, trace.WithBatcher(traceExporter))
			}
			metricExporter, err := otlpmetricgrpc.New(ctx, otlpmetricgrpc.WithGRPCConn(connection))
			if err != nil {
				logger.WarnContext(ctx, "OTLP metric exporter could not be initialised", "error", err)
			} else {
				meterOptions = append(meterOptions, sdkmetric.WithReader(
					sdkmetric.NewPeriodicReader(metricExporter, sdkmetric.WithInterval(10*time.Second))))
			}
		}
	}

	tracerProvider := trace.NewTracerProvider(traceOptions...)
	otel.SetTracerProvider(tracerProvider)
	meterProvider := sdkmetric.NewMeterProvider(meterOptions...)
	otel.SetMeterProvider(meterProvider)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return func(shutdownContext context.Context) error {
		err := errors.Join(tracerProvider.Shutdown(shutdownContext), meterProvider.Shutdown(shutdownContext))
		if connection != nil {
			err = errors.Join(err, connection.Close())
		}
		return err
	}, nil
}

func newOTLPConnection(endpoint string) (*grpc.ClientConn, error) {
	target := endpoint
	if strings.Contains(endpoint, "://") {
		parsed, err := url.Parse(endpoint)
		if err != nil {
			return nil, fmt.Errorf("parse OTEL_EXPORTER_OTLP_ENDPOINT: %w", err)
		}
		if parsed.Scheme == "https" {
			return nil, errors.New("OTEL_EXPORTER_OTLP_ENDPOINT uses https, but the offline demo collector is plaintext")
		}
		target = parsed.Host
	}
	return grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
}
