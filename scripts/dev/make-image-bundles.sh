#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX='[make-image-bundles]'
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$ROOT_DIR"

OUT_DIR='dist/o11y-lab-vm-transfer/images'
SOURCE_REGISTRY=''
LIST_ONLY=false
PODMAN_STORE=false
K3S_STORE=false

usage() {
	cat <<'EOF'
Usage: scripts/dev/make-image-bundles.sh [options]
  --list                  print external and curated-manifest image references
  --out DIR               output directory (default: dist/o11y-lab-vm-transfer/images)
  --podman-store          build images-podman.tar
  --k3s-store             build images-k3s-containerd.tar
  --both                  build both store bundles
  --source REGISTRY       override upstream registry host for online pulls
EOF
}

while (($#)); do
	case "$1" in
		--list) LIST_ONLY=true ;;
		--out)
			(($# >= 2)) || { usage >&2; exit 2; }
			OUT_DIR="$2"
			shift
			;;
		--podman-store) PODMAN_STORE=true ;;
		--k3s-store) K3S_STORE=true ;;
		--both) PODMAN_STORE=true; K3S_STORE=true ;;
		--source)
			(($# >= 2)) || { usage >&2; exit 2; }
			SOURCE_REGISTRY="$2"
			shift
			;;
		-h|--help) usage; exit 0 ;;
		*) printf '%s unknown argument: %s\n' "$LOG_PREFIX" "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

if [[ "$LIST_ONLY" == true ]]; then
	exec python3 "$SCRIPT_DIR/workshop_images.py" --list
fi
if [[ "$PODMAN_STORE" == false && "$K3S_STORE" == false ]]; then
	printf '%s choose --podman-store, --k3s-store, or --both; use --list to inspect inputs without fetching\n' "$LOG_PREFIX" >&2
	exit 2
fi

