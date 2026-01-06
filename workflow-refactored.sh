#!/data/data/com.termux/files/usr/bin/bash
# Termux 24/7 Auto-Restart Workflow - REFACTORED
# Wersja: 2.0 - Modularny, łatwy w utrzymaniu
# 
# Struktura:
#   workflow.sh          - Main orchestrator (ten plik)
#   scripts/logging.sh   - Logowanie, kolory, rotacja
#   scripts/secrets.sh   - Encrypted storage
#   scripts/telegram.sh  - Powiadomienia, progress bar
#   scripts/git-config.sh - Git auth, auto-pull, change detection
#   scripts/rclone.sh    - Google Drive sync
#   scripts/pipeline.sh  - Photo processing pipeline

# ============================================================================
# INITIALIZATION
# ============================================================================

# Dynamic directory detection
WORKFLOW_DIR="$(dirname "$(realpath "$0")")"
SCRIPTS_DIR="$WORKFLOW_DIR/scripts"

# Logging files
LOG_FILE="$WORKFLOW_DIR/logs/workflow.log"
ERROR_LOG="$WORKFLOW_DIR/logs/error.log"

# Config files
CONFIG_FILE="$WORKFLOW_DIR/config.env"
PID_FILE="$WORKFLOW_DIR/workflow.pid"
LOCK_FILE="$WORKFLOW_DIR/workflow.lock"
STATE_FILE="$WORKFLOW_DIR/state.json"

# Load all modules
for module in logging secrets telegram git-config rclone pipeline; do
    source "$SCRIPTS_DIR/${module}.sh" || {
        echo "ERROR: Cannot load module: ${module}.sh"
        exit 1
    }
done

# Load config
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# ============================================================================
# CORE FUNCTIONS - DAEMON MANAGEMENT
# ============================================================================

start_daemon() {
    log "=== Starting Workflow Daemon ==="
    
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if ps -p "$old_pid" > /dev/null 2>&1; then
            warn "Daemon already running (PID: $old_pid)"
            return 1
        else
            warn "Stale PID file found - removing"
            rm -f "$PID_FILE"
        fi
    fi
    
    # Start in background
    nohup bash "$0" run > /dev/null 2>&1 &
    local daemon_pid=$!
    echo $daemon_pid > "$PID_FILE"
    
    log "✅ Daemon started (PID: $daemon_pid)"
    sleep 1
    
    # Verify it's running
    if ps -p "$daemon_pid" > /dev/null 2>&1; then
        log "✓ Daemon verified running"
        return 0
    else
        error "Daemon failed to start"
        return 1
    fi
}

stop_workflow() {
    if [ ! -f "$PID_FILE" ]; then
        warn "No PID file found"
        return 1
    fi
    
    local pid=$(cat "$PID_FILE")
    
    if ! ps -p "$pid" > /dev/null 2>&1; then
        warn "Process not running (stale PID: $pid)"
        rm -f "$PID_FILE"
        return 1
    fi
    
    log "Stopping workflow (PID: $pid)..."
    kill "$pid" 2>/dev/null
    sleep 2
    
    if ps -p "$pid" > /dev/null 2>&1; then
        warn "Force killing..."
        kill -9 "$pid" 2>/dev/null
        sleep 1
    fi
    
    rm -f "$PID_FILE" "$LOCK_FILE"
    log "✓ Workflow stopped"
}

status_workflow() {
    if [ ! -f "$PID_FILE" ]; then
        echo "Status: NOT RUNNING (no PID file)"
        return 1
    fi
    
    local pid=$(cat "$PID_FILE")
    
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "Status: RUNNING (PID: $pid)"
        
        # Show uptime
        local start_time=$(stat -f%B "$PID_FILE" 2>/dev/null || stat -c%Y "$PID_FILE" 2>/dev/null)
        local current_time=$(date +%s)
        local uptime=$((current_time - start_time))
        
        echo "Uptime: $((uptime / 3600))h $((uptime % 3600 / 60))m"
        return 0
    else
        echo "Status: NOT RUNNING (stale PID: $pid)"
        rm -f "$PID_FILE"
        return 1
    fi
}

# ============================================================================
# MAIN WORKFLOW LOOP
# ============================================================================

HEALTHCHECK_INTERVAL=60
RESTART_DELAY=5

