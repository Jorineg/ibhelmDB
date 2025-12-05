-- =====================================
-- INVOLVED PERSON SEARCH FUNCTION
-- =====================================
-- Enables searching for items (tasks/emails) by involved person
-- Searches across unified_persons and all linked entities (tw_users, m_contacts)

-- =====================================
-- 1. HELPER FUNCTION: Find matching unified person IDs
-- =====================================

-- Returns all unified_person IDs that match a search term
-- Searches in: unified_persons.display_name, unified_persons.primary_email,
--              teamwork.users (first_name, last_name, email),
--              missive.contacts (name, email)
CREATE OR REPLACE FUNCTION find_unified_persons_by_search(p_search_text TEXT)
RETURNS TABLE(unified_person_id UUID)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_search_pattern TEXT;
BEGIN
    -- Create case-insensitive search pattern
    v_search_pattern := '%' || LOWER(p_search_text) || '%';
    
    RETURN QUERY
    SELECT DISTINCT up.id
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
        OR LOWER(mc.email) LIKE v_search_pattern;
END;
$$;

-- =====================================
-- 2. HELPER FUNCTION: Get all linked IDs for unified persons
-- =====================================

-- Returns all tw_user_ids linked to the given unified_person IDs
CREATE OR REPLACE FUNCTION get_linked_tw_user_ids(p_unified_person_ids UUID[])
RETURNS TABLE(tw_user_id INTEGER)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT upl.tw_user_id
    FROM unified_person_links upl
    WHERE upl.unified_person_id = ANY(p_unified_person_ids)
    AND upl.tw_user_id IS NOT NULL;
END;
$$;

-- Returns all m_contact_ids linked to the given unified_person IDs
CREATE OR REPLACE FUNCTION get_linked_m_contact_ids(p_unified_person_ids UUID[])
RETURNS TABLE(m_contact_id INTEGER)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT upl.m_contact_id
    FROM unified_person_links upl
    WHERE upl.unified_person_id = ANY(p_unified_person_ids)
    AND upl.m_contact_id IS NOT NULL;
END;
$$;

-- Returns all missive user_ids linked to the given unified_person IDs
-- (via missive.contacts -> missive.users)
CREATE OR REPLACE FUNCTION get_linked_m_user_ids(p_unified_person_ids UUID[])
RETURNS TABLE(m_user_id UUID)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT mu.id
    FROM unified_person_links upl
    JOIN missive.contacts mc ON upl.m_contact_id = mc.id
    JOIN missive.users mu ON mu.contact_id = mc.id
    WHERE upl.unified_person_id = ANY(p_unified_person_ids)
    AND upl.m_contact_id IS NOT NULL;
END;
$$;

-- =====================================
-- 3. MAIN SEARCH FUNCTION: Search items by involved person
-- =====================================

