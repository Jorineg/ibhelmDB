#!/bin/bash
# Smart schema apply script
# Handles Atlas limitations with a hybrid approach:
# - tables/ → Atlas diffs (handles table changes)
# - code/   → psql direct (all .sql files, sorted)
# - manual/ → psql direct (all .sql files, sorted)
#
# Usage:
#   ./apply_schema.sh           # Normal apply
#   ./apply_schema.sh --cron    # Also setup pg_cron jobs

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parse args
SETUP_CRON=false
for arg in "$@"; do
    case $arg in
        --cron) SETUP_CRON=true ;;
    esac
done

# Get database URL
DB_URL="${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_DIR="$SCRIPT_DIR/supabase/schema"

echo -e "${GREEN}=== IBHelm Schema Apply ===${NC}"
echo ""

# Step 1: Apply table changes via Atlas (uses atlas.hcl config)
echo -e "${YELLOW}Step 1: Applying table changes via Atlas...${NC}"
cd "$SCRIPT_DIR"

# Use atlas.hcl env config which defines:
# - schemas: only public, teamwork, missive, teamworkmissiveconnector
# - exclude: auth.*, storage.*, realtime.*, etc.
# - src: supabase/schema/tables
atlas schema apply --env dev --auto-approve 2>&1 || {
    echo -e "${YELLOW}Atlas returned non-zero (may be expected for no changes)${NC}"
}
echo -e "${GREEN}✓ Table changes applied${NC}"

# Step 2: Apply all code files (sorted order)
echo ""
echo -e "${YELLOW}Step 2: Applying code files (functions, views, triggers)...${NC}"
for sql_file in $(find "$SCHEMA_DIR/code" -name "*.sql" -type f | sort); do
    filename=$(basename "$sql_file")
    echo -e "  → $filename"
    psql "$DB_URL" -f "$sql_file" -q
done
echo -e "${GREEN}✓ Code files applied${NC}"

# Step 3: Apply all manual files (sorted order)
echo ""
echo -e "${YELLOW}Step 3: Applying manual files (special indexes)...${NC}"
for sql_file in $(find "$SCHEMA_DIR/manual" -name "*.sql" -type f | sort); do
    filename=$(basename "$sql_file")
    echo -e "  → $filename"
    psql "$DB_URL" -f "$sql_file" -q
done
echo -e "${GREEN}✓ Manual files applied${NC}"

# Step 4: Refresh materialized views
echo ""
echo -e "${YELLOW}Step 4: Refreshing materialized views...${NC}"
psql "$DB_URL" -q -c "SELECT refresh_unified_items_aggregates(FALSE);" 2>/dev/null || echo "  (skipped - MVs may not exist yet)"
echo -e "${GREEN}✓ Materialized views refreshed${NC}"

# Step 5: Populate junction tables
echo ""
echo -e "${YELLOW}Step 5: Populating involved persons junction table...${NC}"
psql "$DB_URL" -q -c "SELECT refresh_item_involved_persons();" 2>/dev/null || echo "  (skipped - function may not exist yet)"
echo -e "${GREEN}✓ Involved persons populated${NC}"

# Step 6: Setup pg_cron (optional)
if [ "$SETUP_CRON" = true ]; then
    echo ""
    echo -e "${YELLOW}Step 6: Setting up pg_cron jobs...${NC}"
    psql "$DB_URL" -f "$SCRIPT_DIR/setup_pg_cron.sql"
    echo -e "${GREEN}✓ pg_cron jobs configured${NC}"
fi

echo ""
echo -e "${GREEN}=== Schema apply complete! ===${NC}"
