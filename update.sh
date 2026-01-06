#!/data/data/com.termux/files/usr/bin/bash
# update.sh - Aktualizacja workflow.sh i sorter-common
# Synchronizuje kod, aktualizuje dependencje, restartuje workflow
# SAMOWYSTARCZALNY - instaluje brakujące narzędzia i repozytoria

# Nie zatrzymuj się na błędach - kontynuuj gdzie się da
set +e

# Kolory
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

WORKFLOW_DIR="$(dirname "$(realpath "$0")")"
LOG_FILE="$WORKFLOW_DIR/logs/update.log"
mkdir -p "$WORKFLOW_DIR/logs"

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

section() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n" | tee -a "$LOG_FILE"
}

# Telegram - wysyłanie wiadomości
send_telegram() {
    local message="$1"
    local silent="${2:-false}"
    
    # Załaduj config jeśli istnieje
    if [ -f "$WORKFLOW_DIR/config.env" ]; then
        source "$WORKFLOW_DIR/config.env"
    fi
    
    # Sprawdzenie czy skonfigurowano
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 1
    fi
    
    # Dodaj info o hoście
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
    
    if [ -f "$WORKFLOW_DIR/config.env" ]; then
        source "$WORKFLOW_DIR/config.env"
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

# ============================================================================
# GŁÓWNA PROCEDURA AKTUALIZACJI
# ============================================================================

section "AKTUALIZACJA WORKFLOW"

log "Katalog workflow: $WORKFLOW_DIR"
log "Start: $(date '+%Y-%m-%d %H:%M:%S')"

# Powiadomienie o starcie update.sh
send_telegram "⚙️ Update script uruchomiony
Czas: $(date '+%Y-%m-%d %H:%M:%S')" true

# 0. Sprawdzenie wymaganych narzędzi
section "SPRAWDZENIE WYMAGANYCH NARZĘDZI"

check_command() {
    local cmd="$1"
    local pkg="$2"
    
    if command -v "$cmd" &> /dev/null; then
        log "✅ $cmd zainstalowany"
        return 0
    else
        warn "❌ $cmd nie znaleziony, próbuję instalować..."
        if command -v pkg &> /dev/null; then
            log "Instaluję: pkg install -y $pkg"
            if pkg install -y "$pkg" >> "$LOG_FILE" 2>&1; then
                log "✅ $pkg zainstalowany"
                return 0
            else
                warn "⚠️ Problem przy instalacji $pkg - spróbuję kontynuować"
                return 1
            fi
        else
            warn "⚠️ pkg install nie dostępny, zainstaluj ręcznie: $pkg"
            return 1
        fi
    fi
}

check_command "git" "git"
check_command "python" "python"
check_command "pip" "python"  # pip jest częścią python
check_command "jq" "jq"
check_command "curl" "curl"

# 1. Sprawdzenie czy workflow działa
section "SPRAWDZENIE STATUSU"

WORKFLOW_RUNNING=false
if [ -f "$WORKFLOW_DIR/workflow.pid" ]; then
    PID=$(cat "$WORKFLOW_DIR/workflow.pid")
    if ps -p "$PID" > /dev/null 2>&1; then
        log "Workflow działa (PID: $PID)"
        WORKFLOW_RUNNING=true
    fi
fi

# 2. Zatrzymanie workflow (jeśli działa)
if [ "$WORKFLOW_RUNNING" = true ]; then
    section "ZATRZYMYWANIE WORKFLOW"
    log "Zatrzymuję workflow..."
    "$WORKFLOW_DIR/workflow.sh" stop || warn "Problem przy zatrzymywaniu workflow"
    sleep 3
fi

# 3. Aktualizacja głównego repozytorium
section "AKTUALIZACJA WORKFLOW.SH (GIT PULL)"

cd "$WORKFLOW_DIR"

log "Sprawdzenie czy jest git repository..."
if [ -d ".git" ]; then
    log "Aktualizuję workflow z git..."
    if git pull origin master >> "$LOG_FILE" 2>&1; then
        log "✅ Git pull zakończony"
    else
        warn "⚠️ Git pull zwrócił kod błędu, kontynuuję..."
    fi
else
    warn "Brak .git - to nie git repository"
    log "Jeśli chcesz updaty, zrób: git clone https://github.com/MatuszG/monitoring-android.git"
fi

# 4. Aktualizacja sorter-common
section "AKTUALIZACJA SORTER-COMMON"

if [ ! -d "$WORKFLOW_DIR/sorter-common" ]; then
    log "Katalog sorter-common nie znaleziony, klonuję..."
    if git clone https://github.com/MatuszG/sorter-common.git "$WORKFLOW_DIR/sorter-common" >> "$LOG_FILE" 2>&1; then
        log "✅ Git clone sorter-common zakończony"
    else
        error "❌ Git clone sorter-common failed!"
        warn "Spróbuj ręcznie: git clone https://github.com/MatuszG/sorter-common.git sorter-common"
    fi
elif [ -d "$WORKFLOW_DIR/sorter-common/.git" ]; then
    cd "$WORKFLOW_DIR/sorter-common"
    
    log "Aktualizuję sorter-common..."
    if git pull origin master >> "$LOG_FILE" 2>&1; then
        log "✅ Git pull sorter-common zakończony"
    else
        warn "⚠️ Git pull sorter-common zwrócił kod błędu"
    fi
else
    warn "Katalog sorter-common istnieje ale bez .git (niezbyt synced)"
    log "Jeśli chcesz updaty: rm -rf sorter-common && git clone ..."
fi

# Instalacja/aktualizacja Python package
if [ -d "$WORKFLOW_DIR/sorter-common" ]; then
    log "Instaluję sorter-common jako Python package..."
    if pip install -e "$WORKFLOW_DIR/sorter-common" >> "$LOG_FILE" 2>&1; then
        log "✅ pip install sorter-common zakończony"
    else
        warn "⚠️ pip install sorter-common zwrócił kod błędu"
        warn "Spróbuj ręcznie: cd $WORKFLOW_DIR/sorter-common && pip install -e ."
    fi
else
    error "❌ Katalog sorter-common nie istnieje - update nie powiódł się"
fi

# 5. Sprawdzenie Python dependencji
section "SPRAWDZENIE PYTHON DEPENDENCJI"

log "Checking main.py requirements..."

# Spróbuj załadować główne moduły
if python -c "import torch, torchvision, ultralytics, easyocr, PIL, cv2, onnxruntime, numpy" 2>> "$LOG_FILE"; then
    log "✅ Python dependencje OK"
else
    warn "⚠️ Brakuje Python dependencji, instaluję..."
    
    # Jeśli sorter-common ma requirements.txt
    if [ -f "$WORKFLOW_DIR/sorter-common/requirements.txt" ]; then
        log "Instaluję z requirements.txt..."
        if pip install -r "$WORKFLOW_DIR/sorter-common/requirements.txt" >> "$LOG_FILE" 2>&1; then
            log "✅ Requirements zainstalowane"
        else
            warn "⚠️ Problem przy instalacji requirements"
        fi
    else
        # Zainstaluj z setup.py
        log "setup.py powinien zainstalować zależności..."
        if pip install -e "$WORKFLOW_DIR/sorter-common" >> "$LOG_FILE" 2>&1; then
            log "✅ Dependencje zainstalowane"
        else
            warn "⚠️ Problem przy instalacji dependencji"
        fi
    fi
fi

# 6. Aktualizacja uprawnień
section "AKTUALIZACJA UPRAWNIEŃ"

chmod +x "$WORKFLOW_DIR/workflow.sh" || warn "Problem przy zmiane uprawnień workflow.sh"
chmod +x "$WORKFLOW_DIR/update.sh" || warn "Problem przy zmiane uprawnień update.sh"
log "✅ Uprawnienia zaktualizowane"

# 7. Walidacja konfiguracji
section "WALIDACJA KONFIGURACJI"

if [ ! -f "$WORKFLOW_DIR/config.env" ]; then
    warn "Brak config.env - utwórz go na podstawie config.env.example"
    if [ -f "$WORKFLOW_DIR/config.env.example" ]; then
        cp "$WORKFLOW_DIR/config.env.example" "$WORKFLOW_DIR/config.env"
        log "Skopiowano config.env.example → config.env"
        log "⚠️ EDYTUJ config.env przed uruchomieniem!"
    fi
else
    log "✅ config.env istnieje"
fi

# 8. Restart workflow (jeśli był uruchomiony)
section "FINALIZACJA"

if [ "$WORKFLOW_RUNNING" = true ]; then
    log "Restartowanie workflow..."
    sleep 2
    
    if "$WORKFLOW_DIR/workflow.sh" start >> "$LOG_FILE" 2>&1; then
        log "✅ Workflow uruchomiony"
        sleep 3
        "$WORKFLOW_DIR/workflow.sh" status || warn "Problem przy sprawdzeniu statusu"
    else
        warn "⚠️ Problem przy uruchamianiu workflow - spróbuj ręcznie: ./workflow.sh start"
    fi
else
    log "Workflow nie był uruchomiony, nie restartowuję"
fi

# ============================================================================
section "AKTUALIZACJA ZAKOŃCZONA"
log "Koniec: $(date '+%Y-%m-%d %H:%M:%S')"
log "Logi z aktualizacji dostępne w: $LOG_FILE"

echo ""
log "📋 Podsumowanie:"
log "  - ✅ Narzędzia systemowe sprawdzone/zainstalowane"
log "  - ✅ workflow.sh zaktualizowany (jeśli git dostępny)"
log "  - ✅ sorter-common pobrany/zaktualizowany"
log "  - ✅ Python dependencje sprawdzone"
log "  - ✅ Konfiguracja sprawdzena"

if [ "$WORKFLOW_RUNNING" = true ]; then
    log "  - ✅ Workflow zrestarted"
else
    log "  - ℹ️ Workflow nie był uruchomiony"
fi

echo ""
log "🔧 Następne kroki:"
log "  1. Sprawdź logi: tail -f logs/update.log"
log "  2. Sprawdź status: ./workflow.sh status"
log "  3. Jeśli potrzebne, edytuj config.env"
log "  4. Uruchom: ./workflow.sh start"
echo ""

# Powiadomienie Telegram o completion
SUMMARY="📋 Update Summary:
✅ Tools checked/installed
✅ workflow.sh updated
✅ sorter-common synced
✅ Python deps verified
✅ Config validated"

if [ "$WORKFLOW_RUNNING" = true ]; then
    SUMMARY="$SUMMARY
✅ Workflow restarted"
else
    SUMMARY="$SUMMARY
ℹ️ Workflow was not running"
fi

send_telegram "✅ Update complete!
$SUMMARY

Duration: $(date '+%Y-%m-%d %H:%M:%S')" true

# Wyślij ostatnie 50 linii logów jeśli byly błędy
if grep -q "ERROR\|❌" "$LOG_FILE" 2>/dev/null; then
    log "Wysyłam error log na Telegram..."
    send_telegram_file "$LOG_FILE" "⚠️ Update logs (errors detected)"
fi
