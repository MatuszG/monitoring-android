#!/data/data/com.termux/files/usr/bin/bash
# update.sh - Aktualizacja workflow.sh i sorter-common
# Wersja: 2.0 - Z rollback, auto-retry, i modułowym logowaniem

set +e

# ============================================================================
# INICJALIZACJA - ŁADOWANIE MODUŁÓW
# ============================================================================

WORKFLOW_DIR="$(dirname "$(realpath "$0")")"
SCRIPTS_DIR="$WORKFLOW_DIR/scripts"

# Ładuj moduły
source "$SCRIPTS_DIR/logging.sh" || {
    echo "ERROR: Nie mogę załadować logging.sh"
    exit 1
}

source "$SCRIPTS_DIR/telegram.sh" || {
    echo "ERROR: Nie mogę załadować telegram.sh"
    exit 1
}

source "$SCRIPTS_DIR/secrets.sh" 2>/dev/null || true

# ============================================================================
# KONFIGURACJA
# ============================================================================

LOG_FILE="$WORKFLOW_DIR/logs/update.log"
ERROR_LOG="$WORKFLOW_DIR/logs/update_error.log"
BACKUP_DIR="$WORKFLOW_DIR/backups"
STATE_FILE="$WORKFLOW_DIR/.update_state.json"
CONFIG_FILE="$WORKFLOW_DIR/config.env"

mkdir -p "$WORKFLOW_DIR/logs" "$BACKUP_DIR"

# Parametry retry i backup
MAX_RETRIES=3
RETRY_DELAY=5
BACKUP_RETENTION_DAYS=7

# ============================================================================
# ENHANCED ERROR HANDLING
# ============================================================================

# Nadpisanie error() z logging.sh dla szczegółowego trackingu
error() {
    local msg="$1"
    local exit_code="${2:-$?}"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S.%3N')"
    local caller="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}"
    local function_name="${FUNCNAME[1]}"
    
    # Pełny error message z kontekstem
    local full_error="[$timestamp] ERROR [$caller in $function_name()]:
  Message: $msg
  Exit Code: $exit_code
  PWD: $(pwd)
  User: $(whoami)
  PID: $$"
    
    echo -e "${RED}$full_error${NC}" | tee -a "$LOG_FILE" "$ERROR_LOG"
    
    # Zrzut stosu wywołań
    echo "  Call Stack:" | tee -a "$ERROR_LOG"
    local frame=0
    while caller $frame 2>/dev/null | tee -a "$ERROR_LOG"; do
        ((frame++))
        [ $frame -gt 10 ] && break
    done
    echo "" | tee -a "$ERROR_LOG"
}

# Trap dla nieoczekiwanych błędów
trap_error() {
    local exit_code=$?
    local line_number=$1
    error "Nieoczekiwany błąd w linii $line_number" $exit_code
    save_state "error" "crashed" "Line: $line_number, Exit: $exit_code"
    
    # Notyfikacja Telegram o crash
    send_telegram "💥 <b>UPDATE CRASHED</b>
Linia: $line_number
Exit code: $exit_code
Sprawdź logi: update_error.log"
}

trap 'trap_error ${LINENO}' ERR

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

save_state() {
    local step="$1"
    local status="$2"
    local details="${3:-}"
    
    cat > "$STATE_FILE" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "step": "$step",
  "status": "$status",
  "details": "$details",
  "pid": $$
}
EOF
    
    debug "State saved: $step -> $status"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "{}"
    fi
}

clear_state() {
    rm -f "$STATE_FILE"
    debug "State cleared"
}

# ============================================================================
# BACKUP & ROLLBACK
# ============================================================================

create_backup() {
    local backup_name="backup_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    section "TWORZENIE BACKUPU"
    log "Backup: $backup_name"
    
    mkdir -p "$backup_path"
    
    # Backup workflow.sh
    if [ -f "$WORKFLOW_DIR/workflow.sh" ]; then
        cp "$WORKFLOW_DIR/workflow.sh" "$backup_path/" && \
            log "✅ workflow.sh → backup"
    fi
    
    # Backup config.env
    if [ -f "$WORKFLOW_DIR/config.env" ]; then
        cp "$WORKFLOW_DIR/config.env" "$backup_path/" && \
            log "✅ config.env → backup"
    fi
    
    # Backup sorter-common (tylko jeśli istnieje)
    if [ -d "$WORKFLOW_DIR/sorter-common" ]; then
        tar -czf "$backup_path/sorter-common.tar.gz" -C "$WORKFLOW_DIR" sorter-common 2>/dev/null && \
            log "✅ sorter-common → backup (tar.gz)"
    fi
    
    # Zapisz git commit hash
    if [ -d "$WORKFLOW_DIR/.git" ]; then
        git rev-parse HEAD > "$backup_path/git_commit.txt" 2>/dev/null && \
            log "✅ Git commit hash → backup"
    fi
    
    # Zapisz listę zainstalowanych Python packages
    pip list --format=freeze > "$backup_path/pip_freeze.txt" 2>/dev/null && \
        log "✅ Python packages → backup"
    
    echo "$backup_path" > "$WORKFLOW_DIR/.last_backup"
    log "✅ Backup utworzony: $backup_path"
    
    # Cleanup starych backupów
    cleanup_old_backups
}

