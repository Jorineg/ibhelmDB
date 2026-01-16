-- =====================================
-- EXTENSIONS, TYPES AND ENUMS
-- =====================================

-- Extensions
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS unaccent SCHEMA extensions;
SET search_path TO public, extensions;

-- =====================================
-- CUSTOM TYPES
-- =====================================

CREATE TYPE location_type AS ENUM ('building', 'level', 'room');
COMMENT ON TYPE location_type IS 'Hierarchical location types: building > level > room';

CREATE TYPE s3_status AS ENUM ('pending', 'uploading', 'uploaded', 'error', 'skipped');
COMMENT ON TYPE s3_status IS 'S3 upload status: pending→uploading→uploaded, or error (retryable), or skipped (permanent)';

CREATE TYPE processing_status AS ENUM ('pending', 'indexing', 'done', 'skipped', 'error');
COMMENT ON TYPE processing_status IS 'OCR/thumbnail status: pending→indexing→done, or skipped (intentionally not processed), or error (failed after retries)';

-- =====================================
-- TASK TYPES (Configurable via UI)
-- =====================================

CREATE TABLE task_types (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    description TEXT,
    color VARCHAR(50),
    icon VARCHAR(100),
    is_default BOOLEAN DEFAULT FALSE,
    display_order INTEGER DEFAULT 0,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE task_type_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_type_id UUID NOT NULL REFERENCES task_types(id) ON DELETE CASCADE,
    teamwork_tag_name TEXT NOT NULL,
    db_created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(teamwork_tag_name)
);

-- =====================================
-- OPERATION RUN TRACKING
-- =====================================

CREATE TABLE operation_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_type VARCHAR(50) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'running',
    total_count INTEGER,
    processed_count INTEGER DEFAULT 0,
    created_count INTEGER DEFAULT 0,
    linked_count INTEGER DEFAULT 0,
    skipped_count INTEGER DEFAULT 0,
    error_message TEXT,
    started_at TIMESTAMP DEFAULT NOW(),
    completed_at TIMESTAMP
);

-- =====================================
-- APP SETTINGS (Single-row JSONB config)
-- =====================================

CREATE TABLE app_settings (
    lock CHAR(1) PRIMARY KEY DEFAULT 'X',
    CONSTRAINT single_row CHECK (lock = 'X'),
    body JSONB NOT NULL DEFAULT '{}'::jsonb
);

INSERT INTO app_settings (body) VALUES ('{"email_color": "#3b82f6", "craft_color": "#8b5cf6", "file_color": "#ef4444", "person_color": "#10b981", "project_color": "#f59e0b", "cost_group_prefixes": ["KGR"], "location_prefix": "O-"}'::jsonb);

-- =====================================
-- USER SETTINGS (Per-user preferences, synced to DB)
-- =====================================

CREATE TABLE user_settings (
    user_id UUID PRIMARY KEY,  -- No FK to auth.users (separate schema in self-hosted)
    settings JSONB NOT NULL DEFAULT '{}'::jsonb,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

-- =====================================
-- INDEXES
-- =====================================

CREATE INDEX idx_task_types_slug ON task_types(slug);
CREATE INDEX idx_task_types_is_default ON task_types(is_default);
CREATE INDEX idx_task_types_display_order ON task_types(display_order);
CREATE INDEX idx_task_type_rules_task_type_id ON task_type_rules(task_type_id);
CREATE INDEX idx_task_type_rules_tag_name ON task_type_rules(teamwork_tag_name);
CREATE INDEX idx_operation_runs_run_type ON operation_runs(run_type);
CREATE INDEX idx_operation_runs_status ON operation_runs(status);
CREATE INDEX idx_operation_runs_started_at ON operation_runs(started_at);
CREATE INDEX idx_operation_runs_run_type_started ON operation_runs(run_type, started_at DESC);

-- =====================================
-- SEED DATA
-- =====================================

INSERT INTO task_types (name, slug, description, is_default, display_order) VALUES
    ('Todo', 'todo', 'Standard actionable task', FALSE, 1),
    ('Info', 'info', 'Informational item', FALSE, 2),
    ('Other', 'other', 'Default category for unmatched tasks', TRUE, 999);

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON TABLE task_types IS 'Configurable task type categories for ibhelm semantics';
COMMENT ON COLUMN task_types.is_default IS 'If true, this type catches all tasks not matching any rule';
COMMENT ON COLUMN task_types.slug IS 'URL-safe identifier, used for filtering';
COMMENT ON TABLE task_type_rules IS 'Maps Teamwork tag names to task types (match any rule)';
COMMENT ON TABLE operation_runs IS 'Tracks status of bulk operations (task_type_extraction, person_linking, project_linking)';
COMMENT ON TABLE app_settings IS 'Admin settings (colors, prefixes, integration URLs). Schema in ibhelmDB/docs/app_settings_schema.md';
COMMENT ON TABLE user_settings IS 'Per-user settings (display prefs, filter configs, key bindings). JSON schema: { hide_completed_tasks, default_sort_field, default_sort_order, filter_configurations, key_bindings }';

