# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

A custom [bootc](https://github.com/bootc-dev/bootc) OCI image layered on top of [Bazzite](https://github.com/ublue-os/bazzite) (a Universal Blue image), adding FreeIPA client support. Images are built via GitHub Actions and published to GHCR (`ghcr.io/<owner>/<repo-name>`).

## Common Commands

All local build tasks use [just](https://just.systems/):

```bash
just build                  # Build container image with podman
just lint                   # Run shellcheck on all .sh files
just format                 # Run shfmt on all .sh files
just check                  # Validate Justfile syntax
just fix                    # Auto-fix Justfile syntax
just build-qcow2            # Build QCOW2 VM image via bootc-image-builder
just run-vm-qcow2           # Run QCOW2 VM (builds if needed, opens browser at port 8006+)
just spawn-vm               # Run VM using systemd-vmspawn
just clean                  # Remove build artifacts from output/
```

## Architecture

### Build Pipeline

1. **`Containerfile`** — The image definition. Uses a two-stage pattern: a scratch `ctx` stage copies `build_files/` without including them in the final layer. The base image is `ghcr.io/ublue-os/bazzite:stable`. Ends with `bootc container lint`.
2. **`build_files/build.sh`** — Executed during the container build (`RUN /ctx/build.sh`). This is the primary place to install packages via `dnf5` and enable systemd units. It runs with `set -ouex pipefail`.
3. **GitHub Actions (`build.yml`)** — Triggers on push to `main`, PRs, and daily schedule. Builds with `buildah`, pushes to GHCR only on non-PR pushes to the default branch, and signs with Cosign using `SIGNING_SECRET`.
4. **GitHub Actions (`build-disk.yml`)** — Manually triggered workflow that produces `qcow2` and `anaconda-iso` disk images from the published OCI image using `bootc-image-builder`. Can optionally upload to S3.

### Key Files to Modify

- **Add packages or system configuration**: Edit `build_files/build.sh`
- **Change base image**: Edit the `FROM` line in `Containerfile`
- **Change disk image layout**: Edit `disk_config/disk.toml` (for qcow2/raw) or `disk_config/iso-gnome.toml` / `disk_config/iso-kde.toml` (for ISOs)
- **Change CI behavior or image metadata**: Edit `.github/workflows/build.yml`

### Image Signing

The CI pipeline signs images with [Cosign](https://github.com/sigstore/cosign). Requires a `SIGNING_SECRET` repository secret containing the private key (generated with `COSIGN_PASSWORD="" cosign generate-key-pair`). The public key `cosign.pub` is committed to the repo. Never commit `cosign.key`.

### Justfile Environment Variables

Override defaults via environment:
- `IMAGE_NAME` (default: `image-template`) — used as the podman image tag
- `DEFAULT_TAG` (default: `latest`)
- `BIB_IMAGE` — the bootc-image-builder image used for disk builds
