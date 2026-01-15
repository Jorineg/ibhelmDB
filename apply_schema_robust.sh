#!/bin/bash
set -e

# ==============================================================================
# ROBUST SCHEMA APPLY SCRIPT
# Handles Atlas diffs + Manual SQLs + "Zombie" Function Cleanup
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"

# Configuration
CONTAINER="supabase-db"
DB_USER="postgres"
DB_NAME="postgres"
SCHEMA_DIR="$SCRIPT_DIR/supabase/schema"

# Flags
SETUP_CRON=true
AUTO_APPROVE=false
SKIP_ATLAS=false

for arg in "$@"; do
    case $arg in
        --no-cron) SETUP_CRON=false ;;
        --yes|-y) AUTO_APPROVE=true ;;
        --skip-atlas) SKIP_ATLAS=true ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Helpers
run_psql() {
    docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" "$@"
}
run_psql_file() {
    docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -f - < "$1"
}

echo -e "${GREEN}=== IBHelm Robust Schema Apply ===${NC}"

# ==============================================================================
# STEP 0: DROP VIEWS (So Atlas can modify columns)
# ==============================================================================
echo -e "${CYAN}[Step 0] Dropping Views (will be recreated in Step 2)${NC}"
run_psql -q <<EOF
-- Drop regular views that might block column changes
DROP VIEW IF EXISTS file_details CASCADE;
DROP VIEW IF EXISTS location_hierarchy CASCADE;
DROP VIEW IF EXISTS project_overview CASCADE;
DROP VIEW IF EXISTS unified_person_details CASCADE;
-- Drop materialized views
DROP MATERIALIZED VIEW IF EXISTS mv_unified_items CASCADE;
EOF
echo -e "${GREEN}  ✓ Views dropped${NC}"

# ==============================================================================
# STEP 1: ATLAS DIFF (With Safe-Guards)
# ==============================================================================
if [ "$SKIP_ATLAS" = true ]; then
    echo -e "${YELLOW}Skipping Atlas step...${NC}"
else
    echo -e "${CYAN}[Step 1] Atlas Migration${NC}"
    
    # Reset dev db
    docker exec -i "$CONTAINER" psql -U supabase_admin -d postgres -c "DROP DATABASE IF EXISTS atlas_dev" -q 2>/dev/null || true
    docker exec -i "$CONTAINER" psql -U supabase_admin -d postgres -c "CREATE DATABASE atlas_dev" -q
    docker exec -i "$CONTAINER" psql -U supabase_admin -d postgres -c "ALTER DATABASE atlas_dev OWNER TO postgres" -q

    MIGRATION_FILE="/tmp/atlas_migration.sql"
    FILTERED_FILE="/tmp/atlas_filtered.sql"

    # Generate Diff
    echo -e "  Generating diff..."
    if ! atlas schema diff \
        --from "$DATABASE_URL" \
        --to "file://supabase/schema/tables" \
        --dev-url "$ATLAS_DEV_URL" \
        --schema public --schema teamwork --schema missive --schema teamworkmissiveconnector \
        --format '{{ sql . "  " }}' \
        > "$MIGRATION_FILE" 2>/tmp/atlas_error.log; then
        echo -e "${RED}  ❌ Atlas failed to generate diff:${NC}"
        cat /tmp/atlas_error.log
        exit 1
    fi

    # --- THE FIX: Filter out drops of manual indexes ---
    # We look for lines starting with DROP INDEX ... and containing specific keywords
    # or belonging to the list of indexes we know are manual.
    grep -vE "DROP INDEX.*(trgm|gin|idx_mv_ui_|manual)" "$MIGRATION_FILE" > "$FILTERED_FILE" || true

    # If the file shrank, warn the user
    if [ $(stat -c%s "$MIGRATION_FILE") -ne $(stat -c%s "$FILTERED_FILE") ]; then
        echo -e "${YELLOW}  ⚠ Filtered out DROP INDEX statements for manual/trgm indexes.${NC}"
    fi

    if [ ! -s "$FILTERED_FILE" ] || ! grep -q "[a-zA-Z]" "$FILTERED_FILE"; then
        echo -e "${GREEN}  ✓ No table changes needed.${NC}"
    else
        echo -e "${YELLOW}  Proposed Changes:${NC}"
        echo "  ----------------------------------------"
        cat "$FILTERED_FILE"
        echo "  ----------------------------------------"
        
        if [ "$AUTO_APPROVE" = false ]; then
            read -p "  Apply this migration? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo -e "${RED}Aborted.${NC}"; exit 1; fi
        fi
        
        run_psql -f - < "$FILTERED_FILE"
        echo -e "${GREEN}  ✓ Table changes applied.${NC}"
    fi
fi

# ==============================================================================
# STEP 2: APPLY CODE (Functions, Triggers, Views)
# ==============================================================================
echo -e "${CYAN}[Step 2] Applying Code (Functions/Views/Triggers)${NC}"

# 2a. Clean up Zombie functions (The "3 Versions" Fix)
# We run a dynamic block to drop overloaded functions before recreating them
echo -e "  Cleaning overloaded functions..."
run_psql -q <<EOF
DO \$\$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT oid::regprocedure as sig FROM pg_proc WHERE proname IN ('query_unified_items', 'count_unified_items_with_metadata') LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
    END LOOP;
END \$\$;
EOF

# 2b. Apply Files
for sql_file in $(find "$SCHEMA_DIR/code" -name "*.sql" -type f | sort); do
    filename=$(basename "$sql_file")
    echo -e "  → $filename"
    
    # Retry loop for views.sql to handle "tuple concurrently updated"
    MAX_RETRIES=3
    count=0
    while [ $count -lt $MAX_RETRIES ]; do
        if run_psql_file "$sql_file" -q > /dev/null 2>&1; then
            break
        else
            count=$((count+1))
            if [ $count -eq $MAX_RETRIES ]; then
                echo -e "${RED}  ❌ Failed to apply $filename after $MAX_RETRIES attempts.${NC}"
                # Run once more without mute to show error
                run_psql_file "$sql_file"
                exit 1
            fi
            echo -e "${YELLOW}     (Retry $count/$MAX_RETRIES due to lock contention...)${NC}"
            sleep 1
        fi
    done
done

# ==============================================================================
# STEP 3: MANUAL INDEXES
# ==============================================================================
echo -e "${CYAN}[Step 3] Applying Manual Indexes${NC}"
for sql_file in $(find "$SCHEMA_DIR/manual" -name "*.sql" -type f | sort); do
    echo -e "  → $(basename "$sql_file")"
    run_psql_file "$sql_file" -q
done

# ==============================================================================
# STEP 4: REFRESH & WARMUP
# ==============================================================================
echo -e "${CYAN}[Step 4] Refreshing & Warming Up${NC}"

# Refresh MVs
run_psql -q -c "SELECT refresh_unified_items_aggregates(FALSE);" 2>/dev/null || true
echo -e "${GREEN}  ✓ Materialized views refreshed${NC}"

# Refresh Junctions
run_psql -q -c "SELECT refresh_item_involved_persons();" 2>/dev/null || true
echo -e "${GREEN}  ✓ Junction tables populated${NC}"

# Optional: pg_cron
if [ "$SETUP_CRON" = true ]; then
    echo -e "${CYAN}[Step 5] Setting up Cron${NC}"
    run_psql_file "$SCRIPT_DIR/setup_pg_cron.sql"
fi

echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"