-- =====================================
-- CUSTOM TYPES AND ENUMS
-- =====================================

-- Location type for hierarchical locations
CREATE TYPE location_type AS ENUM ('building', 'level', 'room');

COMMENT ON TYPE location_type IS 'Hierarchical location types: building > level > room';

-- =====================================
-- TASK TYPES (Configurable via UI)
-- =====================================
-- Replaces the former task_extension_type enum with a flexible table approach

-- Task Types table (configurable task categories)
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

-- Task Type Rules (maps Teamwork tags to task types)
CREATE TABLE task_type_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_type_id UUID NOT NULL REFERENCES task_types(id) ON DELETE CASCADE,
    teamwork_tag_name TEXT NOT NULL,
    
    db_created_at TIMESTAMP DEFAULT NOW(),
    
    -- Each tag can only be mapped to one task type
    UNIQUE(teamwork_tag_name)
);

-- Extraction Run Tracking (for UI status of re-run operations)
CREATE TABLE extraction_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status VARCHAR(50) NOT NULL DEFAULT 'running',  -- 'running', 'completed', 'failed'
    total_count INTEGER,
    processed_count INTEGER DEFAULT 0,
    error_message TEXT,
    started_at TIMESTAMP DEFAULT NOW(),
    completed_at TIMESTAMP
);

-- Indexes for task types
CREATE INDEX idx_task_types_slug ON task_types(slug);
CREATE INDEX idx_task_types_is_default ON task_types(is_default);
CREATE INDEX idx_task_types_display_order ON task_types(display_order);

CREATE INDEX idx_task_type_rules_task_type_id ON task_type_rules(task_type_id);
CREATE INDEX idx_task_type_rules_tag_name ON task_type_rules(teamwork_tag_name);

CREATE INDEX idx_extraction_runs_status ON extraction_runs(status);
CREATE INDEX idx_extraction_runs_started_at ON extraction_runs(started_at);

-- Insert default task types
INSERT INTO task_types (name, slug, description, is_default, display_order) VALUES
    ('Todo', 'todo', 'Standard actionable task', FALSE, 1),
    ('Info', 'info', 'Informational item', FALSE, 2),
    ('Other', 'other', 'Default category for unmatched tasks', TRUE, 999);

COMMENT ON TABLE task_types IS 'Configurable task type categories for ibhelm semantics';
COMMENT ON COLUMN task_types.is_default IS 'If true, this type catches all tasks not matching any rule';
COMMENT ON COLUMN task_types.slug IS 'URL-safe identifier, used for filtering';

COMMENT ON TABLE task_type_rules IS 'Maps Teamwork tag names to task types (match any rule)';
COMMENT ON COLUMN task_type_rules.teamwork_tag_name IS 'Exact match against teamwork.tags.name';

COMMENT ON TABLE extraction_runs IS 'Tracks status of bulk extraction re-run operations';

-- =====================================
-- APPEARANCE SETTINGS (Configurable via UI)
-- =====================================
-- Stores appearance/styling configuration for the dashboard

-- Appearance Settings table (singleton - one row)
CREATE TABLE appearance_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Email display colors (used for badges, link buttons, color bars)
    email_color VARCHAR(50) DEFAULT '#3b82f6',
    
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

-- Insert default appearance settings (singleton row)
INSERT INTO appearance_settings (email_color) VALUES ('#3b82f6');

COMMENT ON TABLE appearance_settings IS 'Singleton table for dashboard appearance configuration';
COMMENT ON COLUMN appearance_settings.email_color IS 'Color for email items (badges, link buttons, color bars in table header)';