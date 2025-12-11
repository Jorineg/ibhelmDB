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
    p_creator_contains TEXT DEFAULT NULL,
    p_status_in TEXT[] DEFAULT NULL, p_status_not_in TEXT[] DEFAULT NULL,
    p_priority_in TEXT[] DEFAULT NULL, p_priority_not_in TEXT[] DEFAULT NULL,
    p_due_date_min TIMESTAMP DEFAULT NULL, p_due_date_max TIMESTAMP DEFAULT NULL,
    p_due_date_is_null BOOLEAN DEFAULT NULL,
    p_created_at_min TIMESTAMPTZ DEFAULT NULL, p_created_at_max TIMESTAMPTZ DEFAULT NULL,
    p_updated_at_min TIMESTAMPTZ DEFAULT NULL, p_updated_at_max TIMESTAMPTZ DEFAULT NULL,
    p_progress_min INTEGER DEFAULT NULL, p_progress_max INTEGER DEFAULT NULL,
    p_attachment_count_min INTEGER DEFAULT NULL, p_attachment_count_max INTEGER DEFAULT NULL,
    p_sort_field TEXT DEFAULT 'sort_date', p_sort_order TEXT DEFAULT 'desc',
    p_limit INTEGER DEFAULT 50, p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    id TEXT, type TEXT, name TEXT, description TEXT, status VARCHAR, project TEXT, customer TEXT,
    location TEXT, location_path TEXT, cost_group TEXT, cost_group_code TEXT,
    due_date TIMESTAMP, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, priority VARCHAR, progress INTEGER, tasklist TEXT,
    task_type_id UUID, task_type_name TEXT, task_type_slug TEXT, task_type_color VARCHAR(50),
    assigned_to JSONB, tags JSONB, body TEXT, preview TEXT, creator TEXT,
    conversation_subject TEXT, recipients JSONB, attachments JSONB, attachment_count INTEGER,
    conversation_comments_text TEXT, craft_url TEXT, teamwork_url TEXT, missive_url TEXT, storage_path TEXT, thumbnail_path TEXT, sort_date TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_person_ids UUID[];
    v_has_person_filter BOOLEAN;
    v_cost_min INTEGER;
    v_cost_max INTEGER;
    v_has_cost_filter BOOLEAN;
    v_location_ids UUID[];
    v_has_location_filter BOOLEAN;
