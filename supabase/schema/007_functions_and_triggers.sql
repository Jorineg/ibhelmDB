-- =====================================
-- FUNCTIONS AND TRIGGERS
-- =====================================

-- =====================================
-- 1. AUTO-UPDATE TIMESTAMPS
-- =====================================

-- Generic function to update db_updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.db_updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to all relevant tables

-- Public schema (ibhelm)
CREATE TRIGGER update_unified_persons_updated_at BEFORE UPDATE ON unified_persons
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_unified_person_links_updated_at BEFORE UPDATE ON unified_person_links
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_project_extensions_updated_at BEFORE UPDATE ON project_extensions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_locations_updated_at BEFORE UPDATE ON locations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_cost_groups_updated_at BEFORE UPDATE ON cost_groups
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_files_updated_at BEFORE UPDATE ON files
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_craft_documents_updated_at BEFORE UPDATE ON craft_documents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_task_extensions_updated_at BEFORE UPDATE ON task_extensions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Teamwork schema
CREATE TRIGGER update_tw_companies_updated_at BEFORE UPDATE ON teamwork.companies
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_tw_users_updated_at BEFORE UPDATE ON teamwork.users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_tw_teams_updated_at BEFORE UPDATE ON teamwork.teams
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_tw_projects_updated_at BEFORE UPDATE ON teamwork.projects
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_tw_tasklists_updated_at BEFORE UPDATE ON teamwork.tasklists
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_tw_tasks_updated_at BEFORE UPDATE ON teamwork.tasks
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Missive schema
CREATE TRIGGER update_m_contacts_updated_at BEFORE UPDATE ON missive.contacts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_m_users_updated_at BEFORE UPDATE ON missive.users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_m_teams_updated_at BEFORE UPDATE ON missive.teams
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_m_conversations_updated_at BEFORE UPDATE ON missive.conversations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_m_messages_updated_at BEFORE UPDATE ON missive.messages
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =====================================
-- 2. LOCATION HIERARCHY MAINTENANCE
-- =====================================

-- Function to build location path and search_text
CREATE OR REPLACE FUNCTION update_location_hierarchy()
RETURNS TRIGGER AS $$
DECLARE
    parent_rec RECORD;
    parent_path TEXT := '';
    parent_path_ids UUID[] := ARRAY[]::UUID[];
    parent_search TEXT := '';
BEGIN
    -- Set depth based on type
    NEW.depth := CASE NEW.type
        WHEN 'building' THEN 0
        WHEN 'level' THEN 1
        WHEN 'room' THEN 2
    END;
    
    -- If has parent, get parent's data
    IF NEW.parent_id IS NOT NULL THEN
        SELECT path, path_ids, search_text, depth
        INTO parent_rec
        FROM locations
        WHERE id = NEW.parent_id;
        
        IF FOUND THEN
            parent_path := parent_rec.path;
            parent_path_ids := parent_rec.path_ids;
            parent_search := parent_rec.search_text;
            
            -- Verify depth is correct
            IF NEW.depth != parent_rec.depth + 1 THEN
                RAISE EXCEPTION 'Location depth must be parent depth + 1';
            END IF;
        END IF;
    END IF;
    
    -- Build materialized path (using IDs)
    IF parent_path = '' OR parent_path IS NULL THEN
        NEW.path := NEW.id::TEXT;
    ELSE
        NEW.path := parent_path || '.' || NEW.id::TEXT;
    END IF;
    
    -- Build path_ids array
    NEW.path_ids := parent_path_ids || NEW.id;
    
    -- Build search_text (concatenate all parent names)
    IF parent_search = '' OR parent_search IS NULL THEN
        NEW.search_text := NEW.name;
    ELSE
        NEW.search_text := parent_search || ' / ' || NEW.name;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER location_hierarchy_trigger
    BEFORE INSERT OR UPDATE ON locations
    FOR EACH ROW
    EXECUTE FUNCTION update_location_hierarchy();

-- Function to update children when parent location changes
CREATE OR REPLACE FUNCTION update_location_children()
RETURNS TRIGGER AS $$
BEGIN
    -- If name or path changed, update all children recursively
    IF OLD.name != NEW.name OR OLD.path != NEW.path THEN
        UPDATE locations
        SET db_updated_at = NOW()  -- This will trigger the hierarchy update
        WHERE parent_id = NEW.id;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER location_children_trigger
    AFTER UPDATE ON locations
    FOR EACH ROW
    WHEN (OLD.name IS DISTINCT FROM NEW.name OR OLD.path IS DISTINCT FROM NEW.path)
    EXECUTE FUNCTION update_location_children();

