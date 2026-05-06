# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Base Image
FROM ghcr.io/ublue-os/bazzite-gnome:latest

## Other possible base images include:
# FROM ghcr.io/ublue-os/bazzite-gnome:stable
# FROM ghcr.io/ublue-os/bazzite:latest          (KDE variant)
# FROM ghcr.io/ublue-os/bazzite:stable          (KDE variant, stable channel)
#
# Universal Blue Images: https://github.com/orgs/ublue-os/packages

### [IM]MUTABLE /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## Uncomment the following line if one desires to make /opt immutable and be able to be used
## by the package manager.

# RUN rm /opt && mkdir /opt

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# Remove upstream hostname so bootc never overwrites the locally set hostname.
# This is required for FreeIPA — a hostname change after joining breaks Kerberos.
RUN rm -f /etc/hostname
    
### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
