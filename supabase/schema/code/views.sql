-- =====================================
-- ALL VIEWS (IDEMPOTENT)
-- =====================================
-- Views use CREATE OR REPLACE
-- Materialized Views use DROP IF EXISTS + CREATE

-- =====================================
-- 1. MATERIALIZED VIEWS FOR UNIFIED_ITEMS PERFORMANCE
-- =====================================

DROP MATERIALIZED VIEW IF EXISTS mv_task_assignees_agg CASCADE;
CREATE MATERIALIZED VIEW mv_task_assignees_agg AS
SELECT ta.task_id,
    jsonb_agg(jsonb_build_object('id', u.id, 'first_name', u.first_name, 'last_name', u.last_name, 'email', u.email)) AS assignees
FROM teamwork.task_assignees ta
JOIN teamwork.users u ON ta.user_id = u.id
GROUP BY ta.task_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_task_assignees_task_id ON mv_task_assignees_agg(task_id);

DROP MATERIALIZED VIEW IF EXISTS mv_task_tags_agg CASCADE;
CREATE MATERIALIZED VIEW mv_task_tags_agg AS
SELECT tt.task_id,
    jsonb_agg(jsonb_build_object('id', tag.id, 'name', tag.name, 'color', tag.color)) AS tags
FROM teamwork.task_tags tt
JOIN teamwork.tags tag ON tt.tag_id = tag.id
GROUP BY tt.task_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_task_tags_task_id ON mv_task_tags_agg(task_id);

DROP MATERIALIZED VIEW IF EXISTS mv_message_recipients_agg CASCADE;
CREATE MATERIALIZED VIEW mv_message_recipients_agg AS
SELECT mr.message_id,
    jsonb_agg(jsonb_build_object('id', mr.id, 'recipient_type', mr.recipient_type,
        'contact', jsonb_build_object('id', rc.id, 'name', rc.name, 'email', rc.email))) AS recipients
FROM missive.message_recipients mr
LEFT JOIN missive.contacts rc ON mr.contact_id = rc.id
GROUP BY mr.message_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_message_recipients_msg_id ON mv_message_recipients_agg(message_id);

DROP MATERIALIZED VIEW IF EXISTS mv_message_attachments_agg CASCADE;
CREATE MATERIALIZED VIEW mv_message_attachments_agg AS
SELECT a.message_id,
    jsonb_agg(jsonb_build_object('id', a.id, 'filename', a.filename, 'extension', a.extension, 'size', a.size)) AS attachments,
    COUNT(*)::INTEGER AS attachment_count
FROM missive.attachments a
GROUP BY a.message_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_message_attachments_msg_id ON mv_message_attachments_agg(message_id);

DROP MATERIALIZED VIEW IF EXISTS mv_conversation_labels_agg CASCADE;
CREATE MATERIALIZED VIEW mv_conversation_labels_agg AS
SELECT cl.conversation_id,
    jsonb_agg(jsonb_build_object('id', sl.id, 'name', sl.name, 'color', NULL)) AS tags
FROM missive.conversation_labels cl
JOIN missive.shared_labels sl ON cl.label_id = sl.id
GROUP BY cl.conversation_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_conversation_labels_conv_id ON mv_conversation_labels_agg(conversation_id);

DROP MATERIALIZED VIEW IF EXISTS mv_conversation_comments_agg CASCADE;
CREATE MATERIALIZED VIEW mv_conversation_comments_agg AS
SELECT cc.conversation_id, string_agg(cc.body, ' ') AS comments_text
FROM missive.conversation_comments cc
WHERE cc.body IS NOT NULL AND cc.body != ''
GROUP BY cc.conversation_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_conversation_comments_conv_id ON mv_conversation_comments_agg(conversation_id);

DROP MATERIALIZED VIEW IF EXISTS mv_conversation_assignees_agg CASCADE;
CREATE MATERIALIZED VIEW mv_conversation_assignees_agg AS
SELECT ca.conversation_id,
    jsonb_agg(jsonb_build_object('id', u.id::TEXT, 'name', u.name, 'email', u.email)) AS assignees
FROM missive.conversation_assignees ca
JOIN missive.users u ON ca.user_id = u.id
GROUP BY ca.conversation_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_conversation_assignees_conv_id ON mv_conversation_assignees_agg(conversation_id);