-- =====================================
-- 3. COST GROUP HIERARCHY MAINTENANCE
-- =====================================

-- Function to build cost group path
CREATE OR REPLACE FUNCTION update_cost_group_path()
RETURNS TRIGGER AS $$
DECLARE
    parent_path TEXT := '';
BEGIN
    -- If has parent, get parent's path
    IF NEW.parent_id IS NOT NULL THEN
        SELECT path INTO parent_path
        FROM cost_groups
        WHERE id = NEW.parent_id;
    END IF;
    
    -- Build materialized path using code (cast to text)
    IF parent_path = '' OR parent_path IS NULL THEN
        NEW.path := NEW.code::TEXT;
    ELSE
        NEW.path := parent_path || '.' || NEW.code::TEXT;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER cost_group_path_trigger
    BEFORE INSERT OR UPDATE ON cost_groups
    FOR EACH ROW
    EXECUTE FUNCTION update_cost_group_path();

-- =====================================
-- 4. TASK TYPE EXTRACTION
-- =====================================

-- Core function: Extract task type for a single task based on rules
CREATE OR REPLACE FUNCTION extract_task_type(p_task_id INTEGER)
RETURNS void AS $$
DECLARE
    v_matched_type_id UUID;
    v_matched_tag_name TEXT;
    v_default_type_id UUID;
