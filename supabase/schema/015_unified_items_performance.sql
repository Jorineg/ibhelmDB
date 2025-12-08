-- =====================================
-- UNIFIED ITEMS PERFORMANCE OPTIMIZATIONS
-- =====================================
-- Addresses slow query performance on unified_items view (1.5-2s for 15k items)
-- 
-- Issues addressed:
-- 1. Correlated subqueries for assignees, tags, recipients, attachments run for each row
-- 2. Missing indexes on sort columns
-- 3. UNION ALL forces both branches to execute even when filtering by type

-- =====================================
-- 1. ADD MISSING INDEXES FOR SORTING
-- =====================================

-- Index for task sort_date calculation
CREATE INDEX IF NOT EXISTS idx_tw_tasks_sort_date 
    ON teamwork.tasks(COALESCE(updated_at, created_at) DESC) 
    WHERE deleted_at IS NULL;

-- Index for message sort_date calculation
CREATE INDEX IF NOT EXISTS idx_m_messages_sort_date 
    ON missive.messages(COALESCE(delivered_at, updated_at, created_at) DESC);

-- Composite index for task status filtering
CREATE INDEX IF NOT EXISTS idx_tw_tasks_deleted_status 
    ON teamwork.tasks(deleted_at, status);

-- =====================================
-- 2. CREATE PRE-AGGREGATED TABLES
-- =====================================

-- Materialized aggregates for task assignees (refreshed periodically)
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_task_assignees_agg AS
SELECT 
    ta.task_id,
    jsonb_agg(jsonb_build_object(
        'id', u.id, 
        'first_name', u.first_name, 
        'last_name', u.last_name, 
        'email', u.email
    )) AS assignees
FROM teamwork.task_assignees ta
JOIN teamwork.users u ON ta.user_id = u.id
GROUP BY ta.task_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_task_assignees_task_id ON mv_task_assignees_agg(task_id);

-- Materialized aggregates for task tags
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_task_tags_agg AS
SELECT 
    tt.task_id,
    jsonb_agg(jsonb_build_object(
        'id', tag.id, 
        'name', tag.name, 
        'color', tag.color
    )) AS tags
FROM teamwork.task_tags tt
JOIN teamwork.tags tag ON tt.tag_id = tag.id
GROUP BY tt.task_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_task_tags_task_id ON mv_task_tags_agg(task_id);

-- Materialized aggregates for message recipients
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_message_recipients_agg AS
SELECT 
    mr.message_id,
    jsonb_agg(jsonb_build_object(
        'id', mr.id, 
        'recipient_type', mr.recipient_type, 
        'contact', jsonb_build_object(
            'id', rc.id, 
            'name', rc.name, 
            'email', rc.email
        )
    )) AS recipients
FROM missive.message_recipients mr
LEFT JOIN missive.contacts rc ON mr.contact_id = rc.id
GROUP BY mr.message_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_message_recipients_msg_id ON mv_message_recipients_agg(message_id);

-- Materialized aggregates for message attachments
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_message_attachments_agg AS
SELECT 
    a.message_id,
    jsonb_agg(jsonb_build_object(
        'id', a.id, 
        'filename', a.filename, 
        'extension', a.extension, 
        'size', a.size
    )) AS attachments,
    COUNT(*)::INTEGER AS attachment_count
FROM missive.attachments a
GROUP BY a.message_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_message_attachments_msg_id ON mv_message_attachments_agg(message_id);

-- Materialized aggregates for conversation labels
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_conversation_labels_agg AS
SELECT 
    cl.conversation_id,
    jsonb_agg(jsonb_build_object(
        'id', sl.id, 
        'name', sl.name, 
        'color', NULL
    )) AS tags
FROM missive.conversation_labels cl
JOIN missive.shared_labels sl ON cl.label_id = sl.id
GROUP BY cl.conversation_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_conversation_labels_conv_id ON mv_conversation_labels_agg(conversation_id);

-- Materialized aggregates for conversation comments (for search)
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_conversation_comments_agg AS
SELECT 
    cc.conversation_id,
    string_agg(cc.body, ' ') AS comments_text
