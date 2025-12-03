-- =====================================
-- SYNC STATUS FUNCTIONS FOR DASHBOARD
-- =====================================
-- RPC functions to expose teamworkmissiveconnector status to the dashboard

-- =====================================
-- 1. GET SYNC CHECKPOINTS
-- =====================================
-- Returns the last scanned timestamps for teamwork and missive

CREATE OR REPLACE FUNCTION get_sync_checkpoints()
RETURNS TABLE (
    source VARCHAR(50),
    last_event_time TIMESTAMP,
    updated_at TIMESTAMP
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        c.source,
        c.last_event_time,
        c.updated_at
    FROM teamworkmissiveconnector.checkpoints c;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION get_sync_checkpoints() IS 'Returns sync checkpoint timestamps for dashboard display';

-- =====================================
-- 2. GET QUEUE HEALTH
-- =====================================
-- Returns pending/processing counts for teamwork and missive queues

CREATE OR REPLACE FUNCTION get_queue_health()
RETURNS TABLE (
    source VARCHAR(50),
    pending_count BIGINT,
    processing_count BIGINT,
    failed_count BIGINT,
    dead_letter_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        q.source,
        COUNT(*) FILTER (WHERE q.status = 'pending') AS pending_count,
        COUNT(*) FILTER (WHERE q.status = 'processing') AS processing_count,
        COUNT(*) FILTER (WHERE q.status = 'failed') AS failed_count,
        COUNT(*) FILTER (WHERE q.status = 'dead_letter') AS dead_letter_count
    FROM teamworkmissiveconnector.queue_items q
    GROUP BY q.source;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION get_queue_health() IS 'Returns queue health metrics for dashboard display';

-- =====================================
-- 3. GET COMBINED SYNC STATUS
-- =====================================
-- Returns combined sync status (checkpoints + queue health) in one call

CREATE OR REPLACE FUNCTION get_sync_status()
RETURNS TABLE (
    source VARCHAR(50),
    last_event_time TIMESTAMP,
    checkpoint_updated_at TIMESTAMP,
    pending_count BIGINT,
    processing_count BIGINT,
    failed_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COALESCE(c.source, q.source) AS source,
        c.last_event_time,
        c.updated_at AS checkpoint_updated_at,
        COALESCE(q.pending_count, 0) AS pending_count,
        COALESCE(q.processing_count, 0) AS processing_count,
        COALESCE(q.failed_count, 0) AS failed_count
    FROM (
        SELECT 
            qi.source,
            COUNT(*) FILTER (WHERE qi.status = 'pending') AS pending_count,
            COUNT(*) FILTER (WHERE qi.status = 'processing') AS processing_count,
            COUNT(*) FILTER (WHERE qi.status = 'failed') AS failed_count
        FROM teamworkmissiveconnector.queue_items qi
        GROUP BY qi.source
    ) q
    FULL OUTER JOIN teamworkmissiveconnector.checkpoints c ON c.source = q.source;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION get_sync_status() IS 'Returns combined sync status for dashboard display';

