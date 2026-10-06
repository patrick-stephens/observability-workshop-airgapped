# Learner VM Feedback Protocol

The `feedback/` directory stores learner-VM report transcriptions and operator observations as evidence for later review.

Name records `airgap-run-00N.md`, incrementing N for each VM run; never overwrite an existing record.

Transcribe verbatim: paste the complete REPORT BEGIN/END block, put observations outside the block, and do not summarise or replace evidence with prose.
The agent reads these records newest-first before changing any learner-VM script or `00-diagnose`.

Every record includes: date; operator; VM / RHEL version; repository commit SHA; `lab-vm.conf` deviations from defaults; whether `K3S_BINARY_URL` is set (yes/no only, never paste its value); `SCRIPT_VERSION` values run; purpose of the run; and VM-side commands run.
Start new records from [airgap-run-template.md](airgap-run-template.md).

## Interpreting the First Diagnostic

The diagnostic now performs real container pulls to classify image availability.
A pull failure is the authoritative failure signal.
A manifest-probe failure alone is informational.

- EXPECTED on a fresh minimal base: SKIPPED or ARROW lines saying packages are not yet installed, network is not yet configured, k3s is not yet installed, or `K3S_BINARY_URL` is unset.
- The default diagnostic is no longer read-only: it runs `podman pull` for each external image, reports timing, and notes local-store warming when the image was previously absent.
- Use `--no-pull-verification` for the previous probe-only mode without pulls or container-store changes; both diagnostic modes retain exit 0, so review the complete report.
- HTTP 404 for an individual manifest means not cached or not visible to this probe; it is informational, not by itself an image or registry failure.
- An actual pull failure is classified as endpoint/DNS/TLS failure, image 404 after mirror resolution, authentication 401/403, or another failure with raw output; successful pulls are OK regardless of manifest probes.
- Missing Skopeo on the minimal base is an expected SKIPPED result; script 20 installs it.
- SELinux enforcing and firewalld active are informational states; retain SELinux enforcing and do not advise disabling it.
- Script 20 owns the documented firewalld decision at provisioning time.
- FAIL lines worth escalating: `$DOCKER_REGISTRY` registry or Artifactory unreachability; the CA absent from the OS trust store; DNF repository failures; ISO mount failures; missing in-repository content; or a checksum mismatch on the manually staged k3s binary.
- Paste the complete REPORT block even when it contains FAIL lines; those failures are the point of the scaffold, not a reason to omit the block.