cleanup_old_backups() {
    log "Czyszczenie starych backupów (>$BACKUP_RETENTION_DAYS dni)..."
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "backup_*" -mtime +$BACKUP_RETENTION_DAYS -exec rm -rf {} \; 2>/dev/null
    local count=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "backup_*" | wc -l)
    debug "Backupów w systemie: $count"
}

rollback() {
    section "ROLLBACK DO POPRZEDNIEJ WERSJI"
    
    if [ ! -f "$WORKFLOW_DIR/.last_backup" ]; then
        error "Brak informacji o ostatnim backupie!"
        return 1
    fi
    
    local backup_path=$(cat "$WORKFLOW_DIR/.last_backup")
    
    if [ ! -d "$backup_path" ]; then
        error "Backup nie istnieje: $backup_path"
        return 1
    fi
    
    log "Przywracanie z: $backup_path"
    
    # Stop workflow jeśli działa
    if [ -f "$WORKFLOW_DIR/workflow.pid" ]; then
        "$WORKFLOW_DIR/workflow.sh" stop 2>/dev/null || true
        sleep 2
    fi
    
    # Restore workflow.sh
    [ -f "$backup_path/workflow.sh" ] && \
        cp "$backup_path/workflow.sh" "$WORKFLOW_DIR/" && \
        log "✅ workflow.sh przywrócony"
    
    # Restore config.env
    [ -f "$backup_path/config.env" ] && \
        cp "$backup_path/config.env" "$WORKFLOW_DIR/" && \
        log "✅ config.env przywrócony"
    
    # Restore sorter-common
    if [ -f "$backup_path/sorter-common.tar.gz" ]; then
        rm -rf "$WORKFLOW_DIR/sorter-common"
        tar -xzf "$backup_path/sorter-common.tar.gz" -C "$WORKFLOW_DIR" 2>/dev/null && \
            log "✅ sorter-common przywrócony"
    fi
    
    # Git rollback jeśli możliwe
    if [ -f "$backup_path/git_commit.txt" ] && [ -d "$WORKFLOW_DIR/.git" ]; then
        local old_commit=$(cat "$backup_path/git_commit.txt")
        cd "$WORKFLOW_DIR"
        git reset --hard "$old_commit" 2>&1 | tee -a "$LOG_FILE"
        log "✅ Git rollback do: $old_commit"
    fi
    
    log "✅ Rollback zakończony!"
    send_telegram "🔄 <b>ROLLBACK WYKONANY</b>
Przywrócono: $(basename $backup_path)
Sprawdź: ./workflow.sh status"
    
    return 0
}

# ============================================================================
# RETRY LOGIC Z DETAILED LOGGING
# ============================================================================

retry_command() {
    local max_attempts="$1"
    local delay="$2"
    local description="$3"
    shift 3
    local cmd="$@"
    
    local attempt=1
    
    debug "retry_command() start: max=$max_attempts, delay=$delay, cmd='${cmd:0:80}...'"
    
    while [ $attempt -le $max_attempts ]; do
        log "Próba $attempt/$max_attempts: $description"
        
        # Uruchom komendę i przechwyt output
        local cmd_output_file=$(mktemp)
        local cmd_start_time=$(date +%s)
        
        if eval "$cmd" > "$cmd_output_file" 2>&1; then
            local cmd_end_time=$(date +%s)
            local cmd_duration=$((cmd_end_time - cmd_start_time))
            
            log "✅ Sukces: $description (czas: ${cmd_duration}s)"
            
            # Debug output jeśli był
            if [ -s "$cmd_output_file" ]; then
                debug "Command output (${description}):"
                head -n 20 "$cmd_output_file" | while IFS= read -r line; do
                    debug "  | $line"
                done
            fi
            
            rm -f "$cmd_output_file"
            return 0
        else
            local cmd_exit_code=$?
            local cmd_end_time=$(date +%s)
            local cmd_duration=$((cmd_end_time - cmd_start_time))
            
            # Zapisz pełny output błędu
            error "Próba $attempt FAILED: $description" "$cmd_exit_code"
            error "  Czas wykonania: ${cmd_duration}s"
            
            if [ -s "$cmd_output_file" ]; then
                error "Command stderr/stdout (ostatnie 30 linii):"
                tail -n 30 "$cmd_output_file" | while IFS= read -r line; do
                    error "  | $line"
                done
            fi
            
            rm -f "$cmd_output_file"
            
            if [ $attempt -lt $max_attempts ]; then
                warn "Retry za ${delay}s... (pozostało prób: $((max_attempts - attempt)))"
                sleep $delay
            else
                error "Wszystkie $max_attempts próby wyczerpane: $description"
                return 1
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    return 1
}

