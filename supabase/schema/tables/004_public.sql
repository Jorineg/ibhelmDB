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
    profile_markdown TEXT,
    profile_generated_at TIMESTAMPTZ,
    status_markdown TEXT,
    status_generated_at TIMESTAMPTZ,
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
    folder_path TEXT,
    folder_id TEXT,
    location TEXT,
    daily_note_date DATE,
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

CREATE TABLE file_contents (
    content_hash TEXT PRIMARY KEY,
    size_bytes BIGINT NOT NULL,
    mime_type TEXT,
    storage_path TEXT UNIQUE, -- format: {hash} (content-addressable)
    extracted_text TEXT,
    thumbnail_path TEXT,
    thumbnail_generated_at TIMESTAMPTZ,
    s3_status s3_status NOT NULL DEFAULT 'pending',
    status_message TEXT, -- reason for error/skipped status
    processing_status processing_status NOT NULL DEFAULT 'pending',
    try_count INTEGER DEFAULT 0,
    last_status_change TIMESTAMPTZ DEFAULT NOW(),
    db_created_at TIMESTAMP DEFAULT NOW(),
    db_updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_path TEXT UNIQUE NOT NULL, -- Full path including filename
    content_hash TEXT NOT NULL REFERENCES file_contents(content_hash),
    project_id INTEGER REFERENCES teamwork.projects(id) ON DELETE SET NULL,
    document_type_id INTEGER REFERENCES document_types(id) ON DELETE SET NULL,
    source_missive_attachment_id UUID REFERENCES missive.attachments(id) ON DELETE SET NULL,
    fs_mtime TIMESTAMP WITH TIME ZONE, -- st_mtime: content modification time
    fs_ctime TIMESTAMP WITH TIME ZONE, -- st_ctime: inode change time (copy/move/chmod)
    file_created_by TEXT,
    filesystem_inode BIGINT,
    filesystem_access_rights JSONB,
    filesystem_attributes JSONB,
    auto_extracted_metadata JSONB,
    deleted_at TIMESTAMPTZ,
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
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

CREATE TABLE project_craft_documents (
    craft_document_id TEXT REFERENCES craft_documents(id) ON DELETE CASCADE,
    tw_project_id INTEGER REFERENCES teamwork.projects(id) ON DELETE CASCADE,
    assigned_at TIMESTAMP DEFAULT NOW(),
    PRIMARY KEY (tw_project_id, craft_document_id)
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

-- =====================================
-- =====================================
-- 10. EMAIL ATTACHMENT FILES
-- =====================================
-- Tracks download status of Missive attachments to NAS.
-- Created by TeamworkMissiveConnector, processed by MissiveAttachmentDownloader.
-- FileMetadataSync links files to attachments via local_filename match.

CREATE TABLE email_attachment_files (
    missive_attachment_id UUID PRIMARY KEY,
    missive_message_id UUID NOT NULL,
    
    -- Original attachment info (denormalized for skip-filtering)
    original_filename TEXT NOT NULL,
    original_url TEXT NOT NULL,
    file_size INTEGER,
    width INTEGER,
    height INTEGER,
    media_type VARCHAR(100),
    sub_type VARCHAR(100),
    
    -- Download tracking
    status VARCHAR(20) DEFAULT 'pending' NOT NULL,
    local_filename TEXT UNIQUE,  -- e.g. "Invoice_0001f0d0-0c46-4036-84c7-c493a226a993.pdf"
    skip_reason TEXT,
    error_message TEXT,
    retry_count INTEGER DEFAULT 0,
    
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    downloaded_at TIMESTAMPTZ,
    
    CONSTRAINT eaf_valid_status CHECK (status IN ('pending', 'downloading', 'completed', 'failed', 'skipped'))
);

-- =====================================
-- 11. AI TRIGGERS
-- =====================================
-- Queue of AI requests triggered by @ai mentions in Missive comments.

CREATE TABLE ai_triggers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES missive.conversations(id) ON DELETE CASCADE,
    comment_id UUID NOT NULL REFERENCES missive.conversation_comments(id) ON DELETE CASCADE,
    comment_body TEXT,
    author_id UUID,
    status VARCHAR(20) DEFAULT 'pending',
    placeholder_post_id TEXT,
    result_post_id TEXT,
    result_markdown TEXT,
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    CONSTRAINT ai_triggers_status_check CHECK (status IN ('pending', 'processing', 'done', 'error'))
);

-- =====================================
-- INDEXES
-- =====================================

CREATE INDEX idx_unified_persons_display_name ON unified_persons(display_name);
CREATE INDEX idx_unified_persons_primary_email ON unified_persons(primary_email);
CREATE INDEX idx_unified_persons_is_internal ON unified_persons(is_internal);
CREATE INDEX idx_unified_persons_is_company ON unified_persons(is_company);
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
CREATE INDEX idx_craft_documents_folder_path ON craft_documents(folder_path);
CREATE INDEX idx_craft_documents_location ON craft_documents(location);
CREATE INDEX idx_craft_documents_daily_note_date ON craft_documents(daily_note_date) WHERE daily_note_date IS NOT NULL;
CREATE INDEX idx_document_types_slug ON document_types(slug);
CREATE INDEX idx_files_full_path ON files(full_path);
CREATE INDEX idx_files_content_hash ON files(content_hash);
CREATE INDEX idx_files_project_id ON files(project_id);
CREATE INDEX idx_files_document_type_id ON files(document_type_id);
CREATE INDEX idx_files_source_missive_attachment_id ON files(source_missive_attachment_id);
CREATE INDEX idx_files_deleted_at ON files(deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX idx_files_last_seen_at ON files(last_seen_at);

CREATE INDEX idx_file_contents_s3_status ON file_contents(s3_status);
CREATE INDEX idx_file_contents_processing_status ON file_contents(processing_status);
CREATE INDEX idx_file_contents_last_status_change ON file_contents(last_status_change);
CREATE INDEX idx_project_conversations_m_conversation_id ON project_conversations(m_conversation_id);
CREATE INDEX idx_project_conversations_tw_project_id ON project_conversations(tw_project_id);
CREATE INDEX idx_project_conversations_source ON project_conversations(source);
CREATE INDEX idx_project_craft_documents_craft_document_id ON project_craft_documents(craft_document_id);
CREATE INDEX idx_project_craft_documents_tw_project_id ON project_craft_documents(tw_project_id);
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
CREATE INDEX idx_eaf_status ON email_attachment_files(status) WHERE status IN ('pending', 'downloading');
CREATE INDEX idx_eaf_message_id ON email_attachment_files(missive_message_id);
CREATE INDEX idx_eaf_local_filename ON email_attachment_files(local_filename) WHERE local_filename IS NOT NULL;
CREATE INDEX idx_ai_triggers_status ON ai_triggers(status);
CREATE INDEX idx_ai_triggers_status_created ON ai_triggers(status, created_at) WHERE status = 'pending';
CREATE INDEX idx_ai_triggers_conversation_id ON ai_triggers(conversation_id);
CREATE INDEX idx_ai_triggers_created_at ON ai_triggers(created_at DESC);
CREATE UNIQUE INDEX idx_ai_triggers_comment_id ON ai_triggers(comment_id);

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
COMMENT ON COLUMN project_extensions.nas_folder_path IS 'NAS project directory name (one segment, e.g. 2021005-DESY-San-Heiz-MK). May include slashes; last segment is used. Drives attachment downloader + file/Craft linking when set.';
COMMENT ON TABLE task_extensions IS 'Decorator pattern: extends Teamwork tasks with ibhelm semantics';
COMMENT ON COLUMN task_extensions.type_source_tag_name IS 'Teamwork tag that triggered task type; also used for Craft folder_path linking when project name does not match (see link_craft_document_to_project)';
COMMENT ON TABLE craft_documents IS 'Stores Craft documents with their full markdown content';
COMMENT ON COLUMN craft_documents.folder_path IS 'Full folder path e.g. /Projekte/Bauprojekt-A';
COMMENT ON COLUMN craft_documents.folder_id IS 'Direct parent folder ID';
COMMENT ON COLUMN craft_documents.location IS 'Built-in location: unsorted, templates, daily_notes (NULL if in folder)';
COMMENT ON COLUMN craft_documents.daily_note_date IS 'Date for daily notes (NULL for regular documents)';
COMMENT ON TABLE file_contents IS 'Content-Addressable Storage: Stores unique file content, OCR, and thumbnails.';
COMMENT ON TABLE files IS 'File references: Maps physical paths to content hashes and projects.';
COMMENT ON COLUMN files.full_path IS 'Full filesystem path including filename.';
COMMENT ON COLUMN files.deleted_at IS 'Soft delete timestamp. Set when file no longer exists on filesystem.';
COMMENT ON COLUMN files.last_seen_at IS 'Last time file was found during filesystem scan.';
COMMENT ON TABLE project_conversations IS 'n:m - A conversation can belong to multiple projects';
COMMENT ON TABLE object_locations IS 'Polymorphic table connecting objects to locations';
COMMENT ON TABLE object_cost_groups IS 'Polymorphic table connecting objects to cost groups';
COMMENT ON TABLE item_involved_persons IS 'Junction table for filtering items by involved person';
COMMENT ON TABLE item_involved_persons IS 'Junction table for filtering items by involved person';
COMMENT ON TABLE email_attachment_files IS 'Download tracking for Missive email attachments. Filename format: {name}_{attachment_id}.{ext}';
COMMENT ON COLUMN email_attachment_files.local_filename IS 'Unique filename used for FileMetadataSync matching. Format: OriginalName_UUID.ext';
COMMENT ON TABLE ai_triggers IS 'Queue of AI requests triggered by @ai mentions in Missive comments';
COMMENT ON COLUMN ai_triggers.status IS 'pending=waiting, processing=claimed, done=completed, error=failed';
COMMENT ON COLUMN ai_triggers.placeholder_post_id IS 'Missive post ID of "thinking..." placeholder for deletion';
COMMENT ON COLUMN ai_triggers.result_post_id IS 'Missive post ID of final AI response';
COMMENT ON COLUMN ai_triggers.result_markdown IS 'Stored AI response for debugging/audit';

-- =====================================
-- 12. PROJECT ACTIVITY SYSTEM
-- =====================================

CREATE TABLE project_event_log (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tw_project_id INT NOT NULL REFERENCES teamwork.projects(id) ON DELETE CASCADE,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    source_table VARCHAR(50) NOT NULL,
    source_id TEXT NOT NULL,
    event_type VARCHAR(20) NOT NULL,

    details JSONB NOT NULL,

    old_content TEXT,
    content_diff TEXT,

    processed_by_diff BOOLEAN DEFAULT FALSE,
    processed_by_agent BOOLEAN DEFAULT FALSE,

    db_created_at TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT pel_event_type_check CHECK (event_type IN ('created', 'changed', 'deleted'))
);

CREATE INDEX idx_event_log_project ON project_event_log(tw_project_id, occurred_at);
CREATE INDEX idx_event_log_unprocessed_diff ON project_event_log(id)
    WHERE NOT processed_by_diff AND old_content IS NOT NULL;
CREATE INDEX idx_event_log_unprocessed_agent ON project_event_log(id)
    WHERE NOT processed_by_agent;

CREATE TABLE project_activity_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tw_project_id INT NOT NULL REFERENCES teamwork.projects(id) ON DELETE CASCADE,
    logged_at TIMESTAMPTZ NOT NULL,

    category VARCHAR(30) NOT NULL,

    summary TEXT NOT NULL,

    source_event_ids BIGINT[],
    kgr_codes TEXT[],
    involved_persons TEXT[],

    generated_at TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT pal_category_check CHECK (category IN (
        'decision', 'blocker', 'resolution', 'progress',
        'milestone', 'risk', 'scope_change', 'communication'
    ))
);

CREATE INDEX idx_activity_log_project ON project_activity_log(tw_project_id, logged_at);

COMMENT ON TABLE project_event_log IS 'Tier 4: Mechanical event log — raw facts captured by DB triggers';
COMMENT ON COLUMN project_event_log.old_content IS 'Temporary: old text for diff computation (NULLed after processing)';
COMMENT ON COLUMN project_event_log.content_diff IS 'Computed unified diff for long text changes';
COMMENT ON TABLE project_activity_log IS 'Tier 3: AI-generated activity narrative — semantic summaries of Tier 4 events';

CREATE TABLE project_agent_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tw_project_id INT NOT NULL REFERENCES teamwork.projects(id) ON DELETE CASCADE,
    action VARCHAR(30) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    result_session_id UUID,
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ,

    CONSTRAINT par_action_check CHECK (action IN ('bootstrap')),
    CONSTRAINT par_status_check CHECK (status IN ('pending', 'processing', 'done', 'error'))
);

