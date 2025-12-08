-- =====================================
-- ADVANCED INDEXES
-- =====================================

-- WICHTIG: Wir nutzen explizit 'extensions.gin_trgm_ops', da Supabase die Extension dort ablegt.

-- =====================================
-- LOCATION SEARCH INDEXES
-- =====================================

CREATE INDEX idx_locations_name_trgm ON locations USING GIN (name extensions.gin_trgm_ops);
CREATE INDEX idx_locations_path_trgm ON locations USING GIN (path extensions.gin_trgm_ops);
-- Full-Text Search nutzt interne Funktionen, das ist ok
CREATE INDEX idx_locations_search_text_fts ON locations USING GIN (to_tsvector('german', COALESCE(search_text, '')));

-- =====================================
-- FILE SEARCH INDEXES
-- =====================================

CREATE INDEX idx_files_filename_trgm ON files USING GIN (filename extensions.gin_trgm_ops);
CREATE INDEX idx_files_extracted_text_fts ON files USING GIN (to_tsvector('german', COALESCE(extracted_text, '')));
CREATE INDEX idx_files_folder_path_trgm ON files USING GIN (folder_path extensions.gin_trgm_ops);
CREATE INDEX idx_files_auto_extracted_metadata_gin ON files USING GIN (auto_extracted_metadata);

-- =====================================
-- UNIFIED PERSONS SEARCH INDEXES
-- =====================================

CREATE INDEX idx_unified_persons_display_name_trgm ON unified_persons USING GIN (display_name extensions.gin_trgm_ops);
CREATE INDEX idx_unified_persons_primary_email_trgm ON unified_persons USING GIN (primary_email extensions.gin_trgm_ops);

-- =====================================
-- COST GROUP SEARCH INDEXES
-- =====================================

CREATE INDEX idx_cost_groups_name_trgm ON cost_groups USING GIN (name extensions.gin_trgm_ops);
-- Cast zu Text für Indexierung
CREATE INDEX idx_cost_groups_code_trgm ON cost_groups USING GIN ((code::TEXT) extensions.gin_trgm_ops);

-- =====================================
-- TEAMWORK SEARCH INDEXES
-- =====================================

CREATE INDEX idx_tw_tasks_name_trgm ON teamwork.tasks USING GIN (name extensions.gin_trgm_ops);
CREATE INDEX idx_tw_tasks_description_fts ON teamwork.tasks USING GIN (to_tsvector('german', COALESCE(description, '')));
CREATE INDEX idx_tw_projects_name_trgm ON teamwork.projects USING GIN (name extensions.gin_trgm_ops);
CREATE INDEX idx_tw_companies_name_trgm ON teamwork.companies USING GIN (name extensions.gin_trgm_ops);

-- =====================================
-- MISSIVE SEARCH INDEXES
-- =====================================

CREATE INDEX idx_m_messages_body_fts ON missive.messages USING GIN (to_tsvector('german', COALESCE(subject, '') || ' ' || COALESCE(body, '') || ' ' || COALESCE(body_plain_text, '')));
CREATE INDEX idx_m_messages_subject_fts ON missive.messages USING GIN (to_tsvector('german', COALESCE(subject, '')));
CREATE INDEX idx_m_contacts_name_trgm ON missive.contacts USING GIN (name extensions.gin_trgm_ops);
CREATE INDEX idx_m_contacts_email_trgm ON missive.contacts USING GIN (email extensions.gin_trgm_ops);

-- =====================================
-- PERFORMANCE INDEXES
-- =====================================

CREATE INDEX idx_project_files_composite ON project_files(tw_project_id, file_id);
CREATE INDEX idx_tw_tasks_project_status ON teamwork.tasks(project_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_m_messages_conversation_delivered ON missive.messages(conversation_id, delivered_at DESC);
CREATE INDEX idx_locations_parent_type ON locations(parent_id, type);