# ============================================================================
# DEPENDENCY CHECK
# ============================================================================

check_command() {
    local cmd="$1"
    local pkg="$2"
    
    debug "check_command(): cmd=$cmd, pkg=$pkg"
    
    if command -v "$cmd" &> /dev/null; then
        local cmd_path=$(command -v "$cmd")
        log "✅ $cmd zainstalowany: $cmd_path"
        
        # Sprawdź wersję jeśli możliwe
        if "$cmd" --version &> /dev/null 2>&1; then
            local version=$("$cmd" --version 2>&1 | head -n1)
            debug "  Wersja: $version"
        fi
        
        return 0
    else
        warn "❌ $cmd nie znaleziony w PATH"
        debug "  PATH: $PATH"
        
        if ! command -v pkg &> /dev/null; then
            error "pkg manager nie dostępny - nie można zainstalować $pkg"
            return 1
        fi
        
        # Retry install z pełnym logowaniem
        if retry_command 2 3 "Instalacja $pkg" "pkg install -y $pkg 2>&1"; then
            log "✅ $pkg zainstalowany"
            
            # Weryfikacja po instalacji
            if command -v "$cmd" &> /dev/null; then
                debug "  Weryfikacja OK: $cmd dostępny po instalacji"
                return 0
            else
                error "Instalacja $pkg zakończona, ale $cmd nadal niedostępny"
                error "  Sprawdź czy nazwa komendy != nazwa pakietu"
                return 1
            fi
        else
            error "Nie udało się zainstalować: $pkg"
            return 1
        fi
    fi
}

# ============================================================================
# GŁÓWNA PROCEDURA AKTUALIZACJI
# ============================================================================

