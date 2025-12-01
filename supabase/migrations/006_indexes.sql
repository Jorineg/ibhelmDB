-- =====================================
-- ADVANCED INDEXES
-- =====================================
-- GiST and GIN indexes for search functionality

-- =====================================
-- LOCATION SEARCH INDEXES
-- =====================================

-- Trigram index for fuzzy/typo-resistant search on location names
CREATE INDEX idx_locations_name_trgm ON locations USING GIST (name gist_trgm_ops);

-- Trigram index for fuzzy search on materialized path
CREATE INDEX idx_locations_path_trgm ON locations USING GIST (path gist_trgm_ops);

-- Full-text search on search_text (will be populated by trigger)
CREATE INDEX idx_locations_search_text_fts ON locations USING GIN (to_tsvector('german', COALESCE(search_text, '')));

-- =====================================
-- FILE SEARCH INDEXES
-- =====================================

-- Trigram index for fuzzy filename search
CREATE INDEX idx_files_filename_trgm ON files USING GIST (filename gist_trgm_ops);

-- Full-text search on extracted text from PDFs
CREATE INDEX idx_files_extracted_text_fts ON files USING GIN (to_tsvector('german', COALESCE(extracted_text, '')));

-- Full-text search on folder path
CREATE INDEX idx_files_folder_path_trgm ON files USING GIST (folder_path gist_trgm_ops);

-- GIN index on auto-extracted metadata JSONB
CREATE INDEX idx_files_auto_extracted_metadata_gin ON files USING GIN (auto_extracted_metadata);

-- =====================================
-- PARTY SEARCH INDEXES
-- =====================================

-- Trigram index for fuzzy search on party names
CREATE INDEX idx_parties_name_primary_trgm ON parties USING GIST (name_primary gist_trgm_ops);
CREATE INDEX idx_parties_name_secondary_trgm ON parties USING GIST (name_secondary gist_trgm_ops);
CREATE INDEX idx_parties_display_name_trgm ON parties USING GIST (display_name gist_trgm_ops);

-- =====================================
-- PROJECT SEARCH INDEXES
-- =====================================

-- Trigram index for fuzzy search on project names
CREATE INDEX idx_projects_name_trgm ON projects USING GIST (name gist_trgm_ops);

-- Full-text search on project description
CREATE INDEX idx_projects_description_fts ON projects USING GIN (to_tsvector('german', COALESCE(description, '')));

-- =====================================
-- COST GROUP SEARCH INDEXES
-- =====================================

-- Trigram index for fuzzy search on cost group names
CREATE INDEX idx_cost_groups_name_trgm ON cost_groups USING GIST (name gist_trgm_ops);

-- Trigram index for fuzzy search on cost group codes
CREATE INDEX idx_cost_groups_code_trgm ON cost_groups USING GIST (code gist_trgm_ops);

-- =====================================
-- TEAMWORK SEARCH INDEXES
-- =====================================

-- Trigram index for task names
CREATE INDEX idx_tw_tasks_name_trgm ON teamwork.tasks USING GIST (name gist_trgm_ops);

-- Full-text search on task descriptions
CREATE INDEX idx_tw_tasks_description_fts ON teamwork.tasks USING GIN (to_tsvector('german', COALESCE(description, '')));

-- Trigram indexes for project and company names
CREATE INDEX idx_tw_projects_name_trgm ON teamwork.projects USING GIST (name gist_trgm_ops);
CREATE INDEX idx_tw_companies_name_trgm ON teamwork.companies USING GIST (name gist_trgm_ops);

-- =====================================
-- MISSIVE SEARCH INDEXES
-- =====================================

-- Full-text search on message body
CREATE INDEX idx_m_messages_body_fts ON missive.messages USING GIN (to_tsvector('german', COALESCE(body, '')));

-- Full-text search on message subject
CREATE INDEX idx_m_messages_subject_fts ON missive.messages USING GIN (to_tsvector('german', COALESCE(subject, '')));

-- Trigram index for contact names and emails
CREATE INDEX idx_m_contacts_name_trgm ON missive.contacts USING GIST (name gist_trgm_ops);
CREATE INDEX idx_m_contacts_email_trgm ON missive.contacts USING GIST (email gist_trgm_ops);

-- =====================================
-- PERFORMANCE INDEXES
-- =====================================

-- Composite indexes for common queries

-- Files by project and type
CREATE INDEX idx_files_project_type ON project_files(project_id, file_id);

-- Tasks by project and status
CREATE INDEX idx_tw_tasks_project_status ON teamwork.tasks(project_id, status) WHERE deleted_at IS NULL;

-- Messages by conversation and date
CREATE INDEX idx_m_messages_conversation_delivered ON missive.messages(conversation_id, delivered_at DESC);

-- Locations by owner and type
CREATE INDEX idx_locations_owner_type ON locations(owner_party_id, type);

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON INDEX idx_locations_name_trgm IS 'Trigram index for typo-resistant location name search';
COMMENT ON INDEX idx_locations_search_text_fts IS 'Full-text search index for location hierarchy search';
COMMENT ON INDEX idx_files_extracted_text_fts IS 'Full-text search index for PDF content search';
COMMENT ON INDEX idx_files_auto_extracted_metadata_gin IS 'GIN index for JSONB metadata queries';

