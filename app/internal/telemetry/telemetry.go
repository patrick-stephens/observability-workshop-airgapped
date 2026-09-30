package telemetry

import (
	"context"
	"os"
	"strings"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
)

func Setup(ctx context.Context, serviceName string, logger interface {
	WarnContext(context.Context, string, ...any)
}) (func(context.Context) error, error) {
	serviceResource := resource.NewWithAttributes("", attribute.String("service.name", serviceName))
	providerOptions := []trace.TracerProviderOption{trace.WithResource(serviceResource)}

	if strings.TrimSpace(os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")) == "" {
		logger.WarnContext(ctx, "OTLP trace export is disabled because OTEL_EXPORTER_OTLP_ENDPOINT is unset")
	} else {
		exporter, err := otlptracegrpc.New(ctx)
		if err != nil {
			logger.WarnContext(ctx, "OTLP trace exporter could not be initialised", "error", err)
		} else {
			providerOptions = append(providerOptions, trace.WithBatcher(exporter))
		}
	}

	provider := trace.NewTracerProvider(providerOptions...)
	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return provider.Shutdown, nil
}
