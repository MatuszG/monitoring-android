#!/bin/bash
# Quick Reference Card
# Cała dokumentacja dostępnych komend

cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║         WORKFLOW 24/7 - QUICK REFERENCE CARD                   ║
║                  Version 2.0 (Refactored)                      ║
╚════════════════════════════════════════════════════════════════╝

PODSTAWOWE KOMENDY
══════════════════════════════════════════════════════════════════

  ./workflow.sh setup
  └─ Pierwsza konfiguracja (Telegram, Git, sekrety, uprawnienia)

  ./workflow.sh start
  └─ Uruchom daemon w tle (background process)

  ./workflow.sh stop
  └─ Zatrzymaj działający daemon

  ./workflow.sh restart
  └─ Restart daemon

  ./workflow.sh status
  └─ Sprawdź czy daemon działa + czas pracy

  ./workflow.sh logs
  └─ Podgląd logów na żywo (Ctrl+C aby wyjść)

  ./workflow.sh run
  └─ Uruchom workflow w foreground (bez daemonizacji)


TELEGRAM - POWIADOMIENIA
══════════════════════════════════════════════════════════════════

  ./workflow.sh telegram-test
  └─ Wyślij test powiadomienia

  ./workflow.sh telegram-config
  └─ Konfiguracja Telegram (token, chat ID)

  ./workflow.sh send-logs
  └─ Wyślij workflow.log + error.log na Telegram


ENCRYPTED SECRETS - BEZPIECZEŃSTWO
══════════════════════════════════════════════════════════════════

  ./workflow.sh secrets-init
  └─ Utwórz encrypted storage + ustaw hasło główne
  └─ (Wykonaj raz na początku)

  ./workflow.sh secrets-edit
  └─ Edytuj szyfrowane dane (tokeny, hasła)
  └─ Wymaga hasła głównego

  ./workflow.sh secrets-load
  └─ Ręczne załadowanie sekretów do zmiennych


GIT - WERSJONOWANIE
══════════════════════════════════════════════════════════════════

  ./workflow.sh git-status
  └─ Pokaż git status + ostatnie 5 commitów

  ./workflow.sh git-pull
  └─ Manual: git pull origin master


PIPELINE - PRZETWARZANIE
══════════════════════════════════════════════════════════════════

  ./workflow.sh pipeline-dry-run
  └─ Test pipeline bez faktycznych zmian
  └─ Sprawdza: incoming files, sorted dir, Python

  ./workflow.sh check-deps
  └─ Weryfikuj zależności: Python, main.py, rclone


UTILITIE - NARZĘDZIA
══════════════════════════════════════════════════════════════════

  ./workflow.sh update-logs
  └─ Pokaż ostatnie 50 linii z update.sh logów

  ./workflow.sh show-config
  └─ Wyświetl current config.env

  ./workflow.sh show-errors
  └─ Pokaż ostatnie 30 błędów z error.log

  ./workflow.sh help
  └─ Pokaż tę pomoc


WORKFLOW W PRAKTYCE
══════════════════════════════════════════════════════════════════

1. INSTALACJA (jedna raz)
   $ ./workflow.sh setup
   • Skonfiguruje Telegram
   • Skonfiguruje Git
   • Utworzy encrypted secrets
   • Ustawi uprawnienia

2. URUCHAMIANIE (każdy dzień)
   $ ./workflow.sh start
   $ ./workflow.sh status
   $ ./workflow.sh logs

3. MONITORING
   $ tail -f logs/workflow.log      # Live logs
   $ tail -f logs/error.log         # Errors only
   $ ./workflow.sh update-logs      # Last updates

4. TROUBLESHOOTING
   $ ./workflow.sh show-errors      # Recent errors
   $ DEBUG=1 ./workflow.sh run      # Verbose mode
   $ ./workflow.sh check-deps       # Verify setup


MODUŁY SYSTEMU
══════════════════════════════════════════════════════════════════

scripts/logging.sh         → Logowanie z kolorami
scripts/secrets.sh         → Encrypted storage (AES-256)
scripts/telegram.sh        → Powiadomienia + progress bar
scripts/git-config.sh      → Git authentication + auto-pull
scripts/rclone.sh          → Google Drive sync
scripts/pipeline.sh        → Photo processing orchestration

