#!/bin/bash
# Logging Module - Zarządzanie logami, rotacją, i zmiennymi kolorów
# Przeznaczenie: Centralizacja logowania dla całego systemu

# Kolory
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m'

# Maksymalny rozmiar logu (10MB)
export MAX_LOG_SIZE=10485760

# ============================================================================
# GŁÓWNE FUNKCJE LOGOWANIA
# ============================================================================

# Standardowe logowanie (info)
log() {
    local message="$1"
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $message" | tee -a "$LOG_FILE"
}

# Ostrzeżenie
warn() {
    local message="$1"
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $message" | tee -a "$LOG_FILE"
}

# Błąd
error() {
    local message="$1"
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $message" | tee -a "$ERROR_LOG"
}

# Debug (tylko jeśli DEBUG=1)
debug() {
    local message="$1"
    if [ "${DEBUG:-0}" = "1" ]; then
        echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $message" | tee -a "$LOG_FILE"
    fi
}

# Info w niebieskim
info() {
    local message="$1"
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $message" | tee -a "$LOG_FILE"
}

# Nagłówek sekcji (z linią)
section() {
    local title="$1"
    echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $title${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}\n"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === $title ===" >> "$LOG_FILE"
}

# Rotacja logów
rotate_logs() {
    # Rotuj LOG_FILE jeśli przekrocza maksymalny rozmiar
    if [ -f "$LOG_FILE" ]; then
        local size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            local timestamp=$(date +%Y%m%d-%H%M%S)
            mv "$LOG_FILE" "$LOG_FILE.${timestamp}"
            debug "Rotacja log file: $LOG_FILE → $LOG_FILE.${timestamp}"
            
            # Kompresuj stary log
            gzip -f "$LOG_FILE.${timestamp}" 2>/dev/null || true
        fi
    fi
    
    # Rotuj ERROR_LOG
    if [ -f "$ERROR_LOG" ]; then
        local size=$(stat -f%z "$ERROR_LOG" 2>/dev/null || stat -c%s "$ERROR_LOG" 2>/dev/null)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            local timestamp=$(date +%Y%m%d-%H%M%S)
            mv "$ERROR_LOG" "$ERROR_LOG.${timestamp}"
            debug "Rotacja error log: $ERROR_LOG → $ERROR_LOG.${timestamp}"
            
            # Kompresuj stary log
            gzip -f "$ERROR_LOG.${timestamp}" 2>/dev/null || true
        fi
    fi
}

# Wypisz ostatnie logi
show_recent_logs() {
    local lines="${1:-50}"
    echo ""
    echo "=== Ostatnie $lines linii logów ===" 
    echo ""
    tail -n "$lines" "$LOG_FILE"
    echo ""
}

# Wypisz ostatnie błędy
show_recent_errors() {
    local lines="${1:-20}"
    echo ""
    echo "=== Ostatnie $lines błędów ===" 
    echo ""
    tail -n "$lines" "$ERROR_LOG"
    echo ""
}

# Sprawdź czy są błędy w logach
check_errors_in_logs() {
    # Zwraca 0 (true) jeśli są błędy, 1 (false) jeśli nie ma
    if grep -iq "ERROR\|FAILED\|❌" "$ERROR_LOG" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Liczba błędów
count_errors() {
    grep -ic "ERROR" "$ERROR_LOG" 2>/dev/null || echo "0"
}

# Liczba ostrzeżeń
count_warnings() {
    grep -ic "WARN" "$LOG_FILE" 2>/dev/null || echo "0"
}

export -f log
export -f warn
export -f error
export -f debug
export -f info
export -f section
export -f rotate_logs
export -f show_recent_logs
export -f show_recent_errors
export -f check_errors_in_logs
export -f count_errors
export -f count_warnings
