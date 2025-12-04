#!/bin/bash
# =====================================
# RESET DATABASE
# =====================================
# By default: Resets only ibhelm-specific objects in public schema
#             PRESERVES: teamwork, missive, teamworkmissiveconnector schemas
#
# With --full: Drops ALL custom schemas, tables, views, functions, types
#              Only preserves Supabase system schemas (auth, storage)
#
# Usage: ./reset_db.sh          (partial reset - keeps connector data)
#        ./reset_db.sh --full   (full reset - drops everything)
#        ./reset_db.sh --force  (skip confirmation, partial reset)
#        ./reset_db.sh --full --force  (skip confirmation, full reset)
# =====================================

set -e  # Exit on error

CONTAINER_NAME="supabase-db"
DB_USER="postgres"
DB_NAME="postgres"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse arguments
FORCE=false
FULL=false
for arg in "$@"; do
    case $arg in
        --force)
            FORCE=true
            ;;
        --full)
            FULL=true
            ;;
    esac
done

echo "=========================================="
if [ "$FULL" = true ]; then
    echo "  IBHelm Database Reset (FULL)"
else
    echo "  IBHelm Database Reset (Partial)"
fi
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

# Confirmation prompt
if [ "$FORCE" != true ]; then
    echo -e "${RED}WARNING: This will DROP database objects!${NC}"
    echo ""
    
    if [ "$FULL" = true ]; then
        echo "FULL RESET - This will remove:"
        echo "  - Schemas: teamwork, missive, teamworkmissiveconnector"
        echo "  - All tables, views, functions in public schema"
        echo "  - Custom types: task_extension_type, location_type"
        echo "  - Extensions: pg_trgm, unaccent"
        echo ""
        echo "This will PRESERVE:"
        echo "  - auth schema (Supabase authentication)"
        echo "  - storage schema (Supabase storage)"
        echo "  - Other Supabase system schemas"
    else
        echo "PARTIAL RESET - This will remove:"
        echo "  - All tables, views, functions in public schema"
        echo "  - Custom types in public schema"
        echo "  - Extensions: pg_trgm, unaccent"
        echo ""
        echo "This will PRESERVE:"
        echo "  - teamwork schema (synced Teamwork data)"
        echo "  - missive schema (synced Missive data)"
        echo "  - teamworkmissiveconnector schema (connector state)"
        echo "  - auth schema (Supabase authentication)"
        echo "  - storage schema (Supabase storage)"
        echo ""
        echo -e "${CYAN}Tip: Use --full to also reset teamwork, missive, and connector data${NC}"
    fi
    
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

echo -e "${YELLOW}Starting database reset...${NC}"
echo ""

# Create the reset SQL script based on mode
if [ "$FULL" = true ]; then
    # FULL RESET - drops everything including connector schemas
    RESET_SQL=$(cat << 'EOSQL'
-- =====================================
-- FULL DATABASE RESET
-- =====================================
-- Drops all objects created by migrations while preserving Supabase system objects

BEGIN;

-- =====================================
-- 1. DROP CUSTOM SCHEMAS (CASCADE removes all objects within)
-- =====================================
DROP SCHEMA IF EXISTS teamwork CASCADE;
DROP SCHEMA IF EXISTS missive CASCADE;
DROP SCHEMA IF EXISTS teamworkmissiveconnector CASCADE;

-- =====================================
-- 2. DROP ALL USER TABLES IN PUBLIC SCHEMA
-- =====================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'public'
        AND tablename NOT LIKE 'pg_%'
        AND tablename NOT LIKE 'sql_%'
    ) LOOP
        EXECUTE 'DROP TABLE IF EXISTS public.' || quote_ident(r.tablename) || ' CASCADE';
        RAISE NOTICE 'Dropped table: %', r.tablename;
    END LOOP;
END $$;

-- =====================================
-- 3. DROP ALL USER VIEWS IN PUBLIC SCHEMA
-- =====================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT viewname 
        FROM pg_views 
        WHERE schemaname = 'public'
    ) LOOP
        EXECUTE 'DROP VIEW IF EXISTS public.' || quote_ident(r.viewname) || ' CASCADE';
        RAISE NOTICE 'Dropped view: %', r.viewname;
    END LOOP;
END $$;

-- =====================================
-- 4. DROP ALL USER FUNCTIONS IN PUBLIC SCHEMA
-- =====================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) as args
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.proname NOT LIKE 'pg_%'
        AND p.prokind IN ('f', 'p')  -- functions and procedures only
    ) LOOP
        BEGIN
            EXECUTE 'DROP FUNCTION IF EXISTS public.' || quote_ident(r.proname) || '(' || r.args || ') CASCADE';
            RAISE NOTICE 'Dropped function: %(%)', r.proname, r.args;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Could not drop function % (may be system function): %', r.proname, SQLERRM;
        END;
    END LOOP;