FROM missive.conversation_comments cc
WHERE cc.body IS NOT NULL AND cc.body != ''
GROUP BY cc.conversation_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_conversation_comments_conv_id ON mv_conversation_comments_agg(conversation_id);

-- =====================================
-- 3. CREATE OPTIMIZED VIEW
-- =====================================

-- Drop the old view first
DROP VIEW IF EXISTS unified_items CASCADE;

-- Create optimized view using pre-aggregated materialized views
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
    cg.code::TEXT AS cost_group_code,
    t.due_date,
    t.created_at,
    t.updated_at,
    t.priority,
    t.progress,
    tl.name AS tasklist,
    tt.id AS task_type_id,
    tt.name AS task_type_name,
    tt.slug AS task_type_slug,
    tt.color AS task_type_color,
    taa.assignees,
    tta.tags,
    NULL::TEXT AS body,
    NULL::TEXT AS preview,
    NULL::TEXT AS from_name,
    NULL::TEXT AS from_email,
    NULL::TEXT AS conversation_subject,
    NULL::JSONB AS recipients,
    NULL::JSONB AS attachments,
    0 AS attachment_count,
    NULL::TEXT AS conversation_comments_text,
    NULL::TEXT AS craft_url,
    t.source_links->>'teamwork_url' AS teamwork_url,
    NULL::TEXT AS missive_url,
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
LEFT JOIN mv_task_assignees_agg taa ON t.id = taa.task_id
LEFT JOIN mv_task_tags_agg tta ON t.id = tta.task_id
WHERE t.deleted_at IS NULL

UNION ALL

-- Emails from Missive
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
    cg.code::TEXT AS cost_group_code,
    NULL AS due_date,
    m.created_at,
    m.updated_at,
    '' AS priority,
    NULL AS progress,
    '' AS tasklist,
    NULL::UUID AS task_type_id,
    NULL::TEXT AS task_type_name,
    NULL::TEXT AS task_type_slug,
    NULL::VARCHAR(50) AS task_type_color,
    NULL::JSONB AS assignees,
    cla.tags,
    m.body_plain_text AS body,
    m.preview,
    from_contact.name AS from_name,
    from_contact.email AS from_email,
    conv.subject AS conversation_subject,
    mra.recipients,
    maa.attachments,
    COALESCE(maa.attachment_count, 0) AS attachment_count,
    cca.comments_text AS conversation_comments_text,
    NULL::TEXT AS craft_url,
    NULL::TEXT AS teamwork_url,
    conv.app_url AS missive_url,
    COALESCE(m.delivered_at, m.updated_at, m.created_at) AS sort_date
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

UNION ALL

-- Craft Documents (only body contains markdown content, not description/preview/status)
SELECT 
    cd.id::TEXT AS id,
    'craft' AS type,
    cd.title AS name,
    NULL::TEXT AS description,
    '' AS status,
    '' AS project,
    '' AS customer,
    NULL AS location,
    NULL AS location_path,
    NULL AS cost_group,
    NULL AS cost_group_code,
    NULL AS due_date,
    cd.craft_created_at AS created_at,
    cd.craft_last_modified_at AS updated_at,
    '' AS priority,
    NULL AS progress,
    '' AS tasklist,
    NULL::UUID AS task_type_id,
    NULL::TEXT AS task_type_name,
    NULL::TEXT AS task_type_slug,
    NULL::VARCHAR(50) AS task_type_color,
    NULL::JSONB AS assignees,
    NULL::JSONB AS tags,
    cd.markdown_content AS body,
    NULL::TEXT AS preview,
    NULL AS from_name,
    NULL AS from_email,
    NULL AS conversation_subject,
    NULL::JSONB AS recipients,
    NULL::JSONB AS attachments,
    0 AS attachment_count,
    NULL AS conversation_comments_text,
    'craftdocs://open?blockId=' || cd.id AS craft_url,
    NULL::TEXT AS teamwork_url,
    NULL::TEXT AS missive_url,
    COALESCE(cd.craft_last_modified_at, cd.db_updated_at, cd.db_created_at) AS sort_date
