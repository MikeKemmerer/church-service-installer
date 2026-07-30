#!/usr/bin/env bash

info() {
    printf '==> %s\n' "$*"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

checkout_trusted_repository() {
    local expected_repository="$1"
    local branch="$2"
    local checkout_dir="$3"
    local actual_repository

    require_command git
    mkdir -p "$(dirname "$checkout_dir")"

    if [[ -d "$checkout_dir/.git" ]]; then
        actual_repository=$(git -C "$checkout_dir" remote get-url origin)
        [[ "$actual_repository" == "$expected_repository" ]] || \
            die "Existing checkout origin does not match the trusted catalog: $checkout_dir"
        git -C "$checkout_dir" fetch --depth 1 origin "$branch"
        git -C "$checkout_dir" checkout --detach "origin/$branch"
    elif [[ -e "$checkout_dir" ]]; then
        die "Checkout path exists but is not a Git checkout: $checkout_dir"
    else
        git clone --depth 1 --branch "$branch" "$expected_repository" "$checkout_dir"
    fi
}