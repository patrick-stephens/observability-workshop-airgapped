package logging

import (
	"context"
	"io"
	"log/slog"
	"os"

	"go.opentelemetry.io/otel/trace"
)

type traceHandler struct {
	inner   slog.Handler
	service string
}

func New(service string) *slog.Logger {
	return NewWithWriter(service, os.Stdout)
}

func NewWithWriter(service string, output io.Writer) *slog.Logger {
	inner := slog.NewJSONHandler(output, &slog.HandlerOptions{
		ReplaceAttr: func(groups []string, attr slog.Attr) slog.Attr {
			if len(groups) == 0 && attr.Key == slog.TimeKey {
				attr.Key = "ts"
			}
			return attr
		},
	})
	return slog.New(&traceHandler{inner: inner, service: service})
}

func (h *traceHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.inner.Enabled(ctx, level)
}

func (h *traceHandler) Handle(ctx context.Context, record slog.Record) error {
	spanContext := trace.SpanContextFromContext(ctx)
	traceID := ""
	spanID := ""
	if spanContext.IsValid() {
		traceID = spanContext.TraceID().String()
		spanID = spanContext.SpanID().String()
	}
	record.AddAttrs(
		slog.String("service", h.service),
		slog.String("trace_id", traceID),
		slog.String("span_id", spanID),
	)
	return h.inner.Handle(ctx, record)
}

func (h *traceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &traceHandler{inner: h.inner.WithAttrs(attrs), service: h.service}
}

func (h *traceHandler) WithGroup(name string) slog.Handler {
	return &traceHandler{inner: h.inner.WithGroup(name), service: h.service}
}
