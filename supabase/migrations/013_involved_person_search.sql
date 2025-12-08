-- =====================================
-- INVOLVED PERSON SEARCH
-- =====================================
-- Junction table and functions for filtering items by involved person
-- Supports: task assignees/creators/updaters, email senders/recipients/conversation participants

-- =====================================
-- 1. INDEXES FOR PERSON SEARCH
-- =====================================

CREATE INDEX IF NOT EXISTS idx_unified_persons_display_name_lower ON unified_persons(LOWER(display_name));
CREATE INDEX IF NOT EXISTS idx_unified_persons_primary_email_lower ON unified_persons(LOWER(primary_email));
CREATE INDEX IF NOT EXISTS idx_tw_users_first_name_lower ON teamwork.users(LOWER(first_name));
CREATE INDEX IF NOT EXISTS idx_tw_users_last_name_lower ON teamwork.users(LOWER(last_name));
CREATE INDEX IF NOT EXISTS idx_m_contacts_name_lower ON missive.contacts(LOWER(name));
CREATE INDEX IF NOT EXISTS idx_tw_tasks_created_by_id ON teamwork.tasks(created_by_id);
CREATE INDEX IF NOT EXISTS idx_tw_tasks_updated_by_id ON teamwork.tasks(updated_by_id);

-- =====================================
-- 2. JUNCTION TABLE
-- =====================================

CREATE TABLE item_involved_persons (
    item_id TEXT NOT NULL,
    item_type TEXT NOT NULL,  -- 'task', 'email'
    unified_person_id UUID NOT NULL REFERENCES unified_persons(id) ON DELETE CASCADE,
    involvement_type TEXT NOT NULL,
    -- Tasks: 'assignee', 'creator', 'updater'
    -- Emails: 'sender', 'recipient', 'conversation_assignee', 'conversation_author', 'conversation_commentator'
    PRIMARY KEY (item_id, item_type, unified_person_id, involvement_type)
);

CREATE INDEX idx_iip_unified_person_id ON item_involved_persons(unified_person_id);
CREATE INDEX idx_iip_item ON item_involved_persons(item_id, item_type);

-- =====================================
-- 3. REFRESH FUNCTION
-- =====================================

CREATE OR REPLACE FUNCTION refresh_item_involved_persons()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE item_involved_persons;
    
    -- Task assignees
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT t.id::TEXT, 'task', upl.unified_person_id, 'assignee'
    FROM teamwork.tasks t
    JOIN teamwork.task_assignees ta ON ta.task_id = t.id
    JOIN unified_person_links upl ON upl.tw_user_id = ta.user_id
    WHERE t.deleted_at IS NULL AND upl.unified_person_id IS NOT NULL;
    
    -- Task creators
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT t.id::TEXT, 'task', upl.unified_person_id, 'creator'
    FROM teamwork.tasks t
    JOIN unified_person_links upl ON upl.tw_user_id = t.created_by_id
    WHERE t.deleted_at IS NULL AND upl.unified_person_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    
    -- Task updaters
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT t.id::TEXT, 'task', upl.unified_person_id, 'updater'
    FROM teamwork.tasks t
    JOIN unified_person_links upl ON upl.tw_user_id = t.updated_by_id
    WHERE t.deleted_at IS NULL AND t.updated_by_id IS NOT NULL AND upl.unified_person_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    
    -- Email senders
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT m.id::TEXT, 'email', upl.unified_person_id, 'sender'
    FROM missive.messages m
    JOIN unified_person_links upl ON upl.m_contact_id = m.from_contact_id
    WHERE upl.unified_person_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    
    -- Email recipients
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT m.id::TEXT, 'email', upl.unified_person_id, 'recipient'
    FROM missive.messages m
    JOIN missive.message_recipients mr ON mr.message_id = m.id
    JOIN unified_person_links upl ON upl.m_contact_id = mr.contact_id
    WHERE upl.unified_person_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    
    -- Conversation assignees
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT m.id::TEXT, 'email', upl.unified_person_id, 'conversation_assignee'
    FROM missive.messages m
    JOIN missive.conversations c ON c.id = m.conversation_id
    JOIN missive.conversation_assignees ca ON ca.conversation_id = c.id
    JOIN missive.users mu ON mu.id = ca.user_id
    JOIN unified_person_links upl ON upl.m_contact_id = mu.contact_id
    WHERE upl.unified_person_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    
    -- Conversation authors
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT m.id::TEXT, 'email', upl.unified_person_id, 'conversation_author'
    FROM missive.messages m
    JOIN missive.conversations c ON c.id = m.conversation_id
    JOIN missive.conversation_authors cauth ON cauth.conversation_id = c.id
    JOIN unified_person_links upl ON upl.m_contact_id = cauth.contact_id
    WHERE upl.unified_person_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    
    -- Conversation commentators
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT m.id::TEXT, 'email', upl.unified_person_id, 'conversation_commentator'
    FROM missive.messages m
    JOIN missive.conversations c ON c.id = m.conversation_id
    JOIN missive.conversation_comments cc ON cc.conversation_id = c.id
    JOIN missive.users mu ON mu.id = cc.author_id
    JOIN unified_person_links upl ON upl.m_contact_id = mu.contact_id
    WHERE upl.unified_person_id IS NOT NULL
    ON CONFLICT DO NOTHING;
