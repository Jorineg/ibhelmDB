-- =====================================
-- SUPABASE STUBS
-- =====================================
-- Minimal stubs for Atlas dev database compatibility
-- These exist in real Supabase but not in vanilla Postgres
-- Required for Atlas to parse schema files that reference Supabase internals

-- =====================================
-- 1. ROLES
-- =====================================

DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- =====================================
-- 2. SCHEMAS
-- =====================================

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;
CREATE SCHEMA IF NOT EXISTS realtime;

-- =====================================
-- 3. STORAGE OBJECTS TABLE (for FK reference)
-- =====================================
-- Real Supabase storage.objects has more columns, this is minimal stub

CREATE TABLE IF NOT EXISTS storage.objects (
    id UUID PRIMARY KEY,
    bucket_id TEXT,
    name TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

