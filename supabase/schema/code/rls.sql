-- =====================================
-- ROW LEVEL SECURITY (IDEMPOTENT)
-- =====================================
-- All statements are idempotent - safe to re-run

-- =====================================
-- 1. HELPER FUNCTIONS
-- =====================================

-- Get current user's email from JWT or session variable (for MCP)
CREATE OR REPLACE FUNCTION get_current_user_email() 
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('app.user_email', true), ''),
    (current_setting('request.jwt.claims', true)::jsonb)->>'email'
  )
$$;

-- Get public email addresses from app_settings
CREATE OR REPLACE FUNCTION get_public_emails() 
RETURNS TEXT[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT ARRAY(SELECT jsonb_array_elements_text(body->'public_email_addresses')) 
     FROM app_settings WHERE lock = 'X'),
    ARRAY[]::TEXT[]
  )
$$;

-- Check if current user is admin (from JWT app_metadata)
CREATE OR REPLACE FUNCTION is_admin() 
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (current_setting('request.jwt.claims', true)::jsonb)->'app_metadata'->>'role' = 'admin',
    FALSE
  )
$$;

-- Get current user ID from JWT (for user_settings)
CREATE OR REPLACE FUNCTION get_current_user_id() 
RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('app.user_id', true), '')::UUID,
    ((current_setting('request.jwt.claims', true)::jsonb)->>'sub')::UUID
  )
$$;

-- =====================================
-- 2. USER SETTINGS RLS
-- =====================================

ALTER TABLE user_settings ENABLE ROW LEVEL SECURITY;

-- Drop existing policies first (idempotent)
DROP POLICY IF EXISTS "user_settings_select_own" ON user_settings;
DROP POLICY IF EXISTS "user_settings_insert_own" ON user_settings;
DROP POLICY IF EXISTS "user_settings_update_own" ON user_settings;
DROP POLICY IF EXISTS "user_settings_delete_own" ON user_settings;

-- Users can only access their own settings
CREATE POLICY "user_settings_select_own" ON user_settings 
FOR SELECT USING (user_id = get_current_user_id());

CREATE POLICY "user_settings_insert_own" ON user_settings 
FOR INSERT WITH CHECK (user_id = get_current_user_id());

CREATE POLICY "user_settings_update_own" ON user_settings 
FOR UPDATE USING (user_id = get_current_user_id());

CREATE POLICY "user_settings_delete_own" ON user_settings 
FOR DELETE USING (user_id = get_current_user_id());

-- =====================================
-- 3. APP SETTINGS RLS
-- =====================================

ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "app_settings_select_all" ON app_settings;
DROP POLICY IF EXISTS "app_settings_update_admin" ON app_settings;

-- Everyone can read app settings
CREATE POLICY "app_settings_select_all" ON app_settings 
FOR SELECT USING (true);

-- Only admins can update app settings
CREATE POLICY "app_settings_update_admin" ON app_settings 
FOR UPDATE USING (is_admin());

-- =====================================
-- 4. OPERATION RUNS RLS (Admin Functions Protection)
-- =====================================

ALTER TABLE operation_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "operation_runs_select_all" ON operation_runs;
DROP POLICY IF EXISTS "operation_runs_insert_admin" ON operation_runs;
DROP POLICY IF EXISTS "operation_runs_update_admin" ON operation_runs;

-- Everyone can view operation run status
CREATE POLICY "operation_runs_select_all" ON operation_runs 
FOR SELECT USING (true);

-- Only admins can create/update operation runs (protects admin functions)
CREATE POLICY "operation_runs_insert_admin" ON operation_runs 
FOR INSERT WITH CHECK (is_admin());

CREATE POLICY "operation_runs_update_admin" ON operation_runs 
FOR UPDATE USING (is_admin());

