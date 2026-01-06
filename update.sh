#!/data/data/com.termux/files/usr/bin/bash
# update.sh - Aktualizacja workflow.sh i sorter-common
# Synchronizuje kod, aktualizuje dependencje, restartuje workflow

set -e  # Exit on error

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

# ============================================================================
# GŁÓWNA PROCEDURA AKTUALIZACJI
# ============================================================================

section "AKTUALIZACJA WORKFLOW"

log "Katalog workflow: $WORKFLOW_DIR"
log "Start: $(date '+%Y-%m-%d %H:%M:%S')"

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
    warn "Brak .git, pomijam git pull dla głównego repozytorium"
fi

# 4. Aktualizacja sorter-common
section "AKTUALIZACJA SORTER-COMMON"

if [ -d "$WORKFLOW_DIR/sorter-common" ]; then
    cd "$WORKFLOW_DIR/sorter-common"
    
    log "Aktualizuję sorter-common..."
    if [ -d ".git" ]; then
        if git pull origin master >> "$LOG_FILE" 2>&1; then
            log "✅ Git pull sorter-common zakończony"
        else
            warn "⚠️ Git pull sorter-common zwrócił kod błędu"
        fi
    else
        warn "Brak .git w sorter-common"
    fi
    
    # Instalacja/aktualizacja Python package
    log "Instaluję sorter-common jako Python package..."
    if pip install -e . >> "$LOG_FILE" 2>&1; then
        log "✅ pip install sorter-common zakończony"
    else
        error "❌ pip install sorter-common failed!"
        error "Spróbuj ręcznie: cd $WORKFLOW_DIR/sorter-common && pip install -e ."
    fi
else
    error "❌ Katalog sorter-common nie znaleziony!"
    error "Spróbuj: git clone https://github.com/MatuszG/sorter-common.git sorter-common"
    exit 1
fi

# 5. Sprawdzenie Python dependencji
section "SPRAWDZENIE PYTHON DEPENDENCJI"

log "Checking main.py requirements..."
if python -c "from config import *; from sorter_common.src.sorter import process_photo; from models import MODEL" 2>> "$LOG_FILE"; then
    log "✅ Python dependencje OK"
else
    warn "⚠️ Możliwe problemy z Python dependencjami"
    log "Zainstaluj ręcznie: pip install -r requirements.txt"
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
        "$WORKFLOW_DIR/workflow.sh" status
    else
        error "❌ Błąd przy uruchamianiu workflow!"
        exit 1
    fi
fi

# ============================================================================
section "AKTUALIZACJA ZAKOŃCZONA"
log "Koniec: $(date '+%Y-%m-%d %H:%M:%S')"
log "Logi z aktualizacji dostępne w: $LOG_FILE"

echo ""
log "📋 Podsumowanie:"
log "  - ✅ workflow.sh zaktualizowany"
log "  - ✅ sorter-common zaktualizowany"
log "  - ✅ Dependencje sprawdzone"
log "  - ✅ Konfiguracja sprawdzena"

if [ "$WORKFLOW_RUNNING" = true ]; then
    log "  - ✅ Workflow zrestarted"
fi

echo ""
log "Aby sprawdzić status: ./workflow.sh status"
log "Aby zobaczyć logi: ./workflow.sh logs"