run_workflow() {
    local run_count=0
    local error_count=0
    
    log "=== Workflow Started (PID: $$) ==="
    echo $$ > "$PID_FILE"
    
    # Load secrets on startup
    if [ -f "$SECRETS_FILE" ]; then
        log "Loading encrypted secrets..."
        if ! load_secrets; then
            warn "Cannot load secrets - continuing without them"
        fi
    fi
    
    # Startup notification
    send_telegram "🚀 Workflow started
PID: $$
Time: $(date '+%Y-%m-%d %H:%M:%S')" true
    
    # Main loop
    while true; do
        rotate_logs
        
        # Try to acquire lock
        if [ -f "$LOCK_FILE" ]; then
            debug "Lock file exists - skipping execution"
            sleep "$HEALTHCHECK_INTERVAL"
            continue
        fi
        
        touch "$LOCK_FILE"
        
        # Execute pipeline
        local exec_start=$(date +%s)
        
        if execute_pipeline; then
            run_count=$((run_count + 1))
            log "Pipeline execution #$run_count completed successfully"
        else
            error_count=$((error_count + 1))
            error "Pipeline execution #$run_count failed (error count: $error_count)"
        fi
        
        local exec_end=$(date +%s)
        local exec_time=$((exec_end - exec_start))
        debug "Execution time: ${exec_time}s"
        
        rm -f "$LOCK_FILE"
        
        # Auto-update check (every 24 hours)
        check_and_run_auto_update
        
        # Health check interval
        sleep "$HEALTHCHECK_INTERVAL"
    done
}

# ============================================================================
# AUTO-UPDATE MECHANISM
# ============================================================================

check_and_run_auto_update() {
    local last_update_file="$WORKFLOW_DIR/.last_update"
    local update_interval=86400  # 24 hours
    
    # Check if last_update exists
    if [ ! -f "$last_update_file" ]; then
        echo $(date +%s) > "$last_update_file"
        return 0
    fi
    
    local last_update=$(cat "$last_update_file")
    local current_time=$(date +%s)
    local time_since=$((current_time - last_update))
    
    # If 24h not elapsed, skip
    if [ $time_since -lt $update_interval ]; then
        debug "Auto-update: next check in $((update_interval - time_since))s"
        return 0
    fi
    
    # Update available - run in background with timeout
    log "Running auto-update in background (timeout: 10min)..."
    
    timeout 600 bash "$WORKFLOW_DIR/update.sh" > /dev/null 2>&1 &
    
    # Update timestamp
    echo $(date +%s) > "$last_update_file"
}

# ============================================================================
# SETUP & INITIALIZATION
# ============================================================================

setup_environment() {
    section "INITIAL SETUP"
    
    # Create directories
    mkdir -p "$WORKFLOW_DIR/logs" 2>/dev/null || true
    mkdir -p "$WORKFLOW_DIR/data" 2>/dev/null || true
    mkdir -p "$SCRIPTS_DIR" 2>/dev/null || true
    
    # Initialize logging
    log "✓ Directories created"
    
    # Termux-specific
    if [ -d "/data/data/com.termux" ]; then
        log "Running on Termux - setting up wake lock..."
        termux-wake-lock 2>/dev/null || warn "termux-wake-lock not available"
    fi
    
    # Setup Telegram
    setup_telegram
    
    # Setup Git
    setup_git_config
    
    # Setup Secrets
    if [ ! -f "$SECRETS_FILE" ]; then
        init_secrets
    fi
    
    # Auto-chmod all .sh files
    log "Setting permissions for shell scripts..."
    find "$WORKFLOW_DIR" -maxdepth 2 -name "*.sh" -type f -exec chmod 755 {} \; 2>/dev/null
    find "$SCRIPTS_DIR" -name "*.sh" -type f -exec chmod 755 {} \; 2>/dev/null
    log "✅ Permissions set (755: rwxr-xr-x)"
    
    # Initialize thermal monitoring daemon
    log "Starting thermal monitoring daemon..."
    if bash "$SCRIPTS_DIR/thermal.sh" start; then
        log "✓ Thermal daemon started"
    else
        warn "Thermal daemon failed to start - continuing without thermal monitoring"
    fi
    
    # Test connectivity
    log "Testing Telegram connectivity..."
    if test_telegram; then
        log "✓ Telegram configured and working"
    else
        warn "Telegram test failed - check config"
    fi
    
    section "SETUP COMPLETE"
    log "Ready to start: $0 start"
}

