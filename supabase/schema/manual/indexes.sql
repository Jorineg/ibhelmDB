-- =====================================
-- ADVANCED INDEXES (MANUAL)
-- =====================================
-- GiST/GIN indexes that Atlas may have issues with
-- Run manually after schema apply if needed

-- JSONB index for file metadata queries
CREATE INDEX IF NOT EXISTS idx_files_auto_extracted_metadata_gin 
    ON files USING GIN (auto_extracted_metadata);

-- Trigram indexes for location search (used by find_location_ids_by_search)
CREATE INDEX IF NOT EXISTS idx_locations_name_trgm 
    ON locations USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_locations_search_text_trgm 
    ON locations USING GIN (search_text gin_trgm_ops);

-- Note: Trigram indexes for mv_unified_items are in views.sql (recreated with MV)
