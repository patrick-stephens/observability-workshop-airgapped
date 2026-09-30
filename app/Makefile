SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := build

BIN_DIR ?= bin

.PHONY: build test docker-build run-all

build:
	mkdir -p "$(BIN_DIR)"
	go build -o "$(BIN_DIR)/frontend" ./cmd/frontend
	go build -o "$(BIN_DIR)/api" ./cmd/api
	go build -o "$(BIN_DIR)/backend" ./cmd/backend

test:
	go test ./...

docker-build:
	@printf '%s\n' 'Docker build is out of scope because this application has no Dockerfiles.' >&2
	@exit 2

run-all: build
	@set -euo pipefail; \
	backend_pid=; api_pid=; frontend_pid=; \
	cleanup() { \
		for pid in "$$frontend_pid" "$$api_pid" "$$backend_pid"; do \
			if [[ -n "$$pid" ]]; then kill "$$pid" 2>/dev/null || true; fi; \
		done; \
		for pid in "$$frontend_pid" "$$api_pid" "$$backend_pid"; do \
			if [[ -n "$$pid" ]]; then wait "$$pid" 2>/dev/null || true; fi; \
		done; \
	}; \
	trap cleanup EXIT; \
	trap 'exit 130' INT; \
	trap 'exit 143' TERM; \
	LISTEN_ADDR=127.0.0.1:8082 OTEL_SERVICE_NAME=backend "./$(BIN_DIR)/backend" & backend_pid=$$!; \
	LISTEN_ADDR=127.0.0.1:8081 BACKEND_URL=http://127.0.0.1:8082 OTEL_SERVICE_NAME=api "./$(BIN_DIR)/api" & api_pid=$$!; \
	LISTEN_ADDR=127.0.0.1:8080 API_URL=http://127.0.0.1:8081 OTEL_SERVICE_NAME=frontend "./$(BIN_DIR)/frontend" & frontend_pid=$$!; \
	wait_for_ready() { \
		local port=$$1; \
		for attempt in {1..50}; do \
			if curl --fail --silent "http://127.0.0.1:$$port/healthz" >/dev/null; then return 0; fi; \
			sleep 0.1; \
		done; \
		printf '[run-all] service on port %s did not become ready\n' "$$port" >&2; \
		return 1; \
	}; \
	wait_for_ready 8082; \
	wait_for_ready 8081; \
	wait_for_ready 8080; \
	printf '[run-all] frontend :8080, api :8081, backend :8082\n'; \
	wait -n "$$frontend_pid" "$$api_pid" "$$backend_pid"
