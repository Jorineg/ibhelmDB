#!/bin/bash
# =====================================
# APPLY MIGRATIONS
# =====================================
# Applies all SQL migrations in order to the Supabase PostgreSQL database
# Run this on the server where Supabase is running in Docker
#
# Usage: ./apply_migrations.sh
# =====================================

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="$SCRIPT_DIR/supabase/migrations"
CONTAINER_NAME="supabase-db"
DB_USER="postgres"
DB_NAME="postgres"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  IBHelm Database Migration"
echo "=========================================="
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

# Check if migrations directory exists
if [ ! -d "$MIGRATIONS_DIR" ]; then
    echo -e "${RED}Error: Migrations directory not found: $MIGRATIONS_DIR${NC}"
    exit 1
fi

# Count migration files
MIGRATION_COUNT=$(ls -1 "$MIGRATIONS_DIR"/*.sql 2>/dev/null | wc -l)
if [ "$MIGRATION_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}No migration files found in $MIGRATIONS_DIR${NC}"
    exit 0
fi

echo "Found $MIGRATION_COUNT migration file(s)"
echo "Migrations directory: $MIGRATIONS_DIR"
echo ""

# Apply migrations in order (sorted by filename)
for migration in $(ls "$MIGRATIONS_DIR"/*.sql | sort); do
    filename=$(basename "$migration")
    echo -e "${YELLOW}Applying: $filename${NC}"
    
    if docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" < "$migration"; then
        echo -e "${GREEN}✓ Applied: $filename${NC}"
    else
        echo -e "${RED}✗ Failed: $filename${NC}"
        exit 1
    fi
    echo ""
done

echo "=========================================="
echo -e "${GREEN}✓ All migrations applied successfully!${NC}"
echo "=========================================="