workflow-refactored.sh     → Main orchestrator (90 linii)


PLIKI KONFIGURACJI
══════════════════════════════════════════════════════════════════

config.env                 → Non-sensitive config (paths, rclone)
~/.secrets/config.enc      → Encrypted secrets (tokens, passwords)
workflow.pid               → Process ID (auto-created)
logs/workflow.log          → Main operations log
logs/error.log             → Errors only
logs/update.log            → Auto-update history


ZMIENNE ŚRODOWISKOWE
══════════════════════════════════════════════════════════════════

DEBUG=1                    → Enable debug logging
export DEBUG=1
./workflow.sh run

MASTER_PASSWORD="xxx"      → Avoid password prompt
export MASTER_PASSWORD="yourpass"
./workflow.sh start


PRZYKŁADY ZAAWANSOWANE
══════════════════════════════════════════════════════════════════

# Test pipeline (bez zmian w Drive)
$ ./workflow.sh pipeline-dry-run

# Edytuj Telegram token
$ ./workflow.sh secrets-edit
$ ./workflow.sh telegram-test

# Manual git pull z logem
$ DEBUG=1 ./workflow.sh git-pull

# View full update history
$ tail -f logs/update.log

# Restart daemon gracefully
$ ./workflow.sh restart

# Check if running (cron friendly)
$ ./workflow.sh status
$ echo $?  # 0=running, 1=stopped


TROUBLESHOOTING
══════════════════════════════════════════════════════════════════

Q: Daemon się nie uruchamia
A: $ ./workflow.sh run           # Run in foreground
   $ tail -f logs/error.log      # Check errors
   $ ./workflow.sh check-deps    # Verify setup

Q: Telegram nie wysyła
A: $ ./workflow.sh telegram-test # Test connection
   $ ./workflow.sh secrets-edit  # Verify token
   $ tail -f logs/error.log      # Check errors

Q: Git pull fails
A: $ ./workflow.sh git-status    # Check status
   $ git pull origin master      # Manual try
   $ ./workflow.sh secrets-edit  # Verify PAT token

Q: Zapomniałem hasła
A: $ rm -rf ~/.secrets/
   $ ./workflow.sh secrets-init  # Create new
   $ ./workflow.sh setup         # Reconfigure all


SYSTEM REQUIREMENTS
══════════════════════════════════════════════════════════════════

✓ Bash 4+
✓ Python 3.8+
✓ Git
✓ rclone
✓ curl
✓ openssl (dla secrets)
✓ jq (optional, dla JSON)


STRUKTURA KATALOGÓW
══════════════════════════════════════════════════════════════════

monitoring-android/
├── workflow.sh                  ← Main script (refactored)
├── update.sh                    ← Auto-update script
├── config.env                   ← Configuration
├── scripts/
│   ├── logging.sh
│   ├── secrets.sh
│   ├── telegram.sh
│   ├── git-config.sh
│   ├── rclone.sh
│   └── pipeline.sh
├── logs/
│   ├── workflow.log
│   ├── error.log
│   └── update.log
└── data/
    └── output.txt


PRZYDATNE LINKI
══════════════════════════════════════════════════════════════════

Pełna dokumentacja:
  - REFACTORING.md           → Architektura systemu
  - ENCRYPTED-SECRETS.md     → Security + encryption
  - README-UPDATE.md         → Auto-update mechanism
  - README.md                → General overview


SUPPORT & KONTAKT
══════════════════════════════════════════════════════════════════

Dokumentacja: ./REFACTORING.md
Encryption:   ./ENCRYPTED-SECRETS.md
Update:       ./README-UPDATE.md
Main:         ./README.md

Debugging:
  1. Czytaj logs/error.log
  2. Uruchom z DEBUG=1
  3. Czytaj odpowiedni plik w scripts/


═══════════════════════════════════════════════════════════════════
Ostatnia aktualizacja: 2026-01-06
Wersja: 2.0 (Refactored, Modular)
═══════════════════════════════════════════════════════════════════
EOF
