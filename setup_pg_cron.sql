-- =====================================
-- PG_CRON SETUP (run manually after schema deploy)
-- =====================================
-- This is separate from schema because pg_cron is server-specific infrastructure
-- Run this once on the server: psql $DATABASE_URL -f setup_pg_cron.sql

-- Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Remove existing job if present (idempotent)
SELECT cron.unschedule('refresh_unified_items_mvs') 
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'refresh_unified_items_mvs');

-- Schedule materialized view refresh every minute
SELECT cron.schedule(
    'refresh_unified_items_mvs',
    '* * * * *',
    $$SELECT refresh_stale_unified_items_aggregates()$$
);

-- Remove existing cleanup job if present (idempotent)
SELECT cron.unschedule('cleanup_eadir_files') 
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup_eadir_files');

-- Hard-delete @eaDir files daily at 5 AM (Synology metadata, should not be synced)
SELECT cron.schedule(
    'cleanup_eadir_files',
    '0 5 * * *',
    $$DELETE FROM public.files WHERE folder_path LIKE '%@eaDir%' OR (auto_extracted_metadata->>'original_path') LIKE '%@eaDir%'$$
);

-- Verify
SELECT jobid, jobname, schedule, command FROM cron.job;

