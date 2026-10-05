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
INCLUDE_AIRGAP=false
NO_CLEAN=false
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
  --include-k3s-airgap-tarball   include the optional k3s image fallback
  --no-clean                     package assets but leave obsolete files
  --clean-obsolete-only          fetch/verify required payload, then clean
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
		--no-clean) NO_CLEAN=true ;;
		--clean-obsolete-only) CLEAN_ONLY=true ;;
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

if [[ "$CLEAN_ONLY" == true && "$NO_CLEAN" == true ]]; then
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
	"k3s/k3s": (sys.argv[2], sys.argv[3], True),
	"k3s/k3s-airgap-images-amd64.tar.zst": (sys.argv[4], sys.argv[5], False),
}
actual = {entry["name"]: entry for entry in payload}
if set(actual) != set(expected):
	raise SystemExit(f"manual-fetch.json payload entries differ from pinned package inputs: {sorted(actual)}")
for name, (url, digest, required) in expected.items():
	entry = actual[name]
	if (entry["source"], entry["sha256"], entry["required"]) != (url, digest, required):
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
	local url="$1" expected="$2" target="$3" temporary="$3.partial"
	if [[ "$REFRESH" == false && -s "$target" ]]; then
		if actual=$(sha256sum "$target" | awk '{print $1}') && [[ "$actual" == "$expected" ]]; then
			printf '%s verified cached payload %s (%s)\n' "$LOG_PREFIX" "${target#"$ROOT_DIR/"}" "$actual"
			return 0
		fi
		printf '%s cached payload failed verification; re-fetching %s\n' "$LOG_PREFIX" "${target#"$ROOT_DIR/"}" >&2
	fi
	mkdir -p "$(dirname "$target")"
	rm -f -- "$temporary"
	curl -fL --retry 2 --connect-timeout 15 --max-time 900 "$url" -o "$temporary"
	verify_sha "$temporary" "$expected"
	mv -f -- "$temporary" "$target"
	printf '%s fetched and verified %s (%s)\n' "$LOG_PREFIX" "${target#"$ROOT_DIR/"}" "$expected"
}

printf '%s PHASE B — FETCH AND VERIFY REPLACEMENTS\n' "$LOG_PREFIX"
if [[ "$DRY_RUN" == true ]]; then
	printf 'Would fetch or reuse REQUIRED k3s %s from %s; SHA-256 %s; cache %s\n' "$K3S_VERSION" "$K3S_BINARY_URL" "$K3S_BINARY_SHA" "${BINARY_CACHE#"$ROOT_DIR/"}"
	if [[ "$INCLUDE_AIRGAP" == true ]]; then
		printf 'Would fetch or reuse OPTIONAL airgap tarball from %s; SHA-256 %s; cache %s\n' "$K3S_TARBALL_URL" "$K3S_TARBALL_SHA" "${TARBALL_CACHE#"$ROOT_DIR/"}"
	else
		printf 'Would omit OPTIONAL airgap tarball; use --include-k3s-airgap-tarball to include it.\n'
	fi
else
	command -v curl >/dev/null 2>&1 || die 'curl is required to fetch the pinned payload'
	command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required to verify the pinned payload'
	fetch_verified "$K3S_BINARY_URL" "$K3S_BINARY_SHA" "$BINARY_CACHE"
	if [[ "$INCLUDE_AIRGAP" == true ]]; then
		fetch_verified "$K3S_TARBALL_URL" "$K3S_TARBALL_SHA" "$TARBALL_CACHE"
	fi
fi

REPO_ZIP="$OUT_DIR/o11y-lab-vm-repository.zip"
PAYLOAD_DIR="$OUT_DIR/payload"
PAYLOAD_ARCHIVE="$PAYLOAD_DIR/o11y-lab-vm-payload.tar.gz"
PAYLOAD_MANIFEST="$PAYLOAD_DIR/payload-manifest.txt"

