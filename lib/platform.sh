#!/usr/bin/env bash

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
PLATFORM_ID=""
PLATFORM_VERSION=""
PLATFORM_ARCH=""
PLATFORM_LABEL=""

detect_platform() {
    [[ -r "$OS_RELEASE_FILE" ]] || die "Cannot read OS metadata: $OS_RELEASE_FILE"

    # shellcheck disable=SC1090
    source "$OS_RELEASE_FILE"
    PLATFORM_ID="${ID:-unknown}"
    PLATFORM_VERSION="${VERSION_ID:-unknown}"
    PLATFORM_ARCH="$(uname -m)"
    PLATFORM_ID="${PLATFORM_ID//$'\r'/}"
    PLATFORM_VERSION="${PLATFORM_VERSION//$'\r'/}"

    case "$PLATFORM_ID" in
        raspbian)
            PLATFORM_LABEL="Raspberry Pi OS $PLATFORM_VERSION"
            ;;
        debian)
            PLATFORM_LABEL="Debian $PLATFORM_VERSION"
            ;;
        *)
            PLATFORM_LABEL="${PRETTY_NAME:-$PLATFORM_ID $PLATFORM_VERSION}"
            ;;
    esac
}

validate_supported_platform() {
    case "$PLATFORM_ID" in
        raspbian)
            return 0
            ;;
        debian)
            [[ "$PLATFORM_VERSION" =~ ^[0-9]+$ && "$PLATFORM_VERSION" -ge 12 ]] || \
                die "Debian $PLATFORM_VERSION is unsupported; Debian 12 or newer is required."
            return 0
            ;;
        *)
            die "Unsupported operating system: $PLATFORM_LABEL. Use Debian 12 or newer, or Raspberry Pi OS."
            ;;
    esac
}

validate_selected_services_for_platform() {
    local catalog_path="$1"
    shift
    local service_id supported

    for service_id in "$@"; do
        supported=$(jq -r --arg id "$service_id" --arg platform "$PLATFORM_ID" \
            '.services[] | select(.id == $id) | (.platforms | index($platform) != null)' \
            "$catalog_path")
        [[ "$supported" == "true" ]] || \
            die "$service_id is not supported on $PLATFORM_LABEL."
    done
}