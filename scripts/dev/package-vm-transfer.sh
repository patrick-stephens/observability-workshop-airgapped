#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX='[package-vm-transfer]'
# Phase C archives a filtered staging copy before Phase D, so the ZIP has post-clean contents without deleting source before package verification.
ROOT_DIR=$(git rev-parse --show-toplevel)
cd "$ROOT_DIR"

MANIFEST='scripts/dev/obsolete-artifacts.txt'
STAGING_DIR='content/vendor/k3s/payload-stage'
DEFAULT_OUT='dist/o11y-lab-vm-transfer'
OUT_DIR="$ROOT_DIR/$DEFAULT_OUT"
DRY_RUN=false
INCLUDE_AIRGAP=true
NO_CLEAN=true
NO_CLEAN_REQUESTED=false
CLEAN_ONLY=false
REFRESH=false
MANUAL_BUNDLE_DIR=''
MANUAL_INSTRUCTIONS_REQUESTED=false
MANUAL_INSTRUCTIONS_PATH=''
LIST_MANUAL=false

usage() {
	cat <<'EOF'
Usage: scripts/dev/package-vm-transfer.sh [options]
	--dry-run                      print phases A-D without changing files
	--no-airgap-tarball            omit the optional k3s image fallback (default includes it)
	--include-k3s-airgap-tarball   compatibility alias; the default already includes it
	--no-clean                     compatibility alias; source cleanup is already disabled by default
	--clean-obsolete-only          explicitly fetch/verify required payload, then stage obsolete removals
  --refresh                      re-fetch pinned payloads and verify hashes
  --out DIR                      output directory (default: dist/o11y-lab-vm-transfer)
	--manual-bundle DIR            create DIR/manual-payload.tar.gz with payload artifacts
	--manual-instructions [PATH]   write Section B instructions (default under dist/)
	--list-manual                  print the generated manual-fetch entry table and exit
EOF
}