-- =====================================
-- 5. UNIFIED ITEMS - Security via View (not RLS)
-- =====================================
-- NOTE: RLS does NOT work on materialized views in PostgreSQL.
-- Email filtering is handled by unified_items_secure view in views.sql
-- which wraps mv_unified_items with the email visibility filter.

-- =====================================
-- 6. MISSIVE MESSAGES RLS (for MCP direct access)
-- =====================================

ALTER TABLE missive.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "messages_email_visibility" ON missive.messages;

-- Email visibility policy for direct message access
CREATE POLICY "messages_email_visibility" ON missive.messages 
FOR SELECT USING (
  -- Check sender
  EXISTS (
    SELECT 1 FROM missive.contacts c 
    WHERE c.id = from_contact_id 
    AND c.email IN (SELECT unnest(ARRAY[get_current_user_email()] || get_public_emails()))
  )
  OR
  -- Check recipients (to/cc/bcc)
  EXISTS (
    SELECT 1 FROM missive.message_recipients mr
    JOIN missive.contacts c ON mr.contact_id = c.id
    WHERE mr.message_id = messages.id
    AND c.email IN (SELECT unnest(ARRAY[get_current_user_email()] || get_public_emails()))
  )
);

-- =====================================
-- 7. MISSIVE CONVERSATIONS RLS
-- =====================================

ALTER TABLE missive.conversations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "conversations_email_visibility" ON missive.conversations;

-- Conversations visible if any message in them is visible
CREATE POLICY "conversations_email_visibility" ON missive.conversations 
FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM missive.messages m
    WHERE m.conversation_id = conversations.id
    -- Message visibility check (same as messages policy)
    AND (
      EXISTS (
        SELECT 1 FROM missive.contacts c 
        WHERE c.id = m.from_contact_id 
        AND c.email IN (SELECT unnest(ARRAY[get_current_user_email()] || get_public_emails()))
      )
      OR EXISTS (
        SELECT 1 FROM missive.message_recipients mr
        JOIN missive.contacts c ON mr.contact_id = c.id
        WHERE mr.message_id = m.id
        AND c.email IN (SELECT unnest(ARRAY[get_current_user_email()] || get_public_emails()))
      )
    )
  )
);

-- =====================================
-- 8. MISSIVE ATTACHMENTS RLS
-- =====================================

ALTER TABLE missive.attachments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "attachments_via_message" ON missive.attachments;

-- Attachments visible if parent message is visible
CREATE POLICY "attachments_via_message" ON missive.attachments 
FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM missive.messages m
    WHERE m.id = message_id
    -- Inline message visibility
    AND (
      EXISTS (
        SELECT 1 FROM missive.contacts c 
        WHERE c.id = m.from_contact_id 
        AND c.email IN (SELECT unnest(ARRAY[get_current_user_email()] || get_public_emails()))
      )
      OR EXISTS (
        SELECT 1 FROM missive.message_recipients mr
        JOIN missive.contacts c ON mr.contact_id = c.id
        WHERE mr.message_id = m.id
        AND c.email IN (SELECT unnest(ARRAY[get_current_user_email()] || get_public_emails()))
      )
    )
  )
);

-- =====================================
-- 9. OTHER MISSIVE TABLES (Open Access)
-- =====================================
-- contacts, users, teams, shared_labels: no sensitive data, keep open
-- message_recipients, conversation_labels, etc: derived from messages

-- =====================================
-- 10. AUTO-ENABLE RLS ON NEW TABLES (Event Trigger)
-- =====================================

CREATE OR REPLACE FUNCTION auto_enable_rls_on_create()
RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE
  obj record;
BEGIN
  FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() 
             WHERE command_tag = 'CREATE TABLE'
             AND schema_name IN ('public', 'missive', 'teamwork')
  LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', obj.object_identity);
    RAISE NOTICE 'Auto-enabled RLS on %', obj.object_identity;
  END LOOP;
END;
$$;

