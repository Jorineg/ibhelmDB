-- =====================================
-- ALL FUNCTIONS (IDEMPOTENT)
-- =====================================
-- All functions use CREATE OR REPLACE - safe to re-run

-- =====================================
-- 1. AUTO-UPDATE TIMESTAMPS
-- =====================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.db_updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION update_updated_at_column() IS 'Generic trigger function to update db_updated_at timestamp';

-- =====================================
-- 2. LOCATION HIERARCHY
-- =====================================

CREATE OR REPLACE FUNCTION update_location_hierarchy()
RETURNS TRIGGER AS $$
DECLARE
    parent_rec RECORD;
    parent_path TEXT := '';
    parent_path_ids UUID[] := ARRAY[]::UUID[];
    parent_search TEXT := '';
BEGIN
    NEW.depth := CASE NEW.type
        WHEN 'building' THEN 0
        WHEN 'level' THEN 1
        WHEN 'room' THEN 2
    END;
    
    IF NEW.parent_id IS NOT NULL THEN
        SELECT path, path_ids, search_text, depth INTO parent_rec
        FROM locations WHERE id = NEW.parent_id;
        
        IF FOUND THEN
            parent_path := parent_rec.path;
            parent_path_ids := parent_rec.path_ids;
            parent_search := parent_rec.search_text;
            IF NEW.depth != parent_rec.depth + 1 THEN
                RAISE EXCEPTION 'Location depth must be parent depth + 1';
            END IF;
        END IF;
    END IF;
    
    IF parent_path = '' OR parent_path IS NULL THEN
        NEW.path := NEW.id::TEXT;
    ELSE
        NEW.path := parent_path || '.' || NEW.id::TEXT;
    END IF;
    
    NEW.path_ids := parent_path_ids || NEW.id;
    
    IF parent_search = '' OR parent_search IS NULL THEN
        NEW.search_text := NEW.name;
    ELSE
        NEW.search_text := parent_search || ' / ' || NEW.name;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_location_children()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.name != NEW.name OR OLD.path != NEW.path THEN
        UPDATE locations SET db_updated_at = NOW() WHERE parent_id = NEW.id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- 3. COST GROUP HIERARCHY
-- =====================================

CREATE OR REPLACE FUNCTION update_cost_group_path()
RETURNS TRIGGER AS $$
DECLARE
    parent_path TEXT := '';
BEGIN
    IF NEW.parent_id IS NOT NULL THEN
        SELECT path INTO parent_path FROM cost_groups WHERE id = NEW.parent_id;
    END IF;
    
    IF parent_path = '' OR parent_path IS NULL THEN
        NEW.path := NEW.code::TEXT;
    ELSE
        NEW.path := parent_path || '.' || NEW.code::TEXT;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_or_create_cost_group(p_code INTEGER, p_name TEXT)
RETURNS UUID SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_cost_group_id UUID;
    v_parent_code INTEGER;
    v_parent_id UUID;
BEGIN
    SELECT id INTO v_cost_group_id FROM cost_groups WHERE code = p_code;
    IF FOUND THEN RETURN v_cost_group_id; END IF;
    
    IF p_code % 10 != 0 THEN
        v_parent_code := (p_code / 10) * 10;
    ELSIF p_code % 100 != 0 THEN
        v_parent_code := (p_code / 100) * 100;
    ELSE
        v_parent_code := NULL;
    END IF;
    
    IF v_parent_code IS NOT NULL THEN
        v_parent_id := get_or_create_cost_group(v_parent_code, NULL);
    END IF;
    
    INSERT INTO cost_groups (code, name, parent_id)
    VALUES (p_code, p_name, v_parent_id)
    RETURNING id INTO v_cost_group_id;
    
    RETURN v_cost_group_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION parse_cost_group_tag(p_tag_name TEXT, p_prefixes TEXT[])
RETURNS TABLE(code INTEGER, name TEXT) AS $$
DECLARE
    v_prefix TEXT;
    v_pattern TEXT;
    v_match TEXT[];
BEGIN
    FOREACH v_prefix IN ARRAY p_prefixes LOOP
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

-- =====================================
-- 4. LOCATION EXTRACTION
-- =====================================

-- Parse location tag: O-Gebäude-Raum, O-Raum, O-Gebäude-Level-Raum
CREATE OR REPLACE FUNCTION parse_location_tag(p_tag_name TEXT, p_prefix TEXT)
RETURNS TABLE(building TEXT, level TEXT, room TEXT) AS $$
DECLARE
    v_pattern TEXT;
    v_match TEXT[];
    v_parts TEXT[];
    v_remainder TEXT;
BEGIN
    IF p_prefix IS NULL OR p_prefix = '' THEN
        p_prefix := 'O-';
    END IF;
    
    -- Check if tag starts with prefix
    IF NOT (LOWER(p_tag_name) LIKE LOWER(p_prefix) || '%') THEN
        RETURN;
    END IF;
    
    -- Get remainder after prefix
    v_remainder := SUBSTRING(p_tag_name FROM LENGTH(p_prefix) + 1);
    IF v_remainder IS NULL OR v_remainder = '' THEN
        RETURN;
    END IF;
    
    -- Split by hyphen
    v_parts := string_to_array(v_remainder, '-');
    
    IF array_length(v_parts, 1) = 1 THEN
        -- O-Raum: just room, no building or level
        room := TRIM(v_parts[1]);
        building := NULL;
        level := NULL;
        RETURN NEXT;
    ELSIF array_length(v_parts, 1) = 2 THEN
        -- O-Gebäude-Raum: building + room, use default level
        building := TRIM(v_parts[1]);
        level := 'Standard';
        room := TRIM(v_parts[2]);
        RETURN NEXT;
    ELSIF array_length(v_parts, 1) >= 3 THEN
        -- O-Gebäude-Level-Raum: full hierarchy
        building := TRIM(v_parts[1]);
        level := TRIM(v_parts[2]);
        room := TRIM(v_parts[3]);
        RETURN NEXT;
    END IF;
    RETURN;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Get or create location hierarchy, returns room ID
CREATE OR REPLACE FUNCTION get_or_create_location(p_building TEXT, p_level TEXT, p_room TEXT)
RETURNS UUID SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_building_id UUID;
    v_level_id UUID;
    v_room_id UUID;
BEGIN
    -- Case 1: Room only (no building/level)
    IF p_building IS NULL THEN
        SELECT id INTO v_room_id FROM locations WHERE name = p_room AND type = 'room' AND parent_id IS NULL;
        IF NOT FOUND THEN
            INSERT INTO locations (name, type, parent_id)
            VALUES (p_room, 'room', NULL)
            RETURNING id INTO v_room_id;
        END IF;
        RETURN v_room_id;
    END IF;
    
    -- Case 2: Building + Level + Room
    -- Get or create building
    SELECT id INTO v_building_id FROM locations WHERE name = p_building AND type = 'building';
    IF NOT FOUND THEN
        INSERT INTO locations (name, type, parent_id)
        VALUES (p_building, 'building', NULL)
        RETURNING id INTO v_building_id;
    END IF;
    
    -- Get or create level under building
    SELECT id INTO v_level_id FROM locations WHERE name = p_level AND type = 'level' AND parent_id = v_building_id;
    IF NOT FOUND THEN
        INSERT INTO locations (name, type, parent_id)
        VALUES (p_level, 'level', v_building_id)
        RETURNING id INTO v_level_id;
    END IF;
    
    -- Get or create room under level
    SELECT id INTO v_room_id FROM locations WHERE name = p_room AND type = 'room' AND parent_id = v_level_id;
    IF NOT FOUND THEN
        INSERT INTO locations (name, type, parent_id)
        VALUES (p_room, 'room', v_level_id)
        RETURNING id INTO v_room_id;
    END IF;
    
    RETURN v_room_id;
END;
$$ LANGUAGE plpgsql;

-- Extract locations from task tags
CREATE OR REPLACE FUNCTION extract_locations_for_task(p_task_id INTEGER)
RETURNS void SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_prefix TEXT;
    v_tag_record RECORD;
    v_parsed RECORD;
    v_location_id UUID;
BEGIN
    SELECT COALESCE(body->>'location_prefix', 'O-') INTO v_prefix
    FROM app_settings WHERE lock = 'X';
    
    DELETE FROM object_locations WHERE tw_task_id = p_task_id AND source = 'auto_teamwork';
    
    FOR v_tag_record IN 
        SELECT t.name AS tag_name
        FROM teamwork.task_tags tt JOIN teamwork.tags t ON tt.tag_id = t.id
        WHERE tt.task_id = p_task_id
    LOOP
        SELECT * INTO v_parsed FROM parse_location_tag(v_tag_record.tag_name, v_prefix);
        IF v_parsed.room IS NOT NULL THEN
            v_location_id := get_or_create_location(v_parsed.building, v_parsed.level, v_parsed.room);
            INSERT INTO object_locations (location_id, tw_task_id, source, source_tag_name)
            VALUES (v_location_id, p_task_id, 'auto_teamwork', v_tag_record.tag_name)
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Extract locations from conversation labels
CREATE OR REPLACE FUNCTION extract_locations_for_conversation(p_conversation_id UUID)
RETURNS void SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_prefix TEXT;
    v_label_record RECORD;
    v_parsed RECORD;
    v_location_id UUID;
BEGIN
    SELECT COALESCE(body->>'location_prefix', 'O-') INTO v_prefix
    FROM app_settings WHERE lock = 'X';
    
    DELETE FROM object_locations WHERE m_conversation_id = p_conversation_id AND source = 'auto_missive';
    
    FOR v_label_record IN 
        SELECT sl.name AS label_name
        FROM missive.conversation_labels cl JOIN missive.shared_labels sl ON cl.label_id = sl.id
        WHERE cl.conversation_id = p_conversation_id
    LOOP
        SELECT * INTO v_parsed FROM parse_location_tag(v_label_record.label_name, v_prefix);
        IF v_parsed.room IS NOT NULL THEN
            v_location_id := get_or_create_location(v_parsed.building, v_parsed.level, v_parsed.room);
            INSERT INTO object_locations (location_id, m_conversation_id, source, source_tag_name)
            VALUES (v_location_id, p_conversation_id, 'auto_missive', v_label_record.label_name)
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Trigger functions for auto-extraction
CREATE OR REPLACE FUNCTION trigger_extract_locations_for_task()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM object_locations WHERE tw_task_id = OLD.task_id AND source = 'auto_teamwork';
        RETURN OLD;
    ELSE
        PERFORM extract_locations_for_task(NEW.task_id);
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_extract_locations_for_conversation()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM object_locations WHERE m_conversation_id = OLD.conversation_id AND source = 'auto_missive';
        RETURN OLD;
    ELSE
        PERFORM extract_locations_for_conversation(NEW.conversation_id);
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- 5. TASK TYPE EXTRACTION
-- =====================================

CREATE OR REPLACE FUNCTION extract_task_type(p_task_id INTEGER)
RETURNS void AS $$
DECLARE
    v_matched_type_id UUID;
    v_matched_tag_name TEXT;
    v_default_type_id UUID;
