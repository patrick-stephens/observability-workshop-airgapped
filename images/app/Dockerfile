ARG GO_BUILDER_IMAGE=golang:1.24-alpine@sha256:757779acac4af1b349a20f357c7296097b4a0b89da4ad0e370b339060077282a
FROM ${GO_BUILDER_IMAGE} AS builder
ARG SOURCE_DATE_EPOCH=0
ENV CGO_ENABLED=0
ENV GOFLAGS=-buildvcs=false
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN for service in frontend api backend sensor-sim; do \
        go build -trimpath -ldflags=-buildid= -o "/out/${service}" "./cmd/${service}" \
        && touch --date="@${SOURCE_DATE_EPOCH}" "/out/${service}"; \
    done

# One image carries all three services; each Deployment selects its binary with `command`.
FROM scratch
COPY --from=builder /out/frontend /out/api /out/backend /out/sensor-sim /
USER 65532:65532
EXPOSE 8080