-- Returns unified_items where the search term matches any involved person
-- This includes: task assignees, creators, updaters, email senders, recipients, conversation assignees
CREATE OR REPLACE FUNCTION search_items_by_involved_person(p_search_text TEXT)
RETURNS TABLE(item_id TEXT, item_type TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_unified_person_ids UUID[];
    v_tw_user_ids INTEGER[];
    v_m_contact_ids INTEGER[];
    v_m_user_ids UUID[];
BEGIN
    -- Early exit if search text is empty
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        RETURN;
    END IF;
    
    -- Step 1: Find all matching unified persons
    SELECT ARRAY_AGG(fp.unified_person_id)
    INTO v_unified_person_ids
    FROM find_unified_persons_by_search(p_search_text) fp;
    
    -- If no matches found, return empty
    IF v_unified_person_ids IS NULL OR array_length(v_unified_person_ids, 1) IS NULL THEN
        RETURN;
    END IF;
    
    -- Step 2: Get all linked IDs
    SELECT ARRAY_AGG(tw_user_id) INTO v_tw_user_ids
    FROM get_linked_tw_user_ids(v_unified_person_ids);
    
    SELECT ARRAY_AGG(m_contact_id) INTO v_m_contact_ids
    FROM get_linked_m_contact_ids(v_unified_person_ids);
    
    SELECT ARRAY_AGG(m_user_id) INTO v_m_user_ids
    FROM get_linked_m_user_ids(v_unified_person_ids);
    
    -- Handle NULL arrays
    v_tw_user_ids := COALESCE(v_tw_user_ids, ARRAY[]::INTEGER[]);
    v_m_contact_ids := COALESCE(v_m_contact_ids, ARRAY[]::INTEGER[]);
    v_m_user_ids := COALESCE(v_m_user_ids, ARRAY[]::UUID[]);
    
    -- Step 3: Return matching tasks
    RETURN QUERY
    SELECT DISTINCT t.id::TEXT, 'task'::TEXT
    FROM teamwork.tasks t
    WHERE t.deleted_at IS NULL
    AND (
        -- Creator or updater matches
        t.created_by_id = ANY(v_tw_user_ids)
        OR t.updated_by_id = ANY(v_tw_user_ids)
        -- Assignee matches
        OR EXISTS (
            SELECT 1 FROM teamwork.task_assignees ta
            WHERE ta.task_id = t.id AND ta.user_id = ANY(v_tw_user_ids)
        )
    );
    
    -- Step 4: Return matching emails
    RETURN QUERY
    SELECT DISTINCT m.id::TEXT, 'email'::TEXT
    FROM missive.messages m
    JOIN missive.conversations c ON m.conversation_id = c.id
    WHERE
        -- Sender matches
        m.from_contact_id = ANY(v_m_contact_ids)
        -- Recipient matches (to, cc, bcc)
        OR EXISTS (
            SELECT 1 FROM missive.message_recipients mr
            WHERE mr.message_id = m.id AND mr.contact_id = ANY(v_m_contact_ids)
        )
        -- Conversation is assigned to the person
        OR EXISTS (
            SELECT 1 FROM missive.conversation_assignees ca
            WHERE ca.conversation_id = c.id AND ca.user_id = ANY(v_m_user_ids)
        )
        -- Person is a conversation author
        OR EXISTS (
            SELECT 1 FROM missive.conversation_authors cauth
            WHERE cauth.conversation_id = c.id AND cauth.contact_id = ANY(v_m_contact_ids)
        );
END;
$$;

-- =====================================
-- 4. RPC FUNCTION: Get unified items filtered by involved person
-- =====================================

-- Main function to be called from the frontend
CREATE OR REPLACE FUNCTION get_unified_items_by_involved_person(
    p_search_text TEXT,
    p_show_tasks BOOLEAN DEFAULT TRUE,
    p_show_emails BOOLEAN DEFAULT TRUE,
    p_text_search TEXT DEFAULT NULL,
    p_sort_field TEXT DEFAULT 'sort_date',
    p_sort_order TEXT DEFAULT 'desc',
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    id TEXT, type TEXT, name TEXT, description TEXT, status VARCHAR, project TEXT, customer TEXT,
    location TEXT, location_path TEXT, cost_group TEXT, cost_group_code VARCHAR(50),
    due_date TIMESTAMPTZ, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, priority VARCHAR,
    progress INTEGER, tasklist TEXT, task_type_id UUID, task_type_name TEXT,
    task_type_slug TEXT, task_type_color VARCHAR(50), assignees JSONB, tags JSONB,
    body TEXT, preview TEXT, from_name TEXT, from_email TEXT, conversation_subject TEXT,
    recipients JSONB, attachments JSONB, attachment_count INTEGER, conversation_comments_text TEXT,
    craft_url TEXT, teamwork_url TEXT, missive_url TEXT, sort_date TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_has_person_search BOOLEAN := p_search_text IS NOT NULL AND TRIM(p_search_text) != '';
BEGIN
    IF p_sort_field NOT IN ('id', 'type', 'name', 'status', 'project', 'customer', 'due_date', 'created_at', 'updated_at', 'priority', 'progress', 'sort_date') THEN
        p_sort_field := 'sort_date';
    END IF;
    IF p_sort_order NOT IN ('asc', 'desc') THEN p_sort_order := 'desc'; END IF;
    
    RETURN QUERY
    WITH matching_items AS (
        SELECT siip.item_id, siip.item_type FROM search_items_by_involved_person(p_search_text) siip
        WHERE v_has_person_search
    )
    SELECT ui.id, ui.type, ui.name, ui.description, ui.status, ui.project, ui.customer,
        ui.location, ui.location_path, ui.cost_group, ui.cost_group_code,
        ui.due_date, ui.created_at, ui.updated_at, ui.priority, ui.progress, ui.tasklist,
        ui.task_type_id, ui.task_type_name, ui.task_type_slug, ui.task_type_color,
        ui.assignees, ui.tags, ui.body, ui.preview, ui.from_name, ui.from_email,
        ui.conversation_subject, ui.recipients, ui.attachments, ui.attachment_count,
        ui.conversation_comments_text, ui.craft_url, ui.teamwork_url, ui.missive_url, ui.sort_date
    FROM unified_items ui
    LEFT JOIN matching_items mi ON ui.id = mi.item_id AND ui.type = mi.item_type
    WHERE ((p_show_tasks AND ui.type = 'task') OR (p_show_emails AND ui.type = 'email'))
        AND (NOT v_has_person_search OR mi.item_id IS NOT NULL)
        AND (p_text_search IS NULL OR LOWER(ui.name) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.description) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.body) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.conversation_comments_text) LIKE '%' || LOWER(p_text_search) || '%')
    ORDER BY 
        CASE WHEN p_sort_field = 'sort_date' AND p_sort_order = 'desc' THEN ui.sort_date END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'sort_date' AND p_sort_order = 'asc' THEN ui.sort_date END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'name' AND p_sort_order = 'desc' THEN ui.name END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'name' AND p_sort_order = 'asc' THEN ui.name END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'desc' THEN ui.created_at END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'asc' THEN ui.created_at END ASC NULLS LAST
    LIMIT p_limit OFFSET p_offset;
