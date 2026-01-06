# 📱 Monitoring Android - Photo Sorting Pipeline for Termux

Automated 24/7 photo sorting system with YOLO object detection and face recognition. Designed for Termux environment with Google Drive integration.

## 🚀 Quick Start

### Prerequisites
```bash
pkg install git python jq curl rclone
```

### Installation

```bash
# Clone main repo
git clone https://github.com/MatuszG/monitoring-android.git
cd monitoring-android

# Clone sorter-common submodule
git clone https://github.com/MatuszG/sorter-common.git sorter-common

# First-time setup
./workflow.sh setup

# Configure Telegram (optional but recommended)
./workflow.sh telegram-config

# Start 24/7 daemon
./workflow.sh start
```

## 📚 Documentation

- **[README-UPDATE.md](README-UPDATE.md)** - Detailed guide for updates, configuration, and troubleshooting
- **[config.env.example](config.env.example)** - Configuration template

## 🏗️ Architecture

### Directory Structure

```
monitoring-android/
├── workflow.sh              # Main orchestrator (24/7 daemon)
├── update.sh                # Auto-update script
├── main.py                  # Python entry point (YOLO + sorting)
├── config.env              # Configuration file
├── config.env.example      # Configuration template
│
├── sorter-common/           # Submodule - Core sorting logic
│   ├── setup.py
│   ├── config.py            # Universal config
│   ├── sorter.py            # Photo processing pipeline
│   └── src/
│       ├── detectors/       # YOLO, Face, OCR
│       ├── core/            # Core utilities
│       └── sorter/          # Sorting logic
│
├── logs/                    # Workflow logs
│   ├── workflow.log         # Info logs
│   └── error.log            # Error logs
│
├── data/                    # Output data
└── tmp/                     # Temporary files
```

## 🔄 Pipeline Flow

Each workflow cycle executes:

1. **sync_rclone()** - Download photos from Google Drive
2. **run_photo_sorting()** - Python pipeline (YOLO detection + face clustering + sorting)
3. **upload_results_rclone()** - Upload sorted results back to Drive
4. **cleanup_tasks()** - Maintenance (rotate logs, cleanup temp files)

### Photo Sorting Process (Python)

- 🎯 **YOLO Detection** - Objects (persons, cars, animals)
- 👤 **Face Detection** - Detect & cluster faces
- 🏷️ **Sorting** - Organize by camera + object type + person
- 📸 **Crops** - Save face crops and object crops
- 📊 **OCR** - Extract plate numbers from license plates

## ⚙️ Configuration

### config.env - Main Configuration

```bash
# Telegram Bot (for notifications)
TELEGRAM_BOT_TOKEN="your_bot_token"
TELEGRAM_CHAT_ID="your_chat_id"

# RCLONE (Google Drive)
RCLONE_REMOTE="gdrive"
RCLONE_ROOT=""

# Paths for pipeline
INCOMING_DIR="/path/to/incoming"
SORTED_DIR="/path/to/sorted"
```

### sorter-common/config.py - Pipeline Configuration

```python
MIN_CONFIDENCE = 0.4        # YOLO confidence threshold
IOU_THRESHOLD = 0.25        # NMS threshold
FACE_CLUSTERING_THRESHOLD = 0.40
CROP_MARGIN = 100
```

## 📋 Commands

### Workflow Management

| Command | Description |
|---------|-------------|
| `./workflow.sh start` | Start 24/7 daemon |
| `./workflow.sh stop` | Stop daemon |
| `./workflow.sh status` | Show status |
| `./workflow.sh logs` | Stream logs |
| `./workflow.sh restart` | Restart daemon |
| `./workflow.sh watchdog` | Start auto-restart monitor |

### Maintenance

| Command | Description |
|---------|-------------|
| `./update.sh` | Update code + dependencies + restart |
| `./workflow.sh setup` | Initial environment setup |
| `./workflow.sh telegram-test` | Test Telegram notifications |

## 🛠️ Troubleshooting

**See [README-UPDATE.md](README-UPDATE.md) for detailed troubleshooting guide.**

Common issues:
- **`logs/workflow.log: No such file or directory`** - Run `mkdir -p logs`
- **`python: command not found`** - Run `pkg install python`
- **`rclone: command not found`** - Run `pkg install rclone && rclone config`

## 🚀 Performance

Auto-workers configuration based on:
- CPU cores
- Storage type (SSD vs HDD vs Network)
- GPU availability
- Network path detection

For Termux:
- Typical: 4-8 directory workers, 2-4 photo workers
- Enable wake lock: `termux-wake-lock`
- Disable battery optimization in Settings

## 📊 Camera Setup

Supported cameras (from `sorter-common/config.py`):

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

Photos sorted by: `camera / class / person_id / photo.jpg`

## 📈 Status & Monitoring

Check workflow status:
```bash
./workflow.sh status

# Stream logs in real-time
./workflow.sh logs

# Send logs via Telegram
./workflow.sh send-logs
```

## 🔄 Updates

Update workflow + sorter-common + dependencies:
```bash
./update.sh
```

This script:
1. Stops workflow (if running)
2. Pulls latest from git (both repos)
3. Installs Python dependencies
4. Validates config
5. Restarts workflow

## 📞 Support

1. Check logs: `./workflow.sh logs`
2. Check status: `./workflow.sh status`
3. Read [README-UPDATE.md](README-UPDATE.md)
4. Check git history for recent changes

## 📝 Pre-requirements 
pkg install git
git pull 
git config --global credential.helper cache