CREATE INDEX idx_par_status ON project_agent_requests(status) WHERE status = 'pending';

COMMENT ON TABLE project_agent_requests IS 'Queue for on-demand agent actions (bootstrap Tier 1/2)';

-- =====================================
-- 13. CHAT
-- =====================================

CREATE TABLE chat_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    title TEXT,
    system_prompt TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE chat_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL,
    content TEXT,
    blocks JSONB,
    metadata JSONB,
    status chat_message_status NOT NULL DEFAULT 'complete',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT chat_messages_role_check CHECK (role IN ('user', 'assistant'))
);

CREATE INDEX idx_chat_sessions_user_id ON chat_sessions(user_id);
CREATE INDEX idx_chat_sessions_updated_at ON chat_sessions(updated_at DESC);
CREATE INDEX idx_chat_messages_session_id ON chat_messages(session_id);
CREATE INDEX idx_chat_messages_created_at ON chat_messages(session_id, created_at);

CREATE TABLE chat_files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    filename TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    bucket TEXT NOT NULL,
    origin VARCHAR(20) NOT NULL,
    size_bytes BIGINT,
    mime_type TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT chat_files_origin_check CHECK (origin IN ('upload', 'generated', 'reference')),
    CONSTRAINT chat_files_bucket_check CHECK (bucket IN ('files', 'chat-files'))
);

