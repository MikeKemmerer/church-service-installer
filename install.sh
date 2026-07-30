#!/usr/bin/env bash
# Church service installer coordinator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"
# shellcheck source=lib/remote-access.sh
source "$SCRIPT_DIR/lib/remote-access.sh"

CATALOG_PATH="$SCRIPT_DIR/config/services.json"
DRY_RUN=0
NON_INTERACTIVE=0
ASSUME_YES=0
FRESH=0
SERVICES_CSV=""
ENABLE_X11_FORWARDING=0
DISABLE_X11_FORWARDING=0
KEY_ONLY_USER=""
CONFIRM_KEY_LOGIN=0
ENABLE_VNC=0
DISABLE_VNC=0
VNC_ALLOW=""
VNC_USER=""
VNC_PASSWORD_FILE=""
ALLOW_UNFIREWALLED_VNC=0
KIOSK_USER=""
KIOSK_INSTALL_DIR="/opt/videokiosk2"
KIOSK_CONFIG_DIR="/etc/videokiosk2"
CALENDAR_USER=""
CALENDAR_DEST="/opt/church-calendar"

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

Install or prepare church AV services on Raspberry Pi OS or Ubuntu 26.04.

Options:
  --services NAME[,NAME...]  Select services by catalog identifier.
  --fresh                    Install selected services from their trusted catalog entry.
    --kiosk-user USER          Run videokiosk2 as this existing desktop user.
        --kiosk-install-dir PATH   Store videokiosk2 runtime scripts here (default: /opt/videokiosk2).
        --kiosk-config-dir PATH    Store videokiosk2 configuration here (default: /etc/videokiosk2).
    --calendar-user USER       Run church-calendar as this existing service user.
    --calendar-dest PATH       Install church-calendar here (default: /opt/church-calendar).
    --enable-x11-forwarding    Enable SSH X11 forwarding with an owned SSH drop-in.
    --disable-x11-forwarding   Remove the installer-owned SSH X11 forwarding drop-in.
    --enable-key-only USER     Disable SSH password login for a verified management user.
    --confirm-key-login        Confirm that a second key-authenticated SSH session works.
    --with-vnc                 Install an x11vnc server attached to the HDMI X11 display.
    --disable-vnc              Remove the installer-owned x11vnc service.
    --vnc-allow CIDR           Allow direct VNC access only from this IPv4 address or CIDR.
    --vnc-user USER            User that owns the local X11 display.
    --vnc-password-file PATH   Read the VNC password from a root-readable local file.
    --allow-unfirewalled-vnc   Permit VNC when no supported firewall is active.
  --dry-run                  Validate platform and selection without changing the host.
  --non-interactive          Require all choices through command-line options.
  --yes                      Confirm the requested action without a prompt.
  --list-services            Print service identifiers and exit.
  -h, --help                 Show this help text.

Restore, dashboard backup, auto-login, and remote-access options are added in
subsequent installer phases. Direct service installers remain available today.
EOF
}

list_services() {
    jq -r '.services[] | "\(.id)\t\(.name)\t\(.role)"' "$CATALOG_PATH"
}

catalog_has_service() {
    local service_id="$1"
    jq -e --arg id "$service_id" '.services[] | select(.id == $id)' \
        "$CATALOG_PATH" >/dev/null
}

validate_selection() {
    local service_id
    for service_id in "${SELECTED_SERVICES[@]}"; do
        catalog_has_service "$service_id" || die "Unknown service: $service_id"
    done

    if selection_has "church-monitoring-server" && selection_has "church-monitoring-client"; then
        die "church-monitoring-server and church-monitoring-client cannot run on the same host."
    fi
}

selection_has() {
    local wanted="$1"
    local service_id
    for service_id in "${SELECTED_SERVICES[@]}"; do
        [[ "$service_id" == "$wanted" ]] && return 0
    done
    return 1
}