-- =====================================
-- 2. UNIFIED ITEMS MATERIALIZED VIEW
-- =====================================

DROP MATERIALIZED VIEW IF EXISTS mv_unified_items CASCADE;
CREATE MATERIALIZED VIEW mv_unified_items AS

-- Tasks from Teamwork (wrapped for DISTINCT ON)
SELECT * FROM (
    SELECT DISTINCT ON (t.id)
        t.id::TEXT AS id, 'task'::TEXT AS type, t.name, t.description, t.status,
        p.name AS project, c.name AS customer, l.name AS location, l.search_text AS location_path,
        cg.name AS cost_group, cg.code::TEXT AS cost_group_code, t.due_date, t.created_at, t.updated_at,
        t.priority, t.progress, tl.name AS tasklist,
        tt.id AS task_type_id, tt.name AS task_type_name, tt.slug AS task_type_slug, tt.color AS task_type_color,
        taa.assignees AS assigned_to, tta.tags,
        NULL::TEXT AS body, NULL::TEXT AS preview,
        NULLIF(TRIM(CONCAT(creator_user.first_name, ' ', creator_user.last_name)), '') AS creator,
        NULL::TEXT AS conversation_subject, NULL::JSONB AS recipients, NULL::JSONB AS attachments,
        0 AS attachment_count, NULL::TEXT AS conversation_comments_text,
        NULL::TEXT AS craft_url, t.source_links->>'teamwork_url' AS teamwork_url, NULL::TEXT AS missive_url,
        NULL::TEXT AS storage_path, NULL::TEXT AS thumbnail_path,
        COALESCE(t.updated_at, t.created_at) AS sort_date,
        -- Pre-computed search text (excludes body for index size)
        CONCAT_WS(' ', t.name, t.description, p.name, c.name, tl.name, 
            NULLIF(TRIM(CONCAT(creator_user.first_name, ' ', creator_user.last_name)), '')) AS search_text,
        -- Pre-extracted assignee names for fast filtering
        ARRAY(SELECT COALESCE(elem->>'first_name', '') || ' ' || COALESCE(elem->>'last_name', '') 
              FROM jsonb_array_elements(taa.assignees) elem) AS assignee_names
    FROM teamwork.tasks t
    LEFT JOIN teamwork.projects p ON t.project_id = p.id
    LEFT JOIN teamwork.companies c ON p.company_id = c.id
    LEFT JOIN teamwork.tasklists tl ON t.tasklist_id = tl.id
    LEFT JOIN teamwork.users creator_user ON t.created_by_id = creator_user.id
    LEFT JOIN object_locations ol ON t.id = ol.tw_task_id
    LEFT JOIN locations l ON ol.location_id = l.id
    LEFT JOIN object_cost_groups ocg ON t.id = ocg.tw_task_id
    LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id
    LEFT JOIN task_extensions te ON t.id = te.tw_task_id
    LEFT JOIN task_types tt ON te.task_type_id = tt.id
    LEFT JOIN mv_task_assignees_agg taa ON t.id = taa.task_id
    LEFT JOIN mv_task_tags_agg tta ON t.id = tta.task_id
    WHERE t.deleted_at IS NULL
    ORDER BY t.id
) tasks

UNION ALL

