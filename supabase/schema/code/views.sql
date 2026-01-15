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

DROP MATERIALIZED VIEW IF EXISTS mv_task_timelogs_agg CASCADE;
CREATE MATERIALIZED VIEW mv_task_timelogs_agg AS
SELECT tl.task_id,
    SUM(tl.minutes)::INTEGER AS logged_minutes,
    SUM(CASE WHEN tl.is_billable = TRUE THEN tl.minutes ELSE 0 END)::INTEGER AS billable_minutes
FROM teamwork.timelogs tl
WHERE tl.deleted = FALSE AND tl.task_id IS NOT NULL
GROUP BY tl.task_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_task_timelogs_task_id ON mv_task_timelogs_agg(task_id);

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
        NULLIF(TRIM(CONCAT_WS(' ', 
            NULLIF(TRIM(CONCAT(creator_user.first_name, ' ', creator_user.last_name)), ''),
            CASE WHEN creator_user.email IS NOT NULL THEN CONCAT('<', creator_user.email, '>') END
        )), '') AS creator,
        NULL::TEXT AS conversation_subject, NULL::JSONB AS recipients, NULL::JSONB AS attachments,
        0 AS attachment_count, NULL::TEXT AS conversation_comments_text,
        NULL::TEXT AS craft_url, t.source_links->>'teamwork_url' AS teamwork_url, NULL::TEXT AS missive_url,
        NULL::TEXT AS storage_path, NULL::TEXT AS thumbnail_path,
        NULL::TEXT AS file_extension,
        t.accumulated_estimated_minutes,
        ttla.logged_minutes,
        ttla.billable_minutes,
        -- Pre-computed search text (includes tags + assignees for single-index search)
        CONCAT_WS(' ', t.name, t.description, p.name, c.name, tl.name, 
            NULLIF(TRIM(CONCAT(creator_user.first_name, ' ', creator_user.last_name)), ''), creator_user.email,
            (SELECT string_agg(elem->>'name', ' ') FROM jsonb_array_elements(tta.tags) elem),
            (SELECT string_agg(COALESCE(elem->>'first_name', '') || ' ' || COALESCE(elem->>'last_name', ''), ' ') FROM jsonb_array_elements(taa.assignees) elem)
        ) AS search_text,
        -- Flattened assignee names for fast trigram search (TEXT instead of ARRAY)
        (SELECT string_agg(COALESCE(elem->>'first_name', '') || ' ' || COALESCE(elem->>'last_name', ''), ' ')
         FROM jsonb_array_elements(taa.assignees) elem) AS assignee_search_text,
        -- Flattened tag names for fast trigram search (P0 optimization)
        (SELECT string_agg(elem->>'name', ' ') FROM jsonb_array_elements(tta.tags) elem) AS tag_names_text,
        -- Pre-computed location IDs for fast array overlap filter (P1 optimization)
        (SELECT array_agg(ol2.location_id) FROM object_locations ol2 WHERE ol2.tw_task_id = t.id) AS location_ids,
        -- RLS: No email restriction for tasks
        NULL::TEXT[] AS involved_emails
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
    LEFT JOIN mv_task_timelogs_agg ttla ON t.id = ttla.task_id
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
        cg.name AS cost_group, cg.code::TEXT AS cost_group_code, NULL::TIMESTAMP AS due_date,
        m.delivered_at AS created_at, COALESCE(m.updated_at, m.delivered_at) AS updated_at,
        ''::VARCHAR AS priority, NULL::INTEGER AS progress, ''::TEXT AS tasklist,
        NULL::UUID AS task_type_id, NULL::TEXT AS task_type_name, NULL::TEXT AS task_type_slug, NULL::VARCHAR(50) AS task_type_color,
        caa.assignees AS assigned_to, cla.tags,
        m.body_plain_text AS body, m.preview,
        NULLIF(TRIM(CONCAT_WS(' ', 
            NULLIF(TRIM(from_contact.name), ''),
            CONCAT('<', from_contact.email, '>')
        )), '') AS creator,
        conv.subject AS conversation_subject, mra.recipients, maa.attachments,
        COALESCE(maa.attachment_count, 0) AS attachment_count, cca.comments_text AS conversation_comments_text,
        NULL::TEXT AS craft_url, NULL::TEXT AS teamwork_url, conv.app_url AS missive_url,
        NULL::TEXT AS storage_path, NULL::TEXT AS thumbnail_path,
        -- File extensions from all attachments (comma-separated, deduplicated)
        (SELECT string_agg(DISTINCT LOWER(elem->>'extension'), ', ') FROM jsonb_array_elements(maa.attachments) elem WHERE elem->>'extension' IS NOT NULL) AS file_extension,
        NULL::INTEGER AS accumulated_estimated_minutes,
        NULL::INTEGER AS logged_minutes,
        NULL::INTEGER AS billable_minutes,
        -- Pre-computed search text (includes body, recipients, attachments, labels for single-index search)
        CONCAT_WS(' ', m.subject, m.preview, m.body_plain_text, twp.name, from_contact.name, from_contact.email, conv.subject, cca.comments_text,
            (SELECT string_agg(CONCAT_WS(' ', elem->'contact'->>'name', elem->'contact'->>'email'), ' ') FROM jsonb_array_elements(mra.recipients) elem),
            (SELECT string_agg(elem->>'filename', ' ') FROM jsonb_array_elements(maa.attachments) elem),
            (SELECT string_agg(elem->>'name', ' ') FROM jsonb_array_elements(cla.tags) elem),
            (SELECT string_agg(COALESCE(elem->>'name', ''), ' ') FROM jsonb_array_elements(caa.assignees) elem)
        ) AS search_text,
        -- Flattened assignee names for fast trigram search
        (SELECT string_agg(COALESCE(elem->>'name', ''), ' ') FROM jsonb_array_elements(caa.assignees) elem) AS assignee_search_text,
        -- Flattened tag names for fast trigram search (P0 optimization)
        (SELECT string_agg(elem->>'name', ' ') FROM jsonb_array_elements(cla.tags) elem) AS tag_names_text,
        -- Pre-computed location IDs for fast array overlap filter (P1 optimization)
        (SELECT array_agg(ol2.location_id) FROM object_locations ol2 WHERE ol2.m_conversation_id = conv.id) AS location_ids,
        -- RLS: All involved email addresses (sender + recipients) for email visibility
        (SELECT array_agg(DISTINCT e) FROM (
            SELECT from_contact.email AS e
            UNION ALL
            SELECT (elem->'contact'->>'email')::TEXT FROM jsonb_array_elements(mra.recipients) elem
        ) sub WHERE e IS NOT NULL) AS involved_emails
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