resolve_kiosk_user() {
    local default_user

    selection_has "videokiosk2" || return 0

    if [[ -z "$KIOSK_USER" ]]; then
        if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
            default_user="$SUDO_USER"
        else
            die "Specify --kiosk-user USER when installing videokiosk2 as root."
        fi

        if [[ $NON_INTERACTIVE -eq 1 ]]; then
            die "--non-interactive videokiosk2 installation requires --kiosk-user USER."
        fi
        read -r -p "Kiosk desktop user [default: $default_user]: " KIOSK_USER
        KIOSK_USER="${KIOSK_USER:-$default_user}"
    fi

    id "$KIOSK_USER" >/dev/null 2>&1 || die "Kiosk user does not exist: $KIOSK_USER"
    [[ "$KIOSK_USER" != "root" ]] || die "Kiosk user must be a non-root desktop user."
    [[ "$KIOSK_INSTALL_DIR" == /* ]] || die "--kiosk-install-dir must be an absolute path."
    [[ "$KIOSK_CONFIG_DIR" == /* ]] || die "--kiosk-config-dir must be an absolute path."
}

resolve_calendar_user() {
    local default_user

    selection_has "church-calendar" || return 0

    if [[ -z "$CALENDAR_USER" ]]; then
        if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
            default_user="$SUDO_USER"
        else
            die "Specify --calendar-user USER when installing church-calendar as root."
        fi

        if [[ $NON_INTERACTIVE -eq 1 ]]; then
            die "--non-interactive church-calendar installation requires --calendar-user USER."
        fi
        read -r -p "Church-calendar service user [default: $default_user]: " CALENDAR_USER
        CALENDAR_USER="${CALENDAR_USER:-$default_user}"
    fi

    id "$CALENDAR_USER" >/dev/null 2>&1 || die "Calendar user does not exist: $CALENDAR_USER"
    [[ "$CALENDAR_USER" != "root" ]] || die "Calendar user must be a non-root account."
    [[ "$CALENDAR_DEST" == /* ]] || die "--calendar-dest must be an absolute path."
}

read_interactive_selection() {
    local selection
    echo "Available services:"
    list_services | column -t -s $'\t'
    read -r -p "Enter comma-separated service identifiers: " selection
    SERVICES_CSV="$selection"
}

parse_services() {
    local service_id
    IFS=',' read -r -a SELECTED_SERVICES <<< "$SERVICES_CSV"
    [[ ${#SELECTED_SERVICES[@]} -gt 0 && -n "${SELECTED_SERVICES[0]}" ]] || \
        die "Select at least one service with --services or the interactive menu."

    for service_id in "${SELECTED_SERVICES[@]}"; do
        [[ "$service_id" =~ ^[a-z0-9-]+$ ]] || die "Invalid service identifier: $service_id"
    done
}

has_host_actions() {
    [[ $ENABLE_X11_FORWARDING -eq 1 || $DISABLE_X11_FORWARDING -eq 1 || \
        -n "$KEY_ONLY_USER" || $ENABLE_VNC -eq 1 || $DISABLE_VNC -eq 1 ]]
}

print_plan() {
    local service_id
    echo "Platform: $PLATFORM_LABEL ($PLATFORM_ARCH)"
    echo "Selected services:"
    for service_id in "${SELECTED_SERVICES[@]}"; do
        jq -r --arg id "$service_id" \
            '.services[] | select(.id == $id) | "  - \(.name) [\(.id)]"' \
            "$CATALOG_PATH"
    done
}

run_service_installer() {
    local service_id="$1"
    local repository branch checkout_dir
    local -a installer_command

    repository=$(jq -r --arg id "$service_id" \
        '.services[] | select(.id == $id) | .repository' "$CATALOG_PATH")
    branch=$(jq -r --arg id "$service_id" \
        '.services[] | select(.id == $id) | .branch' "$CATALOG_PATH")
    checkout_dir="/opt/church-service-installer/checkouts/$service_id"
    mapfile -t installer_command < <(jq -r --arg id "$service_id" \
        '.services[] | select(.id == $id) | .installer[]' "$CATALOG_PATH")

    checkout_trusted_repository "$repository" "$branch" "$checkout_dir"
    info "Running $service_id installer"
    if [[ "$service_id" == "videokiosk2" ]]; then
        installer_command+=(
            --kiosk-user "$KIOSK_USER"
            --install-dir "$KIOSK_INSTALL_DIR"
            --config-dir "$KIOSK_CONFIG_DIR"
        )
    fi
    (
        cd "$checkout_dir"
        if [[ "$service_id" == "church-calendar" ]]; then
            RUN_USER="$CALENDAR_USER" DEST="$CALENDAR_DEST" "${installer_command[@]}"
        else
            "${installer_command[@]}"
        fi
    )
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --services)
            SERVICES_CSV="${2:-}"
            shift 2
            ;;
        --fresh)
            FRESH=1
            shift
            ;;
        --kiosk-user)
            KIOSK_USER="${2:-}"
            [[ -n "$KIOSK_USER" ]] || die "--kiosk-user requires a user."
            shift 2
            ;;
        --kiosk-install-dir)
            KIOSK_INSTALL_DIR="${2:-}"
            [[ -n "$KIOSK_INSTALL_DIR" ]] || die "--kiosk-install-dir requires a path."
            shift 2
            ;;
        --kiosk-config-dir)
            KIOSK_CONFIG_DIR="${2:-}"
            [[ -n "$KIOSK_CONFIG_DIR" ]] || die "--kiosk-config-dir requires a path."
            shift 2
            ;;
        --calendar-user)
            CALENDAR_USER="${2:-}"
            [[ -n "$CALENDAR_USER" ]] || die "--calendar-user requires a user."
            shift 2
            ;;
        --calendar-dest)
            CALENDAR_DEST="${2:-}"
            [[ -n "$CALENDAR_DEST" ]] || die "--calendar-dest requires a path."
            shift 2
            ;;
        --enable-x11-forwarding)
            ENABLE_X11_FORWARDING=1
            shift
            ;;
        --disable-x11-forwarding)
            DISABLE_X11_FORWARDING=1
            shift
            ;;
        --enable-key-only)
            KEY_ONLY_USER="${2:-}"
            [[ -n "$KEY_ONLY_USER" ]] || die "--enable-key-only requires a user."
            shift 2
            ;;
        --confirm-key-login)
            CONFIRM_KEY_LOGIN=1
            shift
            ;;
        --with-vnc)
            ENABLE_VNC=1
            shift
            ;;
        --disable-vnc)
            DISABLE_VNC=1
            shift
            ;;
        --vnc-allow)
            VNC_ALLOW="${2:-}"
            [[ -n "$VNC_ALLOW" ]] || die "--vnc-allow requires an IPv4 address or CIDR."
            shift 2
            ;;
        --vnc-user)
            VNC_USER="${2:-}"
            [[ -n "$VNC_USER" ]] || die "--vnc-user requires a user."
            shift 2
            ;;
        --vnc-password-file)
            VNC_PASSWORD_FILE="${2:-}"
            [[ -n "$VNC_PASSWORD_FILE" ]] || die "--vnc-password-file requires a path."
            shift 2
            ;;
        --allow-unfirewalled-vnc)
            ALLOW_UNFIREWALLED_VNC=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --list-services)
            require_command jq
            list_services
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

require_command jq
[[ -f "$CATALOG_PATH" ]] || die "Missing service catalog: $CATALOG_PATH"

if [[ -z "$SERVICES_CSV" && ! has_host_actions ]]; then
    [[ $NON_INTERACTIVE -eq 0 ]] || die "--non-interactive requires --services or a host action."
    read_interactive_selection
fi

SELECTED_SERVICES=()
if [[ -n "$SERVICES_CSV" ]]; then
    parse_services
    validate_selection
    resolve_kiosk_user
    resolve_calendar_user
fi
detect_platform
validate_supported_platform
if [[ ${#SELECTED_SERVICES[@]} -gt 0 ]]; then
    validate_selected_services_for_platform "$CATALOG_PATH" "${SELECTED_SERVICES[@]}"
    print_plan
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk user: $KIOSK_USER"
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk scripts: $KIOSK_INSTALL_DIR"
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk configuration: $KIOSK_CONFIG_DIR"
    [[ -n "$CALENDAR_USER" ]] && echo "Calendar user: $CALENDAR_USER"
    [[ -n "$CALENDAR_USER" ]] && echo "Calendar destination: $CALENDAR_DEST"
else
    echo "Platform: $PLATFORM_LABEL ($PLATFORM_ARCH)"
fi

if has_host_actions; then
    echo "Host actions requested:"
    [[ $ENABLE_X11_FORWARDING -eq 1 ]] && echo "  - Enable SSH X11 forwarding"
    [[ $DISABLE_X11_FORWARDING -eq 1 ]] && echo "  - Disable SSH X11 forwarding"
    [[ -n "$KEY_ONLY_USER" ]] && echo "  - Enable SSH key-only login for $KEY_ONLY_USER"
    [[ $ENABLE_VNC -eq 1 ]] && echo "  - Enable attached-display VNC"
    [[ $DISABLE_VNC -eq 1 ]] && echo "  - Disable attached-display VNC"
fi

if [[ $DRY_RUN -eq 1 ]]; then
    info "Dry run complete. No changes were made."
    exit 0
fi

if [[ ${#SELECTED_SERVICES[@]} -gt 0 && $FRESH -eq 0 ]]; then
    die "Choose --fresh. Restore support is not implemented in this first slice."
fi

if [[ $EUID -ne 0 ]]; then
    die "Run this installer as root: sudo ./install.sh ..."
fi

if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "Apply the requested service and host changes now? [y/N] " confirmation
    [[ "$confirmation" =~ ^[Yy]([Ee][Ss])?$ ]] || die "Cancelled."
fi

if [[ $ENABLE_X11_FORWARDING -eq 1 ]]; then
    configure_ssh_x11_forwarding
fi
if [[ $DISABLE_X11_FORWARDING -eq 1 ]]; then
    disable_ssh_x11_forwarding
fi
if [[ -n "$KEY_ONLY_USER" ]]; then
    [[ $CONFIRM_KEY_LOGIN -eq 1 ]] || \
        die "--enable-key-only requires --confirm-key-login after verifying a second SSH key login."
    configure_ssh_key_only "$KEY_ONLY_USER"
fi
if [[ $ENABLE_VNC -eq 1 ]]; then
    configure_x11vnc "$VNC_ALLOW" "$VNC_USER" "$VNC_PASSWORD_FILE" "$ALLOW_UNFIREWALLED_VNC" "$NON_INTERACTIVE"
fi
if [[ $DISABLE_VNC -eq 1 ]]; then
    disable_x11vnc
fi

for service_id in "${SELECTED_SERVICES[@]}"; do
    run_service_installer "$service_id"
done

info "Installation completed."