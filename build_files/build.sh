#!/bin/bash

set -ouex pipefail

### Install packages

# freeipa-client pulls in sssd, krb5-workstation, certmonger, and other
# required dependencies automatically.
dnf5 install -y \
    freeipa-client \
    oddjob \
    oddjob-mkhomedir \
    powertop

### Preserve FreeIPA join state across bootc updates
#
# bootc performs a three-way /etc merge on update: it diffs old-image /etc
# vs new-image /etc and applies that delta to local /etc. Files that
# ipa-client-install creates and that are NOT shipped in this image are
# treated as local additions and are never touched by updates.
#
# Strategy: create the directory skeleton here so the paths exist at first
# boot, but deliberately ship NO config file content. ipa-client-install
# then owns those files entirely, and bootc will never overwrite them.

install -d -m 0755 /etc/ipa
install -d -m 0750 /etc/sssd/conf.d

# sssd's runtime/cache directories under /var are declared via
# systemd-tmpfiles rather than created directly here -- see var-state.conf
# for why (bootc container lint's var-tmpfiles check, and avoiding baking
# content into /var at build time that a real first boot can create itself).
install -Dm644 /ctx/var-state.conf \
    /usr/lib/tmpfiles.d/var-state.conf

### Install Trayscale (Tailscale tray GUI) via Flatpak
#
# Trayscale (https://github.com/DeedleFake/trayscale, Flathub app ID
# dev.deedles.Trayscale) is a small GTK4 tray app wrapping the tailscale
# CLI. It is NOT installed via `flatpak install` here at build time:
# bootc/ostree do NOT carry arbitrary /var content from the container
# image into a deployed system beyond a genuinely first-ever install, so
# anything written under /var/lib/flatpak during this RUN step would only
# exist in this ephemeral build layer and be silently absent after
# `bootc switch` -- the documented, common path onto this image -- onto a
# real (non-fresh-install) system. Baking the app and its runtime into
# /usr and reseeding it via tmpfiles.d isn't a good fit either: a Flatpak
# app plus its runtime is a large, complex OSTree-like repo layout, and
# copying it into the image would meaningfully bloat every deployment
# even for hosts that never use it.
#
# Instead, ship a oneshot systemd service that installs it from Flathub on
# first boot (guarded by a ConditionPathExists so it only ever runs once
# the app isn't already present) and enable it below. This mirrors how
# FreeIPA join is also a runtime, not build-time, action in this image.

install -m 0644 /ctx/trayscale-flatpak-install.service \
    /usr/lib/systemd/system/trayscale-flatpak-install.service

### Power-saving tuning via powertop --auto-tune
#
# powertop --auto-tune applies its recommended power-saving settings
# (runtime PM for PCI/USB devices, disk/audio power management, etc.)
# without the interactive UI. It only touches runtime device/kernel state
# under /sys and /proc, not /etc, so there's nothing for bootc's three-way
# /etc merge to preserve here -- the service just needs to re-run on every
# boot, since none of that tuning survives a reboot on its own.

cat > /usr/lib/systemd/system/powertop-autotune.service << 'EOF'
[Unit]
Description=Powertop auto-tune power-saving settings
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/powertop --auto-tune

[Install]
WantedBy=multi-user.target
EOF

### Enable required system units

systemctl enable sssd
systemctl enable oddjobd
systemctl enable podman.socket
systemctl enable trayscale-flatpak-install.service
systemctl enable powertop-autotune.service

### Fix bootc-image-builder ISO manifest generation compatibility
#
# Repos inherited from the Bazzite base image (e.g. terra-mesa) reference
# GPG keys via local file:// paths in /etc/pki/rpm-gpg/. BIB's anaconda-iso
# manifest generation extracts repo configs from the container image and runs
# dnf dependency resolution inside its own container, which has no access to
# those key files. Patching gpgcheck=0 alone is insufficient — dnf also
# enforces repo_gpgcheck (repomd.xml signature verification) and fails with
# "Signing key not found" when the gpgkey reference is absent.
#
# In a bootc image, packages are never updated via dnf; bootc upgrade pulls
# cosign-verified OCI images instead. These repos serve no purpose in the
# deployed system. Truncate any repo file that carries a local file:// gpgkey
# reference so BIB's manifest generation can proceed without error.
#
# Each directory is searched separately so find exits 0 when the directory
# exists, avoiding a pipefail abort if one of the directories is absent.
for _repo_dir in /etc/yum.repos.d /usr/lib/yum.repos.d; do
    [[ -d "$_repo_dir" ]] || continue
    find "$_repo_dir" -name '*.repo' | while IFS= read -r _repo_file; do
        grep -ql 'gpgkey=file://' "$_repo_file" 2>/dev/null || continue
        # Remove local file:// gpgkey lines and disable signature checking.
        # BIB's depsolve runs inside its own container and cannot access
        # file:// paths from the target image. In a bootc image, packages
        # are never updated via dnf; security comes from cosign-verified
        # OCI image pulls, so disabling repo GPG checks is safe here.
        sed -i \
            -e '/^gpgkey=file:/d' \
            -e 's/^gpgcheck=.*/gpgcheck=0/' \
            -e 's/^repo_gpgcheck=.*/repo_gpgcheck=0/' \
            "$_repo_file"
        grep -q '^repo_gpgcheck=' "$_repo_file" || \
            sed -i '/^\[/a repo_gpgcheck=0' "$_repo_file"
        grep -q '^gpgcheck=' "$_repo_file" || \
            sed -i '/^\[/a gpgcheck=0' "$_repo_file"
    done