-- Craft Documents (wrapped for DISTINCT ON due to multiple projects)
SELECT * FROM (
    SELECT DISTINCT ON (cd.id)
        cd.id::TEXT AS id, 'craft'::TEXT AS type, cd.title AS name, cd.folder_path AS description, ''::VARCHAR AS status,
        COALESCE(twp.name, '') AS project, ''::TEXT AS customer, NULL::TEXT AS location, NULL::TEXT AS location_path,
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
        NULL::TEXT AS file_extension,
        NULL::INTEGER AS accumulated_estimated_minutes,
        NULL::INTEGER AS logged_minutes,
        NULL::INTEGER AS billable_minutes,
        -- Pre-computed search text (includes body for single-index search)
        CONCAT_WS(' ', cd.title, cd.folder_path, twp.name, cd.markdown_content) AS search_text,
        -- No assignees for craft docs
        NULL::TEXT AS assignee_search_text,
        -- No tags for craft docs
        NULL::TEXT AS tag_names_text,
        -- No locations for craft docs
        NULL::UUID[] AS location_ids,
        -- RLS: No email restriction for craft docs
        NULL::TEXT[] AS involved_emails
    FROM craft_documents cd
    LEFT JOIN project_craft_documents pcd ON cd.id = pcd.craft_document_id
    LEFT JOIN teamwork.projects twp ON pcd.tw_project_id = twp.id
    WHERE cd.is_deleted = FALSE
    ORDER BY cd.id
) craft_docs

UNION ALL

