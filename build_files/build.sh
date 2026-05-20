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

### Enable required system units

systemctl enable sssd
systemctl enable oddjobd
systemctl enable podman.socket

### Fix bootc-image-builder SELinux relabeling compatibility
#
# The CentOS-based bootc-image-builder ships setfiles with PCRE2 10.46 while
# Fedora/Bazzite compiles file_contexts.bin with PCRE2 10.47. The version
# mismatch puts setfiles into a degraded mode that cannot apply a
# security.selinux xattr to any file that also carries a security.capability
# xattr, returning exit 255 and failing the entire disk image build.
#
# oidc_child carries cap_dac_override file capabilities for OIDC/OAuth2
# authentication flows. Standard Kerberos/LDAP FreeIPA auth does not use
# oidc_child at all. Removing its file capabilities allows setfiles to label
# it normally; SELinux policy governs its access control in the deployed image.
setcap -r /usr/libexec/sssd/oidc_child
