-- =====================================
-- EXTENSIONS
-- =====================================
-- Enable required PostgreSQL extensions

-- UUID generation
-- Note: gen_random_uuid() is built-in since Postgres 13, no extension needed for it.
-- We only enable pg_trgm and unaccent.

-- Trigram similarity search for fuzzy matching
-- Used for location search and typo-resistant queries
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Full-text search support
CREATE EXTENSION IF NOT EXISTS unaccent;

COMMENT ON EXTENSION pg_trgm IS 'Trigram similarity for fuzzy search in locations and files';
COMMENT ON EXTENSION unaccent IS 'Text search dictionary that removes accents';

