#!/bin/bash

set -ouex pipefail

### Install packages

# freeipa-client pulls in sssd, krb5-workstation, certmonger, and other
# required dependencies automatically.
dnf5 install -y \
    freeipa-client \
    oddjob \
    oddjob-mkhomedir

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

# Ensure sssd runtime and cache directories survive across updates.
# These already live under /var which is mutable and preserved by bootc.
install -d -m 0711 /var/lib/sss/db
install -d -m 0755 /var/lib/sss/pipes/private
install -d -m 0755 /var/log/sssd

### Fix Intel Tiger Lake audio not being recognized (SOF + SoundWire boards)
#
# An earlier revision of this image shipped a blanket
# `options snd-intel-dspcfg dsp_driver=1` modprobe override, forcing the
# legacy snd_hda_intel driver instead of SOF, based on a workaround
# documented for HD-Audio Tiger Lake laptops:
# https://github.com/tirsasaki/Fix-Intel-Tiger-Lake-Audio-Disable-SOF-on-EndeavourOS-Arch-Linux
#
# That override is actively harmful on Tiger Lake Chromebooks (e.g. the
# Volteer/Lindar family): those boards drive their speakers/headset over
# SoundWire -- a Realtek RT5682 codec plus RT1011 amps -- entirely through
# Intel's SOF DSP, with no HD-Audio codec involved at all. dsp_driver's
# values are 0=auto, 1=legacy, 2=SST, 3=SOF, 4=AVS; forcing 1 (legacy)
# means SOF never claims the controller, so the SoundWire codec/amps are
# never brought up -- no ASoC sound card is registered
# (`/proc/asound/cards` stays empty) and PipeWire falls back to a fake
# "Dummy Output" sink, which is the very symptom the override was meant to
# fix. Auto (0), the kernel default, is correct for these boards, so the
# fix is to leave dsp_driver alone rather than to override it -- hence no
# modprobe.d file is shipped here at all.
#
# Getting a real sound card registered is necessary but not sufficient.
# WirePlumber imports ALSA cards through the ALSA Use Case Manager (UCM):
# if a card has no UCM profile, WirePlumber can only offer a routeless
# "stereo fallback" node, which again looks like "Dummy Output" even
# though `aplay -l`/`speaker-test` work fine against the card directly.
# Fedora's alsa-ucm-conf package doesn't carry profiles for several
# Chromebook SOF boards, including "sof-rt5682" (the card name used by
# Tiger Lake Chromebooks with the RT5682/RT1011 hardware described above).
# The actively maintained WeirdTreeThing/alsa-ucm-conf-cros project
# packages ChromeOS's own topology for these boards as a drop-in overlay
# onto the standard /usr/share/alsa/ucm2 tree: its ucm2/ directory only
# adds card, codec, and platform definitions missing upstream (its
# overrides/ directory replaces upstream configs for the older AVS driver
# instead, doesn't apply to any SOF board, and is intentionally not
# installed here).
# Pinned to a specific commit for build reproducibility.

_ucm_cros_rev="a46dd193ab81ed71c4465453f5297f21e413769f"
curl -fsSL \
    "https://github.com/WeirdTreeThing/alsa-ucm-conf-cros/archive/${_ucm_cros_rev}.tar.gz" \
    -o /tmp/alsa-ucm-conf-cros.tar.gz
tar -xzf /tmp/alsa-ucm-conf-cros.tar.gz -C /tmp
install -d -m 0755 /usr/share/alsa/ucm2
cp -a "/tmp/alsa-ucm-conf-cros-${_ucm_cros_rev}/ucm2/." /usr/share/alsa/ucm2/
rm -rf /tmp/alsa-ucm-conf-cros.tar.gz "/tmp/alsa-ucm-conf-cros-${_ucm_cros_rev}"

