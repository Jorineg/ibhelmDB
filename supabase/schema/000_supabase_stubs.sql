-- =====================================
-- SUPABASE STUBS (ROLES ONLY)
-- =====================================
-- Minimal stubs for Atlas dev database compatibility
-- Only creates roles required by grants in other files
-- DOES NOT create schemas to avoid OID conflicts

DO $$ 
BEGIN 
  -- Safely create roles if they don't exist
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END $$;

