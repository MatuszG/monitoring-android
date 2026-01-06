#!/bin/bash
# Rclone Module - Synchronizacja z Google Drive
# Przeznaczenie: Bidirectional sync incoming <-> sorted photos

# ============================================================================
# ZMIENNE GLOBALNE
# ============================================================================

export RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"
export RCLONE_ROOT="${RCLONE_ROOT:-}"
export INCOMING_DIR="${INCOMING_DIR:-/mnt/incoming}"
export SORTED_DIR="${SORTED_DIR:-/mnt/sorted}"
export GDRIVE_PATH="${GDRIVE_PATH:-Posortowane}"

# Timeouty
export RCLONE_SYNC_TIMEOUT=60    # Sync timeout w sekundach
export RCLONE_UPLOAD_TIMEOUT=120 # Upload timeout

# ============================================================================
# KONFIGURACJA RCLONE
# ============================================================================

check_rclone() {
    if ! command -v rclone &> /dev/null; then
        error "rclone nie zainstalowany!"
        return 1
    fi
    
    # Sprawdzenie czy remote jest skonfigurowany
    if ! rclone listremotes | grep -q "^${RCLONE_REMOTE}$"; then
        error "rclone remote '$RCLONE_REMOTE' nie skonfigurowany"
        error "Uruchom: rclone config"
        return 1
    fi
    
    debug "✓ rclone dostępny i skonfigurowany"
    return 0
}

setup_rclone() {
    log "=== Konfiguracja RCLONE ==="
    
    if ! command -v rclone &> /dev/null; then
        warn "rclone nie zainstalowany - pomijam"
        return 1
    fi
    
    echo ""
    echo "Aby skonfigurować rclone dla Google Drive:"
    echo "1. Uruchom: rclone config"
    echo "2. Wybierz: n) New remote"
    echo "3. Nazwa: $RCLONE_REMOTE"
    echo "4. Typ: google drive"
    echo "5. Zaloguj się do Google"
    echo ""
    
    read -p "Uruchomić konfigurację rclone? (t/N): " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Tt]$ ]]; then
        rclone config
        log "✓ Konfiguracja rclone zakończona"
    fi
}

# ============================================================================
# SYNCHRONIZACJA PRZYCHODZĄCYCH ZDJĘĆ
# ============================================================================

sync_rclone_incoming() {
    # Pobierz nowe zdjęcia z Google Drive
    log "Synchronizacja przychodzących zdjęć z Google Drive..."
    debug "Komenda: rclone sync $RCLONE_REMOTE:$RCLONE_ROOT $INCOMING_DIR"
    
    if ! check_rclone; then
        error "rclone nie jest dostępny"
        return 1
    fi
    
    # Utwórz katalog jeśli nie istnieje
    mkdir -p "$INCOMING_DIR" 2>/dev/null || {
        error "Nie mogę stworzyć $INCOMING_DIR"
        return 1
    }
    
    # Wykonaj sync z timeoutem
    timeout "$RCLONE_SYNC_TIMEOUT" rclone sync \
        "$RCLONE_REMOTE:$RCLONE_ROOT" "$INCOMING_DIR" \
        --transfers 4 \
        --checkers 8 \
        --verbose \
        --log-file "$LOG_FILE" 2>&1
    
    local sync_status=$?
    
    if [ $sync_status -eq 0 ]; then
        local file_count=$(find "$INCOMING_DIR" -type f | wc -l)
        log "✓ Sync incoming: $file_count plików do przetworzenia"
        return 0
    elif [ $sync_status -eq 124 ]; then
        error "Sync timeout ($RCLONE_SYNC_TIMEOUT s) - sieć powolna?"
        return 1
    else
        error "Sync failed (status: $sync_status)"
        return 1
    fi
}

# ============================================================================
# WYSYŁANIE POSORTOWANYCH ZDJĘĆ
# ============================================================================

sync_rclone_upload() {
    # Wyślij posortowane zdjęcia z powrotem do Google Drive
    log "Wysyłanie posortowanych zdjęć do Google Drive..."
    debug "Komenda: rclone sync $SORTED_DIR $RCLONE_REMOTE:$RCLONE_ROOT/$GDRIVE_PATH"
    
    if ! check_rclone; then
        error "rclone nie jest dostępny"
        return 1
    fi
    
    # Sprawdzenie czy są zdjęcia do wysłania
    if [ ! -d "$SORTED_DIR" ] || [ -z "$(find "$SORTED_DIR" -type f)" ]; then
        debug "Brak zdjęć do wysłania (pusty sorted_dir)"
        return 0
    fi
    
    # Wykonaj sync z timeoutem
    timeout "$RCLONE_UPLOAD_TIMEOUT" rclone sync \
        "$SORTED_DIR" "$RCLONE_REMOTE:$RCLONE_ROOT/$GDRIVE_PATH" \
        --transfers 4 \
        --checkers 8 \
        --verbose \
        --log-file "$LOG_FILE" 2>&1
    
    local upload_status=$?
    
    if [ $upload_status -eq 0 ]; then
        local file_count=$(find "$SORTED_DIR" -type f | wc -l)
        log "✓ Upload: $file_count plików wysłanych"
        return 0
    elif [ $upload_status -eq 124 ]; then
        error "Upload timeout ($RCLONE_UPLOAD_TIMEOUT s) - pliki zbyt duże?"
        return 1
    else
        error "Upload failed (status: $upload_status)"
        return 1
    fi
}

# ============================================================================
# SPRAWDZENIE STATUSU SYNC
# ============================================================================

check_rclone_status() {
    if ! check_rclone; then
        return 1
    fi
    
    section "RCLONE STATUS"
    
    echo "Remote: $RCLONE_REMOTE"
    echo "Path: $RCLONE_ROOT"
    echo ""
    
    echo "Incoming directory:"
    du -sh "$INCOMING_DIR" 2>/dev/null || echo "  (nie istnieje)"
    
    echo ""
    echo "Sorted directory:"
    du -sh "$SORTED_DIR" 2>/dev/null || echo "  (nie istnieje)"
    
    echo ""
    echo "Remote storage:"
    rclone size "$RCLONE_REMOTE:$RCLONE_ROOT" --json 2>/dev/null | \
        grep -o '"bytes":[0-9]*' || echo "  (nie mogę sprawdzić)"
    
    echo ""
}

# ============================================================================
# CZYSZCZENIE CACHE
# ============================================================================

cleanup_rclone() {
    log "Czyszczenie rclone cache..."
    
    # Rclone cache jest zwykle w ~/.cache/rclone/
    if [ -d "$HOME/.cache/rclone" ]; then
        find "$HOME/.cache/rclone" -type f -mtime +7 -delete 2>/dev/null
        log "✓ Cache starsze niż 7 dni usunięte"
    fi
}

export -f check_rclone
export -f setup_rclone
export -f sync_rclone_incoming
export -f sync_rclone_upload
export -f check_rclone_status
export -f cleanup_rclone