BEGIN
    IF p_sort_field NOT IN ('name', 'status', 'project', 'customer', 'due_date', 'created_at', 'updated_at', 'priority', 'sort_date', 'progress', 'attachment_count', 'cost_group_code', 'creator') THEN
        p_sort_field := 'sort_date';
    END IF;
    IF p_sort_order NOT IN ('asc', 'desc') THEN p_sort_order := 'desc'; END IF;
    
    v_has_person_filter := p_involved_person IS NOT NULL AND TRIM(p_involved_person) != '';
    IF v_has_person_filter THEN
        v_person_ids := find_person_ids_by_search(p_involved_person);
        IF array_length(v_person_ids, 1) IS NULL THEN RETURN; END IF;
    END IF;
    
    v_has_cost_filter := p_cost_group_code IS NOT NULL AND TRIM(p_cost_group_code) != '';
    IF v_has_cost_filter THEN
        SELECT cgr.min_code, cgr.max_code INTO v_cost_min, v_cost_max FROM compute_cost_group_range(p_cost_group_code) cgr;
        IF v_cost_min IS NULL THEN v_has_cost_filter := FALSE; END IF;
    END IF;
    
    v_has_location_filter := p_location_search IS NOT NULL AND TRIM(p_location_search) != '';
    IF v_has_location_filter THEN
        v_location_ids := find_location_ids_by_search(p_location_search);
        IF array_length(v_location_ids, 1) IS NULL THEN RETURN; END IF;
    END IF;
    
    RETURN QUERY
    SELECT ui.id, ui.type, ui.name, ui.description, ui.status, ui.project, ui.customer,
        ui.location, ui.location_path, ui.cost_group, ui.cost_group_code,
        ui.due_date, ui.created_at, ui.updated_at, ui.priority, ui.progress, ui.tasklist,
        ui.task_type_id, ui.task_type_name, ui.task_type_slug, ui.task_type_color,
        ui.assigned_to, ui.tags, ui.body, ui.preview, ui.creator,
        ui.conversation_subject, ui.recipients, ui.attachments, ui.attachment_count,
        ui.conversation_comments_text, ui.craft_url, ui.teamwork_url, ui.missive_url, ui.storage_path, ui.thumbnail_path, ui.sort_date
    FROM mv_unified_items ui
    WHERE (p_types IS NULL OR ui.type = ANY(p_types))
        AND (ui.type != 'task' OR p_task_types IS NULL OR ui.task_type_id = ANY(p_task_types))
        AND (p_text_search IS NULL OR p_text_search = '' OR
            ui.name ILIKE '%' || p_text_search || '%' OR
            ui.description ILIKE '%' || p_text_search || '%' OR
            ui.body ILIKE '%' || p_text_search || '%' OR
            ui.preview ILIKE '%' || p_text_search || '%' OR
            ui.conversation_comments_text ILIKE '%' || p_text_search || '%')
        AND (NOT v_has_person_filter OR EXISTS (
            SELECT 1 FROM item_involved_persons iip
            WHERE iip.item_id = ui.id AND iip.item_type = ui.type AND iip.unified_person_id = ANY(v_person_ids)))
        AND (p_tag_search IS NULL OR p_tag_search = '' OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(ui.tags) t WHERE t->>'name' ILIKE '%' || p_tag_search || '%'))
        AND (NOT v_has_cost_filter OR (ui.cost_group_code IS NOT NULL AND ui.cost_group_code ~ '^\d+$'
            AND ui.cost_group_code::INTEGER >= v_cost_min AND ui.cost_group_code::INTEGER <= v_cost_max))
        AND (p_project_search IS NULL OR p_project_search = '' OR ui.project ILIKE '%' || p_project_search || '%')
        AND (NOT v_has_location_filter OR (
            (ui.type = 'task' AND EXISTS (
                SELECT 1 FROM object_locations ol WHERE ol.tw_task_id = ui.id::INTEGER AND ol.location_id = ANY(v_location_ids)))
            OR (ui.type = 'email' AND EXISTS (
                SELECT 1 FROM object_locations ol 
                JOIN missive.messages mm ON mm.conversation_id = ol.m_conversation_id 
                WHERE mm.id = ui.id::UUID AND ol.location_id = ANY(v_location_ids)))
            OR (ui.type = 'file' AND EXISTS (
                SELECT 1 FROM object_locations ol WHERE ol.file_id = ui.id::UUID AND ol.location_id = ANY(v_location_ids)))))
        AND (p_name_contains IS NULL OR p_name_contains = '' OR ui.name ILIKE '%' || p_name_contains || '%')
        AND (p_description_contains IS NULL OR p_description_contains = '' OR ui.description ILIKE '%' || p_description_contains || '%')
        AND (p_customer_contains IS NULL OR p_customer_contains = '' OR ui.customer ILIKE '%' || p_customer_contains || '%')
        AND (p_tasklist_contains IS NULL OR p_tasklist_contains = '' OR ui.tasklist ILIKE '%' || p_tasklist_contains || '%')
        AND (p_creator_contains IS NULL OR p_creator_contains = '' OR ui.creator ILIKE '%' || p_creator_contains || '%')
        AND (p_status_in IS NULL OR ui.status = ANY(p_status_in))
        AND (p_status_not_in IS NULL OR ui.status IS NULL OR NOT (ui.status = ANY(p_status_not_in)))
        AND (p_priority_in IS NULL OR ui.priority = ANY(p_priority_in))
        AND (p_priority_not_in IS NULL OR ui.priority IS NULL OR NOT (ui.priority = ANY(p_priority_not_in)))
        AND (p_due_date_min IS NULL OR ui.due_date >= p_due_date_min)
        AND (p_due_date_max IS NULL OR ui.due_date <= p_due_date_max)
        AND (p_due_date_is_null IS NULL OR (p_due_date_is_null = TRUE AND ui.due_date IS NULL) OR (p_due_date_is_null = FALSE AND ui.due_date IS NOT NULL))
        AND (p_created_at_min IS NULL OR ui.created_at >= p_created_at_min)
        AND (p_created_at_max IS NULL OR ui.created_at <= p_created_at_max)
        AND (p_updated_at_min IS NULL OR ui.updated_at >= p_updated_at_min)
        AND (p_updated_at_max IS NULL OR ui.updated_at <= p_updated_at_max)
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
        CASE WHEN p_sort_field = 'attachment_count' AND p_sort_order = 'asc' THEN ui.attachment_count END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'cost_group_code' AND p_sort_order = 'desc' THEN NULLIF(ui.cost_group_code, '')::INTEGER END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'cost_group_code' AND p_sort_order = 'asc' THEN NULLIF(ui.cost_group_code, '')::INTEGER END ASC NULLS LAST,
        CASE WHEN p_sort_field = 'creator' AND p_sort_order = 'desc' THEN ui.creator END DESC NULLS LAST,
        CASE WHEN p_sort_field = 'creator' AND p_sort_order = 'asc' THEN ui.creator END ASC NULLS LAST
    LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION count_unified_items_with_metadata(
    p_types TEXT[] DEFAULT NULL, p_task_types UUID[] DEFAULT NULL,
    p_text_search TEXT DEFAULT NULL, p_involved_person TEXT DEFAULT NULL,
    p_tag_search TEXT DEFAULT NULL, p_cost_group_code TEXT DEFAULT NULL,
    p_project_search TEXT DEFAULT NULL, p_location_search TEXT DEFAULT NULL,
    p_name_contains TEXT DEFAULT NULL, p_description_contains TEXT DEFAULT NULL,
    p_customer_contains TEXT DEFAULT NULL, p_tasklist_contains TEXT DEFAULT NULL,
    p_creator_contains TEXT DEFAULT NULL,
    p_status_in TEXT[] DEFAULT NULL, p_status_not_in TEXT[] DEFAULT NULL,
    p_priority_in TEXT[] DEFAULT NULL, p_priority_not_in TEXT[] DEFAULT NULL,
    p_due_date_min TIMESTAMP DEFAULT NULL, p_due_date_max TIMESTAMP DEFAULT NULL,
    p_due_date_is_null BOOLEAN DEFAULT NULL,
    p_created_at_min TIMESTAMPTZ DEFAULT NULL, p_created_at_max TIMESTAMPTZ DEFAULT NULL,
    p_updated_at_min TIMESTAMPTZ DEFAULT NULL, p_updated_at_max TIMESTAMPTZ DEFAULT NULL,
    p_progress_min INTEGER DEFAULT NULL, p_progress_max INTEGER DEFAULT NULL,
    p_attachment_count_min INTEGER DEFAULT NULL, p_attachment_count_max INTEGER DEFAULT NULL
)
RETURNS TABLE(total_count INTEGER, nonempty_columns TEXT[], type_counts JSONB, task_type_counts JSONB)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_person_ids UUID[];
    v_has_person_filter BOOLEAN;
    v_cost_min INTEGER;
    v_cost_max INTEGER;
    v_has_cost_filter BOOLEAN;
    v_location_ids UUID[];
    v_has_location_filter BOOLEAN;
    -- Column presence flags
    v_has_name BOOLEAN; v_has_description BOOLEAN; v_has_body BOOLEAN;
    v_has_status BOOLEAN; v_has_project BOOLEAN; v_has_customer BOOLEAN;
    v_has_location BOOLEAN; v_has_location_path BOOLEAN;
    v_has_cost_group BOOLEAN; v_has_cost_group_code BOOLEAN;
    v_has_due_date BOOLEAN; v_has_priority BOOLEAN; v_has_progress BOOLEAN;
    v_has_tasklist BOOLEAN; v_has_assigned_to BOOLEAN; v_has_tags BOOLEAN;
    v_has_creator BOOLEAN;
    v_has_recipients BOOLEAN; v_has_conversation_subject BOOLEAN;
    v_has_attachment_count BOOLEAN;
    v_has_created_at BOOLEAN; v_has_updated_at BOOLEAN;
