-- =====================================
-- AUTOCOMPLETE SEARCH FUNCTIONS
-- =====================================
-- Functions for live autocomplete suggestions for projects and persons

-- =====================================
-- 1. PROJECT AUTOCOMPLETE SEARCH
-- =====================================

-- Returns project suggestions matching a search term
-- Searches in: project name, company name, description
CREATE OR REPLACE FUNCTION search_projects_autocomplete(
    p_search_text TEXT,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE(
    id INTEGER,
    name TEXT,
    company_name TEXT,
    status VARCHAR
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_search_pattern TEXT;
BEGIN
    -- Handle empty search
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        -- Return most recent/active projects when no search term
        RETURN QUERY
        SELECT 
            p.id,
            p.name::TEXT,
            c.name::TEXT AS company_name,
            p.status
        FROM teamwork.projects p
        LEFT JOIN teamwork.companies c ON p.company_id = c.id
        ORDER BY p.updated_at DESC NULLS LAST, p.name ASC
        LIMIT p_limit;
        RETURN;
    END IF;
    
    -- Create case-insensitive search pattern
    v_search_pattern := '%' || LOWER(p_search_text) || '%';
    
    RETURN QUERY
    SELECT 
        p.id,
        p.name::TEXT,
        c.name::TEXT AS company_name,
        p.status
    FROM teamwork.projects p
    LEFT JOIN teamwork.companies c ON p.company_id = c.id
    WHERE 
        LOWER(p.name) LIKE v_search_pattern
        OR LOWER(c.name) LIKE v_search_pattern
        OR LOWER(p.description) LIKE v_search_pattern
    ORDER BY 
        -- Prioritize exact matches at start of name
        CASE WHEN LOWER(p.name) LIKE LOWER(p_search_text) || '%' THEN 0 ELSE 1 END,
        -- Then by status (active first)
        CASE p.status WHEN 'active' THEN 0 ELSE 1 END,
        -- Then alphabetically
        p.name ASC
    LIMIT p_limit;
END;
$$;

-- =====================================
-- 2. PERSON AUTOCOMPLETE SEARCH
-- =====================================

-- Returns person suggestions matching a search term
-- Searches across: unified_persons, teamwork users/companies, missive contacts
CREATE OR REPLACE FUNCTION search_persons_autocomplete(
    p_search_text TEXT,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE(
    id UUID,
    display_name TEXT,
    primary_email TEXT,
    source_type TEXT,
    is_internal BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_search_pattern TEXT;
BEGIN
    -- Handle empty search
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        -- Return most recent persons when no search term
        RETURN QUERY
        SELECT 
            up.id,
            up.display_name::TEXT,
            up.primary_email::TEXT,
            'unified'::TEXT AS source_type,
            up.is_internal
        FROM unified_persons up
        ORDER BY up.db_updated_at DESC NULLS LAST, up.display_name ASC
        LIMIT p_limit;
        RETURN;
    END IF;
    
    -- Create case-insensitive search pattern
    v_search_pattern := '%' || LOWER(p_search_text) || '%';
    
    RETURN QUERY
    SELECT DISTINCT ON (up.id)
        up.id,
        up.display_name::TEXT,
        up.primary_email::TEXT,
        CASE 
            WHEN upl.tw_user_id IS NOT NULL THEN 'teamwork_user'
            WHEN upl.tw_company_id IS NOT NULL THEN 'teamwork_company'
            WHEN upl.m_contact_id IS NOT NULL THEN 'missive_contact'
            ELSE 'unified'
        END::TEXT AS source_type,
        up.is_internal
    FROM unified_persons up
    LEFT JOIN unified_person_links upl ON up.id = upl.unified_person_id
    LEFT JOIN teamwork.users twu ON upl.tw_user_id = twu.id
    LEFT JOIN teamwork.companies twc ON upl.tw_company_id = twc.id
    LEFT JOIN missive.contacts mc ON upl.m_contact_id = mc.id
    WHERE 
        -- Match unified person directly
        LOWER(up.display_name) LIKE v_search_pattern
        OR LOWER(up.primary_email) LIKE v_search_pattern
        -- Match linked Teamwork user
        OR LOWER(twu.first_name) LIKE v_search_pattern
        OR LOWER(twu.last_name) LIKE v_search_pattern
        OR LOWER(twu.email) LIKE v_search_pattern
        OR LOWER(COALESCE(twu.first_name, '') || ' ' || COALESCE(twu.last_name, '')) LIKE v_search_pattern
        -- Match linked Teamwork company
        OR LOWER(twc.name) LIKE v_search_pattern
        OR LOWER(twc.email_one) LIKE v_search_pattern
        -- Match linked Missive contact
        OR LOWER(mc.name) LIKE v_search_pattern
        OR LOWER(mc.email) LIKE v_search_pattern
    ORDER BY 
        up.id,
        -- Prioritize exact matches at start
        CASE WHEN LOWER(up.display_name) LIKE LOWER(p_search_text) || '%' THEN 0 ELSE 1 END,
        -- Internal users first
        CASE WHEN up.is_internal THEN 0 ELSE 1 END,
        -- Then alphabetically
        up.display_name ASC
    LIMIT p_limit;
END;
$$;

-- =====================================
-- 3. COST GROUP AUTOCOMPLETE SEARCH
-- =====================================

-- Returns cost group suggestions matching a search term
-- Supports hierarchical filtering: 400 matches 4xx, 450 matches 45x, 456 matches exactly
CREATE OR REPLACE FUNCTION search_cost_groups_autocomplete(
    p_search_text TEXT,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE(
    id UUID,
    code INTEGER,
    name TEXT,
    path TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_search_code INTEGER;
    v_code_min INTEGER;
    v_code_max INTEGER;
BEGIN
    -- Handle empty search - return most common/recent cost groups
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        RETURN QUERY
        SELECT 
            cg.id,
            cg.code,
            cg.name::TEXT,
            cg.path::TEXT
        FROM cost_groups cg
        ORDER BY cg.code ASC
        LIMIT p_limit;
        RETURN;
    END IF;
    
    -- Try to parse as code for hierarchical search
    BEGIN
        v_search_code := TRIM(p_search_text)::INTEGER;
        
        -- Determine range based on entered digits
        IF v_search_code >= 100 AND v_search_code <= 999 THEN
            -- Full 3-digit code - exact match
            v_code_min := v_search_code;
            v_code_max := v_search_code;
        ELSIF v_search_code >= 10 AND v_search_code <= 99 THEN
            -- 2-digit code - match all in that range (45 -> 450-459)
            v_code_min := v_search_code * 10;
            v_code_max := v_search_code * 10 + 9;
        ELSIF v_search_code >= 1 AND v_search_code <= 9 THEN
            -- 1-digit code - match all in that range (4 -> 400-499)
            v_code_min := v_search_code * 100;
            v_code_max := v_search_code * 100 + 99;
        ELSE
            v_search_code := NULL;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_search_code := NULL;
    END;
    
    -- If valid code range, search by code
    IF v_search_code IS NOT NULL THEN
        RETURN QUERY
        SELECT 
            cg.id,
            cg.code,
            cg.name::TEXT,
            cg.path::TEXT
        FROM cost_groups cg
        WHERE cg.code >= v_code_min AND cg.code <= v_code_max
        ORDER BY cg.code ASC
        LIMIT p_limit;
    ELSE
        -- Search by name
        RETURN QUERY
        SELECT 
            cg.id,
            cg.code,
            cg.name::TEXT,
            cg.path::TEXT
        FROM cost_groups cg
        WHERE LOWER(cg.name) LIKE '%' || LOWER(p_search_text) || '%'
        ORDER BY 
            -- Prioritize matches at start of name
            CASE WHEN LOWER(cg.name) LIKE LOWER(p_search_text) || '%' THEN 0 ELSE 1 END,
            cg.code ASC
        LIMIT p_limit;
    END IF;
END;
$$;

-- =====================================
-- 4. TAG AUTOCOMPLETE SEARCH
-- =====================================

-- Returns tag suggestions matching a search term
-- Searches across teamwork.tags and missive.shared_labels (deduplicated by name)
CREATE OR REPLACE FUNCTION search_tags_autocomplete(
    p_search_text TEXT,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE(
    id TEXT,
    name TEXT,
    color TEXT,
    source TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_search_pattern TEXT;
BEGIN
    -- Handle empty search - return most used tags
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        RETURN QUERY
        WITH combined_tags AS (
            -- Teamwork tags with usage count
            SELECT 
                'tw_' || t.id::TEXT AS id,
                t.name::TEXT AS name,
                t.color::TEXT AS color,
                'teamwork'::TEXT AS source,
                (SELECT COUNT(*) FROM teamwork.task_tags tt WHERE tt.tag_id = t.id) AS usage_count
            FROM teamwork.tags t
            
            UNION ALL
            
            -- Missive labels with usage count
            SELECT 
                'm_' || sl.id::TEXT AS id,
                sl.name::TEXT AS name,
                NULL::TEXT AS color,
                'missive'::TEXT AS source,
                (SELECT COUNT(*) FROM missive.conversation_labels cl WHERE cl.label_id = sl.id) AS usage_count
            FROM missive.shared_labels sl
        )
        SELECT DISTINCT ON (LOWER(ct.name))
            ct.id,
            ct.name,
            ct.color,
            ct.source
        FROM combined_tags ct
        ORDER BY LOWER(ct.name), ct.usage_count DESC
        LIMIT p_limit;
        RETURN;
    END IF;
    
    -- Create case-insensitive search pattern
    v_search_pattern := '%' || LOWER(p_search_text) || '%';
    
    RETURN QUERY
    WITH combined_tags AS (
        -- Teamwork tags
        SELECT 
            'tw_' || t.id::TEXT AS id,
            t.name::TEXT AS name,
            t.color::TEXT AS color,
            'teamwork'::TEXT AS source
        FROM teamwork.tags t
        WHERE LOWER(t.name) LIKE v_search_pattern
        
        UNION ALL
        
        -- Missive labels
        SELECT 
            'm_' || sl.id::TEXT AS id,
            sl.name::TEXT AS name,
            NULL::TEXT AS color,
            'missive'::TEXT AS source
        FROM missive.shared_labels sl
        WHERE LOWER(sl.name) LIKE v_search_pattern
    )
    SELECT DISTINCT ON (LOWER(ct.name))
        ct.id,
        ct.name,
        ct.color,
        ct.source
    FROM combined_tags ct
    ORDER BY 
        LOWER(ct.name),
        -- Prioritize exact matches at start
        CASE WHEN LOWER(ct.name) LIKE LOWER(p_search_text) || '%' THEN 0 ELSE 1 END
    LIMIT p_limit;
END;
$$;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON FUNCTION search_projects_autocomplete(TEXT, INTEGER) IS 
    'Returns project suggestions for autocomplete, matching name, company, or description';

COMMENT ON FUNCTION search_persons_autocomplete(TEXT, INTEGER) IS 
    'Returns person suggestions for autocomplete, searching across all linked entities';

COMMENT ON FUNCTION search_cost_groups_autocomplete(TEXT, INTEGER) IS 
    'Returns cost group suggestions with hierarchical code matching (400 matches 4xx, 450 matches 45x)';

COMMENT ON FUNCTION search_tags_autocomplete(TEXT, INTEGER) IS 
    'Returns tag suggestions for autocomplete, searching across teamwork tags and missive labels';

