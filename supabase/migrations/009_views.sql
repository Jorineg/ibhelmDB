-- =====================================
-- VIEWS
-- =====================================

-- =====================================
-- 1. UNIFIED ITEMS VIEW
-- =====================================
-- Combines tasks and emails into a single queryable structure

CREATE OR REPLACE VIEW unified_items AS

-- Tasks from Teamwork
SELECT 
    t.id::TEXT AS id,
    'task' AS type,
    t.name,
    t.description,
    t.status,
    p.name AS project,
    c.name AS customer,
    l.name AS location,
    l.search_text AS location_path,
    cg.name AS cost_group,
    cg.code AS cost_group_code,
    t.due_date,
    t.created_at,
    t.updated_at,
    t.priority,
    t.progress,
    tl.name AS tasklist,
    
    -- Task type from task_extensions
    tt.id AS task_type_id,
    tt.name AS task_type_name,
    tt.slug AS task_type_slug,
    tt.color AS task_type_color,
    
    -- Aggregate assignees
    (
        SELECT jsonb_agg(jsonb_build_object(
            'id', u.id, 
            'first_name', u.first_name, 
            'last_name', u.last_name, 
            'email', u.email
        ))
        FROM teamwork.task_assignees ta
        JOIN teamwork.users u ON ta.user_id = u.id
        WHERE ta.task_id = t.id
    ) AS assignees,
    
    -- Aggregate tags
    (
        SELECT jsonb_agg(jsonb_build_object(
            'id', tag.id, 
            'name', tag.name, 
            'color', tag.color
        ))
        FROM teamwork.task_tags tt
        JOIN teamwork.tags tag ON tt.tag_id = tag.id
        WHERE tt.task_id = t.id
    ) AS tags,
    
    -- Email-specific fields (null for tasks)
    NULL::TEXT AS body,
    NULL::TEXT AS preview,
    NULL::TEXT AS from_name,
    NULL::TEXT AS from_email,
    NULL::TEXT AS conversation_subject,
    NULL::JSONB AS recipients,
    NULL::JSONB AS attachments,
    0 AS attachment_count,
    
    -- External links
    t.source_links->>'teamwork_url' AS teamwork_url,
    NULL::TEXT AS missive_url,
    
    -- Sort key
    COALESCE(t.updated_at, t.created_at) AS sort_date
    
FROM teamwork.tasks t
LEFT JOIN teamwork.projects p ON t.project_id = p.id
LEFT JOIN teamwork.companies c ON p.company_id = c.id
LEFT JOIN teamwork.tasklists tl ON t.tasklist_id = tl.id
LEFT JOIN object_locations ol ON t.id = ol.tw_task_id
LEFT JOIN locations l ON ol.location_id = l.id
LEFT JOIN object_cost_groups ocg ON t.id = ocg.tw_task_id
LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id
LEFT JOIN task_extensions te ON t.id = te.tw_task_id
LEFT JOIN task_types tt ON te.task_type_id = tt.id
WHERE t.deleted_at IS NULL

UNION ALL

-- Emails from Missive (via conversations for location/cost group linking)
SELECT 
    m.id::TEXT AS id,
    'email' AS type,
    m.subject AS name,
    COALESCE(m.preview, LEFT(m.body, 200)) AS description,
    '' AS status,
    COALESCE(twp.name, '') AS project,
    '' AS customer,
    l.name AS location,
    l.search_text AS location_path,
    cg.name AS cost_group,
    cg.code AS cost_group_code,
    NULL AS due_date,
    m.created_at,
    m.updated_at,
    '' AS priority,
    NULL AS progress,
    '' AS tasklist,
    
    -- Task type fields (null for emails)
    NULL::UUID AS task_type_id,
    NULL::TEXT AS task_type_name,
    NULL::TEXT AS task_type_slug,
    NULL::VARCHAR(50) AS task_type_color,
    
    -- Task-specific fields (null for emails)
    NULL::JSONB AS assignees,
    
    -- Aggregate conversation labels as tags (all messages in a conversation get all labels)
    (
        SELECT jsonb_agg(jsonb_build_object(
            'id', sl.id, 
            'name', sl.name, 
            'color', NULL
        ))
        FROM missive.conversation_labels cl
        JOIN missive.shared_labels sl ON cl.label_id = sl.id
        WHERE cl.conversation_id = m.conversation_id
    ) AS tags,
    
    -- Email-specific fields
    m.body_plain_text AS body,
    m.preview,
    from_contact.name AS from_name,
    from_contact.email AS from_email,
    conv.subject AS conversation_subject,
    
    -- Aggregate recipients
    (
        SELECT jsonb_agg(jsonb_build_object(
            'id', mr.id, 
            'recipient_type', mr.recipient_type, 
            'contact', jsonb_build_object(
                'id', rc.id, 
                'name', rc.name, 
                'email', rc.email
            )
        ))
        FROM missive.message_recipients mr
        LEFT JOIN missive.contacts rc ON mr.contact_id = rc.id
        WHERE mr.message_id = m.id
    ) AS recipients,
    
    -- Aggregate attachments
    (
        SELECT jsonb_agg(jsonb_build_object(
            'id', a.id, 
            'filename', a.filename, 
            'extension', a.extension, 
            'size', a.size
        ))
        FROM missive.attachments a
        WHERE a.message_id = m.id
    ) AS attachments,
    
    (
        SELECT COUNT(*)::INTEGER
        FROM missive.attachments a
        WHERE a.message_id = m.id
    ) AS attachment_count,
    
    -- External links
    NULL::TEXT AS teamwork_url,
    conv.app_url AS missive_url,
    
    -- Sort key
    COALESCE(m.delivered_at, m.updated_at, m.created_at) AS sort_date
    
