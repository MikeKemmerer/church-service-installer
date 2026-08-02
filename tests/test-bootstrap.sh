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
assert_contains "--repair-apparmor" "$help_output"
assert_contains "--configure-apparmor" "$help_output"
assert_contains "--kiosk-alsa-audio-device" "$help_output"

list_output=$(bash "$PROJECT_DIR/install.sh" --list-services)
assert_contains "church-calendar" "$list_output"
assert_contains "church-monitoring-client" "$list_output"

bootstrap_test_root=$(mktemp -d)
cat > "$bootstrap_test_root/jq" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/jq "$@"
EOF
cat > "$bootstrap_test_root/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$bootstrap_test_root/whiptail" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$bootstrap_test_root/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOOTSTRAP_LOG"
if [[ "$1" == "install" ]]; then
    cp /usr/bin/jq "$BOOTSTRAP_TEST_ROOT/jq"
    chmod 755 "$BOOTSTRAP_TEST_ROOT/jq"
fi
EOF
chmod 755 "$bootstrap_test_root/jq" "$bootstrap_test_root/git" "$bootstrap_test_root/whiptail" "$bootstrap_test_root/apt-get"
bootstrap_log="$bootstrap_test_root/apt.log"
PATH="$bootstrap_test_root:/usr/bin:/bin" BOOTSTRAP_APT_GET=apt-get BOOTSTRAP_LOG="$bootstrap_log" BOOTSTRAP_TEST_ROOT="$bootstrap_test_root" \
    bash "$PROJECT_DIR/install.sh" --list-services >/dev/null
test ! -e "$bootstrap_log"
PATH="$bootstrap_test_root:/usr/bin:/bin" BOOTSTRAP_APT_GET=apt-get BOOTSTRAP_FORCE_MISSING=jq BOOTSTRAP_LOG="$bootstrap_log" BOOTSTRAP_TEST_ROOT="$bootstrap_test_root" \
    bash "$PROJECT_DIR/install.sh" --list-services --yes >/dev/null
grep -qx 'update' "$bootstrap_log"
grep -qx 'install -y jq' "$bootstrap_log"
rm -f "$bootstrap_test_root/git" "$bootstrap_test_root/whiptail" "$bootstrap_test_root/apt-get" "$bootstrap_log"
rmdir "$bootstrap_test_root"

state_test_root=$(mktemp -d)
STATE_ROOT="$state_test_root" bash -c '
    source "$1/lib/common.sh"
    source "$1/lib/state.sh"
    state_init
    state_checkpoint preflight
    state_finish completed
    test -f "$TRANSACTION_DIR/checkpoints/preflight"
    test "$(cat "$TRANSACTION_DIR/status")" = completed
    for path in "$TRANSACTION_DIR/checkpoints/preflight" "$TRANSACTION_DIR/events.log" "$TRANSACTION_DIR/status"; do
        unlink "$path"
    done
    rmdir "$TRANSACTION_DIR/checkpoints" "$TRANSACTION_DIR/backups" "$TRANSACTION_DIR"
' _ "$PROJECT_DIR"
rmdir "$state_test_root"

text_menu_output=$(printf 'cameras\n' | OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --menu-mode text --dry-run 2>&1)
assert_contains "Guided Appliance Installer" "$text_menu_output"
assert_contains "Camera Control [cameras]" "$text_menu_output"

dry_run_output=$(OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --services church-calendar,cameras --calendar-user nobody --dry-run)
assert_contains "Platform: Debian 12" "$dry_run_output"
assert_contains "Dry run complete" "$dry_run_output"

repair_dry_run=$(OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --repair-apparmor --dry-run)
assert_contains "Requested action: repair detected AppArmor configurations" "$repair_dry_run"
assert_contains "Dry run complete" "$repair_dry_run"

configure_dry_run=$(OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --services cameras --configure-apparmor --dry-run)
assert_contains "Requested action: configure AppArmor after installation" "$configure_dry_run"
assert_contains "Dry run complete" "$configure_dry_run"

if OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --services cameras --repair-apparmor --dry-run \
    >/dev/null 2>&1; then
    echo "Expected combined service selection and AppArmor repair to fail" >&2
    exit 1
fi

if OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --configure-apparmor --dry-run \
    >/dev/null 2>&1; then
    echo "Expected AppArmor configuration without services to fail" >&2
    exit 1
fi

if OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --services videokiosk2 --kiosk-user root --dry-run \
    >/dev/null 2>&1; then
    echo "Expected root kiosk user to fail" >&2
    exit 1
fi

if OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --services videokiosk2 --non-interactive --dry-run \
    >/dev/null 2>&1; then
    echo "Expected non-interactive kiosk installation without a user to fail" >&2
    exit 1
fi

kiosk_dry_run=$(OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --services videokiosk2 --kiosk-user nobody \
        --kiosk-install-dir /home/nobody/videokiosk2 \
    --kiosk-config-dir /home/nobody/videokiosk2 \
    --kiosk-audio-output alsa \
    --kiosk-alsa-audio-device hdmi:CARD=PCH,DEV=0 --dry-run)
assert_contains "Kiosk scripts: /home/nobody/videokiosk2" "$kiosk_dry_run"
assert_contains "Kiosk configuration: /home/nobody/videokiosk2" "$kiosk_dry_run"
assert_contains "Kiosk audio output: alsa" "$kiosk_dry_run"
assert_contains "Kiosk ALSA audio device: hdmi:CARD=PCH,DEV=0" "$kiosk_dry_run"

if OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --services church-calendar --calendar-user root --dry-run \
    >/dev/null 2>&1; then
    echo "Expected root calendar user to fail" >&2
    exit 1
fi

if OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --services church-calendar --non-interactive --dry-run \
    >/dev/null 2>&1; then
    echo "Expected non-interactive calendar installation without a user to fail" >&2
    exit 1
fi

if OS_RELEASE_FILE="$FIXTURE_DIR/debian-12-os-release" \
    bash "$PROJECT_DIR/install.sh" --services church-monitoring-server,church-monitoring-client --dry-run \
    >/dev/null 2>&1; then
    echo "Expected monitoring server/client conflict to fail" >&2
    exit 1
fi

echo "Bootstrap tests passed."