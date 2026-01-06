#!/data/data/com.termux/files/usr/bin/bash
# Thermal Monitoring Daemon - INDEPENDENT
# Niezależny skrypt do monitorowania temperatury urządzenia
# Uruchamia się w tle, loguje temperaturę, raportuje status
# Wysyła notyfikacje Telegram dla istotnych zdarzeń (BEZ pingów)

# ============================================================================
# INITIALIZATION
# ============================================================================

WORKFLOW_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
SCRIPTS_DIR="$WORKFLOW_DIR/scripts"
LOG_FILE="$WORKFLOW_DIR/logs/thermal.log"
THERMAL_PID_FILE="$WORKFLOW_DIR/thermal.pid"
THERMAL_STATE_FILE="$WORKFLOW_DIR/thermal.state"
THERMAL_LOCK="$WORKFLOW_DIR/thermal.lock"
EVENT_LOG_FILE="$WORKFLOW_DIR/logs/events.log"

# Thermal thresholds (°C)
TEMP_SAFE=35
TEMP_WARM=40
TEMP_HOT=50
TEMP_CRITICAL=60

# Monitoring interval (seconds)
MONITOR_INTERVAL=60

# Rate limiting for Telegram notifications (seconds)
TELEGRAM_RATE_LIMIT=300  # 5 minutes between same event types
LAST_TELEGRAM_HOT=$(date +%s)
LAST_TELEGRAM_CRITICAL=$(date +%s)

# ============================================================================
# LOGGING & OUTPUT
# ============================================================================

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" >> "$LOG_FILE"
}

debug() {
    [ "$DEBUG_MODE" = "true" ] && echo "[DEBUG] $*" >&2
}

# ============================================================================
# EVENT LOGGING & NOTIFICATIONS
# ============================================================================

log_event() {
    # Log important events to events.log
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$EVENT_LOG_FILE"
}

send_telegram_notification() {
    # Send Telegram notification without pings
    # Usage: send_telegram_notification "message"
    
    local message=$1
    
    # Check if Telegram is configured
    if [ ! -f "$WORKFLOW_DIR/config.env" ]; then
        debug "config.env not found - skipping Telegram notification"
        return 1
    fi
    
    # Source config to get Telegram vars
    source "$WORKFLOW_DIR/config.env" 2>/dev/null || return 1
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        debug "Telegram not configured - skipping notification"
        return 1
    fi
    
    # Send message without pings (no @ mentions)
    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" \
        > /dev/null 2>&1
    
    debug "Telegram notification sent: ${message:0:50}..."
}

notify_critical_temp() {
    local temp=$1
    local current_time=$(date +%s)
    local time_diff=$((current_time - LAST_TELEGRAM_CRITICAL))
    
    # Rate limiting: max 1 notification per 5 minutes
    if [ $time_diff -lt $TELEGRAM_RATE_LIMIT ]; then
        debug "CRITICAL notification rate limited (last: ${time_diff}s ago)"
        return 0
    fi
    
    LAST_TELEGRAM_CRITICAL=$current_time
    
    log_event "CRITICAL" "Temperature reached CRITICAL: ${temp}°C"
    
    local message="🔴 <b>CRITICAL TEMPERATURE</b>
Temperature: <b>${temp}°C</b>
Status: <b>Emergency Cooldown Activated</b>
Time: $(date '+%H:%M:%S')"
    
    send_telegram_notification "$message"
}

notify_hot_temp() {
    local temp=$1
    local current_time=$(date +%s)
    local time_diff=$((current_time - LAST_TELEGRAM_HOT))
    
    # Rate limiting: max 1 notification per 5 minutes
    if [ $time_diff -lt $TELEGRAM_RATE_LIMIT ]; then
        debug "HOT notification rate limited (last: ${time_diff}s ago)"
        return 0
    fi
    
    LAST_TELEGRAM_HOT=$current_time
    
    log_event "WARNING" "Temperature is HOT: ${temp}°C"
    
    local message="🔥 <b>HIGH TEMPERATURE WARNING</b>
Temperature: <b>${temp}°C</b>
Status: <b>Reducing Operations</b>
Time: $(date '+%H:%M:%S')"
    
    send_telegram_notification "$message"
}

