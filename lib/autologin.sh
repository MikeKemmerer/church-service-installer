#!/usr/bin/env bash

GDM_CONFIG="${GDM_CONFIG:-/etc/gdm3/custom.conf}"
GDM_BACKUP_DIR="${GDM_BACKUP_DIR:-/var/backups/church-service-installer/gdm3}"
AUTOLOGIN_STATE_PATH="${AUTOLOGIN_STATE_PATH:-/etc/church-service-installer/gdm-autologin.state}"

gdm_daemon_value() {
    local setting="$1"
    awk -v setting="$setting" '
        /^\[daemon\][[:space:]]*$/ { in_daemon = 1; next }
        in_daemon && /^\[[^]]+\][[:space:]]*$/ { exit }
        in_daemon && $0 ~ "^[[:space:]]*" setting "[[:space:]]*=" {
            sub("^[[:space:]]*" setting "[[:space:]]*=[[:space:]]*", "")
            print
            exit
        }
    ' "$GDM_CONFIG"
}

write_gdm_autologin_config() {
    local autologin_user="$1"
    local temporary_config

    temporary_config=$(mktemp)
    awk -v autologin_user="$autologin_user" '
        function emit_keys() {
            if (!keys_written) {
                print "WaylandEnable=false"
                print "AutomaticLoginEnable=true"
                print "AutomaticLogin=" autologin_user
                keys_written = 1
            }
        }
        /^\[daemon\][[:space:]]*$/ {
            if (in_daemon) {
                emit_keys()
            }
            in_daemon = 1
            found_daemon = 1
            print
            next
        }
        in_daemon && /^\[[^]]+\][[:space:]]*$/ {
            emit_keys()
            in_daemon = 0
        }
        in_daemon && /^[[:space:]]*#?[[:space:]]*(WaylandEnable|AutomaticLoginEnable|AutomaticLogin)[[:space:]]*=/ {
            next
        }
        { print }
        END {
            if (in_daemon) {
                emit_keys()
            }
            if (!found_daemon) {
                print ""
                print "[daemon]"
                print "WaylandEnable=false"
                print "AutomaticLoginEnable=true"
                print "AutomaticLogin=" autologin_user
            }
        }
    ' "$GDM_CONFIG" > "$temporary_config"
    install -m 644 "$temporary_config" "$GDM_CONFIG"
    rm -f "$temporary_config"
}

remove_gdm_managed_keys() {
    local remove_wayland="$1"
    local temporary_config

    temporary_config=$(mktemp)
    awk -v remove_wayland="$remove_wayland" '
        /^\[daemon\][[:space:]]*$/ { in_daemon = 1; print; next }
        in_daemon && /^\[[^]]+\][[:space:]]*$/ { in_daemon = 0 }
        in_daemon && /^[[:space:]]*#?[[:space:]]*(AutomaticLoginEnable|AutomaticLogin)[[:space:]]*=/ { next }
        in_daemon && remove_wayland == "1" && /^[[:space:]]*#?[[:space:]]*WaylandEnable[[:space:]]*=/ { next }
        { print }
    ' "$GDM_CONFIG" > "$temporary_config"
    install -m 644 "$temporary_config" "$GDM_CONFIG"
    rm -f "$temporary_config"
}

create_kiosk_user() {
    local kiosk_user="$1"
    local password_file="$2"
    local non_interactive="$3"
    local password

    [[ "$kiosk_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid kiosk user: $kiosk_user"
    if id "$kiosk_user" >/dev/null 2>&1; then
        die "Kiosk user already exists: $kiosk_user. Use --autologin-user instead."
    fi

    if [[ -n "$password_file" ]]; then
        [[ -r "$password_file" ]] || die "Cannot read kiosk password file: $password_file"
        password=$(<"$password_file")
    else
        [[ "$non_interactive" -eq 0 ]] || \
            die "--non-interactive --create-kiosk-user requires --kiosk-password-file."
        read -r -s -p "Password for $kiosk_user: " password
        echo
    fi
    [[ -n "$password" ]] || die "Kiosk account password cannot be empty."

    useradd --create-home --shell /bin/bash "$kiosk_user"
    printf '%s:%s\n' "$kiosk_user" "$password" | chpasswd
    unset password
    usermod --append --groups sudo "$kiosk_user"
    info "Created kiosk user $kiosk_user with normal sudo password requirements."
}

configure_ubuntu_autologin() {
    local autologin_user="$1"
    local existing_autologin existing_wayland backup_path managed_wayland=0

    [[ "$PLATFORM_ID" == "ubuntu" && "$PLATFORM_VERSION" == "26.04" ]] || \
        die "Ubuntu GDM auto-login is available only on Ubuntu 26.04."
    [[ -n "$autologin_user" ]] || \
        die "Specify --autologin-user or --create-kiosk-user for Ubuntu auto-login."
    id "$autologin_user" >/dev/null 2>&1 || die "Unknown auto-login user: $autologin_user"
    [[ -f "$GDM_CONFIG" ]] || die "GDM configuration not found: $GDM_CONFIG"
    dpkg-query -W -f='${Status}' gdm3 2>/dev/null | grep -q 'install ok installed' || \
        die "GDM3 is not installed; auto-login is only supported for Ubuntu Desktop with GDM."

    existing_autologin=$(gdm_daemon_value "AutomaticLogin")
    [[ -z "$existing_autologin" ]] || \
        die "GDM already has an auto-login user ($existing_autologin); refuse to overwrite it."
    existing_wayland=$(gdm_daemon_value "WaylandEnable")
    if [[ -n "$existing_wayland" && "$existing_wayland" != "false" ]]; then
        die "GDM already defines WaylandEnable=$existing_wayland; configure X11 manually before enabling kiosk auto-login."
    fi
    [[ -z "$existing_wayland" ]] && managed_wayland=1

    mkdir -p "$GDM_BACKUP_DIR" "$(dirname "$AUTOLOGIN_STATE_PATH")"
    chmod 700 "$GDM_BACKUP_DIR"
    backup_path="$GDM_BACKUP_DIR/custom.conf.$(date -u +%Y%m%dT%H%M%SZ).bak"
    cp -p "$GDM_CONFIG" "$backup_path"
    chmod 600 "$backup_path"
    write_gdm_autologin_config "$autologin_user"
    cat > "$AUTOLOGIN_STATE_PATH" <<EOF
MANAGED_WAYLAND=$managed_wayland
AUTOLOGIN_USER=$autologin_user
BACKUP_PATH=$backup_path
EOF
    chmod 600 "$AUTOLOGIN_STATE_PATH"
    info "GDM auto-login is configured for $autologin_user. Reboot to start the required X11 session."
}

disable_ubuntu_autologin() {
    local managed_wayland

    [[ -f "$AUTOLOGIN_STATE_PATH" ]] || \
        die "No installer-managed GDM auto-login state was found."
    # shellcheck disable=SC1090
    source "$AUTOLOGIN_STATE_PATH"
    managed_wayland="${MANAGED_WAYLAND:-0}"
    remove_gdm_managed_keys "$managed_wayland"
    rm -f "$AUTOLOGIN_STATE_PATH"
    info "Installer-managed GDM auto-login is disabled. Reboot to return to the normal login screen."
}