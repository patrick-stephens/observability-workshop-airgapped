# Vendored Runtime Inputs

The repository already contains the workshop sources, documentation mirrors, runtime build-context archives, k3s installer, k3s system-image reference list, SELinux RPM, vendored `app_pod.yaml`, and `reveal.js-menu`.
These inputs need no fetching or staging; their exact paths and integrity records are listed in `content/extracted/vendored-files.txt`, `content/vendor/k3s/SHA256SUMS`, and the runtime catalog.
The configured Artifactory CA is supplied by the learner VM base image.

## k3s Binary at Provisioning

Set `K3S_BINARY_URL` on the learner VM to the exact HTTPS Artifactory generic-file URL provided by the administrator.
The committed setting is empty, and the binary checksum authority remains the `learner-k3s-binary-amd64` record in `versions.lock`.
Script 45 downloads the binary to a temporary file, validates TLS and the response, verifies the locked SHA-256, then installs it before starting k3s.
For same-VM recovery instructions, use [MANUAL-FETCH.md](MANUAL-FETCH.md), Section B.

## Container Images at Provisioning

The Podman and k3s containerd stores are separate.
Script 60 pulls external Podman images through `registries.conf`; script 62 uses `k3s crictl pull` for external Kubernetes images through k3s's `registries.yaml`.
Locally built images needed by k3s use `podman save` followed by `k3s ctr -n k8s.io images import`.
If the Artifactory mirror is unreachable or an image is absent, capture the original reference, endpoint, pull output, DNS and CA/TLS diagnostics, and relevant journals, then contact the Artifactory administrator.
Do not use a public-internet fallback.
Learner-network Artifactory access and image pulls remain unverified until operator reports are reviewed.