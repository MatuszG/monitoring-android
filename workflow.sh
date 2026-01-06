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
    
    log "Pobieranie najnowszych zmian z repozytorium..."
    cd "$WORKFLOW_DIR" && git pull origin master
    
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

# ============================================================================
# AUTO-UPDATE - Uruchamianie update.sh co 24h
# ============================================================================

check_and_run_auto_update() {
    local last_update_file="$WORKFLOW_DIR/.last_update"
    local update_interval=86400  # 24 godziny w sekundach
    local current_time=$(date +%s)
    
    # Sprawdzenie czy plik ostatniej aktualizacji istnieje
    if [ ! -f "$last_update_file" ]; then
        log "Pierwsza aktualizacja - tworzę marker..."
        echo "$current_time" > "$last_update_file"
        return 0
    fi
    
    # Pobierz czas ostatniej aktualizacji
    local last_update=$(cat "$last_update_file")
    local time_since_update=$((current_time - last_update))
    
    # Sprawdzenie czy minęło 24h
    if [ $time_since_update -ge $update_interval ]; then
        log "Minęło 24h od ostatniej aktualizacji - uruchamiam update.sh"
        send_telegram "🔄 Auto-update: Zaczynam aktualizację kodu
Ostatnia aktualizacja: $(date -d @$last_update '+%Y-%m-%d %H:%M:%S')" true
        
        # Uruchom update.sh w tle (nie blokuj main pipeline)
        if "$WORKFLOW_DIR/update.sh" >> "$LOG_FILE" 2>> "$ERROR_LOG" &
            UPDATE_PID=$!
            
            # Czekaj max 10 minut na aktualizację
            local timeout=600
            local elapsed=0
            while ps -p "$UPDATE_PID" > /dev/null 2>&1 && [ $elapsed -lt $timeout ]; do
                sleep 10
                elapsed=$((elapsed + 10))
            done
            
            if ps -p "$UPDATE_PID" > /dev/null 2>&1; then
                warn "Update.sh przekroczył timeout (10 minut), kontynuuję..."
            fi
            
            # Zaktualizuj czas ostatniej aktualizacji
            echo "$current_time" > "$last_update_file"
            
            # Wyślij info o completion
            send_telegram "✅ Auto-update zakończony
Czas: $(date '+%H:%M:%S')
Następna aktualizacja: $(date -d '+24 hours' '+%Y-%m-%d %H:%M:%S')" true
        then
            log "✅ Auto-update uruchomiony pomyślnie"
        else
            error "Problem przy uruchamianiu update.sh"
            send_telegram "❌ Auto-update failed!
Sprawdź logi: ./workflow.sh logs" false
        fi
    else
        local hours_until=$((($update_interval - $time_since_update) / 3600))
        log "Następna aktualizacja za ~$hours_until godzin"
    fi
}

# Wykonanie zadań
execute_tasks() {
    local overall_status=0
    
    log "=== Rozpoczęcie cyklu przetwarzania ==="
    
    # 0. Sprawdzenie i uruchomienie auto-update co 24h
    check_and_run_auto_update
    
    # 1. Sync z Google Drive / źródła
    if ! sync_rclone; then
        error "Błąd synchronizacji rclone"
        overall_status=1
    fi
    
    # 2. Uruchomienie Python pipeline przetwarzania zdjęć
    if ! run_photo_sorting; then
        error "Błąd przetwarzania zdjęć"
        overall_status=1
    fi
    
    # 3. Upload wyników z powrotem na Drive
    if ! upload_results_rclone; then
        error "Błąd uploadu wyników"
        overall_status=1
    fi
    
    # 4. Cleanup i maintenance
    cleanup_tasks
    
    # 5. Status systemu
    log "Status systemu: $(get_system_status)"
    
    log "=== Koniec cyklu ==="
    return $overall_status
}

# Synchronizacja z Google Drive / rclone remote
sync_rclone() {
    local rclone_remote="${RCLONE_REMOTE:-gdrive}"
    local incoming_dir="${INCOMING_DIR:-/mnt/incoming}"
    
    if ! command -v rclone &> /dev/null; then
        warn "rclone nie zainstalowany, pomijam sync"
        return 0
    fi
    
    log "Synchronizacja z rclone ($rclone_remote)..."
    
    # Ustaw timeout i limity
    if rclone sync \
        "$rclone_remote:$RCLONE_ROOT/DriveSyncFiles" "$incoming_dir" \
        --transfers=4 \
        --checkers=8 \
        --log-file="$LOG_FILE" \
        --log-level=INFO \
        --skip-links \
        --timeout=60s \
        2>> "$ERROR_LOG"; then
        
        log "✅ Sync rclone zakończony"
        return 0
    else
        error "Sync rclone failed"
        return 1
    fi
}