CREATE INDEX idx_chat_files_message_id ON chat_files(message_id);
CREATE INDEX idx_chat_files_content_hash ON chat_files(content_hash);

COMMENT ON TABLE chat_sessions IS 'AI chat sessions per user';
COMMENT ON TABLE chat_messages IS 'Messages within a chat session';
COMMENT ON COLUMN chat_messages.role IS 'user or assistant';
COMMENT ON COLUMN chat_messages.blocks IS 'Neutral content blocks: [{type:"text",text}, {type:"tool_call",id,code,result|[{type:"text"},{type:"image",storage_path,media_type}],error}, {type:"thinking",text}]';
COMMENT ON COLUMN chat_messages.metadata IS '{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, model} for assistant messages';
COMMENT ON TABLE chat_files IS 'Files attached to chat messages (uploads, generated, or references to existing NAS files)';
COMMENT ON COLUMN chat_files.content_hash IS 'SHA-256 hash of file content, also used as S3 key/path in the bucket';
COMMENT ON COLUMN chat_files.bucket IS 'Supabase Storage bucket: files (existing NAS) or chat-files (uploaded/generated)';
COMMENT ON COLUMN chat_files.origin IS 'upload: user uploaded, generated: sandbox created, reference: matched existing file_contents';

-- =====================================
-- AGENT FEEDBACK
-- =====================================
CREATE TABLE agent_feedback (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    context VARCHAR(20) NOT NULL,
    model TEXT,
    category TEXT,
    feedback TEXT NOT NULL,
    session_id UUID REFERENCES chat_sessions(id)
);

