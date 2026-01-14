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
-- SELECT cron.schedule(
--     'cleanup_eadir_files',
--     '0 5 * * *',
--     $$DELETE FROM public.files WHERE folder_path LIKE '%@eaDir%' OR (auto_extracted_metadata->>'original_path') LIKE '%@eaDir%'$$
-- );

-- Remove existing stuck indexing cleanup job if present (idempotent)
SELECT cron.unschedule('cleanup_stuck_indexing') 
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup_stuck_indexing');

-- Reset stuck "indexing" items every 5 minutes
-- Items stuck > 30 minutes: reset to pending (or error if max retries reached)
SELECT cron.schedule(
    'cleanup_stuck_indexing',
    '*/5 * * * *',
    $$
    UPDATE public.file_contents
    SET 
        processing_status = CASE WHEN try_count >= 2 THEN 'error' ELSE 'pending' END,
        try_count = try_count + 1,
        status_message = CASE WHEN try_count >= 2 THEN 'stuck in indexing' ELSE status_message END,
        last_status_change = NOW(),
        db_updated_at = NOW()
    WHERE processing_status = 'indexing'
      AND last_status_change < NOW() - INTERVAL '30 minutes'
    $$
);

-- Verify
SELECT jobid, jobname, schedule, command FROM cron.job;

