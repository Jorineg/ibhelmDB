-- =====================================
-- IBHELM SCHEMA (PUBLIC)
-- =====================================
-- Main business logic tables for ibhelm

-- =====================================
-- 1. MASTER DATA (Parties & Projects)
-- =====================================

-- Parties (Unified Company/Person Model)
CREATE TABLE parties (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type party_type NOT NULL,
    parent_party_id UUID REFERENCES parties(id) ON DELETE SET NULL,
    
    name_primary TEXT NOT NULL,
    name_secondary TEXT,
    
    -- Display name (maintained by trigger)
    display_name TEXT,
    
    job_title TEXT,
    email VARCHAR(500),
    phone VARCHAR(100),
    
    -- Internal flag
    is_internal BOOLEAN DEFAULT FALSE,
    
    -- External system references
    tw_company_id INTEGER REFERENCES teamwork.companies(id) ON DELETE SET NULL,
    tw_user_id INTEGER REFERENCES teamwork.users(id) ON DELETE SET NULL,
    m_contact_id INTEGER REFERENCES missive.contacts(id) ON DELETE SET NULL,
    
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT parties_type_person_requires_primary_name CHECK (
        type = 'company' OR name_primary IS NOT NULL
    ),
    CONSTRAINT parties_person_can_have_parent CHECK (
        type = 'person' OR parent_party_id IS NULL
    )
);

-- Projects
CREATE TABLE projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    project_number VARCHAR(100),
    description TEXT,
    status VARCHAR(50),
    start_date DATE,
    end_date DATE,
    
    client_party_id UUID REFERENCES parties(id) ON DELETE SET NULL,
    tw_project_id INTEGER REFERENCES teamwork.projects(id) ON DELETE SET NULL,
    
    created_at TIMESTAMP DEFAULT NOW(),
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

-- Project Contractors (n:m relationship)
CREATE TABLE project_contractors (
    id SERIAL PRIMARY KEY,
    project_id UUID REFERENCES projects(id) ON DELETE CASCADE,
    contractor_party_id UUID REFERENCES parties(id) ON DELETE CASCADE,
    role VARCHAR(100),
    
    CONSTRAINT project_contractors_unique UNIQUE (project_id, contractor_party_id)
);

-- =====================================
-- 2. HIERARCHIES (Locations & Cost Groups)
-- =====================================

-- Locations (Hierarchical: Building > Level > Room)
CREATE TABLE locations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id UUID REFERENCES locations(id) ON DELETE CASCADE,
    owner_party_id UUID REFERENCES parties(id) ON DELETE SET NULL,
    
    name TEXT NOT NULL,
    type location_type NOT NULL,
    
    -- Materialized path for efficient hierarchy queries
    path TEXT,
    path_ids UUID[],
    depth INTEGER NOT NULL DEFAULT 0,
    
    -- Generated search text (will be populated by trigger)
    search_text TEXT,
    
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT locations_depth_check CHECK (depth >= 0 AND depth <= 2),
    CONSTRAINT locations_type_depth_match CHECK (
        (type = 'building' AND depth = 0) OR
        (type = 'level' AND depth = 1) OR
        (type = 'room' AND depth = 2)
    )
);

-- Cost Groups (Hierarchical: 300 > 310 > 311.5)
CREATE TABLE cost_groups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id UUID REFERENCES cost_groups(id) ON DELETE CASCADE,
    code VARCHAR(50) NOT NULL UNIQUE,
    name TEXT NOT NULL,
    
    -- Materialized path for efficient hierarchy queries
    path TEXT,
    
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

-- =====================================
-- 3. FILES & CONTENT
-- =====================================

-- Document Types
CREATE TABLE document_types (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    slug VARCHAR(100) UNIQUE NOT NULL,
    description TEXT,
    
    db_created_at TIMESTAMP DEFAULT NOW()
);