-- Files (wrapped for DISTINCT ON)
SELECT * FROM (
    SELECT DISTINCT ON (f.id)
        f.id::TEXT AS id, 'file'::TEXT AS type, f.full_path AS name, f.full_path AS description, ''::VARCHAR AS status,
        COALESCE(twp.name, '') AS project, ''::TEXT AS customer, l.name AS location, l.search_text AS location_path,
        cg.name AS cost_group, cg.code::TEXT AS cost_group_code, NULL::TIMESTAMP AS due_date,
        f.fs_mtime AS created_at, f.fs_ctime AS updated_at,
        ''::VARCHAR AS priority, NULL::INTEGER AS progress, ''::TEXT AS tasklist,
        NULL::UUID AS task_type_id, NULL::TEXT AS task_type_name, NULL::TEXT AS task_type_slug, NULL::VARCHAR(50) AS task_type_color,
        NULL::JSONB AS assigned_to, NULL::JSONB AS tags,
        fc.extracted_text AS body, NULL::TEXT AS preview,
        f.file_created_by AS creator, NULL::TEXT AS conversation_subject,
        NULL::JSONB AS recipients, NULL::JSONB AS attachments, 0 AS attachment_count, NULL::TEXT AS conversation_comments_text,
        NULL::TEXT AS craft_url, NULL::TEXT AS teamwork_url, NULL::TEXT AS missive_url,
        fc.storage_path, fc.thumbnail_path,
        -- File extension: part after last dot, empty if no dot
        CASE WHEN f.full_path LIKE '%.%' THEN LOWER(SUBSTRING(f.full_path FROM '\.([^.]+)$')) ELSE NULL END AS file_extension,
        NULL::INTEGER AS accumulated_estimated_minutes,
        NULL::INTEGER AS logged_minutes,
        NULL::INTEGER AS billable_minutes,
        -- Pre-computed search text (includes body for single-index search)
        CONCAT_WS(' ', f.full_path, twp.name, f.file_created_by, fc.extracted_text) AS search_text,
        -- No assignees for files
        NULL::TEXT AS assignee_search_text,
        -- No tags for files
        NULL::TEXT AS tag_names_text,
        -- Pre-computed location IDs for fast array overlap filter (P1 optimization)
        (SELECT array_agg(ol2.location_id) FROM object_locations ol2 WHERE ol2.file_id = f.id) AS location_ids,
        -- RLS: No email restriction for files
        NULL::TEXT[] AS involved_emails
    FROM files f
    JOIN file_contents fc ON f.content_hash = fc.content_hash
    LEFT JOIN object_locations ol ON f.id = ol.file_id
    LEFT JOIN locations l ON ol.location_id = l.id
    LEFT JOIN object_cost_groups ocg ON f.id = ocg.file_id
    LEFT JOIN cost_groups cg ON ocg.cost_group_id = cg.id
    LEFT JOIN teamwork.projects twp ON f.project_id = twp.id
    ORDER BY f.id
) files;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_unified_items_id_type ON mv_unified_items(id, type);