-- Drop and recreate event trigger (idempotent)
DROP EVENT TRIGGER IF EXISTS auto_rls_trigger;
CREATE EVENT TRIGGER auto_rls_trigger
ON ddl_command_end
WHEN TAG IN ('CREATE TABLE')
EXECUTE FUNCTION auto_enable_rls_on_create();

-- =====================================
-- GRANTS FOR RLS TO WORK
-- =====================================

-- Helper functions must be executable by authenticated users
GRANT EXECUTE ON FUNCTION get_current_user_email() TO authenticated;
GRANT EXECUTE ON FUNCTION get_public_emails() TO authenticated;
GRANT EXECUTE ON FUNCTION is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION get_current_user_id() TO authenticated;

-- MCP readonly also needs these for RLS policies to evaluate
GRANT EXECUTE ON FUNCTION get_current_user_email() TO mcp_readonly;
GRANT EXECUTE ON FUNCTION get_public_emails() TO mcp_readonly;
GRANT EXECUTE ON FUNCTION is_admin() TO mcp_readonly;
GRANT EXECUTE ON FUNCTION get_current_user_id() TO mcp_readonly;

-- MCP: revoke direct MV access, grant secure view
REVOKE SELECT ON mv_unified_items FROM mcp_readonly;
GRANT SELECT ON unified_items_secure TO mcp_readonly;

-- MCP: revoke ALL write functions (prevent calling via SELECT function())
-- Admin batch operations
REVOKE EXECUTE ON FUNCTION rerun_all_task_type_extractions() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_person_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_project_conversation_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_cost_group_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_location_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_file_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_craft_linking() FROM mcp_readonly;
-- CRITICAL: Data deletion
REVOKE EXECUTE ON FUNCTION purge_excluded_teamwork_data() FROM mcp_readonly;
-- Record creation/modification
REVOKE EXECUTE ON FUNCTION get_or_create_location(TEXT, TEXT, TEXT) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION get_or_create_cost_group(INTEGER, TEXT) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION link_file_to_project(UUID) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION link_craft_document_to_project(TEXT) FROM mcp_readonly;
-- Metadata extraction (writes to DB)
REVOKE EXECUTE ON FUNCTION extract_locations_for_task(INTEGER) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_locations_for_conversation(UUID) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_cost_groups_for_task(INTEGER) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_cost_groups_for_conversation(UUID) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_cost_groups_for_file(UUID) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_file_metadata(UUID) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_craft_metadata(TEXT) FROM mcp_readonly;
-- Trigger functions (should never be called directly anyway)
REVOKE EXECUTE ON FUNCTION trigger_extract_file_metadata() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION trigger_extract_craft_metadata() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION trigger_delete_s3_content() FROM mcp_readonly;
-- File operations
REVOKE EXECUTE ON FUNCTION upsert_files_checkpoint(JSONB) FROM mcp_readonly;

-- Authenticated users need access to missive schema for RLS-protected queries
GRANT USAGE ON SCHEMA missive TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA missive TO authenticated;

-- Authenticated users need access to teamwork schema
GRANT USAGE ON SCHEMA teamwork TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA teamwork TO authenticated;

-- Settings tables: authenticated can read/write (RLS controls row access)
GRANT SELECT, INSERT, UPDATE, DELETE ON user_settings TO authenticated;
GRANT SELECT, UPDATE ON app_settings TO authenticated;

-- Operation runs: authenticated can read all, RLS controls write
GRANT SELECT, INSERT, UPDATE ON operation_runs TO authenticated;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON FUNCTION get_current_user_email() IS 'Returns current user email from JWT or MCP session variable';
COMMENT ON FUNCTION get_public_emails() IS 'Returns list of public email addresses from app_settings';
COMMENT ON FUNCTION is_admin() IS 'Returns true if current user has admin role in JWT app_metadata';
COMMENT ON FUNCTION get_current_user_id() IS 'Returns current user UUID from JWT sub claim or session variable';