done
unset _repo_dir _repo_file

### Set up Homebrew for all users (including FreeIPA domain users)
#
# Homebrew is installed to /home/linuxbrew/.linuxbrew (the standard Linux
# prefix). In a bootc deployment, /home is a symlink to /var/home.
#
# The account is created here, at build time, so /etc/passwd/group ship
# with it on every image. The actual Homebrew installation, though, is
# deferred to a first-boot systemd unit (homebrew-install.service) instead
# of running here: ostree only seeds /var from the image on a machine's
# very first deployment, and leaves an already-provisioned machine's /var
# alone on every later bootc upgrade. Installing the (thousands of files)
# Homebrew tree into /var at build time meant CI rebuilt it from scratch
# every day for no benefit to any already-deployed machine, and even a
# brand-new machine's baked-in copy is immediately superseded by
# Homebrew's own `brew update` anyway. See homebrew-install.sh/.service
# for the actual install logic.
#
# The 'brew' group grants write access to the installation. Local users and
# FreeIPA domain users added to this group can run 'brew install'. Users not
# in the group can still run any package that is already installed.
#
# The linuxbrew user/brew group are declared via systemd-sysusers rather
# than useradd/groupadd, with pinned UID/GID (950/951), instead of letting
# useradd/groupadd allocate whatever system ID happens to be free that day.
# bootc container lint flags plain useradd/groupadd here ("sysusers" check)
# for a real reason: /etc/passwd and /etc/group ARE part of bootc's
# three-way /etc merge on upgrade (unlike /var -- see above), so if two
# builds of this image allocate a different UID for the same username (a
# real risk across daily rebuilds, since the free-ID choice depends on
# whatever other system accounts exist in that day's build), the merge
# applies that UID change to already-deployed machines. The on-disk files
# under /var/home/linuxbrew (seeded once, at first install, with the
# numeric UID baked into their inodes) don't get renumbered to match, so
# the account silently stops owning its own files. A fixed UID/GID makes
# every build produce byte-identical passwd/group entries for this
# account, so there's never a diff for the merge to apply.
install -Dm644 /ctx/homebrew-sysusers.conf /usr/lib/sysusers.d/homebrew.conf
systemd-sysusers /usr/lib/sysusers.d/homebrew.conf

install -Dm755 /ctx/homebrew-install.sh \
    /usr/libexec/homebrew-install.sh
install -Dm644 /ctx/homebrew-install.service \
    /usr/lib/systemd/system/homebrew-install.service
systemctl enable homebrew-install.service

cat > /etc/profile.d/brew.sh << 'BREWEOF'
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
BREWEOF
chmod 644 /etc/profile.d/brew.sh

### Configure container image signature verification
#
# Ship the Cosign public key and a container policy so that deployed systems
# can verify this image's signature on every bootc upgrade. Without these
# files the client pulls with ostree-unverified-registry: and skips checking.
#
# After this image is deployed, switch to the signed scheme once with:
#   sudo bootc switch ostree-image-signed:docker://ghcr.io/personalcyber/bazzite-freeipa:latest
# Subsequent upgrades will then enforce signature verification automatically.

install -d -m 0755 /etc/pki/containers
install -m 0644 /ctx/cosign.pub \
    /etc/pki/containers/ghcr.io-personalcyber-bazzite-freeipa.pub

install -d -m 0755 /etc/containers/registries.d
cat > /etc/containers/registries.d/ghcr.io-personalcyber-bazzite-freeipa.yaml << 'EOF'
docker:
  ghcr.io/personalcyber/bazzite-freeipa:
    use-sigstore-attachments: true
EOF

# Patch the existing policy.json (inherited from the base image) rather than
# replacing it, to preserve verification rules for the base image itself.
jq '.transports.docker["ghcr.io/personalcyber/bazzite-freeipa"] = [
  {
    "type": "sigstoreSigned",
    "keyPath": "/etc/pki/containers/ghcr.io-personalcyber-bazzite-freeipa.pub",
    "signedIdentity": {"type": "matchRepository"}
  }
]' /etc/containers/policy.json > /tmp/policy.json.new
install -m 0644 /tmp/policy.json.new /etc/containers/policy.json