# Uruchomienie Python pipeline sortowania zdjęć
run_photo_sorting() {
    log "Uruchamianie pipeline sortowania zdjęć..."
    
    # Sprawdzenie Python
    if ! command -v python &> /dev/null; then
        warn "Python nie zainstalowany, pomijam sorting"
        return 0
    fi
    
    # Zmień katalog na sorter-common aby imports działały
    local sorter_dir="$WORKFLOW_DIR/sorter-common"
    if [ ! -d "$sorter_dir" ]; then
        error "Katalog sorter-common nie znaleziony: $sorter_dir"
        return 1
    fi
    
    # Uruchom main.py z odpowiednimi zmiennymi środowiskowymi
    (
        cd "$WORKFLOW_DIR"
        
        # Ustaw zmienne dla pipeline
        export PYTHONUNBUFFERED=1
        export DEBUG="0"  # "0"=produkcja, "1"=lokalny debug, "2"=10 zdjęć test
        
        # Jeśli istnieje .env, załaduj go
        if [ -f "$WORKFLOW_DIR/.env" ]; then
            source "$WORKFLOW_DIR/.env"
        fi
        
        # Opcjonalnie załaduj config.env
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
        fi
        
        if python main.py >> "$LOG_FILE" 2>> "$ERROR_LOG"; then
            log "✅ Pipeline sortowania zakończony"
            return 0
        else
            error "Pipeline sortowania failed"
            return 1
        fi
    )
    
    return $?
}

# Upload wyników z powrotem na Google Drive
upload_results_rclone() {
    local rclone_remote="${RCLONE_REMOTE:-gdrive}"
    local sorted_dir="${SORTED_DIR:-/mnt/sorted}"
    local gdrive_path="${GDRIVE_PATH:-Posortowane}"
    
    if ! command -v rclone &> /dev/null; then
        warn "rclone nie zainstalowany, pomijam upload"
        return 0
    fi
    
    log "Upload wyników do Google Drive..."
    
    if [ ! -d "$sorted_dir" ]; then
        warn "Brak katalogu wyników: $sorted_dir"
        return 0
    fi
    
    # Sprawdź czy są pliki do uploadu
    local file_count=$(find "$sorted_dir" -type f 2>/dev/null | wc -l)
    if [ "$file_count" -eq 0 ]; then
        log "Brak plików do uploadu (katalog pusty)"
        return 0
    fi
    
    log "Uploading $file_count files..."
    
    if rclone sync "$sorted_dir" "$rclone_remote:$RCLONE_ROOT/$gdrive_path" \
        --transfers=4 \
        --checkers=8 \
        --log-file="$LOG_FILE" \
        --log-level=INFO \
        --timeout=120s \
        2>> "$ERROR_LOG"; then
        
        log "✅ Upload wyników zakończony"
        return 0
    else
        error "Upload rclone failed"
        return 1
    fi
}

# System cleanup i maintenance
cleanup_tasks() {
    log "Czyszczenie plików tymczasowych..."
    
    # Usuń stare pliki z tmp (starsze niż 7 dni)
    find "$WORKFLOW_DIR/tmp" -type f -mtime +7 -delete 2>/dev/null
    
    # Usuń stare logi (starsze niż 30 dni)
    find "$WORKFLOW_DIR/logs" -name "*.log.*" -mtime +30 -delete 2>/dev/null
    
    # Opcjonalnie: usuń pliki z to_delete
    local to_delete_dir="${SORTED_DIR}/to_delete"
    if [ -d "$to_delete_dir" ]; then
        local delete_count=$(find "$to_delete_dir" -type f 2>/dev/null | wc -l)
        if [ "$delete_count" -gt 0 ]; then
            log "Usuwam $delete_count plików zaznaczonych do usunięcia..."
            rm -rf "$to_delete_dir"/* 2>> "$ERROR_LOG"
        fi
    fi
    
    return 0
}

# Pobranie statusu systemu
get_system_status() {
    local mem_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100}' 2>/dev/null || echo "N/A")
    local uptime=$(uptime -p 2>/dev/null || echo "N/A")
    local cpu_load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' || echo "N/A")
    
    echo "💾 Mem: ${mem_usage}% | 🔄 Load: ${cpu_load} | ⏱️ Uptime: $uptime"
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
    
    update-logs)
        if [ -f "$WORKFLOW_DIR/logs/update.log" ]; then
            echo ""
            echo "=== Ostatnie logi z update.sh ==="
            echo ""
            tail -n 50 "$WORKFLOW_DIR/logs/update.log"
            echo ""
            echo "Aby zobaczyć wszystkie: tail -f $WORKFLOW_DIR/logs/update.log"
        else
            echo "Nie ma logów update.sh (jeszcze nie było aktualizacji)"
        fi
        ;;
    
    *)
        echo "Termux 24/7 Auto-Restart Workflow"
        echo "=================================="
        echo ""
        echo "Użycie: $0 {setup|start|stop|restart|status|logs|watchdog|telegram-*|update-logs}"
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
        echo "Update & Maintenance:"
        echo "  update-logs     - Pokaż ostatnie logi z aktualizacji"
        echo ""
        echo "Telegram:"
        echo "  telegram-test   - Test powiadomienia"
        echo "  telegram-config - Konfiguracja Telegram"
        echo "  send-logs       - Wyślij logi na Telegram"
        echo ""
        ;;
esac
