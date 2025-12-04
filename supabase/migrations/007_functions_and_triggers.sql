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
    
    -- Build materialized path using code
    IF parent_path = '' OR parent_path IS NULL THEN
        NEW.path := NEW.code;
    ELSE
        NEW.path := parent_path || '.' || NEW.code;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER cost_group_path_trigger
    BEFORE INSERT OR UPDATE ON cost_groups
    FOR EACH ROW
    EXECUTE FUNCTION update_cost_group_path();

-- =====================================
-- 4. FUZZY LOCATION SEARCH FUNCTION
-- =====================================

-- Function for typo-resistant, multi-level location search
-- Implements requirements from additional_requirements_unstructured.md
CREATE OR REPLACE FUNCTION search_locations(
    search_query TEXT,
    match_threshold FLOAT DEFAULT 0.3
)
RETURNS TABLE (
    location_id UUID,
    location_name TEXT,
    location_type location_type,
    full_path TEXT,
    similarity_score FLOAT,
    exact_match BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        l.id AS location_id,
        l.name AS location_name,
        l.type AS location_type,
        l.search_text AS full_path,
        GREATEST(
            similarity(l.name, search_query),
            similarity(l.search_text, search_query)
        ) AS similarity_score,
        (
            l.name ILIKE '%' || search_query || '%' OR
            l.search_text ILIKE '%' || search_query || '%'
        ) AS exact_match
    FROM locations l
    WHERE 
        -- Trigram similarity match
        (
            similarity(l.name, search_query) > match_threshold OR
            similarity(l.search_text, search_query) > match_threshold
        )
        OR
        -- Exact substring match (for autocomplete)
        (
            l.name ILIKE '%' || search_query || '%' OR
            l.search_text ILIKE '%' || search_query || '%'
        )
    ORDER BY
        -- Prioritize: exact matches first, then by similarity, then by depth (specific first)
        exact_match DESC,
        similarity_score DESC,
        l.depth DESC,
        l.name ASC
    LIMIT 50;
END;
$$ LANGUAGE plpgsql STABLE;

-- =====================================
-- 5. UNIFIED SEARCH FUNCTION
-- =====================================

-- Function to search across all objects (files, tasks, conversations)
CREATE OR REPLACE FUNCTION search_all_objects(
    search_query TEXT,
    filter_project_id INTEGER DEFAULT NULL,
    filter_location_id UUID DEFAULT NULL,
    filter_cost_group_id UUID DEFAULT NULL,
    limit_results INTEGER DEFAULT 50
)
RETURNS TABLE (
    object_id TEXT,
    object_type TEXT,
    name TEXT,
    description TEXT,
    project_name TEXT,
    location_name TEXT,
    cost_group_name TEXT,
    relevance FLOAT
) AS $$
BEGIN
    RETURN QUERY
    WITH ranked_files AS (
        SELECT 
            f.id::TEXT AS object_id,
            'file'::TEXT AS object_type,
            f.filename AS name,
            COALESCE(f.extracted_text, '') AS description,
            p.name AS project_name,
            l.search_text AS location_name,
            cg.name AS cost_group_name,
            ts_rank(
                to_tsvector('german', COALESCE(f.filename || ' ' || f.extracted_text, '')),
                plainto_tsquery('german', search_query)
            ) AS relevance
        FROM files f
        LEFT JOIN project_files pf ON f.id = pf.file_id
        LEFT JOIN teamwork.projects p ON pf.tw_project_id = p.id
        LEFT JOIN object_locations ol ON f.id = ol.file_id
        LEFT JOIN locations l ON ol.location_id = l.id
        LEFT JOIN object_cost_groups ocg ON f.id = ocg.file_id
        LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id
        WHERE 
            (filter_project_id IS NULL OR p.id = filter_project_id)
            AND (filter_location_id IS NULL OR l.id = filter_location_id)
            AND (filter_cost_group_id IS NULL OR cg.id = filter_cost_group_id)
            AND to_tsvector('german', COALESCE(f.filename || ' ' || f.extracted_text, '')) @@ plainto_tsquery('german', search_query)
    ),
    ranked_tasks AS (
        SELECT 
            t.id::TEXT AS object_id,
            'task'::TEXT AS object_type,
            t.name AS name,
            COALESCE(t.description, '') AS description,
            p.name AS project_name,
            l.search_text AS location_name,
            cg.name AS cost_group_name,
            ts_rank(
                to_tsvector('german', COALESCE(t.name || ' ' || t.description, '')),
                plainto_tsquery('german', search_query)
            ) AS relevance
        FROM teamwork.tasks t
        LEFT JOIN teamwork.projects p ON t.project_id = p.id
        LEFT JOIN object_locations ol ON t.id = ol.tw_task_id
        LEFT JOIN locations l ON ol.location_id = l.id
        LEFT JOIN object_cost_groups ocg ON t.id = ocg.tw_task_id
        LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id
        WHERE 
            t.deleted_at IS NULL
            AND (filter_project_id IS NULL OR p.id = filter_project_id)
            AND (filter_location_id IS NULL OR l.id = filter_location_id)
            AND (filter_cost_group_id IS NULL OR cg.id = filter_cost_group_id)
            AND to_tsvector('german', COALESCE(t.name || ' ' || t.description, '')) @@ plainto_tsquery('german', search_query)
    ),
    ranked_conversations AS (
        SELECT 
            c.id::TEXT AS object_id,
            'conversation'::TEXT AS object_type,
            c.subject AS name,
            COALESCE(c.latest_message_subject, '') AS description,
            p.name AS project_name,
            l.search_text AS location_name,
            cg.name AS cost_group_name,
            ts_rank(
                to_tsvector('german', COALESCE(c.subject || ' ' || c.latest_message_subject, '')),
                plainto_tsquery('german', search_query)
            ) AS relevance
        FROM missive.conversations c
        LEFT JOIN project_conversations pc ON c.id = pc.m_conversation_id
        LEFT JOIN teamwork.projects p ON pc.tw_project_id = p.id
        LEFT JOIN object_locations ol ON c.id = ol.m_conversation_id
        LEFT JOIN locations l ON ol.location_id = l.id
        LEFT JOIN object_cost_groups ocg ON c.id = ocg.m_conversation_id
        LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id
        WHERE 
            (filter_project_id IS NULL OR p.id = filter_project_id)
            AND (filter_location_id IS NULL OR l.id = filter_location_id)
            AND (filter_cost_group_id IS NULL OR cg.id = filter_cost_group_id)
            AND to_tsvector('german', COALESCE(c.subject || ' ' || c.latest_message_subject, '')) @@ plainto_tsquery('german', search_query)
    )
    SELECT * FROM (
        SELECT * FROM ranked_files
        UNION ALL
        SELECT * FROM ranked_tasks
        UNION ALL
        SELECT * FROM ranked_conversations
    ) combined
    ORDER BY relevance DESC
    LIMIT limit_results;
END;
$$ LANGUAGE plpgsql STABLE;

-- =====================================
-- 6. TASK TYPE EXTRACTION
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
-- 7. BULK RE-EXTRACTION FUNCTIONS (for UI button)
-- =====================================

-- Main function to re-run extraction on all tasks
-- Returns the extraction_run ID for status tracking
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
    -- Create a new run record
    INSERT INTO extraction_runs (status, started_at)
    VALUES ('running', NOW())
    RETURNING id INTO v_run_id;

    -- Count total tasks
    SELECT COUNT(*) INTO v_total_count
    FROM teamwork.tasks
    WHERE deleted_at IS NULL;

    -- Update total count
    UPDATE extraction_runs SET total_count = v_total_count WHERE id = v_run_id;

    -- Loop through all tasks and extract types
    FOR v_task_record IN 
        SELECT id FROM teamwork.tasks WHERE deleted_at IS NULL
    LOOP
        BEGIN
            PERFORM extract_task_type(v_task_record.id);
            v_processed := v_processed + 1;
            
            -- Update progress every 100 tasks
            IF v_processed % 100 = 0 THEN
                UPDATE extraction_runs 
                SET processed_count = v_processed 
                WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Log error but continue processing
            RAISE NOTICE 'Error processing task %: %', v_task_record.id, SQLERRM;
        END;
    END LOOP;

    -- Mark as completed
    UPDATE extraction_runs 
    SET 
        status = 'completed',
        processed_count = v_processed,
        completed_at = NOW()
    WHERE id = v_run_id;

    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

-- Function to check extraction run status
CREATE OR REPLACE FUNCTION get_extraction_run_status(p_run_id UUID)
RETURNS TABLE (
    id UUID,
    status VARCHAR(50),
    total_count INTEGER,
    processed_count INTEGER,
    progress_percent NUMERIC,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    error_message TEXT
)
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        er.id,
        er.status,
        er.total_count,
        er.processed_count,
        CASE 
            WHEN er.total_count > 0 THEN 
                ROUND((er.processed_count::NUMERIC / er.total_count::NUMERIC) * 100, 1)
            ELSE 0
        END AS progress_percent,
        er.started_at,
        er.completed_at,
        er.error_message
    FROM extraction_runs er
    WHERE er.id = p_run_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- Function to get the latest extraction run
CREATE OR REPLACE FUNCTION get_latest_extraction_run()
RETURNS TABLE (
    id UUID,
    status VARCHAR(50),
    total_count INTEGER,
    processed_count INTEGER,
    progress_percent NUMERIC,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    error_message TEXT
)
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        er.id,
        er.status,
        er.total_count,
        er.processed_count,
        CASE 
            WHEN er.total_count > 0 THEN 
                ROUND((er.processed_count::NUMERIC / er.total_count::NUMERIC) * 100, 1)
            ELSE 0
        END AS progress_percent,
        er.started_at,
        er.completed_at,
        er.error_message
    FROM extraction_runs er
    ORDER BY er.started_at DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

-- Add trigger for task_types table updates
CREATE TRIGGER update_task_types_updated_at BEFORE UPDATE ON task_types
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON FUNCTION update_updated_at_column() IS 'Generic trigger function to update db_updated_at timestamp';
COMMENT ON FUNCTION update_location_hierarchy() IS 'Maintains materialized path and search_text for location hierarchy';
COMMENT ON FUNCTION update_cost_group_path() IS 'Maintains materialized path for cost group hierarchy';
COMMENT ON FUNCTION search_locations(TEXT, FLOAT) IS 'Typo-resistant location search with similarity scoring';
COMMENT ON FUNCTION search_all_objects(TEXT, INTEGER, UUID, UUID, INTEGER) IS 'Unified full-text search across files, tasks, and conversations';
COMMENT ON FUNCTION extract_task_type(INTEGER) IS 'Extracts and assigns task type based on tag matching rules';
COMMENT ON FUNCTION rerun_all_task_type_extractions() IS 'Re-runs task type extraction on all tasks, returns run ID for tracking';
COMMENT ON FUNCTION get_extraction_run_status(UUID) IS 'Gets status of an extraction run by ID';
COMMENT ON FUNCTION get_latest_extraction_run() IS 'Gets the most recent extraction run status';