END $$;

-- =====================================
-- 5. DROP CUSTOM TYPES
-- =====================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT t.typname
        FROM pg_type t
        JOIN pg_namespace n ON t.typnamespace = n.oid
        WHERE n.nspname = 'public'
        AND t.typtype = 'e'  -- enum types
    ) LOOP
        EXECUTE 'DROP TYPE IF EXISTS public.' || quote_ident(r.typname) || ' CASCADE';
        RAISE NOTICE 'Dropped type: %', r.typname;
    END LOOP;
END $$;

-- =====================================
-- 6. DROP EXTENSIONS (except uuid-ossp which Supabase may need)
-- =====================================
DROP EXTENSION IF EXISTS pg_trgm CASCADE;
DROP EXTENSION IF EXISTS unaccent CASCADE;

COMMIT;

SELECT 'Full database reset complete!' as status;
EOSQL
)
else
    # PARTIAL RESET - preserves teamwork, missive, teamworkmissiveconnector schemas
    RESET_SQL=$(cat << 'EOSQL'
-- =====================================
-- PARTIAL DATABASE RESET
-- =====================================
-- Drops ibhelm-specific objects while preserving connector schemas

BEGIN;

-- =====================================
-- 1. DROP ALL USER TABLES IN PUBLIC SCHEMA
-- =====================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'public'
        AND tablename NOT LIKE 'pg_%'
        AND tablename NOT LIKE 'sql_%'
    ) LOOP
        EXECUTE 'DROP TABLE IF EXISTS public.' || quote_ident(r.tablename) || ' CASCADE';
        RAISE NOTICE 'Dropped table: %', r.tablename;
    END LOOP;
END $$;

-- =====================================
-- 2. DROP ALL USER VIEWS IN PUBLIC SCHEMA
-- =====================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT viewname 
        FROM pg_views 
        WHERE schemaname = 'public'
    ) LOOP
        EXECUTE 'DROP VIEW IF EXISTS public.' || quote_ident(r.viewname) || ' CASCADE';
        RAISE NOTICE 'Dropped view: %', r.viewname;
    END LOOP;
END $$;

-- =====================================
-- 3. DROP ALL USER FUNCTIONS IN PUBLIC SCHEMA
-- =====================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) as args
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.proname NOT LIKE 'pg_%'
        AND p.prokind IN ('f', 'p')  -- functions and procedures only
    ) LOOP
        BEGIN
            EXECUTE 'DROP FUNCTION IF EXISTS public.' || quote_ident(r.proname) || '(' || r.args || ') CASCADE';
            RAISE NOTICE 'Dropped function: %(%)', r.proname, r.args;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Could not drop function % (may be system function): %', r.proname, SQLERRM;
        END;
    END LOOP;
END $$;

-- =====================================
-- 4. DROP CUSTOM TYPES
-- =====================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT t.typname
        FROM pg_type t
        JOIN pg_namespace n ON t.typnamespace = n.oid
        WHERE n.nspname = 'public'
        AND t.typtype = 'e'  -- enum types
    ) LOOP
        EXECUTE 'DROP TYPE IF EXISTS public.' || quote_ident(r.typname) || ' CASCADE';
        RAISE NOTICE 'Dropped type: %', r.typname;
    END LOOP;
END $$;

-- =====================================
-- 5. DROP EXTENSIONS (except uuid-ossp which Supabase may need)
-- =====================================
DROP EXTENSION IF EXISTS pg_trgm CASCADE;
DROP EXTENSION IF EXISTS unaccent CASCADE;

COMMIT;

SELECT 'Partial database reset complete! (teamwork, missive, teamworkmissiveconnector schemas preserved)' as status;
EOSQL
)
fi

# Execute the reset
echo -e "${CYAN}Executing reset SQL...${NC}"
echo ""

if echo "$RESET_SQL" | docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME"; then
    echo ""
    echo "=========================================="
    if [ "$FULL" = true ]; then
        echo -e "${GREEN}✓ Full database reset complete!${NC}"
    else
        echo -e "${GREEN}✓ Partial database reset complete!${NC}"
        echo -e "${CYAN}  (teamwork, missive, teamworkmissiveconnector preserved)${NC}"
    fi
    echo "=========================================="
    echo ""
    echo "You can now re-apply migrations with:"
    echo "  ./apply_migrations.sh"
else
    echo ""
    echo -e "${RED}✗ Database reset failed!${NC}"
    exit 1
fi
