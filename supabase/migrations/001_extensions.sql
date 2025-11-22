-- =====================================
-- EXTENSIONS
-- =====================================
-- Enable required PostgreSQL extensions

-- UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Trigram similarity search for fuzzy matching
-- Used for location search and typo-resistant queries
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Full-text search support
CREATE EXTENSION IF NOT EXISTS unaccent;

COMMENT ON EXTENSION pg_trgm IS 'Trigram similarity for fuzzy search in locations and files';
COMMENT ON EXTENSION unaccent IS 'Text search dictionary that removes accents';

