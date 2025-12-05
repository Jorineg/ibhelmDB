-- =====================================
-- UNIFIED ITEMS BENCHMARK - SUMMARY TABLE
-- =====================================
-- Creates a summary of query execution times
-- Run: psql -U postgres -d postgres -f benchmark_unified_items_summary.sql

DO $$
DECLARE
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    v_count BIGINT;
    results TEXT := '';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'UNIFIED ITEMS PERFORMANCE BENCHMARK';
    RAISE NOTICE '========================================';
    RAISE NOTICE '';
    
    -- Test 1: Full count
    start_time := clock_timestamp();
    SELECT COUNT(*) INTO v_count FROM unified_items;
    end_time := clock_timestamp();
    RAISE NOTICE '1. Full COUNT(*): % rows in % ms', v_count, EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 2: Count tasks only
    start_time := clock_timestamp();
    SELECT COUNT(*) INTO v_count FROM unified_items WHERE type = 'task';
    end_time := clock_timestamp();
    RAISE NOTICE '2. COUNT tasks only: % rows in % ms', v_count, EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 3: Count emails only
    start_time := clock_timestamp();
    SELECT COUNT(*) INTO v_count FROM unified_items WHERE type = 'email';
    end_time := clock_timestamp();
    RAISE NOTICE '3. COUNT emails only: % rows in % ms', v_count, EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 4: SELECT * LIMIT 50 (default sort)
    start_time := clock_timestamp();
    PERFORM * FROM unified_items ORDER BY sort_date DESC LIMIT 50;
    end_time := clock_timestamp();
    RAISE NOTICE '4. SELECT * LIMIT 50 (sorted): % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 5: SELECT minimal columns LIMIT 50
    start_time := clock_timestamp();
    PERFORM id, type, name, project, sort_date FROM unified_items ORDER BY sort_date DESC LIMIT 50;
    end_time := clock_timestamp();
    RAISE NOTICE '5. SELECT minimal cols LIMIT 50: % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 6: Tasks only with sort
    start_time := clock_timestamp();
    PERFORM * FROM unified_items WHERE type = 'task' ORDER BY sort_date DESC LIMIT 50;
    end_time := clock_timestamp();
    RAISE NOTICE '6. Tasks only LIMIT 50: % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 7: Emails only with sort
    start_time := clock_timestamp();
    PERFORM * FROM unified_items WHERE type = 'email' ORDER BY sort_date DESC LIMIT 50;
    end_time := clock_timestamp();
    RAISE NOTICE '7. Emails only LIMIT 50: % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 8: Search in name
    start_time := clock_timestamp();
    PERFORM * FROM unified_items WHERE name ILIKE '%test%' ORDER BY sort_date DESC LIMIT 50;
    end_time := clock_timestamp();
    RAISE NOTICE '8. Search name ILIKE: % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 9: Search in description
    start_time := clock_timestamp();
    PERFORM * FROM unified_items WHERE description ILIKE '%test%' ORDER BY sort_date DESC LIMIT 50;
    end_time := clock_timestamp();
    RAISE NOTICE '9. Search description ILIKE: % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 10: Search in conversation comments
    start_time := clock_timestamp();
    PERFORM * FROM unified_items WHERE conversation_comments_text ILIKE '%test%' ORDER BY sort_date DESC LIMIT 50;
    end_time := clock_timestamp();
    RAISE NOTICE '10. Search comments ILIKE: % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 11: Combined search (OR)
    start_time := clock_timestamp();
    PERFORM * FROM unified_items 
    WHERE name ILIKE '%test%' 
       OR description ILIKE '%test%' 
       OR conversation_comments_text ILIKE '%test%'
    ORDER BY sort_date DESC LIMIT 50;
    end_time := clock_timestamp();
    RAISE NOTICE '11. Combined search (OR): % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 12: Filter by project
    start_time := clock_timestamp();
    PERFORM * FROM unified_items WHERE project IS NOT NULL ORDER BY sort_date DESC LIMIT 50;
    end_time := clock_timestamp();
    RAISE NOTICE '12. Filter by project: % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 13: Deep pagination (page 100)
    start_time := clock_timestamp();
    PERFORM * FROM unified_items ORDER BY sort_date DESC LIMIT 50 OFFSET 5000;
    end_time := clock_timestamp();
    RAISE NOTICE '13. Deep pagination (offset 5000): % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 14: Select with all JSON columns
    start_time := clock_timestamp();
    PERFORM id, type, name, assignees, tags, recipients, attachments FROM unified_items ORDER BY sort_date DESC LIMIT 50;
    end_time := clock_timestamp();
    RAISE NOTICE '14. Select with JSON cols: % ms', EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    -- Test 15: Count with complex filter
    start_time := clock_timestamp();
    SELECT COUNT(*) INTO v_count FROM unified_items 
    WHERE type = 'task' 
      AND project IS NOT NULL 
      AND task_type_id IS NOT NULL;
    end_time := clock_timestamp();
    RAISE NOTICE '15. COUNT with complex filter: % rows in % ms', v_count, EXTRACT(MILLISECONDS FROM end_time - start_time)::INT;
    
    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'BENCHMARK COMPLETE';
    RAISE NOTICE '========================================';
END $$;

-- Also show materialized view status
SELECT 
    '>>> MV Status' AS info,
    view_name,
    CASE WHEN needs_refresh THEN 'STALE' ELSE 'FRESH' END AS status,
    EXTRACT(EPOCH FROM (NOW() - last_refreshed_at))::INT || 's ago' AS last_refresh
FROM mv_refresh_status
ORDER BY view_name;