BEGIN
    SELECT ttr.task_type_id, ttr.teamwork_tag_name INTO v_matched_type_id, v_matched_tag_name
    FROM teamwork.task_tags tt
    JOIN teamwork.tags t ON tt.tag_id = t.id
    JOIN task_type_rules ttr ON LOWER(t.name) = LOWER(ttr.teamwork_tag_name)
    WHERE tt.task_id = p_task_id LIMIT 1;

    IF v_matched_type_id IS NULL THEN
        SELECT id INTO v_default_type_id FROM task_types WHERE is_default = TRUE LIMIT 1;
        v_matched_type_id := v_default_type_id;
        v_matched_tag_name := NULL;
    END IF;

    INSERT INTO task_extensions (tw_task_id, task_type_id, type_source, type_source_tag_name)
    VALUES (p_task_id, v_matched_type_id, 'auto', v_matched_tag_name)
    ON CONFLICT (tw_task_id) DO UPDATE SET
        task_type_id = EXCLUDED.task_type_id,
        type_source = 'auto',
        type_source_tag_name = EXCLUDED.type_source_tag_name,
        db_updated_at = NOW()
    WHERE task_extensions.type_source = 'auto' OR task_extensions.type_source IS NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_extract_task_type()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM extract_task_type(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

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

-- =====================================
-- 5. COST GROUP EXTRACTION
-- =====================================

CREATE OR REPLACE FUNCTION extract_cost_groups_for_task(p_task_id INTEGER)
RETURNS void SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_prefixes TEXT[];
    v_tag_record RECORD;
    v_parsed RECORD;
    v_cost_group_id UUID;
BEGIN
    SELECT COALESCE(
        (SELECT ARRAY(SELECT jsonb_array_elements_text(body->'cost_group_prefixes')) 
         FROM app_settings WHERE lock = 'X'),
        ARRAY['KGR']
    ) INTO v_prefixes;
    
    DELETE FROM object_cost_groups WHERE tw_task_id = p_task_id AND source = 'auto_teamwork';
    
    FOR v_tag_record IN 
        SELECT t.name AS tag_name
        FROM teamwork.task_tags tt JOIN teamwork.tags t ON tt.tag_id = t.id
        WHERE tt.task_id = p_task_id
    LOOP
        SELECT * INTO v_parsed FROM parse_cost_group_tag(v_tag_record.tag_name, v_prefixes);
        IF v_parsed.code IS NOT NULL THEN
            v_cost_group_id := get_or_create_cost_group(v_parsed.code, v_parsed.name);
            INSERT INTO object_cost_groups (cost_group_id, tw_task_id, source, source_tag_name)
            VALUES (v_cost_group_id, p_task_id, 'auto_teamwork', v_tag_record.tag_name)
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION extract_cost_groups_for_conversation(p_conversation_id UUID)
RETURNS void SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_prefixes TEXT[];
    v_label_record RECORD;
    v_parsed RECORD;
    v_cost_group_id UUID;
BEGIN
    SELECT COALESCE(
        (SELECT ARRAY(SELECT jsonb_array_elements_text(body->'cost_group_prefixes')) 
         FROM app_settings WHERE lock = 'X'),
        ARRAY['KGR']
    ) INTO v_prefixes;
    
    DELETE FROM object_cost_groups WHERE m_conversation_id = p_conversation_id AND source = 'auto_missive';
    
    FOR v_label_record IN 
        SELECT sl.name AS label_name
        FROM missive.conversation_labels cl JOIN missive.shared_labels sl ON cl.label_id = sl.id
        WHERE cl.conversation_id = p_conversation_id
    LOOP
        SELECT * INTO v_parsed FROM parse_cost_group_tag(v_label_record.label_name, v_prefixes);
        IF v_parsed.code IS NOT NULL THEN
            v_cost_group_id := get_or_create_cost_group(v_parsed.code, v_parsed.name);
            INSERT INTO object_cost_groups (cost_group_id, m_conversation_id, source, source_tag_name)
            VALUES (v_cost_group_id, p_conversation_id, 'auto_missive', v_label_record.label_name)
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Trigger functions for cost group auto-extraction
CREATE OR REPLACE FUNCTION trigger_extract_cost_groups_for_task()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM object_cost_groups WHERE tw_task_id = OLD.task_id AND source = 'auto_teamwork';
        RETURN OLD;
    ELSE
        PERFORM extract_cost_groups_for_task(NEW.task_id);
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_extract_cost_groups_for_conversation()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM object_cost_groups WHERE m_conversation_id = OLD.conversation_id AND source = 'auto_missive';
        RETURN OLD;
    ELSE
        PERFORM extract_cost_groups_for_conversation(NEW.conversation_id);
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- 6. UNIFIED PERSON LINKING
-- =====================================

CREATE OR REPLACE FUNCTION link_person_from_missive_contact(p_contact_id INTEGER)
RETURNS TEXT AS $$
DECLARE
    v_contact RECORD;
    v_existing_person_id UUID;
    v_existing_link_count INTEGER;
    v_new_person_id UUID;
BEGIN
    SELECT id, name, email INTO v_contact FROM missive.contacts WHERE id = p_contact_id;
    IF NOT FOUND THEN RETURN 'skipped'; END IF;
    
    SELECT COUNT(*) INTO v_existing_link_count FROM unified_person_links WHERE m_contact_id = p_contact_id;
    IF v_existing_link_count > 0 THEN RETURN 'skipped'; END IF;
    
    IF v_contact.email IS NOT NULL AND v_contact.email != '' THEN
        SELECT id INTO v_existing_person_id FROM unified_persons
        WHERE LOWER(primary_email) = LOWER(v_contact.email) LIMIT 1;
    END IF;
    
    IF v_existing_person_id IS NOT NULL THEN
        INSERT INTO unified_person_links (unified_person_id, m_contact_id, link_type)
        VALUES (v_existing_person_id, p_contact_id, 'auto_email');
        RETURN 'linked';
    ELSE
        INSERT INTO unified_persons (display_name, primary_email)
        VALUES (COALESCE(NULLIF(v_contact.name, ''), v_contact.email), v_contact.email)
        RETURNING id INTO v_new_person_id;
        
        INSERT INTO unified_person_links (unified_person_id, m_contact_id, link_type)
        VALUES (v_new_person_id, p_contact_id, 'auto_email');
        RETURN 'created';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION link_person_from_teamwork_user(p_user_id INTEGER)
RETURNS TEXT AS $$
DECLARE
    v_user RECORD;
    v_existing_person_id UUID;
    v_existing_link_count INTEGER;
    v_new_person_id UUID;
    v_display_name TEXT;
BEGIN
    SELECT id, first_name, last_name, email INTO v_user FROM teamwork.users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN 'skipped'; END IF;
    
    SELECT COUNT(*) INTO v_existing_link_count FROM unified_person_links WHERE tw_user_id = p_user_id;
    IF v_existing_link_count > 0 THEN RETURN 'skipped'; END IF;
    
    v_display_name := TRIM(COALESCE(v_user.first_name, '') || ' ' || COALESCE(v_user.last_name, ''));
    IF v_display_name = '' THEN v_display_name := v_user.email; END IF;
    
    IF v_user.email IS NOT NULL AND v_user.email != '' THEN
        SELECT id INTO v_existing_person_id FROM unified_persons
        WHERE LOWER(primary_email) = LOWER(v_user.email) LIMIT 1;
    END IF;
    
    IF v_existing_person_id IS NOT NULL THEN
        INSERT INTO unified_person_links (unified_person_id, tw_user_id, link_type)
        VALUES (v_existing_person_id, p_user_id, 'auto_email');
        RETURN 'linked';
    ELSE
        INSERT INTO unified_persons (display_name, primary_email)
        VALUES (v_display_name, v_user.email)
        RETURNING id INTO v_new_person_id;
        
        INSERT INTO unified_person_links (unified_person_id, tw_user_id, link_type)
        VALUES (v_new_person_id, p_user_id, 'auto_email');
        RETURN 'created';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_link_person_from_missive_contact()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM link_person_from_missive_contact(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_link_person_from_teamwork_user()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM link_person_from_teamwork_user(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- 7. PROJECT-CONVERSATION LINKING
-- =====================================

CREATE OR REPLACE FUNCTION link_projects_for_conversation(p_conversation_id UUID)
RETURNS INTEGER AS $$
DECLARE
    v_label RECORD;
    v_project RECORD;
    v_links_created INTEGER := 0;
    v_existing_count INTEGER;
BEGIN
    FOR v_label IN 
        SELECT sl.id as label_id, sl.name as label_name
        FROM missive.conversation_labels cl
        JOIN missive.shared_labels sl ON cl.label_id = sl.id
        WHERE cl.conversation_id = p_conversation_id
    LOOP
        FOR v_project IN 
            SELECT id, name FROM teamwork.projects
            WHERE LOWER(name) = LOWER(v_label.label_name)
        LOOP
            SELECT COUNT(*) INTO v_existing_count FROM project_conversations
            WHERE m_conversation_id = p_conversation_id AND tw_project_id = v_project.id;
            
            IF v_existing_count = 0 THEN
                INSERT INTO project_conversations (m_conversation_id, tw_project_id, source, source_label_name, assigned_at)
                VALUES (p_conversation_id, v_project.id, 'auto_label', v_label.label_name, NOW());
                v_links_created := v_links_created + 1;
            END IF;
        END LOOP;
    END LOOP;
    RETURN v_links_created;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_link_projects_on_conversation_insert()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM link_projects_for_conversation(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_link_projects_on_label_change()
RETURNS TRIGGER AS $$
DECLARE
    v_label_name TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        -- Get the label name that was removed
        SELECT name INTO v_label_name FROM missive.shared_labels WHERE id = OLD.label_id;
        -- Remove auto-links created from this label
        DELETE FROM project_conversations 
        WHERE m_conversation_id = OLD.conversation_id 
          AND source = 'auto_label' 
          AND source_label_name = v_label_name;
        RETURN OLD;
    ELSE
        PERFORM link_projects_for_conversation(NEW.conversation_id);
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- 8. INVOLVED PERSONS
-- =====================================

CREATE OR REPLACE FUNCTION find_person_ids_by_search(p_search_text TEXT)
RETURNS UUID[] LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_pattern TEXT;
    v_result UUID[];
BEGIN
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN RETURN ARRAY[]::UUID[]; END IF;
    v_pattern := '%' || p_search_text || '%';
    
    SELECT ARRAY_AGG(DISTINCT up.id) INTO v_result
    FROM unified_persons up
    LEFT JOIN unified_person_links upl ON up.id = upl.unified_person_id
    LEFT JOIN teamwork.users twu ON upl.tw_user_id = twu.id
    LEFT JOIN teamwork.companies twc ON upl.tw_company_id = twc.id
    LEFT JOIN missive.contacts mc ON upl.m_contact_id = mc.id
    WHERE up.display_name ILIKE v_pattern OR up.primary_email ILIKE v_pattern
        OR twu.first_name ILIKE v_pattern OR twu.last_name ILIKE v_pattern
        OR twu.email ILIKE v_pattern
        OR (COALESCE(twu.first_name, '') || ' ' || COALESCE(twu.last_name, '')) ILIKE v_pattern
        OR twc.name ILIKE v_pattern OR twc.email_one ILIKE v_pattern
        OR mc.name ILIKE v_pattern OR mc.email ILIKE v_pattern;
    
    RETURN COALESCE(v_result, ARRAY[]::UUID[]);
END;
$$;

CREATE OR REPLACE FUNCTION refresh_item_involved_persons()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE item_involved_persons;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT t.id::TEXT, 'task', upl.unified_person_id, 'assignee'
    FROM teamwork.tasks t
    JOIN teamwork.task_assignees ta ON ta.task_id = t.id
    JOIN unified_person_links upl ON upl.tw_user_id = ta.user_id
    WHERE t.deleted_at IS NULL AND upl.unified_person_id IS NOT NULL;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT t.id::TEXT, 'task', upl.unified_person_id, 'creator'
    FROM teamwork.tasks t JOIN unified_person_links upl ON upl.tw_user_id = t.created_by_id
    WHERE t.deleted_at IS NULL AND upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT t.id::TEXT, 'task', upl.unified_person_id, 'updater'
    FROM teamwork.tasks t JOIN unified_person_links upl ON upl.tw_user_id = t.updated_by_id
    WHERE t.deleted_at IS NULL AND t.updated_by_id IS NOT NULL AND upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT m.id::TEXT, 'email', upl.unified_person_id, 'sender'
    FROM missive.messages m JOIN unified_person_links upl ON upl.m_contact_id = m.from_contact_id
    WHERE upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT m.id::TEXT, 'email', upl.unified_person_id, 'recipient'
    FROM missive.messages m
    JOIN missive.message_recipients mr ON mr.message_id = m.id
    JOIN unified_person_links upl ON upl.m_contact_id = mr.contact_id
    WHERE upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT m.id::TEXT, 'email', upl.unified_person_id, 'conversation_assignee'
    FROM missive.messages m
    JOIN missive.conversations c ON c.id = m.conversation_id
    JOIN missive.conversation_assignees ca ON ca.conversation_id = c.id
    JOIN missive.users mu ON mu.id = ca.user_id
    JOIN unified_person_links upl ON upl.m_contact_id = mu.contact_id
    WHERE upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT m.id::TEXT, 'email', upl.unified_person_id, 'conversation_author'
    FROM missive.messages m
    JOIN missive.conversations c ON c.id = m.conversation_id
    JOIN missive.conversation_authors cauth ON cauth.conversation_id = c.id
    JOIN unified_person_links upl ON upl.m_contact_id = cauth.contact_id
    WHERE upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
    
    INSERT INTO item_involved_persons (item_id, item_type, unified_person_id, involvement_type)
    SELECT DISTINCT m.id::TEXT, 'email', upl.unified_person_id, 'conversation_commentator'
    FROM missive.messages m
    JOIN missive.conversations c ON c.id = m.conversation_id
    JOIN missive.conversation_comments cc ON cc.conversation_id = c.id
    JOIN missive.users mu ON mu.id = cc.author_id
    JOIN unified_person_links upl ON upl.m_contact_id = mu.contact_id
    WHERE upl.unified_person_id IS NOT NULL ON CONFLICT DO NOTHING;
END;
$$;

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

-- =====================================
-- 9. BULK OPERATION FUNCTIONS
-- =====================================

CREATE OR REPLACE FUNCTION get_operation_run_status(p_run_id UUID)
RETURNS TABLE (
    id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT
) AS $$
BEGIN
    RETURN QUERY SELECT r.id, r.status, r.total_count, r.processed_count,
        r.created_count, r.linked_count, r.skipped_count,
        CASE WHEN r.total_count > 0 THEN ROUND((r.processed_count::NUMERIC / r.total_count::NUMERIC) * 100, 1) ELSE 0 END,
        r.started_at, r.completed_at, r.error_message
    FROM operation_runs r WHERE r.id = p_run_id;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_latest_operation_run(p_run_type VARCHAR(50))
RETURNS TABLE (
    id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT
) AS $$
BEGIN
    RETURN QUERY SELECT r.id, r.status, r.total_count, r.processed_count,
        r.created_count, r.linked_count, r.skipped_count,
        CASE WHEN r.total_count > 0 THEN ROUND((r.processed_count::NUMERIC / r.total_count::NUMERIC) * 100, 1) ELSE 0 END,
        r.started_at, r.completed_at, r.error_message
    FROM operation_runs r WHERE r.run_type = p_run_type ORDER BY r.started_at DESC LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION rerun_all_task_type_extractions()
RETURNS UUID AS $$
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

CREATE OR REPLACE FUNCTION rerun_all_person_linking()
RETURNS UUID SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_run_id UUID;
    v_total_count INTEGER;
    v_processed INTEGER := 0;
    v_created INTEGER := 0;
    v_linked INTEGER := 0;
    v_skipped INTEGER := 0;
    v_record RECORD;
    v_result TEXT;
BEGIN
    INSERT INTO operation_runs (run_type, status, started_at)
    VALUES ('person_linking', 'running', NOW())
    RETURNING id INTO v_run_id;

    SELECT (SELECT COUNT(*) FROM missive.contacts) + (SELECT COUNT(*) FROM teamwork.users) INTO v_total_count;
    UPDATE operation_runs SET total_count = v_total_count WHERE id = v_run_id;

    FOR v_record IN SELECT id FROM missive.contacts ORDER BY id LOOP
        BEGIN
            v_result := link_person_from_missive_contact(v_record.id);
            v_processed := v_processed + 1;
            IF v_result = 'created' THEN v_created := v_created + 1;
            ELSIF v_result = 'linked' THEN v_linked := v_linked + 1;
            ELSE v_skipped := v_skipped + 1; END IF;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed, created_count = v_created,
                    linked_count = v_linked, skipped_count = v_skipped WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_processed := v_processed + 1; v_skipped := v_skipped + 1;
        END;
    END LOOP;

    FOR v_record IN SELECT id FROM teamwork.users ORDER BY id LOOP
        BEGIN
            v_result := link_person_from_teamwork_user(v_record.id);
            v_processed := v_processed + 1;
            IF v_result = 'created' THEN v_created := v_created + 1;
            ELSIF v_result = 'linked' THEN v_linked := v_linked + 1;
            ELSE v_skipped := v_skipped + 1; END IF;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed, created_count = v_created,
                    linked_count = v_linked, skipped_count = v_skipped WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_processed := v_processed + 1; v_skipped := v_skipped + 1;
        END;
    END LOOP;

    UPDATE operation_runs SET status = 'completed', processed_count = v_processed, created_count = v_created,
        linked_count = v_linked, skipped_count = v_skipped, completed_at = NOW() WHERE id = v_run_id;
    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION rerun_all_project_conversation_linking()
RETURNS UUID SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_run_id UUID;
    v_total_count INTEGER;
    v_processed INTEGER := 0;
    v_linked INTEGER := 0;
    v_skipped INTEGER := 0;
    v_record RECORD;
    v_result INTEGER;
BEGIN
    INSERT INTO operation_runs (run_type, status, started_at)
    VALUES ('project_linking', 'running', NOW())
    RETURNING id INTO v_run_id;

    SELECT COUNT(DISTINCT cl.conversation_id) INTO v_total_count FROM missive.conversation_labels cl;
    UPDATE operation_runs SET total_count = v_total_count WHERE id = v_run_id;

    FOR v_record IN SELECT DISTINCT cl.conversation_id FROM missive.conversation_labels cl ORDER BY cl.conversation_id LOOP
        BEGIN
            v_result := link_projects_for_conversation(v_record.conversation_id);
            v_processed := v_processed + 1;
            IF v_result > 0 THEN v_linked := v_linked + v_result;
            ELSE v_skipped := v_skipped + 1; END IF;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed, linked_count = v_linked, skipped_count = v_skipped
                WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_processed := v_processed + 1; v_skipped := v_skipped + 1;
        END;
    END LOOP;

    UPDATE operation_runs SET status = 'completed', processed_count = v_processed, linked_count = v_linked,
        skipped_count = v_skipped, completed_at = NOW() WHERE id = v_run_id;
    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION rerun_all_cost_group_linking()
RETURNS UUID SECURITY DEFINER SET search_path = public AS $$
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
    INSERT INTO operation_runs (run_type, status, started_at)
    VALUES ('cost_group_linking', 'running', NOW())
    RETURNING id INTO v_run_id;

    SELECT COUNT(*) INTO v_task_count FROM teamwork.tasks WHERE deleted_at IS NULL;
    SELECT COUNT(*) INTO v_conv_count FROM missive.conversations;
    v_total_count := v_task_count + v_conv_count;
    UPDATE operation_runs SET total_count = v_total_count WHERE id = v_run_id;
    
    SELECT COUNT(*) INTO v_initial_cg_count FROM cost_groups;
    SELECT COUNT(*) INTO v_initial_link_count FROM object_cost_groups;

    FOR v_record IN SELECT id FROM teamwork.tasks WHERE deleted_at IS NULL LOOP
        BEGIN
            PERFORM extract_cost_groups_for_task(v_record.id);
            v_processed := v_processed + 1;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;

    FOR v_record IN SELECT id FROM missive.conversations LOOP
        BEGIN
            PERFORM extract_cost_groups_for_conversation(v_record.id);
            v_processed := v_processed + 1;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;

    SELECT COUNT(*) INTO v_final_cg_count FROM cost_groups;
    SELECT COUNT(*) INTO v_final_link_count FROM object_cost_groups;
    v_created := v_final_cg_count - v_initial_cg_count;
    v_linked := v_final_link_count - v_initial_link_count;

    UPDATE operation_runs SET status = 'completed', processed_count = v_processed,
        created_count = v_created, linked_count = v_linked, completed_at = NOW()
    WHERE id = v_run_id;
    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION rerun_all_location_linking()
RETURNS UUID SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_run_id UUID;
    v_task_count INTEGER;
    v_conv_count INTEGER;
    v_total_count INTEGER;
    v_processed INTEGER := 0;
    v_created INTEGER := 0;
    v_linked INTEGER := 0;
    v_record RECORD;
    v_initial_loc_count INTEGER;
    v_initial_link_count INTEGER;
    v_final_loc_count INTEGER;
    v_final_link_count INTEGER;
BEGIN
    INSERT INTO operation_runs (run_type, status, started_at)
    VALUES ('location_linking', 'running', NOW())
    RETURNING id INTO v_run_id;

    SELECT COUNT(*) INTO v_task_count FROM teamwork.tasks WHERE deleted_at IS NULL;
    SELECT COUNT(*) INTO v_conv_count FROM missive.conversations;
    v_total_count := v_task_count + v_conv_count;
    UPDATE operation_runs SET total_count = v_total_count WHERE id = v_run_id;
    
    SELECT COUNT(*) INTO v_initial_loc_count FROM locations;
    SELECT COUNT(*) INTO v_initial_link_count FROM object_locations;

    FOR v_record IN SELECT id FROM teamwork.tasks WHERE deleted_at IS NULL LOOP
        BEGIN
            PERFORM extract_locations_for_task(v_record.id);
            v_processed := v_processed + 1;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;

    FOR v_record IN SELECT id FROM missive.conversations LOOP
        BEGIN
            PERFORM extract_locations_for_conversation(v_record.id);
            v_processed := v_processed + 1;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;

    SELECT COUNT(*) INTO v_final_loc_count FROM locations;
    SELECT COUNT(*) INTO v_final_link_count FROM object_locations;
    v_created := v_final_loc_count - v_initial_loc_count;
    v_linked := v_final_link_count - v_initial_link_count;

    UPDATE operation_runs SET status = 'completed', processed_count = v_processed,
        created_count = v_created, linked_count = v_linked, completed_at = NOW()
    WHERE id = v_run_id;
    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_location_linking_run_status(p_run_id UUID)
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
AS $$
BEGIN RETURN QUERY SELECT * FROM get_operation_run_status(p_run_id); END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_latest_location_linking_run()
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
AS $$
BEGIN RETURN QUERY SELECT * FROM get_latest_operation_run('location_linking'); END;
$$ LANGUAGE plpgsql STABLE;

-- Wrapper functions for backwards compatibility
CREATE OR REPLACE FUNCTION get_extraction_run_status(p_run_id UUID)
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
AS $$
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
AS $$
BEGIN
    RETURN QUERY SELECT r.id, r.status, r.total_count, r.processed_count,
        CASE WHEN r.total_count > 0 THEN ROUND((r.processed_count::NUMERIC / r.total_count::NUMERIC) * 100, 1) ELSE 0 END,
        r.started_at, r.completed_at, r.error_message
    FROM operation_runs r WHERE r.run_type = 'task_type_extraction' ORDER BY r.started_at DESC LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_person_linking_run_status(p_run_id UUID)
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
SECURITY DEFINER SET search_path = public AS $$
BEGIN RETURN QUERY SELECT * FROM get_operation_run_status(p_run_id); END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_latest_person_linking_run()
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
SECURITY DEFINER SET search_path = public AS $$
BEGIN RETURN QUERY SELECT * FROM get_latest_operation_run('person_linking'); END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_project_linking_run_status(p_run_id UUID)
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    linked_count INTEGER, skipped_count INTEGER, progress_percent NUMERIC,
    started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY SELECT r.id, r.status, r.total_count, r.processed_count, r.linked_count, r.skipped_count,
        CASE WHEN r.total_count > 0 THEN ROUND((r.processed_count::NUMERIC / r.total_count::NUMERIC) * 100, 1) ELSE 0 END,
        r.started_at, r.completed_at, r.error_message
    FROM operation_runs r WHERE r.id = p_run_id;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_latest_project_linking_run()
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    linked_count INTEGER, skipped_count INTEGER, progress_percent NUMERIC,
    started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY SELECT r.id, r.status, r.total_count, r.processed_count, r.linked_count, r.skipped_count,
        CASE WHEN r.total_count > 0 THEN ROUND((r.processed_count::NUMERIC / r.total_count::NUMERIC) * 100, 1) ELSE 0 END,
        r.started_at, r.completed_at, r.error_message
    FROM operation_runs r WHERE r.run_type = 'project_linking' ORDER BY r.started_at DESC LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_cost_group_linking_run_status(p_run_id UUID)
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
AS $$
BEGIN RETURN QUERY SELECT * FROM get_operation_run_status(p_run_id); END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_latest_cost_group_linking_run()
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
AS $$
BEGIN RETURN QUERY SELECT * FROM get_latest_operation_run('cost_group_linking'); END;
$$ LANGUAGE plpgsql STABLE;

-- =====================================
-- 10. AUTOCOMPLETE SEARCH FUNCTIONS
-- =====================================

CREATE OR REPLACE FUNCTION search_companies_autocomplete(p_search_text TEXT, p_limit INTEGER DEFAULT 10)
RETURNS TABLE(id INTEGER, name TEXT, project_count BIGINT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_search_pattern TEXT;
BEGIN
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        RETURN QUERY SELECT c.id, c.name::TEXT, COUNT(p.id) AS project_count
        FROM teamwork.companies c LEFT JOIN teamwork.projects p ON p.company_id = c.id
        GROUP BY c.id, c.name
        ORDER BY c.name ASC LIMIT p_limit;
        RETURN;
    END IF;
    
    v_search_pattern := '%' || p_search_text || '%';
    RETURN QUERY SELECT c.id, c.name::TEXT, COUNT(p.id) AS project_count
    FROM teamwork.companies c LEFT JOIN teamwork.projects p ON p.company_id = c.id
    WHERE c.name ILIKE v_search_pattern
    GROUP BY c.id, c.name
    ORDER BY CASE WHEN c.name ILIKE p_search_text || '%' THEN 0 ELSE 1 END, c.name ASC
    LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION search_projects_autocomplete(p_search_text TEXT, p_limit INTEGER DEFAULT 10)
RETURNS TABLE(id INTEGER, name TEXT, company_name TEXT, status VARCHAR)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_search_pattern TEXT;
BEGIN
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        RETURN QUERY SELECT p.id, p.name::TEXT, c.name::TEXT AS company_name, p.status
        FROM teamwork.projects p LEFT JOIN teamwork.companies c ON p.company_id = c.id
        ORDER BY p.updated_at DESC NULLS LAST, p.name ASC LIMIT p_limit;
        RETURN;
    END IF;
    
    v_search_pattern := '%' || p_search_text || '%';
    RETURN QUERY SELECT p.id, p.name::TEXT, c.name::TEXT AS company_name, p.status
    FROM teamwork.projects p LEFT JOIN teamwork.companies c ON p.company_id = c.id
    WHERE p.name ILIKE v_search_pattern OR c.name ILIKE v_search_pattern OR p.description ILIKE v_search_pattern
    ORDER BY CASE WHEN p.name ILIKE p_search_text || '%' THEN 0 ELSE 1 END,
        CASE p.status WHEN 'active' THEN 0 ELSE 1 END, p.name ASC
    LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION search_persons_autocomplete(p_search_text TEXT, p_limit INTEGER DEFAULT 10)
RETURNS TABLE(id UUID, display_name TEXT, primary_email TEXT, source_type TEXT, is_internal BOOLEAN)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_search_pattern TEXT;
BEGIN
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        RETURN QUERY SELECT up.id, up.display_name::TEXT, up.primary_email::TEXT, 'unified'::TEXT AS source_type, up.is_internal
        FROM unified_persons up ORDER BY up.db_updated_at DESC NULLS LAST, up.display_name ASC LIMIT p_limit;
        RETURN;
    END IF;
    
    v_search_pattern := '%' || p_search_text || '%';
    RETURN QUERY SELECT DISTINCT ON (up.id) up.id, up.display_name::TEXT, up.primary_email::TEXT,
        CASE WHEN upl.tw_user_id IS NOT NULL THEN 'teamwork_user'
             WHEN upl.tw_company_id IS NOT NULL THEN 'teamwork_company'
             WHEN upl.m_contact_id IS NOT NULL THEN 'missive_contact'
             ELSE 'unified' END::TEXT AS source_type, up.is_internal
    FROM unified_persons up
    LEFT JOIN unified_person_links upl ON up.id = upl.unified_person_id
    LEFT JOIN teamwork.users twu ON upl.tw_user_id = twu.id
    LEFT JOIN teamwork.companies twc ON upl.tw_company_id = twc.id
    LEFT JOIN missive.contacts mc ON upl.m_contact_id = mc.id
    WHERE up.display_name ILIKE v_search_pattern OR up.primary_email ILIKE v_search_pattern
        OR twu.first_name ILIKE v_search_pattern OR twu.last_name ILIKE v_search_pattern
        OR twu.email ILIKE v_search_pattern
        OR (COALESCE(twu.first_name, '') || ' ' || COALESCE(twu.last_name, '')) ILIKE v_search_pattern
        OR twc.name ILIKE v_search_pattern OR twc.email_one ILIKE v_search_pattern
        OR mc.name ILIKE v_search_pattern OR mc.email ILIKE v_search_pattern
    ORDER BY up.id, CASE WHEN up.display_name ILIKE p_search_text || '%' THEN 0 ELSE 1 END,
        CASE WHEN up.is_internal THEN 0 ELSE 1 END, up.display_name ASC
    LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION search_cost_groups_autocomplete(p_search_text TEXT, p_limit INTEGER DEFAULT 10)
RETURNS TABLE(id UUID, code INTEGER, name TEXT, path TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_search_code INTEGER; v_code_min INTEGER; v_code_max INTEGER;
BEGIN
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        RETURN QUERY SELECT cg.id, cg.code, cg.name::TEXT, cg.path::TEXT FROM cost_groups cg ORDER BY cg.code ASC LIMIT p_limit;
        RETURN;
    END IF;
    
    BEGIN
        v_search_code := TRIM(p_search_text)::INTEGER;
        IF v_search_code >= 100 AND v_search_code <= 999 THEN v_code_min := v_search_code; v_code_max := v_search_code;
        ELSIF v_search_code >= 10 AND v_search_code <= 99 THEN v_code_min := v_search_code * 10; v_code_max := v_search_code * 10 + 9;
        ELSIF v_search_code >= 1 AND v_search_code <= 9 THEN v_code_min := v_search_code * 100; v_code_max := v_search_code * 100 + 99;
        ELSE v_search_code := NULL; END IF;
    EXCEPTION WHEN OTHERS THEN v_search_code := NULL;
    END;
    
    IF v_search_code IS NOT NULL THEN
        RETURN QUERY SELECT cg.id, cg.code, cg.name::TEXT, cg.path::TEXT FROM cost_groups cg
        WHERE cg.code >= v_code_min AND cg.code <= v_code_max ORDER BY cg.code ASC LIMIT p_limit;
    ELSE
        RETURN QUERY SELECT cg.id, cg.code, cg.name::TEXT, cg.path::TEXT FROM cost_groups cg
        WHERE cg.name ILIKE '%' || p_search_text || '%'
        ORDER BY CASE WHEN cg.name ILIKE p_search_text || '%' THEN 0 ELSE 1 END, cg.code ASC
        LIMIT p_limit;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION search_locations_autocomplete(p_search_text TEXT, p_limit INTEGER DEFAULT 10)
RETURNS TABLE(id UUID, name TEXT, type location_type, path TEXT, depth INTEGER)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_search_pattern TEXT;
BEGIN
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        RETURN QUERY SELECT l.id, l.name::TEXT, l.type, l.search_text::TEXT AS path, l.depth
        FROM locations l
        ORDER BY l.type, l.name ASC LIMIT p_limit;
        RETURN;
    END IF;
    
    v_search_pattern := '%' || p_search_text || '%';
    
    RETURN QUERY SELECT l.id, l.name::TEXT, l.type, l.search_text::TEXT AS path, l.depth
    FROM locations l
    WHERE l.name ILIKE v_search_pattern OR l.search_text ILIKE v_search_pattern
    ORDER BY 
        CASE WHEN l.name ILIKE p_search_text THEN 0
             WHEN l.name ILIKE p_search_text || '%' THEN 1
             ELSE 2 END,
        l.type, l.name ASC
    LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION search_tags_autocomplete(p_search_text TEXT, p_limit INTEGER DEFAULT 10)
RETURNS TABLE(id TEXT, name TEXT, color TEXT, source TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_search_pattern TEXT;
BEGIN
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN
        RETURN QUERY WITH combined_tags AS (
            SELECT 'tw_' || t.id::TEXT AS id, t.name::TEXT AS name, t.color::TEXT AS color, 'teamwork'::TEXT AS source,
                (SELECT COUNT(*) FROM teamwork.task_tags tt WHERE tt.tag_id = t.id) AS usage_count
            FROM teamwork.tags t
            UNION ALL
            SELECT 'm_' || sl.id::TEXT AS id, sl.name::TEXT AS name, NULL::TEXT AS color, 'missive'::TEXT AS source,
                (SELECT COUNT(*) FROM missive.conversation_labels cl WHERE cl.label_id = sl.id) AS usage_count
            FROM missive.shared_labels sl
        ) SELECT DISTINCT ON (LOWER(ct.name)) ct.id, ct.name, ct.color, ct.source
        FROM combined_tags ct ORDER BY LOWER(ct.name), ct.usage_count DESC LIMIT p_limit;
        RETURN;
    END IF;
    
    v_search_pattern := '%' || p_search_text || '%';
    RETURN QUERY WITH combined_tags AS (
        SELECT 'tw_' || t.id::TEXT AS id, t.name::TEXT AS name, t.color::TEXT AS color, 'teamwork'::TEXT AS source
        FROM teamwork.tags t WHERE t.name ILIKE v_search_pattern
        UNION ALL
        SELECT 'm_' || sl.id::TEXT AS id, sl.name::TEXT AS name, NULL::TEXT AS color, 'missive'::TEXT AS source
        FROM missive.shared_labels sl WHERE sl.name ILIKE v_search_pattern
    ) SELECT DISTINCT ON (LOWER(ct.name)) ct.id, ct.name, ct.color, ct.source
    FROM combined_tags ct ORDER BY LOWER(ct.name), CASE WHEN ct.name ILIKE p_search_text || '%' THEN 0 ELSE 1 END
    LIMIT p_limit;
END;
$$;

-- =====================================
-- 11. UNIFIED QUERY FUNCTIONS
-- =====================================

CREATE OR REPLACE FUNCTION compute_cost_group_range(p_code TEXT)
RETURNS TABLE(min_code INTEGER, max_code INTEGER)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_num INTEGER;
BEGIN
    IF p_code IS NULL OR TRIM(p_code) = '' THEN RETURN; END IF;
    BEGIN v_num := TRIM(p_code)::INTEGER;
    EXCEPTION WHEN OTHERS THEN RETURN; END;
    
    IF v_num >= 100 AND v_num <= 999 THEN
        -- 3-digit code - hierarchical based on trailing zeros
        IF v_num % 100 = 0 THEN min_code := v_num; max_code := v_num + 99;      -- 400 -> 400-499
        ELSIF v_num % 10 = 0 THEN min_code := v_num; max_code := v_num + 9;     -- 430 -> 430-439
        ELSE min_code := v_num; max_code := v_num; END IF;                       -- 434 -> exact
    ELSIF v_num >= 10 AND v_num <= 99 THEN min_code := v_num * 10; max_code := v_num * 10 + 9;
    ELSIF v_num >= 1 AND v_num <= 9 THEN min_code := v_num * 100; max_code := v_num * 100 + 99;
    ELSE RETURN; END IF;
    RETURN NEXT;
END;
$$;

-- Find all descendant location IDs for hierarchical filtering
CREATE OR REPLACE FUNCTION find_location_ids_by_search(p_search_text TEXT)
RETURNS UUID[] LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_pattern TEXT;
    v_result UUID[];
    v_matched_ids UUID[];
BEGIN
    IF p_search_text IS NULL OR TRIM(p_search_text) = '' THEN RETURN ARRAY[]::UUID[]; END IF;
    v_pattern := '%' || p_search_text || '%';
    
    -- Find locations matching the search
    SELECT ARRAY_AGG(l.id) INTO v_matched_ids
    FROM locations l
    WHERE l.name ILIKE v_pattern OR l.search_text ILIKE v_pattern;
    
    IF v_matched_ids IS NULL OR array_length(v_matched_ids, 1) IS NULL THEN
        RETURN ARRAY[]::UUID[];
    END IF;
    
    -- Include matched locations and ALL their descendants (hierarchical search)
    SELECT ARRAY_AGG(DISTINCT l.id) INTO v_result
    FROM locations l
    WHERE l.id = ANY(v_matched_ids) 
       OR l.path_ids && v_matched_ids;  -- GIN index on path_ids
    
    RETURN COALESCE(v_result, ARRAY[]::UUID[]);
END;
$$;

CREATE OR REPLACE FUNCTION query_unified_items(
    p_types TEXT[] DEFAULT NULL, p_task_types UUID[] DEFAULT NULL,
    p_text_search TEXT DEFAULT NULL, p_involved_person TEXT DEFAULT NULL,
    p_tag_search TEXT DEFAULT NULL, p_cost_group_code TEXT DEFAULT NULL,
    p_project_search TEXT DEFAULT NULL, p_location_search TEXT DEFAULT NULL,
    p_name_contains TEXT DEFAULT NULL, p_description_contains TEXT DEFAULT NULL,
    p_customer_contains TEXT DEFAULT NULL, p_tasklist_contains TEXT DEFAULT NULL,
    p_creator_contains TEXT DEFAULT NULL, p_assigned_to_contains TEXT DEFAULT NULL,
    p_status_in TEXT[] DEFAULT NULL, p_status_not_in TEXT[] DEFAULT NULL,
    p_priority_in TEXT[] DEFAULT NULL, p_priority_not_in TEXT[] DEFAULT NULL,
    p_due_date_min TIMESTAMP DEFAULT NULL, p_due_date_max TIMESTAMP DEFAULT NULL,
    p_due_date_is_null BOOLEAN DEFAULT NULL,
    p_created_at_min TIMESTAMPTZ DEFAULT NULL, p_created_at_max TIMESTAMPTZ DEFAULT NULL,
    p_updated_at_min TIMESTAMPTZ DEFAULT NULL, p_updated_at_max TIMESTAMPTZ DEFAULT NULL,
    p_progress_min INTEGER DEFAULT NULL, p_progress_max INTEGER DEFAULT NULL,
    p_attachment_count_min INTEGER DEFAULT NULL, p_attachment_count_max INTEGER DEFAULT NULL,
    p_file_extension_contains TEXT DEFAULT NULL,
    p_accumulated_estimated_minutes_min INTEGER DEFAULT NULL, p_accumulated_estimated_minutes_max INTEGER DEFAULT NULL,
    p_logged_minutes_min INTEGER DEFAULT NULL, p_logged_minutes_max INTEGER DEFAULT NULL,
    p_billable_minutes_min INTEGER DEFAULT NULL, p_billable_minutes_max INTEGER DEFAULT NULL,
    p_hide_completed_tasks BOOLEAN DEFAULT NULL,
    p_file_ignore_patterns TEXT[] DEFAULT NULL,
    p_sort_field TEXT DEFAULT 'updated_at', p_sort_order TEXT DEFAULT 'desc',
    p_limit INTEGER DEFAULT 50, p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    id TEXT, type TEXT, name TEXT, description TEXT, status VARCHAR, project TEXT, customer TEXT,
    location TEXT, location_path TEXT, cost_group TEXT, cost_group_code TEXT,
    due_date TIMESTAMP, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, priority VARCHAR, progress INTEGER, tasklist TEXT,
    task_type_id UUID, task_type_name TEXT, task_type_slug TEXT, task_type_color VARCHAR(50),
    assigned_to JSONB, tags JSONB, body TEXT, preview TEXT, creator TEXT,
    conversation_subject TEXT, recipients JSONB, attachments JSONB, attachment_count INTEGER,
    conversation_comments_text TEXT, craft_url TEXT, teamwork_url TEXT, missive_url TEXT, storage_path TEXT, thumbnail_path TEXT,
    file_extension TEXT, accumulated_estimated_minutes INTEGER, logged_minutes INTEGER, billable_minutes INTEGER
)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
-- SECURITY INVOKER: RLS policies on mv_unified_items are enforced
DECLARE
    v_sql TEXT;
    v_where TEXT[] := ARRAY[]::TEXT[];
    v_order_expr TEXT;
    v_order_expr_outer TEXT;
    v_person_ids UUID[];
    v_cost_min INTEGER;
    v_cost_max INTEGER;
    v_location_ids UUID[];
BEGIN
    -- Validate and sanitize sort parameters
    IF p_sort_field NOT IN ('name', 'status', 'project', 'customer', 'due_date', 'created_at', 'updated_at', 'priority', 'progress', 'attachment_count', 'cost_group_code', 'creator', 'location', 'location_path', 'cost_group', 'tasklist', 'conversation_subject', 'file_extension', 'accumulated_estimated_minutes', 'logged_minutes', 'billable_minutes') THEN
        p_sort_field := 'updated_at';
    END IF;
    IF p_sort_order NOT IN ('asc', 'desc') THEN p_sort_order := 'desc'; END IF;
    
    -- Pre-compute lookup filters
    IF p_involved_person IS NOT NULL AND TRIM(p_involved_person) != '' THEN
        v_person_ids := find_person_ids_by_search(p_involved_person);
        IF array_length(v_person_ids, 1) IS NULL THEN RETURN; END IF;
    END IF;
    
    IF p_cost_group_code IS NOT NULL AND TRIM(p_cost_group_code) != '' THEN
        SELECT cgr.min_code, cgr.max_code INTO v_cost_min, v_cost_max FROM compute_cost_group_range(p_cost_group_code) cgr;
    END IF;
    
    IF p_location_search IS NOT NULL AND TRIM(p_location_search) != '' THEN
        v_location_ids := find_location_ids_by_search(p_location_search);
        IF array_length(v_location_ids, 1) IS NULL THEN RETURN; END IF;
    END IF;
    
    -- Build WHERE conditions dynamically (only add when filter is active)
    IF p_types IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.type = ANY(%L::TEXT[])', p_types));
    END IF;
    IF p_task_types IS NOT NULL THEN
        v_where := array_append(v_where, format('(ui.type != ''task'' OR ui.task_type_id = ANY(%L::UUID[]))', p_task_types));
    END IF;
    -- Text search uses consolidated search_text column (includes body, tags, assignees, recipients, attachments)
    IF p_text_search IS NOT NULL AND p_text_search != '' THEN
        v_where := array_append(v_where, format('ui.search_text ILIKE %L', '%' || p_text_search || '%'));
    END IF;
    IF v_person_ids IS NOT NULL THEN
        v_where := array_append(v_where, format('EXISTS (SELECT 1 FROM item_involved_persons iip WHERE iip.item_id = ui.id AND iip.item_type = ui.type AND iip.unified_person_id = ANY(%L::UUID[]))', v_person_ids));
    END IF;
    -- P0 optimization: Use pre-computed tag_names_text with trigram index instead of jsonb_array_elements
    IF p_tag_search IS NOT NULL AND p_tag_search != '' THEN
        v_where := array_append(v_where, format('ui.tag_names_text ILIKE %L', '%' || p_tag_search || '%'));
    END IF;
    IF v_cost_min IS NOT NULL THEN
        v_where := array_append(v_where, format('(ui.cost_group_code IS NOT NULL AND ui.cost_group_code ~ ''^\d+$'' AND ui.cost_group_code::INTEGER >= %s AND ui.cost_group_code::INTEGER <= %s)', v_cost_min, v_cost_max));
    END IF;
    IF p_project_search IS NOT NULL AND p_project_search != '' THEN
        v_where := array_append(v_where, format('ui.project ILIKE %L', '%' || p_project_search || '%'));
    END IF;
    -- P1 optimization: Use pre-computed location_ids array with GIN index instead of 3x EXISTS subqueries
    IF v_location_ids IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.location_ids && %L::UUID[]', v_location_ids));
    END IF;
    IF p_name_contains IS NOT NULL AND p_name_contains != '' THEN
        v_where := array_append(v_where, format('ui.name ILIKE %L', '%' || p_name_contains || '%'));
    END IF;
    IF p_description_contains IS NOT NULL AND p_description_contains != '' THEN
        v_where := array_append(v_where, format('ui.description ILIKE %L', '%' || p_description_contains || '%'));
    END IF;
    IF p_customer_contains IS NOT NULL AND p_customer_contains != '' THEN
        v_where := array_append(v_where, format('ui.customer ILIKE %L', '%' || p_customer_contains || '%'));
    END IF;
    IF p_tasklist_contains IS NOT NULL AND p_tasklist_contains != '' THEN
        v_where := array_append(v_where, format('ui.tasklist ILIKE %L', '%' || p_tasklist_contains || '%'));
    END IF;
    IF p_creator_contains IS NOT NULL AND p_creator_contains != '' THEN
        v_where := array_append(v_where, format('ui.creator ILIKE %L', '%' || p_creator_contains || '%'));
    END IF;
    -- Assignee search uses flattened text column with trigram index
    IF p_assigned_to_contains IS NOT NULL AND p_assigned_to_contains != '' THEN
        v_where := array_append(v_where, format('ui.assignee_search_text ILIKE %L', '%' || p_assigned_to_contains || '%'));
    END IF;
    IF p_status_in IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.status = ANY(%L::TEXT[])', p_status_in));
    END IF;
    IF p_status_not_in IS NOT NULL THEN
        v_where := array_append(v_where, format('(ui.status IS NULL OR NOT (ui.status = ANY(%L::TEXT[])))', p_status_not_in));
    END IF;
    IF p_hide_completed_tasks = TRUE THEN
        v_where := array_append(v_where, '(ui.type != ''task'' OR ui.status != ''completed'')');
    END IF;
    -- File ignore patterns: hide files matching any of the LIKE patterns (match against name which contains full path)
    IF p_file_ignore_patterns IS NOT NULL AND array_length(p_file_ignore_patterns, 1) > 0 THEN
        v_where := array_append(v_where, format('(ui.type != ''file'' OR NOT (ui.name LIKE ANY(%L::TEXT[])))', p_file_ignore_patterns));
    END IF;
    IF p_priority_in IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.priority = ANY(%L::TEXT[])', p_priority_in));
    END IF;
    IF p_priority_not_in IS NOT NULL THEN
        v_where := array_append(v_where, format('(ui.priority IS NULL OR NOT (ui.priority = ANY(%L::TEXT[])))', p_priority_not_in));
    END IF;
    IF p_due_date_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.due_date >= %L', p_due_date_min));
    END IF;
    IF p_due_date_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.due_date <= %L', p_due_date_max));
    END IF;
    IF p_due_date_is_null = TRUE THEN
        v_where := array_append(v_where, 'ui.due_date IS NULL');
    ELSIF p_due_date_is_null = FALSE THEN
        v_where := array_append(v_where, 'ui.due_date IS NOT NULL');
    END IF;
    IF p_created_at_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.created_at >= %L', p_created_at_min));
    END IF;
    IF p_created_at_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.created_at <= %L', p_created_at_max));
    END IF;
    IF p_updated_at_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.updated_at >= %L', p_updated_at_min));
    END IF;
    IF p_updated_at_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.updated_at <= %L', p_updated_at_max));
    END IF;
    IF p_progress_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.progress >= %s', p_progress_min));
    END IF;
    IF p_progress_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.progress <= %s', p_progress_max));
    END IF;
    IF p_attachment_count_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.attachment_count >= %s', p_attachment_count_min));
    END IF;
    IF p_attachment_count_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.attachment_count <= %s', p_attachment_count_max));
    END IF;
    IF p_file_extension_contains IS NOT NULL AND p_file_extension_contains != '' THEN
        v_where := array_append(v_where, format('ui.file_extension ILIKE %L', '%' || p_file_extension_contains || '%'));
    END IF;
    IF p_accumulated_estimated_minutes_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.accumulated_estimated_minutes >= %s', p_accumulated_estimated_minutes_min));
    END IF;
    IF p_accumulated_estimated_minutes_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.accumulated_estimated_minutes <= %s', p_accumulated_estimated_minutes_max));
    END IF;
    IF p_logged_minutes_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.logged_minutes >= %s', p_logged_minutes_min));
    END IF;
    IF p_logged_minutes_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.logged_minutes <= %s', p_logged_minutes_max));
    END IF;
    IF p_billable_minutes_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.billable_minutes >= %s', p_billable_minutes_min));
    END IF;
    IF p_billable_minutes_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.billable_minutes <= %s', p_billable_minutes_max));
    END IF;
    
    -- Build ORDER BY expressions (for inner skinny query and outer full query)
    -- Always add id as secondary sort for deterministic ordering when primary sort values are equal
    IF p_sort_field = 'cost_group_code' THEN
        v_order_expr := format('NULLIF(ui.cost_group_code, '''')::INTEGER %s NULLS LAST, ui.id', p_sort_order);
        v_order_expr_outer := format('NULLIF(full_ui.cost_group_code, '''')::INTEGER %s NULLS LAST, full_ui.id', p_sort_order);
    ELSE
        v_order_expr := format('ui.%I %s NULLS LAST, ui.id', p_sort_field, p_sort_order);
        v_order_expr_outer := format('full_ui.%I %s NULLS LAST, full_ui.id', p_sort_field, p_sort_order);
    END IF;
    
    -- Build dynamic SQL using DEFERRED JOIN pattern:
    -- 1. Inner CTE fetches only IDs (skinny) with sort/limit
    -- 2. Outer query joins to get full row data for only the needed rows
    v_sql := 'WITH skinny_ids AS MATERIALIZED (
        SELECT ui.id, ui.type
        FROM mv_unified_items ui';
    
    IF array_length(v_where, 1) > 0 THEN
        v_sql := v_sql || ' WHERE ' || array_to_string(v_where, ' AND ');
    END IF;
    
    v_sql := v_sql || ' ORDER BY ' || v_order_expr;
    v_sql := v_sql || format(' LIMIT %s OFFSET %s', p_limit, p_offset);
    v_sql := v_sql || ')
    SELECT full_ui.id, full_ui.type, full_ui.name, full_ui.description, full_ui.status, full_ui.project, full_ui.customer,
        full_ui.location, full_ui.location_path, full_ui.cost_group, full_ui.cost_group_code,
        full_ui.due_date, full_ui.created_at, full_ui.updated_at, full_ui.priority, full_ui.progress, full_ui.tasklist,
        full_ui.task_type_id, full_ui.task_type_name, full_ui.task_type_slug, full_ui.task_type_color,
        full_ui.assigned_to, full_ui.tags, LEFT(full_ui.body, 800) AS body, full_ui.preview, full_ui.creator,
        full_ui.conversation_subject, (SELECT jsonb_agg(elem) FROM (SELECT elem FROM jsonb_array_elements(full_ui.recipients) AS elem LIMIT 5) sub) AS recipients, full_ui.attachments, full_ui.attachment_count,
        full_ui.conversation_comments_text, full_ui.craft_url, full_ui.teamwork_url, full_ui.missive_url, full_ui.storage_path, full_ui.thumbnail_path,
        full_ui.file_extension, full_ui.accumulated_estimated_minutes, full_ui.logged_minutes, full_ui.billable_minutes
    FROM skinny_ids s
    JOIN mv_unified_items full_ui ON s.id = full_ui.id AND s.type = full_ui.type
    ORDER BY ' || v_order_expr_outer;
    
    RETURN QUERY EXECUTE v_sql;
END;
$$;

-- Simple count function - just returns COUNT(*)
CREATE OR REPLACE FUNCTION count_unified_items(
    p_types TEXT[] DEFAULT NULL, p_task_types UUID[] DEFAULT NULL,
    p_text_search TEXT DEFAULT NULL, p_involved_person TEXT DEFAULT NULL,
    p_tag_search TEXT DEFAULT NULL, p_cost_group_code TEXT DEFAULT NULL,
    p_project_search TEXT DEFAULT NULL, p_location_search TEXT DEFAULT NULL,
    p_name_contains TEXT DEFAULT NULL, p_description_contains TEXT DEFAULT NULL,
    p_customer_contains TEXT DEFAULT NULL, p_tasklist_contains TEXT DEFAULT NULL,
    p_creator_contains TEXT DEFAULT NULL, p_assigned_to_contains TEXT DEFAULT NULL,
    p_status_in TEXT[] DEFAULT NULL, p_status_not_in TEXT[] DEFAULT NULL,
    p_priority_in TEXT[] DEFAULT NULL, p_priority_not_in TEXT[] DEFAULT NULL,
    p_due_date_min TIMESTAMP DEFAULT NULL, p_due_date_max TIMESTAMP DEFAULT NULL,
    p_due_date_is_null BOOLEAN DEFAULT NULL,
    p_created_at_min TIMESTAMPTZ DEFAULT NULL, p_created_at_max TIMESTAMPTZ DEFAULT NULL,
    p_updated_at_min TIMESTAMPTZ DEFAULT NULL, p_updated_at_max TIMESTAMPTZ DEFAULT NULL,
    p_progress_min INTEGER DEFAULT NULL, p_progress_max INTEGER DEFAULT NULL,
    p_attachment_count_min INTEGER DEFAULT NULL, p_attachment_count_max INTEGER DEFAULT NULL,
    p_file_extension_contains TEXT DEFAULT NULL,
    p_accumulated_estimated_minutes_min INTEGER DEFAULT NULL, p_accumulated_estimated_minutes_max INTEGER DEFAULT NULL,
    p_logged_minutes_min INTEGER DEFAULT NULL, p_logged_minutes_max INTEGER DEFAULT NULL,
    p_billable_minutes_min INTEGER DEFAULT NULL, p_billable_minutes_max INTEGER DEFAULT NULL,
    p_hide_completed_tasks BOOLEAN DEFAULT NULL,
    p_file_ignore_patterns TEXT[] DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
-- SECURITY INVOKER: RLS policies on mv_unified_items are enforced
DECLARE
    v_sql TEXT;
    v_where TEXT[] := ARRAY[]::TEXT[];
    v_where_clause TEXT;
    v_person_ids UUID[];
    v_cost_min INTEGER;
    v_cost_max INTEGER;
    v_location_ids UUID[];
    v_count INTEGER;
BEGIN
    -- Pre-compute lookup filters
    IF p_involved_person IS NOT NULL AND TRIM(p_involved_person) != '' THEN
        v_person_ids := find_person_ids_by_search(p_involved_person);
        IF array_length(v_person_ids, 1) IS NULL THEN RETURN 0; END IF;
    END IF;
    
    IF p_cost_group_code IS NOT NULL AND TRIM(p_cost_group_code) != '' THEN
        SELECT cgr.min_code, cgr.max_code INTO v_cost_min, v_cost_max FROM compute_cost_group_range(p_cost_group_code) cgr;
    END IF;
    
    IF p_location_search IS NOT NULL AND TRIM(p_location_search) != '' THEN
        v_location_ids := find_location_ids_by_search(p_location_search);
        IF array_length(v_location_ids, 1) IS NULL THEN RETURN 0; END IF;
    END IF;
    
    -- Build WHERE conditions dynamically
    IF p_types IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.type = ANY(%L::TEXT[])', p_types));
    END IF;
    IF p_task_types IS NOT NULL THEN
        v_where := array_append(v_where, format('(ui.type != ''task'' OR ui.task_type_id = ANY(%L::UUID[]))', p_task_types));
    END IF;
    -- Text search uses consolidated search_text column (includes body, tags, assignees, recipients, attachments)
    IF p_text_search IS NOT NULL AND p_text_search != '' THEN
        v_where := array_append(v_where, format('ui.search_text ILIKE %L', '%' || p_text_search || '%'));
    END IF;
    IF v_person_ids IS NOT NULL THEN
        v_where := array_append(v_where, format('EXISTS (SELECT 1 FROM item_involved_persons iip WHERE iip.item_id = ui.id AND iip.item_type = ui.type AND iip.unified_person_id = ANY(%L::UUID[]))', v_person_ids));
    END IF;
    -- P0 optimization: Use pre-computed tag_names_text with trigram index instead of jsonb_array_elements
    IF p_tag_search IS NOT NULL AND p_tag_search != '' THEN
        v_where := array_append(v_where, format('ui.tag_names_text ILIKE %L', '%' || p_tag_search || '%'));
    END IF;
    IF v_cost_min IS NOT NULL THEN
        v_where := array_append(v_where, format('(ui.cost_group_code IS NOT NULL AND ui.cost_group_code ~ ''^\d+$'' AND ui.cost_group_code::INTEGER >= %s AND ui.cost_group_code::INTEGER <= %s)', v_cost_min, v_cost_max));
    END IF;
    IF p_project_search IS NOT NULL AND p_project_search != '' THEN
        v_where := array_append(v_where, format('ui.project ILIKE %L', '%' || p_project_search || '%'));
    END IF;
    -- P1 optimization: Use pre-computed location_ids array with GIN index instead of 3x EXISTS subqueries
    IF v_location_ids IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.location_ids && %L::UUID[]', v_location_ids));
    END IF;
    IF p_name_contains IS NOT NULL AND p_name_contains != '' THEN
        v_where := array_append(v_where, format('ui.name ILIKE %L', '%' || p_name_contains || '%'));
    END IF;
    IF p_description_contains IS NOT NULL AND p_description_contains != '' THEN
        v_where := array_append(v_where, format('ui.description ILIKE %L', '%' || p_description_contains || '%'));
    END IF;
    IF p_customer_contains IS NOT NULL AND p_customer_contains != '' THEN
        v_where := array_append(v_where, format('ui.customer ILIKE %L', '%' || p_customer_contains || '%'));
    END IF;
    IF p_tasklist_contains IS NOT NULL AND p_tasklist_contains != '' THEN
        v_where := array_append(v_where, format('ui.tasklist ILIKE %L', '%' || p_tasklist_contains || '%'));
    END IF;
    IF p_creator_contains IS NOT NULL AND p_creator_contains != '' THEN
        v_where := array_append(v_where, format('ui.creator ILIKE %L', '%' || p_creator_contains || '%'));
    END IF;
    -- Assignee search uses flattened text column with trigram index
    IF p_assigned_to_contains IS NOT NULL AND p_assigned_to_contains != '' THEN
        v_where := array_append(v_where, format('ui.assignee_search_text ILIKE %L', '%' || p_assigned_to_contains || '%'));
    END IF;
    IF p_status_in IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.status = ANY(%L::TEXT[])', p_status_in));
    END IF;
    IF p_status_not_in IS NOT NULL THEN
        v_where := array_append(v_where, format('(ui.status IS NULL OR NOT (ui.status = ANY(%L::TEXT[])))', p_status_not_in));
    END IF;
    IF p_hide_completed_tasks = TRUE THEN
        v_where := array_append(v_where, '(ui.type != ''task'' OR ui.status != ''completed'')');
    END IF;
    -- File ignore patterns: hide files matching any of the LIKE patterns (match against name which contains full path)
    IF p_file_ignore_patterns IS NOT NULL AND array_length(p_file_ignore_patterns, 1) > 0 THEN
        v_where := array_append(v_where, format('(ui.type != ''file'' OR NOT (ui.name LIKE ANY(%L::TEXT[])))', p_file_ignore_patterns));
    END IF;
    IF p_priority_in IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.priority = ANY(%L::TEXT[])', p_priority_in));
    END IF;
    IF p_priority_not_in IS NOT NULL THEN
        v_where := array_append(v_where, format('(ui.priority IS NULL OR NOT (ui.priority = ANY(%L::TEXT[])))', p_priority_not_in));
    END IF;
    IF p_due_date_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.due_date >= %L', p_due_date_min));
    END IF;
    IF p_due_date_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.due_date <= %L', p_due_date_max));
    END IF;
    IF p_due_date_is_null = TRUE THEN
        v_where := array_append(v_where, 'ui.due_date IS NULL');
    ELSIF p_due_date_is_null = FALSE THEN
        v_where := array_append(v_where, 'ui.due_date IS NOT NULL');
    END IF;
    IF p_created_at_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.created_at >= %L', p_created_at_min));
    END IF;
    IF p_created_at_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.created_at <= %L', p_created_at_max));
    END IF;
    IF p_updated_at_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.updated_at >= %L', p_updated_at_min));
    END IF;
    IF p_updated_at_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.updated_at <= %L', p_updated_at_max));
    END IF;
    IF p_progress_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.progress >= %s', p_progress_min));
    END IF;
    IF p_progress_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.progress <= %s', p_progress_max));
    END IF;
    IF p_attachment_count_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.attachment_count >= %s', p_attachment_count_min));
    END IF;
    IF p_attachment_count_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.attachment_count <= %s', p_attachment_count_max));
    END IF;
    IF p_file_extension_contains IS NOT NULL AND p_file_extension_contains != '' THEN
        v_where := array_append(v_where, format('ui.file_extension ILIKE %L', '%' || p_file_extension_contains || '%'));
    END IF;
    IF p_accumulated_estimated_minutes_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.accumulated_estimated_minutes >= %s', p_accumulated_estimated_minutes_min));
    END IF;
    IF p_accumulated_estimated_minutes_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.accumulated_estimated_minutes <= %s', p_accumulated_estimated_minutes_max));
    END IF;
    IF p_logged_minutes_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.logged_minutes >= %s', p_logged_minutes_min));
    END IF;
    IF p_logged_minutes_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.logged_minutes <= %s', p_logged_minutes_max));
    END IF;
    IF p_billable_minutes_min IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.billable_minutes >= %s', p_billable_minutes_min));
    END IF;
    IF p_billable_minutes_max IS NOT NULL THEN
        v_where := array_append(v_where, format('ui.billable_minutes <= %s', p_billable_minutes_max));
    END IF;
    
    -- Build WHERE clause
    IF array_length(v_where, 1) > 0 THEN
        v_where_clause := ' WHERE ' || array_to_string(v_where, ' AND ');
    ELSE
        v_where_clause := '';
    END IF;
    
    -- Simple COUNT(*)
    v_sql := 'SELECT COUNT(*)::INTEGER FROM mv_unified_items ui' || v_where_clause;
    EXECUTE v_sql INTO v_count;
    RETURN v_count;
END;
$$;

-- =====================================
-- 12. UNIFIED PERSONS QUERY
-- =====================================

CREATE OR REPLACE FUNCTION query_unified_persons(
    p_text_search TEXT DEFAULT NULL,
    p_project_search TEXT DEFAULT NULL,
    p_is_internal BOOLEAN DEFAULT NULL,
    p_is_company BOOLEAN DEFAULT NULL,
    p_sort_field TEXT DEFAULT 'display_name',
    p_sort_order TEXT DEFAULT 'asc',
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    id UUID, display_name TEXT, primary_email TEXT, preferred_contact_method VARCHAR, is_internal BOOLEAN, is_company BOOLEAN, notes TEXT,
    tw_company_id INTEGER, tw_company_name TEXT, tw_company_website TEXT,
    tw_user_id INTEGER, tw_user_first_name TEXT, tw_user_last_name TEXT, tw_user_email VARCHAR,
    m_contact_id INTEGER, m_contact_email VARCHAR, m_contact_name TEXT,
    db_created_at TIMESTAMP, db_updated_at TIMESTAMP
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_has_project_filter BOOLEAN;
    v_matching_person_ids UUID[];
BEGIN
    IF p_sort_field NOT IN ('display_name', 'primary_email', 'is_internal', 'is_company', 'db_created_at', 'db_updated_at', 'preferred_contact_method', 'tw_company_name', 'tw_company_website', 'tw_user_first_name', 'tw_user_last_name', 'tw_user_email', 'm_contact_name', 'm_contact_email') THEN
        p_sort_field := 'display_name';
    END IF;
    IF p_sort_order NOT IN ('asc', 'desc') THEN p_sort_order := 'asc'; END IF;
    
    v_has_project_filter := p_project_search IS NOT NULL AND TRIM(p_project_search) != '';
    
    IF v_has_project_filter THEN
        -- Find persons involved in items that belong to matching projects
        SELECT ARRAY_AGG(DISTINCT iip.unified_person_id) INTO v_matching_person_ids
        FROM item_involved_persons iip
        JOIN mv_unified_items ui ON ui.id = iip.item_id AND ui.type = iip.item_type
        WHERE ui.project ILIKE '%' || p_project_search || '%';
        
        IF v_matching_person_ids IS NULL OR array_length(v_matching_person_ids, 1) IS NULL THEN
            RETURN;
        END IF;
    END IF;
    
    RETURN QUERY
    SELECT upd.id, upd.display_name, upd.primary_email, upd.preferred_contact_method, upd.is_internal, upd.is_company, upd.notes,
        upd.tw_company_id, upd.tw_company_name, upd.tw_company_website,
        upd.tw_user_id, upd.tw_user_first_name, upd.tw_user_last_name, upd.tw_user_email,
        upd.m_contact_id, upd.m_contact_email, upd.m_contact_name,
        upd.db_created_at, upd.db_updated_at
    FROM unified_person_details upd
    WHERE (NOT v_has_project_filter OR upd.id = ANY(v_matching_person_ids))
        AND (p_text_search IS NULL OR p_text_search = '' OR
            upd.display_name ILIKE '%' || p_text_search || '%' OR
            upd.primary_email ILIKE '%' || p_text_search || '%' OR
            upd.tw_company_name ILIKE '%' || p_text_search || '%' OR
            upd.tw_user_email ILIKE '%' || p_text_search || '%' OR
            upd.m_contact_name ILIKE '%' || p_text_search || '%' OR
            upd.m_contact_email ILIKE '%' || p_text_search || '%')
        AND (p_is_internal IS NULL OR upd.is_internal = p_is_internal)
        AND (p_is_company IS NULL OR upd.is_company = p_is_company)
    ORDER BY
        CASE WHEN p_sort_field = 'display_name' AND p_sort_order = 'asc' THEN upd.display_name END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'display_name' AND p_sort_order = 'desc' THEN upd.display_name END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'primary_email' AND p_sort_order = 'asc' THEN upd.primary_email END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'primary_email' AND p_sort_order = 'desc' THEN upd.primary_email END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'is_internal' AND p_sort_order = 'asc' THEN upd.is_internal END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'is_internal' AND p_sort_order = 'desc' THEN upd.is_internal END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'is_company' AND p_sort_order = 'asc' THEN upd.is_company END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'is_company' AND p_sort_order = 'desc' THEN upd.is_company END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'db_created_at' AND p_sort_order = 'asc' THEN upd.db_created_at END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'db_created_at' AND p_sort_order = 'desc' THEN upd.db_created_at END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'db_updated_at' AND p_sort_order = 'asc' THEN upd.db_updated_at END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'db_updated_at' AND p_sort_order = 'desc' THEN upd.db_updated_at END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'preferred_contact_method' AND p_sort_order = 'asc' THEN upd.preferred_contact_method END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'preferred_contact_method' AND p_sort_order = 'desc' THEN upd.preferred_contact_method END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'tw_company_name' AND p_sort_order = 'asc' THEN upd.tw_company_name END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'tw_company_name' AND p_sort_order = 'desc' THEN upd.tw_company_name END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'tw_company_website' AND p_sort_order = 'asc' THEN upd.tw_company_website END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'tw_company_website' AND p_sort_order = 'desc' THEN upd.tw_company_website END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'tw_user_first_name' AND p_sort_order = 'asc' THEN upd.tw_user_first_name END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'tw_user_first_name' AND p_sort_order = 'desc' THEN upd.tw_user_first_name END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'tw_user_last_name' AND p_sort_order = 'asc' THEN upd.tw_user_last_name END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'tw_user_last_name' AND p_sort_order = 'desc' THEN upd.tw_user_last_name END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'tw_user_email' AND p_sort_order = 'asc' THEN upd.tw_user_email END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'tw_user_email' AND p_sort_order = 'desc' THEN upd.tw_user_email END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'm_contact_name' AND p_sort_order = 'asc' THEN upd.m_contact_name END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'm_contact_name' AND p_sort_order = 'desc' THEN upd.m_contact_name END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'm_contact_email' AND p_sort_order = 'asc' THEN upd.m_contact_email END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'm_contact_email' AND p_sort_order = 'desc' THEN upd.m_contact_email END DESC NULLS LAST
    LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION count_unified_persons(
    p_text_search TEXT DEFAULT NULL,
    p_project_search TEXT DEFAULT NULL,
    p_is_internal BOOLEAN DEFAULT NULL,
    p_is_company BOOLEAN DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_count INTEGER;
    v_has_project_filter BOOLEAN;
    v_matching_person_ids UUID[];
BEGIN
    v_has_project_filter := p_project_search IS NOT NULL AND TRIM(p_project_search) != '';
    
    IF v_has_project_filter THEN
        SELECT ARRAY_AGG(DISTINCT iip.unified_person_id) INTO v_matching_person_ids
        FROM item_involved_persons iip
        JOIN mv_unified_items ui ON ui.id = iip.item_id AND ui.type = iip.item_type
        WHERE ui.project ILIKE '%' || p_project_search || '%';
        
        IF v_matching_person_ids IS NULL OR array_length(v_matching_person_ids, 1) IS NULL THEN
            RETURN 0;
        END IF;
    END IF;
    
    SELECT COUNT(*)::INTEGER INTO v_count
    FROM unified_person_details upd
    WHERE (NOT v_has_project_filter OR upd.id = ANY(v_matching_person_ids))
        AND (p_text_search IS NULL OR p_text_search = '' OR
            upd.display_name ILIKE '%' || p_text_search || '%' OR
            upd.primary_email ILIKE '%' || p_text_search || '%' OR
            upd.tw_company_name ILIKE '%' || p_text_search || '%' OR
            upd.tw_user_email ILIKE '%' || p_text_search || '%' OR
            upd.m_contact_name ILIKE '%' || p_text_search || '%' OR
            upd.m_contact_email ILIKE '%' || p_text_search || '%')
        AND (p_is_internal IS NULL OR upd.is_internal = p_is_internal)
        AND (p_is_company IS NULL OR upd.is_company = p_is_company);
    
    RETURN v_count;
END;
$$;

-- =====================================
-- 13. SYNC STATUS FUNCTIONS
-- =====================================

CREATE OR REPLACE FUNCTION get_sync_status()
RETURNS TABLE (
    source VARCHAR(50), last_event_time TIMESTAMPTZ, checkpoint_updated_at TIMESTAMPTZ,
    pending_count BIGINT, processing_count BIGINT, failed_count BIGINT, 
    last_processed_at TIMESTAMPTZ, last_failed_at TIMESTAMPTZ, oldest_processing_started_at TIMESTAMPTZ
) AS $$
BEGIN
    -- Return connector sources (teamwork, missive, craft)
    RETURN QUERY SELECT COALESCE(c.source, q.source) AS source, c.last_event_time, c.updated_at AS checkpoint_updated_at,
        COALESCE(q.pending_count, 0) AS pending_count, COALESCE(q.processing_count, 0) AS processing_count,
        COALESCE(q.failed_count, 0) AS failed_count, q.last_processed_at, q.last_failed_at, q.oldest_processing_started_at
    FROM (
        SELECT qi.source,
            COUNT(*) FILTER (WHERE qi.status = 'pending') AS pending_count,
            COUNT(*) FILTER (WHERE qi.status = 'processing') AS processing_count,
            COUNT(*) FILTER (WHERE qi.status = 'failed') AS failed_count,
            MAX(qi.processed_at) FILTER (WHERE qi.status = 'completed') AS last_processed_at,
            MAX(qi.updated_at) FILTER (WHERE qi.status = 'failed') AS last_failed_at,
            MIN(qi.processing_started_at) FILTER (WHERE qi.status = 'processing') AS oldest_processing_started_at
        FROM teamworkmissiveconnector.queue_items qi GROUP BY qi.source
    ) q FULL OUTER JOIN teamworkmissiveconnector.checkpoints c ON c.source = q.source
    WHERE COALESCE(c.source, q.source) IN ('teamwork', 'missive', 'craft');
    
    -- Return files sync status (S3 Queue)
    -- Note: 'skipped' is treated as completed (intentional exclusion, not an error)
    RETURN QUERY SELECT 
        'files'::VARCHAR(50) AS source,
        NULL::TIMESTAMPTZ AS last_event_time,
        NULL::TIMESTAMPTZ AS checkpoint_updated_at,
        COUNT(*) FILTER (WHERE s3_status = 'pending') AS pending_count,
        COUNT(*) FILTER (WHERE s3_status = 'uploading') AS processing_count,
        COUNT(*) FILTER (WHERE s3_status = 'error') AS failed_count,
        MAX(last_status_change) FILTER (WHERE s3_status IN ('uploaded', 'skipped')) AS last_processed_at,
        MAX(last_status_change) FILTER (WHERE s3_status = 'error') AS last_failed_at,
        MIN(last_status_change) FILTER (WHERE s3_status = 'uploading') AS oldest_processing_started_at
    FROM file_contents;
    
    -- Return thumbnails/OCR queue status (TTE)
    RETURN QUERY SELECT 
        'thumbnails'::VARCHAR(50) AS source,
        NULL::TIMESTAMPTZ AS last_event_time,
        NULL::TIMESTAMPTZ AS checkpoint_updated_at,
        COUNT(*) FILTER (WHERE processing_status = 'pending' AND s3_status = 'uploaded') AS pending_count,
        COUNT(*) FILTER (WHERE processing_status = 'indexing') AS processing_count,
        COUNT(*) FILTER (WHERE processing_status = 'error') AS failed_count,
        MAX(last_status_change) FILTER (WHERE processing_status = 'done') AS last_processed_at,
        MAX(last_status_change) FILTER (WHERE processing_status = 'error') AS last_failed_at,
        MIN(last_status_change) FILTER (WHERE processing_status = 'indexing') AS oldest_processing_started_at
    FROM file_contents;
    
    -- Return attachments download queue status (only project-linked)
    RETURN QUERY SELECT 
        'attachments'::VARCHAR(50) AS source,
        NULL::TIMESTAMPTZ AS last_event_time,
        NULL::TIMESTAMPTZ AS checkpoint_updated_at,
        COUNT(*) FILTER (WHERE eaf.status = 'pending') AS pending_count,
        COUNT(*) FILTER (WHERE eaf.status = 'downloading') AS processing_count,
        COUNT(*) FILTER (WHERE eaf.status = 'failed') AS failed_count,
        MAX(eaf.downloaded_at) FILTER (WHERE eaf.status = 'completed') AS last_processed_at,
        MAX(eaf.updated_at) FILTER (WHERE eaf.status = 'failed') AS last_failed_at,
        MIN(eaf.updated_at) FILTER (WHERE eaf.status = 'downloading') AS oldest_processing_started_at
    FROM email_attachment_files eaf
    JOIN missive.messages msg ON eaf.missive_message_id = msg.id
    WHERE EXISTS (SELECT 1 FROM project_conversations pc WHERE pc.m_conversation_id = msg.conversation_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- =====================================
-- 14. CONNECTOR QUEUE FUNCTIONS
-- =====================================

CREATE OR REPLACE FUNCTION teamworkmissiveconnector.dequeue_items(
    p_worker_id VARCHAR(100), p_max_items INTEGER DEFAULT 10, p_source VARCHAR(50) DEFAULT NULL
)
RETURNS TABLE (id INTEGER, source VARCHAR(50), event_type VARCHAR(100), external_id VARCHAR(255), payload JSONB, retry_count INTEGER) AS $$
BEGIN
    RETURN QUERY UPDATE teamworkmissiveconnector.queue_items q
    SET status = 'processing', processing_started_at = NOW(), worker_id = p_worker_id, updated_at = NOW()
    WHERE q.id IN (
        SELECT qi.id FROM teamworkmissiveconnector.queue_items qi
        WHERE qi.status = 'pending' AND (p_source IS NULL OR qi.source = p_source)
            AND (qi.next_retry_at IS NULL OR qi.next_retry_at <= NOW())
        ORDER BY qi.created_at ASC LIMIT p_max_items FOR UPDATE SKIP LOCKED
    )
    RETURNING q.id, q.source, q.event_type, q.external_id, q.payload, q.retry_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION teamworkmissiveconnector.mark_completed(p_item_id INTEGER, p_processing_time_ms INTEGER DEFAULT NULL)
RETURNS VOID AS $$
BEGIN
    UPDATE teamworkmissiveconnector.queue_items
    SET status = 'completed', processed_at = NOW(), processing_time_ms = p_processing_time_ms, updated_at = NOW()
    WHERE id = p_item_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION teamworkmissiveconnector.mark_failed(p_item_id INTEGER, p_error_message TEXT, p_retry BOOLEAN DEFAULT TRUE)
RETURNS VOID AS $$
DECLARE v_retry_count INTEGER; v_max_retries INTEGER; v_next_retry_delay INTERVAL;
BEGIN
    SELECT retry_count, max_retries INTO v_retry_count, v_max_retries
    FROM teamworkmissiveconnector.queue_items WHERE id = p_item_id;
    
    v_next_retry_delay := CASE v_retry_count
        WHEN 0 THEN INTERVAL '1 minute' WHEN 1 THEN INTERVAL '5 minutes'
        WHEN 2 THEN INTERVAL '15 minutes' WHEN 3 THEN INTERVAL '30 minutes'
        ELSE INTERVAL '1 hour' END;
    
    IF p_retry AND v_retry_count < v_max_retries THEN
        UPDATE teamworkmissiveconnector.queue_items
        SET status = 'pending', retry_count = retry_count + 1, error_message = p_error_message,
            next_retry_at = NOW() + v_next_retry_delay, processing_started_at = NULL, worker_id = NULL, updated_at = NOW()
        WHERE id = p_item_id;
    ELSE
        UPDATE teamworkmissiveconnector.queue_items
        SET status = 'dead_letter', error_message = p_error_message, processed_at = NOW(), updated_at = NOW()
        WHERE id = p_item_id;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION teamworkmissiveconnector.cleanup_old_items(p_retention_days INTEGER DEFAULT 7)
RETURNS INTEGER AS $$
DECLARE v_deleted_count INTEGER;
BEGIN
    DELETE FROM teamworkmissiveconnector.queue_items
    WHERE status = 'completed' AND processed_at < NOW() - (p_retention_days || ' days')::INTERVAL;
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RETURN v_deleted_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION teamworkmissiveconnector.reset_stuck_items(p_stuck_threshold_minutes INTEGER DEFAULT 30)
RETURNS INTEGER AS $$
DECLARE v_reset_count INTEGER;
BEGIN
    UPDATE teamworkmissiveconnector.queue_items
    SET status = 'pending', processing_started_at = NULL, worker_id = NULL, updated_at = NOW()
    WHERE status = 'processing' AND processing_started_at < NOW() - (p_stuck_threshold_minutes || ' minutes')::INTERVAL;
    GET DIAGNOSTICS v_reset_count = ROW_COUNT;
    RETURN v_reset_count;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- 15. MATERIALIZED VIEW REFRESH FUNCTIONS
-- =====================================

CREATE OR REPLACE FUNCTION mark_mv_needs_refresh(p_view_name TEXT)
RETURNS void AS $$
BEGIN
    UPDATE mv_refresh_status SET needs_refresh = TRUE WHERE view_name = p_view_name;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_mark_mv_stale()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM mark_mv_needs_refresh(TG_ARGV[0]);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION refresh_unified_items_aggregates(p_concurrent BOOLEAN DEFAULT TRUE)
RETURNS void AS $$
BEGIN
    IF p_concurrent THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_task_assignees_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_task_tags_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_message_recipients_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_message_attachments_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_conversation_labels_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_conversation_comments_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_conversation_assignees_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_unified_items;
    ELSE
        REFRESH MATERIALIZED VIEW mv_task_assignees_agg;
        REFRESH MATERIALIZED VIEW mv_task_tags_agg;
        REFRESH MATERIALIZED VIEW mv_message_recipients_agg;
        REFRESH MATERIALIZED VIEW mv_message_attachments_agg;
        REFRESH MATERIALIZED VIEW mv_conversation_labels_agg;
        REFRESH MATERIALIZED VIEW mv_conversation_comments_agg;
        REFRESH MATERIALIZED VIEW mv_conversation_assignees_agg;
        REFRESH MATERIALIZED VIEW mv_unified_items;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION refresh_stale_unified_items_aggregates()
RETURNS TABLE(view_name TEXT, refreshed BOOLEAN) AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT mrs.view_name FROM mv_refresh_status mrs 
        WHERE mrs.needs_refresh = TRUE OR (NOW() - mrs.last_refreshed_at) > (mrs.refresh_interval_minutes || ' minutes')::INTERVAL
    LOOP
        view_name := r.view_name;
        BEGIN
            EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %I', r.view_name);
        EXCEPTION WHEN OTHERS THEN
            EXECUTE format('REFRESH MATERIALIZED VIEW %I', r.view_name);
        END;
        UPDATE mv_refresh_status SET needs_refresh = FALSE, last_refreshed_at = NOW() WHERE mv_refresh_status.view_name = r.view_name;
        refreshed := TRUE;
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- 16. PROCESSING QUEUE STATUS (CAS)
-- =====================================
-- Processing queue is now managed via file_contents.processing_status
-- No separate thumbnail_processing_queue table needed

CREATE OR REPLACE FUNCTION get_processing_queue_status()
RETURNS TABLE (
    pending_count BIGINT,
    processing_count BIGINT,
    done_count BIGINT,
    error_count BIGINT,
    last_processed_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY 
    SELECT 
        COUNT(*) FILTER (WHERE processing_status = 'pending' AND s3_status = 'uploaded'),
        COUNT(*) FILTER (WHERE processing_status = 'indexing'),
        COUNT(*) FILTER (WHERE processing_status = 'done'),
        COUNT(*) FILTER (WHERE processing_status = 'error'),
        MAX(last_status_change) FILTER (WHERE processing_status = 'done')
    FROM file_contents;
END;
$$ LANGUAGE plpgsql STABLE;

-- =====================================
-- 17. FILES CHECKPOINT UPSERT
-- =====================================



-- =====================================
-- 18. FILE METADATA EXTRACTION
-- =====================================

-- Link file to email attachment by matching local_filename against full_path's filename part
CREATE OR REPLACE FUNCTION link_file_to_email_attachment(p_file_id UUID)
RETURNS TEXT AS $$
DECLARE
    v_full_path TEXT;
    v_filename TEXT;
    v_attachment_id UUID;
BEGIN
    SELECT full_path INTO v_full_path FROM files WHERE id = p_file_id;
    IF NOT FOUND OR v_full_path IS NULL THEN RETURN 'skipped'; END IF;
    
    -- Extract filename from full_path (part after last /)
    v_filename := SUBSTRING(v_full_path FROM '[^/]+$');
    IF v_filename IS NULL OR v_filename = '' THEN RETURN 'skipped'; END IF;
    
    -- Look up by local_filename in email_attachment_files
    SELECT missive_attachment_id INTO v_attachment_id
    FROM email_attachment_files
    WHERE local_filename = v_filename AND status = 'completed';
    
    IF v_attachment_id IS NOT NULL THEN
        UPDATE files SET source_missive_attachment_id = v_attachment_id WHERE id = p_file_id;
        RETURN 'linked';
    END IF;
    
    RETURN 'skipped';
END;
$$ LANGUAGE plpgsql;

-- Link file to project if full_path contains project name
CREATE OR REPLACE FUNCTION link_file_to_project(p_file_id UUID)
RETURNS INTEGER SECURITY DEFINER SET search_path = public, teamwork, missive AS $$
DECLARE
    v_full_path TEXT;
    v_project_id INTEGER;
BEGIN
    SELECT full_path INTO v_full_path FROM files WHERE id = p_file_id;
    IF NOT FOUND OR v_full_path IS NULL THEN RETURN NULL; END IF;
    
    -- Check if path contains any project name (case-insensitive)
    -- Match the longest project name (most specific)
    SELECT id INTO v_project_id
    FROM teamwork.projects 
    WHERE v_full_path ILIKE '%' || name || '%'
    ORDER BY LENGTH(name) DESC
    LIMIT 1;
    
    IF v_project_id IS NOT NULL THEN
        UPDATE files SET project_id = v_project_id WHERE id = p_file_id;
    END IF;
    
    RETURN v_project_id;
END;
$$ LANGUAGE plpgsql;

-- Extract cost groups from file path (searches anywhere in full_path)
CREATE OR REPLACE FUNCTION extract_cost_groups_for_file(p_file_id UUID)
RETURNS void SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_prefixes TEXT[];
    v_full_path TEXT;
    v_prefix TEXT;
    v_match TEXT[];
    v_cost_group_id UUID;
    v_code INTEGER;
BEGIN
    SELECT COALESCE(
        (SELECT ARRAY(SELECT jsonb_array_elements_text(body->'cost_group_prefixes')) 
         FROM app_settings WHERE lock = 'X'),
        ARRAY['KGR']
    ) INTO v_prefixes;
    
    SELECT full_path INTO v_full_path FROM files WHERE id = p_file_id;
    IF NOT FOUND OR v_full_path IS NULL OR v_full_path = '' THEN RETURN; END IF;
    
    DELETE FROM object_cost_groups WHERE file_id = p_file_id AND source = 'auto_path';
    
    -- Search for cost group patterns anywhere in the path
    FOREACH v_prefix IN ARRAY v_prefixes LOOP
        FOR v_match IN SELECT regexp_matches(v_full_path, v_prefix || '\s*(\d{3})', 'gi') LOOP
            v_code := v_match[1]::INTEGER;
            v_cost_group_id := get_or_create_cost_group(v_code, NULL);
            INSERT INTO object_cost_groups (cost_group_id, file_id, source, source_tag_name)
            VALUES (v_cost_group_id, p_file_id, 'auto_path', v_prefix || ' ' || v_code::TEXT)
            ON CONFLICT DO NOTHING;
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Link file to document type if full_path contains document type name
CREATE OR REPLACE FUNCTION link_file_to_document_type(p_file_id UUID)
RETURNS TEXT AS $$
DECLARE
    v_full_path TEXT;
    v_matched_type_id INTEGER;
BEGIN
    SELECT full_path INTO v_full_path FROM files WHERE id = p_file_id;
    IF NOT FOUND OR v_full_path IS NULL OR v_full_path = '' THEN RETURN 'skipped'; END IF;
    
    -- Find document type by name match in path (case-insensitive)
    -- Prefer longer matches (more specific document types)
    SELECT id INTO v_matched_type_id
    FROM document_types
    WHERE v_full_path ILIKE '%' || name || '%'
    ORDER BY LENGTH(name) DESC
    LIMIT 1;
    
    IF v_matched_type_id IS NOT NULL THEN
        UPDATE files SET document_type_id = v_matched_type_id WHERE id = p_file_id;
        RETURN 'linked';
    END IF;
    
    RETURN 'skipped';
END;
$$ LANGUAGE plpgsql;

-- Master function: extract all file metadata
CREATE OR REPLACE FUNCTION extract_file_metadata(p_file_id UUID)
RETURNS void SECURITY DEFINER SET search_path = public, teamwork, missive AS $$
BEGIN
    PERFORM link_file_to_email_attachment(p_file_id);
    PERFORM link_file_to_project(p_file_id);
    PERFORM extract_cost_groups_for_file(p_file_id);
    PERFORM link_file_to_document_type(p_file_id);
END;
$$ LANGUAGE plpgsql;

-- Upload queue management with Multi-Source support
-- Retries: pending (unlimited), error (up to 5 tries), uploading stuck >30min (auto-reset)
CREATE OR REPLACE FUNCTION dequeue_upload_batch(p_batch_size INTEGER DEFAULT 10, p_path_prefixes TEXT[] DEFAULT '{}')
RETURNS TABLE (content_hash TEXT, size_bytes BIGINT, full_path TEXT) AS $$
BEGIN
    RETURN QUERY 
    WITH candidate_hashes AS (
        SELECT DISTINCT fc.content_hash AS hash
        FROM file_contents fc
        WHERE (
            -- Pending items: retry if under limit or enough time passed
            (fc.s3_status = 'pending' AND (fc.try_count < 3 OR (NOW() - fc.last_status_change) > INTERVAL '1 hour'))
            -- Error items: retry up to 5 times total
            OR (fc.s3_status = 'error' AND fc.try_count < 5)
            -- Stuck uploading items: reset after 30 minutes (worker probably died)
            OR (fc.s3_status = 'uploading' AND (NOW() - fc.last_status_change) > INTERVAL '30 minutes')
          )
          AND (
            p_path_prefixes = '{}' OR 
            EXISTS (
                SELECT 1 FROM files f 
                WHERE f.content_hash = fc.content_hash 
                AND EXISTS (SELECT 1 FROM unnest(p_path_prefixes) p WHERE f.full_path LIKE p || '%')
            )
          )
        LIMIT p_batch_size
    ),
    locked_batch AS (
        SELECT fc.content_hash, fc.size_bytes
        FROM file_contents fc
        WHERE fc.content_hash IN (SELECT hash FROM candidate_hashes)
          AND fc.s3_status IN ('pending', 'error', 'uploading')
        FOR UPDATE SKIP LOCKED
    ),
    updated AS (
        UPDATE file_contents
        SET s3_status = 'uploading',
            last_status_change = NOW(),
            try_count = try_count + 1
        FROM locked_batch lb
        WHERE file_contents.content_hash = lb.content_hash
        RETURNING file_contents.content_hash, file_contents.size_bytes
    )
    SELECT u.content_hash, u.size_bytes, 
           (SELECT f.full_path FROM files f WHERE f.content_hash = u.content_hash LIMIT 1)
    FROM updated u;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_upload_complete(p_hash TEXT, p_storage_path TEXT, p_mime_type TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE file_contents
    SET s3_status = 'uploaded',
        storage_path = p_storage_path,
        mime_type = p_mime_type,
        last_status_change = NOW(),
        db_updated_at = NOW()
    WHERE content_hash = p_hash;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_upload_failed(p_hash TEXT, p_error TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE file_contents
    SET s3_status = 'error',
        status_message = p_error,
        last_status_change = NOW()
    WHERE content_hash = p_hash;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_upload_skipped(p_hash TEXT, p_reason TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE file_contents
    SET s3_status = 'skipped',
        status_message = p_reason,
        last_status_change = NOW()
    WHERE content_hash = p_hash;
END;
$$ LANGUAGE plpgsql;

-- Reset stuck uploads on service startup (called by FileMetadataSync)
CREATE OR REPLACE FUNCTION reset_stuck_uploads()
RETURNS INTEGER AS $$
DECLARE
    affected INTEGER;
BEGIN
    UPDATE file_contents
    SET s3_status = 'pending',
        last_status_change = NOW()
    WHERE s3_status = 'uploading';
    
    GET DIAGNOSTICS affected = ROW_COUNT;
    RETURN affected;
END;
$$ LANGUAGE plpgsql;

-- Processing queue for ThumbnailTextExtractor (atomic claim with FOR UPDATE SKIP LOCKED)
CREATE OR REPLACE FUNCTION claim_pending_file_content(p_limit INTEGER DEFAULT 5)
RETURNS TABLE (content_hash TEXT, storage_path TEXT, size_bytes BIGINT, try_count INTEGER, full_path TEXT) AS $$
BEGIN
    RETURN QUERY
    WITH locked_batch AS (
        SELECT fc.content_hash, fc.storage_path, fc.size_bytes, fc.try_count
        FROM file_contents fc
        WHERE fc.s3_status = 'uploaded'
          AND fc.processing_status = 'pending'
        ORDER BY fc.db_created_at ASC
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED
    ),
    updated AS (
        UPDATE file_contents fc
        SET processing_status = 'indexing',
            last_status_change = NOW(),
            db_updated_at = NOW()
        FROM locked_batch lb
        WHERE fc.content_hash = lb.content_hash
        RETURNING fc.content_hash, fc.storage_path, fc.size_bytes, fc.try_count
    )
    SELECT u.content_hash, u.storage_path, u.size_bytes, u.try_count,
           (SELECT f.full_path FROM files f WHERE f.content_hash = u.content_hash LIMIT 1)
    FROM updated u;
END;
$$ LANGUAGE plpgsql;

-- Trigger for auto-extraction on file insert/update
CREATE OR REPLACE FUNCTION trigger_extract_file_metadata()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public, teamwork, missive AS $$
BEGIN
    PERFORM extract_file_metadata(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Bulk rerun function for all files
CREATE OR REPLACE FUNCTION rerun_all_file_linking()
RETURNS UUID SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_run_id UUID;
    v_total_count INTEGER;
    v_processed INTEGER := 0;
    v_linked INTEGER := 0;
    v_created INTEGER := 0;
    v_record RECORD;
    v_result TEXT;
    v_project_links INTEGER;
    v_initial_cg_count INTEGER;
    v_initial_project_count INTEGER;
    v_final_cg_count INTEGER;
    v_final_project_count INTEGER;
BEGIN
    INSERT INTO operation_runs (run_type, status, started_at)
    VALUES ('file_linking', 'running', NOW())
    RETURNING id INTO v_run_id;

    SELECT COUNT(*) INTO v_total_count FROM files;
    UPDATE operation_runs SET total_count = v_total_count WHERE id = v_run_id;
    
    SELECT COUNT(*) INTO v_initial_cg_count FROM object_cost_groups WHERE file_id IS NOT NULL;
    SELECT COUNT(*) INTO v_initial_project_count FROM files WHERE project_id IS NOT NULL;

    FOR v_record IN SELECT id FROM files ORDER BY db_created_at LOOP
        BEGIN
            -- Link to email attachment
            v_result := link_file_to_email_attachment(v_record.id);
            IF v_result = 'linked' THEN v_linked := v_linked + 1; END IF;
            
            -- Link to projects
            v_project_links := link_file_to_project(v_record.id);
            
            -- Extract cost groups
            PERFORM extract_cost_groups_for_file(v_record.id);
            
            -- Link to document type
            v_result := link_file_to_document_type(v_record.id);
            
            v_processed := v_processed + 1;
            IF v_processed % 100 = 0 THEN
                UPDATE operation_runs SET processed_count = v_processed WHERE id = v_run_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_processed := v_processed + 1;
        END;
    END LOOP;

    SELECT COUNT(*) INTO v_final_cg_count FROM object_cost_groups WHERE file_id IS NOT NULL;
    SELECT COUNT(*) INTO v_final_project_count FROM files WHERE project_id IS NOT NULL;
    v_created := (v_final_cg_count - v_initial_cg_count) + (v_final_project_count - v_initial_project_count);

    UPDATE operation_runs SET status = 'completed', processed_count = v_processed,
        linked_count = v_linked, created_count = v_created, completed_at = NOW()
    WHERE id = v_run_id;
    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

-- Garbage Collection
CREATE OR REPLACE FUNCTION trigger_cleanup_unreferenced_content()
RETURNS TRIGGER AS $$
BEGIN
    -- If content_hash is still used elsewhere, do nothing
    IF EXISTS (SELECT 1 FROM files WHERE content_hash = OLD.content_hash AND id != OLD.id) THEN
        RETURN OLD;
    END IF;

    -- Delete content (S3 deletion trigger will take it from here)
    DELETE FROM file_contents WHERE content_hash = OLD.content_hash;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- Storage Deletion Placeholder
CREATE OR REPLACE FUNCTION trigger_delete_s3_content()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public AS $$
BEGIN
    -- Placeholder for S3 deletion via pg_net or webhook
    -- Example for Supabase Storage:
    -- PERFORM net.http_post(
    --   url := 'http://kong:8000/storage/v1/object/' || OLD.storage_path,
    --   headers := '{"Authorization": "Bearer SERVICE_ROLE_KEY"}'::jsonb
    -- );
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- Status functions for file linking
CREATE OR REPLACE FUNCTION get_file_linking_run_status(p_run_id UUID)
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
AS $$
BEGIN RETURN QUERY SELECT * FROM get_operation_run_status(p_run_id); END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_latest_file_linking_run()
RETURNS TABLE (id UUID, status VARCHAR(50), total_count INTEGER, processed_count INTEGER,
    created_count INTEGER, linked_count INTEGER, skipped_count INTEGER,
    progress_percent NUMERIC, started_at TIMESTAMP, completed_at TIMESTAMP, error_message TEXT)
AS $$
BEGIN RETURN QUERY SELECT * FROM get_latest_operation_run('file_linking'); END;
$$ LANGUAGE plpgsql STABLE;

-- =====================================
-- CRAFT DOCUMENT AUTO-LINKING
-- =====================================

-- Link craft document to project if folder_path contains project name
CREATE OR REPLACE FUNCTION link_craft_document_to_project(p_craft_document_id TEXT)
RETURNS INTEGER SECURITY DEFINER SET search_path = public, teamwork AS $$
DECLARE
    v_folder_path TEXT;
    v_project RECORD;
    v_links_created INTEGER := 0;
BEGIN
    SELECT folder_path INTO v_folder_path FROM craft_documents WHERE id = p_craft_document_id;
    IF NOT FOUND OR v_folder_path IS NULL OR v_folder_path = '' THEN RETURN 0; END IF;
    
    FOR v_project IN 
        SELECT id, name FROM teamwork.projects 
        WHERE v_folder_path ILIKE '%' || name || '%'
    LOOP
        INSERT INTO project_craft_documents (craft_document_id, tw_project_id, assigned_at)
        VALUES (p_craft_document_id, v_project.id, NOW())
        ON CONFLICT (tw_project_id, craft_document_id) DO NOTHING;
        
        IF FOUND THEN
            v_links_created := v_links_created + 1;
        END IF;
    END LOOP;
    
    RETURN v_links_created;
END;
$$ LANGUAGE plpgsql;

-- Master function: extract all craft document metadata
CREATE OR REPLACE FUNCTION extract_craft_metadata(p_craft_document_id TEXT)
RETURNS void SECURITY DEFINER SET search_path = public, teamwork AS $$
BEGIN
    PERFORM link_craft_document_to_project(p_craft_document_id);
END;
$$ LANGUAGE plpgsql;

-- Trigger for auto-extraction on craft document insert/update
CREATE OR REPLACE FUNCTION trigger_extract_craft_metadata()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public, teamwork AS $$
BEGIN
    PERFORM extract_craft_metadata(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Bulk rerun function for all craft documents
CREATE OR REPLACE FUNCTION rerun_all_craft_linking()
RETURNS TABLE (total INTEGER, linked INTEGER) SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_total INTEGER := 0;
    v_linked INTEGER := 0;
    v_record RECORD;
    v_result INTEGER;
BEGIN
    FOR v_record IN SELECT id FROM craft_documents WHERE is_deleted = FALSE LOOP
        v_result := link_craft_document_to_project(v_record.id);
        v_total := v_total + 1;
        IF v_result > 0 THEN
            v_linked := v_linked + 1;
        END IF;
    END LOOP;
    
    RETURN QUERY SELECT v_total, v_linked;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- ATTACHMENT DOWNLOAD QUEUE
-- =====================================

-- Get pending attachments only for emails linked to a project
CREATE OR REPLACE FUNCTION get_pending_project_attachments(
    p_limit INTEGER DEFAULT 10,
    p_max_retries INTEGER DEFAULT 3
)
RETURNS TABLE(
    missive_attachment_id UUID,
    missive_message_id UUID,
    original_filename TEXT,
    original_url TEXT,
    file_size INTEGER,
    width INTEGER,
    height INTEGER,
    media_type VARCHAR(100),
    sub_type VARCHAR(100),
    retry_count INTEGER,
    project_name TEXT,
    delivered_at TIMESTAMP,
    sender_email VARCHAR(500),
    email_subject TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, missive, teamwork AS $$
    SELECT DISTINCT ON (eaf.missive_attachment_id)
        eaf.missive_attachment_id,
        eaf.missive_message_id,
        eaf.original_filename,
        eaf.original_url,
        eaf.file_size,
        eaf.width,
        eaf.height,
        eaf.media_type,
        eaf.sub_type,
        eaf.retry_count,
        p.name AS project_name,
        msg.delivered_at,
        c.email AS sender_email,
        COALESCE(msg.subject, conv.subject, conv.latest_message_subject) AS email_subject
    FROM email_attachment_files eaf
    JOIN missive.messages msg ON eaf.missive_message_id = msg.id
    JOIN missive.conversations conv ON msg.conversation_id = conv.id
    JOIN project_conversations pc ON msg.conversation_id = pc.m_conversation_id
    JOIN teamwork.projects p ON pc.tw_project_id = p.id
    LEFT JOIN missive.contacts c ON msg.from_contact_id = c.id
    WHERE eaf.status = 'pending'
      AND eaf.retry_count < p_max_retries
    ORDER BY eaf.missive_attachment_id, eaf.created_at ASC
    LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION trigger_queue_attachment_download()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.url IS NOT NULL THEN
        INSERT INTO email_attachment_files (
            missive_attachment_id, missive_message_id,
            original_filename, original_url, file_size,
            width, height, media_type, sub_type
        ) VALUES (
            NEW.id, NEW.message_id,
            COALESCE(NEW.filename, 'attachment'), NEW.url, NEW.size,
            NEW.width, NEW.height, NEW.media_type, NEW.sub_type
        )
        ON CONFLICT (missive_attachment_id) DO UPDATE SET
            original_url = EXCLUDED.original_url,
            updated_at = NOW();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- FILE-EMAIL RELATIONSHIP QUERIES
-- =====================================

-- Get the source email for a file (if it came from an email attachment)
CREATE OR REPLACE FUNCTION get_file_source_email(p_file_id UUID)
RETURNS TABLE(
    message_id UUID,
    subject TEXT,
    from_name TEXT,
    from_email VARCHAR(500),
    delivered_at TIMESTAMP,
    missive_url TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, missive AS $$
    SELECT 
        m.id AS message_id,
        COALESCE(m.subject, c.subject, c.latest_message_subject) AS subject,
        fc.name AS from_name,
        fc.email AS from_email,
        m.delivered_at,
        c.app_url AS missive_url
    FROM files f
    JOIN missive.attachments ma ON f.source_missive_attachment_id = ma.id
    JOIN missive.messages m ON ma.message_id = m.id
    JOIN missive.conversations c ON m.conversation_id = c.id
    LEFT JOIN missive.contacts fc ON m.from_contact_id = fc.id
    WHERE f.id = p_file_id;
$$;

-- Get all files that belong to an email/message (via attachments)
CREATE OR REPLACE FUNCTION get_email_files(p_message_id UUID)
RETURNS TABLE(
    file_id UUID,
    full_path TEXT,
    storage_path TEXT,
    thumbnail_path TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, missive AS $$
    SELECT 
        f.id AS file_id,
        f.full_path,
        fc.storage_path,
        fc.thumbnail_path
    FROM missive.attachments ma
    JOIN files f ON f.source_missive_attachment_id = ma.id
    JOIN file_contents fc ON f.content_hash = fc.content_hash
    WHERE ma.message_id = p_message_id
    AND f.deleted_at IS NULL;
$$;

-- =====================================
-- GRANTS
-- =====================================

GRANT EXECUTE ON FUNCTION get_file_source_email(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_email_files(UUID) TO authenticated;
GRANT SELECT ON mv_refresh_status TO authenticated;
GRANT EXECUTE ON FUNCTION mark_mv_needs_refresh(TEXT) TO authenticated;
-- =====================================
-- EMAIL HTML BODY (for iframe preview)
-- =====================================

CREATE OR REPLACE FUNCTION get_email_html_body(p_message_id UUID)
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = missive AS $$
    SELECT body FROM messages WHERE id = p_message_id;
$$;

CREATE OR REPLACE FUNCTION get_email_html_bodies(p_message_ids UUID[])
RETURNS TABLE(message_id UUID, html_body TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = missive AS $$
    SELECT id, body FROM messages WHERE id = ANY(p_message_ids);
$$;

GRANT EXECUTE ON FUNCTION get_email_html_body(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_email_html_bodies(UUID[]) TO authenticated;

-- =====================================
-- CRAFT MARKDOWN BODY (for preview)
-- =====================================

CREATE OR REPLACE FUNCTION get_craft_markdown(p_document_id TEXT)
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT markdown_content FROM craft_documents WHERE id = p_document_id;
$$;

CREATE OR REPLACE FUNCTION get_craft_markdowns(p_document_ids TEXT[])
RETURNS TABLE(document_id TEXT, markdown TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT id, markdown_content FROM craft_documents WHERE id = ANY(p_document_ids);
$$;

GRANT EXECUTE ON FUNCTION get_craft_markdown(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_craft_markdowns(TEXT[]) TO authenticated;

GRANT EXECUTE ON FUNCTION refresh_unified_items_aggregates(BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION refresh_stale_unified_items_aggregates() TO authenticated;
GRANT EXECUTE ON FUNCTION compute_cost_group_range(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_sync_status() TO authenticated;
GRANT EXECUTE ON FUNCTION query_unified_persons(TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION count_unified_persons(TEXT, TEXT, BOOLEAN, BOOLEAN) TO authenticated;

GRANT EXECUTE ON FUNCTION rerun_all_file_linking() TO authenticated;
GRANT EXECUTE ON FUNCTION get_file_linking_run_status(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_latest_file_linking_run() TO authenticated;
GRANT EXECUTE ON FUNCTION rerun_all_craft_linking() TO authenticated;

-- =====================================
-- PURGE EXCLUDED TEAMWORK DATA
-- =====================================

CREATE OR REPLACE FUNCTION purge_excluded_teamwork_data()
RETURNS TABLE(
    projects_deleted INTEGER,
    tasks_deleted INTEGER,
    timelogs_deleted INTEGER,
    tags_deleted INTEGER,
    conversations_unlinked INTEGER,
    craft_docs_unlinked INTEGER,
    files_unlinked INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, teamwork
AS $$
DECLARE
    v_excluded_company_ids INTEGER[];
    v_excluded_project_ids INTEGER[];
    v_all_excluded_project_ids INTEGER[];
    v_task_ids_to_delete INTEGER[];
    v_projects_deleted INTEGER := 0;
    v_tasks_deleted INTEGER := 0;
    v_timelogs_deleted INTEGER := 0;
    v_tags_deleted INTEGER := 0;
    v_conversations_unlinked INTEGER := 0;
    v_craft_docs_unlinked INTEGER := 0;
    v_files_unlinked INTEGER := 0;
BEGIN
    -- Get exclusion lists from app_settings (JSONB arrays -> PostgreSQL arrays)
    SELECT 
        COALESCE(ARRAY(SELECT jsonb_array_elements_text(body->'excluded_tw_company_ids')::INTEGER), ARRAY[]::INTEGER[]),
        COALESCE(ARRAY(SELECT jsonb_array_elements_text(body->'excluded_tw_project_ids')::INTEGER), ARRAY[]::INTEGER[])
    INTO v_excluded_company_ids, v_excluded_project_ids
    FROM app_settings
    WHERE lock = 'X';
    
    -- Combine: excluded projects + projects belonging to excluded companies
    SELECT ARRAY_AGG(DISTINCT id)
    INTO v_all_excluded_project_ids
    FROM teamwork.projects
    WHERE id = ANY(v_excluded_project_ids)
       OR company_id = ANY(v_excluded_company_ids);
    
    IF v_all_excluded_project_ids IS NULL OR array_length(v_all_excluded_project_ids, 1) IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 0;
        RETURN;
    END IF;
    
    -- Collect task IDs before deletion (for item_involved_persons cleanup)
    SELECT ARRAY_AGG(id)
    INTO v_task_ids_to_delete
    FROM teamwork.tasks
    WHERE project_id = ANY(v_all_excluded_project_ids);
    
    -- 1. Delete item_involved_persons for tasks (no FK, text-based item_id)
    IF v_task_ids_to_delete IS NOT NULL THEN
        DELETE FROM item_involved_persons
        WHERE item_type = 'task' 
          AND item_id = ANY(SELECT t::TEXT FROM UNNEST(v_task_ids_to_delete) t);
    END IF;
    
    -- 2. Delete timelogs (FK SET NULL won't delete them)
    DELETE FROM teamwork.timelogs
    WHERE project_id = ANY(v_all_excluded_project_ids);
    GET DIAGNOSTICS v_timelogs_deleted = ROW_COUNT;
    
    -- 3. Delete tasks (cascades: task_tags, task_assignees, object_locations, object_cost_groups, task_extensions)
    DELETE FROM teamwork.tasks
    WHERE project_id = ANY(v_all_excluded_project_ids);
    GET DIAGNOSTICS v_tasks_deleted = ROW_COUNT;
    
    -- 4. Delete tags associated with excluded projects
    DELETE FROM teamwork.tags
    WHERE project_id = ANY(v_all_excluded_project_ids);
    GET DIAGNOSTICS v_tags_deleted = ROW_COUNT;
    
    -- 5. Unlink conversations from excluded projects (don't delete the conversations themselves)
    DELETE FROM project_conversations
    WHERE tw_project_id = ANY(v_all_excluded_project_ids);
    GET DIAGNOSTICS v_conversations_unlinked = ROW_COUNT;
    
    -- 6. Unlink craft documents from excluded projects
    DELETE FROM project_craft_documents
    WHERE tw_project_id = ANY(v_all_excluded_project_ids);
    GET DIAGNOSTICS v_craft_docs_unlinked = ROW_COUNT;
    
    -- 7. Unlink files from excluded projects (set project_id to NULL)
    UPDATE files SET project_id = NULL
    WHERE project_id = ANY(v_all_excluded_project_ids);
    GET DIAGNOSTICS v_files_unlinked = ROW_COUNT;
    
    -- 8. Delete projects (cascades: tasklists, project_extensions, project_contractors)
    DELETE FROM teamwork.projects
    WHERE id = ANY(v_all_excluded_project_ids);
    GET DIAGNOSTICS v_projects_deleted = ROW_COUNT;
    
    RETURN QUERY SELECT 
        v_projects_deleted,
        v_tasks_deleted,
        v_timelogs_deleted,
        v_tags_deleted,
        v_conversations_unlinked,
        v_craft_docs_unlinked,
        v_files_unlinked;
END;
$$;

COMMENT ON FUNCTION purge_excluded_teamwork_data() IS 'Deletes all Teamwork data for excluded companies/projects and unlinks related items';

GRANT EXECUTE ON FUNCTION purge_excluded_teamwork_data() TO authenticated;
GRANT EXECUTE ON FUNCTION search_companies_autocomplete(TEXT, INTEGER) TO authenticated;

-- =====================================
-- GET COMPANIES/PROJECTS BY IDS
-- =====================================

CREATE OR REPLACE FUNCTION get_companies_by_ids(p_ids INTEGER[])
RETURNS TABLE(id INTEGER, name TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT c.id, c.name::TEXT FROM teamwork.companies c WHERE c.id = ANY(p_ids) ORDER BY c.name;
$$;

CREATE OR REPLACE FUNCTION get_projects_by_ids(p_ids INTEGER[])
RETURNS TABLE(id INTEGER, name TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT p.id, p.name::TEXT FROM teamwork.projects p WHERE p.id = ANY(p_ids) ORDER BY p.name;
$$;

GRANT EXECUTE ON FUNCTION get_companies_by_ids(INTEGER[]) TO authenticated;
GRANT EXECUTE ON FUNCTION get_projects_by_ids(INTEGER[]) TO authenticated;

