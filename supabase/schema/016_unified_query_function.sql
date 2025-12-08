-- =====================================
-- UNIFIED QUERY FUNCTION
-- =====================================
-- Single entry point for all unified_items queries
-- All filtering, searching, sorting happens in the database

-- =====================================
-- 1. HELPER: COST GROUP RANGE CALCULATION
-- =====================================

CREATE OR REPLACE FUNCTION compute_cost_group_range(p_code TEXT)
RETURNS TABLE(min_code INTEGER, max_code INTEGER)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_num INTEGER;
BEGIN
    IF p_code IS NULL OR TRIM(p_code) = '' THEN
        RETURN;
    END IF;
    
    BEGIN
        v_num := TRIM(p_code)::INTEGER;
    EXCEPTION WHEN OTHERS THEN
        RETURN;
    END;
    
    IF v_num >= 100 AND v_num <= 999 THEN
        -- Full 3-digit code - exact match
        min_code := v_num;
        max_code := v_num;
    ELSIF v_num >= 10 AND v_num <= 99 THEN
        -- 2-digit code - match range (45 -> 450-459)
        min_code := v_num * 10;
        max_code := v_num * 10 + 9;
    ELSIF v_num >= 1 AND v_num <= 9 THEN
        -- 1-digit code - match range (4 -> 400-499)
        min_code := v_num * 100;
        max_code := v_num * 100 + 99;
    ELSE
        RETURN;
    END IF;
    
    RETURN NEXT;
END;
$$;

-- =====================================
-- 2. MAIN QUERY FUNCTION
-- =====================================