-- Emails from Missive (wrapped for DISTINCT ON)
SELECT * FROM (
    SELECT DISTINCT ON (m.id)
        m.id::TEXT AS id, 'email'::TEXT AS type, m.subject AS name,
        COALESCE(m.preview, LEFT(m.body, 200)) AS description, ''::VARCHAR AS status,
        COALESCE(twp.name, '') AS project, ''::TEXT AS customer, l.name AS location, l.search_text AS location_path,
        cg.name AS cost_group, cg.code::TEXT AS cost_group_code, NULL::TIMESTAMP AS due_date, m.created_at, m.updated_at,
        ''::VARCHAR AS priority, NULL::INTEGER AS progress, ''::TEXT AS tasklist,
        NULL::UUID AS task_type_id, NULL::TEXT AS task_type_name, NULL::TEXT AS task_type_slug, NULL::VARCHAR(50) AS task_type_color,
        caa.assignees AS assigned_to, cla.tags,
        m.body_plain_text AS body, m.preview,
        from_contact.name AS creator,
        conv.subject AS conversation_subject, mra.recipients, maa.attachments,
        COALESCE(maa.attachment_count, 0) AS attachment_count, cca.comments_text AS conversation_comments_text,
        NULL::TEXT AS craft_url, NULL::TEXT AS teamwork_url, conv.app_url AS missive_url,
        NULL::TEXT AS storage_path, NULL::TEXT AS thumbnail_path,
        COALESCE(m.delivered_at, m.updated_at, m.created_at) AS sort_date,
        -- Pre-computed search text (excludes body for index size)
        CONCAT_WS(' ', m.subject, m.preview, twp.name, from_contact.name, conv.subject, cca.comments_text) AS search_text,
        -- Pre-extracted assignee names for fast filtering
        ARRAY(SELECT COALESCE(elem->>'name', '') FROM jsonb_array_elements(caa.assignees) elem) AS assignee_names
    FROM missive.messages m
    LEFT JOIN missive.conversations conv ON m.conversation_id = conv.id
    LEFT JOIN missive.contacts from_contact ON m.from_contact_id = from_contact.id
    LEFT JOIN object_locations ol ON conv.id = ol.m_conversation_id
    LEFT JOIN locations l ON ol.location_id = l.id
    LEFT JOIN object_cost_groups ocg ON conv.id = ocg.m_conversation_id
    LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id
    LEFT JOIN project_conversations pc ON conv.id = pc.m_conversation_id
    LEFT JOIN teamwork.projects twp ON pc.tw_project_id = twp.id
    LEFT JOIN mv_message_recipients_agg mra ON m.id = mra.message_id
    LEFT JOIN mv_message_attachments_agg maa ON m.id = maa.message_id
    LEFT JOIN mv_conversation_labels_agg cla ON m.conversation_id = cla.conversation_id
    LEFT JOIN mv_conversation_comments_agg cca ON m.conversation_id = cca.conversation_id
    LEFT JOIN mv_conversation_assignees_agg caa ON m.conversation_id = caa.conversation_id
    ORDER BY m.id
) emails

UNION ALL

-- Craft Documents (no duplicates possible)
SELECT 
    cd.id::TEXT AS id, 'craft'::TEXT AS type, cd.title AS name, NULL::TEXT AS description, ''::VARCHAR AS status,
    ''::TEXT AS project, ''::TEXT AS customer, NULL::TEXT AS location, NULL::TEXT AS location_path,
    NULL::TEXT AS cost_group, NULL::TEXT AS cost_group_code, NULL::TIMESTAMP AS due_date,
    cd.craft_created_at AS created_at, cd.craft_last_modified_at AS updated_at,
    ''::VARCHAR AS priority, NULL::INTEGER AS progress, ''::TEXT AS tasklist,
    NULL::UUID AS task_type_id, NULL::TEXT AS task_type_name, NULL::TEXT AS task_type_slug, NULL::VARCHAR(50) AS task_type_color,
    NULL::JSONB AS assigned_to, NULL::JSONB AS tags,
    cd.markdown_content AS body, NULL::TEXT AS preview,
    NULL::TEXT AS creator, NULL::TEXT AS conversation_subject,
    NULL::JSONB AS recipients, NULL::JSONB AS attachments, 0 AS attachment_count, NULL::TEXT AS conversation_comments_text,
    'craftdocs://open?blockId=' || cd.id AS craft_url, NULL::TEXT AS teamwork_url, NULL::TEXT AS missive_url,
    NULL::TEXT AS storage_path, NULL::TEXT AS thumbnail_path,
    COALESCE(cd.craft_last_modified_at, cd.db_updated_at, cd.db_created_at) AS sort_date,
    -- Pre-computed search text
    cd.title AS search_text,
    -- No assignees for craft docs
    ARRAY[]::TEXT[] AS assignee_names
FROM craft_documents cd
WHERE cd.is_deleted = FALSE

UNION ALL

