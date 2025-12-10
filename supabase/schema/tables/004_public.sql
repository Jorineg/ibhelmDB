-- =====================================
-- IBHELM SCHEMA (PUBLIC)
-- =====================================

-- =====================================
-- 1. UNIFIED PERSONS
-- =====================================

CREATE TABLE unified_persons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name TEXT NOT NULL,
    primary_email TEXT,
    preferred_contact_method VARCHAR(50),
    is_internal BOOLEAN DEFAULT FALSE,
    is_company BOOLEAN DEFAULT FALSE,
    notes TEXT,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE unified_person_links (
    id SERIAL PRIMARY KEY,
    unified_person_id UUID NOT NULL REFERENCES unified_persons(id) ON DELETE CASCADE,
    tw_user_id INTEGER REFERENCES teamwork.users(id) ON DELETE CASCADE,
    tw_company_id INTEGER REFERENCES teamwork.companies(id) ON DELETE CASCADE,
    m_contact_id INTEGER REFERENCES missive.contacts(id) ON DELETE CASCADE,
    link_type VARCHAR(50) DEFAULT 'auto_email',
    linked_by UUID,
    linked_at TIMESTAMP DEFAULT NOW(),
    CONSTRAINT unified_person_links_one_source CHECK (
        (tw_user_id IS NOT NULL)::int + 
        (tw_company_id IS NOT NULL)::int + 
        (m_contact_id IS NOT NULL)::int = 1
    )
);

CREATE UNIQUE INDEX idx_unified_person_links_tw_user_id ON unified_person_links(tw_user_id) WHERE tw_user_id IS NOT NULL;
CREATE UNIQUE INDEX idx_unified_person_links_tw_company_id ON unified_person_links(tw_company_id) WHERE tw_company_id IS NOT NULL;
CREATE UNIQUE INDEX idx_unified_person_links_m_contact_id ON unified_person_links(m_contact_id) WHERE m_contact_id IS NOT NULL;

-- =====================================
-- 2. HIERARCHIES
-- =====================================

CREATE TABLE locations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id UUID REFERENCES locations(id) ON DELETE CASCADE,
    name TEXT,
    type location_type,
    teamwork_tag_pattern VARCHAR(255),
    path TEXT,
    path_ids UUID[],
    depth INTEGER,
    search_text TEXT,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE cost_groups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id UUID REFERENCES cost_groups(id) ON DELETE CASCADE,
    code INTEGER NOT NULL UNIQUE,
    name TEXT,
    path TEXT,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW(),
    CONSTRAINT cost_groups_code_3_digits CHECK (code >= 100 AND code <= 999)
);

-- =====================================
-- 3. PROJECT EXTENSIONS
-- =====================================

