#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX='[package-vm-transfer]'
# Phase C archives a filtered source-only staging copy and never cleans the worktree.
ROOT_DIR=$(git rev-parse --show-toplevel)
cd "$ROOT_DIR"

MANIFEST='scripts/dev/obsolete-artifacts.txt'
STAGING_DIR='content/vendor/k3s/payload-stage'
DEFAULT_OUT='dist/o11y-lab-vm-transfer'
OUT_DIR="$ROOT_DIR/$DEFAULT_OUT"
DRY_RUN=false
MANUAL_INSTRUCTIONS_REQUESTED=false
MANUAL_INSTRUCTIONS_PATH=''
LIST_MANUAL=false

usage() {
	cat <<'EOF'
Usage: scripts/dev/package-vm-transfer.sh [options]
	--dry-run                      preview source-only ZIP packaging without writing or deleting files
	--out DIR                      output directory (default: dist/o11y-lab-vm-transfer)
	--manual-instructions [PATH]   write runtime binary recovery notes (default under dist/)
	--list-manual                  print the generated manual-fetch entry table and exit
EOF
}

while (($#)); do
	case "$1" in
		--dry-run) DRY_RUN=true ;;
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

if [[ "$OUT_DIR" != /* ]]; then OUT_DIR="$ROOT_DIR/$OUT_DIR"; fi
if [[ "$LIST_MANUAL" == true ]]; then
	exec python3 -B "$ROOT_DIR/scripts/dev/generate-manual-fetch.py" --list
fi
if [[ "$MANUAL_INSTRUCTIONS_REQUESTED" == true && -z "$MANUAL_INSTRUCTIONS_PATH" ]]; then
	MANUAL_INSTRUCTIONS_PATH="$OUT_DIR/MANUAL-FETCH-runtime.txt"
fi
if [[ -n "$MANUAL_INSTRUCTIONS_PATH" && "$MANUAL_INSTRUCTIONS_PATH" != /* ]]; then MANUAL_INSTRUCTIONS_PATH="$ROOT_DIR/$MANUAL_INSTRUCTIONS_PATH"; fi

REPO_ZIP="$OUT_DIR/o11y-lab-vm-repository.zip"
REPO_ZIP_SHA="$REPO_ZIP.sha256"
GENERATED_PAYLOAD_DIR='learner-vm/content/vendor/payload'
if [[ "$DRY_RUN" == false && ( -e "$REPO_ZIP" || -e "$REPO_ZIP_SHA" ) ]]; then
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
printf 'Legacy artifact bytes reviewed (not fetched or transferred): %s\n' "$TOTAL_BYTES"
printf '%s PHASE B — FETCH AND VERIFY REPLACEMENTS\n' "$LOG_PREFIX"
printf 'No k3s binary or airgap archive is fetched, copied, or required by the source-only ZIP.\n'
printf 'K3S_BINARY_URL and the binary SHA remain operator/runtime configuration and versions.lock metadata.\n'

printf '%s PHASE C — PACKAGE SOURCE-ONLY REPOSITORY ZIP\n' "$LOG_PREFIX"
if [[ "$DRY_RUN" == true ]]; then
	printf 'Would build %s from tracked worktree content, including unstaged edits, plus non-ignored untracked source; deleted paths are omitted.\n' "${REPO_ZIP#"$ROOT_DIR/"}"
	printf 'Would exclude .git/, .git/lfs/, dist/, logs/caches, private-key paths, payload staging/generated payloads, and the four obsolete paths.\n'
	printf 'Would write only an online ZIP checksum sidecar; no runtime payload, archive, or cache files would be created.\n'
	printf 'Would preserve the worktree and never stage or clean source files.\n'
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
		[[ "$path" == "$GENERATED_PAYLOAD_DIR" || "$path" == "$GENERATED_PAYLOAD_DIR/"* ]] && continue
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
	append_ignore "$repo_stage/.gitignore" '/dist/'
	append_ignore "$repo_stage/.gitignore" "/$STAGING_DIR/"
	append_ignore "$repo_stage/.gitignore" "/$GENERATED_PAYLOAD_DIR/"
	zip_temporary="$OUT_DIR/.o11y-lab-vm-repository.zip.partial.$$"
	sha_temporary="$OUT_DIR/.o11y-lab-vm-repository.zip.sha256.partial.$$"
	rm -f -- "$zip_temporary" "$sha_temporary"
	(cd "$repo_stage" && zip -q -X -yr "$zip_temporary" .)
	unzip -tqq "$zip_temporary" || die "generated ZIP failed its integrity test: $zip_temporary"
	ZIP_LIST_TEMP="$temp_root/zip-list.txt"
	unzip -Z1 "$zip_temporary" > "$ZIP_LIST_TEMP"
	for required in learner-vm/scripts/00-diagnose.sh learner-vm/scripts/45-k3s-install.sh learner-vm/lab-vm.conf content/vendor/MANUAL-FETCH.md content/vendor/manual-fetch.json; do
		grep -Fxq -- "$required" "$ZIP_LIST_TEMP" || grep -Fxq -- "./$required" "$ZIP_LIST_TEMP" || die "generated ZIP is missing required source entry $required"
	done
	if grep -Eq '(^|/)content/vendor/payload/k3s/|(^|/)content/vendor/k3s/k3s$|(^|/)k3s-airgap-images-amd64\.tar\.zst$|\.tar\.(gz|zst)$|o11y-lab-vm-payload' "$ZIP_LIST_TEMP"; then die 'generated source-only ZIP unexpectedly contains a k3s binary, airgap image tarball, or payload archive'; fi
	zip_sha=$(sha256sum "$zip_temporary" | awk '{print $1}')
	printf '%s  %s\n' "$zip_sha" "$(basename "$REPO_ZIP")" > "$sha_temporary"
	mv -- "$zip_temporary" "$REPO_ZIP"
	zip_temporary=''
	mv -- "$sha_temporary" "$REPO_ZIP_SHA"
	sha_temporary=''
	(cd "$OUT_DIR" && sha256sum -c "$(basename "$REPO_ZIP_SHA")")
	zip_contents=$(wc -l < "$ZIP_LIST_TEMP" | tr -d '[:space:]')
	trap - EXIT
	cleanup_temp
fi

if [[ "$MANUAL_INSTRUCTIONS_REQUESTED" == true ]]; then
	if [[ "$DRY_RUN" == true ]]; then
		printf '%s MANUAL INSTRUCTIONS DRY-RUN\n' "$LOG_PREFIX"
		python3 - "$ROOT_DIR/content/vendor/manual-fetch.json" "$MANUAL_INSTRUCTIONS_PATH" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(*(
	f'{"REQUIRED" if entry["required"] else "OPTIONAL"} {entry["name"]} | {entry["source"]} | lock_key={entry.get("lock_key", "n/a")} | staging={entry["staging"]}'
	for entry in document
	if entry["category"] == "payload"
), sep="\n")
print(f'Would write runtime binary recovery instructions to {sys.argv[2]}.')
PY
	else
		python3 -B "$ROOT_DIR/scripts/dev/generate-manual-fetch.py" --instructions "$MANUAL_INSTRUCTIONS_PATH"
	fi
fi

if [[ "$DRY_RUN" == true ]]; then
	printf 'Dry-run complete; source files were not fetched, written, removed, staged, or committed.\n'
	exit 0
fi

zip_sha=$(sha256sum "$REPO_ZIP" | awk '{print $1}')
zip_contents=$(zipinfo -1 "$REPO_ZIP" | wc -l | tr -d '[:space:]')
printf '%s PHASE D — SUMMARY\n' "$LOG_PREFIX"
printf 'source-only repository ZIP: %s | %s bytes | SHA-256 %s\n' "${REPO_ZIP#"$ROOT_DIR/"}" "$(stat -c '%s' "$REPO_ZIP")" "$zip_sha"
printf 'archive contents: %s entries; k3s binary and airgap tarball are not included\n' "$zip_contents"
printf 'online-only SHA sidecar: %s (not required on learner VM)\n' "${REPO_ZIP_SHA#"$ROOT_DIR/"}"
printf 'receiving instructions (transfer this ZIP only):\n'
printf "ZIP_SHA256='%s'\n" "$zip_sha"
cat <<'EOF'
set -euo pipefail
REPOSITORY_DIR="$HOME/o11y-lab"
printf '%s  %s\n' "$ZIP_SHA256" o11y-lab-vm-repository.zip | sha256sum -c -
mkdir -p "$REPOSITORY_DIR"
unzip -q o11y-lab-vm-repository.zip -d "$REPOSITORY_DIR"
cd "$REPOSITORY_DIR/learner-vm"
sudo bash scripts/00-diagnose.sh
EOF
printf 'Transcribe the complete REPORT block and wait for review before running scripts 10-80.\n'