if [[ "$CLEAN_ONLY" == false ]]; then
	printf '%s PHASE C — PACKAGE\n' "$LOG_PREFIX"
	if [[ "$DRY_RUN" == true ]]; then
		printf 'Would build repository ZIP from the Git index and working-tree contents into a temporary staging copy.\n'
		printf 'Would exclude .git/, .git/lfs/, dist/, generated logs/caches, and every obsolete-artifacts.txt path.\n'
		printf 'Would include the Phase-D .gitignore entries in the staging copy so the ZIP reflects post-clean state.\n'
		printf 'Would build %s and %s with matching SHA-256 sidecars.\n' "${REPO_ZIP#"$ROOT_DIR/"}" "${PAYLOAD_ARCHIVE#"$ROOT_DIR/"}"
	else
		command -v zip >/dev/null 2>&1 || die 'zip is required to create the repository archive'
		command -v tar >/dev/null 2>&1 || die 'tar is required to create the payload archive'
		command -v cp >/dev/null 2>&1 || die 'cp is required to stage repository files'
		mkdir -p "$OUT_DIR" "$PAYLOAD_DIR"
		temp_root=$(mktemp -d "${TMPDIR:-/tmp}/o11y-transfer.XXXXXX")
		cleanup_temp() { rm -rf -- "$temp_root"; }
		trap cleanup_temp EXIT
		repo_stage="$temp_root/repository"
		mkdir -p "$repo_stage"
		while IFS= read -r -d '' path; do
			[[ -n "${OBSOLETE_SET[$path]+x}" ]] && continue
			[[ "$path" == dist || "$path" == dist/* ]] && continue
			case "$path" in
				*/__pycache__/*|.cache|.cache/*|*/.cache|*/.cache/*|.pytest_cache|.pytest_cache/*|*/.pytest_cache|*/.pytest_cache/*|.mypy_cache|.mypy_cache/*|*/.mypy_cache|*/.mypy_cache/*|.ruff_cache|.ruff_cache/*|*/.ruff_cache|*/.ruff_cache/*|logs|logs/*|*/logs|*/logs/*) continue ;;
			esac
			[[ "$path" == *.pyc || "$path" == *.log ]] && continue
			[[ -f "$ROOT_DIR/$path" || -L "$ROOT_DIR/$path" ]] || die "indexed source disappeared before packaging: $path"
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
		for entry in '/dist/' '/content/vendor/k3s/payload-stage/'; do
			append_ignore "$repo_stage/.gitignore" "$entry"
		done
		for path in "${OBSOLETE_PATHS[@]}"; do append_ignore "$repo_stage/.gitignore" "$(ignore_path "$path")"; done
		rm -f -- "$REPO_ZIP" "$REPO_ZIP.sha256"
		(cd "$repo_stage" && zip -q -X -yr "$REPO_ZIP" .)
		(cd "$OUT_DIR" && sha256sum "$(basename "$REPO_ZIP")" > "$(basename "$REPO_ZIP").sha256")
		(cd "$OUT_DIR" && sha256sum -c "$(basename "$REPO_ZIP").sha256")

		payload_stage="$temp_root/payload"
		mkdir -p "$payload_stage/payload/k3s"
		install -m 0700 "$BINARY_CACHE" "$payload_stage/payload/k3s/k3s"
		{
			printf 'relative path | version | source URL | SHA-256 | REQUIRED/OPTIONAL | expected destination on VM\n'
			printf 'payload/k3s/k3s | %s | %s | %s | REQUIRED | /usr/local/bin/k3s (0700 root)\n' "$K3S_VERSION" "$K3S_BINARY_URL" "$K3S_BINARY_SHA"
			if [[ "$INCLUDE_AIRGAP" == true ]]; then
				install -m 0600 "$TARBALL_CACHE" "$payload_stage/payload/k3s/k3s-airgap-images-amd64.tar.zst"
				printf 'payload/k3s/k3s-airgap-images-amd64.tar.zst | %s | %s | %s | OPTIONAL | /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst\n' "$K3S_VERSION" "$K3S_TARBALL_URL" "$K3S_TARBALL_SHA"
			fi
		} > "$PAYLOAD_MANIFEST"
		rm -f -- "$PAYLOAD_ARCHIVE" "$PAYLOAD_ARCHIVE.sha256"
		(cd "$payload_stage" && tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -czf "$PAYLOAD_ARCHIVE" payload)
		(cd "$PAYLOAD_DIR" && sha256sum "$(basename "$PAYLOAD_ARCHIVE")" > "$(basename "$PAYLOAD_ARCHIVE").sha256")
		(cd "$PAYLOAD_DIR" && sha256sum -c "$(basename "$PAYLOAD_ARCHIVE").sha256")
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
	for index in "${!OBSOLETE_PATHS[@]}"; do
		path="${OBSOLETE_PATHS[$index]}"
		if [[ -e "$path" ]]; then
			printf 'Would git rm -- %s (%s)\n' "$path" "${OBSOLETE_REPLACEMENTS[$index]}"
		else
			printf 'No removal needed; already absent from HEAD: %s\n' "$path"
		fi
	done
	printf 'Would add exact ignore entries for dist/, payload staging, and the four obsolete paths.\n'
	printf 'Would report: git diff --cached --stat -- <manifest paths>\n'
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
printf 'repo ZIP: %s | %s bytes | SHA-256 %s\n' "${REPO_ZIP#"$ROOT_DIR/"}" "$(stat -c '%s' "$REPO_ZIP")" "$(sha256sum "$REPO_ZIP" | awk '{print $1}')"
printf 'payload archive: %s | %s bytes | SHA-256 %s\n' "${PAYLOAD_ARCHIVE#"$ROOT_DIR/"}" "$(stat -c '%s' "$PAYLOAD_ARCHIVE")" "$(sha256sum "$PAYLOAD_ARCHIVE" | awk '{print $1}')"
printf 'payload manifest: %s\n' "${PAYLOAD_MANIFEST#"$ROOT_DIR/"}"
printf 'removed files: %s | total bytes: %s\n' "$removed_count" "$removed_bytes"
printf 'obsolete-manifest resolutions:\n'
for index in "${!OBSOLETE_PATHS[@]}"; do
	printf '%s | %s | %s bytes | %s\n' "${OBSOLETE_PATHS[$index]}" "${OBSOLETE_REPLACEMENTS[$index]}" "${OBSOLETE_SIZES[$index]}" "${OBSOLETE_REASONS[$index]}"
done
printf 'operator verification commands:\n  (cd %s && sha256sum -c %s)\n  (cd %s && sha256sum -c %s)\n' \
	"${OUT_DIR#"$ROOT_DIR/"}" "$(basename "$REPO_ZIP").sha256" \
	"${PAYLOAD_DIR#"$ROOT_DIR/"}" "$(basename "$PAYLOAD_ARCHIVE").sha256"
printf 'receiving sequence: verify both archive checksums; extract the repository ZIP to the chosen repository directory; extract the payload archive with --strip-components=1 into /var/tmp/o11y-lab-vm-manual; verify both staged payload hashes against payload/payload-manifest.txt; from <repository>/learner-vm run sudo bash scripts/00-diagnose.sh; transcribe its complete REPORT block and wait for review before running scripts 10-80.\n'