### Install Fleet agent (fleetd/orbit)
#
# fleetd is Fleet's cross-platform osquery agent (orbit + osqueryd):
# https://fleetdm.com/docs/using-fleet/orbit
# https://fleetdm.com/docs/configuration/agent-configuration
#
# There is no public dnf/yum repo for it. The only supported way to obtain
# an installable package is `fleetctl package`, which fetches the orbit and
# osqueryd binaries from Fleet's TUF update server (tuf.fleetctl.com) and
# wraps them into an rpm using fpm. Install fpm's build dependencies, grab
# the latest fleetctl release, and build the rpm WITHOUT --fleet-url or
# --enroll-secret so no server address or secret is baked into the image.

dnf5 install -y ruby ruby-devel rubygems rpm-build gcc make redhat-rpm-config

# Fedora's rubygems defaults to a per-user install (under $HOME) even when
# run as root, which would land the gem cache under /root. /root, /usr/local,
# /opt, etc. are all symlinked into /var on this ostree-based image (see the
# /opt note in the Containerfile) and /var isn't populated during this RUN
# step, so nothing can be created under any of them. Pin GEM_HOME under
# /tmp (tmpfs-mounted for this RUN step, see Containerfile) to sidestep
# that, with its bin/ on PATH so `fleetctl package` can find the fpm
# executable it shells out to.
export GEM_HOME=/tmp/fleet-fpm-gems
export PATH="${GEM_HOME}/bin:${PATH}"
mkdir -p "${GEM_HOME}"
gem install --no-document fpm

# fleetctl separately writes a query-history file straight to /root/.goquery
# regardless of $HOME (it resolves the home directory via the OS user
# database, not the environment), so the HOME trick above wouldn't have
# covered it anyway. Fix it at the source instead: create the real backing
# directory for the /root -> /var/roothome symlink.
mkdir -p /var/roothome

_fleet_version="$(curl -fsSL https://api.github.com/repos/fleetdm/fleet/releases/latest |
    jq -r '.tag_name' | sed 's/^fleet-v//')"
_fleet_workdir="$(mktemp -d)"
curl -fsSL \
    "https://github.com/fleetdm/fleet/releases/download/fleet-v${_fleet_version}/fleetctl_v${_fleet_version}_linux_amd64.tar.gz" \
    -o "${_fleet_workdir}/fleetctl.tar.gz"
tar -xzf "${_fleet_workdir}/fleetctl.tar.gz" -C "${_fleet_workdir}"
_fleetctl="${_fleet_workdir}/fleetctl_v${_fleet_version}_linux_amd64/fleetctl"
chmod 0755 "${_fleetctl}"

# fleetctl is invoked directly from ${_fleet_workdir} rather than installed
# to /usr/local/bin: /usr/local is symlinked into /var on this ostree-based
# image (see the GEM_HOME note above) and isn't writable during this RUN
# step.
(cd "${_fleet_workdir}" && "${_fleetctl}" package --type rpm)

# fleet-osquery writes orbit's TUF-managed binary tree under /opt/orbit AND
# a launcher under /usr/local/bin. Both /opt and /usr/local are symlinked
# into /var in this image (see the [IM]MUTABLE /opt note in the
# Containerfile), and /var isn't populated during this RUN step, so
# pre-create both real backing directories just so dnf5 has somewhere to
# write through the symlinks.
mkdir -p /var/opt /var/usrlocal

# fpm-generated postinstall scriptlets (%post/%posttrans) call systemctl in
# ways that fail hard in this scriptless buildah container (no systemd
# PID 1), unlike the tolerant %systemd_post macros freeipa's packages use
# above. Skip scriptlets entirely — we enable orbit.service ourselves
# below regardless of whatever the package's postinstall would have done.
dnf5 install -y --setopt=tsflags=noscripts "${_fleet_workdir}"/fleet-osquery*.rpm

