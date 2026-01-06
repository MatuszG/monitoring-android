# main.py – ULTRA FAST 2025 – pipeline + progress bar

import os
import sys
from pathlib import Path

# Add sorter-common to path
sys.path.insert(0, str(Path(__file__).parent.parent / "sorter-common"))

from queue import Queue
from threading import Thread, Lock
from concurrent.futures import ThreadPoolExecutor
from collections.abc import Iterable
import platform
import psutil
from tqdm import tqdm

# Import from sorter-common
from config import *
from src.sorter import process_photo
from models import MODEL, device, face_detector

from PIL import ImageFile
import warnings

# ==================== Automatyczne pobieranie modeli ====================
print("\n" + "=" * 80)
print("🚀 INICJALIZACJA APLIKACJI")
print("=" * 80)

# Modele zostaną pobrane automatycznie przy imporcie z sorter_common
try:
    print("✅ Modele załadowane pomyślnie")
except Exception as e:
    print(f"❌ Błąd przy ładowaniu modeli: {e}")
    raise

# ==================== Ustawienia PIL ====================
ImageFile.LOAD_TRUNCATED_IMAGES = True
warnings.filterwarnings("ignore", "(Possibly )?corrupt EXIF data", UserWarning)
warnings.filterwarnings("ignore", "Corrupt JPEG data", UserWarning)

# ==================== Foldery wynikowe ====================
SORTED_DIR.mkdir(parents=True, exist_ok=True)
TO_DELETE_DIR.mkdir(parents=True, exist_ok=True)

# ==================== Tryb pracy ====================
print("=" * 80)
mode = (
    "DEBUG lokalny" if DEBUG == "1" else
    "DEBUG 10 zdjęć (błyskawiczny)" if DEBUG == "2" else
    "PRODUKCJA"
)
print(f"TRYB: {mode}")
print(f"Źródło: {SOURCE}")
print(f"Wyniki:  {SORTED_DIR}")
print("=" * 80)

# ==================== Auto-detekcja liczby workerów ====================
def auto_workers():
    cpu = psutil.cpu_count(logical=True)
    cpu_phys = psutil.cpu_count(logical=False)
    system = platform.system().lower()

    # Detekcja nośnika (SSD / HDD / sieć)
    try:
        disk_stats = psutil.disk_io_counters()
        is_fast_disk = disk_stats.write_time < 300_000  # prosty heurystyczny test
    except:
        is_fast_disk = True

    # Detekcja ścieżki sieciowej
    is_network_path = (
        str(SOURCE).startswith("//") or
        str(SOURCE).startswith("\\\\") or
        "DriveSyncFiles" in str(SOURCE) or
        "Google Drive" in str(SOURCE)
    )

    # Detekcja GPU
    has_gpu = False
    try:
        import torch
        has_gpu = torch.cuda.is_available()
    except:
        pass

    # Workery katalogowe
    if is_network_path:
        dir_workers = min(max(cpu // 2, 4), 32)
    elif is_fast_disk:
        dir_workers = min(cpu * 2, 32)
    else:
        dir_workers = min(cpu, 16)

    # Workery do przetwarzania zdjęć
    if has_gpu:
        photo_workers = 1
    else:
        photo_workers = max(2, cpu_phys)

    return dir_workers, photo_workers

NUM_DIR_WORKERS, NUM_PHOTO_WORKERS = auto_workers()
print(f"Automatyczne ustawienie workerów:")
print(f"  - Workerów katalogowych: {NUM_DIR_WORKERS}")
print(f"  - Workerów zdjęciowych:  {NUM_PHOTO_WORKERS}")

# ==================== PIPELINE QUEUES ====================
dir_queue = Queue()
photo_queue = Queue()

# ==================== Progress bar i licznik ====================
processed_count = 0
processed_lock = Lock()

# Liczymy wszystkie pliki JPG/PNG, jeśli chcemy pełny progress
def count_photos(source: Path):
    exts = (".jpg", ".jpeg", ".png")
    return sum(1 for _ in source.rglob("*") if _.suffix.lower() in exts)

if DEBUG != "2":  # w DEBUG 10 zdjęć nie liczymy wszystkich
    total_photos = count_photos(SOURCE)
else:
    total_photos = 10

pbar = tqdm(total=total_photos, desc="Przetworzono zdjęć", unit="img", ncols=80)

# ==================== Funkcje pipeline ====================
def folder_scanner():
    """Rekurencyjnie wrzuca katalogi do kolejki dir_queue."""
    for root, dirs, files in os.walk(SOURCE):
        for d in dirs:
            dir_queue.put(Path(root) / d)
    dir_queue.put(SOURCE)  # główny katalog też
    for _ in range(NUM_DIR_WORKERS):
        dir_queue.put(None)

def file_scanner():
    """Pobiera katalogi i wrzuca zdjęcia do photo_queue."""
    exts = (".jpg", ".jpeg", ".png")
    while True:
        d = dir_queue.get()
        if d is None:
            dir_queue.task_done()
            break
        try:
            for entry in os.scandir(d):
                if entry.is_file() and entry.name.lower().endswith(exts):
                    photo_queue.put(Path(entry.path))
        except:
            pass
        dir_queue.task_done()
    photo_queue.put(None)  # sygnał stop dla photo workers

def photo_worker():
    """Przetwarza zdjęcia i aktualizuje licznik/progress bar."""
    global processed_count
    while True:
        p = photo_queue.get()
        if p is None:
            photo_queue.task_done()
            break
        try:
            process_photo(p)
        except Exception as e:
            print(f"BŁĄD przy {p.name}: {e}")

        with processed_lock:
            processed_count += 1
            pbar.update(1)

        photo_queue.task_done()

# ==================== MAIN ====================
print("Startuję streaming pipeline…")

# 1) Start folder scanner
Thread(target=folder_scanner, daemon=True).start()

# 2) Start file scanners
for _ in range(NUM_DIR_WORKERS):
    Thread(target=file_scanner, daemon=True).start()

# 3) Start photo workers
for _ in range(NUM_PHOTO_WORKERS):
    Thread(target=photo_worker, daemon=True).start()

# 4) Czekamy na zakończenie
dir_queue.join()
photo_queue.join()
pbar.close()

print("\n" + "=" * 80)
print("GOTOWE! Wszystkie zdjęcia przetworzone (pipeline).")
print(f"Wyniki znajdziesz w: {SORTED_DIR}")
print("=" * 80)
