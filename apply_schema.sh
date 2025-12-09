#!/bin/bash
# Smart schema apply script
# Handles Atlas limitations with a hybrid approach:
# - tables/ → Atlas diffs (handles table changes)
# - code/   → psql direct (all .sql files, sorted)
# - manual/ → psql direct (all .sql files, sorted)
#
# Usage:
#   ./apply_schema.sh              # Normal apply
#   ./apply_schema.sh --cron       # Also setup pg_cron jobs
#   ./apply_schema.sh --yes        # Skip confirmation prompts
#   ./apply_schema.sh --skip-atlas # Skip Atlas, only run code/manual/refresh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env if exists (for DATABASE_URL, ATLAS_DEV_URL)
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Config
CONTAINER="supabase-db"
DB_USER="postgres"
DB_NAME="postgres"

# Parse args
SETUP_CRON=false
AUTO_APPROVE=false
SKIP_ATLAS=false
for arg in "$@"; do
    case $arg in
        --cron) SETUP_CRON=true ;;
        --yes|-y) AUTO_APPROVE=true ;;
        --skip-atlas) SKIP_ATLAS=true ;;
    esac
done

SCHEMA_DIR="$SCRIPT_DIR/supabase/schema"

# Helper to run psql in container
run_psql() {
    docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" "$@"
}

run_psql_file() {
    docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -f - < "$1"
}

echo -e "${GREEN}=== IBHelm Schema Apply ===${NC}"
echo ""

if [ "$SKIP_ATLAS" = true ]; then
    echo -e "${YELLOW}Skipping Atlas (--skip-atlas)${NC}"
else
    # Step 0: Reset Atlas dev database (clean slate for diff computation)
    echo -e "${YELLOW}Step 0: Resetting Atlas dev database...${NC}"
    docker exec -i "$CONTAINER" psql -U supabase_admin -d postgres -c "DROP DATABASE IF EXISTS atlas_dev" -q 2>/dev/null || true
    docker exec -i "$CONTAINER" psql -U supabase_admin -d postgres -c "CREATE DATABASE atlas_dev" -q
    docker exec -i "$CONTAINER" psql -U supabase_admin -d postgres -c "ALTER DATABASE atlas_dev OWNER TO postgres" -q
    echo -e "${GREEN}✓ Atlas dev database reset${NC}"

    # Step 1: Generate migration SQL and ask for approval
    echo ""
    echo -e "${YELLOW}Step 1: Computing table changes via Atlas...${NC}"
    cd "$SCRIPT_DIR"

    MIGRATION_FILE="/tmp/atlas_migration.sql"

    # Generate migration SQL (diff from current DB to desired schema)
    # Only diff the schemas we manage (not supabase internals)
    atlas schema diff \
        --from "$DATABASE_URL" \
        --to "file://supabase/schema/tables" \
        --dev-url "$ATLAS_DEV_URL" \
        --schema public \
        --schema teamwork \
        --schema missive \
        --schema teamworkmissiveconnector \
        --format '{{ sql . "  " }}' \
        > "$MIGRATION_FILE" 2>&1 || true

    # Check if there are actual changes
    if [ ! -s "$MIGRATION_FILE" ] || ! grep -q "[a-zA-Z]" "$MIGRATION_FILE"; then
        echo -e "${GREEN}✓ No table changes needed${NC}"
    else
        echo -e "${YELLOW}Migration SQL:${NC}"
        echo "----------------------------------------"
        cat "$MIGRATION_FILE"
        echo "----------------------------------------"
        echo ""
        
        if [ "$AUTO_APPROVE" = false ]; then
            read -p "Apply this migration? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo -e "${RED}Aborted by user${NC}"
                exit 1
            fi
        fi
        
        echo -e "${YELLOW}Applying migration via psql...${NC}"
        run_psql -f - < "$MIGRATION_FILE"
        echo -e "${GREEN}✓ Table changes applied${NC}"
    fi
fi

# Step 2: Apply all code files (sorted order)
echo ""
echo -e "${YELLOW}Step 2: Applying code files (functions, views, triggers)...${NC}"
for sql_file in $(find "$SCHEMA_DIR/code" -name "*.sql" -type f | sort); do
    filename=$(basename "$sql_file")
    echo -e "  → $filename"
    run_psql_file "$sql_file" -q
done
echo -e "${GREEN}✓ Code files applied${NC}"

# Step 3: Apply all manual files (sorted order)
echo ""
echo -e "${YELLOW}Step 3: Applying manual files (special indexes)...${NC}"
for sql_file in $(find "$SCHEMA_DIR/manual" -name "*.sql" -type f | sort); do
    filename=$(basename "$sql_file")
    echo -e "  → $filename"
    run_psql_file "$sql_file" -q
done
echo -e "${GREEN}✓ Manual files applied${NC}"

# Step 4: Refresh materialized views
echo ""
echo -e "${YELLOW}Step 4: Refreshing materialized views...${NC}"
run_psql -q -c "SELECT refresh_unified_items_aggregates(FALSE);" 2>/dev/null || echo "  (skipped - MVs may not exist yet)"
echo -e "${GREEN}✓ Materialized views refreshed${NC}"

# Step 5: Populate junction tables
echo ""
echo -e "${YELLOW}Step 5: Populating involved persons junction table...${NC}"
run_psql -q -c "SELECT refresh_item_involved_persons();" 2>/dev/null || echo "  (skipped - function may not exist yet)"
echo -e "${GREEN}✓ Involved persons populated${NC}"

# Step 6: Setup pg_cron (optional)
if [ "$SETUP_CRON" = true ]; then
    echo ""
    echo -e "${YELLOW}Step 6: Setting up pg_cron jobs...${NC}"
    run_psql_file "$SCRIPT_DIR/setup_pg_cron.sql"
    echo -e "${GREEN}✓ pg_cron jobs configured${NC}"
fi

echo ""
echo -e "${GREEN}=== Schema apply complete! ===${NC}"
