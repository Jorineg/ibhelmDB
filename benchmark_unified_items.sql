-- =====================================
-- UNIFIED ITEMS PERFORMANCE BENCHMARK
-- =====================================
-- Run this in psql to measure query performance
-- Usage: psql -U postgres -d postgres -f benchmark_unified_items.sql

\echo '========================================'
\echo 'UNIFIED ITEMS PERFORMANCE BENCHMARK'
\echo '========================================'
\echo ''

-- Enable timing
\timing on

-- =====================================
-- 1. BASIC COUNTS
-- =====================================
\echo ''
\echo '--- 1. BASIC COUNTS ---'
\echo ''

\echo 'Total tasks:'
SELECT COUNT(*) FROM teamwork.tasks WHERE deleted_at IS NULL;

\echo ''
\echo 'Total messages:'
SELECT COUNT(*) FROM missive.messages;

\echo ''
\echo 'Total unified_items (full count):'
SELECT COUNT(*) FROM unified_items;

-- =====================================
-- 2. SIMPLE SELECT (First 50 rows)
-- =====================================
\echo ''
\echo '--- 2. SIMPLE SELECT (First 50 rows, sorted by sort_date) ---'
\echo ''

\echo 'SELECT all columns:'
SELECT * FROM unified_items ORDER BY sort_date DESC LIMIT 50;

\echo ''
\echo 'SELECT only essential columns:'
SELECT 
    id, type, name, description, status, project, customer,
    task_type_name, task_type_color, assignees, tags,
    teamwork_url, missive_url, sort_date
FROM unified_items 
ORDER BY sort_date DESC 
LIMIT 50;

-- =====================================
-- 3. TYPE FILTERING
-- =====================================
\echo ''
\echo '--- 3. TYPE FILTERING ---'
\echo ''

\echo 'Tasks only (50 rows):'
SELECT * FROM unified_items WHERE type = 'task' ORDER BY sort_date DESC LIMIT 50;

\echo ''
\echo 'Emails only (50 rows):'
SELECT * FROM unified_items WHERE type = 'email' ORDER BY sort_date DESC LIMIT 50;

-- =====================================
-- 4. SEARCH QUERIES
-- =====================================
\echo ''
\echo '--- 4. SEARCH QUERIES ---'
\echo ''

\echo 'Search in name (ilike):'
SELECT * FROM unified_items 
WHERE name ILIKE '%test%' 
ORDER BY sort_date DESC 
LIMIT 50;

\echo ''
\echo 'Search in description (ilike):'
SELECT * FROM unified_items 
WHERE description ILIKE '%test%' 
ORDER BY sort_date DESC 
LIMIT 50;

\echo ''
\echo 'Search in conversation_comments_text (ilike):'
SELECT * FROM unified_items 
WHERE conversation_comments_text ILIKE '%test%' 
ORDER BY sort_date DESC 
LIMIT 50;

\echo ''
\echo 'Combined search (name OR description OR comments):'
SELECT * FROM unified_items 
WHERE name ILIKE '%test%' 
   OR description ILIKE '%test%' 
   OR conversation_comments_text ILIKE '%test%'
ORDER BY sort_date DESC 
LIMIT 50;

-- =====================================
-- 5. FILTER BY PROJECT/LOCATION
-- =====================================
\echo ''
\echo '--- 5. FILTER BY PROJECT/LOCATION ---'
\echo ''

\echo 'Filter by project name:'
SELECT * FROM unified_items 
WHERE project IS NOT NULL AND project != ''
ORDER BY sort_date DESC 
LIMIT 50;

\echo ''
\echo 'Filter by location:'
SELECT * FROM unified_items 
WHERE location IS NOT NULL 
ORDER BY sort_date DESC 
LIMIT 50;

-- =====================================
-- 6. TASK TYPE FILTERING
-- =====================================
\echo ''
\echo '--- 6. TASK TYPE FILTERING ---'
\echo ''