CREATE OR REPLACE FUNCTION query_unified_items(
    -- Type filters
    p_types TEXT[] DEFAULT NULL,              -- ['task', 'email', 'craft'] - NULL = all
    p_task_types UUID[] DEFAULT NULL,         -- Task type IDs - NULL = all tasks
    
    -- Global text search (searches name, description, body, preview, comments)
    p_text_search TEXT DEFAULT NULL,
    
    -- Special filters (require complex logic)
    p_involved_person TEXT DEFAULT NULL,      -- Junction table lookup
    p_tag_search TEXT DEFAULT NULL,           -- JSONB array search
    p_cost_group_code TEXT DEFAULT NULL,      -- Hierarchical (4→400-499, 45→450-459)
    
    -- Simple text contains filters (ilike)
    p_project_search TEXT DEFAULT NULL,
    p_location_building TEXT DEFAULT NULL,
    p_location_floor TEXT DEFAULT NULL,
    p_location_room TEXT DEFAULT NULL,
    p_name_contains TEXT DEFAULT NULL,
    p_description_contains TEXT DEFAULT NULL,
    p_customer_contains TEXT DEFAULT NULL,
    p_tasklist_contains TEXT DEFAULT NULL,
    p_from_name_contains TEXT DEFAULT NULL,
    p_from_email_contains TEXT DEFAULT NULL,
    
    -- Enum filters (in/not in arrays)
    p_status_in TEXT[] DEFAULT NULL,
    p_status_not_in TEXT[] DEFAULT NULL,
    p_priority_in TEXT[] DEFAULT NULL,
    p_priority_not_in TEXT[] DEFAULT NULL,
    
    -- Date range filters
    p_due_date_min TIMESTAMP DEFAULT NULL,
    p_due_date_max TIMESTAMP DEFAULT NULL,
    p_due_date_is_null BOOLEAN DEFAULT NULL,  -- TRUE=only nulls, FALSE=only non-nulls
    p_created_at_min TIMESTAMPTZ DEFAULT NULL,
    p_created_at_max TIMESTAMPTZ DEFAULT NULL,
    p_updated_at_min TIMESTAMPTZ DEFAULT NULL,
    p_updated_at_max TIMESTAMPTZ DEFAULT NULL,
    
    -- Number range filters
    p_progress_min INTEGER DEFAULT NULL,
    p_progress_max INTEGER DEFAULT NULL,
    p_attachment_count_min INTEGER DEFAULT NULL,
    p_attachment_count_max INTEGER DEFAULT NULL,
    
    -- Pagination & sorting
    p_sort_field TEXT DEFAULT 'sort_date',
    p_sort_order TEXT DEFAULT 'desc',
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    id TEXT,
    type TEXT,
    name TEXT,
    description TEXT,
    status VARCHAR,
    project TEXT,
    customer TEXT,
    location TEXT,
    location_path TEXT,
    cost_group TEXT,
    cost_group_code TEXT,
    due_date TIMESTAMP,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    priority VARCHAR,
    progress INTEGER,
    tasklist TEXT,
    task_type_id UUID,
    task_type_name TEXT,
    task_type_slug TEXT,
    task_type_color VARCHAR(50),
    assignees JSONB,
    tags JSONB,
    body TEXT,
    preview TEXT,
    from_name TEXT,
    from_email TEXT,
    conversation_subject TEXT,
    recipients JSONB,
    attachments JSONB,
    attachment_count INTEGER,
    conversation_comments_text TEXT,
    craft_url TEXT,
    teamwork_url TEXT,
    missive_url TEXT,
    sort_date TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_person_ids UUID[];
    v_has_person_filter BOOLEAN;
    v_cost_min INTEGER;
    v_cost_max INTEGER;
    v_has_cost_filter BOOLEAN;
BEGIN
    -- Validate sort parameters
    IF p_sort_field NOT IN ('name', 'status', 'project', 'customer', 'due_date', 'created_at', 'updated_at', 'priority', 'sort_date', 'progress', 'attachment_count') THEN
        p_sort_field := 'sort_date';
    END IF;
    IF p_sort_order NOT IN ('asc', 'desc') THEN
        p_sort_order := 'desc';
    END IF;
    
    -- Pre-compute person IDs if filter is active
    v_has_person_filter := p_involved_person IS NOT NULL AND TRIM(p_involved_person) != '';
    IF v_has_person_filter THEN
        v_person_ids := find_person_ids_by_search(p_involved_person);
        IF array_length(v_person_ids, 1) IS NULL THEN
            -- No matching persons found, return empty
            RETURN;
        END IF;
    END IF;
    
    -- Pre-compute cost group range if filter is active
    v_has_cost_filter := p_cost_group_code IS NOT NULL AND TRIM(p_cost_group_code) != '';
    IF v_has_cost_filter THEN
        SELECT cgr.min_code, cgr.max_code INTO v_cost_min, v_cost_max
        FROM compute_cost_group_range(p_cost_group_code) cgr;
        IF v_cost_min IS NULL THEN
            v_has_cost_filter := FALSE;
        END IF;
    END IF;
    
    RETURN QUERY
    SELECT
        ui.id, ui.type, ui.name, ui.description, ui.status, ui.project, ui.customer,
        ui.location, ui.location_path, ui.cost_group, ui.cost_group_code,
        ui.due_date, ui.created_at, ui.updated_at, ui.priority, ui.progress, ui.tasklist,
        ui.task_type_id, ui.task_type_name, ui.task_type_slug, ui.task_type_color,
        ui.assignees, ui.tags, ui.body, ui.preview, ui.from_name, ui.from_email,
        ui.conversation_subject, ui.recipients, ui.attachments, ui.attachment_count,
        ui.conversation_comments_text, ui.craft_url, ui.teamwork_url, ui.missive_url,
        ui.sort_date
    FROM unified_items ui
    WHERE
        -- ===== TYPE FILTERS =====
        (p_types IS NULL OR ui.type = ANY(p_types))
        AND (ui.type != 'task' OR p_task_types IS NULL OR ui.task_type_id = ANY(p_task_types))
        
        -- ===== GLOBAL TEXT SEARCH =====
        AND (p_text_search IS NULL OR p_text_search = '' OR
            LOWER(ui.name) LIKE '%' || LOWER(p_text_search) || '%' OR
            LOWER(ui.description) LIKE '%' || LOWER(p_text_search) || '%' OR
            LOWER(ui.body) LIKE '%' || LOWER(p_text_search) || '%' OR
            LOWER(ui.preview) LIKE '%' || LOWER(p_text_search) || '%' OR
            LOWER(ui.conversation_comments_text) LIKE '%' || LOWER(p_text_search) || '%')
        
        -- ===== INVOLVED PERSON FILTER (junction table) =====
        AND (NOT v_has_person_filter OR EXISTS (
            SELECT 1 FROM item_involved_persons iip
            WHERE iip.item_id = ui.id AND iip.item_type = ui.type
            AND iip.unified_person_id = ANY(v_person_ids)
        ))
        
        -- ===== TAG FILTER (JSONB array search) =====
        AND (p_tag_search IS NULL OR p_tag_search = '' OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(ui.tags) t
            WHERE LOWER(t->>'name') LIKE '%' || LOWER(p_tag_search) || '%'
        ))
        
        -- ===== COST GROUP FILTER (hierarchical) =====
        AND (NOT v_has_cost_filter OR (
            ui.cost_group_code IS NOT NULL 
            AND ui.cost_group_code ~ '^\d+$'
            AND ui.cost_group_code::INTEGER >= v_cost_min 
            AND ui.cost_group_code::INTEGER <= v_cost_max
        ))
        
        -- ===== SIMPLE TEXT CONTAINS FILTERS =====
        AND (p_project_search IS NULL OR p_project_search = '' OR LOWER(ui.project) LIKE '%' || LOWER(p_project_search) || '%')
        AND (p_location_building IS NULL OR p_location_building = '' OR LOWER(ui.location_path) LIKE '%' || LOWER(p_location_building) || '%')
        AND (p_location_floor IS NULL OR p_location_floor = '' OR LOWER(ui.location_path) LIKE '%' || LOWER(p_location_floor) || '%')
        AND (p_location_room IS NULL OR p_location_room = '' OR LOWER(ui.location_path) LIKE '%' || LOWER(p_location_room) || '%')
        AND (p_name_contains IS NULL OR p_name_contains = '' OR LOWER(ui.name) LIKE '%' || LOWER(p_name_contains) || '%')
        AND (p_description_contains IS NULL OR p_description_contains = '' OR LOWER(ui.description) LIKE '%' || LOWER(p_description_contains) || '%')
        AND (p_customer_contains IS NULL OR p_customer_contains = '' OR LOWER(ui.customer) LIKE '%' || LOWER(p_customer_contains) || '%')
        AND (p_tasklist_contains IS NULL OR p_tasklist_contains = '' OR LOWER(ui.tasklist) LIKE '%' || LOWER(p_tasklist_contains) || '%')
        AND (p_from_name_contains IS NULL OR p_from_name_contains = '' OR LOWER(ui.from_name) LIKE '%' || LOWER(p_from_name_contains) || '%')
        AND (p_from_email_contains IS NULL OR p_from_email_contains = '' OR LOWER(ui.from_email) LIKE '%' || LOWER(p_from_email_contains) || '%')
        
        -- ===== ENUM FILTERS (in/not in) =====
        AND (p_status_in IS NULL OR ui.status = ANY(p_status_in))
        AND (p_status_not_in IS NULL OR ui.status IS NULL OR NOT (ui.status = ANY(p_status_not_in)))
        AND (p_priority_in IS NULL OR ui.priority = ANY(p_priority_in))
        AND (p_priority_not_in IS NULL OR ui.priority IS NULL OR NOT (ui.priority = ANY(p_priority_not_in)))
        
        -- ===== DATE RANGE FILTERS =====
        AND (p_due_date_min IS NULL OR ui.due_date >= p_due_date_min)
        AND (p_due_date_max IS NULL OR ui.due_date <= p_due_date_max)
        AND (p_due_date_is_null IS NULL OR 
            (p_due_date_is_null = TRUE AND ui.due_date IS NULL) OR
            (p_due_date_is_null = FALSE AND ui.due_date IS NOT NULL))
        AND (p_created_at_min IS NULL OR ui.created_at >= p_created_at_min)
        AND (p_created_at_max IS NULL OR ui.created_at <= p_created_at_max)
        AND (p_updated_at_min IS NULL OR ui.updated_at >= p_updated_at_min)
        AND (p_updated_at_max IS NULL OR ui.updated_at <= p_updated_at_max)
        
        -- ===== NUMBER RANGE FILTERS =====
        AND (p_progress_min IS NULL OR ui.progress >= p_progress_min)
        AND (p_progress_max IS NULL OR ui.progress <= p_progress_max)
        AND (p_attachment_count_min IS NULL OR ui.attachment_count >= p_attachment_count_min)
        AND (p_attachment_count_max IS NULL OR ui.attachment_count <= p_attachment_count_max)
    
    ORDER BY
        CASE WHEN p_sort_field = 'sort_date' AND p_sort_order = 'desc' THEN ui.sort_date END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'sort_date' AND p_sort_order = 'asc' THEN ui.sort_date END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'name' AND p_sort_order = 'desc' THEN ui.name END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'name' AND p_sort_order = 'asc' THEN ui.name END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'desc' THEN ui.created_at END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'asc' THEN ui.created_at END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'updated_at' AND p_sort_order = 'desc' THEN ui.updated_at END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'updated_at' AND p_sort_order = 'asc' THEN ui.updated_at END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'due_date' AND p_sort_order = 'desc' THEN ui.due_date END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'due_date' AND p_sort_order = 'asc' THEN ui.due_date END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'status' AND p_sort_order = 'desc' THEN ui.status END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'status' AND p_sort_order = 'asc' THEN ui.status END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'project' AND p_sort_order = 'desc' THEN ui.project END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'project' AND p_sort_order = 'asc' THEN ui.project END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'customer' AND p_sort_order = 'desc' THEN ui.customer END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'customer' AND p_sort_order = 'asc' THEN ui.customer END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'priority' AND p_sort_order = 'desc' THEN ui.priority END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'priority' AND p_sort_order = 'asc' THEN ui.priority END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'progress' AND p_sort_order = 'desc' THEN ui.progress END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'progress' AND p_sort_order = 'asc' THEN ui.progress END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'attachment_count' AND p_sort_order = 'desc' THEN ui.attachment_count END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'attachment_count' AND p_sort_order = 'asc' THEN ui.attachment_count END ASC NULLS LAST
    LIMIT p_limit
    OFFSET p_offset;