### Seed orbit's /opt and /usr/local files onto real (non-fresh-install) systems
#
# bootc/ostree do NOT carry arbitrary /var content from the container image
# into a deployed system beyond a genuinely first-ever install, and recent
# ostree versions dropped even that: /var is machine-local state, meant to
# be populated via systemd-tmpfiles, not shipped with the image. Since
# /opt and /usr/local both resolve through /var here, the files fleet-
# osquery just installed above only exist in this ephemeral build layer --
# on `bootc switch` (the documented, common path onto this image), rpm's
# database ends up listing /opt/orbit/... and /usr/local/bin/orbit as
# installed while the paths themselves are completely empty.
#
# Work around this by stashing what was just installed under a plain /usr
# path (which IS committed normally -- orbit.service loading correctly
# from /usr/lib/systemd/system proves that), then shipping a tmpfiles.d
# snippet that copies it into place through the symlinks on first boot.
# The 'C' tmpfiles directive only acts if its destination doesn't already
# exist, so this never clobbers orbit's own self-updated binaries later.
mkdir -p /usr/lib/fleetd-seed
cp -a /opt/orbit /usr/lib/fleetd-seed/opt-orbit
cp -a /usr/local/bin/orbit /usr/lib/fleetd-seed/usrlocal-bin-orbit

install -d -m 0755 /usr/lib/tmpfiles.d
cat > /usr/lib/tmpfiles.d/fleetd-seed.conf << 'EOF'
# Populate /opt/orbit and /usr/local/bin/orbit (both resolving into /var)
# from the image-committed seed the first time they're missing. See the
# Fleet agent section of build.sh for why this exists.
C /opt/orbit - - - - /usr/lib/fleetd-seed/opt-orbit
C /usr/local/bin/orbit - - - - /usr/lib/fleetd-seed/usrlocal-bin-orbit
EOF

# Make sure orbit.service doesn't race the tmpfiles seeding above. This is
# almost certainly already guaranteed by systemd's default ordering (both
# sysinit.target, which pulls in systemd-tmpfiles-setup.service, and
# orbit.service's own multi-user.target dependency chain go through
# basic.target), but it's cheap to make explicit.
install -d -m 0755 /usr/lib/systemd/system/orbit.service.d
cat > /usr/lib/systemd/system/orbit.service.d/10-wait-for-seed.conf << 'EOF'
[Unit]
After=systemd-tmpfiles-setup.service
EOF

### Preserve Fleet enrollment state across bootc updates
#
# Same three-way /etc merge concern as FreeIPA above: orbit's runtime
# configuration (Fleet server URL, enrollment secret path, TLS settings)
# lives in /etc/default/orbit, which is read via orbit.service's
# EnvironmentFile directive. Because the package was built without
# --fleet-url/--enroll-secret, that file should already be free of server
# details, but strip it unconditionally so this image never ships any
# content there. An operator enrolls the host later (populating
# /etc/default/orbit and enabling the service); bootc will treat that as a
# local addition and never touch it on subsequent updates.

rm -f /etc/default/orbit

# fleetctl and fpm itself are only needed to produce the package and don't
# need to ship in the final image.
rm -rf "${GEM_HOME}"
rm -rf "${_fleet_workdir}"
# Drop the query-history file fleetctl wrote to /root/.goquery; /var/roothome
# itself stays, since it's the image's real backing directory for the
# pre-existing /root symlink, not something this build step introduced.
rm -rf /var/roothome/.goquery
unset _fleet_version _fleet_workdir _fleetctl GEM_HOME

# ruby/ruby-devel/rubygems/rpm-build are also removed: nothing else in this
# image legitimately needs a system Ruby, and leaving one in place makes
# the Homebrew installer below pick it up instead of its own vendored Ruby
# -- Fedora splits the 'json' stdlib gem out of the base ruby package, so
# Homebrew's install script fails with a LoadError as soon as it tries to
# use the system interpreter. gcc/make/redhat-rpm-config are left alone:
# unlike ruby, they may already be relied on by the base Bazzite image for
# akmods/DKMS builds, and `dnf5 remove` can't tell "installed only for this
# step" apart from "already required by the base image".
dnf5 remove -y ruby ruby-devel rubygems rpm-build || true

### Flatpak inventory for osquery Automatic Table Construction (ATC)
#
# osquery has no native flatpak_packages table (unlike deb_packages /
# rpm_packages), so Fleet's Software inventory can't see installed
# Flatpak apps -- a real gap on an image where Flatpak/Flathub is a
# first-class app delivery mechanism. flatpak-inventory.py rebuilds a
# flatpak_packages table in a plain SQLite database that osquery's ATC
# feature can expose as a normal queryable table; see the
# auto_table_construction snippet in README.md for the Fleet-side config
# needed to actually wire it up. Unlike orbit's /opt payload above, the
# database only ever exists at runtime (the script creates its own
# directory), so there's no build-time /var content requiring tmpfiles.d
# seeding here.