FROM craft_documents cd
WHERE cd.is_deleted = FALSE;

-- =====================================
-- 4. CREATE FUNCTION TO REFRESH MATERIALIZED VIEWS
-- =====================================

-- Use CONCURRENTLY for non-blocking refreshes (requires unique index and previous population)
CREATE OR REPLACE FUNCTION refresh_unified_items_aggregates(p_concurrent BOOLEAN DEFAULT TRUE)
RETURNS void AS $$
BEGIN
    IF p_concurrent THEN
        -- Non-blocking refresh (use after initial population)
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_task_assignees_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_task_tags_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_message_recipients_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_message_attachments_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_conversation_labels_agg;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_conversation_comments_agg;
    ELSE
        -- Blocking refresh (use for initial population)
        REFRESH MATERIALIZED VIEW mv_task_assignees_agg;
        REFRESH MATERIALIZED VIEW mv_task_tags_agg;
        REFRESH MATERIALIZED VIEW mv_message_recipients_agg;
        REFRESH MATERIALIZED VIEW mv_message_attachments_agg;
        REFRESH MATERIALIZED VIEW mv_conversation_labels_agg;
        REFRESH MATERIALIZED VIEW mv_conversation_comments_agg;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =====================================
-- 5. GRANT PERMISSIONS
-- =====================================

GRANT SELECT ON mv_task_assignees_agg TO authenticated;
GRANT SELECT ON mv_task_tags_agg TO authenticated;
GRANT SELECT ON mv_message_recipients_agg TO authenticated;
GRANT SELECT ON mv_message_attachments_agg TO authenticated;
GRANT SELECT ON mv_conversation_labels_agg TO authenticated;
GRANT SELECT ON mv_conversation_comments_agg TO authenticated;
GRANT EXECUTE ON FUNCTION refresh_unified_items_aggregates(BOOLEAN) TO authenticated;

-- =====================================
-- 6. TRIGGERS TO MARK MATERIALIZED VIEWS FOR REFRESH
-- =====================================
-- Instead of refreshing on every change (expensive), 
-- we track if refresh is needed and do it periodically

CREATE TABLE IF NOT EXISTS mv_refresh_status (
    view_name TEXT PRIMARY KEY,
    needs_refresh BOOLEAN DEFAULT FALSE,
    last_refreshed_at TIMESTAMP DEFAULT NOW(),
    refresh_interval_minutes INTEGER DEFAULT 5
);

-- Initialize refresh status for all materialized views
INSERT INTO mv_refresh_status (view_name, needs_refresh, refresh_interval_minutes) VALUES
    ('mv_task_assignees_agg', FALSE, 5),
    ('mv_task_tags_agg', FALSE, 5),
    ('mv_message_recipients_agg', FALSE, 5),
    ('mv_message_attachments_agg', FALSE, 5),
    ('mv_conversation_labels_agg', FALSE, 5),
    ('mv_conversation_comments_agg', FALSE, 1)
ON CONFLICT (view_name) DO NOTHING;

-- Function to mark a view as needing refresh
CREATE OR REPLACE FUNCTION mark_mv_needs_refresh(p_view_name TEXT)
RETURNS void AS $$
BEGIN
    UPDATE mv_refresh_status SET needs_refresh = TRUE WHERE view_name = p_view_name;
END;
$$ LANGUAGE plpgsql;

-- Single parameterized trigger function for marking MVs as stale (uses TG_ARGV[0] for view name)
CREATE OR REPLACE FUNCTION trigger_mark_mv_stale()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM mark_mv_needs_refresh(TG_ARGV[0]);
    RETURN NULL; -- For AFTER statement triggers, return value is ignored
END;
$$ LANGUAGE plpgsql;

-- Create triggers on source tables (using parameterized function)
DROP TRIGGER IF EXISTS trg_task_assignees_mv_stale ON teamwork.task_assignees;
CREATE TRIGGER trg_task_assignees_mv_stale AFTER INSERT OR UPDATE OR DELETE ON teamwork.task_assignees
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_task_assignees_agg');