BEGIN
    v_has_person_filter := p_involved_person IS NOT NULL AND TRIM(p_involved_person) != '';
    IF v_has_person_filter THEN
        v_person_ids := find_person_ids_by_search(p_involved_person);
        IF array_length(v_person_ids, 1) IS NULL THEN
            total_count := 0; nonempty_columns := ARRAY[]::TEXT[];
            type_counts := '{}'::JSONB; task_type_counts := '{}'::JSONB;
            RETURN NEXT; RETURN;
        END IF;
    END IF;
    
    v_has_cost_filter := p_cost_group_code IS NOT NULL AND TRIM(p_cost_group_code) != '';
    IF v_has_cost_filter THEN
        SELECT cgr.min_code, cgr.max_code INTO v_cost_min, v_cost_max FROM compute_cost_group_range(p_cost_group_code) cgr;
        IF v_cost_min IS NULL THEN v_has_cost_filter := FALSE; END IF;
    END IF;
    
    v_has_location_filter := p_location_search IS NOT NULL AND TRIM(p_location_search) != '';
    IF v_has_location_filter THEN
        v_location_ids := find_location_ids_by_search(p_location_search);
        IF array_length(v_location_ids, 1) IS NULL THEN
            total_count := 0; nonempty_columns := ARRAY[]::TEXT[];
            type_counts := '{}'::JSONB; task_type_counts := '{}'::JSONB;
            RETURN NEXT; RETURN;
        END IF;
    END IF;
    
    -- Main aggregation query
    SELECT 
        COUNT(*)::INTEGER,
        -- Column presence checks (BOOL_OR short-circuits)
        BOOL_OR(ui.name IS NOT NULL AND ui.name != ''),
        BOOL_OR(ui.description IS NOT NULL AND ui.description != ''),
        BOOL_OR(ui.body IS NOT NULL AND ui.body != ''),
        BOOL_OR(ui.status IS NOT NULL AND ui.status != ''),
        BOOL_OR(ui.project IS NOT NULL AND ui.project != ''),
        BOOL_OR(ui.customer IS NOT NULL AND ui.customer != ''),
        BOOL_OR(ui.location IS NOT NULL AND ui.location != ''),
        BOOL_OR(ui.location_path IS NOT NULL AND ui.location_path != ''),
        BOOL_OR(ui.cost_group IS NOT NULL AND ui.cost_group != ''),
        BOOL_OR(ui.cost_group_code IS NOT NULL AND ui.cost_group_code != ''),
        BOOL_OR(ui.due_date IS NOT NULL),
        BOOL_OR(ui.priority IS NOT NULL AND ui.priority != ''),
        BOOL_OR(ui.progress IS NOT NULL),
        BOOL_OR(ui.tasklist IS NOT NULL AND ui.tasklist != ''),
        BOOL_OR(ui.assigned_to IS NOT NULL AND jsonb_array_length(ui.assigned_to) > 0),
        BOOL_OR(ui.tags IS NOT NULL AND jsonb_array_length(ui.tags) > 0),
        BOOL_OR(ui.creator IS NOT NULL AND ui.creator != ''),
        BOOL_OR(ui.recipients IS NOT NULL AND jsonb_array_length(ui.recipients) > 0),
        BOOL_OR(ui.conversation_subject IS NOT NULL AND ui.conversation_subject != ''),
        BOOL_OR(ui.attachment_count IS NOT NULL AND ui.attachment_count > 0),
        BOOL_OR(ui.created_at IS NOT NULL),
        BOOL_OR(ui.updated_at IS NOT NULL),
        -- Type counts as JSONB
        jsonb_build_object(
            'task', COUNT(*) FILTER (WHERE ui.type = 'task'),
            'email', COUNT(*) FILTER (WHERE ui.type = 'email'),
            'craft', COUNT(*) FILTER (WHERE ui.type = 'craft'),
            'file', COUNT(*) FILTER (WHERE ui.type = 'file')
        ),
        -- Task type counts: aggregate task_type_id -> count
        COALESCE(
            (SELECT jsonb_object_agg(tt.task_type_id, tt.cnt)
             FROM (
                 SELECT ui2.task_type_id, COUNT(*)::INTEGER as cnt
                 FROM mv_unified_items ui2
                 WHERE ui2.type = 'task' AND ui2.task_type_id IS NOT NULL
                     AND (p_types IS NULL OR ui2.type = ANY(p_types))
                     AND (p_task_types IS NULL OR ui2.task_type_id = ANY(p_task_types))
                     AND (p_text_search IS NULL OR p_text_search = '' OR
                         ui2.name ILIKE '%' || p_text_search || '%' OR
                         ui2.description ILIKE '%' || p_text_search || '%' OR
                         ui2.body ILIKE '%' || p_text_search || '%' OR
                         ui2.preview ILIKE '%' || p_text_search || '%' OR
                         ui2.conversation_comments_text ILIKE '%' || p_text_search || '%')
                     AND (NOT v_has_person_filter OR EXISTS (
                         SELECT 1 FROM item_involved_persons iip WHERE iip.item_id = ui2.id AND iip.item_type = ui2.type AND iip.unified_person_id = ANY(v_person_ids)))
                     AND (p_tag_search IS NULL OR p_tag_search = '' OR EXISTS (
                         SELECT 1 FROM jsonb_array_elements(ui2.tags) t WHERE t->>'name' ILIKE '%' || p_tag_search || '%'))
                     AND (NOT v_has_cost_filter OR (ui2.cost_group_code IS NOT NULL AND ui2.cost_group_code ~ '^\d+$'
                         AND ui2.cost_group_code::INTEGER >= v_cost_min AND ui2.cost_group_code::INTEGER <= v_cost_max))
                     AND (p_project_search IS NULL OR p_project_search = '' OR ui2.project ILIKE '%' || p_project_search || '%')
                     AND (NOT v_has_location_filter OR EXISTS (
                         SELECT 1 FROM object_locations ol WHERE ol.tw_task_id = ui2.id::INTEGER AND ol.location_id = ANY(v_location_ids)))
                     AND (p_name_contains IS NULL OR p_name_contains = '' OR ui2.name ILIKE '%' || p_name_contains || '%')
                     AND (p_description_contains IS NULL OR p_description_contains = '' OR ui2.description ILIKE '%' || p_description_contains || '%')
                     AND (p_customer_contains IS NULL OR p_customer_contains = '' OR ui2.customer ILIKE '%' || p_customer_contains || '%')
                     AND (p_tasklist_contains IS NULL OR p_tasklist_contains = '' OR ui2.tasklist ILIKE '%' || p_tasklist_contains || '%')
                     AND (p_status_in IS NULL OR ui2.status = ANY(p_status_in))
                     AND (p_status_not_in IS NULL OR ui2.status IS NULL OR NOT (ui2.status = ANY(p_status_not_in)))
                     AND (p_priority_in IS NULL OR ui2.priority = ANY(p_priority_in))
                     AND (p_priority_not_in IS NULL OR ui2.priority IS NULL OR NOT (ui2.priority = ANY(p_priority_not_in)))
                     AND (p_due_date_min IS NULL OR ui2.due_date >= p_due_date_min)
                     AND (p_due_date_max IS NULL OR ui2.due_date <= p_due_date_max)
                     AND (p_due_date_is_null IS NULL OR (p_due_date_is_null = TRUE AND ui2.due_date IS NULL) OR (p_due_date_is_null = FALSE AND ui2.due_date IS NOT NULL))
                     AND (p_created_at_min IS NULL OR ui2.created_at >= p_created_at_min)
                     AND (p_created_at_max IS NULL OR ui2.created_at <= p_created_at_max)
                     AND (p_updated_at_min IS NULL OR ui2.updated_at >= p_updated_at_min)
                     AND (p_updated_at_max IS NULL OR ui2.updated_at <= p_updated_at_max)
                     AND (p_progress_min IS NULL OR ui2.progress >= p_progress_min)
                     AND (p_progress_max IS NULL OR ui2.progress <= p_progress_max)
                     AND (p_attachment_count_min IS NULL OR ui2.attachment_count >= p_attachment_count_min)
                     AND (p_attachment_count_max IS NULL OR ui2.attachment_count <= p_attachment_count_max)
                 GROUP BY ui2.task_type_id
             ) tt),
            '{}'::JSONB
        )
    INTO total_count,
        v_has_name, v_has_description, v_has_body,
        v_has_status, v_has_project, v_has_customer,
        v_has_location, v_has_location_path,
        v_has_cost_group, v_has_cost_group_code,
        v_has_due_date, v_has_priority, v_has_progress,
        v_has_tasklist, v_has_assigned_to, v_has_tags,
        v_has_creator,
        v_has_recipients, v_has_conversation_subject,
        v_has_attachment_count, v_has_created_at, v_has_updated_at,
        type_counts, task_type_counts
    FROM mv_unified_items ui
    WHERE (p_types IS NULL OR ui.type = ANY(p_types))
        AND (ui.type != 'task' OR p_task_types IS NULL OR ui.task_type_id = ANY(p_task_types))
        AND (p_text_search IS NULL OR p_text_search = '' OR
            ui.name ILIKE '%' || p_text_search || '%' OR
            ui.description ILIKE '%' || p_text_search || '%' OR
            ui.body ILIKE '%' || p_text_search || '%' OR
            ui.preview ILIKE '%' || p_text_search || '%' OR
            ui.conversation_comments_text ILIKE '%' || p_text_search || '%')
        AND (NOT v_has_person_filter OR EXISTS (
            SELECT 1 FROM item_involved_persons iip WHERE iip.item_id = ui.id AND iip.item_type = ui.type AND iip.unified_person_id = ANY(v_person_ids)))
        AND (p_tag_search IS NULL OR p_tag_search = '' OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(ui.tags) t WHERE t->>'name' ILIKE '%' || p_tag_search || '%'))
        AND (NOT v_has_cost_filter OR (ui.cost_group_code IS NOT NULL AND ui.cost_group_code ~ '^\d+$'
            AND ui.cost_group_code::INTEGER >= v_cost_min AND ui.cost_group_code::INTEGER <= v_cost_max))
        AND (p_project_search IS NULL OR p_project_search = '' OR ui.project ILIKE '%' || p_project_search || '%')
        AND (NOT v_has_location_filter OR (
            (ui.type = 'task' AND EXISTS (
                SELECT 1 FROM object_locations ol WHERE ol.tw_task_id = ui.id::INTEGER AND ol.location_id = ANY(v_location_ids)))
            OR (ui.type = 'email' AND EXISTS (
                SELECT 1 FROM object_locations ol 
                JOIN missive.messages mm ON mm.conversation_id = ol.m_conversation_id 
                WHERE mm.id = ui.id::UUID AND ol.location_id = ANY(v_location_ids)))
            OR (ui.type = 'file' AND EXISTS (
                SELECT 1 FROM object_locations ol WHERE ol.file_id = ui.id::UUID AND ol.location_id = ANY(v_location_ids)))))
        AND (p_name_contains IS NULL OR p_name_contains = '' OR ui.name ILIKE '%' || p_name_contains || '%')
        AND (p_description_contains IS NULL OR p_description_contains = '' OR ui.description ILIKE '%' || p_description_contains || '%')
        AND (p_customer_contains IS NULL OR p_customer_contains = '' OR ui.customer ILIKE '%' || p_customer_contains || '%')
        AND (p_tasklist_contains IS NULL OR p_tasklist_contains = '' OR ui.tasklist ILIKE '%' || p_tasklist_contains || '%')
        AND (p_creator_contains IS NULL OR p_creator_contains = '' OR ui.creator ILIKE '%' || p_creator_contains || '%')
        AND (p_status_in IS NULL OR ui.status = ANY(p_status_in))
        AND (p_status_not_in IS NULL OR ui.status IS NULL OR NOT (ui.status = ANY(p_status_not_in)))
        AND (p_priority_in IS NULL OR ui.priority = ANY(p_priority_in))
        AND (p_priority_not_in IS NULL OR ui.priority IS NULL OR NOT (ui.priority = ANY(p_priority_not_in)))
        AND (p_due_date_min IS NULL OR ui.due_date >= p_due_date_min)
        AND (p_due_date_max IS NULL OR ui.due_date <= p_due_date_max)
        AND (p_due_date_is_null IS NULL OR (p_due_date_is_null = TRUE AND ui.due_date IS NULL) OR (p_due_date_is_null = FALSE AND ui.due_date IS NOT NULL))
        AND (p_created_at_min IS NULL OR ui.created_at >= p_created_at_min)
        AND (p_created_at_max IS NULL OR ui.created_at <= p_created_at_max)
        AND (p_updated_at_min IS NULL OR ui.updated_at >= p_updated_at_min)
        AND (p_updated_at_max IS NULL OR ui.updated_at <= p_updated_at_max)
        AND (p_progress_min IS NULL OR ui.progress >= p_progress_min)
        AND (p_progress_max IS NULL OR ui.progress <= p_progress_max)
        AND (p_attachment_count_min IS NULL OR ui.attachment_count >= p_attachment_count_min)
        AND (p_attachment_count_max IS NULL OR ui.attachment_count <= p_attachment_count_max);
    
    -- Build nonempty_columns array from flags
    nonempty_columns := ARRAY_REMOVE(ARRAY[
        CASE WHEN v_has_name THEN 'name' END,
        CASE WHEN v_has_description THEN 'description' END,
        CASE WHEN v_has_body THEN 'body' END,
        CASE WHEN v_has_status THEN 'status' END,
        CASE WHEN v_has_project THEN 'project' END,
        CASE WHEN v_has_customer THEN 'customer' END,
        CASE WHEN v_has_location THEN 'location' END,
        CASE WHEN v_has_location_path THEN 'location_path' END,
        CASE WHEN v_has_cost_group THEN 'cost_group' END,
        CASE WHEN v_has_cost_group_code THEN 'cost_group_code' END,
        CASE WHEN v_has_due_date THEN 'due_date' END,
        CASE WHEN v_has_priority THEN 'priority' END,
        CASE WHEN v_has_progress THEN 'progress' END,
        CASE WHEN v_has_tasklist THEN 'tasklist' END,
        CASE WHEN v_has_assigned_to THEN 'assigned_to' END,
        CASE WHEN v_has_tags THEN 'tags' END,
        CASE WHEN v_has_creator THEN 'creator' END,
        CASE WHEN v_has_recipients THEN 'recipients' END,
        CASE WHEN v_has_conversation_subject THEN 'conversation_subject' END,
        CASE WHEN v_has_attachment_count THEN 'attachment_count' END,
        CASE WHEN v_has_created_at THEN 'created_at' END,
        CASE WHEN v_has_updated_at THEN 'updated_at' END
    ], NULL);
    
    RETURN NEXT;
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
    IF p_sort_field NOT IN ('display_name', 'primary_email', 'is_internal', 'is_company', 'db_created_at', 'db_updated_at') THEN
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
        CASE WHEN p_sort_field = 'db_updated_at' AND p_sort_order = 'desc' THEN upd.db_updated_at END DESC NULLS LAST
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
    pending_count BIGINT, processing_count BIGINT, failed_count BIGINT, last_processed_at TIMESTAMPTZ
) AS $$
BEGIN
    -- Return connector sources (teamwork, missive, craft)
    RETURN QUERY SELECT COALESCE(c.source, q.source) AS source, c.last_event_time, c.updated_at AS checkpoint_updated_at,
        COALESCE(q.pending_count, 0) AS pending_count, COALESCE(q.processing_count, 0) AS processing_count,
        COALESCE(q.failed_count, 0) AS failed_count, q.last_processed_at
    FROM (
        SELECT qi.source,
            COUNT(*) FILTER (WHERE qi.status = 'pending') AS pending_count,
            COUNT(*) FILTER (WHERE qi.status = 'processing') AS processing_count,
            COUNT(*) FILTER (WHERE qi.status = 'failed') AS failed_count,
            MAX(qi.processed_at) FILTER (WHERE qi.status = 'completed') AS last_processed_at
        FROM teamworkmissiveconnector.queue_items qi GROUP BY qi.source
    ) q FULL OUTER JOIN teamworkmissiveconnector.checkpoints c ON c.source = q.source
    WHERE COALESCE(c.source, q.source) IN ('teamwork', 'missive', 'craft');
    
    -- Return files checkpoint (no queue)
    RETURN QUERY SELECT 
        'files'::VARCHAR(50) AS source,
        fc.last_event_time,
        fc.updated_at AS checkpoint_updated_at,
        0::BIGINT AS pending_count,
        0::BIGINT AS processing_count,
        0::BIGINT AS failed_count,
        NULL::TIMESTAMPTZ AS last_processed_at
    FROM teamworkmissiveconnector.checkpoints fc
    WHERE fc.source = 'files';
    
    -- Return thumbnails queue status
    RETURN QUERY SELECT 
        'thumbnails'::VARCHAR(50) AS source,
        NULL::TIMESTAMPTZ AS last_event_time,
        NULL::TIMESTAMPTZ AS checkpoint_updated_at,
        COUNT(*) FILTER (WHERE tq.status = 'pending') AS pending_count,
        COUNT(*) FILTER (WHERE tq.status = 'processing') AS processing_count,
        COUNT(*) FILTER (WHERE tq.status = 'failed') AS failed_count,
        MAX(tq.processed_at) FILTER (WHERE tq.status = 'completed') AS last_processed_at
    FROM thumbnail_processing_queue tq;
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
-- 16. THUMBNAIL PROCESSING QUEUE
-- =====================================