CREATE INDEX idx_agent_feedback_created ON agent_feedback(created_at DESC);

-- =====================================
-- 15. PROMPT TEMPLATES
-- =====================================

CREATE TABLE prompt_templates (
    id TEXT PRIMARY KEY,
    owner_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('prompt', 'component', 'doc')),
    content TEXT NOT NULL DEFAULT '',
    description TEXT,
    is_system BOOLEAN NOT NULL DEFAULT FALSE,
    db_created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    db_updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_prompt_templates_category ON prompt_templates(category);
CREATE INDEX idx_prompt_templates_owner ON prompt_templates(owner_id) WHERE owner_id IS NOT NULL;

COMMENT ON TABLE prompt_templates IS 'Composable prompt templates, reusable components, and reference docs for LLM systems';
COMMENT ON COLUMN prompt_templates.id IS 'Human-readable slug: chat.system_prompt, tool_doc.read_functions, doc.dashboard_manual';
COMMENT ON COLUMN prompt_templates.owner_id IS 'NULL = system-owned (admin-managed), UUID = user-owned';
COMMENT ON COLUMN prompt_templates.category IS 'prompt = full LLM prompts, component = reusable building blocks, doc = reference documentation';
COMMENT ON COLUMN prompt_templates.is_system IS 'System templates cannot be deleted (but can be edited by admins)';

-- =====================================
-- MCP READONLY GRANTS
-- =====================================
GRANT USAGE ON SCHEMA public TO mcp_readonly;
GRANT USAGE ON SCHEMA teamwork TO mcp_readonly;
GRANT USAGE ON SCHEMA missive TO mcp_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA teamwork TO mcp_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA missive TO mcp_readonly;

