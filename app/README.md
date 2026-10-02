# Demo Application

The application is a three-service HTTP request path: frontend calls api, and api calls backend.
Each service listens on `:8080` by default, as it would in its own Kubernetes workload.
`LISTEN_ADDR` overrides the listener for local multi-process runs.

## Build and Test

Run `make build` to produce `bin/frontend`, `bin/api`, `bin/backend`, and `bin/sensor-sim`.
Run `make sensor-sim` to build only the sensor simulator.
The simulator sends RFC5424 appliance events over TCP to the address in `SYSLOG_TARGET` and retries connections forever.
Run `make test` to execute the Go test suite.
The `docker-build` target is intentionally unavailable; `scripts/05-capture-cluster-assets.sh` builds the pinned image reproducibly.

## Run Locally

Run `make run-all` to start frontend on `127.0.0.1:8080`, api on `127.0.0.1:8081`, and backend on `127.0.0.1:8082`.
The target waits for all three health endpoints and stops all processes when interrupted.
Without `OTEL_EXPORTER_OTLP_ENDPOINT`, each service logs one warning and continues without exporting traces.
Set `API_URL` and `BACKEND_URL` to override downstream service addresses when running individual binaries.

Each service provides `GET /`, `GET /healthz`, `GET /readyz`, `GET /metrics`, and `GET /chaos`.
The `/metrics` endpoint uses the Prometheus default registry.

## Chaos Control

Call `GET /chaos?mode=slow` to make that service wait two seconds before handling its next root request.
Call `GET /chaos?mode=error` to make its root request return HTTP 500.
Call `GET /chaos?mode=dns` to resolve `backend.typo.svc.cluster.local` and return HTTP 502 if resolution fails.
Call `GET /chaos?mode=ok` to restore normal behaviour immediately.
The mode is held in process memory and changes take effect before the control endpoint responds.

For the slow-path check, run `curl 'localhost:8080/chaos?mode=slow'` and then `time curl localhost:8080/`.
The second request should take approximately two seconds.
