#!/usr/bin/env bash
# registry-probe.sh — no changes, just reports
set -uo pipefail

ART="${ART_HOST:-artifactory.internal}"
CA="${CA_PATH:-/etc/pki/tls/certs/ca-bundle.crt}"
PREFIX_CANDIDATES=(
  "docker-remote"          # if a single prefix exists
  "docker"
  "dockerhub"
  "docker-virtual"
)

probe_image() {
  local prefix="$1" image="$2" tag="$3"
  local url="https://${ART}/${prefix}/${image}/manifests/${tag}"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    --cacert "$CA" \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "$url" 2>&1)
  printf '  %-40s -> %s\n' "${prefix}/${image}:${tag}" "$code"
}

echo "=== Artifactory root reachable? ==="
curl -sS -o /dev/null -w 'status=%{http_code} time=%{time_total}s\n' \
  --cacert "$CA" "https://${ART}/" || echo "  FAILED — check CA and hostname"

echo
echo "=== which prefixes exist? ==="
for p in "${PREFIX_CANDIDATES[@]}"; do
  curl -sS -o /dev/null -w "  ${p}: %{http_code}\n" \
    --cacert "$CA" "https://${ART}/${p}/v2/" || true
done

echo
echo "=== can we pull through each candidate, across all three upstreams? ==="
for p in "${PREFIX_CANDIDATES[@]}"; do
  echo "prefix: ${p}"
  probe_image "$p" "library/busybox"              "1.36"        # docker.io
  probe_image "$p" "fluent/fluent-bit"            "5.1.1"       # ghcr.io (!!)
  probe_image "$p" "prometheus/node-exporter"     "v1.12.1"     # quay.io (!!)
  echo
done

echo "=== Docker daemon present? ==="
command -v docker >/dev/null && docker version --format '{{.Server.Version}}' \
  || echo "  docker not installed — expected"
