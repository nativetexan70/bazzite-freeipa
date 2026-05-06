# bazzite-freeipa

A custom [bootc](https://github.com/bootc-dev/bootc) image layered on [Bazzite](https://github.com/ublue-os/bazzite) (Universal Blue) that ships `freeipa-client` and all required dependencies pre-installed. The image is built and published automatically to GHCR via GitHub Actions and is designed to preserve an existing FreeIPA domain join across `bootc` updates.

Published image: `ghcr.io/nativetexan70/bazzite-freeipa:latest`

---

# Switching to This Image

## From an Existing Bazzite or Universal Blue System

If you are already running a bootc-based system (Bazzite, Bluefin, Aurora, etc.), switching requires a single command and a reboot. No reinstall is needed.

```bash
sudo bootc switch ghcr.io/nativetexan70/bazzite-freeipa:latest
```

`bootc switch` stages the new image. The switch takes effect on the next reboot.

```bash
systemctl reboot
```

After rebooting, confirm you are on the new image:

```bash
sudo bootc status
```

> [!NOTE]
> If your current system is already joined to a FreeIPA domain, the join state is preserved. See [FreeIPA Join Persistence](#freeipa-join-persistence) below for details on how this works.

## From a Non-bootc Fedora or RPM-based System

A fresh install using an ISO is the recommended path. Download or build an ISO from this repository (see [Building Disk Images](#building-disk-images)) and boot from it. The installer's post-install script automatically switches the new system to `ghcr.io/nativetexan70/bazzite-freeipa:latest`.

---

# Setting Up FreeIPA Client

The `freeipa-client`, `sssd`, `oddjob`, and `oddjob-mkhomedir` packages are pre-installed in this image. After switching or installing, join the machine to your FreeIPA domain using `ipa-client-install`.

## Prerequisites

- Network access to your FreeIPA server (DNS must be resolvable)
- A one-time password or admin credentials for enrollment

## Joining the Domain

```bash
sudo ipa-client-install \
    --domain=your.domain.example \
    --server=ipa.your.domain.example \
    --realm=YOUR.DOMAIN.EXAMPLE \
    --mkhomedir \
    --no-ntp
```

Key flags:
- `--mkhomedir` — creates home directories on first login via `oddjob-mkhomedir`, which is enabled in this image
- `--no-ntp` — recommended if NTP is already managed by another service (e.g., `systemd-timesyncd` or Chrony on your network)
- `--unattended` — add this flag for scripted/automated enrollment together with `--password`

`ipa-client-install` will write and own `/etc/ipa/default.conf`, `/etc/sssd/sssd.conf`, `/etc/krb5.conf`, and related files. These are treated as local files by bootc and will not be overwritten by image updates.

After the join completes, verify that `sssd` is running:

```bash
systemctl status sssd
```

And test that a domain user can be resolved:

```bash
id <domain-username>
```

## Leaving the Domain

To remove the machine from FreeIPA cleanly:

```bash
sudo ipa-client-install --uninstall
```

---

# FreeIPA Join Persistence

This image is specifically designed so that an existing domain join survives `bootc` updates. Here is how it works.

When `bootc` applies an update it performs a **three-way merge** of `/etc`:

1. It diffs the old image's `/etc` against the new image's `/etc`.
2. It applies that delta to your local `/etc`.

Files that exist locally but are **not present in the image** are treated as local additions and are never touched. This image deliberately ships the directory skeletons `/etc/ipa/` and `/etc/sssd/conf.d/` but ships **no config file content** inside them. Every file that `ipa-client-install` writes — `sssd.conf`, `default.conf`, `krb5.conf`, etc. — is therefore a local addition that bootc will never overwrite.

Runtime state (`/var/lib/sss/`, `/var/log/sssd/`) lives under `/var`, which bootc never modifies.

**In practice:** after a `bootc update` and reboot, `sssd` comes back up reading the same config it had before the update, and domain authentication continues without any intervention.

### What Could Break a Join

- Manually editing a file that a future image version also ships (currently none, by design)
- Running `ipa-client-install --uninstall` before updating, then expecting the join to survive

---

# Keeping the Image Updated

`bootc` checks for and stages updates automatically if the `bootc-fetch-apply-updates.timer` systemd unit is enabled. To enable automatic updates:

```bash
sudo systemctl enable --now bootc-fetch-apply-updates.timer
```

Updates are staged in the background and applied on the next reboot. A reboot does **not** happen automatically unless you also configure a reboot schedule.

To trigger a manual update check:

```bash
sudo bootc upgrade
```

---

# Building the Image Locally

Requires [just](https://just.systems/) and [podman](https://podman.io/). Both are available by default on all Universal Blue images.

```bash
just build          # Build the container image
just lint           # Run shellcheck on all shell scripts
just format         # Run shfmt on all shell scripts
just check          # Validate Justfile syntax
just clean          # Remove local build artifacts
```

To build and run a QCOW2 virtual machine locally:

```bash
just build-qcow2    # Build a QCOW2 disk image via bootc-image-builder
just run-vm-qcow2   # Run the QCOW2 image in a VM (opens browser at localhost:8006+)
```

---

# Building Disk Images

The [build-disk.yml](./.github/workflows/build-disk.yml) GitHub Actions workflow builds installable disk images (`qcow2` and `anaconda-iso`) from the published OCI image. Trigger it manually from the Actions tab, selecting `amd64` or `arm64`.

The ISO kickstart is pre-configured to switch a newly installed system to `ghcr.io/nativetexan70/bazzite-freeipa:latest` automatically.

To upload disk images to S3, add the following repository secrets under `Settings` → `Secrets and Variables` → `Actions`:

| Secret | Description |
|---|---|
| `S3_PROVIDER` | Provider name from the [rclone S3 list](https://rclone.org/s3/) |
| `S3_BUCKET_NAME` | Your bucket name |
| `S3_ACCESS_KEY_ID` | Access key for the bucket |
| `S3_SECRET_ACCESS_KEY` | Secret key for the bucket |
| `S3_REGION` | Bucket region (`auto` if unknown) |
| `S3_ENDPOINT` | Provider-specific endpoint URL |

---

# Image Signing

Images pushed to GHCR are signed with [Cosign](https://github.com/sigstore/cosign) using a key stored as the `SIGNING_SECRET` repository secret. The public key is at [`cosign.pub`](./cosign.pub).

To verify an image locally:

```bash
cosign verify --key cosign.pub ghcr.io/nativetexan70/bazzite-freeipa:latest
```

> [!WARNING]
> Never commit `cosign.key` to the repository. Only `cosign.pub` is safe to commit.

---

# Community

- [Universal Blue Forums](https://universal-blue.discourse.group/)
- [Universal Blue Discord](https://discord.gg/WEu6BdFEtp)
- [bootc discussion forums](https://github.com/bootc-dev/bootc/discussions)
