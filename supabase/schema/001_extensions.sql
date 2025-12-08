-- =====================================
-- EXTENSIONS
-- =====================================

-- Supabase best practice: Extensions in eigenem Schema
CREATE SCHEMA IF NOT EXISTS extensions;

-- Extension für Trigramm-Suche (in extensions schema)
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA extensions;

-- Extension für Akzent-Entfernung (in extensions schema)
CREATE Extension IF NOT EXISTS unaccent SCHEMA extensions;

-- Search Path für die aktuelle Session setzen, damit nachfolgende Skripte die Extensions finden
SET search_path TO public, extensions;