-- Files
CREATE TABLE files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Reference to Supabase storage.objects(id)
    storage_object_id UUID REFERENCES storage.objects(id) ON DELETE SET NULL,
    
    filename TEXT NOT NULL,
    folder_path TEXT,
    content_hash VARCHAR(64),
    
    -- Full-text search
    extracted_text TEXT,
    
    -- Thumbnails
    thumbnail_path TEXT,
    thumbnail_generated_at TIMESTAMP,
    
    document_type_id INTEGER REFERENCES document_types(id) ON DELETE SET NULL,
    
    -- Source reference
    source_missive_attachment_id UUID REFERENCES missive.attachments(id) ON DELETE SET NULL,
    
    -- File metadata
    file_created_at TIMESTAMP WITH TIME ZONE,
    file_modified_at TIMESTAMP WITH TIME ZONE,
    file_created_by TEXT,
    filesystem_inode BIGINT,
    filesystem_access_rights JSONB,
    filesystem_attributes JSONB,
    
    -- Auto-extracted metadata
    auto_extracted_metadata JSONB,
    
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

-- =====================================
-- 4. THE GLUE (Connecting Everything)
-- =====================================

-- Project Files (n:m - A file can belong to multiple projects)
CREATE TABLE project_files (
    file_id UUID REFERENCES files(id) ON DELETE CASCADE,
    project_id UUID REFERENCES projects(id) ON DELETE CASCADE,
    
    assigned_at TIMESTAMP DEFAULT NOW(),
    
    PRIMARY KEY (project_id, file_id)
);

-- Object Locations (Polymorphic - connects files/tasks/messages to locations)
CREATE TABLE object_locations (
    id SERIAL PRIMARY KEY,
    location_id UUID REFERENCES locations(id) ON DELETE CASCADE,
    
    -- Polymorphic columns (exactly ONE must be set)
    tw_task_id INTEGER REFERENCES teamwork.tasks(id) ON DELETE CASCADE,
    m_message_id UUID REFERENCES missive.messages(id) ON DELETE CASCADE,
    file_id UUID REFERENCES files(id) ON DELETE CASCADE,
    
    db_created_at TIMESTAMP DEFAULT NOW(),
    
    -- Constraint: exactly one object reference must be set
    CONSTRAINT object_locations_one_object CHECK (
        (file_id IS NOT NULL)::int + 
        (tw_task_id IS NOT NULL)::int + 
        (m_message_id IS NOT NULL)::int = 1
    )
);

-- Object Cost Groups (Polymorphic - connects files/tasks/messages to cost groups)
CREATE TABLE object_cost_groups (
    id SERIAL PRIMARY KEY,
    cost_group_id UUID REFERENCES cost_groups(id) ON DELETE CASCADE,
    
    -- Polymorphic columns (exactly ONE must be set)
    tw_task_id INTEGER REFERENCES teamwork.tasks(id) ON DELETE CASCADE,
    m_message_id UUID REFERENCES missive.messages(id) ON DELETE CASCADE,
    file_id UUID REFERENCES files(id) ON DELETE CASCADE,
    
    db_created_at TIMESTAMP DEFAULT NOW(),
    
    -- Constraint: exactly one object reference must be set
    CONSTRAINT object_cost_groups_one_object CHECK (
        (file_id IS NOT NULL)::int + 
        (tw_task_id IS NOT NULL)::int + 
        (m_message_id IS NOT NULL)::int = 1
    )
);