install -d -m 0755 /usr/libexec
install -m 0755 /ctx/flatpak-inventory.py /usr/libexec/flatpak-inventory.py
install -m 0644 /ctx/flatpak-inventory.service \
    /usr/lib/systemd/system/flatpak-inventory.service
install -m 0644 /ctx/flatpak-inventory.timer \
    /usr/lib/systemd/system/flatpak-inventory.timer

### Install Trayscale (Tailscale tray GUI) via Flatpak
#
# Trayscale (https://github.com/DeedleFake/trayscale, Flathub app ID
# dev.deedles.Trayscale) is a small GTK4 tray app wrapping the tailscale
# CLI. It is NOT installed via `flatpak install` here at build time: per
# the "bootc/ostree do NOT carry /var content..." note in the Fleet agent
# section above, anything written under /var/lib/flatpak during this RUN
# step would only exist in this ephemeral build layer and be silently
# absent after `bootc switch` -- the documented, common path onto this
# image -- onto a real (non-fresh-install) system. Baking the app and its
# runtime into /usr and reseeding it via tmpfiles.d (as done for orbit)
# isn't a good fit either: unlike orbit's two files, a Flatpak app plus its
# runtime is a large, complex OSTree-like repo layout, and copying it into
# the image would meaningfully bloat every deployment even for hosts that
# never use it.
#
# Instead, ship a oneshot systemd service that installs it from Flathub on
# first boot (guarded by a ConditionPathExists so it only ever runs once
# the app isn't already present) and enable it below. This mirrors how
# FreeIPA join and Fleet enrollment are also runtime, not build-time,
# actions in this image.

install -m 0644 /ctx/trayscale-flatpak-install.service \
    /usr/lib/systemd/system/trayscale-flatpak-install.service

### Enable required system units

systemctl enable sssd
systemctl enable oddjobd
systemctl enable podman.socket
# orbit will log connection errors until an operator populates
# /etc/default/orbit with a Fleet server URL and enrollment secret, but
# enabling it now means it starts enforcing agent configuration as soon as
# that file is in place, with no extra step required after enrollment.
systemctl enable orbit || true
systemctl enable flatpak-inventory.timer
systemctl enable trayscale-flatpak-install.service

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

### Install Homebrew for all users (including FreeIPA domain users)
#
# Homebrew is installed to /home/linuxbrew/.linuxbrew (the standard Linux
# prefix). In a bootc deployment, /home is a symlink to /var/home. The /var
# tree is seeded from the OCI image on first install and preserved across
# bootc upgrades, so the brew installation is present from first boot and
# survives image updates independently.
#
# The 'brew' group grants write access to the installation. Local users and
# FreeIPA domain users added to this group can run 'brew install'. Users not
# in the group can still run any package that is already installed.

useradd -r -M -d /home/linuxbrew -s /bin/bash linuxbrew
groupadd -r brew
usermod -aG brew linuxbrew

# /home is a symlink to /var/home in Bazzite; create the real directory
# since the symlink target does not exist during the container build.
mkdir -p /var/home/linuxbrew
chown linuxbrew:linuxbrew /var/home/linuxbrew
chmod 0755 /var/home/linuxbrew

curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
    -o /tmp/brew-install.sh
# runuser/su both invoke PAM which fails in a container build environment.
# setpriv drops to the target UID/GID without PAM and is safe in containers.
setpriv --reuid=linuxbrew --regid=linuxbrew --init-groups \
    env HOME=/home/linuxbrew USER=linuxbrew NONINTERACTIVE=1 \
    bash /tmp/brew-install.sh

chgrp -R brew /home/linuxbrew/.linuxbrew
chmod -R g+rwX /home/linuxbrew/.linuxbrew
find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} +

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
