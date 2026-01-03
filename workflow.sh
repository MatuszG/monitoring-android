#!/data/data/com.termux/files/usr/bin/bash
# Termux 24/7 Auto-Restart Workflow
# Wersja: 1.1 - Z powiadomieniami Telegram

WORKFLOW_DIR="$(dirname "$(realpath "$0")")"
LOG_FILE="$WORKFLOW_DIR/logs/workflow.log"
ERROR_LOG="$WORKFLOW_DIR/logs/error.log"
PID_FILE="$WORKFLOW_DIR/workflow.pid"
LOCK_FILE="$WORKFLOW_DIR/workflow.lock"
STATE_FILE="$WORKFLOW_DIR/state.json"
CONFIG_FILE="$WORKFLOW_DIR/config.env"

# Konfiguracja
MAX_LOG_SIZE=10485760  # 10MB
HEALTHCHECK_INTERVAL=60  # sekundy
RESTART_DELAY=5  # sekundy po crashu
MAX_RETRIES=3
OFFLINE_THRESHOLD=180  # sekundy bez odpowiedzi = offline

# Telegram config (ładowane z pliku)
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Kolory
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    local msg="$1"
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $msg" | tee -a "$ERROR_LOG"
    
    # Wyślij powiadomienie na Telegram
    send_telegram "🔴 ERROR: $msg"
}

# Telegram - wysyłanie wiadomości
send_telegram() {
    local message="$1"
    local silent="${2:-false}"  # false = z dźwiękiem, true = cicho
    
    # Załaduj config jeśli istnieje
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    # Sprawdź czy skonfigurowano
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 1
    fi
    
    # Dodaj hostname/info urządzenia
    local device_info="📱 $(hostname 2>/dev/null || echo 'Termux')"
    local full_message="${device_info}
${message}"
    
    # Wyślij przez API
    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${full_message}" \
        -d "parse_mode=HTML" \
        -d "disable_notification=${silent}" \
        > /dev/null 2>&1
    
    return $?
}

# Telegram - wysyłanie pliku (logi)
send_telegram_file() {
    local file_path="$1"
    local caption="${2:-Log file}"
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 1
    fi
    
    if [ ! -f "$file_path" ]; then
        return 1
    fi
    
    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "document=@${file_path}" \
        -F "caption=${caption}" \
        > /dev/null 2>&1
    
    return $?
}

# Rotacja logów gdy za duże
rotate_logs() {
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        log "Log rotowany"
    fi
}

# Sprawdzenie czy workflow już działa
check_running() {
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        if ps -p "$OLD_PID" > /dev/null 2>&1; then
            return 0  # Działa
        else
            warn "Znaleziono martwy PID: $OLD_PID"
            rm -f "$PID_FILE" "$LOCK_FILE"
        fi
    fi
    return 1  # Nie działa
}

# Lock file - zapobiega równoległym uruchomieniom
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        LOCK_TIME=$(stat -c%Y "$LOCK_FILE" 2>/dev/null || stat -f%m "$LOCK_FILE" 2>/dev/null)
        CURRENT_TIME=$(date +%s)
        DIFF=$((CURRENT_TIME - LOCK_TIME))
        
        if [ $DIFF -gt 300 ]; then
            warn "Usuwam stary lock (${DIFF}s)"
            rm -f "$LOCK_FILE"
        else
            error "Workflow już działa (lock aktywny)"
            return 1
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    return 0
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# Zapisz stan workflow
save_state() {
    cat > "$STATE_FILE" << EOF
{
  "last_run": "$(date -Iseconds)",
  "pid": $$,
  "runs": ${1:-0},
  "errors": ${2:-0}
}
EOF
}

# Inicjalizacja środowiska
setup_environment() {
    log "=== Konfiguracja środowiska 24/7 ==="
    
    mkdir -p "$WORKFLOW_DIR"/{data,scripts,logs,tmp}
    
    # Termux-services dla niezawodności
    if ! command -v sv &> /dev/null; then
        log "Instalacja termux-services..."
        pkg install -y termux-services
        source $PREFIX/etc/profile.d/start-services.sh
    fi
    
    # Podstawowe zależności
    log "Instalacja zależności..."
    pkg install -y cronie termux-wake-lock jq curl
    
    # Wake lock - zapobiega uśpieniu
    log "Aktywacja wake lock..."
    termux-wake-lock
    
    # Konfiguracja Telegram
    setup_telegram
    
    # Wyłącz battery optimization dla Termux (instrukcja)
    log ""
    log "WAŻNE: Wyłącz optymalizację baterii dla Termux:"
    log "1. Ustawienia -> Bateria -> Optymalizacja -> Termux -> Nie optymalizuj"
    log "2. Ustawienia -> Aplikacje -> Termux -> Bateria -> Bez ograniczeń"
    log ""
}

