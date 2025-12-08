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
-- COMMENTS
-- =====================================

COMMENT ON FUNCTION search_projects_autocomplete(TEXT, INTEGER) IS 
    'Returns project suggestions for autocomplete, matching name, company, or description';

COMMENT ON FUNCTION search_persons_autocomplete(TEXT, INTEGER) IS 
    'Returns person suggestions for autocomplete, searching across all linked entities';


