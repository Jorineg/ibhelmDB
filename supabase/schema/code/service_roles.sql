-- Service Roles for External Components
-- These roles have MINIMAL permissions required for their specific tasks.
-- Use these instead of service_role key for better security.
--
-- IMPORTANT: After running this script, set passwords:
--   ALTER ROLE tte_fetcher WITH PASSWORD 'your-secure-password';
--   ALTER ROLE tte_uploader WITH PASSWORD 'your-secure-password';

--------------------------------------------------------------------------------
-- ThumbnailTextExtractor Roles
-- Security model: Direct PostgreSQL with minimal GRANT permissions
-- Even if credentials stolen, attacker can ONLY do what's granted - nothing else.
--------------------------------------------------------------------------------

-- Drop existing roles if they exist (for idempotency)
DO $$ 
BEGIN
    -- Revoke all privileges first to avoid dependency issues
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM tte_fetcher' ;
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM tte_fetcher';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM tte_uploader';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM tte_uploader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

DROP ROLE IF EXISTS tte_fetcher;
DROP ROLE IF EXISTS tte_uploader;

--------------------------------------------------------------------------------
-- tte_fetcher: Can ONLY claim pending file_content records
-- Used by ThumbnailTextExtractor fetcher component
--------------------------------------------------------------------------------
CREATE ROLE tte_fetcher WITH LOGIN;
COMMENT ON ROLE tte_fetcher IS 'ThumbnailTextExtractor fetcher - can ONLY claim pending files';

-- Grant minimal permissions
-- NOTE: claim_pending_file_content is SECURITY DEFINER, so it runs as owner
-- and tte_fetcher does NOT need any table permissions - only EXECUTE on function
GRANT USAGE ON SCHEMA public TO tte_fetcher;
GRANT EXECUTE ON FUNCTION public.claim_pending_file_content(INTEGER) TO tte_fetcher;

-- Explicitly deny everything else (not strictly needed, but documents intent)
-- The role has no other grants, so it cannot:
-- - SELECT from any table (SECURITY DEFINER handles this inside the function)
-- - INSERT/UPDATE/DELETE any table
-- - Execute any other function
-- - Access any other schema

--------------------------------------------------------------------------------
-- tte_uploader: Can ONLY update file_contents with processing results
-- Used by ThumbnailTextExtractor uploader component
--------------------------------------------------------------------------------
CREATE ROLE tte_uploader WITH LOGIN;
COMMENT ON ROLE tte_uploader IS 'ThumbnailTextExtractor uploader - can ONLY update processing results';

-- Grant minimal permissions
GRANT USAGE ON SCHEMA public TO tte_uploader;

-- Can only SELECT to find record by content_hash (needed for WHERE clause)
GRANT SELECT (content_hash) ON public.file_contents TO tte_uploader;

-- Can only UPDATE these specific columns - nothing else
GRANT UPDATE (
    processing_status,
    thumbnail_path,
    thumbnail_generated_at,
    extracted_text,
    try_count,
    last_status_change,
    db_updated_at
) ON public.file_contents TO tte_uploader;

-- Explicitly document what this role CANNOT do:
-- - Cannot SELECT any other columns (e.g., storage_path, size_bytes)
-- - Cannot INSERT new records
-- - Cannot DELETE records
-- - Cannot access any other table
-- - Cannot execute any function

--------------------------------------------------------------------------------
-- Verification queries (run manually to verify permissions)
--------------------------------------------------------------------------------
-- Check tte_fetcher permissions:
--   SELECT * FROM information_schema.role_routine_grants WHERE grantee = 'tte_fetcher';
--
-- Check tte_uploader permissions:
--   SELECT * FROM information_schema.role_column_grants WHERE grantee = 'tte_uploader';
--
-- Test tte_fetcher can only claim:
--   SET ROLE tte_fetcher;
--   SELECT * FROM claim_pending_file_content(1);  -- Should work
--   SELECT * FROM file_contents LIMIT 1;          -- Should FAIL (permission denied)
--   RESET ROLE;
--
-- Test tte_uploader can only update:
--   SET ROLE tte_uploader;
--   UPDATE file_contents SET processing_status = 'test' WHERE content_hash = 'xxx';  -- Should work
--   SELECT storage_path FROM file_contents LIMIT 1;  -- Should FAIL (permission denied)
--   RESET ROLE;
