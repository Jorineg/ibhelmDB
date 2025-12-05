#!/bin/bash
# =====================================
# UPDATE DATABASE WITH DATA PRESERVATION
# =====================================
# This script:
# 1. Stops TeamworkMissiveConnector services
# 2. Backs up data from teamwork, missive, teamworkmissiveconnector schemas
# 3. Pulls latest changes from git
# 4. Resets database and applies migrations
# 5. Restores backed up data
# 6. Restarts TeamworkMissiveConnector services
#
# Usage: ./update_db.sh [--force] [--no-backup] [--no-restore]
#        --force: Skip confirmation prompts
#        --no-backup: Skip backup step (useful if you have a recent backup)
#        --no-restore: Skip restore step (fresh start with new schema)
# =====================================

set -e

cd "$(dirname "$0")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CONTAINER_NAME="supabase-db"
DB_USER="postgres"
DB_NAME="postgres"
BACKUP_DIR="./backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/schema_backup_$TIMESTAMP.sql"
CONNECTOR_DIR="../TeamworkMissiveConnector"

# macOS launchd config
LAUNCHD_LABEL="com.teamworkmissive.connector"

# Linux systemd config (user services)
SYSTEMD_CONNECTOR_SERVICE="teamwork-missive-connector"
SYSTEMD_WORKER_SERVICE="teamwork-missive-worker"

# Detect OS
OS_TYPE="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macos"
elif [[ "$OSTYPE" == "linux"* ]]; then
    OS_TYPE="linux"
fi

# Parse arguments
FORCE=false
NO_BACKUP=false
NO_RESTORE=false
for arg in "$@"; do
    case $arg in
        --force)
            FORCE=true
            ;;
        --no-backup)
            NO_BACKUP=true
            ;;
        --no-restore)
            NO_RESTORE=true
            ;;
    esac
