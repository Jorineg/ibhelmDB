-- =====================================
-- TEAMWORK MISSIVE CONNECTOR SCHEMA
-- =====================================

CREATE SCHEMA IF NOT EXISTS teamworkmissiveconnector;

-- =====================================
-- 1. CHECKPOINTS TABLE
-- =====================================

CREATE TABLE teamworkmissiveconnector.checkpoints (
    source VARCHAR(50) PRIMARY KEY,
    last_event_time TIMESTAMPTZ NOT NULL,
    last_cursor TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT checkpoints_valid_source CHECK (source IN ('teamwork', 'missive', 'craft', 'files'))
);

CREATE INDEX idx_checkpoints_source ON teamworkmissiveconnector.checkpoints(source);
CREATE INDEX idx_checkpoints_updated_at ON teamworkmissiveconnector.checkpoints(updated_at);

-- =====================================
-- 2. QUEUE ITEMS TABLE
-- =====================================

CREATE TABLE teamworkmissiveconnector.queue_items (
    id SERIAL PRIMARY KEY,
    source VARCHAR(50) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    external_id VARCHAR(255) NOT NULL,
    payload JSONB,
    status VARCHAR(50) DEFAULT 'pending' NOT NULL,
    retry_count INTEGER DEFAULT 0 NOT NULL,
    max_retries INTEGER DEFAULT 3 NOT NULL,
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    processing_started_at TIMESTAMPTZ,
    processed_at TIMESTAMPTZ,
    next_retry_at TIMESTAMPTZ,
    worker_id VARCHAR(100),
    processing_time_ms INTEGER,
    CONSTRAINT queue_items_valid_source CHECK (source IN ('teamwork', 'missive', 'craft')),
    CONSTRAINT queue_items_valid_status CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'dead_letter')),
    CONSTRAINT queue_items_retry_count_positive CHECK (retry_count >= 0),
    CONSTRAINT queue_items_max_retries_positive CHECK (max_retries >= 0)
);

CREATE INDEX idx_queue_items_status_created ON teamworkmissiveconnector.queue_items(status, created_at) WHERE status IN ('pending', 'processing');
CREATE INDEX idx_queue_items_source ON teamworkmissiveconnector.queue_items(source);
CREATE INDEX idx_queue_items_external_id ON teamworkmissiveconnector.queue_items(external_id);
CREATE INDEX idx_queue_items_next_retry ON teamworkmissiveconnector.queue_items(next_retry_at) WHERE status = 'pending' AND next_retry_at IS NOT NULL;
CREATE INDEX idx_queue_items_created_at ON teamworkmissiveconnector.queue_items(created_at);

-- =====================================
-- 3. WEBHOOK CONFIG TABLE
-- =====================================

CREATE TABLE teamworkmissiveconnector.webhook_config (
    source VARCHAR(50) PRIMARY KEY,
    webhook_ids JSONB NOT NULL,
    webhook_url TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    last_verified_at TIMESTAMPTZ,
    CONSTRAINT webhook_config_valid_source CHECK (source IN ('teamwork', 'missive', 'craft'))
);

CREATE INDEX idx_webhook_config_source ON teamworkmissiveconnector.webhook_config(source);
CREATE INDEX idx_webhook_config_active ON teamworkmissiveconnector.webhook_config(is_active);

-- =====================================
-- 4. PROCESSING STATS TABLE
-- =====================================

CREATE TABLE teamworkmissiveconnector.processing_stats (
    id SERIAL PRIMARY KEY,
    source VARCHAR(50) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    stat_hour TIMESTAMPTZ NOT NULL,
    events_received INTEGER DEFAULT 0,
    events_processed INTEGER DEFAULT 0,
    events_failed INTEGER DEFAULT 0,
    avg_processing_time_ms INTEGER,
    max_processing_time_ms INTEGER,
    min_processing_time_ms INTEGER,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    CONSTRAINT processing_stats_unique_hour UNIQUE (source, event_type, stat_hour),
    CONSTRAINT processing_stats_valid_source CHECK (source IN ('teamwork', 'missive', 'craft'))
);

CREATE INDEX idx_processing_stats_source_hour ON teamworkmissiveconnector.processing_stats(source, stat_hour DESC);
CREATE INDEX idx_processing_stats_stat_hour ON teamworkmissiveconnector.processing_stats(stat_hour DESC);

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON SCHEMA teamworkmissiveconnector IS 'Application state and queue management for TeamworkMissiveConnector';
COMMENT ON TABLE teamworkmissiveconnector.checkpoints IS 'Sync checkpoints for incremental data synchronization from external systems';
COMMENT ON TABLE teamworkmissiveconnector.queue_items IS 'Event queue for async processing of webhooks and backfill operations';
COMMENT ON TABLE teamworkmissiveconnector.webhook_config IS 'Webhook configuration and IDs for external systems';
COMMENT ON TABLE teamworkmissiveconnector.processing_stats IS 'Hourly processing statistics for monitoring and debugging';

