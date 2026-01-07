#!/bin/bash
# Migration Script - Automatyczna migracja ze starego workflow.sh na nowy refactored
# Usage: chmod +x migrate.sh && ./migrate.sh

set -e  # Exit on error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  WORKFLOW MIGRATION - Old → Refactored (2.0)          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# PHASE 1: PRE-FLIGHT CHECKS
# ============================================================================

echo -e "${YELLOW}PHASE 1: Pre-flight Checks${NC}"
echo "────────────────────────────────────────────────────────"

# Check if we're in the right directory
if [ ! -f "workflow.sh" ]; then
    echo -e "${RED}❌ ERROR: workflow.sh not found in current directory${NC}"
    echo "Run this script from the monitoring-android root directory"
    exit 1
fi

echo -e "${GREEN}✓${NC} Found workflow.sh"

# Check if scripts directory exists
if [ ! -d "scripts" ]; then
    echo -e "${RED}❌ ERROR: scripts/ directory not found${NC}"
    echo "New refactored scripts should be in scripts/ directory"
    exit 1
fi

echo -e "${GREEN}✓${NC} Found scripts/ directory"

# Verify all required modules exist
required_modules=("logging.sh" "secrets.sh" "telegram.sh" "git-config.sh" "rclone.sh" "pipeline.sh")
for module in "${required_modules[@]}"; do
    if [ ! -f "scripts/$module" ]; then
        echo -e "${RED}❌ ERROR: scripts/$module not found${NC}"
        exit 1
    fi
done

echo -e "${GREEN}✓${NC} All required modules present"

# Check if workflow-refactored.sh exists
if [ ! -f "workflow-refactored.sh" ]; then
    echo -e "${RED}❌ ERROR: workflow-refactored.sh not found${NC}"
    echo "New refactored script should exist"
    exit 1
fi

echo -e "${GREEN}✓${NC} Found workflow-refactored.sh"

# Check if config.env exists
if [ ! -f "config.env" ]; then
    echo -e "${YELLOW}⚠${NC}  config.env not found (will create from example)"
    if [ -f "config.env.example" ]; then
        cp config.env.example config.env
        echo -e "${GREEN}✓${NC} Created config.env from example"
    else
        echo -e "${RED}⚠${NC}  No config.env.example found either - you'll need to create it manually"
    fi
fi

echo ""
echo -e "${YELLOW}PHASE 2: Backup Original${NC}"
echo "────────────────────────────────────────────────────────"

# Backup current workflow.sh
BACKUP_TIME=$(date +%Y%m%d-%H%M%S)
if [ -f "workflow.sh" ]; then
    cp workflow.sh "workflow-backup-${BACKUP_TIME}.sh"
    echo -e "${GREEN}✓${NC} Backed up workflow.sh → workflow-backup-${BACKUP_TIME}.sh"
fi

# Backup update.sh if it exists
if [ -f "update.sh" ]; then
    cp update.sh "update-backup-${BACKUP_TIME}.sh"
    echo -e "${GREEN}✓${NC} Backed up update.sh → update-backup-${BACKUP_TIME}.sh"
fi

echo ""
echo -e "${YELLOW}PHASE 3: Replace Main Script${NC}"
echo "────────────────────────────────────────────────────────"

# Replace workflow.sh with refactored version
cp workflow-refactored.sh workflow.sh
chmod 755 workflow.sh
echo -e "${GREEN}✓${NC} Replaced workflow.sh with refactored version"

echo ""
echo -e "${YELLOW}PHASE 4: Set Permissions${NC}"
echo "────────────────────────────────────────────────────────"

# Set permissions for all modules
chmod 755 scripts/*.sh
echo -e "${GREEN}✓${NC} Set execute permissions for scripts/*.sh (755)"

chmod 755 workflow.sh update.sh 2>/dev/null || true
echo -e "${GREEN}✓${NC} Set execute permissions for main scripts"

echo ""
echo -e "${YELLOW}PHASE 5: Validate New Structure${NC}"
echo "────────────────────────────────────────────────────────"

# Test if new workflow.sh can load modules
if bash -n workflow.sh 2>&1 | grep -q "syntax error"; then
    echo -e "${RED}❌ Syntax error in workflow.sh${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} workflow.sh syntax OK"

# Try to source one module
if ! source scripts/logging.sh 2>/dev/null; then
    echo -e "${RED}❌ Error loading logging.sh${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Module loading works"

echo ""
echo -e "${YELLOW}PHASE 6: Create Log Directories${NC}"
echo "────────────────────────────────────────────────────────"

mkdir -p logs/
chmod 755 logs/
echo -e "${GREEN}✓${NC} Created logs/ directory"

mkdir -p data/
chmod 755 data/
echo -e "${GREEN}✓${NC} Created data/ directory"

echo ""
echo -e "${YELLOW}PHASE 7: Migration Summary${NC}"
echo "────────────────────────────────────────────────────────"

cat << EOF

✅ MIGRATION COMPLETED SUCCESSFULLY

Changes Made:
  ✓ Backed up original files:
    - workflow-backup-${BACKUP_TIME}.sh
    - update-backup-${BACKUP_TIME}.sh (if existed)
  
  ✓ Installed refactored version:
    - workflow.sh (new, 90 lines)
    - scripts/ (6 modular scripts, 729 lines total)
  
  ✓ Set permissions:
    - workflow.sh: 755
    - scripts/*.sh: 755
    - update.sh: 755

Next Steps:
  1. Read the new structure:
     cat REFACTORING.md

  2. Run initial setup:
     ./workflow.sh setup

  3. Start the daemon:
     ./workflow.sh start

  4. Check status:
     ./workflow.sh status
     ./workflow.sh logs

Documentation:
  - REFACTORING.md         → Complete architecture
  - QUICK-REFERENCE.sh     → All available commands
  - ENCRYPTED-SECRETS.md   → Security details
  - README-UPDATE.md       → Auto-update mechanism

Troubleshooting:
  If something breaks, restore the old version:
  
  cp workflow-backup-${BACKUP_TIME}.sh workflow.sh
  ./workflow.sh start

Need Help?
  ./workflow.sh help
  cat QUICK-REFERENCE.sh

═══════════════════════════════════════════════════════════════════

EOF

echo -e "${GREEN}${YELLOW}Migration ready. Run:${NC} ${BLUE}./workflow.sh setup${NC}"
