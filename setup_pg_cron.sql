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

-- Verify
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_unified_items_mvs';

