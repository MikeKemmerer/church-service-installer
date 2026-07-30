#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"

assert_contains() {
    local expected="$1"
    local output="$2"
    [[ "$output" == *"$expected"* ]] || {
        printf 'Expected output to contain: %s\nActual output:\n%s\n' "$expected" "$output" >&2
        exit 1
    }
}

help_output=$(bash "$PROJECT_DIR/install.sh" --help)
assert_contains "Usage: sudo ./install.sh" "$help_output"

list_output=$(bash "$PROJECT_DIR/install.sh" --list-services)
assert_contains "church-calendar" "$list_output"
assert_contains "church-monitoring-client" "$list_output"

dry_run_output=$(OS_RELEASE_FILE="$FIXTURE_DIR/ubuntu-26.04-os-release" \
    bash "$PROJECT_DIR/install.sh" --services church-calendar,cameras --calendar-user nobody --dry-run)
assert_contains "Platform: Ubuntu 26.04" "$dry_run_output"
assert_contains "Dry run complete" "$dry_run_output"

if OS_RELEASE_FILE="$FIXTURE_DIR/ubuntu-26.04-os-release" \
    bash "$PROJECT_DIR/install.sh" --services videokiosk2 --kiosk-user root --dry-run \
    >/dev/null 2>&1; then
    echo "Expected root kiosk user to fail" >&2
    exit 1
fi

if OS_RELEASE_FILE="$FIXTURE_DIR/ubuntu-26.04-os-release" \
    bash "$PROJECT_DIR/install.sh" --services videokiosk2 --non-interactive --dry-run \
    >/dev/null 2>&1; then
    echo "Expected non-interactive kiosk installation without a user to fail" >&2
    exit 1
fi

kiosk_dry_run=$(OS_RELEASE_FILE="$FIXTURE_DIR/ubuntu-26.04-os-release" \
    bash "$PROJECT_DIR/install.sh" --services videokiosk2 --kiosk-user nobody \
        --kiosk-install-dir /home/nobody/videokiosk2 \
        --kiosk-config-dir /home/nobody/videokiosk2 --dry-run)
assert_contains "Kiosk scripts: /home/nobody/videokiosk2" "$kiosk_dry_run"
assert_contains "Kiosk configuration: /home/nobody/videokiosk2" "$kiosk_dry_run"

if OS_RELEASE_FILE="$FIXTURE_DIR/ubuntu-26.04-os-release" \
    bash "$PROJECT_DIR/install.sh" --services church-calendar --calendar-user root --dry-run \
    >/dev/null 2>&1; then
    echo "Expected root calendar user to fail" >&2
    exit 1
fi

if OS_RELEASE_FILE="$FIXTURE_DIR/ubuntu-26.04-os-release" \
    bash "$PROJECT_DIR/install.sh" --services church-calendar --non-interactive --dry-run \
    >/dev/null 2>&1; then
    echo "Expected non-interactive calendar installation without a user to fail" >&2
    exit 1
fi

if OS_RELEASE_FILE="$FIXTURE_DIR/ubuntu-26.04-os-release" \
    bash "$PROJECT_DIR/install.sh" --services church-monitoring-server,church-monitoring-client --dry-run \
    >/dev/null 2>&1; then
    echo "Expected monitoring server/client conflict to fail" >&2
    exit 1
fi

echo "Bootstrap tests passed."