-- =====================================
-- SERVICE AGENT SCHEMA
-- =====================================
-- Separate schema for service management data.
-- Only accessible via service key, NOT anon key.
-- This provides security isolation from the dashboard.

CREATE SCHEMA IF NOT EXISTS service_agent;

-- =====================================
-- 1. SERVICE CONFIGURATIONS
-- =====================================
-- Centralized configuration for IBHelm services.
-- Used by service-agent to provide env vars to containers at startup.

CREATE TABLE service_agent.configurations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key TEXT NOT NULL UNIQUE,
    value TEXT NOT NULL,
    is_secret BOOLEAN DEFAULT FALSE,
    scope TEXT[] NOT NULL DEFAULT ARRAY['*'],
    category TEXT,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE INDEX idx_sac_scope ON service_agent.configurations USING GIN(scope);
CREATE INDEX idx_sac_category ON service_agent.configurations(category);

-- =====================================
-- 2. OPERATION LOGS (for audit trail)
-- =====================================
-- Log of all service operations performed via agent.

CREATE TABLE service_agent.operation_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_name TEXT NOT NULL,
    operation TEXT NOT NULL,  -- 'start', 'stop', 'restart', 'update', 'config_change'
    success BOOLEAN NOT NULL,
    message TEXT,
    performed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    performed_by_email TEXT,
    performed_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_saol_service ON service_agent.operation_logs(service_name);
CREATE INDEX idx_saol_operation ON service_agent.operation_logs(operation);
CREATE INDEX idx_saol_performed_at ON service_agent.operation_logs(performed_at DESC);

-- =====================================
-- PERMISSIONS
-- =====================================
-- Revoke all from public (anon key uses public role)
-- Only service_role can access this schema

REVOKE ALL ON SCHEMA service_agent FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA service_agent FROM PUBLIC;

-- Grant to service_role (used by service key)
GRANT USAGE ON SCHEMA service_agent TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA service_agent TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA service_agent TO service_role;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON SCHEMA service_agent IS 'Service management data. Only accessible via service key.';
COMMENT ON TABLE service_agent.configurations IS 'Centralized config for IBHelm services. Key-value with scope filtering.';
COMMENT ON COLUMN service_agent.configurations.scope IS 'Array of service names. Use * for all services.';
COMMENT ON COLUMN service_agent.configurations.is_secret IS 'If true, value is masked in dashboard UI.';
COMMENT ON TABLE service_agent.operation_logs IS 'Audit log of all service operations.';

