# 📚 Przewodnik Aktualizacji i Uruchamiania Workflow

Dokumentacja dla **monitoring-android** - automated photo sorting pipeline w Termux.

---

## 🚀 Szybki Start

### 1. Pierwsza konfiguracja

```bash
# Klonuj sorter-common (jeśli jeszcze nie)
git clone https://github.com/MatuszG/sorter-common.git sorter-common

# Setup środowiska (instalacja zależności, Telegram config)
./workflow.sh setup
```

### 2. Konfiguracja Telegram (opcjonalnie, ale rekomendowane)

```bash
# Interaktywna konfiguracja
./workflow.sh telegram-config

# Test powiadomienia
./workflow.sh telegram-test
```

### 3. Uruchomienie workflow

```bash
# Start daemon (w tle, 24/7)
./workflow.sh start

# Sprawdzenie statusu
./workflow.sh status

# Podgląd logów na żywo
./workflow.sh logs
```

### 4. Opcjonalnie: watchdog (auto-restart przy crash)

```bash
# W osobnym oknie/ssh
./workflow.sh watchdog
```

---

## 📦 Plik `update.sh` - Automatyczna Aktualizacja

Skrypt `update.sh` automatyzuje całą procedurę aktualizacji - **całkowicie samowystarczalny**:

```bash
./update.sh
```

### Co robi `update.sh`? (8 kroków)

0. ✅ **Sprawdza/instaluje** wymagane narzędzia (git, python, pip, jq, curl)
1. ✅ **Sprawdza** czy workflow działa
2. ⏹️ **Zatrzymuje** workflow (jeśli działa)
3. 📥 **Pobiera** ostatnią wersję z git (`git pull origin master`)
4. 📥 **Klonuje lub aktualizuje** sorter-common (auto-clone jeśli brakuje!)
5. ✔️ **Instaluje** Python dependencje (auto-detect brakujących)
6. 🔐 **Aktualizuje** uprawnienia (chmod +x)
7. 📋 **Waliduje** config.env (kopiuje z .example jeśli brakuje)
8. 🚀 **Restartuje** workflow (jeśli był uruchomiony)

### Samowystarczalność

Skrypt **automatycznie**:
- Instaluje brakujące narzędzia (git, python, rclone, jq, curl)
- Klonuje sorter-common jeśli go brakuje
- Pobiera Python dependencje (torch, ultralytics, easyocr, etc.)
- Tworzy config.env z template'u jeśli brakuje
- Nie zatrzymuje się na błędach - kontynuuje gdzie się da

**Wykorzystuj po każdej aktualizacji repozytorium!**

### Pierwsze uruchomienie

```bash
# Na czystej instalacji (jeśli brakuje wszystkiego)
./update.sh

# To zawsze działa - instaluje automatycznie!
```

---

## ⚙️ Struktura Kodu i Podziale Sekcji

### `workflow.sh` - Główny orchestrator

```
workflow.sh
├── SETUP & KONFIGURACJA
│   ├── setup_environment()      # Instalacja zależności (pkg, rclone, jq, etc.)
│   ├── setup_telegram()         # Konfiguracja powiadomień Telegram
│   └── setup_autostart()        # Auto-start przy boot
│
├── MAIN PIPELINE (execute_tasks)
│   ├── sync_rclone()            # Pobranie zdjęć z Google Drive
│   ├── run_photo_sorting()      # Python main.py - YOLO + Face detection
│   ├── upload_results_rclone()  # Upload wyników na Drive
│   ├── cleanup_tasks()          # Usuwanie starych temp files
│   └── get_system_status()      # Status RAM, CPU, uptime
│
├── LOGGING & MONITORING
│   ├── log()                    # Info logs
│   ├── warn()                   # Warning logs
│   ├── error()                  # Error logs
│   ├── rotate_logs()            # Rotacja logów (max 10MB)
│   └── send_telegram()          # Powiadomienia Telegram
│
├── DAEMON MANAGEMENT
│   ├── start_daemon()           # Start workflow w tle
│   ├── stop_workflow()          # Stop graceful + cleanup
│   ├── run_workflow()           # Main loop (healthcheck, retries)
│   ├── start_watchdog()         # Auto-restart monitor
│   └── status_workflow()        # Status check
│
└── UTILITIES
    ├── check_running()          # Czy workflow żyje?
    ├── acquire_lock()           # Mutex dla parallel safety
    ├── release_lock()           # Unlock
    └── save_state()             # JSON state file
```

