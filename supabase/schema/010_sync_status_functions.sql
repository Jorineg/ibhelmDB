-- =====================================
-- SYNC STATUS FUNCTIONS FOR DASHBOARD
-- =====================================
-- RPC functions to expose teamworkmissiveconnector status to the dashboard

-- =====================================
-- GET COMBINED SYNC STATUS
-- =====================================
-- Returns combined sync status (checkpoints + queue health) in one call

CREATE OR REPLACE FUNCTION get_sync_status()
RETURNS TABLE (
    source VARCHAR(50),
    last_event_time TIMESTAMPTZ,
    checkpoint_updated_at TIMESTAMPTZ,
    pending_count BIGINT,
    processing_count BIGINT,
    failed_count BIGINT,
    last_processed_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COALESCE(c.source, q.source) AS source,
        c.last_event_time,
        c.updated_at AS checkpoint_updated_at,
        COALESCE(q.pending_count, 0) AS pending_count,
        COALESCE(q.processing_count, 0) AS processing_count,
        COALESCE(q.failed_count, 0) AS failed_count,
        q.last_processed_at
    FROM (
        SELECT 
            qi.source,
            COUNT(*) FILTER (WHERE qi.status = 'pending') AS pending_count,
            COUNT(*) FILTER (WHERE qi.status = 'processing') AS processing_count,
            COUNT(*) FILTER (WHERE qi.status = 'failed') AS failed_count,
            MAX(qi.processed_at) FILTER (WHERE qi.status = 'completed') AS last_processed_at
        FROM teamworkmissiveconnector.queue_items qi
        GROUP BY qi.source
    ) q
    FULL OUTER JOIN teamworkmissiveconnector.checkpoints c ON c.source = q.source;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION get_sync_status() IS 'Returns combined sync status for dashboard display';