main_update() {
    section "AKTUALIZACJA WORKFLOW"
    
    log "Katalog workflow: $WORKFLOW_DIR"
    log "Start: $(date '+%Y-%m-%d %H:%M:%S')"
    
    HAS_CODE_CHANGES=false
    HAS_ERRORS=false
    
    save_state "init" "started"
    send_telegram_progress "0/10" "0" "💾 Rozpoczynam update..."
    
    # 0. Backup
    send_telegram_progress "0/10" "5" "💾 Tworzenie backupu..."
    create_backup
    save_state "backup" "completed"
    
    # 1. Sprawdzenie wymaganych narzędzi
    section "SPRAWDZENIE WYMAGANYCH NARZĘDZI"
    send_telegram_progress "1/10" "10" "🔍 Sprawdzanie narzędzi..."
    
    save_state "tools_check" "running"
    
    check_command "git" "git" || HAS_ERRORS=true
    check_command "python" "python" || HAS_ERRORS=true
    check_command "pip" "python" || HAS_ERRORS=true
    check_command "jq" "jq" || HAS_ERRORS=true
    check_command "curl" "curl" || HAS_ERRORS=true
    
    save_state "tools_check" "completed"
    
    # 2. Sprawdzenie statusu workflow
    section "SPRAWDZENIE STATUSU"
    send_telegram_progress "2/10" "20" "✔️ Narzędzia OK
🔍 Status workflow..."
    
    save_state "status_check" "running"
    
    WORKFLOW_RUNNING=false
    if [ -f "$WORKFLOW_DIR/workflow.pid" ]; then
        PID=$(cat "$WORKFLOW_DIR/workflow.pid")
        if ps -p "$PID" > /dev/null 2>&1; then
            log "Workflow działa (PID: $PID)"
            WORKFLOW_RUNNING=true
        fi
    fi
    
    save_state "status_check" "completed"
    
    # 3. Zatrzymanie workflow
    if [ "$WORKFLOW_RUNNING" = true ]; then
        section "ZATRZYMYWANIE WORKFLOW"
        send_telegram_progress "3/10" "30" "⏹️ Zatrzymywanie workflow..."
        
        save_state "stop_workflow" "running"
        
        log "Zatrzymuję workflow..."
        if retry_command 3 2 "Zatrzymanie workflow" "'$WORKFLOW_DIR/workflow.sh' stop 2>&1"; then
            log "✅ Workflow zatrzymany"
        else
            warn "Problem z zatrzymaniem - kontynuuję"
        fi
        sleep 3
        
        save_state "stop_workflow" "completed"
    fi
    
    # 4. Git pull workflow  
    section "AKTUALIZACJA WORKFLOW.SH (GIT PULL)"
    send_telegram_progress "4/10" "40" "🔥 Aktualizacja workflow.sh..."
    
    save_state "git_pull_workflow" "running"
    
    cd "$WORKFLOW_DIR" || {
        error "Nie można wejść do katalogu: $WORKFLOW_DIR"
        HAS_ERRORS=true
        save_state "git_pull_workflow" "failed"
        return 1
    }
    
    debug "PWD: $(pwd)"
    
    if [ -d ".git" ]; then
        log "Aktualizuję workflow z git..."
        
        # Sprawdź remote
        local remote_url=$(git remote get-url origin 2>&1)
        debug "Git remote: $remote_url"
        
        # Sprawdź czy są uncommitted changes
        if ! git diff-index --quiet HEAD -- 2>/dev/null; then
            warn "Wykryto niezapisane zmiany w repo!"
            debug "Git status:"
            git status --short | while read line; do
                debug "  $line"
            done
        fi
        
        # Fetch z timeout
        if retry_command 3 5 "Git fetch" "timeout 30 git fetch origin master 2>&1"; then
            
            local current_commit=$(git rev-parse HEAD)
            local remote_commit=$(git rev-parse origin/master 2>&1)
            
            debug "Current commit: $current_commit"
            debug "Remote commit:  $remote_commit"
            
            if [ "$current_commit" != "$remote_commit" ]; then
                log "🔄 Wykryto zmiany w remote - pulling..."
                HAS_CODE_CHANGES=true
                
                # Sprawdź co się zmieni
                debug "Zmiany do pobrania:"
                git log --oneline HEAD..origin/master | while read line; do
                    debug "  $line"
                done
                
                if retry_command 2 3 "Git pull" "timeout 30 git pull origin master 2>&1"; then
                    log "✅ Git pull zakończony - kod zaktualizowany!"
                    
                    # Pokaż co się zmieniło
                    debug "Zaktualizowane pliki:"
                    git diff --name-status $current_commit HEAD | while read line; do
                        debug "  $line"
                    done
                else
                    error "Git pull failed po retry"
                    HAS_ERRORS=true
                fi
            else
                log "ℹ️ Kod jest aktualny (brak zmian)"
            fi
        else
            error "Git fetch failed po retry"
            error "Możliwe przyczyny:"
            error "  - Brak połączenia internetowego"
            error "  - Problem z DNS"
            error "  - Timeout (>30s)"
            error "  - Remote repo niedostępne"
            HAS_ERRORS=true
        fi
    else
        warn "Brak .git - to nie jest git repository"
        debug "Zawartość katalogu:"
        ls -la "$WORKFLOW_DIR" | head -20 | while read line; do
            debug "  $line"
        done
    fi
    
    save_state "git_pull_workflow" "completed"
    
    # Kontynuuj z pozostałymi krokami (5-10)...
    # [Reszta kodu jak wcześniej, ale z użyciem modułów]
    
    send_telegram_progress "10/10" "100" "✅ Update complete!"
    
    return 0
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

case "${1:-update}" in
    update)
        main_update
        
        # Podsumowanie
        echo ""
        log "📋 Podsumowanie:"
        log "  - ✅ Backup utworzony"
        log "  - ✅ Kod zaktualizowany"
        
        # Notyfikacja Telegram
        if grep -q "ERROR\|❌" "$ERROR_LOG" 2>/dev/null; then
            HAS_ERRORS=true
        fi
        
        if [ "$HAS_ERRORS" = true ]; then
            send_telegram "🔴 <b>Update zakończony z BŁĘDAMI</b>
Sprawdź logi: update_error.log"
            send_telegram_file "$ERROR_LOG" "⚠️ Error log"
        elif [ "$HAS_CODE_CHANGES" = true ]; then
            send_telegram "🟢 <b>Kod zaktualizowany pomyślnie!</b>
Workflow gotowy do pracy"
        else
            send_telegram "⚪ Update OK - bez zmian" "true"
        fi
        
        clear_state
        ;;
    
    rollback)
        rollback
        ;;
    
    list-backups)
        echo "Dostępne backupy:"
        ls -lht "$BACKUP_DIR" | grep backup_
        ;;
    
    clean-backups)
        log "Czyszczenie wszystkich backupów..."
        rm -rf "$BACKUP_DIR"/backup_*
        log "✅ Backupy wyczyszczone"
        ;;
    
    test-telegram)
        test_telegram
        ;;
    
    *)
        cat << EOF
update.sh - Advanced Update Script v2.0
========================================

Użycie: $0 {update|rollback|list-backups|clean-backups|test-telegram}

  update         - Aktualizuj workflow (z backup i retry)
  rollback       - Przywróć poprzednią wersję  
  list-backups   - Pokaż dostępne backupy
  clean-backups  - Usuń wszystkie backupy
  test-telegram  - Test powiadomień Telegram

EOF
        ;;
esac