done

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}  IBHelm Database Update with Backup${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: docker is not installed or not in PATH${NC}"
    exit 1
fi

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${RED}Error: Container '${CONTAINER_NAME}' is not running${NC}"
    echo "Make sure Supabase is started with: docker compose up -d"
    exit 1
fi

# Confirmation
if [ "$FORCE" != true ]; then
    echo "This script will:"
    echo "  1. Stop TeamworkMissiveConnector services"
    echo "  2. Backup data from teamwork, missive, teamworkmissiveconnector schemas"
    echo "  3. Pull latest changes from git"
    echo "  4. Reset database and apply migrations"
    echo "  5. Restore backed up data"
    echo "  6. Restart TeamworkMissiveConnector services"
    echo ""
    echo -e "${YELLOW}Warning: Data restoration may fail if schema changes are incompatible${NC}"
    echo ""
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# =====================================
# STEP 1: Stop TeamworkMissiveConnector Services
# =====================================
echo -e "${CYAN}=== Step 1: Stopping TeamworkMissiveConnector Services ===${NC}"

SERVICES_WERE_RUNNING=false
LAUNCHD_WAS_RUNNING=false
SYSTEMD_WAS_RUNNING=false

# macOS: Check and stop launchd service
if [ "$OS_TYPE" = "macos" ]; then
    if launchctl list 2>/dev/null | grep -q "$LAUNCHD_LABEL"; then
        echo "Stopping launchd service ($LAUNCHD_LABEL)..."
        launchctl unload "$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist" 2>/dev/null || true
        SERVICES_WERE_RUNNING=true
        LAUNCHD_WAS_RUNNING=true
        echo -e "${GREEN}✓ LaunchAgent stopped${NC}"
    fi
fi

# Linux: Check and stop systemd user services
if [ "$OS_TYPE" = "linux" ]; then
    # Check if systemd user services exist and are running
    if systemctl --user is-active --quiet "$SYSTEMD_CONNECTOR_SERVICE" 2>/dev/null; then
        echo "Stopping systemd service ($SYSTEMD_CONNECTOR_SERVICE)..."
        systemctl --user stop "$SYSTEMD_CONNECTOR_SERVICE" 2>/dev/null || true
        SERVICES_WERE_RUNNING=true
        SYSTEMD_WAS_RUNNING=true
        echo -e "${GREEN}✓ Connector service stopped${NC}"
    fi
    
    if systemctl --user is-active --quiet "$SYSTEMD_WORKER_SERVICE" 2>/dev/null; then
        echo "Stopping systemd service ($SYSTEMD_WORKER_SERVICE)..."
        systemctl --user stop "$SYSTEMD_WORKER_SERVICE" 2>/dev/null || true
        SERVICES_WERE_RUNNING=true
        SYSTEMD_WAS_RUNNING=true
        echo -e "${GREEN}✓ Worker service stopped${NC}"
    fi
fi

# Kill any running connector processes (fallback for manual runs)
echo "Checking for running connector processes..."
CONNECTOR_PIDS=$(pgrep -f "src\.app|src\.workers\.dispatcher|src\.startup" 2>/dev/null || true)
if [ -n "$CONNECTOR_PIDS" ]; then
    echo "Stopping connector processes: $CONNECTOR_PIDS"
    kill $CONNECTOR_PIDS 2>/dev/null || true
    sleep 2
    # Force kill if still running
    kill -9 $CONNECTOR_PIDS 2>/dev/null || true
    SERVICES_WERE_RUNNING=true
    echo -e "${GREEN}✓ Connector processes stopped${NC}"
else
    echo "No running connector processes found"
fi

# Give processes time to fully stop
sleep 1
echo ""

# =====================================
# STEP 2: Backup Schema Data
# =====================================
if [ "$NO_BACKUP" != true ]; then
    echo -e "${CYAN}=== Step 2: Backing Up Schema Data ===${NC}"
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    echo "Backing up data to: $BACKUP_FILE"
    
    # Create backup SQL file with header
    cat > "$BACKUP_FILE" << 'HEADER'
-- =====================================
-- IBHelm Schema Data Backup
-- =====================================
-- This file contains data from:
--   - teamwork schema
--   - missive schema
--   - teamworkmissiveconnector schema
--
-- Restore with: psql -f <this_file>
-- =====================================

-- Disable triggers during restore for better performance
SET session_replication_role = replica;

HEADER
    
    # Backup each schema's data
    for schema in teamwork missive teamworkmissiveconnector; do
        echo "  Backing up $schema schema..."
        
        # Check if schema exists and has tables
        TABLES_EXIST=$(docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -t -c \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$schema';" 2>/dev/null | tr -d ' ')
        
        if [ "$TABLES_EXIST" != "0" ] && [ -n "$TABLES_EXIST" ]; then
            # Use pg_dump for data only with column inserts for better compatibility
            docker exec "$CONTAINER_NAME" pg_dump -U "$DB_USER" -d "$DB_NAME" \
                --schema="$schema" \
                --data-only \
                --column-inserts \
                --disable-triggers \
                --no-owner \
                --no-privileges \
                2>/dev/null >> "$BACKUP_FILE" || echo "  (No data in $schema)"
            echo -e "  ${GREEN}✓ $schema backed up${NC}"
        else
            echo "  (Schema $schema does not exist or has no tables)"
        fi
    done
    
    # Add footer to backup
    cat >> "$BACKUP_FILE" << 'FOOTER'

-- Re-enable triggers
SET session_replication_role = DEFAULT;

-- Done
FOOTER
    
    # Show backup size
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo ""
    echo -e "${GREEN}✓ Backup complete: $BACKUP_FILE ($BACKUP_SIZE)${NC}"
else
    echo -e "${YELLOW}=== Step 2: Backup Skipped (--no-backup) ===${NC}"
fi
echo ""

# =====================================
# STEP 3: Git Pull
# =====================================
echo -e "${CYAN}=== Step 3: Git Pull ===${NC}"
git pull
echo ""

# =====================================
# STEP 4: Reset Database
# =====================================
echo -e "${CYAN}=== Step 4: Reset Database ===${NC}"
./reset_db.sh --full --force
echo ""

# =====================================
# STEP 5: Apply Migrations
# =====================================
echo -e "${CYAN}=== Step 5: Apply Migrations ===${NC}"
./apply_migrations.sh
echo ""

# =====================================
# STEP 6: Restore Data
# =====================================
if [ "$NO_RESTORE" != true ] && [ "$NO_BACKUP" != true ] && [ -f "$BACKUP_FILE" ]; then
    echo -e "${CYAN}=== Step 6: Restoring Data ===${NC}"
    echo "Restoring from: $BACKUP_FILE"
    
    # Restore the data
    if docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" < "$BACKUP_FILE" 2>&1 | grep -v "^SET$" | grep -v "^INSERT" | head -20; then
        echo ""
        echo -e "${GREEN}✓ Data restoration complete${NC}"
    else
        echo ""
        echo -e "${YELLOW}⚠ Data restoration completed with possible warnings${NC}"
        echo "Check the backup file and database manually if needed"
    fi
elif [ "$NO_RESTORE" = true ]; then
    echo -e "${YELLOW}=== Step 6: Restore Skipped (--no-restore) ===${NC}"
elif [ "$NO_BACKUP" = true ]; then
    echo -e "${YELLOW}=== Step 6: Restore Skipped (no backup was made) ===${NC}"
else
    echo -e "${YELLOW}=== Step 6: No backup file found to restore ===${NC}"
fi
echo ""

# =====================================
# STEP 7: Restart Services
# =====================================
echo -e "${CYAN}=== Step 7: Restarting TeamworkMissiveConnector Services ===${NC}"

SERVICES_RESTARTED=false

# macOS: Restart launchd service
if [ "$OS_TYPE" = "macos" ]; then
    PLIST_PATH="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
    if [ -f "$PLIST_PATH" ]; then
        echo "Starting launchd service..."
        launchctl load "$PLIST_PATH" 2>/dev/null || true
        sleep 2
        
        if launchctl list | grep -q "$LAUNCHD_LABEL"; then
            echo -e "${GREEN}✓ LaunchAgent started successfully${NC}"
            SERVICES_RESTARTED=true
        else
            echo -e "${YELLOW}⚠ LaunchAgent may not have started. Check: launchctl list | grep teamworkmissive${NC}"
        fi
    elif [ "$LAUNCHD_WAS_RUNNING" = true ]; then
        echo -e "${YELLOW}⚠ LaunchAgent was running but plist not found${NC}"
    fi
fi

# Linux: Restart systemd user services
if [ "$OS_TYPE" = "linux" ]; then
    # Check if systemd service files exist
    CONNECTOR_SERVICE_FILE="$HOME/.config/systemd/user/$SYSTEMD_CONNECTOR_SERVICE.service"
    WORKER_SERVICE_FILE="$HOME/.config/systemd/user/$SYSTEMD_WORKER_SERVICE.service"
    
    if [ -f "$CONNECTOR_SERVICE_FILE" ] || [ -f "$WORKER_SERVICE_FILE" ]; then
        echo "Starting systemd services..."
        
        if [ -f "$CONNECTOR_SERVICE_FILE" ]; then
            systemctl --user start "$SYSTEMD_CONNECTOR_SERVICE" 2>/dev/null || true
            sleep 1
            if systemctl --user is-active --quiet "$SYSTEMD_CONNECTOR_SERVICE"; then
                echo -e "${GREEN}✓ Connector service started${NC}"
                SERVICES_RESTARTED=true
            else
                echo -e "${YELLOW}⚠ Connector service may not have started${NC}"
                echo "  Check: systemctl --user status $SYSTEMD_CONNECTOR_SERVICE"
            fi
        fi
        
        if [ -f "$WORKER_SERVICE_FILE" ]; then
            systemctl --user start "$SYSTEMD_WORKER_SERVICE" 2>/dev/null || true
            sleep 1
            if systemctl --user is-active --quiet "$SYSTEMD_WORKER_SERVICE"; then
                echo -e "${GREEN}✓ Worker service started${NC}"
                SERVICES_RESTARTED=true
            else
                echo -e "${YELLOW}⚠ Worker service may not have started${NC}"
                echo "  Check: systemctl --user status $SYSTEMD_WORKER_SERVICE"
            fi
        fi
    elif [ "$SYSTEMD_WAS_RUNNING" = true ]; then
        echo -e "${YELLOW}⚠ Systemd services were running but service files not found${NC}"
    fi
fi

# If no service manager was used but services were running manually
if [ "$SERVICES_RESTARTED" = false ] && [ "$SERVICES_WERE_RUNNING" = true ]; then
    echo -e "${YELLOW}Note: Services were running manually (not via launchd/systemd).${NC}"
    echo "You may need to manually restart the connector:"
    echo "  cd $CONNECTOR_DIR && ./scripts/run_local.sh"
elif [ "$SERVICES_RESTARTED" = false ] && [ "$SERVICES_WERE_RUNNING" = false ]; then
    echo "No services to restart (none were running before)"
fi
echo ""

# =====================================
# COMPLETE
# =====================================
echo -e "${BLUE}==========================================${NC}"
echo -e "${GREEN}✓ Database update complete!${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""
if [ "$NO_BACKUP" != true ] && [ -f "$BACKUP_FILE" ]; then
    echo "Backup saved at: $BACKUP_FILE"
    echo ""
fi
echo "Recent backups:"
ls -lh "$BACKUP_DIR"/*.sql 2>/dev/null | tail -5 || echo "  (no backups found)"
echo ""