-- Files (wrapped for DISTINCT ON)
SELECT * FROM (
    SELECT DISTINCT ON (f.id)
        f.id::TEXT AS id, 'file'::TEXT AS type, f.filename AS name, f.folder_path AS description, ''::VARCHAR AS status,
        COALESCE(twp.name, '') AS project, ''::TEXT AS customer, l.name AS location, l.search_text AS location_path,
        cg.name AS cost_group, cg.code::TEXT AS cost_group_code, NULL::TIMESTAMP AS due_date,
        f.file_created_at AS created_at, f.file_modified_at AS updated_at,
        ''::VARCHAR AS priority, NULL::INTEGER AS progress, ''::TEXT AS tasklist,
        NULL::UUID AS task_type_id, NULL::TEXT AS task_type_name, NULL::TEXT AS task_type_slug, NULL::VARCHAR(50) AS task_type_color,
        NULL::JSONB AS assigned_to, NULL::JSONB AS tags,
        f.extracted_text AS body, NULL::TEXT AS preview,
        f.file_created_by AS creator, NULL::TEXT AS conversation_subject,
        NULL::JSONB AS recipients, NULL::JSONB AS attachments, 0 AS attachment_count, NULL::TEXT AS conversation_comments_text,
        NULL::TEXT AS craft_url, NULL::TEXT AS teamwork_url, NULL::TEXT AS missive_url,
        f.storage_path, f.thumbnail_path,
        COALESCE(f.file_modified_at, f.db_updated_at, f.db_created_at) AS sort_date,
        -- Pre-computed search text
        CONCAT_WS(' ', f.filename, f.folder_path, twp.name, f.file_created_by) AS search_text,
        -- No assignees for files
        ARRAY[]::TEXT[] AS assignee_names
    FROM files f
    LEFT JOIN object_locations ol ON f.id = ol.file_id
    LEFT JOIN locations l ON ol.location_id = l.id
    LEFT JOIN object_cost_groups ocg ON f.id = ocg.file_id
    LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id
    LEFT JOIN project_files pf ON f.id = pf.file_id
    LEFT JOIN teamwork.projects twp ON pf.tw_project_id = twp.id
    ORDER BY f.id
) files;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_unified_items_id_type ON mv_unified_items(id, type);

-- Consolidated trigram index for text search (single index instead of 9 separate ones)
CREATE INDEX IF NOT EXISTS idx_mv_ui_search_text_trgm ON mv_unified_items USING gin (search_text gin_trgm_ops);
-- Body search still needs its own index (not in search_text due to size)
CREATE INDEX IF NOT EXISTS idx_mv_ui_body_trgm ON mv_unified_items USING gin (body gin_trgm_ops);
-- Assignee names array for fast filtering
CREATE INDEX IF NOT EXISTS idx_mv_ui_assignee_names ON mv_unified_items USING gin (assignee_names);

-- =====================================
-- 3. UNIFIED PERSON DETAILS VIEW
-- =====================================

CREATE OR REPLACE VIEW unified_person_details AS
SELECT 
    up.id, up.display_name, up.primary_email, up.preferred_contact_method, up.is_internal, up.is_company, up.notes,
    twc.id AS tw_company_id, twc.name AS tw_company_name, twc.website AS tw_company_website,
    twu.id AS tw_user_id, twu.first_name AS tw_user_first_name, twu.last_name AS tw_user_last_name, twu.email AS tw_user_email,
    mc.id AS m_contact_id, mc.email AS m_contact_email, mc.name AS m_contact_name,
    up.db_created_at, up.db_updated_at
FROM unified_persons up
LEFT JOIN unified_person_links upl_company ON up.id = upl_company.unified_person_id AND upl_company.tw_company_id IS NOT NULL
LEFT JOIN teamwork.companies twc ON upl_company.tw_company_id = twc.id
LEFT JOIN unified_person_links upl_user ON up.id = upl_user.unified_person_id AND upl_user.tw_user_id IS NOT NULL
LEFT JOIN teamwork.users twu ON upl_user.tw_user_id = twu.id
LEFT JOIN unified_person_links upl_contact ON up.id = upl_contact.unified_person_id AND upl_contact.m_contact_id IS NOT NULL
LEFT JOIN missive.contacts mc ON upl_contact.m_contact_id = mc.id;

-- =====================================
-- 4. PROJECT OVERVIEW VIEW
-- =====================================