# Konfiguracja Telegram
setup_telegram() {
    log "=== Konfiguracja powiadomień Telegram ==="
    
    if [ -f "$CONFIG_FILE" ]; then
        log "Znaleziono istniejącą konfigurację"
        source "$CONFIG_FILE"
        
        if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
            echo ""
            read -p "Zmienić istniejącą konfigurację? (t/N): " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Tt]$ ]]; then
                return
            fi
        fi
    fi
    
    echo ""
    echo "Aby otrzymywać powiadomienia Telegram:"
    echo "1. Utwórz bota: https://t.me/BotFather"
    echo "2. Użyj komendy /newbot i skopiuj token"
    echo "3. Znajdź swoje chat_id: https://t.me/userinfobot"
    echo ""
    
    read -p "Telegram Bot Token: " bot_token
    read -p "Telegram Chat ID: " chat_id
    
    # Zapisz konfigurację
    cat > "$CONFIG_FILE" << EOF
# Konfiguracja Telegram
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
EOF
    
    chmod 600 "$CONFIG_FILE"
    
    # Test powiadomienia
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    log "Wysyłam test powiadomienia..."
    if send_telegram "✅ Workflow 24/7 skonfigurowany!

🔔 Otrzymasz powiadomienia o:
• Crashach workflow
• Błędach wykonania
• Statusie offline
• Restartach serwisu"; then
        log "✓ Powiadomienie testowe wysłane!"
    else
        error "✗ Nie udało się wysłać powiadomienia - sprawdź dane"
    fi
}

# Główna funkcja workflow
run_workflow() {
    local run_count=0
    local error_count=0
    local last_notification=0
    
    log "=== Workflow 24/7 uruchomiony (PID: $$) ==="
    echo $$ > "$PID_FILE"
    
    # Powiadomienie o starcie
    send_telegram "🚀 Workflow uruchomiony
PID: $$
Czas: $(date '+%Y-%m-%d %H:%M:%S')" true
    
    # Pętla główna
    while true; do
        rotate_logs
        
        if ! acquire_lock; then
            sleep 5
            continue
        fi
        
        run_count=$((run_count + 1))
        log "--- Cykl #$run_count ---"
        
        # Wykonanie zadań workflow
        if execute_tasks; then
            save_state "$run_count" "$error_count"
            error_count=0  # Reset licznika błędów po sukcesie
        else
            error_count=$((error_count + 1))
            error "Zadanie failed (błędów: $error_count)"
            save_state "$run_count" "$error_count"
            
            # Wyślij logi jeśli dużo błędów
            if [ $error_count -eq $MAX_RETRIES ]; then
                send_telegram_file "$ERROR_LOG" "⚠️ Error log - $error_count błędów"
            fi
            
            # Zbyt wiele błędów - restartuj
            if [ $error_count -ge $MAX_RETRIES ]; then
                error "Za dużo błędów, restart za ${RESTART_DELAY}s..."
                send_telegram "🔄 Restart workflow po $error_count błędach
Kolejna próba za ${RESTART_DELAY}s"
                
                release_lock
                sleep $RESTART_DELAY
                error_count=0
            fi
        fi
        
        release_lock
        
        # Healthcheck
        sleep $HEALTHCHECK_INTERVAL
    done
}

# Wykonanie zadań
execute_tasks() {
    # Hello World
    echo "[$(date -Iseconds)] Hello from 24/7 workflow" >> "$WORKFLOW_DIR/data/output.txt"
    
    # Status systemu
    local mem_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100}')
    local uptime=$(uptime -p 2>/dev/null || echo "N/A")
    
    log "Pamięć: ${mem_usage}% | Uptime: $uptime"
    
    # Placeholder dla przyszłych funkcji
    # python_detection_task
    # rclone_sync_task
    
    # Cleanup starych plików (opcjonalnie)
    find "$WORKFLOW_DIR/tmp" -type f -mtime +7 -delete 2>/dev/null
    
    return 0
}

# Funkcje do rozbudowy
python_detection_task() {
    if command -v python &> /dev/null; then
        log "Uruchamianie detekcji..."
        python "$WORKFLOW_DIR/scripts/detect.py" >> "$LOG_FILE" 2>> "$ERROR_LOG"
        return $?
    fi
    return 0
}

rclone_sync_task() {
    if command -v rclone &> /dev/null; then
        log "Synchronizacja rclone..."
        rclone sync "$WORKFLOW_DIR/data" remote:backup --log-file="$LOG_FILE"
        return $?
    fi
    return 0
}

# Watchdog - monitoruje workflow i restartuje przy crash
start_watchdog() {
    log "=== Uruchamianie watchdog ==="
    
    local offline_count=0
    local last_crash_notification=0
    local notification_cooldown=300  # 5 minut między powiadomieniami
    
    # Powiadomienie o starcie watchdog
    send_telegram "👁️ Watchdog aktywny
Monitoruje workflow co 30s" true
    
    while true; do
        local current_time=$(date +%s)
        
        if ! check_running; then
            offline_count=$((offline_count + 1))
            
            # Powiadomienie tylko jeśli minął cooldown
            if [ $((current_time - last_crash_notification)) -gt $notification_cooldown ]; then
                warn "Workflow nie działa - restart ($offline_count)..."
                send_telegram "❌ Workflow OFFLINE wykryty!

Próba #${offline_count}
Automatyczny restart za ${RESTART_DELAY}s..."
                
                last_crash_notification=$current_time
            fi
            
            sleep $RESTART_DELAY
            
            # Uruchom workflow w tle
            "$0" daemon &
            sleep 5
            
            # Sprawdź czy się uruchomił
            if check_running; then
                send_telegram "✅ Workflow przywrócony
PID: $(cat $PID_FILE)
Downtime: ~$((offline_count * 30))s"
                offline_count=0
            fi
        else
            # Workflow działa - reset licznika
            if [ $offline_count -gt 0 ]; then
                offline_count=0
            fi
        fi
        
        sleep 30
    done
}

