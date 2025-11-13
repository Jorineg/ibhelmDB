-- Create a unified view that combines tasks and emails into a single queryable structure
-- This eliminates the need for multiple API calls and client-side merging

CREATE OR REPLACE VIEW unified_items AS

-- Tasks
SELECT 
    t.task_id::text AS id,
    'task' AS type,
    t.name,
    t.description,
    t.status,
    p.name AS project,
    c.name AS customer,
    '' AS building,
    '' AS floor,
    '' AS room,
    '' AS kostengruppe,
    t.due_date,
    t.created_at,
    t.updated_at,
    t.priority,
    t.progress,
    tl.name AS tasklist,
    
    -- Aggregate related data
    (
        SELECT json_agg(json_build_object('id', u.id, 'first_name', u.first_name, 'last_name', u.last_name, 'email', u.email))
        FROM task_assignees ta
        JOIN tw_users u ON ta.user_id = u.id
        WHERE ta.task_id = t.task_id
    ) AS assignees,
    
    (
        SELECT json_agg(json_build_object('id', tag.id, 'name', tag.name, 'color', tag.color))
        FROM task_tags tt
        JOIN tw_tags tag ON tt.tag_id = tag.id
        WHERE tt.task_id = t.task_id
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
    
    -- Sort key for unified ordering
    COALESCE(t.updated_at, t.created_at) AS sort_date
    
FROM tasks t
LEFT JOIN tw_projects p ON t.project_id = p.id
LEFT JOIN tw_companies c ON p.company_id = c.id
LEFT JOIN tw_tasklists tl ON t.tasklist_id = tl.id
WHERE t.deleted_at IS NULL

UNION ALL

-- Emails
SELECT 
    m.id::text AS id,
    'email' AS type,
    m.subject AS name,
    COALESCE(m.preview, m.body, '') AS description,
    '' AS status,
    '' AS project,
    '' AS customer,
    '' AS building,
    '' AS floor,
    '' AS room,
    '' AS kostengruppe,
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
    
    (
        SELECT json_agg(json_build_object('id', mr.id, 'recipient_type', mr.recipient_type, 'contact', json_build_object('id', c.id, 'name', c.name, 'email', c.email)))
        FROM m_message_recipients mr
        LEFT JOIN m_contacts c ON mr.contact_id = c.id
        WHERE mr.message_id = m.id
    ) AS recipients,
    
    (
        SELECT json_agg(json_build_object('id', a.id, 'filename', a.filename, 'extension', a.extension, 'size', a.size))
        FROM m_attachments a
        WHERE a.message_id = m.id
    ) AS attachments,
    
    (
        SELECT COUNT(*)
        FROM m_attachments a
        WHERE a.message_id = m.id
    ) AS attachment_count,
    
    -- Sort key for unified ordering
    COALESCE(m.delivered_at, m.updated_at, m.created_at) AS sort_date
    
FROM m_messages m
LEFT JOIN m_conversations conv ON m.conversation_id = conv.id
LEFT JOIN m_contacts from_contact ON m.from_contact_id = from_contact.id;

-- Create indexes on the base tables to improve view performance
CREATE INDEX IF NOT EXISTS idx_tasks_updated_created_at ON tasks(COALESCE(updated_at, created_at) DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_m_messages_delivered_updated_created_at ON m_messages(COALESCE(delivered_at, updated_at, created_at) DESC);

-- Add comments for documentation
COMMENT ON VIEW unified_items IS 'Unified view combining tasks and emails for dashboard display. Includes all necessary fields and related data aggregated as JSON.';