CREATE OR REPLACE VIEW project_overview AS
SELECT 
    twp.id, twp.name, twp.description, twp.status, twp.start_date, twp.end_date,
    twc.name AS company_name,
    client.display_name AS client_name, client.primary_email AS client_email,
    pe.nas_folder_path, pe.internal_notes,
    dl.name AS default_location_name, dl.search_text AS default_location_path,
    dcg.name AS default_cost_group_name, dcg.code::TEXT AS default_cost_group_code,
    (SELECT COUNT(*) FROM project_files pf WHERE pf.tw_project_id = twp.id) AS file_count,
    (SELECT COUNT(*) FROM project_contractors pc WHERE pc.tw_project_id = twp.id) AS contractor_count,
    (SELECT COUNT(*) FROM project_conversations pcon WHERE pcon.tw_project_id = twp.id) AS conversation_count,
    (SELECT COUNT(*) FROM teamwork.tasks t WHERE t.project_id = twp.id AND t.deleted_at IS NULL) AS task_count,
    (SELECT COUNT(*) FROM teamwork.tasks t WHERE t.project_id = twp.id AND t.deleted_at IS NULL AND t.status = 'completed') AS completed_task_count,
    twp.created_at, twp.updated_at,
    pe.db_created_at AS extension_created_at, pe.db_updated_at AS extension_updated_at
FROM teamwork.projects twp
LEFT JOIN teamwork.companies twc ON twp.company_id = twc.id
LEFT JOIN project_extensions pe ON twp.id = pe.tw_project_id
LEFT JOIN unified_persons client ON pe.client_person_id = client.id
LEFT JOIN locations dl ON pe.default_location_id = dl.id
LEFT JOIN cost_groups dcg ON pe.default_cost_group_id = dcg.id;

-- =====================================
-- 5. FILE DETAILS VIEW
-- =====================================

CREATE OR REPLACE VIEW file_details AS
SELECT 
    f.id, f.filename, f.folder_path, f.content_hash,
    dt.name AS document_type, dt.slug AS document_type_slug,
    f.thumbnail_path, f.thumbnail_generated_at, f.thumbnail_generated_at IS NOT NULL AS has_thumbnail,
    f.extracted_text IS NOT NULL AND LENGTH(f.extracted_text) > 0 AS has_extracted_text,
    ma.filename AS source_attachment_filename, ma.size AS source_attachment_size,
    (SELECT jsonb_agg(jsonb_build_object('id', twp.id, 'name', twp.name))
     FROM project_files pf JOIN teamwork.projects twp ON pf.tw_project_id = twp.id WHERE pf.file_id = f.id) AS projects,
    (SELECT jsonb_agg(jsonb_build_object('id', loc.id, 'name', loc.name, 'type', loc.type, 'path', loc.search_text))
     FROM object_locations ol JOIN locations loc ON ol.location_id = loc.id WHERE ol.file_id = f.id) AS locations,
    (SELECT jsonb_agg(jsonb_build_object('id', cg.id, 'code', cg.code::TEXT, 'name', cg.name))
     FROM object_cost_groups ocg JOIN cost_groups cg ON ocg.cost_group_id = cg.id WHERE ocg.file_id = f.id) AS cost_groups,
    f.file_created_at, f.file_modified_at, f.db_created_at, f.db_updated_at
FROM files f
LEFT JOIN document_types dt ON f.document_type_id = dt.id
LEFT JOIN missive.attachments ma ON f.source_missive_attachment_id = ma.id;

-- =====================================
-- 6. LOCATION HIERARCHY VIEW
-- =====================================

CREATE OR REPLACE VIEW location_hierarchy AS
SELECT 
    l.id, l.name, l.type, l.depth, l.path, l.search_text AS full_path,
    parent.id AS parent_id, parent.name AS parent_name, parent.type AS parent_type,
    building.id AS building_id, building.name AS building_name,
    (SELECT COUNT(*) FROM locations child WHERE child.parent_id = l.id) AS child_count,
    (SELECT COUNT(*) FROM object_locations ol WHERE ol.location_id = l.id) AS related_object_count,
    l.db_created_at, l.db_updated_at
FROM locations l
LEFT JOIN locations parent ON l.parent_id = parent.id
LEFT JOIN LATERAL (SELECT loc.id, loc.name FROM locations loc WHERE l.path_ids[1] = loc.id LIMIT 1) building ON true;

-- =====================================
-- 7. CONNECTOR MONITORING VIEWS
-- =====================================

