#!/bin/bash
# Secrets Management Module - Encrypted storage dla tokeny, hasła, etc
# Przeznaczenie: Zarządzanie wrażliwymi danymi z szyfrowaniem AES-256

# ============================================================================
# ZMIENNE GLOBALNE
# ============================================================================

export SECRETS_DIR="$HOME/.secrets"
export SECRETS_FILE="$SECRETS_DIR/config.enc"
export SECRETS_HASH_FILE="$SECRETS_DIR/.hash"

# ============================================================================
# INICJALIZACJA SYSTEMU SZYFROWANIA
# ============================================================================

init_secrets() {
    log "Inicjalizacja systemu szyfrowania..."
    
    if [ ! -d "$SECRETS_DIR" ]; then
        mkdir -p "$SECRETS_DIR" || { error "Nie mogę stworzyć $SECRETS_DIR"; return 1; }
        chmod 700 "$SECRETS_DIR"
        log "✅ Katalog $SECRETS_DIR utworzony (uprawnienia: 700)"
    fi
    
    if [ -f "$SECRETS_FILE" ]; then
        log "✓ Plik secrets już istnieje"
        return 0
    fi
    
    section "KONFIGURACJA SZYFROWANYCH TAJEMNIC"
    
    log "Ustaw GŁÓWNE HASŁO do szyfrowania danych (min 12 znaków)"
    log "To hasło będzie wymagane podczas startu workflow"
    echo ""
    
    read -sp "Wpisz hasło: " master_password
    echo ""
    read -sp "Powtórz hasło: " master_password_confirm
    echo ""
    
    if [ "$master_password" != "$master_password_confirm" ]; then
        error "Hasła się nie zgadzają!"
        return 1
    fi
    
    if [ ${#master_password} -lt 12 ]; then
        error "Hasło musi mieć co najmniej 12 znaków!"
        return 1
    fi
    
    # Przygotuj plik z domyślnymi sekretami
    cat > "$SECRETS_DIR/.config.txt" << 'EOF'
# Wrażliwe dane - zostaną zaszyfrowane
# Format: KLUCZ=WARTOŚĆ

TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
RCLONE_PASSWORD=""
RCLONE_API_KEY=""
GIT_PAT_TOKEN=""
EOF
    
    chmod 600 "$SECRETS_DIR/.config.txt"
    
    # Zaszyfruj plik przy użyciu openssl
    openssl enc -aes-256-cbc -salt -in "$SECRETS_DIR/.config.txt" \
        -out "$SECRETS_FILE" -k "$master_password" -p 2>/dev/null
    
    if [ $? -eq 0 ]; then
        # Zapisz SHA256 hasła dla weryfikacji
        echo -n "$master_password" | sha256sum | cut -d' ' -f1 > "$SECRETS_HASH_FILE"
        chmod 600 "$SECRETS_HASH_FILE"
        
        rm -f "$SECRETS_DIR/.config.txt"
        chmod 600 "$SECRETS_FILE"
        
        log "✅ Plik sekretów zaszyfrowany i zapisany w: $SECRETS_FILE"
        log "⚠️  WAŻNE: Zapamiętaj hasło! Będzie wymagane do uruchamiania workflow."
        return 0
    else
        error "Błąd przy szyfrowaniu pliku!"
        return 1
    fi
}

# ============================================================================
# WERYFIKACJA HASŁA
# ============================================================================

verify_master_password() {
    local password="$1"
    
    if [ ! -f "$SECRETS_HASH_FILE" ]; then
        return 1
    fi
    
    local stored_hash=$(cat "$SECRETS_HASH_FILE")
    local provided_hash=$(echo -n "$password" | sha256sum | cut -d' ' -f1)
    
    if [ "$stored_hash" = "$provided_hash" ]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# ŁADOWANIE SEKRETÓW
# ============================================================================

load_secrets() {
    if [ ! -f "$SECRETS_FILE" ]; then
        debug "Brak szyfrowanego pliku sekretów - pomijam ładowanie"
        return 0
    fi
    
    log "Wprowadzenie głównego hasła wymagane..."
    read -sp "Wpisz główne hasło: " master_password
    echo ""
    
    # Weryfikuj hasło
    if ! verify_master_password "$master_password"; then
        error "❌ Błędne hasło!"
        return 1
    fi
    
    # Odszyfruj plik
    local decrypted_content=$(openssl enc -aes-256-cbc -d -in "$SECRETS_FILE" \
        -k "$master_password" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        error "Błąd przy odszyfrowaniu sekretów!"
        return 1
    fi
    
    # Załaduj zmienne ze zdeszyfryowanego pliku
    eval "$decrypted_content"
    
    # Exportuj zmienne
    export TELEGRAM_BOT_TOKEN
    export TELEGRAM_CHAT_ID
    export RCLONE_PASSWORD
    export RCLONE_API_KEY
    export GIT_PAT_TOKEN
    
    # Zapisz hasło w zmiennej globalnej (dla automation)
    export MASTER_PASSWORD="$master_password"
    
    log "✅ Tajemnice załadowane"
    return 0
}

# ============================================================================
# EDYCJA SEKRETÓW
# ============================================================================

edit_secrets() {
    if [ ! -f "$SECRETS_FILE" ]; then
        error "Plik sekretów nie istnieje! Uruchom: ./workflow.sh secrets-init"
        return 1
    fi
    
    read -sp "Wpisz główne hasło do edycji: " master_password
    echo ""
    
    if ! verify_master_password "$master_password"; then
        error "❌ Błędne hasło!"
        return 1
    fi
    
    # Odszyfruj do tymczasowego pliku
    local temp_file=$(mktemp)
    openssl enc -aes-256-cbc -d -in "$SECRETS_FILE" \
        -k "$master_password" -out "$temp_file" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        error "Błąd przy odszyfrowaniu!"
        rm -f "$temp_file"
        return 1
    fi
    
    log "Edytor: $(${EDITOR:-nano} --version | head -1 || echo "nano")"
    
    # Otwórz edytor
    ${EDITOR:-nano} "$temp_file"
    
    # Zaszyfruj z powrotem
    openssl enc -aes-256-cbc -salt -in "$temp_file" \
        -out "$SECRETS_FILE" -k "$master_password" -p 2>/dev/null
    
    rm -f "$temp_file"
    log "✅ Sekrety zaktualizowane"
}

# ============================================================================
# AUTOMATYCZNE ŁADOWANIE W SEND_TELEGRAM
# ============================================================================

ensure_secrets_loaded() {
    # Jeśli sekrety istnieją ale nie są załadowane - załaduj je
    if [ -f "$SECRETS_FILE" ] && [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        debug "Automatyczne ładowanie sekretów..."
        if [ -n "$MASTER_PASSWORD" ]; then
            # Mamy hasło w zmiennej - użyj go
            local decrypted=$(openssl enc -aes-256-cbc -d -in "$SECRETS_FILE" \
                -k "$MASTER_PASSWORD" 2>/dev/null)
            eval "$decrypted"
        fi
    fi
}

export -f init_secrets
export -f verify_master_password
export -f load_secrets
export -f edit_secrets
export -f ensure_secrets_loaded
