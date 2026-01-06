#!/bin/bash
# Git Configuration Module - Zarządzanie Git auth, auto-pull, change detection
# Przeznaczenie: Wszystko związane z Git operations dla auto-update

# ============================================================================
# KONFIGURACJA GIT
# ============================================================================

setup_git_config() {
    log "=== Konfiguracja Git ==="
    
    # Sprawdzenie czy git jest zainstalowany
    if ! command -v git &> /dev/null; then
        warn "Git nie zainstalowany - pomijam konfigurację"
        return 1
    fi
    
    # Sprawdzenie czy już skonfigurowano
    if git config --global user.name > /dev/null 2>&1; then
        local current_user=$(git config --global user.name)
        echo ""
        echo "Git już skonfigurowany dla: $current_user"
        read -p "Zmienić konfigurację? (t/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Tt]$ ]]; then
            return 0
        fi
    fi
    
    echo ""
    echo "Konfiguracja Git dla automatycznych pull/push"
    echo ""
    
    # Ustawienia Git
    read -p "Git user.name: " git_name
    read -p "Git user.email: " git_email
    
    git config --global user.name "$git_name"
    git config --global user.email "$git_email"
    git config --global core.autocrlf input
    
    log "✓ Ustawienia Git: user.name = $git_name"
    
    # Menu autentykacji
    echo ""
    echo "Metody autentykacji Git:"
    echo "1) Personal Access Token (PAT) - Polecane"
    echo "2) Password + Cache (24h) - Mniej bezpieczne"
    echo "3) SSH Key - Wymaga ręcznej konfiguracji"
    echo ""
    read -p "Wybierz metodę (1-3): " auth_method
    
    case $auth_method in
        1)
            setup_git_pat
            ;;
        2)
            setup_git_password_cache
            ;;
        3)
            setup_git_ssh
            ;;
        *)
            warn "Nieznana opcja"
            return 1
            ;;
    esac
}

# ============================================================================
# GIT: PERSONAL ACCESS TOKEN (PAT)
# ============================================================================

setup_git_pat() {
    echo ""
    echo "Personal Access Token Setup"
    echo "=========================="
    echo "1. GitHub: https://github.com/settings/tokens"
    echo "2. Wygeneruj nowy token (repo scope)"
    echo "3. Skopiuj token poniżej"
    echo ""
    
    read -sp "Wpisz token (będzie zaszyfrowany): " git_token
    echo ""
    
    # Zapisz w ~/.git-credentials (standard Git)
    {
        echo "https://$git_token@github.com"
    } > "$HOME/.git-credentials"
    
    chmod 600 "$HOME/.git-credentials"
    
    # Skonfiguruj Git aby używał credential helper
    git config --global credential.helper store
    
    log "✓ Token PAT zapisany w ~/.git-credentials (chmod 600)"
}

# ============================================================================
# GIT: PASSWORD CACHE
# ============================================================================

setup_git_password_cache() {
    echo ""
    echo "Password Cache Setup"
    echo "===================="
    echo "Hasła będą pamiętane przez 24 godziny"
    echo ""
    
    # Skonfiguruj Git cache na 24h (86400 sekund)
    git config --global credential.helper 'cache --timeout=86400'
    
    log "✓ Git credential cache: 24 godziny"
}

# ============================================================================
# GIT: SSH KEY
# ============================================================================

setup_git_ssh() {
    echo ""
    echo "SSH Key Setup"
    echo "============="
    echo "Wymaga ręcznego ustawienia SSH key w GitHub"
    echo ""
    
    # Sprawdź czy jest SSH key
    if [ -f "$HOME/.ssh/id_rsa" ]; then
        log "✓ SSH key już istnieje: $HOME/.ssh/id_rsa"
    else
        warn "SSH key nie znaleziony. Utwórz go komendą:"
        warn "ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa"
    fi
    
    # Skonfiguruj SSH protocol
    git config --global url."git@github.com:".insteadOf "https://github.com/"
    
    log "✓ Git skonfigurowany do SSH"
}

# ============================================================================
# GIT: DETEKT ZMIAN
# ============================================================================

detect_git_changes() {
    # Sprawdza czy kod się zmienił od ostatniej aktualizacji
    # Zwraca 0 (true) jeśli są zmiany, 1 (false) jeśli nie
    
    if ! command -v git &> /dev/null; then
        return 1
    fi
    
    # Pobierz najnowsze info z remote
    git fetch origin master > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        debug "Git fetch failed - nie mogę sprawdzić zmian"
        return 1
    fi
    
    # Porównaj local vs remote
    local local_hash=$(git rev-parse HEAD 2>/dev/null)
    local remote_hash=$(git rev-parse origin/master 2>/dev/null)
    
    if [ "$local_hash" != "$remote_hash" ]; then
        debug "Git changes detected: $local_hash != $remote_hash"
        return 0
    fi
    
    return 1
}

# ============================================================================
# GIT: AUTO-PULL
# ============================================================================

auto_git_pull() {
    # Automatycznie pull latest changes
    
    if ! command -v git &> /dev/null; then
        debug "Git nie dostępny"
        return 1
    fi
    
    log "Aktualizuję kod z repozytorium..."
    
    # Wykonaj git pull
    if git pull origin master > /dev/null 2>&1; then
        log "✓ Git pull zakończony pomyślnie"
        return 0
    else
        error "Git pull failed"
        return 1
    fi
}

# ============================================================================
# GIT: STATUS
# ============================================================================

show_git_status() {
    if ! command -v git &> /dev/null; then
        warn "Git nie zainstalowany"
        return 1
    fi
    
    echo ""
    echo "=== Git Status ==="
    echo ""
    git status --porcelain
    echo ""
    
    echo "=== Git Log (ostatnie 5 commitów) ==="
    echo ""
    git log --oneline -5
    echo ""
}

export -f setup_git_config
export -f setup_git_pat
export -f setup_git_password_cache
export -f setup_git_ssh
export -f detect_git_changes
export -f auto_git_pull
export -f show_git_status
