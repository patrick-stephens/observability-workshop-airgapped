# Learner VM: First Run

This guide describes the RHEL 8.6 learner-VM repository workflow.
The Git repository carries the source; optional approved image archives may also be supplied locally for recovery.
Vendored workshop sources, documentation mirrors, build-context archives, and small k3s support files are already in the repository.
Network-fetched runtime dependencies use Artifactory, with no public-internet fallback.
The operator sets `K3S_BINARY_URL` on the VM before provisioning.

## Repository Workflow

1. On the connected machine, commit and push the reviewed repository changes.
2. Bring the repository onto the airgapped network using the approved internal mirror or repository transfer process.
3. On the learner VM, clone or copy the repository into its working directory.
4. Edit `learner-vm/lab-vm.conf` and set `K3S_BINARY_URL` to the exact HTTPS Artifactory generic-file URL supplied by the administrator.
5. From the repository's `learner-vm/` directory, run `sudo bash scripts/00-diagnose.sh`.
6. Transcribe the complete REPORT block into `feedback/airgap-run-001.md` and wait for review.
7. After approval, run scripts 10 through 80 in numeric order and transcribe each complete REPORT block.
8. When both parts of `80-verify-offline.sh` pass, shut down cleanly and snapshot the VM.

Set the required binary URL on the learner VM; the committed value remains empty.
The optional airgap-images URL also remains empty unless the Artifactory administrator supplies its exact generic-file endpoint.

```bash
K3S_BINARY_URL=""
K3S_AIRGAP_IMAGES_URL=""
```

Do not invent an endpoint or use a public release URL.
The binary SHA-256 authority is the `learner-k3s-binary-amd64` record in `versions.lock`.
`10-preflight.sh` fails with an administrator-directed fix hint if script 45 would need a download while the URL is unset.

## Runtime Recovery

Standalone files use local-first resolution; invalid staged checksums fail without a network fallback, and absent files use their configured Artifactory URL where applicable.
Scripts 60 and 62 prefer catalogued local `image-archive` files before mirror pulls into their separate Podman and k3s stores; see [MANUAL-FETCH.md](../content/vendor/MANUAL-FETCH.md) Section C for save/load commands, small-image vendoring, and approval escalation.
Prefer the derived `docker-registry.${ART_REPO_DOMAIN}` endpoint, or configure the deployment's supported path form, and retain SELinux enforcing while script 20 performs the planned firewalld change.

## Report Protocol

Run the initial diagnostic from the repository's `learner-vm/` directory:

```bash
cd /path/to/repository/learner-vm
sudo bash scripts/00-diagnose.sh
```

Copy every complete REPORT block verbatim into the corresponding feedback record.
Follow each `NEXT` line and stop after any failure until the report has been reviewed.
The connected-machine registry probe returned HTTP 000 because its resolver could not resolve the configured host; this is not learner-network evidence.
The learner VM has not been validated until its own diagnostic and provisioning reports are reviewed.
