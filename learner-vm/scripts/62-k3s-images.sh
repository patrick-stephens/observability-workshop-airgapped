#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="62-k3s-images"
SCRIPT_VERSION="1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
UNKNOWN_ARGUMENTS=()
for argument in "$@"; do
	case "$argument" in
		--dry-run) DRY_RUN=true ;;
		*) UNKNOWN_ARGUMENTS+=("$argument") ;;
	esac
done
source "$SCRIPT_DIR/lib.sh"
begin_report
for argument in "${UNKNOWN_ARGUMENTS[@]}"; do
	step_fail "unknown argument: $argument" "Run learner-vm/scripts/62-k3s-images.sh [--dry-run]." "printf '%s\\n' --dry-run"
done
if ((EUID != 0)) && [[ "$DRY_RUN" == false ]]; then
	step_fail "k3s image preparation requires root" "Run sudo learner-vm/scripts/62-k3s-images.sh after script 45." "id -u"
	end_report "rerun with sudo after k3s is installed"
	exit 1
elif ((EUID != 0)); then
	step_skip "root is required for real store changes; dry-run continues" "rerun with sudo on the learner VM"
fi

K3S='/usr/local/bin/k3s'
SYSTEM_IMAGES="$REPO_ROOT/content/vendor/k3s/k3s-images.txt"
CURATED="$REPO_ROOT/content/extracted/curated.json"
MANIFEST="$REPO_ROOT/content/repos/opentelemetry/_vendored/app_pod.yaml"
K3S_BUNDLE="$MANUAL_FETCH_DIR/images/images-k3s-containerd.tar"
K3S_BUNDLE_SHA="$K3S_BUNDLE.sha256"
K3S_BUNDLE_IMAGES="$K3S_BUNDLE.images.sha256"
PODMAN_TAR=''
cleanup() {
	[[ -z "$PODMAN_TAR" ]] || rm -f -- "$PODMAN_TAR"
}
trap cleanup EXIT

format_k3s_failure() {
	local image="$1"
	step_fail "k3s image operation failed for $image" "Check CA trust and /etc/rancher/k3s/registries.yaml; CRI pulls use Artifactory only when that learner-network path succeeds. See Section C of content/vendor/MANUAL-FETCH.md and stage a valid bundle under $MANUAL_FETCH_DIR/images/." \
		"$K3S --version" \
		"$K3S crictl --help" \
		"$K3S crictl images" \
		"$K3S ctr -n k8s.io images list" \
		"journalctl -u k3s -b --no-pager | tail -n 15" \
		"cat /etc/rancher/k3s/registries.yaml" \
		"tail -n 15 /var/lib/rancher/k3s/agent/containerd/containerd.log" \
		"printf '%s\\n' $(printf %q "$image")"
}

k3s_image_exists() {
	"$K3S" ctr -n k8s.io images list 2>/dev/null | awk -v reference="$1" '$1 == reference {found=1} END {exit !found}'
}

for file in "$SYSTEM_IMAGES" "$CURATED" "$MANIFEST" "$REPO_ROOT/content/vendor/manual-fetch.json"; do
	if [[ ! -s "$file" ]]; then
		step_fail "k3s image input is missing: ${file#"$REPO_ROOT/"}" "Restore the repository ZIP and vendored manifest." "ls -l $(printf %q "$file")" "find $(printf %q "$REPO_ROOT/content/vendor") -maxdepth 2 -type f -print"
	fi
done

if [[ "$DRY_RUN" == true ]]; then
	step_skip "installed k3s binary check is target-side and was not evaluated during dry-run" "$K3S"
elif [[ ! -x "$K3S" ]]; then
	step_fail "k3s executable is unavailable at $K3S" "Run learner-vm/scripts/45-k3s-install.sh after staging the binary described in Section B of content/vendor/MANUAL-FETCH.md." "ls -l $(printf '%q' "$K3S")" "sha256sum $(printf '%q' "$MANUAL_FETCH_DIR/k3s/k3s")"
fi
if ! command -v python3 >/dev/null 2>&1; then
	step_fail "python3 is unavailable" "Run learner-vm/scripts/20-install-tooling.sh before parsing curated image metadata." "command -v python3" "rpm -q python3"
	end_report "install Python 3 before preparing k3s images"
	exit 1
fi
if ! command -v podman >/dev/null 2>&1 && [[ "$DRY_RUN" == true ]]; then
	step_skip "Podman store is target-side and was not inspected during dry-run" "run after script 20 installs Podman"
elif ! command -v podman >/dev/null 2>&1; then
	step_fail "Podman is unavailable" "Run learner-vm/scripts/20-install-tooling.sh before preparing local k3s image transfers." "command -v podman" "rpm -q podman"
fi

if system_image_text="$(python3 - "$SYSTEM_IMAGES" "$CURATED" <<'PY'
import json
import sys
images = set()
with open(sys.argv[1], encoding="utf-8") as source:
    images.update(line.strip() for line in source if line.strip() and not line.lstrip().startswith("#"))
with open(sys.argv[2], encoding="utf-8") as source:
    curated = json.load(source)
