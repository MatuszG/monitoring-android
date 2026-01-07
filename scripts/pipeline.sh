#!/bin/bash
# Pipeline Module - Główny pipeline przetwarzania zdjęć
# Przeznaczenie: Orchetracja: sync → sorting → upload → cleanup

# ============================================================================
# ZMIENNE GLOBALNE
# ============================================================================

export PYTHON_SCRIPT="${WORKFLOW_DIR}/main.py"
export PYTHON_TIMEOUT=1800  # 30 minut na przetworzenie

# ============================================================================
# SPRAWDZENIE DEPENDENCIES
# ============================================================================

check_pipeline_dependencies() {
    log "Sprawdzenie zależności pipeline..."
    
    local missing_deps=0
    
    # Python
    if ! command -v python3 &> /dev/null; then
        error "Python 3 nie zainstalowany"
        missing_deps=$((missing_deps + 1))
    fi
    
    # Main.py
    if [ ! -f "$PYTHON_SCRIPT" ]; then
        error "Script $PYTHON_SCRIPT nie znaleziony"
        missing_deps=$((missing_deps + 1))
    fi
    
    if [ $missing_deps -gt 0 ]; then
        error "Brakuje $missing_deps zależności"
        return 1
    fi
    
    debug "✓ Wszystkie zależności dostępne"
    return 0
}

# ============================================================================
# RUN PHOTO SORTING
# ============================================================================

run_photo_sorting() {
    log "Uruchamianie Python pipeline (main.py)..."
    
    if ! check_pipeline_dependencies; then
        error "Nie mogę uruchomić pipeline"
        return 1
    fi
    
    # Sprawdzenie czy są pliki do przetworzenia
    if [ ! -d "$INCOMING_DIR" ] || [ -z "$(find "$INCOMING_DIR" -type f)" ]; then
        log "Brak zdjęć do przetworzenia"
        return 0
    fi
    
    # Ustaw zmienne środowiskowe
    export PYTHONUNBUFFERED=1
    export DEBUG="${DEBUG:-0}"
    export INCOMING_DIR
    export SORTED_DIR
    
    # Uruchom z timeoutem
    log "Komenda: python3 $PYTHON_SCRIPT"
    
    timeout "$PYTHON_TIMEOUT" python3 "$PYTHON_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
    
    local py_status=${PIPESTATUS[0]}
    
    if [ $py_status -eq 0 ]; then
        local processed=$(find "$SORTED_DIR" -type f | wc -l)
        log "✓ Pipeline zakończony: $processed zdjęć przetworzonych"
        return 0
    elif [ $py_status -eq 124 ]; then
        error "Pipeline timeout ($PYTHON_TIMEOUT s) - zbyt dużo zdjęć?"
        return 1
    else
        error "Pipeline failed (status: $py_status)"
        return 1
    fi
}

# ============================================================================
# CLEANUP TEMPORARY FILES
# ============================================================================

cleanup_temp_files() {
    log "Czyszczenie plików tymczasowych..."
    
    # Usuń temp pliki
    if [ -d "$INCOMING_DIR" ]; then
        find "$INCOMING_DIR" -name "*.tmp" -delete 2>/dev/null
        find "$INCOMING_DIR" -name "*.lock" -delete 2>/dev/null
    fi
    
    # Usuń logi starsze niż 7 dni
    if [ -d "$WORKFLOW_DIR/logs" ]; then
        find "$WORKFLOW_DIR/logs" -name "*.log.*" -mtime +7 -delete 2>/dev/null
    fi
    
    debug "✓ Cleanup zakończony"
}

# ============================================================================
# MAIN PIPELINE ORCHESTRATION
# ============================================================================

execute_pipeline() {
    section "PIPELINE EXECUTION"
    
    # Pre-pipeline thermal check
    if ! check_thermal_before_pipeline; then
        error "Pipeline aborted - thermal check failed"
        return 1
    fi
    
    local start_time=$(date +%s)
    local steps_failed=0
    
    # Check if we should skip due to temperature
    if should_skip_pipeline; then
        warn "Pipeline skipped - device in cooldown mode or temperature critical"
        return 1
    fi
    
    # Reduce operations if temperature is HIGH
    reduce_pipeline_operations
    
    # Step 1: Sync incoming photos
    if ! sync_rclone_incoming; then
        error "Pipeline failed at sync_incoming"
        notify_error "❌ Pipeline failed: sync_incoming"
        return 1
    fi
    
    # Step 2: Photo sorting
    if ! run_photo_sorting; then
        warn "Pipeline warning at run_photo_sorting - kontynuuję"
        steps_failed=$((steps_failed + 1))
    fi
    
    # Step 3: Upload sorted photos
    if ! sync_rclone_upload; then
        warn "Pipeline warning at sync_upload - kontynuuję"
        steps_failed=$((steps_failed + 1))
    fi
    
    # Step 4: Cleanup
    cleanup_temp_files
    
    # Post-pipeline thermal check
    check_thermal_after_pipeline
    
    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Summary
    section "PIPELINE SUMMARY"
    log "Czas wykonania: ${duration}s"
    log "Temperatura końcowa: $(read_temperature)°C"
    
    if [ $steps_failed -eq 0 ]; then
        log "✅ Pipeline zakończony pomyślnie"
        notify_success "Pipeline completed successfully in ${duration}s"
        return 0
    else
        warn "Pipeline completed with $steps_failed warnings"
        return 1
    fi
}

# ============================================================================
# DRY RUN - TEST PIPELINE
# ============================================================================

pipeline_dry_run() {
    log "Wykonywanie DRY RUN pipeline (bez zmian)..."
    
    # Check incoming
    if [ -d "$INCOMING_DIR" ]; then
        local incoming_count=$(find "$INCOMING_DIR" -type f | wc -l)
        log "Incoming files: $incoming_count"
    else
        log "Incoming directory: (nie istnieje)"
    fi
    
    # Check sorted
    if [ -d "$SORTED_DIR" ]; then
        local sorted_count=$(find "$SORTED_DIR" -type f | wc -l)
        log "Sorted files: $sorted_count"
    else
        log "Sorted directory: (nie istnieje)"
    fi
    
    # Check Python
    if [ -f "$PYTHON_SCRIPT" ]; then
        log "Python script: OK"
        python3 "$PYTHON_SCRIPT" --version 2>/dev/null || log "  (no version flag)"
    else
        log "Python script: MISSING"
    fi
    
    log "✓ Dry run completed"
}

export -f check_pipeline_dependencies
export -f run_photo_sorting
export -f cleanup_temp_files
export -f execute_pipeline
export -f pipeline_dry_run
