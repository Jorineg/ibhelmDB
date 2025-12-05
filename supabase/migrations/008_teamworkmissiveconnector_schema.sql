-- =====================================
-- TEAMWORK MISSIVE CONNECTOR SCHEMA (FIXED)
-- =====================================
-- Application state and queue management for the TeamworkMissiveConnector
-- 
-- LOCATION IN ibhelmDB REPO:
-- supabase/migrations/009_teamworkmissiveconnector_schema.sql
--
-- This migration creates a dedicated schema for connector application state,
-- separating it from business data (public/teamwork/missive schemas).
--
-- IMPORTANT FIX: Removed triggers that were causing "db_updated_at" errors
-- The teamworkmissiveconnector tables use "updated_at" not "db_updated_at"
-- =====================================

CREATE SCHEMA IF NOT EXISTS teamworkmissiveconnector;

-- =====================================
-- 1. CHECKPOINTS TABLE
-- =====================================
-- Tracks sync checkpoints for incremental data synchronization
-- Used by backfill operations to resume from last known state

CREATE TABLE teamworkmissiveconnector.checkpoints (
    source VARCHAR(50) PRIMARY KEY,
    last_event_time TIMESTAMP NOT NULL,
    last_cursor TEXT,
    updated_at TIMESTAMP DEFAULT NOW(),
    
    CONSTRAINT checkpoints_valid_source CHECK (source IN ('teamwork', 'missive', 'craft'))
);

CREATE INDEX idx_checkpoints_source ON teamworkmissiveconnector.checkpoints(source);
CREATE INDEX idx_checkpoints_updated_at ON teamworkmissiveconnector.checkpoints(updated_at);

COMMENT ON TABLE teamworkmissiveconnector.checkpoints IS 'Sync checkpoints for incremental data synchronization from external systems';
COMMENT ON COLUMN teamworkmissiveconnector.checkpoints.source IS 'Source system: teamwork or missive';
COMMENT ON COLUMN teamworkmissiveconnector.checkpoints.last_event_time IS 'Timestamp of last processed event';
COMMENT ON COLUMN teamworkmissiveconnector.checkpoints.last_cursor IS 'Optional pagination cursor for API calls';

-- =====================================
-- 2. QUEUE ITEMS TABLE
-- =====================================
-- Event queue for async processing of webhooks and backfill events
-- Replaces file-based spool queue with ACID-compliant database queue

CREATE TABLE teamworkmissiveconnector.queue_items (
    id SERIAL PRIMARY KEY,
    
    -- Event identification
    source VARCHAR(50) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    external_id VARCHAR(255) NOT NULL,
    payload JSONB,
    
    -- Processing state
    status VARCHAR(50) DEFAULT 'pending' NOT NULL,
    retry_count INTEGER DEFAULT 0 NOT NULL,
    max_retries INTEGER DEFAULT 3 NOT NULL,
    error_message TEXT,
    
    -- Timestamps
    created_at TIMESTAMP DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMP DEFAULT NOW() NOT NULL,
    processing_started_at TIMESTAMP,
    processed_at TIMESTAMP,
    next_retry_at TIMESTAMP,
    
    -- Processing metadata
    worker_id VARCHAR(100),
    processing_time_ms INTEGER,
    
    CONSTRAINT queue_items_valid_source CHECK (source IN ('teamwork', 'missive', 'craft')),
    CONSTRAINT queue_items_valid_status CHECK (
        status IN ('pending', 'processing', 'completed', 'failed', 'dead_letter')
    ),
    CONSTRAINT queue_items_retry_count_positive CHECK (retry_count >= 0),
    CONSTRAINT queue_items_max_retries_positive CHECK (max_retries >= 0)
);

-- Performance indexes
CREATE INDEX idx_queue_items_status_created ON teamworkmissiveconnector.queue_items(status, created_at) 
    WHERE status IN ('pending', 'processing');
