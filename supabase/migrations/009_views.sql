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
    
    -- Aggregate assignees
    (
        SELECT json_agg(json_build_object(
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
        SELECT json_agg(json_build_object(
            'id', tag.id, 
            'name', tag.name, 
            'color', tag.color
        ))
        FROM teamwork.task_tags tt
        JOIN teamwork.tags tag ON tt.tag_id = tag.id
        WHERE tt.task_id = t.id
    ) AS tags,
    
    -- Email-specific fields (null for tasks)
    NULL AS body,
    NULL AS preview,
    NULL AS from_name,
    NULL AS from_email,
    NULL AS conversation_subject,
    NULL AS recipients,
    NULL AS attachments,
    0 AS attachment_count,
    
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
WHERE t.deleted_at IS NULL

UNION ALL

-- Emails from Missive
SELECT 
    m.id::TEXT AS id,
    'email' AS type,
    m.subject AS name,
    COALESCE(m.preview, LEFT(m.body, 200)) AS description,
    '' AS status,
    '' AS project,
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
    
    -- Task-specific fields (null for emails)
    NULL AS assignees,
    NULL AS tags,
    
    -- Email-specific fields
    m.body,
    m.preview,
    from_contact.name AS from_name,
    from_contact.email AS from_email,
    conv.subject AS conversation_subject,
    
    -- Aggregate recipients
    (
        SELECT json_agg(json_build_object(
            'id', mr.id, 
            'recipient_type', mr.recipient_type, 
            'contact', json_build_object(
                'id', c.id, 
                'name', c.name, 
                'email', c.email
            )
        ))
        FROM missive.message_recipients mr
        LEFT JOIN missive.contacts c ON mr.contact_id = c.id
        WHERE mr.message_id = m.id
    ) AS recipients,
    
    -- Aggregate attachments
    (
        SELECT json_agg(json_build_object(
            'id', a.id, 
            'filename', a.filename, 
            'extension', a.extension, 
            'size', a.size
        ))
        FROM missive.attachments a
        WHERE a.message_id = m.id
    ) AS attachments,
    
    (
        SELECT COUNT(*)
        FROM missive.attachments a
        WHERE a.message_id = m.id
    ) AS attachment_count,
    
    -- Sort key
    COALESCE(m.delivered_at, m.updated_at, m.created_at) AS sort_date
    
FROM missive.messages m
LEFT JOIN missive.conversations conv ON m.conversation_id = conv.id
LEFT JOIN missive.contacts from_contact ON m.from_contact_id = from_contact.id
LEFT JOIN object_locations ol ON m.id = ol.m_message_id
LEFT JOIN locations l ON ol.location_id = l.id
LEFT JOIN object_cost_groups ocg ON m.id = ocg.m_message_id
LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id;

-- =====================================
-- 2. PARTY DETAILS VIEW
-- =====================================
-- Enriched party view with external system info

CREATE OR REPLACE VIEW party_details AS
SELECT 
    p.id,
    p.type,
    p.name_primary,
    p.name_secondary,
    p.display_name,
    p.job_title,
    p.email,
    p.phone,
    p.is_internal,
    
    -- Parent company info (for persons)
    parent.display_name AS parent_company_name,
    parent.email AS parent_company_email,
    
    -- Teamwork company data
    twc.name AS tw_company_name,
    twc.website AS tw_company_website,
    
    -- Teamwork user data
    twu.first_name AS tw_user_first_name,
    twu.last_name AS tw_user_last_name,
    twu.email AS tw_user_email,
    
    -- Missive contact data
    mc.email AS m_contact_email,
    
    p.db_created_at,
    p.db_updated_at
    
FROM parties p
LEFT JOIN parties parent ON p.parent_party_id = parent.id
LEFT JOIN teamwork.companies twc ON p.tw_company_id = twc.id
LEFT JOIN teamwork.users twu ON p.tw_user_id = twu.id
LEFT JOIN missive.contacts mc ON p.m_contact_id = mc.id;

-- =====================================
-- 3. PROJECT OVERVIEW VIEW
-- =====================================
-- Project with aggregated data

CREATE OR REPLACE VIEW project_overview AS
SELECT 
    p.id,
    p.name,
    p.project_number,
    p.description,
    p.status,
    p.start_date,
    p.end_date,
    
    -- Client info
    client.display_name AS client_name,
    client.email AS client_email,
    client.phone AS client_phone,
    
    -- Teamwork project data
    twp.name AS tw_project_name,
    twp.status AS tw_project_status,
    twp.is_starred AS tw_project_starred,
    
    -- Aggregated counts
    (SELECT COUNT(*) FROM project_files pf WHERE pf.project_id = p.id) AS file_count,
    (SELECT COUNT(*) FROM project_contractors pc WHERE pc.project_id = p.id) AS contractor_count,
    (SELECT COUNT(*) FROM teamwork.tasks t WHERE t.project_id = twp.id AND t.deleted_at IS NULL) AS task_count,
    (SELECT COUNT(*) FROM teamwork.tasks t WHERE t.project_id = twp.id AND t.deleted_at IS NULL AND t.status = 'completed') AS completed_task_count,
    
    p.created_at,
    p.db_created_at,
    p.db_updated_at
    
FROM projects p
LEFT JOIN parties client ON p.client_party_id = client.id
LEFT JOIN teamwork.projects twp ON p.tw_project_id = twp.id;

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
        SELECT json_agg(json_build_object(
            'id', proj.id,
            'name', proj.name,
            'project_number', proj.project_number
        ))
        FROM project_files pf
        JOIN projects proj ON pf.project_id = proj.id
        WHERE pf.file_id = f.id
    ) AS projects,
    
    -- Locations (aggregated)
    (
        SELECT json_agg(json_build_object(
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
        SELECT json_agg(json_build_object(
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
    l.search_text AS full_path,
    
    -- Parent info
    parent.id AS parent_id,
    parent.name AS parent_name,
    parent.type AS parent_type,
    
    -- Owner info
    owner.display_name AS owner_name,
    owner.type AS owner_type,
    
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
LEFT JOIN parties owner ON l.owner_party_id = owner.id
LEFT JOIN LATERAL (
    SELECT id, name
    FROM locations
    WHERE l.path_ids[1] = id
    LIMIT 1
) building ON true;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON VIEW unified_items IS 'Unified view combining tasks and emails for dashboard display';
COMMENT ON VIEW party_details IS 'Enriched party view with external system references';
COMMENT ON VIEW project_overview IS 'Project overview with aggregated counts and related data';
COMMENT ON VIEW file_details IS 'File details with all metadata and relationships';
COMMENT ON VIEW location_hierarchy IS 'Location hierarchy with parent/child relationships and counts';

