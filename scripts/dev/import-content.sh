#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX='[import-content]'
ROOT_DIR=$(git rev-parse --show-toplevel)
cd "$ROOT_DIR"

TRACKS=(opentelemetry otel-developers prometheus fluentbit perses)
REFRESH=false
if [[ ${1:-} == --refresh ]]; then
	REFRESH=true
elif [[ $# -gt 0 ]]; then
	printf '%s unknown argument: %s\n' "$LOG_PREFIX" "$1" >&2
	exit 2
fi

for tool in git wget curl python3 sha256sum tar install date; do
	command -v "$tool" >/dev/null || {
		printf '%s required command not found: %s\n' "$LOG_PREFIX" "$tool" >&2
		exit 1
	}
done

mkdir -p content/repos content/docs content/bin
LOCK_TMP=$(mktemp)
WORK_DIR=$(mktemp -d)
cleanup() {
	rm -f "$LOCK_TMP"
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

lock_record() {
	local key=$1 value=$2 reason=$3
	awk -v key="$key" '$1 != key' versions.lock > "$LOCK_TMP"
	printf '%s %s - %s\n' "$key" "$value" "$reason" >> "$LOCK_TMP"
	mv "$LOCK_TMP" versions.lock
}

has_files() {
	[[ -d $1 ]] && [[ -n $(find "$1" -mindepth 1 -maxdepth 1 -print -quit) ]]
}

landing_page() {
	[[ -d $1 ]] && [[ -n $(find "$1" -type f \( -name index.html -o -name index.htm \) -print -quit) ]]
}

lock_value() {
	awk -v key="$1" '$1 == key { print $2; exit }' versions.lock
}

printf 'track | source SHA | lab*.html count | docs landing OK\n'
printf '%s\n' '-------|------------|------------------|-----------------'

for track in "${TRACKS[@]}"; do
	printf '%s importing %s\n' "$LOG_PREFIX" "$track" >&2
	target_repo="content/repos/$track"
	target_docs="content/docs/$track"
	repo_sha=''

	if [[ $REFRESH == false && -s "$target_repo/.source-sha" ]] && has_files "$target_repo"; then
		repo_sha=$(<"$target_repo/.source-sha")
	else
		source_repo=''
		for candidate in "bundle/repos/$track" "$target_repo"; do
			if has_files "$candidate"; then
				source_repo=$candidate
				break
			fi
		done

		if [[ -n $source_repo ]]; then
			if [[ -d "$source_repo/.git" ]]; then
				repo_sha=$(git -C "$source_repo" rev-parse HEAD)
			elif [[ -s "$source_repo/.source-sha" ]]; then
				repo_sha=$(<"$source_repo/.source-sha")
			else
				printf '%s cannot determine HEAD SHA for %s\n' "$LOG_PREFIX" "$source_repo" >&2
				exit 1
			fi
			staged_repo="$WORK_DIR/$track-repo"
			mkdir -p "$staged_repo"
			tar -C "$source_repo" --exclude=.git -cf - . | tar -C "$staged_repo" -xf -
		else
			git clone --quiet "https://gitlab.com/o11y-workshops/workshop-$track.git" "$WORK_DIR/$track-clone"
			repo_sha=$(git -C "$WORK_DIR/$track-clone" rev-parse HEAD)
			staged_repo="$WORK_DIR/$track-repo"
			mkdir -p "$staged_repo"
			tar -C "$WORK_DIR/$track-clone" --exclude=.git -cf - . | tar -C "$staged_repo" -xf -
		fi

		printf '%s\n' "$repo_sha" > "$staged_repo/.source-sha"
		rm -rf "$target_repo"
		mv "$staged_repo" "$target_repo"
	fi
	lock_record "workshop.repo.$track" "$repo_sha" "GitLab source HEAD SHA"

	docs_changed=false
	if [[ $REFRESH == true ]] || ! landing_page "$target_docs"; then
		staged_docs="$WORK_DIR/$track-docs"
		mkdir -p "$staged_docs"
		if has_files "bundle/site/$track"; then
			tar -C "bundle/site/$track" -cf - . | tar -C "$staged_docs" -xf -
		else
			if ! wget --quiet --mirror --convert-links --page-requisites --no-parent \
				-P "$staged_docs" "https://o11y-workshops.gitlab.io/workshop-$track/"; then
				printf '%s warning: wget reported an error while mirroring %s\n' "$LOG_PREFIX" "$track" >&2
			fi
		fi
		if ! landing_page "$staged_docs"; then
			printf '%s no docs landing page found for %s\n' "$LOG_PREFIX" "$track" >&2
			exit 1
		fi
		rm -rf "$target_docs"
		mv "$staged_docs" "$target_docs"
		docs_changed=true
	fi
	docs_date=$(lock_value "workshop.docs.$track")
	if [[ $docs_changed == true || -z $docs_date ]]; then
		docs_date=$(date -u +%Y-%m-%d)
	fi
	lock_record "workshop.docs.$track" "$docs_date" "GitLab Pages mirror date"

	lab_count=$(find "$target_repo" -type f -name 'lab*.html' | wc -l | tr -d ' ')
	if landing_page "$target_docs"; then
		docs_ok=yes
	else
		docs_ok=no
	fi
	printf '%s | %s | %s | %s\n' "$track" "$repo_sha" "$lab_count" "$docs_ok"
done

compose_binary=content/bin/docker-compose-v2
compose_checksum=content/bin/docker-compose-v2.sha256
compose_version=$(lock_value workshop.compose-v2)
if [[ $REFRESH == true || ! -s $compose_binary || ! -s $compose_checksum ]]; then
	compose_release=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest)
	compose_tag=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' <<< "$compose_release")
	compose_version=${compose_tag#v}
	compose_url="https://github.com/docker/compose/releases/download/$compose_tag/docker-compose-linux-x86_64"
	curl -fL "$compose_url" -o "$WORK_DIR/docker-compose-v2"
	install -m 0755 "$WORK_DIR/docker-compose-v2" "$compose_binary"
	compose_sha=$(sha256sum "$compose_binary" | awk '{print $1}')
	printf '%s  docker-compose-v2\n' "$compose_sha" > "$compose_checksum"
else
	compose_sha=$(sha256sum "$compose_binary" | awk '{print $1}')
	compose_expected=$(awk '{print $1}' "$compose_checksum")
	if [[ $compose_sha != "$compose_expected" ]]; then
		printf '%s checksum mismatch for %s; use --refresh to replace it\n' "$LOG_PREFIX" "$compose_binary" >&2
		exit 1
	fi
	if [[ -z $compose_version ]]; then
		printf '%s no Compose version is recorded in versions.lock; use --refresh to reacquire it\n' "$LOG_PREFIX" >&2
		exit 1
	fi
	compose_tag="v$compose_version"
	compose_url="https://github.com/docker/compose/releases/download/$compose_tag/docker-compose-linux-x86_64"
fi
lock_record workshop.compose-v2 "$compose_version" "source=$compose_url sha256=$compose_sha"
printf '%s vendored docker-compose %s (%s)\n' "$LOG_PREFIX" "$compose_version" "$compose_sha"