-- Trigram indexes for fast ILIKE searches
-- Combined search text (includes body, tags, assignees, recipients, attachments - single index for all text search)
CREATE INDEX IF NOT EXISTS idx_mv_ui_search_text_trgm ON mv_unified_items USING gin (search_text gin_trgm_ops);
-- Dedicated column trigram indexes for specific filters (faster than combined)
CREATE INDEX IF NOT EXISTS idx_mv_ui_project_trgm ON mv_unified_items USING gin (project gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_mv_ui_customer_trgm ON mv_unified_items USING gin (customer gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_mv_ui_name_trgm ON mv_unified_items USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_mv_ui_creator_trgm ON mv_unified_items USING gin (creator gin_trgm_ops);
-- Flattened assignee text for fast trigram search (replaces slow array unnest)
CREATE INDEX IF NOT EXISTS idx_mv_ui_assignee_trgm ON mv_unified_items USING gin (assignee_search_text gin_trgm_ops);
-- Flattened tag names for fast trigram search (P0 optimization - replaces jsonb_array_elements)
CREATE INDEX IF NOT EXISTS idx_mv_ui_tags_trgm ON mv_unified_items USING gin (tag_names_text gin_trgm_ops);
-- Pre-computed location IDs for fast array overlap filter (P1 optimization - replaces 3x EXISTS subqueries)
CREATE INDEX IF NOT EXISTS idx_mv_ui_location_ids ON mv_unified_items USING GIN (location_ids);
-- RLS: Involved email addresses for fast array overlap in email visibility policy
CREATE INDEX IF NOT EXISTS idx_mv_ui_involved_emails ON mv_unified_items USING GIN (involved_emails);

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
    (SELECT COUNT(*) FROM files f WHERE f.project_id = twp.id AND f.deleted_at IS NULL) AS file_count,
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
    f.id, f.full_path, f.content_hash,
    dt.name AS document_type, dt.slug AS document_type_slug,
    fc.thumbnail_path, fc.thumbnail_generated_at, fc.thumbnail_generated_at IS NOT NULL AS has_thumbnail,
    fc.extracted_text IS NOT NULL AND LENGTH(fc.extracted_text) > 0 AS has_extracted_text,
    ma.filename AS source_attachment_filename, ma.size AS source_attachment_size,
    (SELECT jsonb_build_object('id', twp.id, 'name', twp.name)
     FROM teamwork.projects twp WHERE twp.id = f.project_id) AS project,
    (SELECT jsonb_agg(jsonb_build_object('id', loc.id, 'name', loc.name, 'type', loc.type, 'path', loc.search_text))
     FROM object_locations ol JOIN locations loc ON ol.location_id = loc.id WHERE ol.file_id = f.id) AS locations,
    (SELECT jsonb_agg(jsonb_build_object('id', cg.id, 'code', cg.code::TEXT, 'name', cg.name))
     FROM object_cost_groups ocg JOIN cost_groups cg ON ocg.cost_group_id = cg.id WHERE ocg.file_id = f.id) AS cost_groups,
    f.fs_mtime, f.fs_ctime, f.db_created_at, f.db_updated_at,
    fc.s3_status, fc.processing_status, fc.size_bytes
FROM files f
JOIN file_contents fc ON f.content_hash = fc.content_hash
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
-- SECURE VIEW FOR EMAIL FILTERING
-- =====================================
-- Wraps mv_unified_items with email visibility filter
-- RLS doesn't work on materialized views, so we use a view layer

CREATE OR REPLACE VIEW unified_items_secure AS
SELECT * FROM mv_unified_items
WHERE type != 'email'
   OR involved_emails && (
      ARRAY[get_current_user_email()] || get_public_emails()
   );

-- =====================================
-- GRANTS
-- =====================================

GRANT SELECT ON mv_task_assignees_agg TO authenticated;
GRANT SELECT ON mv_task_tags_agg TO authenticated;
GRANT SELECT ON mv_task_timelogs_agg TO authenticated;
GRANT SELECT ON mv_message_recipients_agg TO authenticated;
GRANT SELECT ON mv_message_attachments_agg TO authenticated;
GRANT SELECT ON mv_conversation_labels_agg TO authenticated;
GRANT SELECT ON mv_conversation_comments_agg TO authenticated;
GRANT SELECT ON mv_conversation_assignees_agg TO authenticated;
-- MV not directly accessible - use unified_items_secure view instead
REVOKE SELECT ON mv_unified_items FROM authenticated;
GRANT SELECT ON unified_items_secure TO authenticated;

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON MATERIALIZED VIEW mv_unified_items IS 'Unified materialized view combining tasks, emails, and Craft documents for dashboard display';
COMMENT ON VIEW unified_items_secure IS 'Security wrapper for mv_unified_items - filters emails by user visibility (use this, not the MV directly)';
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
COMMENT ON MATERIALIZED VIEW mv_task_timelogs_agg IS 'Pre-aggregated task timelogs (logged minutes) for unified_items performance';

-- =====================================
-- REGISTER MVS FOR CRON REFRESH
-- =====================================

INSERT INTO mv_refresh_status (view_name, needs_refresh, refresh_interval_minutes) VALUES
    ('mv_task_assignees_agg', FALSE, 5),
    ('mv_task_tags_agg', FALSE, 5),
    ('mv_task_timelogs_agg', FALSE, 5),
    ('mv_message_recipients_agg', FALSE, 5),
    ('mv_message_attachments_agg', FALSE, 5),
    ('mv_conversation_labels_agg', FALSE, 5),
    ('mv_conversation_comments_agg', FALSE, 1),
    ('mv_conversation_assignees_agg', FALSE, 5),
    ('mv_unified_items', FALSE, 1)
ON CONFLICT (view_name) DO NOTHING;

