-- Service Roles for External Components
-- These roles have MINIMAL permissions required for their specific tasks.
-- Use these instead of service_role key for better security.
--
-- SECURITY MODEL:
-- Each component has ONE secret that serves TWO purposes:
--   1. Database role password (PostgreSQL authentication)
--   2. API key for PostgREST proxy (X-API-Key header validation)
-- This simplifies deployment while maintaining security boundaries.
-- If a secret leaks, the attacker can only access what that role permits.
--
-- IMPORTANT: After running this script, set passwords:
--   ALTER ROLE tte_fetcher WITH PASSWORD 'your-secure-password';
--   ALTER ROLE tte_uploader WITH PASSWORD 'your-secure-password';
--   ALTER ROLE fms_service WITH PASSWORD 'your-fms-service-secret';
--   ALTER ROLE mad_downloader WITH PASSWORD 'your-mad-service-secret';
--   ALTER ROLE tmc_connector WITH PASSWORD 'your-secure-password';

--------------------------------------------------------------------------------
-- ThumbnailTextExtractor Roles
-- Security model: Direct PostgreSQL with minimal GRANT permissions
-- Even if credentials stolen, attacker can ONLY do what's granted - nothing else.
--------------------------------------------------------------------------------

-- Drop existing roles if they exist (for idempotency)
DO $$ 
BEGIN
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

GRANT USAGE ON SCHEMA public TO tte_fetcher;
GRANT EXECUTE ON FUNCTION public.claim_pending_file_content(INTEGER) TO tte_fetcher;

--------------------------------------------------------------------------------
-- tte_uploader: Can ONLY update file_contents with processing results
-- Used by ThumbnailTextExtractor uploader component
--------------------------------------------------------------------------------
CREATE ROLE tte_uploader WITH LOGIN;
COMMENT ON ROLE tte_uploader IS 'ThumbnailTextExtractor uploader - can ONLY update processing results';

GRANT USAGE ON SCHEMA public TO tte_uploader;
GRANT SELECT (content_hash) ON public.file_contents TO tte_uploader;
GRANT UPDATE (
    processing_status, thumbnail_path, thumbnail_generated_at,
    extracted_text, try_count, last_status_change, db_updated_at
) ON public.file_contents TO tte_uploader;

--------------------------------------------------------------------------------
-- FileMetadataSync (FMS) Role
-- Scans filesystem, registers files, and handles S3 upload queue
--
-- DUAL-USE SECRET: FMS_SERVICE_SECRET is used as:
--   1. This role's DB password (for PostgREST → PostgreSQL)
--   2. API key in X-API-Key header (for FMS → PostgREST proxy)
-- Configure nginx to validate X-API-Key against this same value.
--------------------------------------------------------------------------------

-- Drop existing roles if they exist (for idempotency)
DO $$ 
BEGIN
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM fms_service';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM fms_service';
    -- Clean up old split roles if they exist
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM fms_scanner';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM fms_scanner';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM fms_uploader';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM fms_uploader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

DROP ROLE IF EXISTS fms_service;
DROP ROLE IF EXISTS fms_scanner;
DROP ROLE IF EXISTS fms_uploader;

CREATE ROLE fms_service WITH LOGIN;
COMMENT ON ROLE fms_service IS 'FileMetadataSync - can scan files and process upload queue';

GRANT USAGE ON SCHEMA public TO fms_service;

-- Scanner operations: read/upsert files and file_contents
GRANT SELECT ON public.files TO fms_service;
GRANT INSERT ON public.files TO fms_service;
GRANT UPDATE (
    full_path, content_hash, last_seen_at, deleted_at, db_updated_at,
    filesystem_inode, filesystem_attributes, auto_extracted_metadata,
    fs_mtime, fs_ctime
) ON public.files TO fms_service;

GRANT SELECT ON public.file_contents TO fms_service;
GRANT INSERT ON public.file_contents TO fms_service;
GRANT UPDATE (content_hash, size_bytes, mime_type, db_updated_at) ON public.file_contents TO fms_service;

-- Uploader operations: process S3 upload queue via SECURITY DEFINER functions
GRANT EXECUTE ON FUNCTION public.dequeue_upload_batch(INTEGER, TEXT[]) TO fms_service;
GRANT EXECUTE ON FUNCTION public.mark_upload_complete(TEXT, TEXT, TEXT) TO fms_service;
GRANT EXECUTE ON FUNCTION public.mark_upload_failed(TEXT, TEXT) TO fms_service;
GRANT EXECUTE ON FUNCTION public.mark_upload_skipped(TEXT, TEXT) TO fms_service;
GRANT EXECUTE ON FUNCTION public.reset_stuck_uploads() TO fms_service;

--------------------------------------------------------------------------------
-- MissiveAttachmentDownloader (MAD) Role
-- Downloads email attachments from Missive API to local storage
--
-- DUAL-USE SECRET: MAD_SERVICE_SECRET is used as:
--   1. This role's DB password (for PostgREST → PostgreSQL)
--   2. API key in X-API-Key header (for MAD → PostgREST proxy)
-- Configure nginx to validate X-API-Key against this same value.
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