END;
$$;

-- =====================================
-- 4. HELPER FUNCTIONS
-- =====================================

CREATE OR REPLACE FUNCTION find_person_ids_by_search(p_search_text TEXT)
RETURNS UUID[] LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_pattern TEXT;
    v_result UUID[];
BEGIN
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN RETURN ARRAY[]::UUID[]; END IF;
    v_pattern := '%' || LOWER(p_search_text) || '%';
    
    SELECT ARRAY_AGG(DISTINCT up.id) INTO v_result
    FROM unified_persons up
    LEFT JOIN unified_person_links upl ON up.id = upl.unified_person_id
    LEFT JOIN teamwork.users twu ON upl.tw_user_id = twu.id
    LEFT JOIN teamwork.companies twc ON upl.tw_company_id = twc.id
    LEFT JOIN missive.contacts mc ON upl.m_contact_id = mc.id
    WHERE LOWER(up.display_name) LIKE v_pattern OR LOWER(up.primary_email) LIKE v_pattern
        OR LOWER(twu.first_name) LIKE v_pattern OR LOWER(twu.last_name) LIKE v_pattern
        OR LOWER(twu.email) LIKE v_pattern
        OR LOWER(COALESCE(twu.first_name, '') || ' ' || COALESCE(twu.last_name, '')) LIKE v_pattern
        OR LOWER(twc.name) LIKE v_pattern OR LOWER(twc.email_one) LIKE v_pattern
        OR LOWER(mc.name) LIKE v_pattern OR LOWER(mc.email) LIKE v_pattern;
    
    RETURN COALESCE(v_result, ARRAY[]::UUID[]);
END;
$$;

-- =====================================
-- 5. INCREMENTAL UPDATE TRIGGERS
-- =====================================

CREATE OR REPLACE FUNCTION refresh_task_involvement(p_task_id INTEGER) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM item_involved_persons WHERE item_id = p_task_id::TEXT AND item_type = 'task';
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT p_task_id::TEXT, 'task', upl.unified_person_id, 'assignee'
    FROM teamwork.task_assignees ta JOIN unified_person_links upl ON upl.tw_user_id = ta.user_id
    WHERE ta.task_id = p_task_id AND upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT p_task_id::TEXT, 'task', upl.unified_person_id, 'creator'
    FROM teamwork.tasks t JOIN unified_person_links upl ON upl.tw_user_id = t.created_by_id
    WHERE t.id = p_task_id AND t.deleted_at IS NULL AND upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT p_task_id::TEXT, 'task', upl.unified_person_id, 'updater'
    FROM teamwork.tasks t JOIN unified_person_links upl ON upl.tw_user_id = t.updated_by_id
    WHERE t.id = p_task_id AND t.deleted_at IS NULL AND t.updated_by_id IS NOT NULL AND upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION refresh_message_involvement(p_message_id UUID) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_conv_id UUID;
BEGIN
    SELECT conversation_id INTO v_conv_id FROM missive.messages WHERE id = p_message_id;
    DELETE FROM item_involved_persons WHERE item_id = p_message_id::TEXT AND item_type = 'email';
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT p_message_id::TEXT, 'email', upl.unified_person_id, 'sender'
    FROM missive.messages m JOIN unified_person_links upl ON upl.m_contact_id = m.from_contact_id
    WHERE m.id = p_message_id AND upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT p_message_id::TEXT, 'email', upl.unified_person_id, 'recipient'
    FROM missive.message_recipients mr JOIN unified_person_links upl ON upl.m_contact_id = mr.contact_id
    WHERE mr.message_id = p_message_id AND upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT p_message_id::TEXT, 'email', upl.unified_person_id, 'conversation_assignee'
    FROM missive.conversation_assignees ca JOIN missive.users mu ON mu.id = ca.user_id JOIN unified_person_links upl ON upl.m_contact_id = mu.contact_id
    WHERE ca.conversation_id = v_conv_id AND upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT p_message_id::TEXT, 'email', upl.unified_person_id, 'conversation_author'
    FROM missive.conversation_authors cauth JOIN unified_person_links upl ON upl.m_contact_id = cauth.contact_id
    WHERE cauth.conversation_id = v_conv_id AND upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT p_message_id::TEXT, 'email', upl.unified_person_id, 'conversation_commentator'
    FROM missive.conversation_comments cc JOIN missive.users mu ON mu.id = cc.author_id JOIN unified_person_links upl ON upl.m_contact_id = mu.contact_id
    WHERE cc.conversation_id = v_conv_id AND upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION refresh_conversation_involvement(p_conv_id UUID) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_msg_id UUID;
