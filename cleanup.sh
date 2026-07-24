#!/usr/bin/env bash

set -Eeuo pipefail

XRAY_DIR="/etc/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"
XRAY_SERVICE_NAME="xray"
APT_ARCHIVE_CONF="/etc/apt/apt.conf.d/99archive"

DO_APPLY=0
PURGE_DEPENDENCIES=0

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  bash cleanup.sh [--yes] [--purge-dependencies]

Options:
  --yes                 Actually perform cleanup. Without this, only prints planned actions.
  --purge-dependencies  Also purge packages installed by deploy.sh. Use with care.
  -h, --help            Show this help.

This removes artifacts created by deploy.sh:
  - xray systemd service
  - /etc/xray
  - /tmp/xray-install.*, /tmp/xray.zip, and common downloaded helper scripts
  - /etc/apt/apt.conf.d/99archive
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes)
                DO_APPLY=1
                ;;
            --purge-dependencies)
                PURGE_DEPENDENCIES=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
}

require_root_when_apply() {
    if [ "$DO_APPLY" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
        die "Please run this script as root when using --yes."
    fi
}

run() {
    if [ "$DO_APPLY" -eq 1 ]; then
        "$@"
    else
        printf '[DRY-RUN] '
        printf '%q ' "$@"
        printf '\n'
    fi
}

run_shell() {
    local description="$1"
    shift

    if [ "$DO_APPLY" -eq 1 ]; then
        "$@"
    else
        printf '[DRY-RUN] %s\n' "$description"
    fi
}

run_best_effort() {
    if [ "$DO_APPLY" -eq 1 ]; then
        "$@" || warn "Command failed, continuing: $*"
    else
        printf '[DRY-RUN] '
        printf '%q ' "$@"
        printf '\n'
    fi
}

systemctl_available() {
    command -v systemctl >/dev/null 2>&1
}

service_exists() {
    if ! systemctl_available; then
        return 1
    fi

    systemctl list-unit-files --type=service --no-legend 2>/dev/null |
        awk '{print $1}' |
        grep -Fxq "${XRAY_SERVICE_NAME}.service"
}

cleanup_systemd_service() {
    if ! service_exists; then
        if ! systemctl_available; then
            warn "systemctl is not available; removing service file only."
        else
            warn "xray service is not installed; removing service file only."
        fi
    else
        run_best_effort systemctl stop "$XRAY_SERVICE_NAME"
        run_best_effort systemctl disable "$XRAY_SERVICE_NAME"
    fi

    if [ -e "$XRAY_SERVICE" ] || [ "$DO_APPLY" -eq 0 ]; then
        run rm -f "$XRAY_SERVICE"
    fi

    if systemctl_available; then
        run_best_effort systemctl daemon-reload
        run_best_effort systemctl reset-failed "$XRAY_SERVICE_NAME"
    fi
}

cleanup_xray_processes() {
    local pid

    if command -v pgrep >/dev/null 2>&1; then
        while read -r pid; do
            [ -n "$pid" ] || continue
            [ "$pid" = "$$" ] && continue
            run_best_effort kill "$pid"
        done < <(pgrep -f '/etc/xray/xray|xray run -config /etc/xray/config.json' || true)
    fi
}

cleanup_xray_files() {
    if [ -d "$XRAY_DIR" ] || [ "$DO_APPLY" -eq 0 ]; then
        run rm -rf "$XRAY_DIR"
    fi

    run_shell "Remove leftover Xray temp files under /tmp" \
        find /tmp -maxdepth 1 \( \
            -type d -name 'xray-install.*' -o \
            -type f -name 'xray.zip' -o \
            -type f -name 'xray-deploy.sh' -o \
            -type f -name 'xray-cleanup.sh' \
        \) -exec rm -rf -- {} +

    if [ -e /tmp/xray.zip ] || [ "$DO_APPLY" -eq 0 ]; then
        run rm -f /tmp/xray.zip
    fi
}

purge_dependencies() {
    if [ "$PURGE_DEPENDENCIES" -ne 1 ]; then
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        warn "apt-get is not available; skipping dependency purge."
        return 0
    fi

    warn "Purging packages may remove tools that were installed before deploy.sh."
    run apt-get purge -y wget curl unzip iproute2
    run apt-get autoremove -y
}

main() {
    parse_args "$@"
    require_root_when_apply

    if [ "$DO_APPLY" -ne 1 ]; then
        warn "Dry-run mode. Re-run with --yes to actually remove files and services."
    fi

    cleanup_systemd_service
    cleanup_xray_processes
    cleanup_xray_files
    if [ -f "$APT_ARCHIVE_CONF" ] || [ "$DO_APPLY" -eq 0 ]; then
        run rm -f "$APT_ARCHIVE_CONF"
    fi
    purge_dependencies

    if [ "$DO_APPLY" -eq 1 ]; then
        log "Cleanup complete."
    else
        log "Dry-run complete."
    fi
}

main "$@"