CREATE TABLE project_extensions (
    tw_project_id INTEGER PRIMARY KEY REFERENCES teamwork.projects(id) ON DELETE CASCADE,
    default_location_id UUID REFERENCES locations(id) ON DELETE SET NULL,
    default_cost_group_id UUID REFERENCES cost_groups(id) ON DELETE SET NULL,
    nas_folder_path TEXT,
    client_person_id UUID REFERENCES unified_persons(id) ON DELETE SET NULL,
    internal_notes TEXT,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE project_contractors (
    id SERIAL PRIMARY KEY,
    tw_project_id INTEGER REFERENCES teamwork.projects(id) ON DELETE CASCADE,
    contractor_person_id UUID REFERENCES unified_persons(id) ON DELETE CASCADE,
    role VARCHAR(100),
    db_created_at TIMESTAMP DEFAULT NOW()
);

-- =====================================
-- 4. TASK EXTENSIONS
-- =====================================

CREATE TABLE task_extensions (
    tw_task_id INTEGER PRIMARY KEY REFERENCES teamwork.tasks(id) ON DELETE CASCADE,
    task_type_id UUID REFERENCES task_types(id) ON DELETE SET NULL,
    type_source VARCHAR(50) DEFAULT 'auto',
    type_source_tag_name VARCHAR(255),
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

-- =====================================
-- 5. FILES & CONTENT
-- =====================================

CREATE TABLE craft_documents (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    markdown_content TEXT,
    is_deleted BOOLEAN DEFAULT FALSE,
    craft_created_at TIMESTAMP WITH TIME ZONE,
    craft_last_modified_at TIMESTAMP WITH TIME ZONE,
    db_created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    db_updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    raw_data JSONB
);

CREATE TABLE document_types (
    id SERIAL PRIMARY KEY,
    name TEXT,
    slug VARCHAR(100) UNIQUE,
    description TEXT,
    db_created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    storage_path TEXT UNIQUE NOT NULL,
    filename TEXT NOT NULL,
    folder_path TEXT,
    content_hash VARCHAR(64) NOT NULL,
    extracted_text TEXT,
    thumbnail_path TEXT,
    thumbnail_generated_at TIMESTAMP,
    document_type_id INTEGER REFERENCES document_types(id) ON DELETE SET NULL,
    source_missive_attachment_id UUID REFERENCES missive.attachments(id) ON DELETE SET NULL,
    file_created_at TIMESTAMP WITH TIME ZONE,
    file_modified_at TIMESTAMP WITH TIME ZONE,
    file_created_by TEXT,
    filesystem_inode BIGINT,
    filesystem_access_rights JSONB,
    filesystem_attributes JSONB,
    auto_extracted_metadata JSONB,
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

-- =====================================
-- 6. THE GLUE
-- =====================================

CREATE TABLE project_conversations (
    m_conversation_id UUID REFERENCES missive.conversations(id) ON DELETE CASCADE,
    tw_project_id INTEGER REFERENCES teamwork.projects(id) ON DELETE CASCADE,
    source VARCHAR(50) NOT NULL,
    source_label_name VARCHAR(255),
    assigned_at TIMESTAMP DEFAULT NOW(),
    PRIMARY KEY (tw_project_id, m_conversation_id)
);

CREATE TABLE project_files (
    file_id UUID REFERENCES files(id) ON DELETE CASCADE,
    tw_project_id INTEGER REFERENCES teamwork.projects(id) ON DELETE CASCADE,
    assigned_at TIMESTAMP DEFAULT NOW(),
    PRIMARY KEY (tw_project_id, file_id)
);

CREATE TABLE object_locations (
    id SERIAL PRIMARY KEY,
    location_id UUID REFERENCES locations(id) ON DELETE CASCADE,
    tw_task_id INTEGER REFERENCES teamwork.tasks(id) ON DELETE CASCADE,
    m_conversation_id UUID REFERENCES missive.conversations(id) ON DELETE CASCADE,
    file_id UUID REFERENCES files(id) ON DELETE CASCADE,
    source VARCHAR(50) NOT NULL,
    source_tag_name VARCHAR(255),
    db_created_at TIMESTAMP DEFAULT NOW(),
    CONSTRAINT object_locations_one_object CHECK (
        (file_id IS NOT NULL)::int + 
        (tw_task_id IS NOT NULL)::int + 
        (m_conversation_id IS NOT NULL)::int = 1
    )
);

CREATE TABLE object_cost_groups (
    id SERIAL PRIMARY KEY,
    cost_group_id UUID REFERENCES cost_groups(id) ON DELETE CASCADE,
    tw_task_id INTEGER REFERENCES teamwork.tasks(id) ON DELETE CASCADE,
    m_conversation_id UUID REFERENCES missive.conversations(id) ON DELETE CASCADE,
    file_id UUID REFERENCES files(id) ON DELETE CASCADE,
    source VARCHAR(50) NOT NULL,
    source_tag_name VARCHAR(255),
    db_created_at TIMESTAMP DEFAULT NOW(),
    CONSTRAINT object_cost_groups_one_object CHECK (
        (file_id IS NOT NULL)::int + 
        (tw_task_id IS NOT NULL)::int + 
        (m_conversation_id IS NOT NULL)::int = 1
    )
);

CREATE UNIQUE INDEX idx_object_cost_groups_unique_task ON object_cost_groups(cost_group_id, tw_task_id) WHERE tw_task_id IS NOT NULL;
CREATE UNIQUE INDEX idx_object_cost_groups_unique_conversation ON object_cost_groups(cost_group_id, m_conversation_id) WHERE m_conversation_id IS NOT NULL;
CREATE UNIQUE INDEX idx_object_cost_groups_unique_file ON object_cost_groups(cost_group_id, file_id) WHERE file_id IS NOT NULL;

CREATE UNIQUE INDEX idx_object_locations_unique_task ON object_locations(location_id, tw_task_id) WHERE tw_task_id IS NOT NULL;
CREATE UNIQUE INDEX idx_object_locations_unique_conversation ON object_locations(location_id, m_conversation_id) WHERE m_conversation_id IS NOT NULL;
CREATE UNIQUE INDEX idx_object_locations_unique_file ON object_locations(location_id, file_id) WHERE file_id IS NOT NULL;

-- =====================================
-- 7. INVOLVED PERSONS JUNCTION TABLE
-- =====================================

CREATE TABLE item_involved_persons (
    item_id TEXT NOT NULL,
    item_type TEXT NOT NULL,
    unified_person_id UUID NOT NULL REFERENCES unified_persons(id) ON DELETE CASCADE,
    involvement_type TEXT NOT NULL,
    PRIMARY KEY (item_id, item_type, unified_person_id, involvement_type)
);

-- =====================================
-- 8. MATERIALIZED VIEW REFRESH STATUS
-- =====================================

CREATE TABLE mv_refresh_status (
    view_name TEXT PRIMARY KEY,
    needs_refresh BOOLEAN DEFAULT FALSE,
    last_refreshed_at TIMESTAMP DEFAULT NOW(),
    refresh_interval_minutes INTEGER DEFAULT 5
);

INSERT INTO mv_refresh_status (view_name, needs_refresh, refresh_interval_minutes) VALUES
    ('mv_task_assignees_agg', FALSE, 5),
    ('mv_task_tags_agg', FALSE, 5),
    ('mv_message_recipients_agg', FALSE, 5),
    ('mv_message_attachments_agg', FALSE, 5),
    ('mv_conversation_labels_agg', FALSE, 5),
    ('mv_conversation_comments_agg', FALSE, 1)
ON CONFLICT (view_name) DO NOTHING;

-- =====================================
-- 9. THUMBNAIL PROCESSING QUEUE
-- =====================================

CREATE TABLE thumbnail_processing_queue (
    id SERIAL PRIMARY KEY,
    file_id UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    status VARCHAR(20) DEFAULT 'pending',
    attempts INTEGER DEFAULT 0,
    last_error TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    UNIQUE(file_id)
);

-- =====================================
-- INDEXES
-- =====================================

CREATE INDEX idx_unified_persons_display_name ON unified_persons(display_name);
CREATE INDEX idx_unified_persons_primary_email ON unified_persons(primary_email);
CREATE INDEX idx_unified_persons_is_internal ON unified_persons(is_internal);
CREATE INDEX idx_unified_persons_is_company ON unified_persons(is_company);
CREATE INDEX idx_unified_persons_display_name_lower ON unified_persons(LOWER(display_name));
CREATE INDEX idx_unified_persons_primary_email_lower ON unified_persons(LOWER(primary_email));
CREATE INDEX idx_unified_person_links_unified_person_id ON unified_person_links(unified_person_id);
CREATE INDEX idx_unified_person_links_link_type ON unified_person_links(link_type);
CREATE INDEX idx_locations_parent_id ON locations(parent_id);
CREATE INDEX idx_locations_type ON locations(type);
CREATE INDEX idx_locations_depth ON locations(depth);
CREATE INDEX idx_locations_path_ids ON locations USING GIN(path_ids);
CREATE INDEX idx_locations_parent_type ON locations(parent_id, type);
CREATE INDEX idx_cost_groups_parent_id ON cost_groups(parent_id);
CREATE INDEX idx_cost_groups_code ON cost_groups(code);
CREATE INDEX idx_project_extensions_default_location_id ON project_extensions(default_location_id);
CREATE INDEX idx_project_extensions_default_cost_group_id ON project_extensions(default_cost_group_id);
CREATE INDEX idx_project_extensions_client_person_id ON project_extensions(client_person_id);
CREATE INDEX idx_project_contractors_tw_project_id ON project_contractors(tw_project_id);
CREATE INDEX idx_project_contractors_contractor_person_id ON project_contractors(contractor_person_id);
CREATE INDEX idx_task_extensions_task_type_id ON task_extensions(task_type_id);
CREATE INDEX idx_task_extensions_type_source ON task_extensions(type_source);
CREATE INDEX idx_craft_documents_title ON craft_documents(title);
CREATE INDEX idx_craft_documents_is_deleted ON craft_documents(is_deleted);
CREATE INDEX idx_craft_documents_craft_last_modified_at ON craft_documents(craft_last_modified_at);
CREATE INDEX idx_craft_documents_db_updated_at ON craft_documents(db_updated_at);
CREATE INDEX idx_document_types_slug ON document_types(slug);
CREATE INDEX idx_files_filename ON files(filename);
CREATE INDEX idx_files_content_hash ON files(content_hash);
CREATE INDEX idx_files_document_type_id ON files(document_type_id);
CREATE INDEX idx_files_source_missive_attachment_id ON files(source_missive_attachment_id);
CREATE INDEX idx_files_storage_path ON files(storage_path);
CREATE INDEX idx_project_conversations_m_conversation_id ON project_conversations(m_conversation_id);
CREATE INDEX idx_project_conversations_tw_project_id ON project_conversations(tw_project_id);
CREATE INDEX idx_project_conversations_source ON project_conversations(source);
CREATE INDEX idx_project_files_file_id ON project_files(file_id);
CREATE INDEX idx_project_files_tw_project_id ON project_files(tw_project_id);
CREATE INDEX idx_project_files_composite ON project_files(tw_project_id, file_id);
CREATE INDEX idx_object_locations_location_id ON object_locations(location_id);
CREATE INDEX idx_object_locations_tw_task_id ON object_locations(tw_task_id);
CREATE INDEX idx_object_locations_m_conversation_id ON object_locations(m_conversation_id);
CREATE INDEX idx_object_locations_file_id ON object_locations(file_id);
CREATE INDEX idx_object_locations_source ON object_locations(source);
CREATE INDEX idx_object_cost_groups_cost_group_id ON object_cost_groups(cost_group_id);
CREATE INDEX idx_object_cost_groups_tw_task_id ON object_cost_groups(tw_task_id);
CREATE INDEX idx_object_cost_groups_m_conversation_id ON object_cost_groups(m_conversation_id);
CREATE INDEX idx_object_cost_groups_file_id ON object_cost_groups(file_id);
CREATE INDEX idx_object_cost_groups_source ON object_cost_groups(source);
CREATE INDEX idx_iip_unified_person_id ON item_involved_persons(unified_person_id);
CREATE INDEX idx_iip_item ON item_involved_persons(item_id, item_type);
CREATE INDEX idx_thumb_queue_status ON thumbnail_processing_queue(status, created_at);
CREATE INDEX idx_thumb_queue_file_id ON thumbnail_processing_queue(file_id);

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON TABLE unified_persons IS 'Canonical identity for a person or company';
COMMENT ON COLUMN unified_persons.is_internal IS 'ibhelm employee';
COMMENT ON COLUMN unified_persons.is_company IS 'true = company, false = person';
COMMENT ON TABLE unified_person_links IS 'Links unified_persons to source systems (Teamwork, Missive)';
COMMENT ON TABLE locations IS 'Hierarchical locations: building > level > room';
COMMENT ON COLUMN locations.path IS 'Materialized path for efficient hierarchy queries';
COMMENT ON COLUMN locations.search_text IS 'Generated search text including all parent names';
COMMENT ON TABLE cost_groups IS 'Hierarchical cost groups (Kostengruppen) - DIN 276 structure';
COMMENT ON COLUMN cost_groups.code IS '3-digit cost group code (100-999). Parent hierarchy: 456->450->400';
COMMENT ON TABLE project_extensions IS '1:1 extension to tw_projects - only ibhelm-specific data';
COMMENT ON COLUMN project_extensions.nas_folder_path IS 'e.g. /projects/2024-001-Neubau-XY/ for auto-assignment';
COMMENT ON TABLE task_extensions IS 'Decorator pattern: extends Teamwork tasks with ibhelm semantics';
COMMENT ON TABLE craft_documents IS 'Stores Craft documents with their full markdown content';
COMMENT ON TABLE files IS 'File metadata. storage_path is UUID-based path in Supabase Storage (e.g. a1b2c3d4.pdf)';
COMMENT ON TABLE project_conversations IS 'n:m - A conversation can belong to multiple projects';
COMMENT ON TABLE object_locations IS 'Polymorphic table connecting objects to locations';
COMMENT ON TABLE object_cost_groups IS 'Polymorphic table connecting objects to cost groups';
COMMENT ON TABLE item_involved_persons IS 'Junction table for filtering items by involved person';
COMMENT ON TABLE thumbnail_processing_queue IS 'Queue for thumbnail generation and text extraction processing';