END;
$$;

-- =====================================
-- 3. COUNT FUNCTION (for pagination)
-- =====================================

CREATE OR REPLACE FUNCTION count_unified_items(
    -- Type filters
    p_types TEXT[] DEFAULT NULL,
    p_task_types UUID[] DEFAULT NULL,
    
    -- Global text search
    p_text_search TEXT DEFAULT NULL,
    
    -- Special filters
    p_involved_person TEXT DEFAULT NULL,
    p_tag_search TEXT DEFAULT NULL,
    p_cost_group_code TEXT DEFAULT NULL,
    
    -- Simple text contains filters
    p_project_search TEXT DEFAULT NULL,
    p_location_building TEXT DEFAULT NULL,
    p_location_floor TEXT DEFAULT NULL,
    p_location_room TEXT DEFAULT NULL,
    p_name_contains TEXT DEFAULT NULL,
    p_description_contains TEXT DEFAULT NULL,
    p_customer_contains TEXT DEFAULT NULL,
    p_tasklist_contains TEXT DEFAULT NULL,
    p_from_name_contains TEXT DEFAULT NULL,
    p_from_email_contains TEXT DEFAULT NULL,
    
    -- Enum filters
    p_status_in TEXT[] DEFAULT NULL,
    p_status_not_in TEXT[] DEFAULT NULL,
    p_priority_in TEXT[] DEFAULT NULL,
    p_priority_not_in TEXT[] DEFAULT NULL,
    
    -- Date range filters
    p_due_date_min TIMESTAMP DEFAULT NULL,
    p_due_date_max TIMESTAMP DEFAULT NULL,
    p_due_date_is_null BOOLEAN DEFAULT NULL,
    p_created_at_min TIMESTAMPTZ DEFAULT NULL,
    p_created_at_max TIMESTAMPTZ DEFAULT NULL,
    p_updated_at_min TIMESTAMPTZ DEFAULT NULL,
    p_updated_at_max TIMESTAMPTZ DEFAULT NULL,
    
    -- Number range filters
    p_progress_min INTEGER DEFAULT NULL,
    p_progress_max INTEGER DEFAULT NULL,
    p_attachment_count_min INTEGER DEFAULT NULL,
    p_attachment_count_max INTEGER DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count INTEGER;
    v_person_ids UUID[];
    v_has_person_filter BOOLEAN;
    v_cost_min INTEGER;
    v_cost_max INTEGER;
    v_has_cost_filter BOOLEAN;
BEGIN
    -- Pre-compute person IDs if filter is active
    v_has_person_filter := p_involved_person IS NOT NULL AND TRIM(p_involved_person) != '';
    IF v_has_person_filter THEN
        v_person_ids := find_person_ids_by_search(p_involved_person);
        IF array_length(v_person_ids, 1) IS NULL THEN
            RETURN 0;
        END IF;
    END IF;
    
    -- Pre-compute cost group range if filter is active
    v_has_cost_filter := p_cost_group_code IS NOT NULL AND TRIM(p_cost_group_code) != '';
    IF v_has_cost_filter THEN
        SELECT cgr.min_code, cgr.max_code INTO v_cost_min, v_cost_max
        FROM compute_cost_group_range(p_cost_group_code) cgr;
        IF v_cost_min IS NULL THEN
            v_has_cost_filter := FALSE;
        END IF;
    END IF;
    
    SELECT COUNT(*)::INTEGER INTO v_count
    FROM unified_items ui
    WHERE
        -- Type filters
        (p_types IS NULL OR ui.type = ANY(p_types))
        AND (ui.type != 'task' OR p_task_types IS NULL OR ui.task_type_id = ANY(p_task_types))
        
        -- Global text search
        AND (p_text_search IS NULL OR p_text_search = '' OR
            LOWER(ui.name) LIKE '%' || LOWER(p_text_search) || '%' OR
            LOWER(ui.description) LIKE '%' || LOWER(p_text_search) || '%' OR
            LOWER(ui.body) LIKE '%' || LOWER(p_text_search) || '%' OR
            LOWER(ui.preview) LIKE '%' || LOWER(p_text_search) || '%' OR
            LOWER(ui.conversation_comments_text) LIKE '%' || LOWER(p_text_search) || '%')
        
        -- Involved person filter
        AND (NOT v_has_person_filter OR EXISTS (
            SELECT 1 FROM item_involved_persons iip
            WHERE iip.item_id = ui.id AND iip.item_type = ui.type
            AND iip.unified_person_id = ANY(v_person_ids)
        ))
        
        -- Tag filter
        AND (p_tag_search IS NULL OR p_tag_search = '' OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(ui.tags) t
            WHERE LOWER(t->>'name') LIKE '%' || LOWER(p_tag_search) || '%'
        ))
        
        -- Cost group filter
        AND (NOT v_has_cost_filter OR (
            ui.cost_group_code IS NOT NULL 
            AND ui.cost_group_code ~ '^\d+$'
            AND ui.cost_group_code::INTEGER >= v_cost_min 
            AND ui.cost_group_code::INTEGER <= v_cost_max
        ))
        
        -- Simple text contains filters
        AND (p_project_search IS NULL OR p_project_search = '' OR LOWER(ui.project) LIKE '%' || LOWER(p_project_search) || '%')
        AND (p_location_building IS NULL OR p_location_building = '' OR LOWER(ui.location_path) LIKE '%' || LOWER(p_location_building) || '%')
        AND (p_location_floor IS NULL OR p_location_floor = '' OR LOWER(ui.location_path) LIKE '%' || LOWER(p_location_floor) || '%')
        AND (p_location_room IS NULL OR p_location_room = '' OR LOWER(ui.location_path) LIKE '%' || LOWER(p_location_room) || '%')
        AND (p_name_contains IS NULL OR p_name_contains = '' OR LOWER(ui.name) LIKE '%' || LOWER(p_name_contains) || '%')
        AND (p_description_contains IS NULL OR p_description_contains = '' OR LOWER(ui.description) LIKE '%' || LOWER(p_description_contains) || '%')
        AND (p_customer_contains IS NULL OR p_customer_contains = '' OR LOWER(ui.customer) LIKE '%' || LOWER(p_customer_contains) || '%')
        AND (p_tasklist_contains IS NULL OR p_tasklist_contains = '' OR LOWER(ui.tasklist) LIKE '%' || LOWER(p_tasklist_contains) || '%')
        AND (p_from_name_contains IS NULL OR p_from_name_contains = '' OR LOWER(ui.from_name) LIKE '%' || LOWER(p_from_name_contains) || '%')
        AND (p_from_email_contains IS NULL OR p_from_email_contains = '' OR LOWER(ui.from_email) LIKE '%' || LOWER(p_from_email_contains) || '%')
        
        -- Enum filters
        AND (p_status_in IS NULL OR ui.status = ANY(p_status_in))
        AND (p_status_not_in IS NULL OR ui.status IS NULL OR NOT (ui.status = ANY(p_status_not_in)))
        AND (p_priority_in IS NULL OR ui.priority = ANY(p_priority_in))
        AND (p_priority_not_in IS NULL OR ui.priority IS NULL OR NOT (ui.priority = ANY(p_priority_not_in)))
        
        -- Date range filters
        AND (p_due_date_min IS NULL OR ui.due_date >= p_due_date_min)
        AND (p_due_date_max IS NULL OR ui.due_date <= p_due_date_max)
        AND (p_due_date_is_null IS NULL OR 
            (p_due_date_is_null = TRUE AND ui.due_date IS NULL) OR
            (p_due_date_is_null = FALSE AND ui.due_date IS NOT NULL))
        AND (p_created_at_min IS NULL OR ui.created_at >= p_created_at_min)
        AND (p_created_at_max IS NULL OR ui.created_at <= p_created_at_max)
        AND (p_updated_at_min IS NULL OR ui.updated_at >= p_updated_at_min)
        AND (p_updated_at_max IS NULL OR ui.updated_at <= p_updated_at_max)
        
        -- Number range filters
        AND (p_progress_min IS NULL OR ui.progress >= p_progress_min)
        AND (p_progress_max IS NULL OR ui.progress <= p_progress_max)
        AND (p_attachment_count_min IS NULL OR ui.attachment_count >= p_attachment_count_min)
        AND (p_attachment_count_max IS NULL OR ui.attachment_count <= p_attachment_count_max);
    
    RETURN v_count;
