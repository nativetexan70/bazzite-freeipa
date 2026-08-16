#!/bin/bash
#
# First-boot Homebrew installer. Run once by homebrew-install.service,
# guarded by that unit's ConditionPathExists so it never runs again once
# /home/linuxbrew/.linuxbrew/bin/brew exists.
#
# This is deferred to first boot rather than run during the image build:
# ostree only seeds /var from the image on a machine's very first
# deployment and leaves an already-provisioned machine's /var alone on
# every later bootc upgrade. Installing the (thousands-of-files) Homebrew
# tree into /var at build time meant CI rebuilt it from scratch on every
# rebuild for no benefit to any already-deployed machine, and even a
# brand-new machine's baked-in copy would be immediately superseded by
# Homebrew's own `brew update` anyway. The linuxbrew user and brew group
# themselves are still created at build time (via systemd-sysusers with a
# pinned UID/GID, see homebrew-sysusers.conf) so /etc/passwd and
# /etc/group ship identically on every image.

set -ouex pipefail

# Homebrew is installed to /home/linuxbrew/.linuxbrew (the standard Linux
# prefix). In a bootc deployment, /home is a symlink to /var/home, which is
# real and present by the time this runs on a deployed system (unlike
# during the container build).
mkdir -p /var/home/linuxbrew
chown linuxbrew:linuxbrew /var/home/linuxbrew
chmod 0755 /var/home/linuxbrew

curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
    -o /tmp/brew-install.sh
# runuser/su both invoke PAM; setpriv drops to the target UID/GID without
# PAM, which also keeps this consistent with the container-build-time
# approach this replaced.
setpriv --reuid=linuxbrew --regid=linuxbrew --init-groups \
    env HOME=/home/linuxbrew USER=linuxbrew NONINTERACTIVE=1 \
    bash /tmp/brew-install.sh
rm -f /tmp/brew-install.sh

# The 'brew' group grants write access to the installation. Local users and
# FreeIPA domain users added to this group can run 'brew install'. Users not
# in the group can still run any package that is already installed.
chgrp -R brew /home/linuxbrew/.linuxbrew
chmod -R g+rwX /home/linuxbrew/.linuxbrew
find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} +
