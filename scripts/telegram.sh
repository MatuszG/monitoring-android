#!/bin/bash
# Telegram Module - Powiadomienia, progress bar, wysyłanie plików
# Przeznaczenie: Cała logika komunikacji z Telegram Bot API

# ============================================================================
# ZMIENNE GLOBALNE
# ============================================================================

export TELEGRAM_BOT_TOKEN=""
export TELEGRAM_CHAT_ID=""

# ============================================================================
# WYSYŁANIE PODSTAWOWYCH WIADOMOŚCI
# ============================================================================

send_telegram() {
    local message="$1"
    local silent="${2:-false}"
    
    # Załaduj sekrety jeśli nie są dostępne
    ensure_secrets_loaded
    
    # Fallback na config.env jeśli sekrety nie działają
    if [ -z "$TELEGRAM_BOT_TOKEN" ] && [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    # Sprawdzenie czy skonfigurowano
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        debug "Telegram nie skonfigurowany - pomijam wiadomość"
        return 1
    fi
    
    # Konstruowanie pełnej wiadomości
    local full_message="${message}"
    
    # Wysłanie
    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${full_message}" \
        -d "parse_mode=HTML" \
        -d "disable_notification=${silent}" \
        > /dev/null 2>&1
    
    return $?
}

# ============================================================================
# WYSYŁANIE PLIKÓW
# ============================================================================

send_telegram_file() {
    local file_path="$1"
    local caption="${2:-Log file}"
    
    # Załaduj sekrety jeśli nie są dostępne
    ensure_secrets_loaded
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        debug "Telegram nie skonfigurowany - pomijam plik"
        return 1
    fi
    
    if [ ! -f "$file_path" ]; then
        warn "Plik do wysłania nie istnieje: $file_path"
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
# PROGRESS BAR Z EMOTKAMI
# ============================================================================

send_telegram_progress() {
    local stage="$1"          # np. "1/8"
    local percent="$2"        # np. "12"
    local message="$3"        # Dodatkowa wiadomość
    
    # Oblicz progress bar (20 znaków)
    local filled=$((percent / 5))
    local empty=$((20 - filled))
    local bar=""
    
    for ((i=0; i<filled; i++)); do
        bar="${bar}█"
    done
    for ((i=0; i<empty; i++)); do
        bar="${bar}░"
    done
    
    # Konstruuj wiadomość z progress bar
    local full_message="📊 Etap: ${stage}
${bar} ${percent}%

${message}"
    
    send_telegram "$full_message" "true"  # silent=true
}

# ============================================================================
# POWIADOMIENIA Z IKONKAMI
# ============================================================================

notify_success() {
    local message="$1"
    send_telegram "✅ $message"
}

notify_error() {
    local message="$1"
    send_telegram "❌ $message"
}

notify_warning() {
    local message="$1"
    send_telegram "⚠️  $message"
}

notify_info() {
    local message="$1"
    send_telegram "ℹ️  $message"
}

notify_running() {
    local message="$1"
    send_telegram "▶️  $message"
}

# ============================================================================
# KONFIGURACJA TELEGRAM
# ============================================================================

setup_telegram() {
    log "=== Konfiguracja powiadomień Telegram (Szyfrowana) ==="
    
    # Sprawdź czy już mamy w szyfrowanym pliku
    if [ -f "$SECRETS_FILE" ]; then
        read -p "Zmienić istniejące dane Telegram? (t/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Tt]$ ]]; then
            return 0
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
    
    # Pobierz hasło jeśli to edycja, inaczej init_secrets go ustawi
    if [ ! -f "$SECRETS_FILE" ]; then
        init_secrets
        if [ $? -ne 0 ]; then
            error "Nie mogę inicjalizować sekretów"
            return 1
        fi
    fi
    
    # Odszyfrujem, edytuję, reszyfrowanie
    read -sp "Wpisz główne hasło do aktualizacji danych: " master_password
    echo ""
    
    if ! verify_master_password "$master_password"; then
        error "❌ Błędne hasło!"
        return 1
    fi
    
    # Odszyfruj
    local temp_file=$(mktemp)
    openssl enc -aes-256-cbc -d -in "$SECRETS_FILE" \
        -k "$master_password" -out "$temp_file" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        error "Błąd przy odszyfrowaniu!"
        rm -f "$temp_file"
        return 1
    fi
    
    # Aktualizuj dane
    sed -i "s/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=\"$bot_token\"/" "$temp_file"
    sed -i "s/^TELEGRAM_CHAT_ID=.*/TELEGRAM_CHAT_ID=\"$chat_id\"/" "$temp_file"
    
    # Reszyfruj
    openssl enc -aes-256-cbc -salt -in "$temp_file" \
        -out "$SECRETS_FILE" -k "$master_password" -p 2>/dev/null
    
    rm -f "$temp_file"
    chmod 600 "$SECRETS_FILE"
    
    # Załaduj nowe wartości
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

# ============================================================================
# TEST TELEGRAM
# ============================================================================

test_telegram() {
    log "Test powiadomienia Telegram..."
    ensure_secrets_loaded
    
    if send_telegram "🧪 Test powiadomienia
Czas: $(date '+%Y-%m-%d %H:%M:%S')
Status: ✅ Działa poprawnie"; then
        log "✓ Test powiadomienia wysłany"
        return 0
    else
        error "✗ Nie mogę wysłać test powiadomienia"
        return 1
    fi
}

export -f send_telegram
export -f send_telegram_file
export -f send_telegram_progress
export -f notify_success
export -f notify_error
export -f notify_warning
export -f notify_info
export -f notify_running
export -f setup_telegram
export -f test_telegram