notify_event() {
    # Generic event notification
    local level=$1
    local message=$2
    
    log_event "$level" "$message"
    
    # Only send Telegram for CRITICAL events
    if [ "$level" = "CRITICAL" ]; then
        local telegram_msg="⚠️ <b>$level EVENT</b>
$message
Time: $(date '+%H:%M:%S')"
        
        send_telegram_notification "$telegram_msg"
    fi
}

# ============================================================================
# THERMAL ZONE DETECTION & READING
# ============================================================================

find_thermal_zones() {
    local zones=()
    
    # Try multiple paths for thermal zones
    if [ -d "/sys/class/thermal" ]; then
        while IFS= read -r zone; do
            if [ -f "$zone/temp" ]; then
                zones+=("$zone")
            fi
        done < <(find /sys/class/thermal -maxdepth 1 -name "thermal_zone*" -type d 2>/dev/null | sort)
    fi
    
    if [ -d "/sys/devices/virtual/thermal" ]; then
        while IFS= read -r zone; do
            if [ -f "$zone/temp" ]; then
                zones+=("$zone")
            fi
        done < <(find /sys/devices/virtual/thermal -maxdepth 1 -name "thermal_zone*" -type d 2>/dev/null | sort)
    fi
    
    # Fallback for /proc interface
    if [ ${#zones[@]} -eq 0 ] && [ -f "/proc/thermal_zone0_temp" ]; then
        zones+=("/proc/thermal_zone0")
    fi
    
    printf '%s\n' "${zones[@]}"
}

init_thermal() {
    log "=== Thermal Daemon Initializing ==="
    
    local zones=($(find_thermal_zones))
    
    if [ ${#zones[@]} -eq 0 ]; then
        log "⚠️  No thermal zones found - daemon will exit"
        return 1
    fi
    
    log "✓ Found ${#zones[@]} thermal zone(s)"
    for zone in "${zones[@]}"; do
        log "  - $zone"
    done
    
    return 0
}

read_temperature() {
    local zones=($(find_thermal_zones))
    
    if [ ${#zones[@]} -eq 0 ]; then
        return 1
    fi
    
    # Read from first zone
    local zone="${zones[0]}"
    local temp_file="$zone/temp"
    
    if [ ! -f "$temp_file" ]; then
        return 1
    fi
    
    local temp=$(cat "$temp_file" 2>/dev/null)
    
    # Handle both mV (÷1000) and °C formats
    if [ "$temp" -gt 100 ]; then
        temp=$((temp / 1000))
    fi
    
    echo "$temp"
}

read_all_temperatures() {
    local zones=($(find_thermal_zones))
    local temps=()
    
    for zone in "${zones[@]}"; do
        temp_file="$zone/temp"

        [[ -r "$temp_file" ]] || continue

        temp=$(cat "$temp_file" 2>/dev/null)
        temp=${temp//$'\n'/}

        [[ "$temp" =~ ^[0-9]+$ ]] || continue

        (( temp > 100 )) && temp=$((temp / 1000))

        zone_name=$(basename "$zone")
        temps+=("$zone_name:${temp}°C")
    done
    
    printf '%s ' "${temps[@]}"
}

get_thermal_status() {
    local temp=$1
    
    if [ "$temp" -le "$TEMP_SAFE" ]; then
        echo "SAFE"
    elif [ "$temp" -le "$TEMP_WARM" ]; then
        echo "WARM"
    elif [ "$temp" -le "$TEMP_HOT" ]; then
        echo "HOT"
    else
        echo "CRITICAL"
    fi
}

# ============================================================================
# TEMPERATURE LOGGING
# ============================================================================

log_temperature() {
    local temp=$1
    local status=$(get_thermal_status "$temp")
    local all_temps=$(read_all_temperatures)
    
    log "TEMP=${temp}°C STATUS=$status | $all_temps"
}

write_thermal_state() {
    local temp=$1
    local status=$2
    local timestamp=$(date '+%s')
    
    cat > "$THERMAL_STATE_FILE" << EOF
{
  "timestamp": "$timestamp",
  "temperature": $temp,
  "status": "$status",
  "datetime": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
}

get_thermal_state() {
    if [ -f "$THERMAL_STATE_FILE" ]; then
        cat "$THERMAL_STATE_FILE"
    else
        echo '{"temperature": 0, "status": "UNKNOWN"}'
    fi
}

# ============================================================================
# EMERGENCY COOLDOWN
# ============================================================================

enter_emergency_cooldown() {
    log "🔴 ENTERING EMERGENCY COOLDOWN MODE"
    
    # Kill resource-intensive processes
    log "Killing intensive processes..."
    pkill -f "python.*main.py" 2>/dev/null && log "  ✓ Stopped Python sorter"
    pkill -f "rclone sync" 2>/dev/null && log "  ✓ Stopped rclone sync"
    pkill -f "java" 2>/dev/null && log "  ✓ Stopped Java processes"
    
    # Clear caches
    log "Clearing caches..."
    sync 2>/dev/null
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && log "  ✓ Dropped filesystem cache"
    
    # Write lock file
    touch "$THERMAL_LOCK"
    log "Emergency cooldown lock activated"
    
    # Wait for temperature to drop
    local max_wait=600  # 10 minutes
    local elapsed=0
    local check_interval=5
    
    log "Waiting for temperature to drop below ${TEMP_HOT}°C (max ${max_wait}s)..."
    
    while [ $elapsed -lt $max_wait ]; do
        local current_temp=$(read_temperature)
        
        if [ -z "$current_temp" ]; then
            elapsed=$((elapsed + check_interval))
            sleep "$check_interval"
            continue
        fi
        
        if [ "$current_temp" -le "$TEMP_HOT" ]; then
            log "✓ Temperature dropped to ${current_temp}°C - emergency resolved"
            rm -f "$THERMAL_LOCK"
            return 0
        fi
        
        elapsed=$((elapsed + check_interval))
        sleep "$check_interval"
    done
    
    log "⚠️  Emergency cooldown timeout - exiting cooldown after ${max_wait}s"
    rm -f "$THERMAL_LOCK"
    return 1
}

# ============================================================================
# PIPELINE INTEGRATION
# ============================================================================

should_skip_pipeline() {
    [ -f "$THERMAL_LOCK" ] && return 0  # true - skip
    return 1  # false - don't skip
}

is_temperature_critical() {
    local temp=$1
    [ "$temp" -ge "$TEMP_CRITICAL" ]
}

is_temperature_hot() {
    local temp=$1
    [ "$temp" -ge "$TEMP_HOT" ]
}

# ============================================================================
# STATUS & REPORTING
# ============================================================================

show_thermal_status() {
    local temp=$(read_temperature)
    local status=$(get_thermal_status "$temp")
    local all_temps=$(read_all_temperatures)
    
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║         THERMAL STATUS REPORT          ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    echo "  Temperature: ${temp}°C"
    echo "  Status:      $status"
    echo "  All zones:   $all_temps"
    echo ""
    
    # Thresholds visualization
    printf "  Range: "
    printf "%-5s %-5s %-5s %-5s\n" "SAFE" "WARM" "HOT" "CRIT"
    printf "        <%dC  <%dC  <%dC  >=%dC\n\n" \
        "$TEMP_WARM" "$TEMP_HOT" "$TEMP_CRITICAL" "$TEMP_CRITICAL"
    
    # Status indicator
    case "$status" in
        SAFE)
            echo "  Status: ✅ SAFE - Normal operation"
            ;;
        WARM)
            echo "  Status: ⚠️  WARM - Monitor closely"
            ;;
        HOT)
            echo "  Status: 🔥 HOT - Reduce operations"
            ;;
        CRITICAL)
            echo "  Status: 🔴 CRITICAL - Emergency cooldown!"
            ;;
    esac
    
    echo ""
    
    if [ -f "$THERMAL_LOCK" ]; then
        echo "  ⚠️  Emergency cooldown ACTIVE"
    fi
    
    echo ""
}

show_thermal_logs() {
    local lines=${1:-50}
    
    if [ ! -f "$LOG_FILE" ]; then
        echo "No thermal logs yet"
        return
    fi
    
    echo ""
    echo "=== Last $lines temperature entries ==="
    echo ""
    tail -n "$lines" "$LOG_FILE"
    echo ""
}

thermal_diagnostics() {
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║       THERMAL DIAGNOSTICS TEST         ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    
    echo "Testing thermal zone detection..."
    local zones=($(find_thermal_zones))
    
    if [ ${#zones[@]} -eq 0 ]; then
        echo "❌ No thermal zones found!"
        echo ""
        echo "Checking standard paths:"
        echo "  /sys/class/thermal: $([ -d /sys/class/thermal ] && echo "exists" || echo "NOT FOUND")"
        echo "  /sys/devices/virtual/thermal: $([ -d /sys/devices/virtual/thermal ] && echo "exists" || echo "NOT FOUND")"
        echo "  /proc/thermal_zone0_temp: $([ -f /proc/thermal_zone0_temp ] && echo "exists" || echo "NOT FOUND")"
        echo ""
        return 1
    fi
    
    echo "✓ Found ${#zones[@]} thermal zone(s)"
    echo ""
    
    for zone in "${zones[@]}"; do
        if [ -f "$zone/temp" ]; then
            local temp=$(cat "$zone/temp" 2>/dev/null)
            if [ "$temp" -gt 100 ]; then
                temp=$((temp / 1000))
            fi
            printf "  %-35s: %d°C\n" "$(basename "$zone")" "$temp"
        fi
    done
    
    echo ""
    echo "✓ Thermal diagnostics passed"
    echo ""
}

# ============================================================================
# DAEMON LIFECYCLE
# ============================================================================

start_thermal_daemon() {
    if [ -f "$THERMAL_PID_FILE" ]; then
        local old_pid=$(cat "$THERMAL_PID_FILE")
        if ps -p "$old_pid" > /dev/null 2>&1; then
            echo "Thermal daemon already running (PID: $old_pid)"
            return 1
        else
            rm -f "$THERMAL_PID_FILE"
        fi
    fi
    
    # Start daemon in background
    nohup bash "$0" daemon > /dev/null 2>&1 &
    local daemon_pid=$!
    echo "$daemon_pid" > "$THERMAL_PID_FILE"
    
    echo "✓ Thermal daemon started (PID: $daemon_pid)"
    sleep 1
    
    if ps -p "$daemon_pid" > /dev/null 2>&1; then
        echo "✓ Thermal daemon verified running"
        return 0
    else
        echo "❌ Thermal daemon failed to start"
        return 1
    fi
}

stop_thermal_daemon() {
    if [ ! -f "$THERMAL_PID_FILE" ]; then
        echo "Thermal daemon not running (no PID file)"
        return 1
    fi
    
    local pid=$(cat "$THERMAL_PID_FILE")
    
    if ! ps -p "$pid" > /dev/null 2>&1; then
        echo "Thermal daemon not running (stale PID: $pid)"
        rm -f "$THERMAL_PID_FILE"
        return 1
    fi
    
    echo "Stopping thermal daemon (PID: $pid)..."
    kill "$pid" 2>/dev/null
    sleep 1
    
    if ps -p "$pid" > /dev/null 2>&1; then
        kill -9 "$pid" 2>/dev/null
        sleep 1
    fi
    
    rm -f "$THERMAL_PID_FILE" "$THERMAL_LOCK"
    echo "✓ Thermal daemon stopped"
}

status_thermal_daemon() {
    if [ ! -f "$THERMAL_PID_FILE" ]; then
        echo "Status: NOT RUNNING (no PID file)"
        return 1
    fi
    
    local pid=$(cat "$THERMAL_PID_FILE")
    
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "Status: RUNNING (PID: $pid)"
        
        # Show last logged temperature
        if [ -f "$LOG_FILE" ]; then
            local last_entry=$(tail -1 "$LOG_FILE")
            echo "Last log: $last_entry"
        fi
        
        return 0
    else
        echo "Status: NOT RUNNING (stale PID: $pid)"
        rm -f "$THERMAL_PID_FILE"
        return 1
    fi
}

# ============================================================================
# MAIN DAEMON LOOP
# ============================================================================

thermal_daemon() {
    log "=== Thermal Daemon Started (PID: $$) ==="
    echo $$ > "$THERMAL_PID_FILE"
    
    # Send startup notification
    log_event "INFO" "Thermal daemon started"
    send_telegram_notification "🟢 <b>Thermal Daemon Started</b>
Monitoring device temperature
Time: $(date '+%H:%M:%S')"
    
    # Initialize
    if ! init_thermal; then
        log "Failed to initialize thermal zones - exiting"
        notify_event "CRITICAL" "Thermal daemon failed to initialize - no thermal zones found"
        rm -f "$THERMAL_PID_FILE"
        exit 1
    fi
    
    # Main monitoring loop
    local last_status=""
    
    while true; do
        local temp=$(read_temperature)
        
        if [ -n "$temp" ]; then
            local status=$(get_thermal_status "$temp")
            
            # Log temperature
            log_temperature "$temp"
            
            # Update state file
            write_thermal_state "$temp" "$status"
            
            # Send notifications for status changes
            if [ "$status" != "$last_status" ]; then
                case "$status" in
                    CRITICAL)
                        notify_critical_temp "$temp"
                        enter_emergency_cooldown
                        ;;
                    HOT)
                        notify_hot_temp "$temp"
                        ;;
                    WARM)
                        log_event "WARNING" "Temperature warming up: ${temp}°C"
                        ;;
                    SAFE)
                        if [ "$last_status" = "WARM" ] || [ "$last_status" = "HOT" ] || [ "$last_status" = "CRITICAL" ]; then
                            log_event "INFO" "Temperature normalized to SAFE: ${temp}°C"
                        fi
                        ;;
                esac
                last_status="$status"
            fi
        fi
        
        # Sleep before next check
        sleep "$MONITOR_INTERVAL"
    done
}

# ============================================================================
# COMMANDS
# ============================================================================

show_help() {
    cat << EOF
Thermal Monitoring Daemon - Independent Script
===============================================

Usage: $0 {command}

Daemon Control:
  daemon              Run thermal daemon (main loop) - use internally
  start               Start daemon in background
  stop                Stop running daemon
  restart             Restart daemon
  status              Show daemon status

Status & Logs:
  show-status         Display current temperature and status
  show-logs           Show recent temperature logs
  show-events         Show recent event log (thermal/emergency events)
  diags               Run thermal diagnostics

Emergency:
  emergency-cooldown  Force emergency cooldown mode

Integration (for pipeline.sh):
  is-critical         Exit 0 if critical, 1 otherwise
  is-hot              Exit 0 if hot, 1 otherwise
  get-state           Print current state as JSON

Examples:
  $0 start            # Start daemon in background
  $0 show-status      # Check current temperature
  $0 show-logs 100    # Last 100 log entries
  $0 diags            # Test thermal sensors
  
Configuration:
  Edit TEMP_* thresholds in this script (lines 25-28)
  Logging goes to: $LOG_FILE

EOF
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

case "${1:-help}" in
    daemon)
        mkdir -p "$WORKFLOW_DIR/logs" 2>/dev/null || true
        thermal_daemon
        ;;
    
    start)
        start_thermal_daemon
        ;;
    
    stop)
        stop_thermal_daemon
        ;;
    
    restart)
        stop_thermal_daemon
        sleep 2
        start_thermal_daemon
        ;;
    
    status)
        status_thermal_daemon
        ;;
    
    show-status)
        show_thermal_status
        ;;
    
    show-logs)
        show_thermal_logs "${2:-50}"
        ;;
    
    diags)
        thermal_diagnostics
        ;;
    
    emergency-cooldown)
        log "⚠️  MANUAL EMERGENCY COOLDOWN TRIGGERED"
        enter_emergency_cooldown
        ;;
    
    is-critical)
        local temp=$(read_temperature)
        is_temperature_critical "$temp"
        exit $?
        ;;
    
    is-hot)
        local temp=$(read_temperature)
        is_temperature_hot "$temp"
        exit $?
        ;;
    
    get-state)
        cat "$THERMAL_STATE_FILE" 2>/dev/null || echo '{"status":"unknown"}'
        ;;
    
    help|--help|-h)
        show_help
        ;;
    
    *)
        show_help
        exit 1
        ;;
esac
