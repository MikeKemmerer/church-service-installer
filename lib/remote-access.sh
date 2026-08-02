#!/usr/bin/env bash

REMOTE_CONFIG_DIR="${REMOTE_CONFIG_DIR:-/etc/church-service-installer}"
SSH_DROPIN_DIR="${SSH_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
SSH_X11_DROPIN="$SSH_DROPIN_DIR/90-church-service-installer-x11.conf"
VNC_PASSWORD_PATH="$REMOTE_CONFIG_DIR/x11vnc.pass"
VNC_ENV_PATH="$REMOTE_CONFIG_DIR/x11vnc.env"
VNC_SERVICE_PATH="${VNC_SERVICE_PATH:-/etc/systemd/system/church-service-installer-x11vnc.service}"

install_packages() {
    require_command apt-get
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

reload_ssh() {
    require_command sshd
    sshd -t || die "SSH configuration validation failed; no reload was attempted."
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
}

configure_ssh_x11_forwarding() {
    install_packages openssh-server xauth
    mkdir -p "$SSH_DROPIN_DIR"
    cat > "$SSH_X11_DROPIN" <<'EOF'
# Managed by church-service-installer. Remove this file to disable the setting.
X11Forwarding yes
X11UseLocalhost yes
X11DisplayOffset 10
EOF
    chmod 644 "$SSH_X11_DROPIN"
    reload_ssh
    info "SSH X11 forwarding is enabled for new SSH sessions."
}

disable_ssh_x11_forwarding() {
    [[ -e "$SSH_X11_DROPIN" ]] || {
        info "SSH X11 forwarding drop-in is already absent."
        return
    }
    rm -f "$SSH_X11_DROPIN"
    reload_ssh
    info "Installer-managed SSH X11 forwarding is disabled."
}

prompt_vnc_password() {
    local first_password second_password
    read -r -s -p "VNC password: " first_password
    echo
    read -r -s -p "Confirm VNC password: " second_password
    echo
    [[ -n "$first_password" ]] || die "A VNC password is required."
    [[ "$first_password" == "$second_password" ]] || die "VNC passwords do not match."
    printf '%s' "$first_password"
}

validate_vnc_allow() {
    local allowed_network="$1"
    [[ "$allowed_network" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || \
        die "VNC allow value must be an IPv4 address or CIDR."
}

active_ufw() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active$'
}

configure_vnc_firewall() {
    local allowed_network="$1"
    local allow_unfirewalled="$2"

    if active_ufw; then
        ufw allow from "$allowed_network" to any port 5900 proto tcp \
            comment 'church-service-installer-vnc'
        return
    fi

    [[ "$allow_unfirewalled" -eq 1 ]] || die \
        "No active supported firewall was found. Re-run with --allow-unfirewalled-vnc only after reviewing LAN exposure."
    info "Continuing without a firewall rule because --allow-unfirewalled-vnc was supplied."
}

resolve_vnc_user() {
    local requested_user="$1"
    if [[ -n "$requested_user" ]]; then
        id "$requested_user" >/dev/null 2>&1 || die "Unknown VNC display user: $requested_user"
        printf '%s' "$requested_user"
        return
    fi
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        printf '%s' "$SUDO_USER"
        return
    fi
    die "Specify the X11 display owner with --vnc-user."
}

configure_x11vnc() {
    local allowed_network="$1"
    local requested_user="$2"
    local password_file="$3"
    local allow_unfirewalled="$4"
    local non_interactive="$5"
    local display_user display_home password

    [[ -n "$allowed_network" ]] || die "--with-vnc requires --vnc-allow."
    validate_vnc_allow "$allowed_network"
    display_user=$(resolve_vnc_user "$requested_user")
    display_home=$(getent passwd "$display_user" | cut -d: -f6)
    [[ -d "$display_home" ]] || die "VNC display user has no home directory: $display_user"

    install_packages x11vnc
    mkdir -p "$REMOTE_CONFIG_DIR"
    chmod 700 "$REMOTE_CONFIG_DIR"

    if [[ -n "$password_file" ]]; then
        [[ -r "$password_file" ]] || die "Cannot read VNC password file: $password_file"
        password=$(<"$password_file")
    else
        [[ "$non_interactive" -eq 0 ]] || die "--non-interactive --with-vnc requires --vnc-password-file."
        password=$(prompt_vnc_password)
    fi
    [[ -n "$password" ]] || die "A VNC password is required."
    x11vnc -storepasswd "$password" "$VNC_PASSWORD_PATH" >/dev/null
    unset password
    chmod 600 "$VNC_PASSWORD_PATH"

    configure_vnc_firewall "$allowed_network" "$allow_unfirewalled"

    cat > "$VNC_ENV_PATH" <<EOF
DISPLAY=:0
XAUTHORITY=$display_home/.Xauthority
VNC_ALLOW=$allowed_network
EOF
    chmod 600 "$VNC_ENV_PATH"

    cat > "$VNC_SERVICE_PATH" <<EOF
[Unit]
Description=Church Service Installer attached-display VNC server
After=display-manager.service
Wants=display-manager.service

[Service]
Type=simple
User=$display_user
EnvironmentFile=$VNC_ENV_PATH
LoadCredential=vnc-password:$VNC_PASSWORD_PATH
ExecStartPre=/usr/bin/test -S /tmp/.X11-unix/X0
ExecStart=/usr/bin/x11vnc -display \${DISPLAY} -auth \${XAUTHORITY} -rfbauth %d/vnc-password -allow \${VNC_ALLOW} -forever -shared -xkb
Restart=on-failure
RestartSec=10

[Install]
WantedBy=graphical.target
EOF
    chmod 644 "$VNC_SERVICE_PATH"
    systemctl daemon-reload
    systemctl enable --now "$(basename "$VNC_SERVICE_PATH")"
    info "Attached-display VNC is enabled for $allowed_network on port 5900."
}

disable_x11vnc() {
    local allowed_network=""

    if [[ -f "$VNC_ENV_PATH" ]]; then
        # shellcheck disable=SC1090
        source "$VNC_ENV_PATH"
        allowed_network="${VNC_ALLOW:-}"
    fi

    systemctl disable --now "$(basename "$VNC_SERVICE_PATH")" 2>/dev/null || true
    rm -f "$VNC_SERVICE_PATH" "$VNC_ENV_PATH" "$VNC_PASSWORD_PATH"
    systemctl daemon-reload

    if [[ -n "$allowed_network" ]] && active_ufw; then
        ufw delete allow from "$allowed_network" to any port 5900 proto tcp || true
    fi
    info "Installer-managed attached-display VNC is disabled."
}