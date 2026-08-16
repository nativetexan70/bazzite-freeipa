# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

A custom [bootc](https://github.com/bootc-dev/bootc) OCI image layered on top of `ghcr.io/ublue-os/bazzite-gnome:stable` (a Universal Blue image), adding FreeIPA client support. Images are built via GitHub Actions and published to `ghcr.io/personalcyber/bazzite-freeipa`. The image is designed so that a FreeIPA domain join survives `bootc` updates via bootc's three-way `/etc` merge.

## Common Commands

All local build tasks use [just](https://just.systems/):

```bash
just build                  # Build container image with podman
just lint                   # Run shellcheck on all .sh files
just format                 # Run shfmt on all .sh files
just check                  # Validate Justfile syntax
just fix                    # Auto-fix Justfile syntax
just build-qcow2            # Build QCOW2 VM image via bootc-image-builder
just build-iso-gnome        # Build GNOME installer ISO
just build-iso-kde          # Build KDE installer ISO
just run-vm-qcow2           # Run QCOW2 VM (builds if needed, opens browser at port 8006+)
just run-vm-iso-gnome       # Run GNOME ISO in a VM
just run-vm-iso-kde         # Run KDE ISO in a VM
just spawn-vm               # Run VM using systemd-vmspawn
just clean                  # Remove build artifacts from output/
```

## Architecture

### Build Pipeline

1. **`Containerfile`** — Two-stage build: a scratch `ctx` stage copies `build_files/` (making scripts available without embedding them in the final layer). The base image is `ghcr.io/ublue-os/bazzite-gnome:stable`. After the main `RUN` step, a `COPY` instruction ships an empty `/etc/hostname` (see Hostname Preservation below). Ends with `bootc container lint`.
2. **`build_files/build.sh`** — Executed during the container build (`RUN /ctx/build.sh`). Installs `freeipa-client`, `oddjob`, `oddjob-mkhomedir`, `powertop`; creates `/etc/ipa/` and `/etc/sssd/conf.d/` directory skeletons; pre-creates `/var/lib/sss/` and `/var/log/sssd/`; applies the Tiger Lake SOF/SoundWire audio fix; ships `trayscale-flatpak-install.service` (installs the Trayscale Flatpak app on first boot) and `powertop-autotune.service` (runs `powertop --auto-tune` every boot); enables `sssd`, `oddjobd`, `podman.socket`, `trayscale-flatpak-install.service`, and `powertop-autotune.service`. Runs with `set -ouex pipefail`.
3. **`build_files/hostname`** — Empty file copied to `/etc/hostname` in the image via `COPY`. Must remain empty.
4. **GitHub Actions (`build.yml`)** — Triggers on push to `main`, PRs, and daily schedule. Builds with `buildah`, pushes to GHCR only on non-PR pushes to the default branch, signs with Cosign using `SIGNING_SECRET`.
5. **GitHub Actions (`build-disk.yml`)** — Manually triggered workflow producing `qcow2`, `anaconda-iso-gnome`, and `anaconda-iso-kde` disk images from the published OCI image using `bootc-image-builder`. Can optionally upload to S3.

### Key Files to Modify

- **Add packages or system configuration**: Edit `build_files/build.sh`
- **Change base image**: Edit the `FROM` line in `Containerfile`
- **Change disk image layout**: Edit `disk_config/disk.toml` (qcow2/raw) or `disk_config/iso-gnome.toml` / `disk_config/iso-kde.toml` (ISOs)
- **Change CI behavior or image metadata**: Edit `.github/workflows/build.yml`

### FreeIPA Join Persistence

bootc performs a three-way `/etc` merge on update: it diffs old-image `/etc` vs new-image `/etc` and applies that delta to local `/etc`. Files written by `ipa-client-install` (`sssd.conf`, `krb5.conf`, `/etc/ipa/default.conf`, etc.) are never shipped in this image, so bootc treats them as local additions and never overwrites them. The `/etc/ipa/` and `/etc/sssd/conf.d/` directories are present in the image as empty skeletons — no config content is shipped inside them.

### Intel Tiger Lake Audio Fix

Tiger Lake (TGL) platforms can fail to bring up audio at all, showing only a "Dummy Output" sink. This turned out to be two independent problems, and the fix that matters depends on which one applies to the hardware.

**Lesson learned — don't force `dsp_driver=1` blindly.** An earlier revision of this image forced the legacy `snd_hda_intel` driver via `options snd-intel-dspcfg dsp_driver=1` in a modprobe.d file, based on a workaround documented for HD-Audio Tiger Lake laptops. That override is actively harmful on Tiger Lake **Chromebooks** (e.g. the Volteer/Lindar family): those boards drive their speakers/headset entirely over **SoundWire** — a Realtek RT5682 codec plus RT1011 amps — through Intel's SOF DSP, with no HD-Audio codec involved. `dsp_driver` values are `0=auto, 1=legacy, 2=SST, 3=SOF, 4=AVS`; forcing `1` means SOF never claims the controller, so the SoundWire codec/amps are never brought up — no ASoC sound card is registered at all (`/proc/asound/cards` stays empty), and PipeWire falls back to a fake sink — the exact symptom the override was meant to cure. Auto (`0`, the kernel default) is correct for these boards, so `build.sh` no longer ships any `dsp_driver` override — the fix is to leave it alone, not to force a different value.

**A working sound card is not the same as working audio.** Even once SOF registers a real card (confirmed via `/proc/asound/cards`, `aplay -l`, `speaker-test`), PipeWire/WirePlumber can still show only "Dummy Output". WirePlumber imports ALSA cards through the ALSA Use Case Manager (UCM); a card with no UCM profile only gets a routeless "stereo fallback" node. Fedora's `alsa-ucm-conf` package doesn't carry profiles for several Chromebook SOF boards, including `sof-rt5682` (the card name for Tiger Lake Chromebooks with an RT5682 headset codec and RT1011 speaker amps). `build.sh` fetches a pinned commit of the actively maintained [WeirdTreeThing/alsa-ucm-conf-cros](https://github.com/WeirdTreeThing/alsa-ucm-conf-cros) project — which packages ChromeOS's own topology for mainline Linux — and overlays its `ucm2/` tree onto `/usr/share/alsa/ucm2` (its `overrides/` directory replaces upstream configs for the older AVS driver, doesn't apply to any SOF board, and is intentionally not installed).

### Preinstalled Flatpak Apps

[Trayscale](https://github.com/DeedleFake/trayscale) (Flathub app ID `dev.deedles.Trayscale`), a GTK4 tray GUI for `tailscale`, is installed system-wide via Flatpak. Rather than running `flatpak install` at build time — which would land under `/var/lib/flatpak`, and bootc/ostree do not carry arbitrary `/var` content from the container image into a deployed system beyond a genuinely first-ever install — `trayscale-flatpak-install.service` (enabled by default) adds the `flathub` remote if missing and installs the app on first boot, guarded by `ConditionPathExists` so it's a no-op on every subsequent boot.

### Hostname Preservation

The upstream Bazzite image ships `/etc/hostname` with a default value. To prevent bootc from ever merging that default over a locally configured hostname (which would break Kerberos), this image ships `/etc/hostname` as an empty file via a `COPY` instruction. `RUN rm -f /etc/hostname` does not work because the OCI build runtime bind-mounts `/etc/hostname` into every `RUN` container, causing "Device or resource busy". `COPY` writes directly to the image layer filesystem outside of a running container and is not subject to the bind-mount.

### Image Signing

The CI pipeline signs images with [Cosign](https://github.com/sigstore/cosign). Requires a `SIGNING_SECRET` repository secret containing the private key (generated with `COSIGN_PASSWORD="" cosign generate-key-pair`). The public key `cosign.pub` is committed to the repo. Never commit `cosign.key`.

### Justfile Environment Variables

Override defaults via environment:
- `IMAGE_NAME` (default: `bazzite-freeipa`) — used as the podman image tag
- `DEFAULT_TAG` (default: `latest`)
- `BIB_IMAGE` — the bootc-image-builder image used for disk builds