BEGIN
    FOR v_msg_id IN SELECT id FROM missive.messages WHERE conversation_id = p_conv_id LOOP
        PERFORM refresh_message_involvement(v_msg_id);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION trigger_refresh_task_involvement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN DELETE FROM item_involved_persons WHERE item_id = OLD.id::TEXT AND item_type = 'task'; RETURN OLD;
    ELSE PERFORM refresh_task_involvement(NEW.id); RETURN NEW; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION trigger_refresh_task_assignee_involvement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN PERFORM refresh_task_involvement(OLD.task_id); RETURN OLD;
    ELSE PERFORM refresh_task_involvement(NEW.task_id); RETURN NEW; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION trigger_refresh_message_involvement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN DELETE FROM item_involved_persons WHERE item_id = OLD.id::TEXT AND item_type = 'email'; RETURN OLD;
    ELSE PERFORM refresh_message_involvement(NEW.id); RETURN NEW; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION trigger_refresh_recipient_involvement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN PERFORM refresh_message_involvement(OLD.message_id); RETURN OLD;
    ELSE PERFORM refresh_message_involvement(NEW.message_id); RETURN NEW; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION trigger_refresh_conversation_involvement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN PERFORM refresh_conversation_involvement(OLD.conversation_id); RETURN OLD;
    ELSE PERFORM refresh_conversation_involvement(NEW.conversation_id); RETURN NEW; END IF;
END;
$$;

CREATE TRIGGER trg_task_involvement AFTER INSERT OR UPDATE OR DELETE ON teamwork.tasks FOR EACH ROW EXECUTE FUNCTION trigger_refresh_task_involvement();
CREATE TRIGGER trg_task_assignee_involvement AFTER INSERT OR UPDATE OR DELETE ON teamwork.task_assignees FOR EACH ROW EXECUTE FUNCTION trigger_refresh_task_assignee_involvement();
CREATE TRIGGER trg_message_involvement AFTER INSERT OR UPDATE OR DELETE ON missive.messages FOR EACH ROW EXECUTE FUNCTION trigger_refresh_message_involvement();
CREATE TRIGGER trg_recipient_involvement AFTER INSERT OR UPDATE OR DELETE ON missive.message_recipients FOR EACH ROW EXECUTE FUNCTION trigger_refresh_recipient_involvement();
CREATE TRIGGER trg_conversation_assignee_involvement AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_assignees FOR EACH ROW EXECUTE FUNCTION trigger_refresh_conversation_involvement();
CREATE TRIGGER trg_conversation_author_involvement AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_authors FOR EACH ROW EXECUTE FUNCTION trigger_refresh_conversation_involvement();
CREATE TRIGGER trg_conversation_comment_involvement AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_comments FOR EACH ROW EXECUTE FUNCTION trigger_refresh_conversation_involvement();

-- =====================================
-- 6. RPC FUNCTION
-- =====================================