END;
$$;

-- =====================================
-- 4. GRANTS
-- =====================================

GRANT EXECUTE ON FUNCTION compute_cost_group_range(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION query_unified_items(
    TEXT[], UUID[], TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT,
    TEXT[], TEXT[], TEXT[], TEXT[],
    TIMESTAMP, TIMESTAMP, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ,
    INTEGER, INTEGER, INTEGER, INTEGER,
    TEXT, TEXT, INTEGER, INTEGER
) TO authenticated;
GRANT EXECUTE ON FUNCTION count_unified_items(
    TEXT[], UUID[], TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT,
    TEXT[], TEXT[], TEXT[], TEXT[],
    TIMESTAMP, TIMESTAMP, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ,
    INTEGER, INTEGER, INTEGER, INTEGER
) TO authenticated;

-- =====================================
-- 5. COMMENTS
-- =====================================

COMMENT ON FUNCTION compute_cost_group_range IS 'Computes min/max code range for hierarchical cost group filtering (4→400-499, 45→450-459, 456→456)';
COMMENT ON FUNCTION query_unified_items IS 'Unified query function for all unified_items filtering, searching, sorting. Single entry point replacing fragmented approaches.';
COMMENT ON FUNCTION count_unified_items IS 'Count function matching query_unified_items for pagination support';