# Daemon mode - uruchamia workflow w tle
start_daemon() {
    if check_running; then
        warn "Workflow już działa (PID: $(cat $PID_FILE))"
        return 1
    fi
    
    log "Uruchamianie daemona..."
    nohup "$0" run >> "$LOG_FILE" 2>> "$ERROR_LOG" &
    sleep 2
    
    if check_running; then
        log "Daemon uruchomiony (PID: $(cat $PID_FILE))"
        send_telegram "🟢 Workflow uruchomiony (daemon)
PID: $(cat $PID_FILE)" true
        return 0
    else
        error "Nie udało się uruchomić daemona"
        send_telegram "❌ Błąd uruchomienia daemona!"
        return 1
    fi
}

# Zatrzymanie workflow
stop_workflow() {
    log "Zatrzymywanie workflow..."
    
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null 2>&1; then
            kill "$PID"
            sleep 2
            
            if ps -p "$PID" > /dev/null 2>&1; then
                kill -9 "$PID"
            fi
            
            log "Workflow zatrzymany"
            send_telegram "⏹️ Workflow zatrzymany ręcznie
PID: $PID" true
        fi
        rm -f "$PID_FILE"
    fi
    
    release_lock
    termux-wake-unlock 2>/dev/null
}

# Status workflow
status_workflow() {
    echo "=== Status Workflow 24/7 ==="
    echo ""
    
    if check_running; then
        PID=$(cat "$PID_FILE")
        echo -e "${GREEN}Status: DZIAŁA${NC} (PID: $PID)"
        
        if [ -f "$STATE_FILE" ]; then
            echo ""
            echo "Stan workflow:"
            jq '.' "$STATE_FILE" 2>/dev/null || cat "$STATE_FILE"
        fi
    else
        echo -e "${RED}Status: ZATRZYMANY${NC}"
    fi
    
    echo ""
    echo "Wake lock: $(termux-wake-lock 2>&1 | grep -q "acquired" && echo "Aktywny" || echo "Nieaktywny")"
    echo ""
    echo "Ostatnie 10 wpisów z loga:"
    tail -n 10 "$LOG_FILE" 2>/dev/null || echo "Brak logów"
}

# Setup auto-start przy boot
setup_autostart() {
    log "Konfiguracja auto-start..."
    
    # Termux:Boot (wymaga instalacji z F-Droid)
    BOOT_DIR="$HOME/.termux/boot"
    mkdir -p "$BOOT_DIR"
    
    cat > "$BOOT_DIR/workflow-start.sh" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock
sleep 10
$HOME/workflow/workflow.sh start
EOF
    
    chmod +x "$BOOT_DIR/workflow-start.sh"
    
    log "Auto-start skonfigurowany"
    log "Zainstaluj 'Termux:Boot' z F-Droid dla pełnej automatyzacji"
}

# Menu główne
case "${1:-menu}" in
    setup)
        setup_environment
        setup_autostart
        log "Setup zakończony!"
        ;;
    
    start)
        start_daemon
        ;;
    
    run)
        run_workflow
        ;;
    
    watchdog)
        start_watchdog
        ;;
    
    daemon)
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
        log "Test powiadomienia Telegram..."
        send_telegram "🧪 Test powiadomienia
Czas: $(date '+%Y-%m-%d %H:%M:%S')
Status: ✅ Działa poprawnie"
        ;;
    
    telegram-config)
        setup_telegram
        ;;
    
    send-logs)
        log "Wysyłam logi na Telegram..."
        send_telegram_file "$LOG_FILE" "📋 Workflow logs"
        send_telegram_file "$ERROR_LOG" "⚠️ Error logs"
        ;;
    
    *)
        echo "Termux 24/7 Auto-Restart Workflow"
        echo "=================================="
        echo ""
        echo "Użycie: $0 {setup|start|stop|restart|status|logs|watchdog|telegram-*}"
        echo ""
        echo "Podstawowe:"
        echo "  setup           - Pierwsza konfiguracja środowiska"
        echo "  start           - Uruchom workflow w tle (daemon)"
        echo "  stop            - Zatrzymaj workflow"
        echo "  restart         - Restart workflow"
        echo "  status          - Sprawdź status"
        echo "  logs            - Podgląd logów na żywo"
        echo "  watchdog        - Uruchom watchdog (auto-restart)"
        echo ""
        echo "Telegram:"
        echo "  telegram-test   - Test powiadomienia"
        echo "  telegram-config - Konfiguracja Telegram"
        echo "  send-logs       - Wyślij logi na Telegram"
        echo ""
        ;;
esac
