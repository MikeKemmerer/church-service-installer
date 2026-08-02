#!/usr/bin/env bash
# Church service installer coordinator.

set -euo pipefail

ORIGINAL_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"
# shellcheck source=lib/tui.sh
source "$SCRIPT_DIR/lib/tui.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/desktop.sh
source "$SCRIPT_DIR/lib/desktop.sh"
# shellcheck source=lib/remote-access.sh
source "$SCRIPT_DIR/lib/remote-access.sh"

CATALOG_PATH="$SCRIPT_DIR/config/services.json"
DRY_RUN=0
NON_INTERACTIVE=0
ASSUME_YES=0
FRESH=0
REPAIR_APPARMOR=0
CONFIGURE_APPARMOR=0
SERVICES_CSV=""
ENABLE_X11_FORWARDING=0
DISABLE_X11_FORWARDING=0
ENABLE_VNC=0
DISABLE_VNC=0
VNC_ALLOW=""
VNC_USER=""
VNC_PASSWORD_FILE=""
ALLOW_UNFIREWALLED_VNC=0
KIOSK_USER=""
KIOSK_INSTALL_DIR="/opt/videokiosk2"
KIOSK_CONFIG_DIR="/etc/videokiosk2"
KIOSK_FEED_URL=""
KIOSK_BROWSER_URL=""
KIOSK_SCHEDULE_URL=""
KIOSK_RESTART_DELAY_MINUTES=""
KIOSK_GPIO_ENABLED=""
KIOSK_GPIO_PIN=""
KIOSK_AUDIO_OUTPUT="auto"
KIOSK_ALSA_AUDIO_DEVICE=""
CALENDAR_USER=""
CALENDAR_DEST="/opt/church-calendar"
MENU_MODE="auto"
BOOTSTRAP_APT_GET="${BOOTSTRAP_APT_GET:-apt-get}"
LIST_SERVICES=0

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

Install or prepare church AV services on Debian 12+ or Raspberry Pi OS.

Options:
  --services NAME[,NAME...]  Select services by catalog identifier.
  --fresh                    Install selected services from their trusted catalog entry.
    --configure-apparmor       Configure Ubuntu AppArmor after a fresh installation.
    --repair-apparmor          Detect installed services and repair their Ubuntu AppArmor setup.
    --kiosk-user USER          Run videokiosk2 as this existing desktop user.
    --kiosk-install-dir PATH   Store videokiosk2 runtime scripts here (default: /opt/videokiosk2).
    --kiosk-config-dir PATH    Store videokiosk2 configuration here (default: /etc/videokiosk2).
    --kiosk-feed-url URL       Set the VLC video feed URL.
    --kiosk-browser-url URL    Set the Falkon failover URL.
    --kiosk-schedule-url URL   Set the scheduled-restart API URL.
    --kiosk-restart-delay-minutes MINUTES  Delay scheduled restarts.
    --kiosk-audio-output MODE  Select auto or alsa audio output (default: auto).
    --kiosk-alsa-audio-device DEVICE  ALSA device used with --kiosk-audio-output alsa.
    --kiosk-gpio-pin PIN       Install the GPIO restart button on this pin.
    --kiosk-no-gpio            Do not install the GPIO restart button.
    --calendar-user USER       Run church-calendar as this existing service user.
    --calendar-dest PATH       Install church-calendar here (default: /opt/church-calendar).
    --enable-x11-forwarding    Enable SSH X11 forwarding with an owned SSH drop-in.
    --disable-x11-forwarding   Remove the installer-owned SSH X11 forwarding drop-in.
    --with-vnc                 Install an x11vnc server attached to the HDMI X11 display.
    --disable-vnc              Remove the installer-owned x11vnc service.
    --vnc-allow CIDR           Allow direct VNC access only from this IPv4 address or CIDR.
    --vnc-user USER            User that owns the local X11 display.
    --vnc-password-file PATH   Read the VNC password from a root-readable local file.
    --allow-unfirewalled-vnc   Permit VNC when no supported firewall is active.
  --dry-run                  Validate platform and selection without changing the host.
    --menu-mode MODE           Use auto, whiptail, text, or none for interactive menus.
  --non-interactive          Require all choices through command-line options.
    --yes                      Approve installer and prerequisite prompts.
  --list-services            Print service identifiers and exit.
  -h, --help                 Show this help text.

