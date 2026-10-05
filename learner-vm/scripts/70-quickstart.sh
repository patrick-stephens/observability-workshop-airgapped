#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="70-quickstart"
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
	step_fail "unknown argument: $argument" "Run learner-vm/scripts/70-quickstart.sh [--dry-run]." "printf '%s\\n' --dry-run"
done
if ((EUID != 0)) && [[ "$DRY_RUN" == false ]]; then
	step_fail "quickstart installation requires root" "Run sudo learner-vm/scripts/70-quickstart.sh after scripts 10-62." "id -u"
	end_report "rerun with sudo after image preparation completes"
	exit 1
elif ((EUID != 0)); then
	step_skip "root is required for service installation; dry-run continues" "rerun with sudo on the learner VM"
fi

if [[ ! -s "$REPO_ROOT/content/extracted/curated.json" || ! -d "$DOCS_ROOT" ]]; then
	step_fail "curated runs or mirrored docs are missing" "Restore content/extracted/curated.json and content/docs from the repository ZIP." "ls -l $(printf %q "$REPO_ROOT/content/extracted/curated.json")" "find $(printf %q "$DOCS_ROOT") -maxdepth 2 -type f -name index.html"
	end_report "restore the repository content before installing quickstart"
	exit 1
fi

docs_unit='/etc/systemd/system/o11y-workshop-docs.service'
docs_unit_tmp=''
cleanup() { [[ -z "$docs_unit_tmp" ]] || rm -f -- "$docs_unit_tmp"; }
trap cleanup EXIT

if [[ "$DRY_RUN" == true ]]; then
	log "would install a localhost-only Python documentation server on port $DOCS_PORT, rooted at $DOCS_ROOT"
	run "install -o root -g root -m 0644 <generated unit> $(printf %q "$docs_unit")"
	run 'systemctl daemon-reload && systemctl enable --now o11y-workshop-docs.service'
	step_skip "documentation service installation and HTTP verification were previewed" "http://localhost:$DOCS_PORT/"
	for program in run-workshop.sh stop-workshop.sh; do
		run "ln -s $(printf %q "$REPO_ROOT/bin/$program") /usr/local/bin/$program"
		step_skip "PATH dispatcher link was previewed" "/usr/local/bin/$program"
	done
	step_skip "Firefox install/policy path was target-side and was not inspected during dry-run" "bookmark is added only after checking the installed Firefox distribution directory"
	step_skip "desktop environment and engineer Desktop directory were not inspected during dry-run" "shortcut is optional and added only when the GNOME paths exist"
else
	if ! command -v python3 >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
		step_fail "Python 3 or systemd is unavailable for the local docs service" "Install Python 3 and run this on the systemd-based RHEL learner VM." "command -v python3" "command -v systemctl" "rpm -q python3 systemd"
	else
		docs_unit_tmp=$(mktemp "${TMPDIR:-/tmp}/o11y-docs.XXXXXX") || docs_unit_tmp=''
		if [[ -z "$docs_unit_tmp" ]]; then
			step_fail "could not create temporary docs unit" "Check temporary disk space." "df -hP /tmp" "ls -ld /etc/systemd/system"
		else
			cat > "$docs_unit_tmp" <<EOF
[Unit]
Description=Local Observability Workshop Documentation
After=network.target

