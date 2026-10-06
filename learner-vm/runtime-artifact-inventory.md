# Learner VM Runtime Artifact Inventory

## Repository-Resident

`content/vendor/k3s/install.sh`, `k3s-images.txt`, the SELinux RPM, workshop repository and documentation mirrors, runtime build-context archives, `app_pod.yaml`, and `reveal.js-menu` are already present in the repository.
The Artifactory CA is supplied by the base image.

## Standalone Runtime Artifacts

`k3s-binary` is required and catalogued in `artifacts.tsv`; a checksum-verified local file is preferred, otherwise script 45 uses the operator-supplied `K3S_BINARY_URL`.
`k3s-airgap-images` is optional and catalogued in `artifacts.tsv`; it is staged for k3s only when a valid local file or configured `K3S_AIRGAP_IMAGES_URL` resolves.

## Package-Manager Dependencies

Script 20 installs RHEL packages and repository/module metadata with DNF, with its existing attached-ISO package fallback.
These transactions are not standalone file downloads.

## Container Images

Nine optional filesystem-only `image-archive` rows identify individual required external images; no archive files are supplied by the repository.
Scripts 60/62 load only present archives targeting their respective stores before checking required references and pulling any remaining images through the mirror.
Operator-recorded archive checksums are verified when supplied, and embedded manifests/blobs are validated; an unpinned archive is explicitly reported as unverified for its archive SHA.
Only catalogued files under `$MANUAL_FETCH_DIR/images/` are considered; an absent file is SKIPPED and the image proceeds to the mirror pull stage.
Script 60 loads through the Docker wrapper into rootful Podman; script 62 imports any matching Podman-store image into k3s before a CRI pull.

Script 60 pulls external Podman images through the configured registry mirror, and script 62 pulls external Kubernetes images through `k3s crictl` and the k3s mirror configuration.
Locally built Podman images required by k3s use `podman save` followed by `k3s ctr -n k8s.io images import`.

## Network Probes

Scripts 00, 30, and 80 use bounded HTTP/TLS checks for diagnostics or offline verification; they do not download standalone artifacts.
