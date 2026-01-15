-- =====================================
-- SUPABASE STUBS (ROLES & PUBLIC)
-- =====================================
-- Minimal stubs for Atlas dev database compatibility

-- Ensure public schema exists and is tracked
CREATE SCHEMA IF NOT EXISTS public;

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
  
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'mcp_readonly') THEN
    CREATE ROLE mcp_readonly NOLOGIN;
  END IF;
END $$;

-- Ensure MCP role respects RLS (critical for email security)
ALTER ROLE mcp_readonly NOBYPASSRLS;