\echo 'Filter tasks by task_type_id (if any exist):'
SELECT * FROM unified_items 
WHERE type = 'task' AND task_type_id IS NOT NULL
ORDER BY sort_date DESC 
LIMIT 50;

-- =====================================
-- 7. EXPLAIN ANALYZE (Detailed execution plans)
-- =====================================
\echo ''
\echo '--- 7. EXPLAIN ANALYZE ---'
\echo ''

\echo 'Full table scan with limit:'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) 
SELECT * FROM unified_items ORDER BY sort_date DESC LIMIT 50;

\echo ''
\echo 'Type filter + sort:'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) 
SELECT * FROM unified_items WHERE type = 'task' ORDER BY sort_date DESC LIMIT 50;

\echo ''
\echo 'Search query:'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) 
SELECT * FROM unified_items 
WHERE name ILIKE '%test%' OR description ILIKE '%test%'
ORDER BY sort_date DESC 
LIMIT 50;

-- =====================================
-- 8. MATERIALIZED VIEWS FRESHNESS
-- =====================================
\echo ''
\echo '--- 8. MATERIALIZED VIEWS STATUS ---'
\echo ''

SELECT 
    view_name,
    needs_refresh,
    last_refreshed_at,
    refresh_interval_minutes,
    NOW() - last_refreshed_at AS time_since_refresh
FROM mv_refresh_status
ORDER BY view_name;

-- =====================================
-- 9. MATERIALIZED VIEW ROW COUNTS
-- =====================================
\echo ''
\echo '--- 9. MATERIALIZED VIEW ROW COUNTS ---'
\echo ''

\echo 'mv_task_assignees_agg:'
SELECT COUNT(*) FROM mv_task_assignees_agg;

\echo ''
\echo 'mv_task_tags_agg:'
SELECT COUNT(*) FROM mv_task_tags_agg;

\echo ''
\echo 'mv_message_recipients_agg:'
SELECT COUNT(*) FROM mv_message_recipients_agg;

\echo ''
\echo 'mv_message_attachments_agg:'
SELECT COUNT(*) FROM mv_message_attachments_agg;

\echo ''
\echo 'mv_conversation_labels_agg:'
SELECT COUNT(*) FROM mv_conversation_labels_agg;

-- =====================================
-- 10. PAGINATION SIMULATION
-- =====================================
\echo ''
\echo '--- 10. PAGINATION SIMULATION ---'
\echo ''

\echo 'Page 1 (offset 0):'
SELECT id, type, name FROM unified_items ORDER BY sort_date DESC LIMIT 50 OFFSET 0;

\echo ''
\echo 'Page 2 (offset 50):'
SELECT id, type, name FROM unified_items ORDER BY sort_date DESC LIMIT 50 OFFSET 50;

\echo ''
\echo 'Page 10 (offset 450):'
SELECT id, type, name FROM unified_items ORDER BY sort_date DESC LIMIT 50 OFFSET 450;

\echo ''
\echo 'Page 100 (offset 4950) - Deep pagination test:'
SELECT id, type, name FROM unified_items ORDER BY sort_date DESC LIMIT 50 OFFSET 4950;

-- =====================================
-- 11. SUMMARY STATS
-- =====================================
\echo ''
\echo '--- 11. TABLE/VIEW STATISTICS ---'
\echo ''

SELECT 
    schemaname,
    relname AS table_name,
    n_live_tup AS estimated_rows,
    n_dead_tup AS dead_rows,
    last_vacuum,
    last_analyze
FROM pg_stat_user_tables
WHERE relname IN ('tasks', 'messages', 'task_assignees', 'task_tags', 
                  'message_recipients', 'attachments', 'conversation_labels', 
                  'conversation_comments')
ORDER BY schemaname, relname;

\timing off

\echo ''
\echo '========================================'
\echo 'BENCHMARK COMPLETE'
\echo '========================================'

