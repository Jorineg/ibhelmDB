-- Service Roles for External Components
-- These roles have MINIMAL permissions required for their specific tasks.
-- Use these instead of service_role key for better security.
--
-- IMPORTANT: After running this script, set passwords:
--   ALTER ROLE tte_fetcher WITH PASSWORD 'your-secure-password';
--   ALTER ROLE tte_uploader WITH PASSWORD 'your-secure-password';
--   ALTER ROLE fms_scanner WITH PASSWORD 'your-secure-password';
--   ALTER ROLE fms_uploader WITH PASSWORD 'your-secure-password';
--   ALTER ROLE mad_downloader WITH PASSWORD 'your-secure-password';
--   ALTER ROLE tmc_connector WITH PASSWORD 'your-secure-password';

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

--------------------------------------------------------------------------------
-- FileMetadataSync (FMS) Roles
-- Scanner: Reads/upserts files and file_contents tables
-- Uploader: Dequeues upload batch, marks upload status
--
-- NOTE: FMS currently uses Supabase REST API (service_role key). To use these
-- roles, update FMS to use direct PostgreSQL connection:
--   PG_DSN_SCANNER=postgresql://fms_scanner:PASSWORD@host:5432/postgres
--   PG_DSN_UPLOADER=postgresql://fms_uploader:PASSWORD@host:5432/postgres
--------------------------------------------------------------------------------

-- Drop existing roles if they exist (for idempotency)
DO $$ 
BEGIN
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM fms_scanner';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM fms_scanner';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM fms_uploader';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM fms_uploader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

DROP ROLE IF EXISTS fms_scanner;
DROP ROLE IF EXISTS fms_uploader;

--------------------------------------------------------------------------------
-- fms_scanner: Scans filesystem and registers files/content
--------------------------------------------------------------------------------
CREATE ROLE fms_scanner WITH LOGIN;
COMMENT ON ROLE fms_scanner IS 'FileMetadataSync scanner - can read and upsert files/file_contents';

GRANT USAGE ON SCHEMA public TO fms_scanner;

-- Read file paths for change detection
GRANT SELECT (full_path, content_hash) ON public.files TO fms_scanner;

-- Upsert file_contents (CAS record)
GRANT SELECT ON public.file_contents TO fms_scanner;
GRANT INSERT ON public.file_contents TO fms_scanner;
GRANT UPDATE (
    size_bytes, mime_type, db_updated_at
) ON public.file_contents TO fms_scanner;

-- Upsert files (path reference) and update last_seen_at/deleted_at
GRANT SELECT ON public.files TO fms_scanner;
GRANT INSERT ON public.files TO fms_scanner;
GRANT UPDATE (
    content_hash, last_seen_at, deleted_at, db_updated_at,
    filesystem_inode, filesystem_attributes, auto_extracted_metadata,
    fs_mtime, fs_ctime
) ON public.files TO fms_scanner;

--------------------------------------------------------------------------------
-- fms_uploader: Handles S3 upload queue
--------------------------------------------------------------------------------
CREATE ROLE fms_uploader WITH LOGIN;
COMMENT ON ROLE fms_uploader IS 'FileMetadataSync uploader - can only process upload queue via functions';

GRANT USAGE ON SCHEMA public TO fms_uploader;

-- SECURITY DEFINER functions - uploader only needs EXECUTE
GRANT EXECUTE ON FUNCTION public.dequeue_upload_batch(INTEGER, TEXT[]) TO fms_uploader;
GRANT EXECUTE ON FUNCTION public.mark_upload_complete(TEXT, TEXT, TEXT) TO fms_uploader;
GRANT EXECUTE ON FUNCTION public.mark_upload_failed(TEXT, TEXT) TO fms_uploader;
GRANT EXECUTE ON FUNCTION public.mark_upload_skipped(TEXT, TEXT) TO fms_uploader;
GRANT EXECUTE ON FUNCTION public.reset_stuck_uploads() TO fms_uploader;

--------------------------------------------------------------------------------
-- MissiveAttachmentDownloader (MAD) Role
-- Downloads email attachments from Missive API to local storage
--
-- NOTE: MAD currently uses Supabase REST API (service_role key). To use this
-- role, update MAD to use direct PostgreSQL connection:
--   PG_DSN=postgresql://mad_downloader:PASSWORD@host:5432/postgres
--------------------------------------------------------------------------------

-- Drop existing role if exists (for idempotency)
DO $$ 
BEGIN
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM mad_downloader';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM mad_downloader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

DROP ROLE IF EXISTS mad_downloader;

CREATE ROLE mad_downloader WITH LOGIN;
COMMENT ON ROLE mad_downloader IS 'MissiveAttachmentDownloader - can only process attachment download queue';

GRANT USAGE ON SCHEMA public TO mad_downloader;

-- Get pending attachments via SECURITY DEFINER function (reads across schemas)
GRANT EXECUTE ON FUNCTION public.get_pending_project_attachments(INTEGER, INTEGER) TO mad_downloader;

-- Update email_attachment_files status
GRANT SELECT (missive_attachment_id, retry_count) ON public.email_attachment_files TO mad_downloader;
GRANT UPDATE (
    status, local_filename, downloaded_at, updated_at, 
    error_message, retry_count, skip_reason, original_url
) ON public.email_attachment_files TO mad_downloader;