FROM missive.messages m
LEFT JOIN missive.conversations conv ON m.conversation_id = conv.id
LEFT JOIN missive.contacts from_contact ON m.from_contact_id = from_contact.id
-- Join locations and cost groups via conversation (not message)
LEFT JOIN object_locations ol ON conv.id = ol.m_conversation_id
LEFT JOIN locations l ON ol.location_id = l.id
LEFT JOIN object_cost_groups ocg ON conv.id = ocg.m_conversation_id
LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id
-- Join project via project_conversations
LEFT JOIN project_conversations pc ON conv.id = pc.m_conversation_id
LEFT JOIN teamwork.projects twp ON pc.tw_project_id = twp.id;

-- =====================================
-- 2. UNIFIED PERSON DETAILS VIEW
-- =====================================
-- Enriched unified person view with linked system info

CREATE OR REPLACE VIEW unified_person_details AS
SELECT 
    up.id,
    up.display_name,
    up.primary_email,
    up.preferred_contact_method,
    up.is_internal,
    up.is_company,
    up.notes,
    
    -- Teamwork company data (if linked)
    twc.id AS tw_company_id,
    twc.name AS tw_company_name,
    twc.website AS tw_company_website,
    
    -- Teamwork user data (if linked)
    twu.id AS tw_user_id,
    twu.first_name AS tw_user_first_name,
    twu.last_name AS tw_user_last_name,
    twu.email AS tw_user_email,
    
    -- Missive contact data (if linked)
    mc.id AS m_contact_id,
    mc.email AS m_contact_email,
    mc.name AS m_contact_name,
    
    up.db_created_at,
    up.db_updated_at
    
FROM unified_persons up
LEFT JOIN unified_person_links upl_company ON up.id = upl_company.unified_person_id AND upl_company.tw_company_id IS NOT NULL
LEFT JOIN teamwork.companies twc ON upl_company.tw_company_id = twc.id
LEFT JOIN unified_person_links upl_user ON up.id = upl_user.unified_person_id AND upl_user.tw_user_id IS NOT NULL
LEFT JOIN teamwork.users twu ON upl_user.tw_user_id = twu.id
LEFT JOIN unified_person_links upl_contact ON up.id = upl_contact.unified_person_id AND upl_contact.m_contact_id IS NOT NULL
LEFT JOIN missive.contacts mc ON upl_contact.m_contact_id = mc.id;

-- =====================================
-- 3. PROJECT OVERVIEW VIEW
-- =====================================
-- Teamwork project with ibhelm extensions and aggregated data

CREATE OR REPLACE VIEW project_overview AS
SELECT 
    twp.id,
    twp.name,
    twp.description,
    twp.status,
    twp.start_date,
    twp.end_date,
    
    -- Company info
    twc.name AS company_name,
    
    -- Client info from project_extensions
    client.display_name AS client_name,
    client.primary_email AS client_email,
    
    -- ibhelm extensions
    pe.nas_folder_path,
    pe.internal_notes,
    
    -- Default location
    dl.name AS default_location_name,
    dl.search_text AS default_location_path,
    
    -- Default cost group
    dcg.name AS default_cost_group_name,
    dcg.code AS default_cost_group_code,
    
    -- Aggregated counts
    (SELECT COUNT(*) FROM project_files pf WHERE pf.tw_project_id = twp.id) AS file_count,
    (SELECT COUNT(*) FROM project_contractors pc WHERE pc.tw_project_id = twp.id) AS contractor_count,
    (SELECT COUNT(*) FROM project_conversations pcon WHERE pcon.tw_project_id = twp.id) AS conversation_count,
    (SELECT COUNT(*) FROM teamwork.tasks t WHERE t.project_id = twp.id AND t.deleted_at IS NULL) AS task_count,
    (SELECT COUNT(*) FROM teamwork.tasks t WHERE t.project_id = twp.id AND t.deleted_at IS NULL AND t.status = 'completed') AS completed_task_count,
    
    twp.created_at,
    twp.updated_at,
    pe.db_created_at AS extension_created_at,
    pe.db_updated_at AS extension_updated_at
    