DROP TRIGGER IF EXISTS trg_task_tags_mv_stale ON teamwork.task_tags;
CREATE TRIGGER trg_task_tags_mv_stale AFTER INSERT OR UPDATE OR DELETE ON teamwork.task_tags
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_task_tags_agg');

DROP TRIGGER IF EXISTS trg_message_recipients_mv_stale ON missive.message_recipients;
CREATE TRIGGER trg_message_recipients_mv_stale AFTER INSERT OR UPDATE OR DELETE ON missive.message_recipients
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_message_recipients_agg');

DROP TRIGGER IF EXISTS trg_attachments_mv_stale ON missive.attachments;
CREATE TRIGGER trg_attachments_mv_stale AFTER INSERT OR UPDATE OR DELETE ON missive.attachments
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_message_attachments_agg');

DROP TRIGGER IF EXISTS trg_conv_labels_mv_stale ON missive.conversation_labels;
CREATE TRIGGER trg_conv_labels_mv_stale AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_labels
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_conversation_labels_agg');

DROP TRIGGER IF EXISTS trg_conv_comments_mv_stale ON missive.conversation_comments;
CREATE TRIGGER trg_conv_comments_mv_stale AFTER INSERT OR UPDATE OR DELETE ON missive.conversation_comments
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_mark_mv_stale('mv_conversation_comments_agg');

-- Function to refresh only stale materialized views (uses dynamic SQL to avoid duplication)
CREATE OR REPLACE FUNCTION refresh_stale_unified_items_aggregates()
RETURNS TABLE(view_name TEXT, refreshed BOOLEAN) AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT mrs.view_name FROM mv_refresh_status mrs 
        WHERE mrs.needs_refresh = TRUE 
           OR (NOW() - mrs.last_refreshed_at) > (mrs.refresh_interval_minutes || ' minutes')::INTERVAL
    LOOP
        view_name := r.view_name;
        BEGIN
            EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %I', r.view_name);
        EXCEPTION WHEN OTHERS THEN
            EXECUTE format('REFRESH MATERIALIZED VIEW %I', r.view_name);
        END;
        UPDATE mv_refresh_status SET needs_refresh = FALSE, last_refreshed_at = NOW() 
        WHERE mv_refresh_status.view_name = r.view_name;
        refreshed := TRUE;
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Grant permissions on new objects
GRANT SELECT, UPDATE ON mv_refresh_status TO authenticated;
GRANT EXECUTE ON FUNCTION mark_mv_needs_refresh(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION refresh_stale_unified_items_aggregates() TO authenticated;

-- =====================================
-- 7. INITIAL REFRESH OF MATERIALIZED VIEWS
-- =====================================
-- Note: Initial refresh uses non-concurrent mode (blocking but necessary)

SELECT refresh_unified_items_aggregates(FALSE);

-- =====================================
-- COMMENTS
-- =====================================

COMMENT ON MATERIALIZED VIEW mv_task_assignees_agg IS 'Pre-aggregated task assignees for unified_items performance';
COMMENT ON MATERIALIZED VIEW mv_task_tags_agg IS 'Pre-aggregated task tags for unified_items performance';
COMMENT ON MATERIALIZED VIEW mv_message_recipients_agg IS 'Pre-aggregated message recipients for unified_items performance';
COMMENT ON MATERIALIZED VIEW mv_message_attachments_agg IS 'Pre-aggregated message attachments for unified_items performance';
COMMENT ON MATERIALIZED VIEW mv_conversation_labels_agg IS 'Pre-aggregated conversation labels for unified_items performance';
COMMENT ON MATERIALIZED VIEW mv_conversation_comments_agg IS 'Pre-aggregated conversation comments for unified_items search';
COMMENT ON FUNCTION refresh_unified_items_aggregates IS 'Refreshes all materialized views used by unified_items. Run periodically or after bulk updates.';