CREATE INDEX idx_queue_items_source ON teamworkmissiveconnector.queue_items(source);
CREATE INDEX idx_queue_items_external_id ON teamworkmissiveconnector.queue_items(external_id);
CREATE INDEX idx_queue_items_next_retry ON teamworkmissiveconnector.queue_items(next_retry_at) 
    WHERE status = 'pending' AND next_retry_at IS NOT NULL;
CREATE INDEX idx_queue_items_created_at ON teamworkmissiveconnector.queue_items(created_at);

COMMENT ON TABLE teamworkmissiveconnector.queue_items IS 'Event queue for async processing of webhooks and backfill operations';
COMMENT ON COLUMN teamworkmissiveconnector.queue_items.source IS 'Source system: teamwork or missive';
COMMENT ON COLUMN teamworkmissiveconnector.queue_items.event_type IS 'Event type (e.g., task.created, conversation.updated)';
COMMENT ON COLUMN teamworkmissiveconnector.queue_items.external_id IS 'External ID from source system';
COMMENT ON COLUMN teamworkmissiveconnector.queue_items.status IS 'Processing status: pending, processing, completed, failed, dead_letter';
COMMENT ON COLUMN teamworkmissiveconnector.queue_items.retry_count IS 'Number of retry attempts';
COMMENT ON COLUMN teamworkmissiveconnector.queue_items.next_retry_at IS 'Scheduled time for next retry (exponential backoff)';
COMMENT ON COLUMN teamworkmissiveconnector.queue_items.worker_id IS 'Identifier of worker processing this item';

-- =====================================
-- 3. WEBHOOK CONFIG TABLE
-- =====================================
-- Stores webhook IDs and configuration for external systems
-- Replaces JSON files: missive_webhook_id.json, teamwork_webhook_ids.json

CREATE TABLE teamworkmissiveconnector.webhook_config (
    source VARCHAR(50) PRIMARY KEY,
    webhook_ids JSONB NOT NULL,
    webhook_url TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMP DEFAULT NOW() NOT NULL,
    last_verified_at TIMESTAMP,
    
    CONSTRAINT webhook_config_valid_source CHECK (source IN ('teamwork', 'missive', 'craft'))
);

CREATE INDEX idx_webhook_config_source ON teamworkmissiveconnector.webhook_config(source);
CREATE INDEX idx_webhook_config_active ON teamworkmissiveconnector.webhook_config(is_active);

COMMENT ON TABLE teamworkmissiveconnector.webhook_config IS 'Webhook configuration and IDs for external systems';
COMMENT ON COLUMN teamworkmissiveconnector.webhook_config.source IS 'Source system: teamwork or missive';
COMMENT ON COLUMN teamworkmissiveconnector.webhook_config.webhook_ids IS 'JSON array/object of webhook IDs from the external system';
COMMENT ON COLUMN teamworkmissiveconnector.webhook_config.webhook_url IS 'Current webhook URL (for reference)';
COMMENT ON COLUMN teamworkmissiveconnector.webhook_config.is_active IS 'Whether webhooks are currently active';

-- =====================================
-- 4. PROCESSING STATS TABLE (OPTIONAL)
-- =====================================
-- Tracks processing statistics and health metrics
-- Useful for monitoring and debugging

CREATE TABLE teamworkmissiveconnector.processing_stats (
    id SERIAL PRIMARY KEY,
    source VARCHAR(50) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    
    -- Aggregate statistics (per hour)
    stat_hour TIMESTAMP NOT NULL,
    
    events_received INTEGER DEFAULT 0,
    events_processed INTEGER DEFAULT 0,
    events_failed INTEGER DEFAULT 0,
    
    avg_processing_time_ms INTEGER,
    max_processing_time_ms INTEGER,
    min_processing_time_ms INTEGER,
    
    created_at TIMESTAMP DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMP DEFAULT NOW() NOT NULL,
    
    CONSTRAINT processing_stats_unique_hour UNIQUE (source, event_type, stat_hour),
    CONSTRAINT processing_stats_valid_source CHECK (source IN ('teamwork', 'missive', 'craft'))
);