# ============================================================================
# MENU/COMMANDS
# ============================================================================

show_help() {
    cat << EOF
Termux 24/7 Auto-Restart Workflow
==================================

Usage: $0 {command}

Core Commands:
  setup              Initial environment setup
  start              Start daemon (background)
  stop               Stop running daemon
  restart            Restart daemon
  status             Show daemon status
  run                Run workflow (foreground)
  logs               Follow logs in real-time

Update & Maintenance:
  update-logs        Show recent update logs

Telegram:
  telegram-test      Send test notification
  telegram-config    Configure Telegram
  send-logs          Send logs to Telegram

Encrypted Secrets:
  secrets-init       Initialize encrypted secrets
  secrets-edit       Edit encrypted secrets
  secrets-load       Load secrets to environment

Git:
  git-status         Show git status
  git-pull           Manual git pull

Thermal Management (Independent Daemon):
  thermal-start      Start thermal monitoring daemon
  thermal-stop       Stop thermal monitoring daemon
  thermal-restart    Restart thermal monitoring daemon
  thermal-status     Show device temperature + status
  thermal-logs       View temperature logs (default: last 50)
  thermal-diags      Run thermal system diagnostics
  emergency-cooldown Force emergency cooldown mode

Pipeline:
  pipeline-dry-run   Test pipeline without changes
  check-deps         Check pipeline dependencies

Utilities:
  show-config        Display configuration
  show-errors        Show recent errors
  help               This message

Examples:
  $0 setup           # First time setup
  $0 start           # Start background daemon
  $0 logs            # Follow logs
  $0 thermal-status  # Check device temperature

EOF
}

# ============================================================================
# MAIN COMMAND HANDLER
# ============================================================================

case "${1:-menu}" in
    setup)
        setup_environment
        log "Setup complete!"
        ;;
    
    start)
        start_daemon
        ;;
    
    run)
        run_workflow
        ;;
    
    stop)
        stop_workflow
        ;;
    
    restart)
        stop_workflow
        sleep 2
        start_daemon
        ;;
    
    status)
        status_workflow
        ;;
    
    logs)
        tail -f "$LOG_FILE"
        ;;
    
    telegram-test)
        test_telegram
        ;;
    
    telegram-config)
        setup_telegram
        ;;
    
    send-logs)
        log "Sending logs to Telegram..."
        send_telegram_file "$LOG_FILE" "📋 Workflow logs"
        send_telegram_file "$ERROR_LOG" "⚠️  Error logs"
        ;;
    
    update-logs)
        if [ -f "$WORKFLOW_DIR/logs/update.log" ]; then
            echo ""
            echo "=== Recent update logs ==="
            echo ""
            tail -n 50 "$WORKFLOW_DIR/logs/update.log"
            echo ""
        else
            echo "No update logs yet (no updates run)"
        fi
        ;;
    
    secrets-init)
        init_secrets
        ;;
    
    secrets-edit)
        edit_secrets
        ;;
    
    secrets-load)
        load_secrets
        ;;
    
    git-status)
        show_git_status
        ;;
    
    git-pull)
        auto_git_pull
        ;;
    
    thermal-start)
        bash "$SCRIPTS_DIR/thermal.sh" start
        ;;
    
    thermal-stop)
        bash "$SCRIPTS_DIR/thermal.sh" stop
        ;;
    
    thermal-restart)
        bash "$SCRIPTS_DIR/thermal.sh" restart
        ;;
    
    thermal-status)
        bash "$SCRIPTS_DIR/thermal.sh" show-status
        ;;
    
    thermal-logs)
        bash "$SCRIPTS_DIR/thermal.sh" show-logs "${2:-50}"
        ;;
    
    thermal-diags)
        bash "$SCRIPTS_DIR/thermal.sh" diags
        ;;
    
    emergency-cooldown)
        bash "$SCRIPTS_DIR/thermal.sh" emergency-cooldown
        ;;
    
    pipeline-dry-run)
        pipeline_dry_run
        ;;
    
    check-deps)
        check_pipeline_dependencies
        ;;
    
    show-config)
        section "Configuration"
        cat "$CONFIG_FILE"
        echo ""
        ;;
    
    show-errors)
        show_recent_errors 30
        ;;
    
    help|--help|-h)
        show_help
        ;;
    
    *)
        show_help
        ;;
esac