FROM teamwork.projects twp
LEFT JOIN teamwork.companies twc ON twp.company_id = twc.id
LEFT JOIN project_extensions pe ON twp.id = pe.tw_project_id
LEFT JOIN unified_persons client ON pe.client_person_id = client.id
LEFT JOIN locations dl ON pe.default_location_id = dl.id
LEFT JOIN cost_groups dcg ON pe.default_cost_group_id = dcg.id;

-- =====================================
-- 4. FILE DETAILS VIEW
-- =====================================
-- Files with all related metadata

CREATE OR REPLACE VIEW file_details AS
SELECT 
    f.id,
    f.filename,
    f.folder_path,
    f.content_hash,
    
    -- Document type
    dt.name AS document_type,
    dt.slug AS document_type_slug,
    
    -- Thumbnail info
    f.thumbnail_path,
    f.thumbnail_generated_at,
    f.thumbnail_generated_at IS NOT NULL AS has_thumbnail,
    
    -- Full-text search available
    f.extracted_text IS NOT NULL AND LENGTH(f.extracted_text) > 0 AS has_extracted_text,
    
    -- Source info
    ma.filename AS source_attachment_filename,
    ma.size AS source_attachment_size,
    
    -- Projects (aggregated)
    (
        SELECT jsonb_agg(jsonb_build_object(
            'id', twp.id,
            'name', twp.name
        ))
        FROM project_files pf
        JOIN teamwork.projects twp ON pf.tw_project_id = twp.id
        WHERE pf.file_id = f.id
    ) AS projects,
    
    -- Locations (aggregated)
    (
        SELECT jsonb_agg(jsonb_build_object(
            'id', loc.id,
            'name', loc.name,
            'type', loc.type,
            'path', loc.search_text
        ))
        FROM object_locations ol
        JOIN locations loc ON ol.location_id = loc.id
        WHERE ol.file_id = f.id
    ) AS locations,
    
    -- Cost groups (aggregated)
    (
        SELECT jsonb_agg(jsonb_build_object(
            'id', cg.id,
            'code', cg.code,
            'name', cg.name
        ))
        FROM object_cost_groups ocg
        JOIN cost_groups cg ON ocg.cost_group_id = cg.id
        WHERE ocg.file_id = f.id
    ) AS cost_groups,
    
    f.file_created_at,
    f.file_modified_at,
    f.db_created_at,
    f.db_updated_at
    
FROM files f
LEFT JOIN document_types dt ON f.document_type_id = dt.id
LEFT JOIN missive.attachments ma ON f.source_missive_attachment_id = ma.id;

-- =====================================
-- 5. LOCATION HIERARCHY VIEW
-- =====================================
-- Locations with full hierarchy information

CREATE OR REPLACE VIEW location_hierarchy AS
SELECT 
    l.id,
    l.name,
    l.type,
    l.depth,
    l.path,
    l.search_text AS full_path,
    
    -- Parent info
    parent.id AS parent_id,
    parent.name AS parent_name,
    parent.type AS parent_type,
    
    -- Building (root) info
    building.id AS building_id,
    building.name AS building_name,
    
    -- Count children
    (SELECT COUNT(*) FROM locations child WHERE child.parent_id = l.id) AS child_count,
    
    -- Count related objects
    (SELECT COUNT(*) FROM object_locations ol WHERE ol.location_id = l.id) AS related_object_count,
    
    l.db_created_at,
    l.db_updated_at
    
FROM locations l
LEFT JOIN locations parent ON l.parent_id = parent.id
LEFT JOIN LATERAL (
    SELECT loc.id, loc.name
    FROM locations loc
    WHERE l.path_ids[1] = loc.id
    LIMIT 1
) building ON true;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON VIEW unified_items IS 'Unified view combining tasks and emails for dashboard display';
COMMENT ON VIEW unified_person_details IS 'Enriched unified person view with linked external system data';
COMMENT ON VIEW project_overview IS 'Teamwork project overview with ibhelm extensions and aggregated counts';
COMMENT ON VIEW file_details IS 'File details with all metadata and relationships';
COMMENT ON VIEW location_hierarchy IS 'Location hierarchy with parent/child relationships and counts';