for track in curated.values():
    for run in track.get("runs", []):
        if not run.get("requires_k3s"):
            continue
        for key in ("image", "images"):
            value = run.get(key, [])
            if isinstance(value, str):
                value = [value]
            if isinstance(value, list):
                images.update(item for item in value if isinstance(item, str) and item)
print("\n".join(sorted(images)))
PY

)"; then
	mapfile -t K3S_IMAGES < <({ printf '%s\n' "$system_image_text"; awk '/^[[:space:]]*image:[[:space:]]*/ { sub(/^[[:space:]]*image:[[:space:]]*/, ""); gsub(/["\047]/, ""); print }' "$MANIFEST"; } | sort -u)
else
	step_fail "could not parse the pinned system list, curated JSON, or k3s manifest" "Restore valid content/vendor/k3s/k3s-images.txt, content/extracted/curated.json, and content/repos/opentelemetry/_vendored/app_pod.yaml." "python3 -m json.tool $(printf %q "$CURATED")" "awk '/image:/ {print}' $(printf %q "$MANIFEST")" "head -n 20 $(printf %q "$SYSTEM_IMAGES")"
fi
if ((${#K3S_IMAGES[@]} == 0)); then
	step_fail "no k3s image references were discovered" "Restore the pinned k3s system image list and curated Kubernetes manifest." "cat $(printf %q "$SYSTEM_IMAGES")" "grep -n 'image:' $(printf %q "$MANIFEST")"
fi

if [[ "$DRY_RUN" == true ]]; then
	if [[ -s "$K3S_BUNDLE" ]]; then
		log "would validate sidecars and import $K3S_BUNDLE with k3s ctr -n k8s.io images import"
	else
		log "no staged k3s-containerd bundle at $K3S_BUNDLE; would use CRI pulls and Podman save/import"
	fi
	for image in "${K3S_IMAGES[@]}"; do
		if [[ "$image" == localhost/* ]]; then
			log "would transfer exact local Podman reference with podman save and k3s ctr import: $image"
		else
			log "would check k3s store, then use k3s crictl pull if absent: $image"
		fi
	done
	step_skip "k3s CRI pulls, imports, and store verification were not executed during dry-run" "Artifactory pulls remain unverified until tested on the learner network"
	end_report "review the image references and mirror configuration, then rerun on the learner VM"
	exit 0
fi

if ! command -v sha256sum >/dev/null 2>&1; then
	step_fail "sha256sum is unavailable" "Install coreutils before verifying manual image bundles." "command -v sha256sum" "rpm -q coreutils"
fi
if [[ -s "$K3S_BUNDLE" ]]; then
	expected_bundle_sha="$(awk 'NR == 1 {print $1}' "$K3S_BUNDLE_SHA" 2>/dev/null || true)"
	actual_bundle_sha="$(sha256sum "$K3S_BUNDLE" | awk '{print $1}')"
		bundle_image_count=0
	if [[ -s "$K3S_BUNDLE_SHA" && -s "$K3S_BUNDLE_IMAGES" && "$expected_bundle_sha" =~ ^[0-9a-f]{64}$ && "$actual_bundle_sha" == "$expected_bundle_sha" ]]; then
		step_ok "manual k3s image archive digest is valid at its staging path"
		if run "$K3S ctr -n k8s.io images import $(printf %q "$K3S_BUNDLE")"; then
			step_ok "imported manual image bundle into k3s containerd namespace k8s.io"
			while IFS='|' read -r reference expected_digest || [[ -n "$reference" ]]; do
				reference="$(printf '%s' "$reference" | xargs)"
				expected_digest="$(printf '%s' "$expected_digest" | xargs)"
				if [[ -z "$reference" || ! "$expected_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
					step_fail "manual k3s image digest sidecar has a malformed row" "Regenerate the bundle with scripts/dev/make-image-bundles.sh and transfer all three files." "sed -n '1,20p' $(printf '%q' "$K3S_BUNDLE_IMAGES")"
					continue
				fi
				((bundle_image_count+=1))
				actual_digest="$($K3S ctr -n k8s.io images list | awk -v ref="$reference" '$1 == ref {print $3; exit}')"
				if [[ "$actual_digest" == "$expected_digest" ]]; then
					step_ok "k3s bundle digest verified for $reference"
				else
					step_fail "k3s imported digest mismatch for $reference: expected $expected_digest, actual ${actual_digest:-missing}" "Regenerate the k3s bundle and its per-image sidecar on the connected machine." "$K3S ctr -n k8s.io images list" "grep -F $(printf '%q' "$reference") $(printf '%q' "$K3S_BUNDLE_IMAGES")"
				fi
			done < "$K3S_BUNDLE_IMAGES"
			if ((bundle_image_count == 0)); then step_fail "manual k3s image digest sidecar is empty" "Regenerate and transfer the archive plus both sidecars using Section C of content/vendor/MANUAL-FETCH.md." "ls -l $(printf '%q' "$K3S_BUNDLE_IMAGES")"; fi
		else
			format_k3s_failure "$K3S_BUNDLE"
		fi
	else
		step_fail "manual k3s image bundle, archive digest, or image digest sidecar is missing/invalid" "Regenerate it with scripts/dev/make-image-bundles.sh --k3s-store and stage all three files under $MANUAL_FETCH_DIR/images/." "ls -l $(printf %q "$MANUAL_FETCH_DIR/images")" "sha256sum $(printf %q "$K3S_BUNDLE")" "cat $(printf %q "$K3S_BUNDLE_IMAGES")"
	fi
else
	step_skip "no manual k3s-containerd fallback bundle is staged" "will use CRI pulls and Podman image imports"
fi

for image in "${K3S_IMAGES[@]}"; do
	if k3s_image_exists "$image"; then
		step_ok "k3s containerd already has $image"
		continue
	fi
	if [[ "$image" == localhost/* ]]; then
		podman_source="$image"
		if ! podman image exists "$podman_source" >/dev/null 2>&1 && podman image exists "${image#localhost/}" >/dev/null 2>&1; then
			podman_source="${image#localhost/}"
			step_skip "manifest requires a localhost reference; transferring the actual Podman source tag without retagging" "$podman_source -> $image"
		fi
		if ! podman image exists "$podman_source" >/dev/null 2>&1; then
			format_k3s_failure "$image (local Podman image $podman_source is absent)"
			continue
		fi
		PODMAN_TAR=$(mktemp "${TMPDIR:-/tmp}/62-local-image.XXXXXX.tar")
		if podman save -o "$PODMAN_TAR" "$podman_source" && run "$K3S ctr -n k8s.io images import $(printf %q "$PODMAN_TAR")"; then
			step_ok "saved and imported Podman image $podman_source to satisfy $image"
			if podman image exists "$podman_source" >/dev/null 2>&1; then
				step_ok "verified source reference remains in the Podman store: $podman_source"
			else
				format_k3s_failure "$image (Podman source disappeared after import: $podman_source)"
			fi
		else
			format_k3s_failure "$image (Podman source $podman_source)"
		fi
		rm -f -- "$PODMAN_TAR"
		PODMAN_TAR=''
	else
		pull_log=$(mktemp "${TMPDIR:-/tmp}/62-cri-pull.XXXXXX")
		if "$K3S" crictl pull "$image" >"$pull_log" 2>&1; then
			step_ok "k3s CRI pull command succeeded for $image"
		else
			pull_status=$?
			format_k3s_failure "$image (CRI pull exit $pull_status; $(tail -n 3 "$pull_log" | tr '\n' '; '))"
		fi
		rm -f -- "$pull_log"
	fi
	if k3s_image_exists "$image"; then
		step_ok "verified original k3s image reference: $image"
	else
		format_k3s_failure "$image (reference absent after acquisition)"
	fi
done

end_report "Review k3s image failures; continue with learner-vm/scripts/70-quickstart.sh only when all required references are present. Artifactory CRI pulls remain unverified until VM-side report evidence exists."
			while IFS='|' read -r reference expected_digest || [[ -n "$reference" ]]; do
				reference="$(printf '%s' "$reference" | xargs)"
				expected_digest="$(printf '%s' "$expected_digest" | xargs)"
				if [[ -z "$reference" || ! "$expected_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
					step_fail "manual k3s image digest sidecar has a malformed row" "Regenerate the bundle with scripts/dev/make-image-bundles.sh and transfer all three files." "sed -n '1,20p' $(printf '%q' "$K3S_BUNDLE_IMAGES")"
					continue
				fi
				((bundle_image_count+=1))
				actual_digest="$($K3S ctr -n k8s.io images list | awk -v ref="$reference" '$1 == ref {print $3; exit}')"
				if [[ "$actual_digest" == "$expected_digest" ]]; then
					step_ok "k3s bundle digest verified for $reference"
				else
					step_fail "k3s imported digest mismatch for $reference: expected $expected_digest, actual ${actual_digest:-missing}" "Regenerate the k3s bundle and its per-image sidecar on the connected machine." "$K3S ctr -n k8s.io images list" "grep -F $(printf '%q' "$reference") $(printf '%q' "$K3S_BUNDLE_IMAGES")"
				fi
			done < "$K3S_BUNDLE_IMAGES"
			if ((bundle_image_count == 0)); then step_fail "manual k3s image digest sidecar is empty" "Regenerate and transfer the archive plus both sidecars using Section C of content/vendor/MANUAL-FETCH.md." "ls -l $(printf '%q' "$K3S_BUNDLE_IMAGES")"; fi
((FAIL_COUNT == 0))
			step_fail "manual k3s image bundle, archive digest, or image digest sidecar is missing/invalid" "Regenerate it with scripts/dev/make-image-bundles.sh --k3s-store and stage all three files under $MANUAL_FETCH_DIR/images/." "ls -l $(printf '%q' "$MANUAL_FETCH_DIR/images")" "sha256sum $(printf '%q' "$K3S_BUNDLE")" "awk 'NR == 1 {print \\$1}' $(printf '%q' "$K3S_BUNDLE_SHA")" "cat $(printf '%q' "$K3S_BUNDLE_IMAGES")"
