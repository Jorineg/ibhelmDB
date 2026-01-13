BEGIN;

-- 0. Drop blocking dependencies IMMEDIATELY to avoid deadlocks
-- These will be recreated by the normal schema apply script
DROP MATERIALIZED VIEW IF EXISTS mv_unified_items CASCADE;
DROP VIEW IF EXISTS file_details CASCADE;
DROP TRIGGER IF EXISTS extract_file_metadata_on_update ON files CASCADE;
DROP TRIGGER IF EXISTS extract_file_metadata_on_insert ON files CASCADE;
DROP TRIGGER IF EXISTS extract_file_metadata_on_delete ON files CASCADE;

-- 1. Create temporary tables/columns if needed
-- (Assuming the schema files are already updated, we might need to manually apply them or use this script to bridge the gap)

-- 2. Populate file_contents from existing files data
-- We take the FIRST occurrence of each hash to be our content master
INSERT INTO file_contents (
    content_hash, 
    size_bytes, 
    mime_type, 
    storage_path, 
    extracted_text, 
    thumbnail_path, 
    thumbnail_generated_at,
    s3_status, 
    processing_status,
    db_created_at,
    db_updated_at
)
SELECT DISTINCT ON (content_hash)
    content_hash, 
    COALESCE((filesystem_attributes->>'size_bytes')::BIGINT, 0),
    auto_extracted_metadata->>'mime_type',
    storage_path,
    extracted_text,
    thumbnail_path,
    thumbnail_generated_at,
    'uploaded'::s3_status,
    CASE 
        WHEN thumbnail_path IS NOT NULL OR extracted_text IS NOT NULL THEN 'done'::processing_status 
        ELSE 'pending'::processing_status 
    END,
    COALESCE(db_created_at, NOW()),
    COALESCE(db_updated_at, NOW())
FROM files
ON CONFLICT (content_hash) DO UPDATE SET
    storage_path = EXCLUDED.storage_path,
    extracted_text = COALESCE(file_contents.extracted_text, EXCLUDED.extracted_text),
    thumbnail_path = COALESCE(file_contents.thumbnail_path, EXCLUDED.thumbnail_path);

-- 3. Prepare files table for transformation
-- We'll add full_path and project_id if they don't exist yet (idempotent)
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='files' AND column_name='full_path') THEN
        ALTER TABLE files ADD COLUMN full_path TEXT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='files' AND column_name='project_id') THEN
        ALTER TABLE files ADD COLUMN project_id INTEGER REFERENCES teamwork.projects(id);
    END IF;
END $$;

-- 4. Populate full_path from old folder_path/filename
UPDATE files 
SET full_path = REPLACE(COALESCE(folder_path || '/', '') || filename, '//', '/');

-- 5. Migrate project_id from project_files junction table
-- We pick the first linked project (since we are simplifying to 1:1)
UPDATE files f
SET project_id = (
    SELECT tw_project_id 
    FROM project_files pf 
    WHERE pf.file_id = f.id 
    ORDER BY assigned_at ASC 
    LIMIT 1
);

-- 6. Cleanup redundant columns from files
ALTER TABLE files DROP COLUMN IF EXISTS storage_path CASCADE;
ALTER TABLE files DROP COLUMN IF EXISTS filename CASCADE;
ALTER TABLE files DROP COLUMN IF EXISTS folder_path CASCADE;
ALTER TABLE files DROP COLUMN IF EXISTS extracted_text CASCADE;
ALTER TABLE files DROP COLUMN IF EXISTS thumbnail_path CASCADE;
ALTER TABLE files DROP COLUMN IF EXISTS thumbnail_generated_at CASCADE;

-- 7. Drop redundant tables
DROP TABLE IF EXISTS project_files CASCADE;
DROP TABLE IF EXISTS thumbnail_processing_queue CASCADE;

-- 8. Add final constraints
ALTER TABLE files ALTER COLUMN full_path SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_files_full_path ON files(full_path);

COMMIT;
