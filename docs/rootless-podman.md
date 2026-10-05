# Rootless Podman: Future Option

The learner VM currently uses rootful Podman. This is deliberate: the provisioning scripts preload images into the rootful store, the workshop's Docker-compatible command routes to that same store, and the k3s containerd store is managed separately.

Rootless Podman is a possible future design, not a setting to enable during this provisioning run. A rootless runtime has a different image store and per-user configuration. Images loaded as root are not automatically visible to `engineer`, and images pulled or built by `engineer` are not automatically visible to rootful Podman or k3s. A migration therefore needs a separately prepared and verified image preload for the rootless user, revised workshop wrappers, and explicit handling of images that must also be imported into k3s.

Before adopting rootless mode, validate the following on a disposable RHEL 8.6 VM:

- Configure subordinate UID/GID ranges for `engineer` and confirm the `newuidmap` and `newgidmap` helpers are installed.
- Enable and test the user's rootless network stack and storage driver with the intended RHEL kernel and filesystem.
- Build or transfer a rootless image bundle, load it as `engineer`, and verify every curated image reference from that account.
- Update the Docker-compatible command and workshop dispatcher so they consistently address the intended user store without silently elevating to root.
- Export any locally built image that k3s needs, then import it into the `k8s.io` containerd namespace and verify the original manifest reference.
- Check port binding, volume ownership, SELinux labels, systemd user services, and startup after logout/reboot.
- Repeat the complete offline verification with Artifactory blocked and confirm no rootful-only image assumptions remain.

Until that work is reviewed and the transfer package includes the matching rootless image payload, keep the documented rootful configuration. Do not switch runtimes or preload images into a second store as an ad hoc repair.