[Service]
Type=simple
User=$WORKSHOP_USER
WorkingDirectory=$DOCS_ROOT
ExecStart=/usr/bin/python3 -m http.server $DOCS_PORT --bind 127.0.0.1 --directory $DOCS_ROOT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
			if [[ -e "$docs_unit" ]] && ! cmp -s "$docs_unit_tmp" "$docs_unit"; then
				step_fail "refusing to replace an existing, different docs service unit" "Review $docs_unit and preserve its current settings before retrying." "systemctl cat o11y-workshop-docs.service" "cat $(printf %q "$docs_unit")"
			elif install -o root -g root -m 0644 "$docs_unit_tmp" "$docs_unit" && systemctl daemon-reload && systemctl enable --now o11y-workshop-docs.service; then
				step_ok "installed and started localhost-only documentation service on port $DOCS_PORT"
			else
				step_fail "could not install/start documentation service" "Check DOCS_PORT, WORKSHOP_USER, systemd unit syntax, and docs root." "systemctl status o11y-workshop-docs.service --no-pager" "journalctl -u o11y-workshop-docs.service -b --no-pager | tail -n 15" "ls -ld $(printf %q "$DOCS_ROOT")"
			fi
		fi
	fi
	if command -v curl >/dev/null 2>&1; then
		landing_page="$(find "$DOCS_ROOT" -type f \( -name index.html -o -name index.htm \) -print -quit 2>/dev/null || true)"
		if [[ -z "$landing_page" ]]; then
			step_fail "no mirrored documentation landing page was found" "Restore the per-track content/docs trees from the repository ZIP." "find $(printf %q "$DOCS_ROOT") -type f -name index.html -o -name index.htm" "ls -la $(printf %q "$DOCS_ROOT")"
		elif relative_page="${landing_page#"$DOCS_ROOT/"}" && curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$DOCS_PORT/$relative_page" >/dev/null; then
			step_ok "local docs server returned a mirrored landing page on port $DOCS_PORT: $relative_page"
		else
			step_fail "local documentation server did not serve the mirrored landing page" "Start o11y-workshop-docs.service and verify DOCS_PORT and content/docs." "systemctl status o11y-workshop-docs.service --no-pager" "curl -v --connect-timeout 3 http://127.0.0.1:$DOCS_PORT/$(printf %q "$relative_page")" "journalctl -u o11y-workshop-docs.service -b --no-pager | tail -n 15"
		fi
	else
		step_fail "curl is unavailable to verify local docs" "Install curl with script 20." "command -v curl" "rpm -q curl"
	fi
	for program in run-workshop.sh stop-workshop.sh; do
		if [[ -x "$REPO_ROOT/bin/$program" ]]; then
			if [[ -L "/usr/local/bin/$program" && "$(readlink -f "/usr/local/bin/$program")" == "$REPO_ROOT/bin/$program" ]]; then
				step_ok "$program is already PATH-visible"
			elif [[ -e "/usr/local/bin/$program" || -L "/usr/local/bin/$program" ]]; then
				step_fail "refusing to replace an existing non-managed PATH command: /usr/local/bin/$program" "Inspect and move the existing path deliberately before retrying." "ls -l $(printf %q "/usr/local/bin/$program")" "readlink -f $(printf %q "/usr/local/bin/$program")"
			elif run "ln -s $(printf %q "$REPO_ROOT/bin/$program") /usr/local/bin/$program"; then
				step_ok "installed $program in /usr/local/bin"
			else
				step_fail "could not install $program" "Check /usr/local/bin permissions and repository ownership." "ls -ld /usr/local/bin" "ls -l $(printf %q "$REPO_ROOT/bin/$program")"
			fi
		else
			step_fail "dispatcher is missing or not executable: $program" "Restore bin/$program from the repository." "ls -l $(printf %q "$REPO_ROOT/bin/$program")" "find $(printf %q "$REPO_ROOT/bin") -maxdepth 1 -type f -print"
		fi
	done

	start_file="/home/$WORKSHOP_USER/START-HERE.md"
	start_tmp=$(mktemp "${TMPDIR:-/tmp}/START-HERE.XXXXXX") || start_tmp=''
	if [[ -z "$start_tmp" ]]; then
		step_fail "could not create START-HERE.md temporary file" "Check temporary disk space and the engineer home." "df -hP /tmp" "getent passwd $(printf %q "$WORKSHOP_USER")"
	else
		track_names="$(python3 -c 'import json,sys; print(", ".join(json.load(open(sys.argv[1],encoding="utf-8")).keys()))' "$REPO_ROOT/content/extracted/curated.json")"
		cat > "$start_tmp" <<EOF
# Observability Workshop: Start Here

Local mirrored documentation: http://localhost:$DOCS_PORT/

Curated workshop tracks: $track_names.
Run run-workshop.sh without arguments to list tracks and curated examples.
Run one example at a time with run-workshop.sh <track> <entry-name> and stop it with stop-workshop.sh <track> <entry-name>.
The Docker-compatible and Podman commands use the rootful Podman image store; k3s containerd is a separate store.
Images are preloaded before hand-off, so no attendee-time network access is required.
Never run system-wide or image prune commands; ask the operator if an image is missing.
Rancher-only installation instructions are not executed, but documented Docker commands use the local Podman compatibility command.
The OpenTelemetry Kubernetes manifest path runs on k3s.
Manual artifact recovery uses $MANUAL_FETCH_DIR and content/vendor/MANUAL-FETCH.md.
EOF
		if [[ -e "$start_file" ]] && ! cmp -s "$start_tmp" "$start_file"; then
			step_fail "refusing to replace an existing custom START-HERE.md" "Review $start_file and preserve or move it deliberately before rerunning." "ls -l $(printf %q "$start_file")" "sed -n '1,80p' $(printf %q "$start_file")"
		elif install -o "$WORKSHOP_USER" -g "$WORKSHOP_USER" -m 0644 "$start_tmp" "$start_file"; then
			step_ok "installed operator START-HERE.md"
		else
			step_fail "could not install START-HERE.md" "Check WORKSHOP_USER and the home directory ownership." "id $(printf %q "$WORKSHOP_USER")" "ls -ld /home/$(printf %q "$WORKSHOP_USER")"
		fi
		rm -f -- "$start_tmp"
	fi

	firefox_bin="$(command -v firefox 2>/dev/null || true)"
	firefox_real=''
	if [[ -n "$firefox_bin" ]]; then firefox_real="$(readlink -f "$firefox_bin" 2>/dev/null || true)"; fi
	if [[ -n "$firefox_real" && -x "$firefox_real" && -d "$(dirname "$firefox_real")" ]]; then
		policy_dir="$(dirname "$firefox_real")/distribution"
		policy_file="$policy_dir/policies.json"
		if [[ -d "$policy_dir" || -w "$(dirname "$firefox_real")" ]]; then
			policy_tmp=$(mktemp "${TMPDIR:-/tmp}/firefox-policies.XXXXXX") || policy_tmp=''
			if [[ -z "$policy_tmp" ]]; then
				step_fail "could not create Firefox policy temporary file" "Check temporary disk space." "df -hP /tmp" "ls -ld $(printf %q "$(dirname "$firefox_real")")"
			else
				python3 - "$policy_file" "$policy_tmp" "$DOCS_PORT" <<'PY'
