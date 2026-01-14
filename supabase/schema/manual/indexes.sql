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

-- =====================================
-- B-TREE INDEXES FOR mv_unified_items
-- =====================================
-- These fix baseline slowness for sorting and simple filtering
CREATE INDEX IF NOT EXISTS idx_mv_ui_updated_at ON mv_unified_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_mv_ui_type ON mv_unified_items(type);
CREATE INDEX IF NOT EXISTS idx_mv_ui_status ON mv_unified_items(status);
CREATE INDEX IF NOT EXISTS idx_mv_ui_project ON mv_unified_items(project);
CREATE INDEX IF NOT EXISTS idx_mv_ui_created_at ON mv_unified_items(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mv_ui_due_date ON mv_unified_items(due_date);
CREATE INDEX IF NOT EXISTS idx_mv_ui_priority ON mv_unified_items(priority);
CREATE INDEX IF NOT EXISTS idx_mv_ui_progress ON mv_unified_items(progress);
CREATE INDEX IF NOT EXISTS idx_mv_ui_attachment_count ON mv_unified_items(attachment_count);
-- Composite index for default dashboard view (type + sort)
CREATE INDEX IF NOT EXISTS idx_mv_ui_type_updated_at ON mv_unified_items(type, updated_at DESC);

-- Covering index for deferred join: allows sorting without heap access
-- Used by skinny_ids CTE to get IDs in sort order without fetching full rows
CREATE INDEX IF NOT EXISTS idx_mv_ui_updated_at_lookup ON mv_unified_items(updated_at DESC, type, id);
CREATE INDEX IF NOT EXISTS idx_mv_ui_created_at_lookup ON mv_unified_items(created_at DESC, type, id);

-- Note: Trigram indexes for mv_unified_items are in views.sql (recreated with MV)

-- =====================================
-- ITEM_INVOLVED_PERSONS INDEXES
-- =====================================
-- Composite index for involved person filter in query_unified_items (P2 optimization)
-- Allows efficient lookup by person_id first, then verify item_id/item_type
CREATE INDEX IF NOT EXISTS idx_iip_person_item 
    ON item_involved_persons(unified_person_id, item_id, item_type);