--------------------------------------------------------------------------------
-- TeamworkMissiveConnector (TMC) Role
-- Syncs data from Teamwork, Missive, and Craft APIs into database
--
-- TMC already uses psycopg2 directly. Update PG_DSN to use this role:
--   PG_DSN=postgresql://tmc_connector:PASSWORD@host:5432/postgres
--------------------------------------------------------------------------------

-- Drop existing role if exists (for idempotency)
DO $$ 
BEGIN
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM tmc_connector';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA teamwork FROM tmc_connector';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA missive FROM tmc_connector';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA teamworkmissiveconnector FROM tmc_connector';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA teamworkmissiveconnector FROM tmc_connector';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

DROP ROLE IF EXISTS tmc_connector;

CREATE ROLE tmc_connector WITH LOGIN;
COMMENT ON ROLE tmc_connector IS 'TeamworkMissiveConnector - can sync Teamwork, Missive, Craft data';

-- Schema access
GRANT USAGE ON SCHEMA public TO tmc_connector;
GRANT USAGE ON SCHEMA teamwork TO tmc_connector;
GRANT USAGE ON SCHEMA missive TO tmc_connector;
GRANT USAGE ON SCHEMA teamworkmissiveconnector TO tmc_connector;

-- ========================================
-- teamwork schema: Full write access to all tables
-- ========================================
GRANT SELECT, INSERT, UPDATE ON teamwork.companies TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.users TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.teams TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.tags TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.projects TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.tasklists TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.tasks TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.timelogs TO tmc_connector;

-- Junction tables: Full control (need DELETE for sync)
GRANT SELECT, INSERT, UPDATE, DELETE ON teamwork.task_tags TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON teamwork.task_assignees TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON teamwork.user_teams TO tmc_connector;

-- ========================================
-- missive schema: Full write access to all tables
-- ========================================
GRANT SELECT, INSERT, UPDATE ON missive.users TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.teams TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.shared_labels TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.conversations TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.messages TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.attachments TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.conversation_comments TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.comment_attachments TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.comment_tasks TO tmc_connector;

-- Contacts: need INSERT for get_or_create pattern
GRANT SELECT, INSERT, UPDATE ON missive.contacts TO tmc_connector;
GRANT USAGE ON SEQUENCE missive.contacts_id_seq TO tmc_connector;

-- Tables with serial IDs need sequence grants
GRANT USAGE ON SEQUENCE missive.message_recipients_id_seq TO tmc_connector;
GRANT USAGE ON SEQUENCE missive.conversation_authors_id_seq TO tmc_connector;
GRANT USAGE ON SEQUENCE missive.comment_mentions_id_seq TO tmc_connector;
GRANT USAGE ON SEQUENCE missive.comment_tasks_id_seq TO tmc_connector;

-- Junction tables: Full control (need DELETE for sync)
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.conversation_users TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.conversation_assignees TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.conversation_labels TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.conversation_authors TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.message_recipients TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.comment_mentions TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.comment_task_assignees TO tmc_connector;

-- ========================================
-- public schema: Limited access
-- ========================================
-- Craft documents
GRANT SELECT, INSERT, UPDATE ON public.craft_documents TO tmc_connector;

-- App settings (read-only for sync filters)
GRANT SELECT ON public.app_settings TO tmc_connector;

-- ========================================
-- teamworkmissiveconnector schema: Queue management
-- ========================================
GRANT SELECT, INSERT, UPDATE ON teamworkmissiveconnector.queue_items TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamworkmissiveconnector.checkpoints TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON teamworkmissiveconnector.webhook_config TO tmc_connector;
GRANT SELECT ON teamworkmissiveconnector.queue_health TO tmc_connector;

-- Queue functions
GRANT EXECUTE ON FUNCTION teamworkmissiveconnector.dequeue_items(VARCHAR, INTEGER, VARCHAR) TO tmc_connector;
GRANT EXECUTE ON FUNCTION teamworkmissiveconnector.mark_completed(INTEGER, INTEGER) TO tmc_connector;
GRANT EXECUTE ON FUNCTION teamworkmissiveconnector.mark_failed(INTEGER, TEXT, BOOLEAN) TO tmc_connector;
GRANT EXECUTE ON FUNCTION teamworkmissiveconnector.cleanup_old_items(INTEGER) TO tmc_connector;
GRANT EXECUTE ON FUNCTION teamworkmissiveconnector.reset_stuck_items(INTEGER) TO tmc_connector;

--------------------------------------------------------------------------------
-- Verification queries (run manually to verify permissions)
--------------------------------------------------------------------------------
-- Check fms_scanner permissions:
--   SELECT * FROM information_schema.role_table_grants WHERE grantee = 'fms_scanner';
--
-- Check fms_uploader permissions:
--   SELECT * FROM information_schema.role_routine_grants WHERE grantee = 'fms_uploader';
--
-- Check mad_downloader permissions:
--   SELECT * FROM information_schema.role_table_grants WHERE grantee = 'mad_downloader';
--
-- Check tmc_connector permissions:
--   SELECT * FROM information_schema.role_table_grants WHERE grantee = 'tmc_connector';
--
-- Test mad_downloader:
--   SET ROLE mad_downloader;
--   SELECT * FROM get_pending_project_attachments(1);  -- Should work
--   SELECT * FROM missive.messages LIMIT 1;  -- Should FAIL
--   RESET ROLE;