-- Task Extensions (Decorator Pattern for Teamwork tasks)
CREATE TABLE task_extensions (
    tw_task_id INTEGER PRIMARY KEY REFERENCES teamwork.tasks(id) ON DELETE CASCADE,
    
    type task_extension_type DEFAULT 'todo',
    
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

-- =====================================
-- BASIC INDEXES
-- =====================================

CREATE INDEX idx_parties_type ON parties(type);
CREATE INDEX idx_parties_parent_party_id ON parties(parent_party_id);
CREATE INDEX idx_parties_email ON parties(email);
CREATE INDEX idx_parties_is_internal ON parties(is_internal);
CREATE INDEX idx_parties_tw_company_id ON parties(tw_company_id);
CREATE INDEX idx_parties_tw_user_id ON parties(tw_user_id);
CREATE INDEX idx_parties_m_contact_id ON parties(m_contact_id);
CREATE INDEX idx_parties_display_name ON parties(display_name);

CREATE INDEX idx_projects_name ON projects(name);
CREATE INDEX idx_projects_project_number ON projects(project_number);
CREATE INDEX idx_projects_client_party_id ON projects(client_party_id);
CREATE INDEX idx_projects_tw_project_id ON projects(tw_project_id);
CREATE INDEX idx_projects_status ON projects(status);

CREATE INDEX idx_project_contractors_project_id ON project_contractors(project_id);
CREATE INDEX idx_project_contractors_contractor_party_id ON project_contractors(contractor_party_id);

CREATE INDEX idx_locations_parent_id ON locations(parent_id);
CREATE INDEX idx_locations_owner_party_id ON locations(owner_party_id);
CREATE INDEX idx_locations_type ON locations(type);
CREATE INDEX idx_locations_depth ON locations(depth);
CREATE INDEX idx_locations_path_ids ON locations USING GIN(path_ids);

CREATE INDEX idx_cost_groups_parent_id ON cost_groups(parent_id);
CREATE INDEX idx_cost_groups_code ON cost_groups(code);

CREATE INDEX idx_document_types_slug ON document_types(slug);

CREATE INDEX idx_files_filename ON files(filename);
CREATE INDEX idx_files_content_hash ON files(content_hash);
CREATE INDEX idx_files_document_type_id ON files(document_type_id);
CREATE INDEX idx_files_source_missive_attachment_id ON files(source_missive_attachment_id);
CREATE INDEX idx_files_storage_object_id ON files(storage_object_id);

CREATE INDEX idx_project_files_file_id ON project_files(file_id);
CREATE INDEX idx_project_files_project_id ON project_files(project_id);

CREATE INDEX idx_object_locations_location_id ON object_locations(location_id);
CREATE INDEX idx_object_locations_tw_task_id ON object_locations(tw_task_id);
CREATE INDEX idx_object_locations_m_message_id ON object_locations(m_message_id);
CREATE INDEX idx_object_locations_file_id ON object_locations(file_id);

CREATE INDEX idx_object_cost_groups_cost_group_id ON object_cost_groups(cost_group_id);
CREATE INDEX idx_object_cost_groups_tw_task_id ON object_cost_groups(tw_task_id);
CREATE INDEX idx_object_cost_groups_m_message_id ON object_cost_groups(m_message_id);
CREATE INDEX idx_object_cost_groups_file_id ON object_cost_groups(file_id);

CREATE INDEX idx_task_extensions_tw_task_id ON task_extensions(tw_task_id);
CREATE INDEX idx_task_extensions_type ON task_extensions(type);

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON TABLE parties IS 'Unified party model: companies and persons in one table';
COMMENT ON COLUMN parties.display_name IS 'Display name maintained by trigger for UI display';
COMMENT ON TABLE projects IS 'Main projects table with references to external systems';
COMMENT ON TABLE locations IS 'Hierarchical locations: building > level > room';
COMMENT ON COLUMN locations.path IS 'Materialized path for efficient hierarchy queries';
COMMENT ON COLUMN locations.search_text IS 'Generated search text including all parent names';
COMMENT ON TABLE cost_groups IS 'Hierarchical cost groups (Kostengruppen)';
COMMENT ON TABLE files IS 'File references with metadata and links to Supabase Storage';
COMMENT ON TABLE object_locations IS 'Polymorphic table connecting objects (files/tasks/messages) to locations';
COMMENT ON TABLE object_cost_groups IS 'Polymorphic table connecting objects (files/tasks/messages) to cost groups';
COMMENT ON TABLE task_extensions IS 'Decorator pattern: extends Teamwork tasks with ibhelm semantics';