CREATE INDEX idx_processing_stats_source_hour ON teamworkmissiveconnector.processing_stats(source, stat_hour DESC);
CREATE INDEX idx_processing_stats_stat_hour ON teamworkmissiveconnector.processing_stats(stat_hour DESC);

COMMENT ON TABLE teamworkmissiveconnector.processing_stats IS 'Hourly processing statistics for monitoring and debugging';
COMMENT ON COLUMN teamworkmissiveconnector.processing_stats.stat_hour IS 'Hour bucket for aggregated statistics';

-- =====================================
-- 5. TRIGGERS FOR AUTO-UPDATE
-- =====================================
-- NOTE: The teamworkmissiveconnector tables use 'updated_at' column,
-- but the generic update_updated_at_column() function expects 'db_updated_at'.
-- Since all functions in this schema explicitly set updated_at = NOW(),
-- no triggers are needed here.

-- =====================================
-- 6. QUEUE MANAGEMENT FUNCTIONS
-- =====================================

-- Function: Dequeue items for processing (with locking)
CREATE OR REPLACE FUNCTION teamworkmissiveconnector.dequeue_items(
    p_worker_id VARCHAR(100),
    p_max_items INTEGER DEFAULT 10,
    p_source VARCHAR(50) DEFAULT NULL
)
RETURNS TABLE (
    id INTEGER,
    source VARCHAR(50),
    event_type VARCHAR(100),
    external_id VARCHAR(255),
    payload JSONB,
    retry_count INTEGER
) AS $$
BEGIN
    RETURN QUERY
    UPDATE teamworkmissiveconnector.queue_items q
    SET 
        status = 'processing',
        processing_started_at = NOW(),
        worker_id = p_worker_id,
        updated_at = NOW()
    WHERE q.id IN (
        SELECT qi.id
        FROM teamworkmissiveconnector.queue_items qi
        WHERE qi.status = 'pending'
            AND (p_source IS NULL OR qi.source = p_source)
            AND (qi.next_retry_at IS NULL OR qi.next_retry_at <= NOW())
        ORDER BY qi.created_at ASC
        LIMIT p_max_items
        FOR UPDATE SKIP LOCKED
    )
    RETURNING 
        q.id,
        q.source,
        q.event_type,
        q.external_id,
        q.payload,
        q.retry_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION teamworkmissiveconnector.dequeue_items IS 'Atomically dequeue items for processing with row-level locking';

