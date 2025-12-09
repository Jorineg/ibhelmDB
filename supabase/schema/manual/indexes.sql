-- =====================================
-- ADVANCED INDEXES (MANUAL)
-- =====================================
-- GiST/GIN indexes that Atlas may have issues with
-- Run manually after schema apply if needed

-- =====================================
-- FULL-TEXT SEARCH INDEXES
-- =====================================

CREATE INDEX IF NOT EXISTS idx_locations_search_text_fts 
    ON locations USING GIN (to_tsvector('german', COALESCE(search_text, '')));

CREATE INDEX IF NOT EXISTS idx_files_extracted_text_fts 
    ON files USING GIN (to_tsvector('german', COALESCE(extracted_text, '')));

CREATE INDEX IF NOT EXISTS idx_files_auto_extracted_metadata_gin 
    ON files USING GIN (auto_extracted_metadata);

CREATE INDEX IF NOT EXISTS idx_tw_tasks_description_fts 
    ON teamwork.tasks USING GIN (to_tsvector('german', COALESCE(description, '')));

CREATE INDEX IF NOT EXISTS idx_m_messages_body_fts 
    ON missive.messages USING GIN (to_tsvector('german', COALESCE(subject, '') || ' ' || COALESCE(body, '') || ' ' || COALESCE(body_plain_text, '')));

CREATE INDEX IF NOT EXISTS idx_m_messages_subject_fts 
    ON missive.messages USING GIN (to_tsvector('german', COALESCE(subject, '')));

-- =====================================
-- COMMENTS
-- =====================================

-- These indexes are run manually because:
-- 1. Atlas may normalize GIN/GiST index definitions differently
-- 2. CREATE INDEX IF NOT EXISTS makes them idempotent
-- 3. They don't affect table structure, only performance

