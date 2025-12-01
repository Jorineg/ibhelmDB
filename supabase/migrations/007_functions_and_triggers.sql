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
CREATE TRIGGER update_parties_updated_at BEFORE UPDATE ON parties
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_projects_updated_at BEFORE UPDATE ON projects
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
-- 4. PARTIES DISPLAY NAME MAINTENANCE
-- =====================================

-- Function to update display name for a party
CREATE OR REPLACE FUNCTION update_party_display_name()
RETURNS TRIGGER AS $$
DECLARE
    parent_name TEXT;
BEGIN
    -- Get parent name if exists
    IF NEW.parent_party_id IS NOT NULL THEN
        SELECT name_primary INTO parent_name
        FROM parties
        WHERE id = NEW.parent_party_id;
    END IF;
    
    -- Generate display name
    NEW.display_name := CASE 
        WHEN NEW.type = 'company' THEN NEW.name_primary
        WHEN NEW.parent_party_id IS NOT NULL THEN 
            NEW.name_primary || COALESCE(', ' || NEW.name_secondary, '') || 
            ' (' || COALESCE(parent_name, 'Unknown') || ')'
        ELSE NEW.name_primary || COALESCE(', ' || NEW.name_secondary, '')
    END;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to update display name on insert or update
CREATE TRIGGER trigger_update_party_display_name
    BEFORE INSERT OR UPDATE OF name_primary, name_secondary, type, parent_party_id
    ON parties
    FOR EACH ROW
    EXECUTE FUNCTION update_party_display_name();

-- Function to update child party display names when parent name changes
CREATE OR REPLACE FUNCTION update_child_party_display_names()
RETURNS TRIGGER AS $$
BEGIN
    -- Only update children if the parent's name_primary changed
    IF OLD.name_primary IS DISTINCT FROM NEW.name_primary THEN
        UPDATE parties
        SET db_updated_at = NOW()
        WHERE parent_party_id = NEW.id;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to cascade display name updates to children
CREATE TRIGGER trigger_update_child_party_display_names
    AFTER UPDATE OF name_primary
    ON parties
    FOR EACH ROW
    WHEN (OLD.name_primary IS DISTINCT FROM NEW.name_primary)
    EXECUTE FUNCTION update_child_party_display_names();

-- =====================================
-- 5. FUZZY LOCATION SEARCH FUNCTION
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
-- 6. UNIFIED SEARCH FUNCTION
-- =====================================

-- Function to search across all objects (files, tasks, messages)
CREATE OR REPLACE FUNCTION search_all_objects(
    search_query TEXT,
    filter_project_id UUID DEFAULT NULL,
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
        LEFT JOIN projects p ON pf.project_id = p.id
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
            AND (filter_project_id IS NULL OR p.tw_project_id::TEXT = filter_project_id::TEXT)
            AND (filter_location_id IS NULL OR l.id = filter_location_id)
            AND (filter_cost_group_id IS NULL OR cg.id = filter_cost_group_id)
            AND to_tsvector('german', COALESCE(t.name || ' ' || t.description, '')) @@ plainto_tsquery('german', search_query)
    ),
    ranked_messages AS (
        SELECT 
            m.id::TEXT AS object_id,
            'message'::TEXT AS object_type,
            m.subject AS name,
            COALESCE(m.body, '') AS description,
            ''::TEXT AS project_name,
            l.search_text AS location_name,
            cg.name AS cost_group_name,
            ts_rank(
                to_tsvector('german', COALESCE(m.subject || ' ' || m.body, '')),
                plainto_tsquery('german', search_query)
            ) AS relevance
        FROM missive.messages m
        LEFT JOIN object_locations ol ON m.id = ol.m_message_id
        LEFT JOIN locations l ON ol.location_id = l.id
        LEFT JOIN object_cost_groups ocg ON m.id = ocg.m_message_id
        LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id
        WHERE 
            (filter_location_id IS NULL OR l.id = filter_location_id)
            AND (filter_cost_group_id IS NULL OR cg.id = filter_cost_group_id)
            AND to_tsvector('german', COALESCE(m.subject || ' ' || m.body, '')) @@ plainto_tsquery('german', search_query)
    )
    SELECT * FROM (
        SELECT * FROM ranked_files
        UNION ALL
        SELECT * FROM ranked_tasks
        UNION ALL
        SELECT * FROM ranked_messages
    ) combined
    ORDER BY relevance DESC
    LIMIT limit_results;
END;
$$ LANGUAGE plpgsql STABLE;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON FUNCTION update_updated_at_column() IS 'Generic trigger function to update db_updated_at timestamp';
COMMENT ON FUNCTION update_location_hierarchy() IS 'Maintains materialized path and search_text for location hierarchy';
COMMENT ON FUNCTION update_cost_group_path() IS 'Maintains materialized path for cost group hierarchy';
COMMENT ON FUNCTION update_party_display_name() IS 'Maintains display_name for parties based on type and parent';
COMMENT ON FUNCTION update_child_party_display_names() IS 'Cascades display_name updates to child parties when parent name changes';
COMMENT ON FUNCTION search_locations(TEXT, FLOAT) IS 'Typo-resistant location search with similarity scoring';
COMMENT ON FUNCTION search_all_objects(TEXT, UUID, UUID, UUID, INTEGER) IS 'Unified full-text search across files, tasks, and messages';