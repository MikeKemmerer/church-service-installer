#!/usr/bin/env bash

TUI_MENU_MODE="${TUI_MENU_MODE:-auto}"

tui_can_use_whiptail() {
    [[ "$TUI_MENU_MODE" != "text" && "$TUI_MENU_MODE" != "none" ]] || return 1
    [[ -t 0 && -t 1 ]] || return 1
    command -v whiptail >/dev/null 2>&1
}

tui_header() {
    cat <<'EOF'

   _____ _                     _      _____                 _
  / ____| |                   | |    / ____|               (_)
 | |    | |__  _   _ _ __ ___| |__ | (___   ___ _ ____   ___ _  ___ ___
 | |    | '_ \| | | | '__/ __| '_ \ \___ \ / _ \ '__\ \ / / | |/ __/ _ \
 | |____| | | | |_| | | | (__| | | |____) |  __/ |   \ V /| | | (_|  __/
  \_____|_| |_|\__,_|_|  \___|_| |_|_____/ \___|_|    \_/ |_|_|\___\___|

                         Guided Appliance Installer

EOF
}

tui_select_services() {
    local catalog_path="$1"
    local selection
    local -a options=()
    local -a selected=()
    local service_id service_name service_role

    while IFS=$'\t' read -r service_id service_name service_role; do
        options+=("$service_id" "$service_name - $service_role" "OFF")
    done < <(jq -r '.services[] | [.id, .name, .role] | @tsv' "$catalog_path")

    if tui_can_use_whiptail; then
        selection=$(whiptail --title "Church Service Installer" \
            --checklist "Select the services to configure on this host." 20 78 8 \
            "${options[@]}" 3>&1 1>&2 2>&3) || return 1
        selection="${selection//\"/}"
        read -r -a selected <<< "$selection"
        (IFS=,; printf '%s' "${selected[*]}")
        return 0
    fi

    tui_header >&2
    printf 'Available services:\n' >&2
    jq -r '.services[] | "  - \(.id): \(.name) (\(.role))"' "$catalog_path" >&2
    printf '\nEnter comma-separated service identifiers: ' >&2
    read -r selection || return 1
    printf '%s' "$selection"
}