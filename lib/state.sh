#!/usr/bin/env bash

STATE_ROOT="${STATE_ROOT:-/var/lib/church-service-installer/transactions}"
TRANSACTION_ID=""
TRANSACTION_DIR=""

state_init() {
    local timestamp

    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    TRANSACTION_ID="${timestamp}-$$"
    TRANSACTION_DIR="$STATE_ROOT/$TRANSACTION_ID"
    install -d -m 700 "$TRANSACTION_DIR/checkpoints" "$TRANSACTION_DIR/backups"
    printf 'running\n' > "$TRANSACTION_DIR/status"
    state_event "transaction started"
}

state_event() {
    [[ -n "$TRANSACTION_DIR" ]] || return 0
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" \
        >> "$TRANSACTION_DIR/events.log"
}

state_checkpoint() {
    local checkpoint="$1"

    [[ "$checkpoint" =~ ^[a-z0-9-]+$ ]] || die "Invalid transaction checkpoint: $checkpoint"
    [[ -n "$TRANSACTION_DIR" ]] || die "Transaction state is not initialized."
    : > "$TRANSACTION_DIR/checkpoints/$checkpoint"
    state_event "checkpoint complete: $checkpoint"
}

state_backup_file() {
    local source_path="$1"
    local backup_name="$2"

    [[ "$backup_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid backup name: $backup_name"
    [[ -e "$source_path" ]] || return 0
    cp -a "$source_path" "$TRANSACTION_DIR/backups/$backup_name"
    state_event "backed up: $source_path"
}

state_finish() {
    local result="$1"

    [[ -n "$TRANSACTION_DIR" ]] || return 0
    printf '%s\n' "$result" > "$TRANSACTION_DIR/status"
    state_event "transaction $result"
}

state_exit_trap() {
    local exit_status=$?

    if [[ -n "$TRANSACTION_DIR" ]]; then
        if [[ $exit_status -eq 0 ]]; then
            state_finish completed
        else
            state_finish failed
        fi
    fi
    return "$exit_status"
}