while (($#)); do
	case "$1" in
		--dry-run) DRY_RUN=true ;;
		--include-k3s-airgap-tarball) INCLUDE_AIRGAP=true ;;
		--no-airgap-tarball) INCLUDE_AIRGAP=false ;;
		--no-clean) NO_CLEAN=true; NO_CLEAN_REQUESTED=true ;;
		--clean-obsolete-only) CLEAN_ONLY=true; NO_CLEAN=false ;;
		--refresh) REFRESH=true ;;
		--manual-bundle)
			(($# >= 2)) || { usage >&2; exit 2; }
			MANUAL_BUNDLE_DIR="$2"
			shift
			;;
		--manual-instructions)
			MANUAL_INSTRUCTIONS_REQUESTED=true
			if (($# >= 2)) && [[ "$2" != --* ]]; then
				MANUAL_INSTRUCTIONS_PATH="$2"
				shift
			fi
			;;
		--list-manual) LIST_MANUAL=true ;;
		--out)
			(($# >= 2)) || { usage >&2; exit 2; }
			OUT_DIR="$2"
			shift
			;;
		-h|--help) usage; exit 0 ;;
		*) printf '%s unknown argument: %s\n' "$LOG_PREFIX" "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

if [[ "$CLEAN_ONLY" == true && "$NO_CLEAN_REQUESTED" == true ]]; then
	printf '%s --clean-obsolete-only cannot be combined with --no-clean\n' "$LOG_PREFIX" >&2
	exit 2
fi
if [[ "$CLEAN_ONLY" == true && ( -n "$MANUAL_BUNDLE_DIR" || "$MANUAL_INSTRUCTIONS_REQUESTED" ) ]]; then
	printf '%s --clean-obsolete-only cannot be combined with manual bundle or instruction generation\n' "$LOG_PREFIX" >&2
	exit 2
fi

if [[ "$OUT_DIR" != /* ]]; then OUT_DIR="$ROOT_DIR/$OUT_DIR"; fi
if [[ "$LIST_MANUAL" == true ]]; then
	exec python3 -B "$ROOT_DIR/scripts/dev/generate-manual-fetch.py" --list
fi
if [[ "$MANUAL_INSTRUCTIONS_REQUESTED" == true && -z "$MANUAL_INSTRUCTIONS_PATH" ]]; then
	MANUAL_INSTRUCTIONS_PATH="$OUT_DIR/MANUAL-FETCH-payload.txt"
fi
if [[ -n "$MANUAL_BUNDLE_DIR" && "$MANUAL_BUNDLE_DIR" != /* ]]; then MANUAL_BUNDLE_DIR="$ROOT_DIR/$MANUAL_BUNDLE_DIR"; fi
if [[ -n "$MANUAL_INSTRUCTIONS_PATH" && "$MANUAL_INSTRUCTIONS_PATH" != /* ]]; then MANUAL_INSTRUCTIONS_PATH="$ROOT_DIR/$MANUAL_INSTRUCTIONS_PATH"; fi

REPO_ZIP="$OUT_DIR/o11y-lab-vm-repository.zip"
REPO_ZIP_SHA="$REPO_ZIP.sha256"
ZIP_PAYLOAD_ROOT='learner-vm/content/vendor/payload'
ZIP_K3S_DIR="$ZIP_PAYLOAD_ROOT/k3s"
ZIP_BINARY_PATH="$ZIP_K3S_DIR/k3s"
ZIP_AIRGAP_PATH="$ZIP_K3S_DIR/k3s-airgap-images-amd64.tar.zst"
ZIP_PAYLOAD_MANIFEST="$ZIP_PAYLOAD_ROOT/payload-manifest.txt"
if [[ "$DRY_RUN" == false && "$CLEAN_ONLY" == false && ( -e "$REPO_ZIP" || -e "$REPO_ZIP_SHA" ) ]]; then
	printf '%s FATAL: refusing to overwrite an existing package or checksum in %s; choose a fresh --out directory\n' "$LOG_PREFIX" "$OUT_DIR" >&2
	exit 1
fi

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

die() {
	printf '%s FATAL: %s\n' "$LOG_PREFIX" "$1" >&2
	exit 1
}

head_file_size() {
	local ref="$1" path="$2" size pointer declared
	size=$(git cat-file -s "$ref:$path")
	if ((size < 256)); then
		pointer=$(git show "$ref:$path")
		if [[ "$pointer" == version\ https://git-lfs.github.com/spec/v1* ]]; then
			declared=$(awk '$1 == "size" { print $2; exit }' <<< "$pointer")
			if [[ "$declared" =~ ^[0-9]+$ ]]; then size="$declared"; fi
		fi
	fi
	printf '%s' "$size"
}

declare -a OBSOLETE_PATHS=()
declare -a OBSOLETE_REASONS=()
declare -a OBSOLETE_REPLACEMENTS=()
declare -a OBSOLETE_SIZES=()
declare -A OBSOLETE_SET=()
TOTAL_BYTES=0

[[ -r "$MANIFEST" ]] || die "missing $MANIFEST; create the reviewed removal manifest first"

printf '%s PHASE A — AUDIT\n' "$LOG_PREFIX"
printf 'path | size bytes | replacement delivery | action\n'
while IFS='|' read -r raw_path raw_reason raw_replacement || [[ -n "${raw_path:-}" ]]; do
	path=$(trim "${raw_path:-}")
	[[ -n "$path" ]] || continue
	reason=$(trim "${raw_reason:-}")
	replacement=$(trim "${raw_replacement:-}")
	[[ -n "$reason" && -n "$replacement" ]] || die "malformed manifest row for $path; expected path | reason | replacement"
	[[ "$path" != /* && "/$path/" != *"/../"* ]] || die "unsafe manifest path: $path"
	[[ -z "${OBSOLETE_SET[$path]+x}" ]] || die "duplicate manifest path: $path"
	OBSOLETE_SET["$path"]=1
	OBSOLETE_PATHS+=("$path")
	OBSOLETE_REASONS+=("$reason")
	OBSOLETE_REPLACEMENTS+=("$replacement")

	if [[ -e "$path" ]]; then
		git ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || die "$path exists but is not tracked; remove it from $MANIFEST or track it before packaging"
		git diff --quiet HEAD -- "$path" || die "$path has local changes; review or preserve them before packaging"
		bytes=$(stat -c '%s' -- "$path")
		action='REMOVE'
		TOTAL_BYTES=$((TOTAL_BYTES + bytes))
	elif git diff --cached --name-only --diff-filter=D -- "$path" | grep -Fxq -- "$path" && git cat-file -e "HEAD:$path" 2>/dev/null; then
		bytes=$(head_file_size HEAD "$path")
		TOTAL_BYTES=$((TOTAL_BYTES + bytes))
		action='ALREADY STAGED FOR REMOVAL'
	elif ! git cat-file -e "HEAD:$path" 2>/dev/null && git cat-file -e "workshop-lvm-prep-v2:$path" 2>/dev/null; then
		bytes=$(head_file_size workshop-lvm-prep-v2 "$path")
		TOTAL_BYTES=$((TOTAL_BYTES + bytes))
		action='ALREADY REMOVED IN CURRENT HEAD (freeze tag verified)'
	else
		die "$path is missing or not tracked; fix $MANIFEST before cleanup"
	fi
	OBSOLETE_SIZES+=("$bytes")
	case "$replacement" in
		*REQUIRED*) required='yes' ;;
		*OPTIONAL*) required='optional' ;;
		*) required='no' ;;
	esac
	printf '%s | %s | %s | %s | %s\n' "$path" "$bytes" "$required" "$replacement" "$action"
done < "$MANIFEST"
((${#OBSOLETE_PATHS[@]} > 0)) || die "$MANIFEST has no removal entries"
REQUIRED_BINARY_PATH='content/vendor/k3s/k3s'
OPTIONAL_AIRGAP_PATH='content/vendor/k3s/k3s-airgap-images-amd64.tar.zst'
[[ -n "${OBSOLETE_SET[$REQUIRED_BINARY_PATH]+x}" ]] || die "$MANIFEST does not list the required k3s executable"
if [[ "$INCLUDE_AIRGAP" == true ]]; then
	[[ -n "${OBSOLETE_SET[$OPTIONAL_AIRGAP_PATH]+x}" ]] || die "$MANIFEST does not list the optional k3s airgap tarball"
fi
for index in "${!OBSOLETE_PATHS[@]}"; do
	path="${OBSOLETE_PATHS[$index]}"
	replacement="${OBSOLETE_REPLACEMENTS[$index]}"
	case "$path" in
		content/vendor/k3s/k3s|content/vendor/k3s/k3s-airgap-images-amd64.tar.zst) ;;
		*)
			[[ "$replacement" == *"no replacement"* ]] || die "unsupported manifest replacement path: $path; add an explicit verified fetch implementation before cleanup"
			;;
	esac
done
printf 'Total bytes to recover in this run: %s\n' "$TOTAL_BYTES"

lock_line() {
	local key="$1"
	awk -v key="$key" '$1 == key { print; exit }' versions.lock
}

lock_value() {
	local key="$1" field="$2" line value prefix
	line=$(lock_line "$key")
	[[ -n "$line" ]] || die "versions.lock has no record for $key"
	if [[ "$field" == 'sha256' ]]; then prefix='sha256:'; else prefix="$field="; fi
	value=$(awk -v prefix="$prefix" '{ for (i = 1; i <= NF; i++) if (index($i, prefix) == 1) { sub(prefix, "", $i); print $i; exit } }' <<< "$line")
	[[ -n "$value" ]] || die "versions.lock record $key has no $field field"
	printf '%s' "$value"
}

K3S_VERSION=$(awk '$1 == "learner-k3s" { print $2; exit }' versions.lock)
K3S_BINARY_SHA=$(lock_value learner-k3s-binary-amd64 sha256 | sed 's/^sha256://')
K3S_BINARY_URL=$(lock_value learner-k3s-binary-amd64 source)
K3S_TARBALL_SHA=$(lock_value learner-k3s-airgap-images-amd64.tar.zst sha256 | sed 's/^sha256://')
K3S_TARBALL_URL=$(lock_value learner-k3s-airgap-images-amd64.tar.zst source)
[[ "$K3S_VERSION" == v1.37.1+k3s1 ]] || die "unexpected or missing pinned k3s version: ${K3S_VERSION:-<empty>}"
[[ "$K3S_BINARY_SHA" =~ ^[0-9a-f]{64}$ && "$K3S_TARBALL_SHA" =~ ^[0-9a-f]{64}$ ]] || die 'invalid k3s SHA-256 in versions.lock'
python3 - "$ROOT_DIR/content/vendor/manual-fetch.json" "$K3S_BINARY_URL" "$K3S_BINARY_SHA" "$K3S_TARBALL_URL" "$K3S_TARBALL_SHA" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
payload = [entry for entry in document if entry["category"] == "payload"]
expected = {
	"k3s/k3s": (sys.argv[2], sys.argv[3], True, "learner-vm/content/vendor/payload/k3s/k3s"),
	"k3s/k3s-airgap-images-amd64.tar.zst": (sys.argv[4], sys.argv[5], False, "learner-vm/content/vendor/payload/k3s/k3s-airgap-images-amd64.tar.zst"),
}
actual = {entry["name"]: entry for entry in payload}
if set(actual) != set(expected):
	raise SystemExit(f"manual-fetch.json payload entries differ from pinned package inputs: {sorted(actual)}")
for name, (url, digest, required, package_path) in expected.items():
	entry = actual[name]
	if (entry["source"], entry["sha256"], entry["required"], entry.get("package_path")) != (url, digest, required, package_path):
		raise SystemExit(f"manual-fetch.json payload pin mismatch for {name}")
PY

BINARY_CACHE="$ROOT_DIR/$STAGING_DIR/k3s"
TARBALL_CACHE="$ROOT_DIR/$STAGING_DIR/k3s-airgap-images-amd64.tar.zst"

verify_sha() {
	local path="$1" expected="$2" actual
	actual=$(sha256sum "$path" | awk '{print $1}')
	[[ "$actual" == "$expected" ]] || die "SHA-256 mismatch for $path: expected $expected, actual $actual"
}

fetch_verified() {
	local url="$1" expected="$2" target="$3" temporary="$3.partial" actual
	if [[ -e "$target" && "$REFRESH" == false ]]; then
		if [[ ! -s "$target" ]]; then die "cached payload is empty and was left unchanged: $target; use --refresh to fetch a replacement"; fi
		actual=$(sha256sum "$target" | awk '{print $1}')
		[[ "$actual" == "$expected" ]] || die "cached payload SHA-256 mismatch for $target: expected $expected, actual $actual; source was left unchanged"
		printf '%s verified cached payload %s (%s)\n' "$LOG_PREFIX" "${target#"$ROOT_DIR/"}" "$actual"
		return 0
	fi
	mkdir -p "$(dirname "$target")"
	rm -f -- "$temporary"
	if ! curl -fL --retry 2 --connect-timeout 15 --max-time 900 "$url" -o "$temporary"; then
		rm -f -- "$temporary"
		die "could not fetch $url; existing source cache was not changed"
	fi
	actual=$(sha256sum "$temporary" | awk '{print $1}')
	if [[ "$actual" != "$expected" ]]; then
		rm -f -- "$temporary"
		die "downloaded payload SHA-256 mismatch for $target: expected $expected, actual $actual; existing source cache was not changed"
	fi
	mv -f -- "$temporary" "$target"
	printf '%s fetched and verified %s (%s)\n' "$LOG_PREFIX" "${target#"$ROOT_DIR/"}" "$expected"
}

printf '%s PHASE B — FETCH AND VERIFY REPLACEMENTS\n' "$LOG_PREFIX"
if [[ "$DRY_RUN" == true ]]; then
	printf 'Would fetch or reuse REQUIRED k3s %s from %s; SHA-256 %s; cache %s\n' "$K3S_VERSION" "$K3S_BINARY_URL" "$K3S_BINARY_SHA" "${BINARY_CACHE#"$ROOT_DIR/"}"
	if [[ "$INCLUDE_AIRGAP" == true ]]; then
		printf 'Would fetch or reuse OPTIONAL airgap tarball from %s; SHA-256 %s; cache %s\n' "$K3S_TARBALL_URL" "$K3S_TARBALL_SHA" "${TARBALL_CACHE#"$ROOT_DIR/"}"
	else
		printf 'Would omit OPTIONAL airgap tarball because --no-airgap-tarball was selected.\n'
	fi
else
	command -v curl >/dev/null 2>&1 || die 'curl is required to fetch the pinned payload'
	command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required to verify the pinned payload'
	fetch_verified "$K3S_BINARY_URL" "$K3S_BINARY_SHA" "$BINARY_CACHE"
	if [[ "$INCLUDE_AIRGAP" == true ]]; then
		fetch_verified "$K3S_TARBALL_URL" "$K3S_TARBALL_SHA" "$TARBALL_CACHE"
	fi
fi

if [[ "$CLEAN_ONLY" == false ]]; then
	printf '%s PHASE C — PACKAGE\n' "$LOG_PREFIX"
	if [[ "$DRY_RUN" == true ]]; then
		printf 'Would build one repository ZIP from the Git index and working-tree contents into a temporary staging copy.\n'
		printf 'Would exclude .git/, .git/lfs/, dist/, generated logs/caches, and every obsolete-artifacts.txt path.\n'
		printf 'Would inject verified payloads and payload-manifest.txt at %s inside the ZIP; no working-tree payload files are created.\n' "$ZIP_PAYLOAD_ROOT/"
		printf 'Would include the Phase-D .gitignore entries in the ZIP staging copy.\n'
		printf 'Would build %s with an online SHA-256 sidecar; the VM transfer needs only this ZIP.\n' "${REPO_ZIP#"$ROOT_DIR/"}"
		if [[ -n "$MANUAL_BUNDLE_DIR" ]]; then printf 'Would additionally create the optional standalone manual payload bundle at %s.\n' "$MANUAL_BUNDLE_DIR"; fi
	else
		command -v zip >/dev/null 2>&1 || die 'zip is required to create the repository archive'
		command -v unzip >/dev/null 2>&1 || die 'unzip is required to verify the repository archive'
		command -v cp >/dev/null 2>&1 || die 'cp is required to stage repository files'
		mkdir -p "$OUT_DIR"
		temp_root=$(mktemp -d "${TMPDIR:-/tmp}/o11y-transfer.XXXXXX")
		zip_temporary=''
		sha_temporary=''
		cleanup_temp() {
			rm -rf -- "$temp_root"
			[[ -z "$zip_temporary" ]] || rm -f -- "$zip_temporary"
			[[ -z "$sha_temporary" ]] || rm -f -- "$sha_temporary"
		}
		trap cleanup_temp EXIT
		repo_stage="$temp_root/repository"
		mkdir -p "$repo_stage"
		while IFS= read -r -d '' path; do
			[[ -n "${OBSOLETE_SET[$path]+x}" ]] && continue
			[[ "$path" == dist || "$path" == dist/* ]] && continue
			[[ "$path" == "$STAGING_DIR" || "$path" == "$STAGING_DIR/"* ]] && continue
			[[ "$path" == "$ZIP_PAYLOAD_ROOT" || "$path" == "$ZIP_PAYLOAD_ROOT/"* ]] && continue
			case "$path" in
				id_rsa|id_dsa|id_ecdsa|id_ed25519|*/id_rsa|*/id_dsa|*/id_ecdsa|*/id_ed25519|*.pem|*.key|*.p12|*.pfx|*.ppk) continue ;;
			esac
			case "$path" in
				*/__pycache__/*|.cache|.cache/*|*/.cache|*/.cache/*|.pytest_cache|.pytest_cache/*|*/.pytest_cache|*/.pytest_cache/*|.mypy_cache|.mypy_cache/*|*/.mypy_cache|*/.mypy_cache/*|.ruff_cache|.ruff_cache/*|*/.ruff_cache|*/.ruff_cache/*|logs|logs/*|*/logs|*/logs/*) continue ;;
			esac
			[[ "$path" == *.pyc || "$path" == *.log ]] && continue
			if [[ ! -f "$ROOT_DIR/$path" && ! -L "$ROOT_DIR/$path" ]]; then
				if git ls-files --deleted -- "$path" | grep -Fxq -- "$path"; then continue; fi
				die "indexed source disappeared before packaging: $path"
			fi
			mkdir -p "$repo_stage/$(dirname "$path")"
			cp -a -- "$ROOT_DIR/$path" "$repo_stage/$path"
		done < <(git ls-files --cached --others --exclude-standard -z)
		append_ignore() {
			local file="$1" entry="$2"
			grep -Fxq -- "$entry" "$file" || printf '%s\n' "$entry" >> "$file"
		}
		ignore_path() {
			local escaped="$1"
			escaped="${escaped//2/[2]}"
			printf '/%s' "$escaped"
		}
		for entry in '/dist/' '/content/vendor/k3s/payload-stage/' '/learner-vm/content/vendor/payload/'; do
			append_ignore "$repo_stage/.gitignore" "$entry"
		done
		for path in "${OBSOLETE_PATHS[@]}"; do append_ignore "$repo_stage/.gitignore" "$(ignore_path "$path")"; done

		payload_stage="$repo_stage/$ZIP_PAYLOAD_ROOT"
		mkdir -p "$payload_stage/k3s"
		verify_sha "$BINARY_CACHE" "$K3S_BINARY_SHA"
		install -m 0700 "$BINARY_CACHE" "$payload_stage/k3s/k3s"
		staged_binary_sha=$(sha256sum "$payload_stage/k3s/k3s" | awk '{print $1}')
		[[ "$staged_binary_sha" == "$K3S_BINARY_SHA" ]] || die "staged ZIP payload hash mismatch for $ZIP_BINARY_PATH: expected $K3S_BINARY_SHA, actual $staged_binary_sha"
		{
			printf 'relative_path\tversion\tsource_url\tsha256\tstatus\n'
			printf '%s\t%s\t%s\t%s\tREQUIRED\n' "$ZIP_BINARY_PATH" "$K3S_VERSION" "$K3S_BINARY_URL" "$K3S_BINARY_SHA"
			if [[ "$INCLUDE_AIRGAP" == true ]]; then
				verify_sha "$TARBALL_CACHE" "$K3S_TARBALL_SHA"
				install -m 0600 "$TARBALL_CACHE" "$payload_stage/k3s/k3s-airgap-images-amd64.tar.zst"
				staged_airgap_sha=$(sha256sum "$payload_stage/k3s/k3s-airgap-images-amd64.tar.zst" | awk '{print $1}')
				[[ "$staged_airgap_sha" == "$K3S_TARBALL_SHA" ]] || die "staged ZIP payload hash mismatch for $ZIP_AIRGAP_PATH: expected $K3S_TARBALL_SHA, actual $staged_airgap_sha"
				printf '%s\t%s\t%s\t%s\tOPTIONAL_INCLUDED\n' "$ZIP_AIRGAP_PATH" "$K3S_VERSION" "$K3S_TARBALL_URL" "$K3S_TARBALL_SHA"
			else
				printf '%s\t%s\t%s\t%s\tOPTIONAL_NOT_INCLUDED\n' "$ZIP_AIRGAP_PATH" "$K3S_VERSION" "$K3S_TARBALL_URL" "$K3S_TARBALL_SHA"
			fi
		} > "$repo_stage/$ZIP_PAYLOAD_MANIFEST"
		zip_temporary="$OUT_DIR/.o11y-lab-vm-repository.zip.partial.$$"
		sha_temporary="$OUT_DIR/.o11y-lab-vm-repository.zip.sha256.partial.$$"
		rm -f -- "$zip_temporary" "$sha_temporary"
		(cd "$repo_stage" && zip -q -X -yr "$zip_temporary" .)
		unzip -tqq "$zip_temporary" || die "generated ZIP failed its integrity test: $zip_temporary"
		for relative_path in "$ZIP_BINARY_PATH" "$ZIP_PAYLOAD_MANIFEST"; do
			entry=$(unzip -Z1 "$zip_temporary" | awk -v path="$relative_path" '$0 == path || $0 == "./" path {print; exit}')
			[[ -n "$entry" ]] || die "generated ZIP is missing required entry $relative_path"
		done
	binary_entry=$(unzip -Z1 "$zip_temporary" | awk -v path="$ZIP_BINARY_PATH" '$0 == path || $0 == "./" path {print; exit}')
		staged_binary_sha=$(unzip -p "$zip_temporary" "$binary_entry" | sha256sum | awk '{print $1}')
		[[ "$staged_binary_sha" == "$K3S_BINARY_SHA" ]] || die "embedded ZIP payload hash mismatch for $ZIP_BINARY_PATH: expected $K3S_BINARY_SHA, actual $staged_binary_sha"
		if [[ "$INCLUDE_AIRGAP" == true ]]; then
			airgap_entry=$(unzip -Z1 "$zip_temporary" | awk -v path="$ZIP_AIRGAP_PATH" '$0 == path || $0 == "./" path {print; exit}')
			[[ -n "$airgap_entry" ]] || die "generated ZIP is missing required included entry $ZIP_AIRGAP_PATH"
			staged_airgap_sha=$(unzip -p "$zip_temporary" "$airgap_entry" | sha256sum | awk '{print $1}')
			[[ "$staged_airgap_sha" == "$K3S_TARBALL_SHA" ]] || die "embedded ZIP payload hash mismatch for $ZIP_AIRGAP_PATH: expected $K3S_TARBALL_SHA, actual $staged_airgap_sha"
		fi
		zip_sha=$(sha256sum "$zip_temporary" | awk '{print $1}')
		printf '%s  %s\n' "$zip_sha" "$(basename "$REPO_ZIP")" > "$sha_temporary"
		mv -- "$zip_temporary" "$REPO_ZIP"
		zip_temporary=''
		mv -- "$sha_temporary" "$REPO_ZIP_SHA"
		sha_temporary=''
		(cd "$OUT_DIR" && sha256sum -c "$(basename "$REPO_ZIP_SHA")")
		trap - EXIT
		cleanup_temp
	fi
else
	printf '%s PHASE C — PACKAGE skipped by --clean-obsolete-only; verified payload remains in the ignored staging cache.\n' "$LOG_PREFIX"
fi

if [[ -n "$MANUAL_BUNDLE_DIR" || "$MANUAL_INSTRUCTIONS_REQUESTED" == true ]]; then
	if [[ "$DRY_RUN" == true ]]; then
		if [[ -n "$MANUAL_BUNDLE_DIR" ]]; then
			printf '%s MANUAL BUNDLE DRY-RUN\n' "$LOG_PREFIX"
			python3 - "$ROOT_DIR/content/vendor/manual-fetch.json" "$MANUAL_BUNDLE_DIR" "$INCLUDE_AIRGAP" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
output_dir, include_optional = sys.argv[2], sys.argv[3] == "true"
for entry in document:
    if entry["category"] != "payload":
        continue
    if not entry["required"] and not include_optional:
        print(f'Would omit OPTIONAL {entry["name"]}; pass --include-k3s-airgap-tarball to include it.')
        continue
    print(f'Would fetch/reuse {"REQUIRED" if entry["required"] else "OPTIONAL"} {entry["name"]} from {entry["source"]}; verify SHA-256 {entry["sha256"]}; stage as {entry["staging"]}.')
print(f'Would write {output_dir}/manual-payload.tar.gz and matching .sha256; archive paths are k3s/<filename>.')
PY
		fi
		if [[ "$MANUAL_INSTRUCTIONS_REQUESTED" == true ]]; then
			printf '%s MANUAL INSTRUCTIONS DRY-RUN\n' "$LOG_PREFIX"
			python3 - "$ROOT_DIR/content/vendor/manual-fetch.json" "$MANUAL_INSTRUCTIONS_PATH" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for entry in document:
    if entry["category"] == "payload":
        status = "REQUIRED" if entry["required"] else "OPTIONAL"
        print(f'{status} {entry["name"]} | {entry["source"]} | sha256={entry["sha256"]} | staging={entry["staging"]}')
print(f'Would write payload-only manual fetch instructions to {sys.argv[2]}.')
PY
		fi
	else
		if [[ -n "$MANUAL_BUNDLE_DIR" ]]; then
			command -v tar >/dev/null 2>&1 || die 'tar is required for --manual-bundle'
			manual_stage=$(mktemp -d "${TMPDIR:-/tmp}/manual-payload.XXXXXX")
			trap 'rm -rf -- "$manual_stage"' EXIT
			mkdir -p "$manual_stage/k3s" "$MANUAL_BUNDLE_DIR"
			install -m 0755 "$BINARY_CACHE" "$manual_stage/k3s/k3s"
			if [[ "$INCLUDE_AIRGAP" == true ]]; then install -m 0644 "$TARBALL_CACHE" "$manual_stage/k3s/k3s-airgap-images-amd64.tar.zst"; fi
			manual_archive="$MANUAL_BUNDLE_DIR/manual-payload.tar.gz"
			manual_archive_sum="$manual_archive.sha256"
			rm -f -- "$manual_archive" "$manual_archive_sum"
			(cd "$manual_stage" && tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -czf "$manual_archive" k3s)
			(cd "$MANUAL_BUNDLE_DIR" && sha256sum "$(basename "$manual_archive")" > "$(basename "$manual_archive").sha256" && sha256sum -c "$(basename "$manual_archive").sha256")
			rm -rf -- "$manual_stage"
			trap - EXIT
		fi
		if [[ "$MANUAL_INSTRUCTIONS_REQUESTED" == true ]]; then
			python3 -B "$ROOT_DIR/scripts/dev/generate-manual-fetch.py" --instructions "$MANUAL_INSTRUCTIONS_PATH"
		fi
	fi
fi

printf '%s PHASE D — REMOVE OBSOLETE FILES\n' "$LOG_PREFIX"
if [[ "$DRY_RUN" == true ]]; then
	if [[ "$NO_CLEAN" == true ]]; then
		printf 'Cleanup is disabled by default; no source files will be removed or staged.\n'
	else
		for index in "${!OBSOLETE_PATHS[@]}"; do
			path="${OBSOLETE_PATHS[$index]}"
			if [[ -e "$path" ]]; then
				printf 'Would git rm -- %s (%s)\n' "$path" "${OBSOLETE_REPLACEMENTS[$index]}"
			else
				printf 'No removal needed; already absent from HEAD: %s\n' "$path"
			fi
		done
		printf 'Would add exact ignore entries for dist/, payload staging, and the four obsolete paths.\n'
	fi
	printf '%s dry-run complete; no files were fetched, written, or removed.\n' "$LOG_PREFIX"
	exit 0
fi

if [[ "$NO_CLEAN" == true ]]; then
	printf '%s cleanup skipped by --no-clean; obsolete source files remain untouched.\n' "$LOG_PREFIX"
else
	for path in "${OBSOLETE_PATHS[@]}"; do
		if [[ -e "$path" ]]; then git rm -- "$path"; fi
	done
	append_ignore() {
		local file="$1" entry="$2"
		grep -Fxq -- "$entry" "$file" || printf '%s\n' "$entry" >> "$file"
	}
	for entry in '/dist/' '/content/vendor/k3s/payload-stage/'; do
		append_ignore .gitignore "$entry"
	done
	for path in "${OBSOLETE_PATHS[@]}"; do append_ignore .gitignore "$(ignore_path "$path")"; done
	git add -- .gitignore
	printf '%s Removal diff stat (staged):\n' "$LOG_PREFIX"
	git diff --cached --stat -- "${OBSOLETE_PATHS[@]}"
fi

if [[ "$CLEAN_ONLY" == true ]]; then
	printf '%s clean-obsolete-only complete; no package archives were created.\n' "$LOG_PREFIX"
	printf '%s removed files: %s; recovered bytes: %s\n' "$LOG_PREFIX" "${#OBSOLETE_PATHS[@]}" "$TOTAL_BYTES"
	exit 0
fi

printf '%s PHASE E — SUMMARY\n' "$LOG_PREFIX"
if [[ "$NO_CLEAN" == false ]]; then
	removed_count=0
	removed_bytes=0
	for path in "${OBSOLETE_PATHS[@]}"; do
		if [[ ! -e "$path" ]] && git diff --cached --name-only --diff-filter=D -- "$path" | grep -Fxq -- "$path"; then
			((removed_count += 1))
			removed_bytes=$((removed_bytes + $(head_file_size HEAD "$path")))
		fi
	done
else
	removed_count=0
	removed_bytes=0
	for path in "${OBSOLETE_PATHS[@]}"; do
		if [[ ! -e "$path" ]] && git diff --cached --name-only --diff-filter=D -- "$path" | grep -Fxq -- "$path"; then
			((removed_count += 1))
			removed_bytes=$((removed_bytes + $(head_file_size HEAD "$path")))
		fi
	done
fi
zip_sha=$(sha256sum "$REPO_ZIP" | awk '{print $1}')
printf 'single-transfer repository ZIP: %s | %s bytes | SHA-256 %s\n' "${REPO_ZIP#"$ROOT_DIR/"}" "$(stat -c '%s' "$REPO_ZIP")" "$zip_sha"
printf 'embedded payload manifest: %s\n' "$ZIP_PAYLOAD_MANIFEST"
if [[ -n "$MANUAL_BUNDLE_DIR" ]]; then printf 'optional standalone manual bundle: %s/manual-payload.tar.gz\n' "$MANUAL_BUNDLE_DIR"; fi
printf 'removed files: %s | total bytes: %s\n' "$removed_count" "$removed_bytes"
printf 'obsolete-manifest resolutions:\n'
for index in "${!OBSOLETE_PATHS[@]}"; do
	printf '%s | %s | %s bytes | %s\n' "${OBSOLETE_PATHS[$index]}" "${OBSOLETE_REPLACEMENTS[$index]}" "${OBSOLETE_SIZES[$index]}" "${OBSOLETE_REASONS[$index]}"
done
printf 'online ZIP sidecar check: (cd %s && sha256sum -c %s)\n' "${OUT_DIR#"$ROOT_DIR/"}" "$(basename "$REPO_ZIP_SHA")"
printf 'receiving commands (transfer this ZIP only):\n'
printf "ZIP_SHA256='%s'\n" "$zip_sha"
cat <<'EOF'
set -euo pipefail
REPOSITORY_DIR="$HOME/o11y-lab"
printf '%s  %s\n' "$ZIP_SHA256" o11y-lab-vm-repository.zip | sha256sum -c -
mkdir -p "$REPOSITORY_DIR"
unzip -q o11y-lab-vm-repository.zip -d "$REPOSITORY_DIR"
cd "$REPOSITORY_DIR"
verify_payload() {
	local relative_path="$1" lock_key="$2" expected_status="$3" lock_line lock_sha manifest_row manifest_status manifest_sha actual
	local manifest='learner-vm/content/vendor/payload/payload-manifest.txt'
	lock_line="$(awk -v key="$lock_key" '$1 == key {print; exit}' versions.lock)"
	lock_sha="$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^sha256:/) {sub(/^sha256:/,"",$i); print $i; exit}}' <<< "$lock_line")"
	manifest_row="$(awk -F '\t' -v path="$relative_path" '$1 == path {print; exit}' "$manifest")"
	[[ -n "$lock_sha" && -n "$manifest_row" ]] || { printf 'Missing pin or manifest row: %s\n' "$relative_path" >&2; return 1; }
	manifest_status="$(cut -f5 <<< "$manifest_row")"
	if [[ "$manifest_status" == OPTIONAL_NOT_INCLUDED ]]; then printf 'SKIP optional payload: %s\n' "$relative_path"; return 0; fi
	[[ "$manifest_status" == "$expected_status" ]] || { printf 'Manifest status mismatch: %s\n' "$relative_path" >&2; return 1; }
	manifest_sha="$(cut -f4 <<< "$manifest_row")"
	[[ "$manifest_sha" == "$lock_sha" ]] || { printf 'versions.lock/manifest mismatch: %s\n' "$relative_path" >&2; return 1; }
	actual="$(sha256sum "$relative_path" | awk '{print $1}')"
	[[ "$actual" == "$lock_sha" ]] || { printf 'Payload SHA-256 mismatch: %s\n' "$relative_path" >&2; return 1; }
	printf 'PASS %s %s\n' "$relative_path" "$actual"
}
verify_payload learner-vm/content/vendor/payload/k3s/k3s learner-k3s-binary-amd64 REQUIRED
verify_payload learner-vm/content/vendor/payload/k3s/k3s-airgap-images-amd64.tar.zst learner-k3s-airgap-images-amd64.tar.zst OPTIONAL_INCLUDED
cd "$REPOSITORY_DIR/learner-vm"
sudo bash scripts/00-diagnose.sh
EOF
printf 'Transcribe the complete REPORT block and wait for review before running scripts 10-80.\n'