-- Function: Mark item as completed
CREATE OR REPLACE FUNCTION teamworkmissiveconnector.mark_completed(
    p_item_id INTEGER,
    p_processing_time_ms INTEGER DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    UPDATE teamworkmissiveconnector.queue_items
    SET 
        status = 'completed',
        processed_at = NOW(),
        processing_time_ms = p_processing_time_ms,
        updated_at = NOW()
    WHERE id = p_item_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION teamworkmissiveconnector.mark_completed IS 'Mark a queue item as successfully completed';

-- Function: Mark item as failed (with retry logic)
CREATE OR REPLACE FUNCTION teamworkmissiveconnector.mark_failed(
    p_item_id INTEGER,
    p_error_message TEXT,
    p_retry BOOLEAN DEFAULT TRUE
)
RETURNS VOID AS $$
DECLARE
    v_retry_count INTEGER;
    v_max_retries INTEGER;
    v_next_retry_delay INTERVAL;
BEGIN
    -- Get current retry count and max retries
    SELECT retry_count, max_retries 
    INTO v_retry_count, v_max_retries
    FROM teamworkmissiveconnector.queue_items
    WHERE id = p_item_id;
    
    -- Exponential backoff: 1min, 5min, 15min, 30min, 1hr
    v_next_retry_delay := CASE v_retry_count
        WHEN 0 THEN INTERVAL '1 minute'
        WHEN 1 THEN INTERVAL '5 minutes'
        WHEN 2 THEN INTERVAL '15 minutes'
        WHEN 3 THEN INTERVAL '30 minutes'
        ELSE INTERVAL '1 hour'
    END;
    
    -- Update item
    IF p_retry AND v_retry_count < v_max_retries THEN
        -- Retry with backoff
        UPDATE teamworkmissiveconnector.queue_items
        SET 
            status = 'pending',
            retry_count = retry_count + 1,
            error_message = p_error_message,
            next_retry_at = NOW() + v_next_retry_delay,
            processing_started_at = NULL,
            worker_id = NULL,
            updated_at = NOW()
        WHERE id = p_item_id;
    ELSE
        -- Move to dead letter (max retries exceeded or no retry)
        UPDATE teamworkmissiveconnector.queue_items
        SET 
            status = 'dead_letter',
            error_message = p_error_message,
            processed_at = NOW(),
            updated_at = NOW()
        WHERE id = p_item_id;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION teamworkmissiveconnector.mark_failed IS 'Mark a queue item as failed with exponential backoff retry logic';

-- Function: Cleanup old completed items
CREATE OR REPLACE FUNCTION teamworkmissiveconnector.cleanup_old_items(
    p_retention_days INTEGER DEFAULT 7
)
RETURNS INTEGER AS $$
DECLARE
    v_deleted_count INTEGER;
BEGIN
    DELETE FROM teamworkmissiveconnector.queue_items
    WHERE status = 'completed'
        AND processed_at < NOW() - (p_retention_days || ' days')::INTERVAL;
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RETURN v_deleted_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION teamworkmissiveconnector.cleanup_old_items IS 'Delete completed queue items older than retention period';

-- Function: Reset stuck items (processing for too long)
CREATE OR REPLACE FUNCTION teamworkmissiveconnector.reset_stuck_items(
    p_stuck_threshold_minutes INTEGER DEFAULT 30
)
RETURNS INTEGER AS $$
DECLARE
    v_reset_count INTEGER;
BEGIN
    UPDATE teamworkmissiveconnector.queue_items
    SET 
        status = 'pending',
        processing_started_at = NULL,
        worker_id = NULL,
        updated_at = NOW()
    WHERE status = 'processing'
        AND processing_started_at < NOW() - (p_stuck_threshold_minutes || ' minutes')::INTERVAL;
    
    GET DIAGNOSTICS v_reset_count = ROW_COUNT;
    RETURN v_reset_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION teamworkmissiveconnector.reset_stuck_items IS 'Reset items stuck in processing state for too long';

-- =====================================
-- 7. MONITORING VIEWS
-- =====================================

-- Queue health view
CREATE OR REPLACE VIEW teamworkmissiveconnector.queue_health AS
SELECT 
    source,
    COUNT(*) FILTER (WHERE status = 'pending') AS pending_count,
    COUNT(*) FILTER (WHERE status = 'processing') AS processing_count,
    COUNT(*) FILTER (WHERE status = 'failed') AS failed_count,
    COUNT(*) FILTER (WHERE status = 'dead_letter') AS dead_letter_count,
    AVG(processing_time_ms) FILTER (WHERE status = 'completed' AND processing_time_ms IS NOT NULL) AS avg_processing_time_ms,
    MAX(created_at) FILTER (WHERE status = 'pending') AS oldest_pending_item,
    COUNT(*) FILTER (WHERE status = 'processing' AND processing_started_at < NOW() - INTERVAL '30 minutes') AS stuck_items
FROM teamworkmissiveconnector.queue_items
GROUP BY source;

COMMENT ON VIEW teamworkmissiveconnector.queue_health IS 'Real-time queue health metrics by source';

-- Recent errors view
CREATE OR REPLACE VIEW teamworkmissiveconnector.recent_errors AS
SELECT 
    id,
    source,
    event_type,
    external_id,
    error_message,
    retry_count,
    created_at,
    updated_at
FROM teamworkmissiveconnector.queue_items
WHERE status IN ('failed', 'dead_letter')
    AND updated_at > NOW() - INTERVAL '24 hours'
ORDER BY updated_at DESC
LIMIT 100;

COMMENT ON VIEW teamworkmissiveconnector.recent_errors IS 'Recent failed queue items for debugging';

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON SCHEMA teamworkmissiveconnector IS 'Application state and queue management for TeamworkMissiveConnector';

