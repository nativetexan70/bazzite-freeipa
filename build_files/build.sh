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
# oidc_child is an sssd binary for OIDC/OAuth2 authentication flows.
# It carries a Fedora-specific SELinux file type (sssd_oidc_child_exec_t)
# that does not exist in the CentOS-based bootc-image-builder's SELinux
# policy. Combined with a PCRE2 version mismatch between the BIB's setfiles
# (10.46) and the Bazzite image's file_contexts.bin (10.47), setfiles fails
# with Permission denied when it encounters this binary and aborts the build.
#
# Standard Kerberos/LDAP FreeIPA authentication never invokes oidc_child.
# Remove it so setfiles has nothing to fail on.
rm -f /usr/libexec/sssd/oidc_child