CREATE OR REPLACE VIEW teamworkmissiveconnector.queue_health AS
SELECT 
    source,
    COUNT(*) FILTER (WHERE status = 'pending') AS pending_count,
    COUNT(*) FILTER (WHERE status = 'processing') AS processing_count,
    COUNT(*) FILTER (WHERE status = 'failed') AS failed_count,
    COUNT(*) FILTER (WHERE status = 'dead_letter') AS dead_letter_count,
    AVG(processing_time_ms) FILTER (WHERE status = 'completed' AND processing_time_ms IS NOT NULL) AS avg_processing_time_ms,
    MAX(created_at) FILTER (WHERE status = 'pending') AS oldest_pending_item,
    COUNT(*) FILTER (WHERE status = 'processing' AND processing_started_at < NOW() - INTERVAL '30 minutes') AS stuck_items
FROM teamworkmissiveconnector.queue_items
GROUP BY source;

CREATE OR REPLACE VIEW teamworkmissiveconnector.recent_errors AS
SELECT id, source, event_type, external_id, error_message, retry_count, created_at, updated_at
FROM teamworkmissiveconnector.queue_items
WHERE status IN ('failed', 'dead_letter') AND updated_at > NOW() - INTERVAL '24 hours'
ORDER BY updated_at DESC LIMIT 100;

-- =====================================
-- GRANTS
-- =====================================

GRANT SELECT ON mv_task_assignees_agg TO authenticated;
GRANT SELECT ON mv_task_tags_agg TO authenticated;
GRANT SELECT ON mv_message_recipients_agg TO authenticated;
GRANT SELECT ON mv_message_attachments_agg TO authenticated;
GRANT SELECT ON mv_conversation_labels_agg TO authenticated;
GRANT SELECT ON mv_conversation_comments_agg TO authenticated;
GRANT SELECT ON mv_conversation_assignees_agg TO authenticated;
GRANT SELECT ON mv_unified_items TO authenticated;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON MATERIALIZED VIEW mv_unified_items IS 'Unified materialized view combining tasks, emails, and Craft documents for dashboard display';
COMMENT ON VIEW unified_person_details IS 'Enriched unified person view with linked external system data';
COMMENT ON VIEW project_overview IS 'Teamwork project overview with ibhelm extensions and aggregated counts';
COMMENT ON VIEW file_details IS 'File details with all metadata and relationships';
COMMENT ON VIEW location_hierarchy IS 'Location hierarchy with parent/child relationships and counts';
COMMENT ON VIEW teamworkmissiveconnector.queue_health IS 'Real-time queue health metrics by source';
COMMENT ON VIEW teamworkmissiveconnector.recent_errors IS 'Recent failed queue items for debugging';
COMMENT ON MATERIALIZED VIEW mv_task_assignees_agg IS 'Pre-aggregated task assignees for unified_items performance';
COMMENT ON MATERIALIZED VIEW mv_task_tags_agg IS 'Pre-aggregated task tags for unified_items performance';
COMMENT ON MATERIALIZED VIEW mv_message_recipients_agg IS 'Pre-aggregated message recipients for unified_items performance';
COMMENT ON MATERIALIZED VIEW mv_message_attachments_agg IS 'Pre-aggregated message attachments for unified_items performance';
COMMENT ON MATERIALIZED VIEW mv_conversation_labels_agg IS 'Pre-aggregated conversation labels for unified_items performance';
COMMENT ON MATERIALIZED VIEW mv_conversation_comments_agg IS 'Pre-aggregated conversation comments for unified_items search';
COMMENT ON MATERIALIZED VIEW mv_conversation_assignees_agg IS 'Pre-aggregated conversation assignees for unified_items performance';

-- =====================================
-- REGISTER MVS FOR CRON REFRESH
-- =====================================

INSERT INTO mv_refresh_status (view_name, needs_refresh, refresh_interval_minutes) VALUES
    ('mv_task_assignees_agg', FALSE, 5),
    ('mv_task_tags_agg', FALSE, 5),
    ('mv_message_recipients_agg', FALSE, 5),
    ('mv_message_attachments_agg', FALSE, 5),
    ('mv_conversation_labels_agg', FALSE, 5),
    ('mv_conversation_comments_agg', FALSE, 1),
    ('mv_conversation_assignees_agg', FALSE, 5),
    ('mv_unified_items', FALSE, 1)
ON CONFLICT (view_name) DO NOTHING;