-- Read and update email_attachment_files (PostgREST needs table-level access)
GRANT SELECT ON public.email_attachment_files TO mad_downloader;
GRANT UPDATE ON public.email_attachment_files TO mad_downloader;

--------------------------------------------------------------------------------
-- TeamworkMissiveConnector (TMC) Role
-- Syncs data from Teamwork, Missive, and Craft APIs into database
--
-- TMC uses psycopg2 directly (not PostgREST). Update PG_DSN to use this role:
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

-- teamwork schema: Full write access
GRANT SELECT, INSERT, UPDATE ON teamwork.companies TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.users TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.teams TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.tags TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.projects TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.tasklists TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.tasks TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamwork.timelogs TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON teamwork.task_tags TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON teamwork.task_assignees TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON teamwork.user_teams TO tmc_connector;

-- missive schema: Full write access
GRANT SELECT, INSERT, UPDATE ON missive.users TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.teams TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.shared_labels TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.conversations TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.messages TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.attachments TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.conversation_comments TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.comment_attachments TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.comment_tasks TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON missive.contacts TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.conversation_users TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.conversation_assignees TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.conversation_labels TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.conversation_authors TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.message_recipients TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.comment_mentions TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON missive.comment_task_assignees TO tmc_connector;

-- public schema: Direct access
GRANT SELECT, INSERT, UPDATE ON public.craft_documents TO tmc_connector;
GRANT SELECT ON public.app_settings TO tmc_connector;

-- public schema: Tables written by DB triggers during TMC inserts
-- (auto-link persons, auto-categorize locations/cost_groups, auto-link projects, etc.)
GRANT SELECT, INSERT, UPDATE ON public.unified_persons TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.unified_person_links TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.object_locations TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.object_cost_groups TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.task_extensions TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.project_conversations TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.project_extensions TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_attachment_files TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.item_involved_persons TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_triggers TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON public.mv_refresh_status TO tmc_connector;
GRANT SELECT ON public.locations TO tmc_connector;
GRANT SELECT ON public.cost_groups TO tmc_connector;
GRANT SELECT ON public.task_types TO tmc_connector;
GRANT SELECT ON public.task_type_rules TO tmc_connector;

-- teamworkmissiveconnector schema: Queue management
GRANT SELECT, INSERT, UPDATE ON teamworkmissiveconnector.queue_items TO tmc_connector;
GRANT SELECT, INSERT, UPDATE ON teamworkmissiveconnector.checkpoints TO tmc_connector;
GRANT SELECT, INSERT, UPDATE, DELETE ON teamworkmissiveconnector.webhook_config TO tmc_connector;
GRANT SELECT ON teamworkmissiveconnector.queue_health TO tmc_connector;
GRANT EXECUTE ON FUNCTION teamworkmissiveconnector.dequeue_items(VARCHAR, INTEGER, VARCHAR) TO tmc_connector;
GRANT EXECUTE ON FUNCTION teamworkmissiveconnector.mark_completed(INTEGER, INTEGER) TO tmc_connector;
GRANT EXECUTE ON FUNCTION teamworkmissiveconnector.mark_failed(INTEGER, TEXT, BOOLEAN) TO tmc_connector;
GRANT EXECUTE ON FUNCTION teamworkmissiveconnector.cleanup_old_items(INTEGER) TO tmc_connector;
GRANT EXECUTE ON FUNCTION teamworkmissiveconnector.reset_stuck_items(INTEGER) TO tmc_connector;

-- Sequence access (needed for INSERT on tables with serial/identity columns)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA teamwork TO tmc_connector;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA missive TO tmc_connector;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA teamworkmissiveconnector TO tmc_connector;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO tmc_connector;

--------------------------------------------------------------------------------
-- MCP Server (Read-Only) Role
-- The stubs file creates mcp_readonly as NOLOGIN; upgrade to LOGIN here
-- so the MCP server can connect directly via psycopg/asyncpg.
--------------------------------------------------------------------------------
ALTER ROLE mcp_readonly WITH LOGIN;

--------------------------------------------------------------------------------
-- Verification queries (run manually)
--------------------------------------------------------------------------------
-- Check role permissions:
--   SELECT * FROM information_schema.role_table_grants WHERE grantee = 'fms_service';
--   SELECT * FROM information_schema.role_routine_grants WHERE grantee = 'fms_service';
--
-- Test fms_service:
--   SET ROLE fms_service;
--   SELECT full_path FROM files LIMIT 1;  -- Should work
--   SELECT * FROM teamwork.tasks LIMIT 1;  -- Should FAIL
--   RESET ROLE;
--
-- Test mad_downloader:
--   SET ROLE mad_downloader;
--   SELECT * FROM get_pending_project_attachments(1);  -- Should work
--   SELECT * FROM missive.messages LIMIT 1;  -- Should FAIL
--   RESET ROLE;