Restore, dashboard backup, auto-login, and remote-access options are added in
subsequent installer phases. Direct service installers remain available today.
EOF
}

list_services() {
    jq -r '.services[] | "\(.id)\t\(.name)\t\(.role)"' "$CATALOG_PATH"
}

bootstrap_dependencies() {
    local -a missing_packages=()
    local confirmation

    if [[ ",${BOOTSTRAP_FORCE_MISSING:-}," == *,jq,* ]] || ! command -v jq >/dev/null 2>&1; then
        missing_packages+=(jq)
    fi
    if [[ ",${BOOTSTRAP_FORCE_MISSING:-}," == *,git,* ]] || ! command -v git >/dev/null 2>&1; then
        missing_packages+=(git)
    fi
    if [[ ",${BOOTSTRAP_FORCE_MISSING:-}," == *,whiptail,* ]] || ! command -v whiptail >/dev/null 2>&1; then
        missing_packages+=(whiptail)
    fi
    [[ ${#missing_packages[@]} -eq 0 ]] && return 0

    if [[ $EUID -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || die \
            "Install bootstrap packages first as root: jq git whiptail"
        info "Installer prerequisites are missing; restarting with sudo."
        exec sudo --preserve-env=OS_RELEASE_FILE,BOOTSTRAP_APT_GET "$0" "${ORIGINAL_ARGS[@]}"
    fi
    command -v "$BOOTSTRAP_APT_GET" >/dev/null 2>&1 || \
        die "Cannot install bootstrap packages: $BOOTSTRAP_APT_GET is unavailable."

    if [[ $ASSUME_YES -eq 0 ]]; then
        [[ $NON_INTERACTIVE -eq 0 ]] || die \
            "Missing installer prerequisites: ${missing_packages[*]}. Re-run with --yes to install them."
        read -r -p "Install installer prerequisites (${missing_packages[*]}) now? [Y/n] " confirmation
        [[ -z "$confirmation" || "$confirmation" =~ ^[Yy]([Ee][Ss])?$ ]] || \
            die "Installer prerequisite installation cancelled."
    fi

    info "Installing installer prerequisites: ${missing_packages[*]}"
    DEBIAN_FRONTEND=noninteractive "$BOOTSTRAP_APT_GET" update
    DEBIAN_FRONTEND=noninteractive "$BOOTSTRAP_APT_GET" install -y "${missing_packages[@]}"
}

restart_as_root() {
    [[ $EUID -eq 0 || $DRY_RUN -eq 1 || $LIST_SERVICES -eq 1 ]] && return 0
    command -v sudo >/dev/null 2>&1 || die "Run this installer as root: sudo ./install.sh ..."
    info "Restarting the guided installer with sudo."
    exec sudo --preserve-env=OS_RELEASE_FILE,BOOTSTRAP_APT_GET "$0" "${ORIGINAL_ARGS[@]}"
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

kiosk_config_value() {
    local key="$1"
    local config_path="$KIOSK_CONFIG_DIR/local.conf"

    [[ -r "$config_path" ]] || return 0
    sed -n "s/^${key}=\"\([^\"]*\)\"$/\1/p" "$config_path" | head -n 1
}

show_kiosk_alsa_device_hint() {
    local hdmi_devices

    echo "To list available ALSA devices later, run: aplay -L"
    if ! command -v aplay >/dev/null 2>&1; then
        echo "Install alsa-utils to list device identifiers on this host."
        return
    fi

    hdmi_devices=$(aplay -L 2>/dev/null | sed -n '/^hdmi:/p')
    if [[ -n "$hdmi_devices" ]]; then
        echo "Available HDMI ALSA devices:"
        while IFS= read -r device; do
            echo "  $device"
        done <<< "$hdmi_devices"
    else
        echo "No HDMI ALSA devices were reported by aplay -L."
    fi
}

resolve_kiosk_url() {
    local variable_name="$1"
    local label="$2"
    local default_value="$3"
    local value="${!variable_name}"

    if [[ -z "$value" ]]; then
        [[ $NON_INTERACTIVE -eq 0 ]] || die "--non-interactive videokiosk2 installation requires $label."
        read -r -p "$label [default: $default_value]: " value
        value="${value:-$default_value}"
    fi

    [[ "$value" =~ ^https?://[^[:space:]]+$ ]] || die "Invalid $label: $value"
    printf -v "$variable_name" '%s' "$value"
}

resolve_kiosk_settings() {
    local feed_default browser_default schedule_default gpio_answer

    selection_has "videokiosk2" || return 0

    feed_default="$(kiosk_config_value STREAM_URL)"
    browser_default="$(kiosk_config_value BROWSER_URL)"
    feed_default="${feed_default:-http://your-stream-server:8086/2.ts}"
    browser_default="${browser_default:-http://your-calendar-server:8000}"
    resolve_kiosk_url KIOSK_FEED_URL "Video feed URL" "$feed_default"
    resolve_kiosk_url KIOSK_BROWSER_URL "Failover browser URL" "$browser_default"
    schedule_default="${KIOSK_BROWSER_URL%/}/api/service-restart-schedule"
    resolve_kiosk_url KIOSK_SCHEDULE_URL "Restart schedule API URL" "$schedule_default"

    if [[ -z "$KIOSK_RESTART_DELAY_MINUTES" ]]; then
        [[ $NON_INTERACTIVE -eq 0 ]] || die \
            "--non-interactive videokiosk2 installation requires --kiosk-restart-delay-minutes."
        read -r -p "Restart delay in minutes [default: 0]: " KIOSK_RESTART_DELAY_MINUTES
        KIOSK_RESTART_DELAY_MINUTES="${KIOSK_RESTART_DELAY_MINUTES:-0}"
    fi
    [[ "$KIOSK_RESTART_DELAY_MINUTES" =~ ^[0-9]+$ ]] || \
        die "Kiosk restart delay must be a non-negative whole number of minutes."

    [[ "$KIOSK_AUDIO_OUTPUT" == "auto" || "$KIOSK_AUDIO_OUTPUT" == "alsa" ]] || \
        die "Kiosk audio output must be auto or alsa."
    if [[ "$KIOSK_AUDIO_OUTPUT" == "alsa" && -z "$KIOSK_ALSA_AUDIO_DEVICE" ]]; then
        if [[ $NON_INTERACTIVE -eq 1 ]]; then
            die "--non-interactive ALSA audio requires --kiosk-alsa-audio-device."
        fi
        show_kiosk_alsa_device_hint
        read -r -p "ALSA audio device [default: hdmi:CARD=PCH,DEV=0]: " KIOSK_ALSA_AUDIO_DEVICE
        KIOSK_ALSA_AUDIO_DEVICE="${KIOSK_ALSA_AUDIO_DEVICE:-hdmi:CARD=PCH,DEV=0}"
    fi

    if [[ -z "$KIOSK_GPIO_ENABLED" ]]; then
        [[ $NON_INTERACTIVE -eq 0 ]] || die \
            "--non-interactive videokiosk2 installation requires --kiosk-gpio-pin or --kiosk-no-gpio."
        read -r -p "Install GPIO button restart monitor? [y/N]: " gpio_answer
        if [[ "$gpio_answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            KIOSK_GPIO_ENABLED=1
        else
            KIOSK_GPIO_ENABLED=0
        fi
    fi

    if [[ "$KIOSK_GPIO_ENABLED" == "1" ]]; then
        if [[ -z "$KIOSK_GPIO_PIN" ]]; then
            [[ $NON_INTERACTIVE -eq 0 ]] || die \
                "--non-interactive GPIO restart requires --kiosk-gpio-pin."
            read -r -p "GPIO pin number [default: 17]: " KIOSK_GPIO_PIN
            KIOSK_GPIO_PIN="${KIOSK_GPIO_PIN:-17}"
        fi
        [[ "$KIOSK_GPIO_PIN" =~ ^[0-9]+$ ]] && (( KIOSK_GPIO_PIN >= 2 && KIOSK_GPIO_PIN <= 27 )) || \
            die "Invalid GPIO pin: $KIOSK_GPIO_PIN (must be 2-27)."
    elif [[ -n "$KIOSK_GPIO_PIN" ]]; then
        die "--kiosk-gpio-pin conflicts with --kiosk-no-gpio."
    fi
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
    SERVICES_CSV=$(TUI_MENU_MODE="$MENU_MODE" tui_select_services "$CATALOG_PATH") || \
        die "Service selection cancelled."
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
    $ENABLE_VNC -eq 1 || $DISABLE_VNC -eq 1 ]]
}

confirmation_prompt() {
    if [[ ${#SELECTED_SERVICES[@]} -eq 1 ]] && \
        selection_has "church-monitoring-client" && \
        ! has_host_actions && \
        [[ $REPAIR_APPARMOR -eq 0 && $CONFIGURE_APPARMOR -eq 0 ]]; then
        printf '%s' "Install Church Monitoring Client and its Apache/collector components now? This does not change Video Kiosk, VLC, Falkon, audio, or desktop settings. [y/N] "
    elif [[ ${#SELECTED_SERVICES[@]} -gt 0 ]] && has_host_actions; then
        printf '%s' "Apply the selected service installations and requested host changes now? [y/N] "
    elif [[ ${#SELECTED_SERVICES[@]} -gt 0 ]]; then
        printf '%s' "Install the selected services now? [y/N] "
    else
        printf '%s' "Apply the requested host changes now? [y/N] "
    fi
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
            --feed-url "$KIOSK_FEED_URL"
            --browser-url "$KIOSK_BROWSER_URL"
            --schedule-url "$KIOSK_SCHEDULE_URL"
            --restart-delay-minutes "$KIOSK_RESTART_DELAY_MINUTES"
            --audio-output "$KIOSK_AUDIO_OUTPUT"
            --non-interactive
            --yes
        )
        if [[ -n "$KIOSK_ALSA_AUDIO_DEVICE" ]]; then
            installer_command+=(--alsa-audio-device "$KIOSK_ALSA_AUDIO_DEVICE")
        fi
        if [[ "$KIOSK_GPIO_ENABLED" == "1" ]]; then
            installer_command+=(--gpio-pin "$KIOSK_GPIO_PIN")
        else
            installer_command+=(--disable-gpio-restart)
        fi
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

unit_is_installed() {
    local unit_name="$1"
    local load_state

    load_state=$(systemctl show "$unit_name" -p LoadState --value 2>/dev/null || true)
    [[ -n "$load_state" && "$load_state" != "not-found" ]]
}

checkout_service_for_repair() {
    local service_id="$1"
    local repository branch checkout_dir

    repository=$(jq -r --arg id "$service_id" \
        '.services[] | select(.id == $id) | .repository' "$CATALOG_PATH")
    branch=$(jq -r --arg id "$service_id" \
        '.services[] | select(.id == $id) | .branch' "$CATALOG_PATH")
    checkout_dir="/opt/church-service-installer/checkouts/$service_id"
    checkout_trusted_repository "$repository" "$branch" "$checkout_dir"
    printf '%s\n' "$checkout_dir"
}

repair_apparmor() {
    local checkout_dir
    local detected=0

    if [[ "$PLATFORM_ID" != "ubuntu" ]]; then
        info "AppArmor repair is Ubuntu-only; no changes are needed on $PLATFORM_LABEL."
        return
    fi

    if unit_is_installed church-calendar.service; then
        info "Detected church-calendar.service; repairing its AppArmor profile."
        checkout_dir=$(checkout_service_for_repair church-calendar)
        (cd "$checkout_dir" && ./install.sh --configure-apparmor-only)
        detected=1
    fi

    if unit_is_installed videokiosk2.service; then
        info "Detected videokiosk2.service; repairing its AppArmor profile."
        checkout_dir=$(checkout_service_for_repair videokiosk2)
        (cd "$checkout_dir" && bash videokiosk2-installer.sh --configure-apparmor-only)
        detected=1
    fi

    if [[ -d /usr/lib/cgi-bin/church-monitoring-server && \
        -f /etc/church-monitoring/server-config.json ]]; then
        info "Detected Church Monitoring server CGI; repairing its AppArmor hat."
        checkout_dir=$(checkout_service_for_repair church-monitoring-server)
        (cd "$checkout_dir" && ./configure-apparmor.sh --role server)
        detected=1
    fi

    if [[ -d /usr/lib/cgi-bin/church-monitoring-client && \
        -f /etc/church-monitoring/client-config.json ]]; then
        info "Detected Church Monitoring client CGI; repairing its AppArmor hat."
        checkout_dir=$(checkout_service_for_repair church-monitoring-client)
        (cd "$checkout_dir" && ./configure-apparmor.sh --role client)
        detected=1
    fi

    if [[ -d /var/www/html/cameracontrol && -d /var/www/html/multicamera ]]; then
        info "Detected Camera Control; repairing its Apache AppArmor hat."
        checkout_dir=$(checkout_service_for_repair church-monitoring-server)
        (cd "$checkout_dir" && ./configure-apparmor.sh --role cameras)
        detected=1
    fi

    [[ $detected -eq 1 ]] || info "No installed AppArmor-enabled services were detected."
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
        --repair-apparmor)
            REPAIR_APPARMOR=1
            shift
            ;;
        --configure-apparmor)
            CONFIGURE_APPARMOR=1
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
        --kiosk-feed-url)
            KIOSK_FEED_URL="${2:-}"
            [[ -n "$KIOSK_FEED_URL" ]] || die "--kiosk-feed-url requires a URL."
            shift 2
            ;;
        --kiosk-browser-url)
            KIOSK_BROWSER_URL="${2:-}"
            [[ -n "$KIOSK_BROWSER_URL" ]] || die "--kiosk-browser-url requires a URL."
            shift 2
            ;;
        --kiosk-schedule-url)
            KIOSK_SCHEDULE_URL="${2:-}"
            [[ -n "$KIOSK_SCHEDULE_URL" ]] || die "--kiosk-schedule-url requires a URL."
            shift 2
            ;;
        --kiosk-restart-delay-minutes)
            KIOSK_RESTART_DELAY_MINUTES="${2:-}"
            [[ -n "$KIOSK_RESTART_DELAY_MINUTES" ]] || die "--kiosk-restart-delay-minutes requires minutes."
            shift 2
            ;;
        --kiosk-audio-output)
            KIOSK_AUDIO_OUTPUT="${2:-}"
            [[ -n "$KIOSK_AUDIO_OUTPUT" ]] || die "--kiosk-audio-output requires auto or alsa."
            shift 2
            ;;
        --kiosk-alsa-audio-device)
            KIOSK_ALSA_AUDIO_DEVICE="${2:-}"
            [[ -n "$KIOSK_ALSA_AUDIO_DEVICE" ]] || die "--kiosk-alsa-audio-device requires a device."
            shift 2
            ;;
        --kiosk-gpio-pin)
            KIOSK_GPIO_PIN="${2:-}"
            [[ -n "$KIOSK_GPIO_PIN" ]] || die "--kiosk-gpio-pin requires a pin number."
            KIOSK_GPIO_ENABLED=1
            shift 2
            ;;
        --kiosk-no-gpio)
            [[ "$KIOSK_GPIO_ENABLED" != "1" ]] || die "--kiosk-no-gpio conflicts with --kiosk-gpio-pin."
            KIOSK_GPIO_ENABLED=0
            shift
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
        --menu-mode)
            MENU_MODE="${2:-}"
            case "$MENU_MODE" in
                auto|whiptail|text|none) ;;
                *) die "--menu-mode must be auto, whiptail, text, or none." ;;
            esac
            shift 2
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
            LIST_SERVICES=1
            shift
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

restart_as_root
bootstrap_dependencies
require_command jq
[[ -f "$CATALOG_PATH" ]] || die "Missing service catalog: $CATALOG_PATH"

if [[ $LIST_SERVICES -eq 1 ]]; then
    list_services
    exit 0
fi

if [[ -z "$SERVICES_CSV" && $REPAIR_APPARMOR -eq 0 ]] && ! has_host_actions; then
    [[ $NON_INTERACTIVE -eq 0 ]] || die "--non-interactive requires --services or a host action."
    [[ "$MENU_MODE" != "none" ]] || die "--menu-mode none requires --services or a host action."
    read_interactive_selection
fi

SELECTED_SERVICES=()
if [[ -n "$SERVICES_CSV" ]]; then
    parse_services
    validate_selection
    resolve_kiosk_user
    resolve_kiosk_settings
    resolve_calendar_user
fi
if [[ $REPAIR_APPARMOR -eq 1 && ${#SELECTED_SERVICES[@]} -gt 0 ]]; then
    die "--repair-apparmor detects installed services; do not combine it with --services."
fi
if [[ $REPAIR_APPARMOR -eq 1 && $CONFIGURE_APPARMOR -eq 1 ]]; then
    die "Choose either --configure-apparmor after a fresh installation or --repair-apparmor."
fi
if [[ $CONFIGURE_APPARMOR -eq 1 && ${#SELECTED_SERVICES[@]} -eq 0 ]]; then
    die "--configure-apparmor requires --services and --fresh."
fi
detect_platform
validate_supported_platform
if [[ ${#SELECTED_SERVICES[@]} -gt 0 ]]; then
    validate_selected_services_for_platform "$CATALOG_PATH" "${SELECTED_SERVICES[@]}"
    print_plan
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk user: $KIOSK_USER"
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk scripts: $KIOSK_INSTALL_DIR"
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk configuration: $KIOSK_CONFIG_DIR"
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk feed: $KIOSK_FEED_URL"
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk failover: $KIOSK_BROWSER_URL"
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk restart schedule: $KIOSK_SCHEDULE_URL"
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk restart delay: ${KIOSK_RESTART_DELAY_MINUTES} minute(s)"
    [[ -n "$KIOSK_USER" ]] && echo "Kiosk audio output: $KIOSK_AUDIO_OUTPUT"
    [[ -n "$KIOSK_ALSA_AUDIO_DEVICE" ]] && echo "Kiosk ALSA audio device: $KIOSK_ALSA_AUDIO_DEVICE"
    [[ "$KIOSK_GPIO_ENABLED" == "1" ]] && echo "Kiosk GPIO restart pin: $KIOSK_GPIO_PIN"
    [[ "$KIOSK_GPIO_ENABLED" == "0" ]] && echo "Kiosk GPIO restart button: disabled"
    [[ -n "$KIOSK_USER" && "$PLATFORM_ID" == "debian" ]] && \
        echo "Kiosk desktop: Xorg, LightDM autologin, and Openbox will be provisioned"
    [[ -n "$CALENDAR_USER" ]] && echo "Calendar user: $CALENDAR_USER"
    [[ -n "$CALENDAR_USER" ]] && echo "Calendar destination: $CALENDAR_DEST"
else
    echo "Platform: $PLATFORM_LABEL ($PLATFORM_ARCH)"
fi

if [[ $REPAIR_APPARMOR -eq 1 ]]; then
    echo "Requested action: repair detected AppArmor configurations"
fi
if [[ $CONFIGURE_APPARMOR -eq 1 ]]; then
    echo "Requested action: configure AppArmor after installation"
fi

if has_host_actions; then
    echo "Host actions requested:"
    [[ $ENABLE_X11_FORWARDING -eq 1 ]] && echo "  - Enable SSH X11 forwarding"
    [[ $DISABLE_X11_FORWARDING -eq 1 ]] && echo "  - Disable SSH X11 forwarding"
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

state_init
trap state_exit_trap EXIT

if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "$(confirmation_prompt)" confirmation
    [[ "$confirmation" =~ ^[Yy]([Ee][Ss])?$ ]] || die "Cancelled."
fi

if [[ $ENABLE_X11_FORWARDING -eq 1 ]]; then
    configure_ssh_x11_forwarding
    state_checkpoint ssh-x11-forwarding
fi
if [[ $DISABLE_X11_FORWARDING -eq 1 ]]; then
    disable_ssh_x11_forwarding
    state_checkpoint ssh-x11-forwarding-disabled
fi
if [[ $ENABLE_VNC -eq 1 ]]; then
    configure_x11vnc "$VNC_ALLOW" "$VNC_USER" "$VNC_PASSWORD_FILE" "$ALLOW_UNFIREWALLED_VNC" "$NON_INTERACTIVE"
    state_checkpoint attached-display-vnc
fi
if [[ $DISABLE_VNC -eq 1 ]]; then
    disable_x11vnc
    state_checkpoint attached-display-vnc-disabled
fi

if [[ $REPAIR_APPARMOR -eq 1 ]]; then
    repair_apparmor
    state_checkpoint apparmor-repair
fi

if selection_has videokiosk2; then
    provision_debian_kiosk_desktop "$KIOSK_USER"
fi

for service_id in "${SELECTED_SERVICES[@]}"; do
    run_service_installer "$service_id"
    state_checkpoint "service-$service_id"
done

if [[ $CONFIGURE_APPARMOR -eq 1 ]]; then
    repair_apparmor
    state_checkpoint apparmor-configure
fi

if [[ $DESKTOP_REBOOT_REQUIRED -eq 1 ]]; then
    info "Reboot this host to start the LightDM/Openbox kiosk session."
fi

info "Installation completed."