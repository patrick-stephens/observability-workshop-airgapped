# Learner VM Feedback Protocol

The `feedback/` directory stores learner-VM report transcriptions and operator observations as evidence for later review.

Name records `airgap-run-00N.md`, incrementing N for each VM run; never overwrite an existing record.

Transcribe verbatim: paste the complete REPORT BEGIN/END block, put observations outside the block, and do not summarise or replace evidence with prose.
The agent reads these records newest-first before changing any learner-VM script or `00-diagnose`.

Every record includes: date; operator; VM / RHEL version; repository commit SHA; `lab-vm.conf` deviations from defaults; whether `K3S_BINARY_URL` is set (yes/no only, never paste its value); `SCRIPT_VERSION` values run; purpose of the run; and VM-side commands run.
Start new records from [airgap-run-template.md](airgap-run-template.md).

## Interpreting the First Diagnostic

- EXPECTED on a fresh minimal base: SKIPPED or ARROW lines saying packages are not yet installed, network is not yet configured, k3s is not yet installed, or `K3S_BINARY_URL` is unset.
- HTTP 404 for an individual image manifest means the image may be uncached and the first actual pull may warm the mirror; it is informational, not by itself a registry endpoint failure.
- A registry failure is the endpoint itself being unreachable, failing DNS/TLS, or otherwise not responding as configured.
- Missing Skopeo on the minimal base is an expected SKIPPED result; script 20 installs it.
- SELinux enforcing and firewalld active are informational states; retain SELinux enforcing and do not advise disabling it.
- Script 20 owns the documented firewalld decision at provisioning time.
- FAIL lines worth escalating: `$DOCKER_REGISTRY` registry or Artifactory unreachability; the CA absent from the OS trust store; DNF repository failures; ISO mount failures; missing in-repository content; or a checksum mismatch on the manually staged k3s binary.
- Paste the complete REPORT block even when it contains FAIL lines; those failures are the point of the scaffold, not a reason to omit the block.