---

## 🔄 Workflow Pipeline - Krok po Kroku

Każdy cykl (`execute_tasks`) robi:

### 1️⃣ **sync_rclone()** - Pobieranie danych
```bash
rclone sync gdrive:DriveSyncFiles /mnt/incoming
```
- Pobiera nowe zdjęcia z Google Drive
- Timeout: 60s, transfers=4, checkers=8
- Logowanie do workflow.log

### 2️⃣ **run_photo_sorting()** - Przetwarzanie (Python)
```bash
python main.py
```
Wykonuje:
- 🎯 **YOLO detection** - detekcja obiektów (osoby, samochody, zwierzęta)
- 👤 **Face detection** - detekcja i clustering twarzy
- 🏷️ **Sorting logic** - sortowanie zdjęć do folderów
- 📸 **Crops saving** - zachowywanie cropi (twarze, obiekty)
- 📊 **OCR** - ekstrakcja tekstu z tablic rejestracyjnych

**Zmienne środowiskowe dla pipeline:**
```bash
DEBUG="0"           # "0"=produkcja, "1"=debug, "2"=test (10 zdjęć)
PYTHONUNBUFFERED=1 # Real-time logging
```

### 3️⃣ **upload_results_rclone()** - Upload wyników
```bash
rclone sync /mnt/sorted gdrive:Posortowane
```
- Upload przetworzonych zdjęć z powrotem na Drive
- Timeout: 120s
- Obsługuje duże pliki

### 4️⃣ **cleanup_tasks()** - Maintenance
- Usuwanie temp files (starsze niż 7 dni)
- Rotacja logów (starsze niż 30 dni)
- Czyszczenie folderu `to_delete`

---

## 🛠️ Zmienne Konfiguracyjne

### `config.env` - Plik konfiguracji

```bash
# TELEGRAM
TELEGRAM_BOT_TOKEN="123456:ABCDEFGHijklmnop"
TELEGRAM_CHAT_ID="987654321"

# RCLONE
RCLONE_REMOTE="gdrive"
RCLONE_ROOT=""

# ŚCIEŻKI (jeśli inne niż domyślne)
INCOMING_DIR="/mnt/incoming"
SORTED_DIR="/mnt/sorted"
GDRIVE_PATH="Posortowane"
```

### `.env` - Python environment variables

```bash
# Opcjonalnie dla debug
DEBUG=0
```

### Zmienne w `sorter-common/config.py`

```python
RCLONE_REMOTE = "gdrive"
INCOMING_DIR = "/gdrive/DriveSyncFiles"
SORTED_DIR = "/gdrive/Posortowane"
MIN_CONFIDENCE = 0.4    # YOLO threshold
FACE_CLUSTERING_THRESHOLD = 0.40
```

---

## 📋 Komendy Workflow

### Zarządzanie

| Komenda | Opis |
|---------|------|
| `./workflow.sh setup` | Pierwsza konfiguracja (instalacja pkg, config) |
| `./workflow.sh start` | Start daemon (w tle) |
| `./workflow.sh stop` | Stop daemon graceful |
| `./workflow.sh restart` | Stop + start |
| `./workflow.sh status` | Pokaż status |
| `./workflow.sh logs` | Tail -f logów na żywo |
| `./workflow.sh watchdog` | Start auto-restart monitor |

### Telegram

| Komenda | Opis |
|---------|------|
| `./workflow.sh telegram-config` | Konfiguracja Telegram BOT |
| `./workflow.sh telegram-test` | Test powiadomienia |
| `./workflow.sh send-logs` | Wyślij logi na Telegram |

### Debug & Maintenance

| Komenda | Opis |
|---------|------|
| `./workflow.sh run` | Run workflow (bez daemon, w foreground) |
| `./update.sh` | Aktualizuj code + dependencje + restart |

---

## 📊 Pliki i Katalogi