CREATE OR REPLACE FUNCTION queue_file_for_processing()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO thumbnail_processing_queue (file_id)
    VALUES (NEW.id)
    ON CONFLICT (file_id) DO UPDATE SET 
        status = 'pending', 
        attempts = 0,
        last_error = NULL,
        updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_queue_file_processing ON files;
CREATE TRIGGER trigger_queue_file_processing
    AFTER INSERT OR UPDATE OF content_hash ON files
    FOR EACH ROW
    EXECUTE FUNCTION queue_file_for_processing();

CREATE OR REPLACE FUNCTION get_thumbnail_queue_status()
RETURNS TABLE (
    pending_count BIGINT,
    processing_count BIGINT,
    completed_count BIGINT,
    failed_count BIGINT,
    last_processed_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY 
    SELECT 
        COUNT(*) FILTER (WHERE status = 'pending'),
        COUNT(*) FILTER (WHERE status = 'processing'),
        COUNT(*) FILTER (WHERE status = 'completed'),
        COUNT(*) FILTER (WHERE status = 'failed'),
        MAX(processed_at) FILTER (WHERE status = 'completed')
    FROM thumbnail_processing_queue;
END;
$$ LANGUAGE plpgsql STABLE;

-- =====================================
-- 17. FILES CHECKPOINT UPSERT
-- =====================================

CREATE OR REPLACE FUNCTION upsert_files_checkpoint(p_last_event_time TIMESTAMPTZ DEFAULT NULL)
RETURNS VOID AS $$
BEGIN
    IF p_last_event_time IS NOT NULL THEN
        -- New files uploaded, update both timestamps
        INSERT INTO teamworkmissiveconnector.checkpoints (source, last_event_time, updated_at)
        VALUES ('files', p_last_event_time, NOW())
        ON CONFLICT (source) DO UPDATE SET
            last_event_time = EXCLUDED.last_event_time,
            updated_at = NOW();
    ELSE
        -- No new files, only update updated_at if record exists, otherwise create with epoch
        INSERT INTO teamworkmissiveconnector.checkpoints (source, last_event_time, updated_at)
        VALUES ('files', '1970-01-01T00:00:00Z', NOW())
        ON CONFLICT (source) DO UPDATE SET updated_at = NOW();
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================
-- GRANTS
-- =====================================

GRANT SELECT ON mv_refresh_status TO authenticated;
GRANT EXECUTE ON FUNCTION mark_mv_needs_refresh(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION refresh_unified_items_aggregates(BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION refresh_stale_unified_items_aggregates() TO authenticated;
GRANT EXECUTE ON FUNCTION compute_cost_group_range(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_sync_status() TO authenticated;
GRANT EXECUTE ON FUNCTION get_thumbnail_queue_status() TO authenticated;
GRANT EXECUTE ON FUNCTION query_unified_persons(TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION count_unified_persons(TEXT, TEXT, BOOLEAN, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION upsert_files_checkpoint(TIMESTAMPTZ) TO service_role;

