#!/bin/bash
# =====================================
# RESET DATABASE
# =====================================
# Drops all custom schemas, tables, views, functions, types, and extensions
# that were created by the migrations.
#
# PRESERVES: auth, storage, and other Supabase system schemas
#
# Usage: ./reset_db.sh
#        ./reset_db.sh --force  (skip confirmation)
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

echo "=========================================="
echo "  IBHelm Database Reset"
echo "=========================================="
echo ""

# Check for --force flag
FORCE=false
if [ "$1" == "--force" ]; then
    FORCE=true
fi

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
    echo -e "${RED}WARNING: This will DROP all custom database objects!${NC}"
    echo ""
    echo "This will remove:"
    echo "  - Schemas: teamwork, missive, teamworkmissiveconnector"
    echo "  - All tables, views, functions in public schema (created by migrations)"
    echo "  - Custom types: task_extension_type, location_type"
    echo "  - Extensions: pg_trgm, unaccent (uuid-ossp kept for Supabase)"
    echo ""
    echo "This will PRESERVE:"
    echo "  - auth schema (Supabase authentication)"
    echo "  - storage schema (Supabase storage)"
    echo "  - Other Supabase system schemas"
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

# Create the reset SQL script
# This dynamically finds and drops objects to be robust against migration changes
RESET_SQL=$(cat << 'EOSQL'
-- =====================================
-- DYNAMIC DATABASE RESET
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
-- This finds all tables in public schema and drops them
-- Supabase system tables are in other schemas (auth, storage, etc.)
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
        -- Exclude common PostGIS/system functions if any
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
-- Note: uuid-ossp is kept as Supabase uses it for gen_random_uuid()

COMMIT;

-- Confirmation
SELECT 'Database reset complete!' as status;
EOSQL
)

# Execute the reset
echo -e "${CYAN}Executing reset SQL...${NC}"
echo ""

if echo "$RESET_SQL" | docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME"; then
    echo ""
    echo "=========================================="
    echo -e "${GREEN}✓ Database reset complete!${NC}"
    echo "=========================================="
    echo ""
    echo "You can now re-apply migrations with:"
    echo "  ./apply_migrations.sh"
else
    echo ""
    echo -e "${RED}✗ Database reset failed!${NC}"
    exit 1
fi

