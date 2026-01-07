#!/usr/bin/env bash

# ==============================
# Pipeline main script
# ==============================

set -Eeuo pipefail

# -------- CONFIG --------
WORKFLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THERMAL_SCRIPT="${WORKFLOW_DIR}/thermal.sh"
THERMAL_LOCK="${WORKFLOW_DIR}/thermal.lock"

# -------- LOGGING --------
log() {
    echo "[INFO ] $*"
}

warn() {
    echo "[WARN ] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
}

# -------- SAFETY CHECKS --------
if [[ ! -x "$THERMAL_SCRIPT" ]]; then
    error "thermal.sh not executable: $THERMAL_SCRIPT"
    error "Fix with: chmod +x scripts/thermal.sh && git add --chmod=+x scripts/thermal.sh"
    exit 1
fi

# -------- THERMAL HELPERS --------

check_thermal_before_pipeline() {
    log "Running thermal pre-check..."

    if "$THERMAL_SCRIPT" is-critical; then
        error "Temperature CRITICAL — aborting pipeline"
        return 1
    fi

    log "Thermal status SAFE"
    return 0
}

should_skip_pipeline() {
    # Skip if device is cooling down
    if [[ -f "$THERMAL_LOCK" ]]; then
        warn "Thermal lock detected ($THERMAL_LOCK)"
        return 0
    fi

    # Skip if temperature is critical
    if "$THERMAL_SCRIPT" is-critical; then
        warn "Temperature critical"
        return 0
    fi

    return 1
}

# -------- PIPELINE STEPS --------

step_prepare() {
    log "Preparing environment..."
    sleep 1
}

step_build() {
    log "Building project..."
    sleep 1
}

step_test() {
    log "Running tests..."
    sleep 1
}

step_deploy() {
    log "Deploying..."
    sleep 1
}

# -------- MAIN PIPELINE --------

execute_pipeline() {
    log "Starting pipeline"

    if should_skip_pipeline; then
        warn "Pipeline skipped (cooldown or thermal critical)"
        return 1
    fi

    if ! check_thermal_before_pipeline; then
        error "Pipeline aborted - thermal check failed"
        return 1
    fi

    step_prepare
    step_build
    step_test
    step_deploy

    log "Pipeline completed successfully"
}

# -------- ENTRYPOINT --------

main() {
    execute_pipeline
}

main "$@"
