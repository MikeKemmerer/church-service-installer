#!/usr/bin/env bash

DESKTOP_LIGHTDM_DROPIN="${DESKTOP_LIGHTDM_DROPIN:-/etc/lightdm/lightdm.conf.d/50-church-service-installer.conf}"
DESKTOP_REBOOT_REQUIRED=0

desktop_packages_installed() {
    local package_name

    for package_name in xorg lightdm openbox falkon vlc alsa-utils x11-xserver-utils xdotool; do
        dpkg-query -W -f='${db:Status-Status}' "$package_name" 2>/dev/null | grep -qx installed || return 1
    done
}

desktop_is_configured_for_user() {
    local kiosk_user="$1"

    [[ -f "$DESKTOP_LIGHTDM_DROPIN" ]] || return 1
    grep -qx "autologin-user=$kiosk_user" "$DESKTOP_LIGHTDM_DROPIN" || return 1
    grep -qx 'user-session=openbox' "$DESKTOP_LIGHTDM_DROPIN"
}

provision_debian_kiosk_desktop() {
    local kiosk_user="$1"
    local lightdm_directory

    [[ "$PLATFORM_ID" == "debian" ]] || return 0
    id "$kiosk_user" >/dev/null 2>&1 || die "Unknown kiosk desktop user: $kiosk_user"
    command -v apt-get >/dev/null 2>&1 || die "APT is required to provision the Debian kiosk desktop."

    if desktop_packages_installed && desktop_is_configured_for_user "$kiosk_user"; then
        info "Debian kiosk desktop is already configured for $kiosk_user."
        return 0
    fi

    state_backup_file "$DESKTOP_LIGHTDM_DROPIN" lightdm-kiosk.conf
    info "Provisioning Xorg, LightDM, Openbox, VLC, Falkon, and ALSA utilities for the kiosk."
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        xorg lightdm openbox falkon vlc alsa-utils x11-xserver-utils xdotool

    lightdm_directory=$(dirname "$DESKTOP_LIGHTDM_DROPIN")
    install -d -m 755 "$lightdm_directory"
    cat > "$DESKTOP_LIGHTDM_DROPIN" <<EOF
# Managed by church-service-installer. Remove this file to disable kiosk autologin.
[Seat:*]
autologin-user=$kiosk_user
autologin-user-timeout=0
user-session=openbox
EOF
    chmod 644 "$DESKTOP_LIGHTDM_DROPIN"
    systemctl set-default graphical.target
    DESKTOP_REBOOT_REQUIRED=1
    state_checkpoint kiosk-desktop-provisioned
    info "Kiosk desktop provisioning is complete. Reboot is required before X11 can start."
}