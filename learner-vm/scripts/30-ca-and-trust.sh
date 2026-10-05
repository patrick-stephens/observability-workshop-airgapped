#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="30-ca-and-trust"
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
	step_fail "unknown argument: $argument" "Run learner-vm/scripts/30-ca-and-trust.sh [--dry-run]." "printf '%s\\n' --dry-run"
done
if ((EUID != 0)) && [[ "$DRY_RUN" == false ]]; then
	step_fail "CA installation requires root" "Run sudo learner-vm/scripts/30-ca-and-trust.sh after script 20." "id -u"
	end_report "rerun with sudo"
	exit 1
elif ((EUID != 0)); then
	step_skip "root is required for the real trust-store update; dry-run continues" "rerun with sudo on the learner VM"
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "CA certificate file is target-side and was not inspected during dry-run" "$CA_CERT_SOURCE"
elif [[ ! -s "$CA_CERT_SOURCE" ]]; then
	step_fail "CA_CERT_SOURCE is missing or empty" "Place the base-image CA at CA_CERT_SOURCE in learner-vm/lab-vm.conf." "ls -l $(printf '%q' "$CA_CERT_SOURCE")" "find /etc/pki/ca-trust/source/anchors -maxdepth 1 -type f -print"
	end_report "stage the configured CA certificate before configuring registry access"
	exit 1
	elif ! command -v openssl >/dev/null 2>&1; then
	step_fail "openssl is unavailable" "Install openssl from the configured RHEL repositories or ISO." "command -v openssl" "rpm -q openssl"
	end_report "install openssl before validating CA trust"
	exit 1
	elif ! openssl x509 -in "$CA_CERT_SOURCE" -noout -subject >/dev/null 2>&1; then
	step_fail "CA_CERT_SOURCE is not a readable X.509 certificate" "Provide the correct CA certificate at $CA_CERT_SOURCE." "file $(printf '%q' "$CA_CERT_SOURCE")" "openssl x509 -in $(printf '%q' "$CA_CERT_SOURCE") -noout -subject"
	end_report "correct CA_CERT_SOURCE before continuing"
	exit 1
fi

anchor_dir='/etc/pki/ca-trust/source/anchors'
anchor_file="$anchor_dir/$(basename "$CA_CERT_SOURCE")"
if [[ -s "$anchor_file" ]] && cmp -s "$CA_CERT_SOURCE" "$anchor_file"; then
	step_ok "configured CA is already present in the OS trust anchors"
elif [[ "$DRY_RUN" == true ]]; then
	run "install -D -o root -g root -m 0644 $(printf %q "$CA_CERT_SOURCE") $(printf %q "$anchor_file")"
	step_skip "OS trust-anchor copy was previewed" "$anchor_file"
elif run "install -D -o root -g root -m 0644 $(printf %q "$CA_CERT_SOURCE") $(printf %q "$anchor_file")"; then
	step_ok "installed CA certificate in the OS trust anchors"
else
	step_fail "could not install the OS trust anchor" "Check CA_CERT_SOURCE and write access to $anchor_dir." "ls -ld $(printf %q "$anchor_dir")" "ls -l $(printf %q "$CA_CERT_SOURCE")"
fi

if [[ "$DRY_RUN" == true ]]; then
	run 'update-ca-trust extract'
	step_skip "update-ca-trust was previewed" "the real run refreshes the operating-system CA bundle"
elif run 'update-ca-trust extract'; then
	step_ok "updated the operating-system CA bundle"
	ca_subject="$(openssl x509 -in "$CA_CERT_SOURCE" -noout -subject 2>/dev/null | sed 's/^subject=//')"
	bundle_subjects="$(openssl crl2pkcs7 -nocrl -certfile /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null || true)"
	if [[ -n "$ca_subject" ]] && grep -Fq -- "$ca_subject" <<< "$bundle_subjects"; then
		step_ok "OS CA bundle contains the configured Artifactory CA subject"
	else
		step_fail "configured CA subject is absent from the OS trust bundle" "Confirm the correct CA_CERT_SOURCE, reinstall it under /etc/pki/ca-trust/source/anchors, and rerun update-ca-trust." "openssl x509 -in $(printf '%q' "$CA_CERT_SOURCE") -noout -subject" "grep -F $(printf '%q' "$ca_subject") /etc/pki/tls/certs/ca-bundle.crt"
	fi
else
	step_fail "update-ca-trust failed" "Verify the installed CA certificate and rerun update-ca-trust." "update-ca-trust check" "ls -l $(printf '%q' "$anchor_file")"
fi

registry_ca="/etc/containers/certs.d/$REG_HOST/ca.crt"
if [[ -s "$registry_ca" ]] && cmp -s "$CA_CERT_SOURCE" "$registry_ca"; then
	step_ok "registry-specific CA is already installed for $REG_HOST"
elif [[ "$DRY_RUN" == true ]]; then
	run "install -D -o root -g root -m 0644 $(printf %q "$CA_CERT_SOURCE") $(printf %q "$registry_ca")"
	step_skip "Podman/Skopeo registry CA copy was previewed" "$registry_ca"
elif run "install -D -o root -g root -m 0644 $(printf %q "$CA_CERT_SOURCE") $(printf %q "$registry_ca")"; then
	step_ok "installed registry-specific CA for $REG_HOST"
else
	step_fail "could not install registry-specific CA" "Check $CA_CERT_SOURCE and permissions under /etc/containers/certs.d/$REG_HOST." "ls -ld /etc/containers/certs.d /etc/containers/certs.d/$REG_HOST" "openssl x509 -in $(printf %q "$CA_CERT_SOURCE") -noout -subject"
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "Artifactory TLS probe was not executed during dry-run" "real execution accepts only HTTP 200 or 302 from https://$ART_HOST/"
elif ! command -v curl >/dev/null 2>&1; then
	step_fail "curl is unavailable for the Artifactory TLS check" "Install curl from the configured repositories or ISO." "command -v curl" "rpm -q curl"
else
	status='000'
	if status="$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' "https://${ART_HOST}/" 2>/dev/null)"; then :; fi
	case "$status" in
		200|302) step_ok "Artifactory TLS verified without insecure options: HTTP $status" ;;
		401) step_fail "Artifactory root returned HTTP 401" "Repair anonymous Artifactory access; do not add credentials to the learner VM." "getent hosts $(printf '%q' "$ART_HOST")" "curl -v --connect-timeout 10 --max-time 15 https://$(printf '%q' "$ART_HOST")/" "printf '' | openssl s_client -connect $(printf '%q' "$REG_HOST"):443 -servername $(printf '%q' "$REG_HOST")" ;;
		*) step_fail "Artifactory HTTPS probe returned HTTP $status" "Check ART_HOST, its DNS/IP mapping, and CA_CERT_SOURCE before script 40." "getent hosts $(printf '%q' "$ART_HOST")" "curl -v --connect-timeout 10 --max-time 15 https://$(printf '%q' "$ART_HOST")/" "printf '' | openssl s_client -connect $(printf '%q' "$REG_HOST"):443 -servername $(printf '%q' "$REG_HOST")" ;;
	esac
fi

end_report "Review the CA and TLS results, then continue to learner-vm/scripts/40-podman-config.sh."
((FAIL_COUNT == 0))