END;
$$;

-- =====================================
-- 5. COUNT FUNCTION for pagination
-- =====================================

CREATE OR REPLACE FUNCTION count_unified_items_by_involved_person(
    p_search_text TEXT,
    p_show_tasks BOOLEAN DEFAULT TRUE,
    p_show_emails BOOLEAN DEFAULT TRUE,
    p_text_search TEXT DEFAULT NULL
)
RETURNS INTEGER LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_count INTEGER;
    v_has_person_search BOOLEAN := p_search_text IS NOT NULL AND TRIM(p_search_text) != '';
BEGIN
    WITH matching_items AS (
        SELECT siip.item_id, siip.item_type FROM search_items_by_involved_person(p_search_text) siip
        WHERE v_has_person_search
    )
    SELECT COUNT(*)::INTEGER INTO v_count
    FROM unified_items ui
    LEFT JOIN matching_items mi ON ui.id = mi.item_id AND ui.type = mi.item_type
    WHERE ((p_show_tasks AND ui.type = 'task') OR (p_show_emails AND ui.type = 'email'))
        AND (NOT v_has_person_search OR mi.item_id IS NOT NULL)
        AND (p_text_search IS NULL OR LOWER(ui.name) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.description) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.body) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.conversation_comments_text) LIKE '%' || LOWER(p_text_search) || '%');
    RETURN v_count;
END;
$$;

-- =====================================
-- 6. INDEXES for performance
-- =====================================

-- Index on unified_persons for faster text search
CREATE INDEX IF NOT EXISTS idx_unified_persons_display_name_lower 
    ON unified_persons(LOWER(display_name));
CREATE INDEX IF NOT EXISTS idx_unified_persons_primary_email_lower 
    ON unified_persons(LOWER(primary_email));

-- Indexes on teamwork.users for faster search
CREATE INDEX IF NOT EXISTS idx_tw_users_first_name_lower 
    ON teamwork.users(LOWER(first_name));
CREATE INDEX IF NOT EXISTS idx_tw_users_last_name_lower 
    ON teamwork.users(LOWER(last_name));

-- Indexes on missive.contacts for faster search
CREATE INDEX IF NOT EXISTS idx_m_contacts_name_lower 
    ON missive.contacts(LOWER(name));

-- Index on tasks for creator/updater lookup
CREATE INDEX IF NOT EXISTS idx_tw_tasks_created_by_id 
    ON teamwork.tasks(created_by_id);
CREATE INDEX IF NOT EXISTS idx_tw_tasks_updated_by_id 
    ON teamwork.tasks(updated_by_id);

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON FUNCTION find_unified_persons_by_search(TEXT) IS 
    'Finds unified_person IDs matching a search term across all linked entities';

COMMENT ON FUNCTION get_linked_tw_user_ids(UUID[]) IS 
    'Returns Teamwork user IDs linked to the given unified person IDs';

COMMENT ON FUNCTION get_linked_m_contact_ids(UUID[]) IS 
    'Returns Missive contact IDs linked to the given unified person IDs';

COMMENT ON FUNCTION get_linked_m_user_ids(UUID[]) IS 
    'Returns Missive user IDs linked to the given unified person IDs (via contacts)';

COMMENT ON FUNCTION search_items_by_involved_person(TEXT) IS 
    'Returns item IDs (tasks/emails) where the search term matches any involved person';

COMMENT ON FUNCTION get_unified_items_by_involved_person(TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT, TEXT, INTEGER, INTEGER) IS 
    'Main RPC function: Returns unified_items filtered by involved person search';

COMMENT ON FUNCTION count_unified_items_by_involved_person(TEXT, BOOLEAN, BOOLEAN, TEXT) IS 
    'Returns count of unified_items matching involved person search (for pagination)';