```
monitoring-android/
├── workflow.sh              # Main orchestrator script
├── update.sh                # Auto-update script
├── main.py                  # Python entry point (YOLO + sorting)
├── config.env              # Configuration (Telegram, paths, etc)
├── config.env.example      # Configuration template
├── README.md               # Main documentation
├── README-UPDATE.md        # Ten plik
│
├── sorter-common/          # Git submodule/repo
│   ├── setup.py
│   ├── config.py           # Universal config (paths, thresholds)
│   ├── sorter.py           # Main photo processing logic
│   ├── models/             # Pre-trained YOLO/Face models
│   └── src/
│       ├── core/           # Core logic
│       ├── detectors/      # YOLO, Face, OCR detectors
│       └── sorter/         # Sorting classifier
│
├── logs/                   # Workflow logs
│   ├── workflow.log        # Info + debug
│   ├── error.log           # Errors
│   └── update.log          # Update script log
│
├── data/                   # Data output
│   ├── output.txt          # Pipeline output
│   └── (processed results)
│
├── tmp/                    # Temporary files
├── scripts/                # Helper scripts (optional)
│
└── (rclone mounted drives - usually /mnt/ or /gdrive)
    ├── DriveSyncFiles/     # Incoming photos
    ├── Posortowane/        # Sorted output
    └── to_delete/          # Files marked for deletion
```

---

## 🔧 Troubleshooting

### 1. `No such file or directory: logs/workflow.log`

**Rozwiązanie:** workflow.sh tworzy katalog auto, ale sprawdzaj:
```bash
mkdir -p logs
```

### 2. `python: command not found`

**Rozwiązanie:** Zainstaluj Python w Termux:
```bash
pkg install python
```

### 3. `rclone: command not found`

**Rozwiązanie:** Zainstaluj rclone:
```bash
pkg install rclone
rclone config      # Skonfiguruj Google Drive
```

### 4. Workflow nie startuje (PID file issues)

**Rozwiązanie:** Oczyszcz stare PID files:
```bash
rm -f workflow.pid workflow.lock
./workflow.sh start
```

### 5. Python dependencje nie znalezione

**Rozwiązanie:** Zainstaluj sorter-common:
```bash
cd sorter-common
pip install -e .
cd ..
```

### 6. "Telegram powiadomienia nie działają"

**Rozwiązanie:**
```bash
./workflow.sh telegram-config
./workflow.sh telegram-test
```

---

## 📈 Performance Tuning

### Liczba workerów (Python main.py)

`auto_workers()` w `main.py` automatycznie dobiera:
- **Dir workers** - skanowanie katalogów (sieć vs SSD/HDD)
- **Photo workers** - przetwarzanie (GPU vs CPU)

Dla Termux na przeciętnym telefonie:
```python
NUM_DIR_WORKERS = 4-8      # Katalogi
NUM_PHOTO_WORKERS = 2-4    # Zdjęcia
```

### Optimize dla Termux

```bash
# Wake lock (zapobiega uśpieniu)
termux-wake-lock

# Wyłącz battery optimization:
# Settings → Battery → Battery optimization → Termux → Don't optimize

# Zwiększ RAM limit (jeśli dostępne)
ulimit -v unlimited
```

---

## 🚀 Workflow - Obsługiwane Kamery

Z `sorter-common/config.py`:

```python
CAMERA_NAMES = {
    "ch1": "garaz",
    "ch2": "podworko_dziadzia_2",
    "ch3": "podworko_2",
    "ch4": "podworko_1",
    "ch5": "podworko_dziadzia_1",
    "ch6": "za_stodola",
}
```

Zdjęcia sortowane po kamerach + YOLO klasy + twarze.

---

## 📞 Support

1. Sprawdzić logi: `./workflow.sh logs`
2. Sprawdzić status: `./workflow.sh status`
3. Wysłać logi: `./workflow.sh send-logs`
4. Manualna aktualizacja: `./update.sh`

---

## 📝 Changelog

### v1.1 - Integracja Pipeline

- ✅ Dodano `sync_rclone()` - pobieranie z Google Drive
- ✅ Dodano `run_photo_sorting()` - Python YOLO pipeline
- ✅ Dodano `upload_results_rclone()` - upload wyników
- ✅ Dodano `update.sh` - automatyczna aktualizacja
- ✅ Dodano `cleanup_tasks()` - maintenance
- ✅ Dynamiczne WORKFLOW_DIR (nie hardcoded `/home/workflow`)

---

**Ostatnia aktualizacja:** 2026-01-06  
**Autor:** MatuszG  
**Repository:** https://github.com/MatuszG/monitoring-android