BEGIN
    -- Find the first matching task type based on task's tags
    SELECT ttr.task_type_id, ttr.teamwork_tag_name
    INTO v_matched_type_id, v_matched_tag_name
    FROM teamwork.task_tags tt
    JOIN teamwork.tags t ON tt.tag_id = t.id
    JOIN task_type_rules ttr ON LOWER(t.name) = LOWER(ttr.teamwork_tag_name)
    WHERE tt.task_id = p_task_id
    LIMIT 1;  -- First match wins (match any)

    -- If no match, get the default type
    IF v_matched_type_id IS NULL THEN
        SELECT id INTO v_default_type_id
        FROM task_types
        WHERE is_default = TRUE
        LIMIT 1;
        
        v_matched_type_id := v_default_type_id;
        v_matched_tag_name := NULL;
    END IF;

    -- Upsert task extension with the type
    INSERT INTO task_extensions (tw_task_id, task_type_id, type_source, type_source_tag_name)
    VALUES (p_task_id, v_matched_type_id, 'auto', v_matched_tag_name)
    ON CONFLICT (tw_task_id) DO UPDATE SET
        task_type_id = EXCLUDED.task_type_id,
        type_source = 'auto',
        type_source_tag_name = EXCLUDED.type_source_tag_name,
        db_updated_at = NOW()
    -- Only update if currently auto (don't override manual assignments)
    WHERE task_extensions.type_source = 'auto' OR task_extensions.type_source IS NULL;
END;
$$ LANGUAGE plpgsql;

-- Trigger function: Called on task insert/update
CREATE OR REPLACE FUNCTION trigger_extract_task_type()
RETURNS TRIGGER AS $$
BEGIN
    -- Extract type for the new/updated task
    PERFORM extract_task_type(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger function: Called when task_tags are modified
CREATE OR REPLACE FUNCTION trigger_task_tags_extract_type()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM extract_task_type(OLD.task_id);
        RETURN OLD;
    ELSE
        PERFORM extract_task_type(NEW.task_id);
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Create triggers for automatic extraction
CREATE TRIGGER extract_task_type_on_task_change
    AFTER INSERT OR UPDATE ON teamwork.tasks
    FOR EACH ROW
    EXECUTE FUNCTION trigger_extract_task_type();

CREATE TRIGGER extract_task_type_on_tags_change
    AFTER INSERT OR UPDATE OR DELETE ON teamwork.task_tags
    FOR EACH ROW
    EXECUTE FUNCTION trigger_task_tags_extract_type();

-- =====================================
-- 5. BULK RE-EXTRACTION FUNCTIONS (for UI button)
-- =====================================

-- Main function to re-run extraction on all tasks
CREATE OR REPLACE FUNCTION rerun_all_task_type_extractions()
RETURNS UUID 
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_run_id UUID;
    v_total_count INTEGER;
    v_processed INTEGER := 0;
    v_task_record RECORD;
BEGIN
    INSERT INTO operation_runs (run_type, status, started_at)
    VALUES ('task_type_extraction', 'running', NOW())
    RETURNING id INTO v_run_id;

    SELECT COUNT(*) INTO v_total_count FROM teamwork.tasks WHERE deleted_at IS NULL;
    UPDATE operation_runs SET total_count = v_total_count WHERE id = v_run_id;

    FOR v_task_record IN SELECT id FROM teamwork.tasks WHERE deleted_at IS NULL LOOP
        BEGIN
            PERFORM extract_task_type(v_task_record.id);
            v_processed := v_processed + 1;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error processing task %: %', v_task_record.id, SQLERRM;
        END;
    END LOOP;

    UPDATE operation_runs SET status = 'completed', processed_count = v_processed, completed_at = NOW()
    WHERE id = v_run_id;
    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

-- Generic function to get operation run status by ID
CREATE OR REPLACE FUNCTION get_operation_run_status(p_run_id UUID)
RETURNS TABLE (
    id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT
)
SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY SELECT r.id, r.status, r.total_count, r.processed_count,
        r.created_count, r.linked_count, r.skipped_count,
        CASE WHEN r.total_count > 0 THEN ROUND((r.processed_count::NUMERIC / r.total_count::NUMERIC) * 100, 1) ELSE 0 END,
        r.started_at, r.completed_at, r.error_message
    FROM operation_runs r WHERE r.id = p_run_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- Generic function to get latest operation run by type
CREATE OR REPLACE FUNCTION get_latest_operation_run(p_run_type VARCHAR(50))
RETURNS TABLE (
    id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT
)
SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY SELECT r.id, r.status, r.total_count, r.processed_count,
        r.created_count, r.linked_count, r.skipped_count,
        CASE WHEN r.total_count > 0 THEN ROUND((r.processed_count::NUMERIC / r.total_count::NUMERIC) * 100, 1) ELSE 0 END,
        r.started_at, r.completed_at, r.error_message
    FROM operation_runs r WHERE r.run_type = p_run_type ORDER BY r.started_at DESC LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

-- Wrapper for backwards compatibility
CREATE OR REPLACE FUNCTION get_extraction_run_status(p_run_id UUID)
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY SELECT r.id, r.status, r.total_count, r.processed_count,
        CASE WHEN r.total_count > 0 THEN ROUND((r.processed_count::NUMERIC / r.total_count::NUMERIC) * 100, 1) ELSE 0 END,
        r.started_at, r.completed_at, r.error_message
    FROM operation_runs r WHERE r.id = p_run_id;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_latest_extraction_run()
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY SELECT r.id, r.status, r.total_count, r.processed_count,
        CASE WHEN r.total_count > 0 THEN ROUND((r.processed_count::NUMERIC / r.total_count::NUMERIC) * 100, 1) ELSE 0 END,
        r.started_at, r.completed_at, r.error_message
    FROM operation_runs r WHERE r.run_type = 'task_type_extraction' ORDER BY r.started_at DESC LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

-- Add trigger for task_types table updates
CREATE TRIGGER update_task_types_updated_at BEFORE UPDATE ON task_types
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =====================================
-- 6. COST GROUP EXTRACTION
-- =====================================

-- Helper function to get or create a cost group with proper parent hierarchy
CREATE OR REPLACE FUNCTION get_or_create_cost_group(p_code INTEGER, p_name TEXT)
RETURNS UUID AS $$
DECLARE
    v_cost_group_id UUID;
    v_parent_code INTEGER;
    v_parent_id UUID;
BEGIN
    -- Check if cost group already exists
    SELECT id INTO v_cost_group_id FROM cost_groups WHERE code = p_code;
    IF FOUND THEN
        RETURN v_cost_group_id;
    END IF;
    
    -- Determine parent code based on DIN 276 structure
    -- 456 -> 450, 450 -> 400, 400 -> NULL
    IF p_code % 10 != 0 THEN
        -- Has single digit, parent is tens (456 -> 450)
        v_parent_code := (p_code / 10) * 10;
    ELSIF p_code % 100 != 0 THEN
        -- Has tens digit but no singles, parent is hundreds (450 -> 400)
        v_parent_code := (p_code / 100) * 100;
    ELSE
        -- Is a hundred (400), no parent
        v_parent_code := NULL;
    END IF;
    
    -- Recursively create parent if needed
    IF v_parent_code IS NOT NULL THEN
        v_parent_id := get_or_create_cost_group(v_parent_code, NULL);
    END IF;
    
    -- Create the cost group
    INSERT INTO cost_groups (code, name, parent_id)
    VALUES (p_code, p_name, v_parent_id)
    RETURNING id INTO v_cost_group_id;
    
    RETURN v_cost_group_id;
END;
$$ LANGUAGE plpgsql;

-- Function to parse cost group from tag name
-- Returns NULL if tag doesn't match pattern, otherwise returns (code, name)
CREATE OR REPLACE FUNCTION parse_cost_group_tag(p_tag_name TEXT, p_prefixes TEXT[])
RETURNS TABLE(code INTEGER, name TEXT) AS $$
DECLARE
    v_prefix TEXT;
    v_pattern TEXT;
    v_match TEXT[];
BEGIN
    FOREACH v_prefix IN ARRAY p_prefixes LOOP
        -- Pattern: PREFIX + spaces + 3-digit code + spaces + name
        -- Example: "KGR 456 Demo Kostengruppe" or "KGR456Demo"
        v_pattern := '^' || v_prefix || '\s*(\d{3})\s*(.*)$';
        v_match := regexp_match(p_tag_name, v_pattern, 'i');
        IF v_match IS NOT NULL THEN
            code := v_match[1]::INTEGER;
            name := NULLIF(TRIM(v_match[2]), '');
            RETURN NEXT;
            RETURN;
        END IF;
    END LOOP;
    RETURN;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Extract cost groups for a single task
CREATE OR REPLACE FUNCTION extract_cost_groups_for_task(p_task_id INTEGER)
RETURNS void AS $$
DECLARE
    v_prefixes TEXT[];
    v_tag_record RECORD;
    v_parsed RECORD;
    v_cost_group_id UUID;
BEGIN
    -- Get prefixes from app_settings
    SELECT COALESCE(
        (SELECT ARRAY(SELECT jsonb_array_elements_text(body->'cost_group_prefixes')) 
         FROM app_settings WHERE lock = 'X'),
        ARRAY['KGR']
    ) INTO v_prefixes;
    
    -- Delete existing auto-linked cost groups for this task
    DELETE FROM object_cost_groups 
    WHERE tw_task_id = p_task_id AND source = 'auto_teamwork';
    
    -- Process each tag on the task
    FOR v_tag_record IN 
        SELECT t.name AS tag_name
        FROM teamwork.task_tags tt
        JOIN teamwork.tags t ON tt.tag_id = t.id
        WHERE tt.task_id = p_task_id
    LOOP
        -- Try to parse as cost group tag
        SELECT * INTO v_parsed FROM parse_cost_group_tag(v_tag_record.tag_name, v_prefixes);
        
        IF v_parsed.code IS NOT NULL THEN
            -- Get or create the cost group
            v_cost_group_id := get_or_create_cost_group(v_parsed.code, v_parsed.name);
            
            -- Link task to cost group (ignore if already exists)
            INSERT INTO object_cost_groups (cost_group_id, tw_task_id, source, source_tag_name)
            VALUES (v_cost_group_id, p_task_id, 'auto_teamwork', v_tag_record.tag_name)
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Extract cost groups for a single conversation (from labels)
CREATE OR REPLACE FUNCTION extract_cost_groups_for_conversation(p_conversation_id UUID)
RETURNS void AS $$
DECLARE
    v_prefixes TEXT[];
    v_label_record RECORD;
    v_parsed RECORD;
    v_cost_group_id UUID;
BEGIN
    -- Get prefixes from app_settings
    SELECT COALESCE(
        (SELECT ARRAY(SELECT jsonb_array_elements_text(body->'cost_group_prefixes')) 
         FROM app_settings WHERE lock = 'X'),
        ARRAY['KGR']
    ) INTO v_prefixes;
    
    -- Delete existing auto-linked cost groups for this conversation
    DELETE FROM object_cost_groups 
    WHERE m_conversation_id = p_conversation_id AND source = 'auto_missive';
    
    -- Process each label on the conversation
    FOR v_label_record IN 
        SELECT sl.name AS label_name
        FROM missive.conversation_labels cl
        JOIN missive.shared_labels sl ON cl.label_id = sl.id
        WHERE cl.conversation_id = p_conversation_id
    LOOP
        -- Try to parse as cost group label
        SELECT * INTO v_parsed FROM parse_cost_group_tag(v_label_record.label_name, v_prefixes);
        
        IF v_parsed.code IS NOT NULL THEN
            -- Get or create the cost group
            v_cost_group_id := get_or_create_cost_group(v_parsed.code, v_parsed.name);
            
            -- Link conversation to cost group (ignore if already exists)
            INSERT INTO object_cost_groups (cost_group_id, m_conversation_id, source, source_tag_name)
            VALUES (v_cost_group_id, p_conversation_id, 'auto_missive', v_label_record.label_name)
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Bulk re-run cost group extraction for all tasks and conversations
CREATE OR REPLACE FUNCTION rerun_all_cost_group_linking()
RETURNS UUID 
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_run_id UUID;
    v_task_count INTEGER;
    v_conv_count INTEGER;
    v_total_count INTEGER;
    v_processed INTEGER := 0;
    v_created INTEGER := 0;
    v_linked INTEGER := 0;
    v_record RECORD;
    v_initial_cg_count INTEGER;
    v_initial_link_count INTEGER;
    v_final_cg_count INTEGER;
    v_final_link_count INTEGER;
BEGIN
    -- Create run record
    INSERT INTO operation_runs (run_type, status, started_at)
    VALUES ('cost_group_linking', 'running', NOW())
    RETURNING id INTO v_run_id;

    -- Count totals
    SELECT COUNT(*) INTO v_task_count FROM teamwork.tasks WHERE deleted_at IS NULL;
    SELECT COUNT(*) INTO v_conv_count FROM missive.conversations;
    v_total_count := v_task_count + v_conv_count;
    
    UPDATE operation_runs SET total_count = v_total_count WHERE id = v_run_id;
    
    -- Get initial counts for stats
    SELECT COUNT(*) INTO v_initial_cg_count FROM cost_groups;
    SELECT COUNT(*) INTO v_initial_link_count FROM object_cost_groups;

    -- Process all tasks
    FOR v_record IN SELECT id FROM teamwork.tasks WHERE deleted_at IS NULL LOOP
        BEGIN
            PERFORM extract_cost_groups_for_task(v_record.id);
            v_processed := v_processed + 1;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error processing task %: %', v_record.id, SQLERRM;
        END;
    END LOOP;

    -- Process all conversations
    FOR v_record IN SELECT id FROM missive.conversations LOOP
        BEGIN
            PERFORM extract_cost_groups_for_conversation(v_record.id);
            v_processed := v_processed + 1;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error processing conversation %: %', v_record.id, SQLERRM;
        END;
    END LOOP;

    -- Calculate stats
    SELECT COUNT(*) INTO v_final_cg_count FROM cost_groups;
    SELECT COUNT(*) INTO v_final_link_count FROM object_cost_groups;
    v_created := v_final_cg_count - v_initial_cg_count;
    v_linked := v_final_link_count - v_initial_link_count;

    -- Complete the run
    UPDATE operation_runs SET 
        status = 'completed', 
        processed_count = v_processed,
        created_count = v_created,
        linked_count = v_linked,
        completed_at = NOW()
    WHERE id = v_run_id;
    
    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

-- Status functions for cost group linking
CREATE OR REPLACE FUNCTION get_cost_group_linking_run_status(p_run_id UUID)
RETURNS TABLE (
    id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT
)
SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY SELECT * FROM get_operation_run_status(p_run_id);
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_latest_cost_group_linking_run()
RETURNS TABLE (
    id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT
)
SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY SELECT * FROM get_latest_operation_run('cost_group_linking');
END;
$$ LANGUAGE plpgsql STABLE;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON FUNCTION update_updated_at_column() IS 'Generic trigger function to update db_updated_at timestamp';
COMMENT ON FUNCTION update_location_hierarchy() IS 'Maintains materialized path and search_text for location hierarchy';
COMMENT ON FUNCTION update_cost_group_path() IS 'Maintains materialized path for cost group hierarchy';
COMMENT ON FUNCTION extract_task_type(INTEGER) IS 'Extracts and assigns task type based on tag matching rules';
COMMENT ON FUNCTION rerun_all_task_type_extractions() IS 'Re-runs task type extraction on all tasks, returns run ID for tracking';
COMMENT ON FUNCTION get_extraction_run_status(UUID) IS 'Gets status of an extraction run by ID';
COMMENT ON FUNCTION get_latest_extraction_run() IS 'Gets the most recent extraction run status';
COMMENT ON FUNCTION get_or_create_cost_group(INTEGER, TEXT) IS 'Gets existing or creates new cost group with proper parent hierarchy (DIN 276)';
COMMENT ON FUNCTION parse_cost_group_tag(TEXT, TEXT[]) IS 'Parses tag name for cost group pattern (PREFIX CODE NAME)';
COMMENT ON FUNCTION extract_cost_groups_for_task(INTEGER) IS 'Extracts and links cost groups from task tags';
COMMENT ON FUNCTION extract_cost_groups_for_conversation(UUID) IS 'Extracts and links cost groups from conversation labels';
COMMENT ON FUNCTION rerun_all_cost_group_linking() IS 'Re-runs cost group extraction on all tasks and conversations';