CREATE OR REPLACE FUNCTION get_unified_items_by_involved_person(
    p_involved_person_search TEXT,
    p_show_tasks BOOLEAN DEFAULT TRUE,
    p_show_emails BOOLEAN DEFAULT TRUE,
    p_show_craft BOOLEAN DEFAULT TRUE,
    p_text_search TEXT DEFAULT NULL,
    p_sort_field TEXT DEFAULT 'sort_date',
    p_sort_order TEXT DEFAULT 'desc',
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0,
    p_selected_task_types UUID[] DEFAULT NULL
)
RETURNS TABLE(
    id TEXT, type TEXT, name TEXT, description TEXT, status VARCHAR, project TEXT, customer TEXT,
    location TEXT, location_path TEXT, cost_group TEXT, cost_group_code VARCHAR(50),
    due_date TIMESTAMP, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, priority VARCHAR,
    progress INTEGER, tasklist TEXT, task_type_id UUID, task_type_name TEXT,
    task_type_slug TEXT, task_type_color VARCHAR(50), assignees JSONB, tags JSONB,
    body TEXT, preview TEXT, from_name TEXT, from_email TEXT, conversation_subject TEXT,
    recipients JSONB, attachments JSONB, attachment_count INTEGER, conversation_comments_text TEXT,
    craft_url TEXT, teamwork_url TEXT, missive_url TEXT, sort_date TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_person_ids UUID[];
    v_has_filter BOOLEAN;
BEGIN
    IF p_sort_field NOT IN ('name', 'status', 'project', 'customer', 'due_date', 'created_at', 'updated_at', 'priority', 'sort_date') THEN p_sort_field := 'sort_date'; END IF;
    IF p_sort_order NOT IN ('asc', 'desc') THEN p_sort_order := 'desc'; END IF;
    
    v_has_filter := p_involved_person_search IS NOT NULL AND TRIM(p_involved_person_search) != '';
    IF v_has_filter THEN
        v_person_ids := find_person_ids_by_search(p_involved_person_search);
        IF array_length(v_person_ids, 1) IS NULL THEN RETURN; END IF;
    END IF;
    
    RETURN QUERY
    SELECT ui.id, ui.type, ui.name, ui.description, ui.status, ui.project, ui.customer,
        ui.location, ui.location_path, ui.cost_group, ui.cost_group_code,
        ui.due_date, ui.created_at, ui.updated_at, ui.priority, ui.progress, ui.tasklist,
        ui.task_type_id, ui.task_type_name, ui.task_type_slug, ui.task_type_color,
        ui.assignees, ui.tags, ui.body, ui.preview, ui.from_name, ui.from_email,
        ui.conversation_subject, ui.recipients, ui.attachments, ui.attachment_count,
        ui.conversation_comments_text, ui.craft_url, ui.teamwork_url, ui.missive_url, ui.sort_date
    FROM unified_items ui
    WHERE ((p_show_tasks AND ui.type = 'task' AND (p_selected_task_types IS NULL OR ui.task_type_id = ANY(p_selected_task_types)))
            OR (p_show_emails AND ui.type = 'email') OR (p_show_craft AND ui.type = 'craft'))
        AND (NOT v_has_filter OR EXISTS (SELECT 1 FROM item_involved_persons iip WHERE iip.item_id = ui.id AND iip.item_type = ui.type AND iip.unified_person_id = ANY(v_person_ids)))
        AND (p_text_search IS NULL OR LOWER(ui.name) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.description) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.body) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.preview) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.conversation_comments_text) LIKE '%' || LOWER(p_text_search) || '%')
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
        CASE WHEN p_sort_field = 'priority' AND p_sort_order = 'asc' THEN ui.priority END ASC NULLS LAST
    LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION count_unified_items_by_involved_person(
    p_involved_person_search TEXT,
    p_show_tasks BOOLEAN DEFAULT TRUE,
    p_show_emails BOOLEAN DEFAULT TRUE,
    p_show_craft BOOLEAN DEFAULT TRUE,
    p_text_search TEXT DEFAULT NULL,
    p_selected_task_types UUID[] DEFAULT NULL
)
RETURNS INTEGER LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_count INTEGER;
    v_person_ids UUID[];
    v_has_filter BOOLEAN;
BEGIN
    v_has_filter := p_involved_person_search IS NOT NULL AND TRIM(p_involved_person_search) != '';
    IF v_has_filter THEN
        v_person_ids := find_person_ids_by_search(p_involved_person_search);
        IF array_length(v_person_ids, 1) IS NULL THEN RETURN 0; END IF;
    END IF;
    
    SELECT COUNT(*)::INTEGER INTO v_count FROM unified_items ui
    WHERE ((p_show_tasks AND ui.type = 'task' AND (p_selected_task_types IS NULL OR ui.task_type_id = ANY(p_selected_task_types)))
            OR (p_show_emails AND ui.type = 'email') OR (p_show_craft AND ui.type = 'craft'))
        AND (NOT v_has_filter OR EXISTS (SELECT 1 FROM item_involved_persons iip WHERE iip.item_id = ui.id AND iip.item_type = ui.type AND iip.unified_person_id = ANY(v_person_ids)))
        AND (p_text_search IS NULL OR LOWER(ui.name) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.description) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.body) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.preview) LIKE '%' || LOWER(p_text_search) || '%'
            OR LOWER(ui.conversation_comments_text) LIKE '%' || LOWER(p_text_search) || '%');
    RETURN v_count;
END;
$$;

-- =====================================
-- 7. INITIAL POPULATION
-- =====================================

SELECT refresh_item_involved_persons();