import json
import os
import sys
source, destination, port = sys.argv[1:]
if os.path.isfile(source):
    with open(source, encoding="utf-8") as stream:
        data=json.load(stream)
else:
    data={"policies":{}}
policies=data.setdefault("policies",{})
bookmarks=policies.setdefault("Bookmarks",[])
item={"Title":"Observability Workshop","URL":f"http://localhost:{port}/","Placement":"toolbar"}
if item not in bookmarks:
    bookmarks.append(item)
with open(destination,"w",encoding="utf-8") as stream:
    json.dump(data,stream,indent=2)
    stream.write("\n")
PY
				if python3 -m json.tool "$policy_tmp" >/dev/null && install -D -o root -g root -m 0644 "$policy_tmp" "$policy_file"; then
					step_ok "added the local workshop Firefox bookmark using a checked distribution path"
				else
					step_fail "could not write valid Firefox bookmark policy" "Check Firefox policy directory permissions and existing policies.json syntax." "python3 -m json.tool $(printf %q "$policy_file")" "ls -ld $(printf %q "$policy_dir")"
				fi
				rm -f -- "$policy_tmp"
			fi
		else
			step_skip "Firefox distribution policy path is absent and not writable" "$policy_dir"
		fi
	else
		step_skip "Firefox binary/install path could not be verified; bookmark policy was not created" "command -v firefox; readlink -f the resolved binary"
	fi

	if command -v gnome-shell >/dev/null 2>&1 && command -v xdg-user-dir >/dev/null 2>&1; then
		desktop_dir="$(runuser -u "$WORKSHOP_USER" -- xdg-user-dir DESKTOP 2>/dev/null || true)"
		if [[ -n "$desktop_dir" && -d "$desktop_dir" ]]; then
			desktop_file="$desktop_dir/Observability-Workshop.desktop"
			if [[ -e "$desktop_file" ]]; then
				step_skip "existing desktop link was left unchanged" "$desktop_file"
			elif [[ "$DRY_RUN" == true ]]; then
				step_skip "GNOME desktop shortcut creation was previewed" "$desktop_file"
			else
				desktop_tmp=$(mktemp "${TMPDIR:-/tmp}/workshop-desktop.XXXXXX") || desktop_tmp=''
				if [[ -z "$desktop_tmp" ]]; then
					step_fail "could not create desktop shortcut temporary file" "Check temporary disk space." "df -hP /tmp" "ls -ld $(printf %q "$desktop_dir")"
				else
					printf '[Desktop Entry]\nType=Link\nName=Observability Workshop\nURL=http://localhost:%s/\nIcon=firefox\n' "$DOCS_PORT" > "$desktop_tmp"
					if install -o "$WORKSHOP_USER" -g "$WORKSHOP_USER" -m 0644 "$desktop_tmp" "$desktop_file"; then step_ok "installed Firefox desktop link for the detected GNOME desktop"; else step_fail "could not install desktop link" "Check the detected desktop directory ownership." "ls -ld $(printf %q "$desktop_dir")" "id $(printf %q "$WORKSHOP_USER")"; fi
					rm -f -- "$desktop_tmp"
				fi
			fi
		else
			step_skip "engineer desktop directory is absent; no shortcut was added" "xdg-user-dir DESKTOP returned ${desktop_dir:-empty}"
		fi
	else
		step_skip "GNOME shell or xdg-user-dir is unavailable; no desktop shortcut was added" "Firefox bookmark remains available through its policy path if configured"
	fi
fi

end_report "Review the local docs URL, then run run-workshop.sh without arguments to list curated examples."
((FAIL_COUNT == 0))
