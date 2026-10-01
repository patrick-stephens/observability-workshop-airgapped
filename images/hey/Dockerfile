ARG GO_BUILDER_IMAGE=golang:1.24-alpine@sha256:757779acac4af1b349a20f357c7296097b4a0b89da4ad0e370b339060077282a
FROM ${GO_BUILDER_IMAGE} AS builder
ARG SOURCE_DATE_EPOCH=0
ENV CGO_ENABLED=0
ENV GOFLAGS=-buildvcs=false
RUN go install -trimpath -ldflags=-buildid= github.com/rakyll/hey@v0.1.4 \
	&& touch --date="@${SOURCE_DATE_EPOCH}" /go/bin/hey

FROM scratch
COPY --from=builder /go/bin/hey /hey
ENTRYPOINT ["/hey"]