command -v docker >/dev/null 2>&1 || { printf '%s FATAL: Docker CLI and daemon are required on this connected machine\n' "$LOG_PREFIX" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { printf '%s FATAL: sha256sum is required\n' "$LOG_PREFIX" >&2; exit 1; }
SKOPEO_IMAGE=$(awk '$1 == "image.skopeo" { print $2; exit }' versions.lock)
[[ -n "$SKOPEO_IMAGE" ]] || { printf '%s FATAL: image.skopeo pin is missing from versions.lock\n' "$LOG_PREFIX" >&2; exit 1; }

if [[ "$OUT_DIR" != /* ]]; then OUT_DIR="$ROOT_DIR/$OUT_DIR"; fi
mkdir -p "$OUT_DIR"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/workshop-image-bundles.XXXXXX")
cleanup() { rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT

run_skopeo() {
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		--env HOME=/tmp \
		--volume "$TEMP_DIR:/work" \
		--volume "$OUT_DIR:/out" \
		--workdir /work \
		"$SKOPEO_IMAGE" "$@"
}

declare -A IMAGE_SOURCES=()
declare -A IMAGE_DIGESTS=()
declare -A COPIED_IMAGES=()

load_store_entries() {
	local store="$1" line reference source
	while IFS= read -r line; do
		reference=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "$line")
		source=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["source"])' "$line")
		IMAGE_SOURCES["$reference"]="$source"
	done < <(python3 "$SCRIPT_DIR/workshop_images.py" --store "$store")
}

load_store_entries podman
load_store_entries k3s

source_for_pull() {
	local source="$1" source_reference path
	source_reference="${source#docker://}"
	if [[ -n "$SOURCE_REGISTRY" ]]; then
		path="${source_reference#*/}"
		source_reference="${SOURCE_REGISTRY%/}/$path"
	fi
	printf 'docker://%s' "$source_reference"
}

ensure_image() {
	local reference="$1" source="${IMAGE_SOURCES[$1]}" pull_source digest alias
	if [[ -n "${COPIED_IMAGES[$reference]+x}" ]]; then return 0; fi
	if [[ "$source" == 'in-repo' ]]; then
		if ! docker image inspect "$reference" >/dev/null 2>&1; then
			for alias in "${!IMAGE_SOURCES[@]}"; do
				if [[ "${IMAGE_SOURCES[$alias]}" != 'in-repo' ]]; then ensure_image "$alias"; fi
			done
			python3 -B "$SCRIPT_DIR/workshop_images.py" --build-local "$reference"
		fi
		if ! docker image inspect "$reference" >/dev/null 2>&1; then
			if [[ "$reference" == localhost/* ]]; then
				alias="${reference#localhost/}"
				if docker image inspect "$alias" >/dev/null 2>&1; then docker image tag "$alias" "$reference"; fi
			fi
		fi
		docker image inspect "$reference" >/dev/null 2>&1 || {
			printf '%s FATAL: in-repository image %s is not built in the connected Docker store; build its workshop context before creating a fallback bundle\n' "$LOG_PREFIX" "$reference" >&2
			exit 1
		}
		digest=''
	else
		pull_source=$(source_for_pull "$source")
		digest=$(run_skopeo inspect --format '{{.Digest}}' "$pull_source")
		[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { printf '%s FATAL: invalid image digest for %s: %s\n' "$LOG_PREFIX" "$reference" "$digest" >&2; exit 1; }
		pull_archive="$TEMP_DIR/pulls/$(printf '%s' "$reference" | tr '/:' '__').tar"
		mkdir -p "$TEMP_DIR/pulls"
		run_skopeo copy --all --preserve-digests "$pull_source" "docker-archive:/work/pulls/$(basename "$pull_archive"):$reference"
		docker load --input "$pull_archive" >/dev/null
	fi
	IMAGE_DIGESTS["$reference"]="$digest"
	COPIED_IMAGES["$reference"]=1
	printf '%s ready %s %s\n' "$LOG_PREFIX" "$reference" "$digest"
}

write_bundle() {
	local store="$1" archive_name="$2" load_command="$3" reference archive image_manifest archive_sha actual expected_digest
	local -a images=()
	for reference in "${!IMAGE_SOURCES[@]}"; do
		case ",${STORE_BY_IMAGE[$reference]-}," in *",$store,"*) images+=("$reference") ;; esac
	done
	((${#images[@]} > 0)) || { printf '%s FATAL: no images were discovered for %s\n' "$LOG_PREFIX" "$store" >&2; exit 1; }
	mapfile -t images < <(printf '%s\n' "${images[@]}" | sort -u)
	for reference in "${images[@]}"; do ensure_image "$reference"; done
	archive="$OUT_DIR/$archive_name"
	image_manifest="$archive.images.sha256"
	local archive_sha
	archive_sha="${archive}.sha256"
	docker save --output "$archive" "${images[@]}"
	: > "$image_manifest"
	for reference in "${images[@]}"; do
		expected_digest="${IMAGE_DIGESTS[$reference]}"
		actual=$(run_skopeo inspect --format '{{.Digest}}' "docker-archive:/out/$archive_name:$reference")
		[[ "$actual" =~ ^sha256:[0-9a-f]{64}$ ]] || { printf '%s FATAL: archive read-back returned an invalid digest for %s: %s\n' "$LOG_PREFIX" "$reference" "$actual" >&2; exit 1; }
		if [[ -n "$expected_digest" && "$actual" != "$expected_digest" ]]; then
			printf '%s FATAL: archive read-back digest mismatch for %s: expected %s, actual %s\n' "$LOG_PREFIX" "$reference" "$expected_digest" "$actual" >&2
			exit 1
		fi
		printf '%s | %s\n' "$reference" "$actual" >> "$image_manifest"
	done
	sha256sum "$archive" > "$archive_sha"
	sha256sum -c "$archive_sha"
	printf '%s images=%s archive=%s bytes=%s sha256=%s\n' "$LOG_PREFIX" "${#images[@]}" "$archive" "$(stat -c '%s' "$archive")" "$(sha256sum "$archive" | awk '{print $1}')"
	printf '%s image digests: %s\n' "$LOG_PREFIX" "$image_manifest"
	printf 'VM load command: %s\n' "$load_command"
}

declare -A STORE_BY_IMAGE=()
for store in podman k3s; do
	while IFS= read -r line; do
		reference=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "$line")
		STORE_BY_IMAGE["$reference"]="${STORE_BY_IMAGE[$reference]-},$store"
	done < <(python3 "$SCRIPT_DIR/workshop_images.py" --store "$store")
done

if [[ "$PODMAN_STORE" == true ]]; then
	write_bundle podman images-podman.tar 'sudo podman load -i images-podman.tar'
fi
if [[ "$K3S_STORE" == true ]]; then
	write_bundle k3s images-k3s-containerd.tar 'sudo k3s ctr -n k8s.io images import images-k3s-containerd.tar'
fi