-- Agent-optimized views and schema functions.
-- These provide a simplified, pre-joined interface for AI agents (PAA, BST, chat).
-- Always re-run, must be idempotent.

-- ============================================================================
-- get_full_schema() — Dynamic full schema doc, replaces static markdown file
-- ============================================================================

CREATE OR REPLACE FUNCTION get_full_schema(p_schema TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
WITH app_schemas(schema_name, sort_order) AS (
    VALUES ('missive', 1), ('public', 2), ('teamwork', 3)
),
filtered_schemas AS (
    SELECT * FROM app_schemas
    WHERE p_schema IS NULL OR schema_name = p_schema
),
enum_vals AS (
    SELECT t.typname, string_agg(e.enumlabel, '/' ORDER BY e.enumsortorder) AS vals
    FROM pg_type t
    JOIN pg_enum e ON t.oid = e.enumtypid
    JOIN pg_namespace n ON t.typnamespace = n.oid
    GROUP BY t.typname
),
pk_cols AS (
    SELECT n.nspname AS schema_name, c.relname AS table_name, a.attname AS col_name
    FROM pg_constraint con
    JOIN pg_class c ON con.conrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(con.conkey)
    WHERE con.contype = 'p'
),
fk_cols AS (
    SELECT n.nspname AS src_schema, c.relname AS src_table, a.attname AS src_col,
           fn.nspname AS tgt_schema, fc.relname AS tgt_table, fa.attname AS tgt_col
    FROM pg_constraint con
    JOIN pg_class c ON con.conrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(con.conkey)
    JOIN pg_class fc ON con.confrelid = fc.oid
    JOIN pg_namespace fn ON fc.relnamespace = fn.oid
    JOIN pg_attribute fa ON fa.attrelid = fc.oid AND fa.attnum = ANY(con.confkey)
    WHERE con.contype = 'f' AND array_length(con.conkey, 1) = 1
),
all_columns AS (
    SELECT c.table_schema, c.table_name, c.column_name, c.udt_name, c.ordinal_position,
           CASE WHEN t.table_type = 'BASE TABLE' THEN 'table' ELSE 'view' END AS rel_type
    FROM information_schema.columns c
    JOIN information_schema.tables t ON c.table_schema = t.table_schema AND c.table_name = t.table_name
    JOIN filtered_schemas s ON c.table_schema = s.schema_name
    WHERE t.table_type IN ('BASE TABLE', 'VIEW')
    UNION ALL
    SELECT n.nspname, c.relname, a.attname, t.typname, a.attnum::int, 'matview'
    FROM pg_class c
    JOIN pg_namespace n ON c.relnamespace = n.oid
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    JOIN pg_type t ON a.atttypid = t.oid
    JOIN filtered_schemas s ON n.nspname = s.schema_name
    WHERE c.relkind = 'm'
),
col_formatted AS (
    SELECT ac.table_schema, ac.table_name, ac.ordinal_position, ac.rel_type,
        ac.column_name
        || CASE
            WHEN ev.vals IS NOT NULL THEN ''
            WHEN ac.udt_name = 'uuid' THEN ' uuid'
            WHEN ac.udt_name = 'int4' AND (ac.column_name = 'id' OR ac.column_name LIKE '%\_id' ESCAPE '\' OR ac.column_name LIKE '%\_count' ESCAPE '\') THEN ''
            WHEN ac.udt_name = 'int4' THEN ' int'
            WHEN ac.udt_name = 'int8' THEN ' bigint'
            WHEN ac.udt_name = 'bool' AND (ac.column_name LIKE 'is\_%' ESCAPE '\' OR ac.column_name LIKE 'has\_%' ESCAPE '\' OR ac.column_name LIKE 'can\_%' ESCAPE '\') THEN ''
            WHEN ac.udt_name = 'bool' THEN ' bool'
            WHEN ac.udt_name = 'timestamp' AND (ac.column_name LIKE '%\_at' ESCAPE '\' OR ac.column_name LIKE '%\_date' ESCAPE '\') THEN ''
            WHEN ac.udt_name = 'timestamp' THEN ' ts'
            WHEN ac.udt_name = 'timestamptz' THEN ' tstz'
            WHEN ac.udt_name = 'jsonb' THEN ' jsonb'
            WHEN ac.udt_name = 'date' THEN ' date'
            WHEN ac.udt_name = 'numeric' THEN ' numeric'
            WHEN ac.udt_name = 'bpchar' THEN ' char'
            WHEN ac.udt_name = '_uuid' THEN ' uuid[]'
            WHEN ac.udt_name = '_text' THEN ' text[]'
            WHEN ac.udt_name = '_int8' THEN ' bigint[]'
            WHEN ac.udt_name IN ('text', 'varchar') THEN ''
            ELSE ' ' || ac.udt_name
           END
        || CASE WHEN pk.col_name IS NOT NULL THEN ' [pk]' ELSE '' END
        || CASE WHEN ev.vals IS NOT NULL THEN ' (' || ev.vals || ')' ELSE '' END
        || CASE
            WHEN fk.tgt_schema IS NOT NULL AND fk.tgt_schema = ac.table_schema
                THEN ' (->' || fk.tgt_table || '.' || fk.tgt_col || ')'
            WHEN fk.tgt_schema IS NOT NULL
                THEN ' (->' || fk.tgt_schema || '.' || fk.tgt_table || '.' || fk.tgt_col || ')'
            ELSE ''
           END
        AS col_str
    FROM all_columns ac
    LEFT JOIN enum_vals ev ON ac.udt_name = ev.typname
    LEFT JOIN pk_cols pk ON ac.table_schema = pk.schema_name AND ac.table_name = pk.table_name AND ac.column_name = pk.col_name
    LEFT JOIN fk_cols fk ON ac.table_schema = fk.src_schema AND ac.table_name = fk.src_table AND ac.column_name = fk.src_col
),
table_lines AS (
    SELECT table_schema, table_name, rel_type,
        '- **' || table_name || '**'
        || CASE rel_type WHEN 'view' THEN ' [view]' WHEN 'matview' THEN ' [mv]' ELSE '' END
        || ': ' || string_agg(col_str, ', ' ORDER BY ordinal_position) AS line
    FROM col_formatted
    GROUP BY table_schema, table_name, rel_type
),
func_lines AS (
    SELECT n.nspname AS schema_name, p.proname AS func_name,
        '- **' || p.proname || '** [fn]('
        || regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(pg_get_function_arguments(p.oid), ' DEFAULT [^,)]+', '', 'g'),
                        'timestamp with time zone', 'tstz', 'g'),
                    'timestamp without time zone', 'ts', 'g'),
                'character varying', 'varchar', 'g'),
            'integer', 'int', 'g')
        || ') → '
        || CASE
            WHEN pg_get_function_result(p.oid) = 'text' THEN 'text'
            WHEN pg_get_function_result(p.oid) = 'boolean' THEN 'bool'
            WHEN pg_get_function_result(p.oid) LIKE 'TABLE(%' THEN 'TABLE(...)'
            ELSE pg_get_function_result(p.oid)
           END
        || CASE WHEN d.description LIKE '@schema_doc%'
            THEN ' -- ' || regexp_replace(d.description, '^@schema_doc\s*', '')
            ELSE '' END
        AS line
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    JOIN filtered_schemas s ON n.nspname = s.schema_name
    LEFT JOIN pg_description d ON d.objoid = p.oid AND d.classoid = 'pg_proc'::regclass
    WHERE d.description LIKE '@schema_doc%'
),
all_lines AS (
    SELECT table_schema AS schema_name,
        CASE rel_type WHEN 'table' THEN 0 WHEN 'view' THEN 1 WHEN 'matview' THEN 2 END AS section,
        table_name AS sort_name, line
    FROM table_lines
    UNION ALL
    SELECT schema_name, 3, func_name, line FROM func_lines
)
SELECT string_agg(
    E'\n## ' || s.schema_name || E'\n\n' || schema_content,
    E'\n'
    ORDER BY s.sort_order
)
|| E'\n\n---\nThis lists all tables, views, and a selection of the most important functions (not all functions).\n'
FROM (
    SELECT al.schema_name,
        string_agg(al.line, E'\n' ORDER BY al.section, al.sort_name) AS schema_content
    FROM all_lines al
    GROUP BY al.schema_name
) sub
JOIN filtered_schemas s ON sub.schema_name = s.schema_name;
$$;

COMMENT ON FUNCTION get_full_schema IS '@schema_doc Complete database schema documentation. Call with no args for all schemas, or pass schema name (missive/public/teamwork) for one schema.';


-- ============================================================================
-- Helper: get active file ignore patterns from app_settings
-- ============================================================================

CREATE OR REPLACE FUNCTION get_file_ignore_extensions()
RETURNS TEXT[]
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT COALESCE(array_agg(LOWER(SUBSTRING(p->>'pattern' FROM 3))), ARRAY[]::TEXT[])
    FROM app_settings,
         jsonb_array_elements(body->'file_ignore_patterns') AS p
    WHERE (p->>'enabled')::boolean = true
      AND (p->>'pattern') ~ '^%\.[a-zA-Z0-9]+$';
$$;

CREATE OR REPLACE FUNCTION get_file_ignore_path_patterns()
RETURNS TEXT[]
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT COALESCE(array_agg(p->>'pattern'), ARRAY[]::TEXT[])
    FROM app_settings,
         jsonb_array_elements(body->'file_ignore_patterns') AS p
    WHERE (p->>'enabled')::boolean = true
      AND (p->>'pattern') !~ '^%\.[a-zA-Z0-9]+$';
$$;


-- ============================================================================
-- v_projects — Projects with Tier 1/2, client, defaults, counts
-- ============================================================================

CREATE OR REPLACE VIEW v_projects AS
SELECT
    p.id AS project_id,
    p.name,
    p.description,
    p.status,
    p.start_date,
    p.end_date,
    c.name AS company,
    client.display_name AS client_name,
    client.primary_email AS client_email,
    pe.nas_folder_path,
    pe.internal_notes,
    pe.profile_markdown AS tier1_profile,
    pe.profile_generated_at AS tier1_generated_at,
    pe.status_markdown AS tier2_status,
    pe.status_generated_at AS tier2_generated_at,
    dl.name AS default_location,
    dl.path AS default_location_path,
    dcg.code AS default_cost_group_code,
    dcg.name AS default_cost_group,
    p.created_at,
    p.updated_at
FROM teamwork.projects p
LEFT JOIN project_extensions pe ON p.id = pe.tw_project_id
LEFT JOIN teamwork.companies c ON p.company_id = c.id
LEFT JOIN unified_persons client ON pe.client_person_id = client.id
LEFT JOIN locations dl ON pe.default_location_id = dl.id
LEFT JOIN cost_groups dcg ON pe.default_cost_group_id = dcg.id;


-- ============================================================================
-- v_project_tasks — Tasks with assignees, tags, KGR, locations, tasklist
-- ============================================================================

CREATE OR REPLACE VIEW v_project_tasks AS
SELECT
    t.project_id,
    t.id AS task_id,
    t.name,
    t.description,
    t.status,
    t.priority,
    t.progress,
    t.due_date,
    t.start_date,
    tl.name AS tasklist,
    assignee_agg.names AS assignees,
    tag_agg.names AS tags,
    cg_agg.codes AS cost_groups,
    loc_agg.names AS locations,
    tt.name AS task_type,
    t.created_at,
    t.updated_at,
    'https://ibhelm.teamwork.com/#/tasks/' || t.id AS url
FROM teamwork.tasks t
LEFT JOIN teamwork.tasklists tl ON t.tasklist_id = tl.id
LEFT JOIN task_extensions te ON t.id = te.tw_task_id
LEFT JOIN task_types tt ON te.task_type_id = tt.id
LEFT JOIN LATERAL (
    SELECT string_agg(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), ', ') AS names
    FROM teamwork.task_assignees ta JOIN teamwork.users u ON ta.user_id = u.id
    WHERE ta.task_id = t.id
) assignee_agg ON TRUE
LEFT JOIN LATERAL (
    SELECT string_agg(tg.name, ', ') AS names
    FROM teamwork.task_tags ttg JOIN teamwork.tags tg ON ttg.tag_id = tg.id
    WHERE ttg.task_id = t.id
) tag_agg ON TRUE
LEFT JOIN LATERAL (
    SELECT string_agg(cg.code::text, ', ') AS codes
    FROM object_cost_groups ocg JOIN cost_groups cg ON ocg.cost_group_id = cg.id
    WHERE ocg.tw_task_id = t.id
) cg_agg ON TRUE
LEFT JOIN LATERAL (
    SELECT string_agg(l.name, ', ') AS names
    FROM object_locations ol JOIN locations l ON ol.location_id = l.id
    WHERE ol.tw_task_id = t.id
) loc_agg ON TRUE
WHERE t.deleted_at IS NULL;


-- ============================================================================
-- v_project_emails — Emails with sender, recipients, attachment summary
-- ============================================================================

CREATE OR REPLACE VIEW v_project_emails AS
SELECT
    pc.tw_project_id AS project_id,
    c.id AS conversation_id,
    m.id AS message_id,
    m.subject,
    m.body_plain_text,
    m.preview,
    sender.name AS from_name,
    sender.email AS from_email,
    recip_agg.to_recipients,
    m.delivered_at,
    att_agg.attachment_filenames,
    COALESCE(att_agg.attachment_count, 0) AS attachment_count,
    c.web_url AS missive_url,
    m.created_at
FROM project_conversations pc
JOIN missive.conversations c ON pc.m_conversation_id = c.id
JOIN missive.messages m ON m.conversation_id = c.id
LEFT JOIN missive.contacts sender ON m.from_contact_id = sender.id
LEFT JOIN LATERAL (
    SELECT string_agg(rc.email, ', ') AS to_recipients
    FROM missive.message_recipients mr
    JOIN missive.contacts rc ON mr.contact_id = rc.id
    WHERE mr.message_id = m.id AND mr.recipient_type = 'to'
) recip_agg ON TRUE
LEFT JOIN LATERAL (
    SELECT string_agg(a.filename, ', ') AS attachment_filenames,
           COUNT(*)::int AS attachment_count
    FROM missive.attachments a WHERE a.message_id = m.id
) att_agg ON TRUE;


-- ============================================================================
-- v_project_craft_docs — Craft docs with content, linked to project
-- ============================================================================

CREATE OR REPLACE VIEW v_project_craft_docs AS
SELECT
    pcd.tw_project_id AS project_id,
    cd.id AS document_id,
    cd.title,
    cd.markdown_content,
    LENGTH(cd.markdown_content) AS content_length,
    cd.folder_path,
    cd.craft_created_at,
    cd.craft_last_modified_at,
    'craftdocs://open?blockId=' || cd.id AS craft_url
FROM project_craft_documents pcd
JOIN craft_documents cd ON pcd.craft_document_id = cd.id
WHERE NOT cd.is_deleted;


-- ============================================================================
-- v_project_files — Files with content, doc type, KGR, junk-filtered
-- ============================================================================

CREATE OR REPLACE VIEW v_project_files AS
SELECT
    f.project_id,
    f.id AS file_id,
    SUBSTRING(f.full_path FROM '[^/]+$') AS filename,
    f.full_path,
    dt.name AS document_type,
    fc.extracted_text,
    fc.storage_path,
    fc.thumbnail_path,
    fc.size_bytes,
    cg_agg.codes AS cost_groups,
    src_email.subject AS source_email_subject,
    f.fs_mtime,
    f.content_hash,
    f.db_created_at AS created_at
FROM files f
JOIN file_contents fc ON f.content_hash = fc.content_hash
LEFT JOIN document_types dt ON f.document_type_id = dt.id
LEFT JOIN LATERAL (
    SELECT string_agg(cg.code::text, ', ') AS codes
    FROM object_cost_groups ocg JOIN cost_groups cg ON ocg.cost_group_id = cg.id
    WHERE ocg.file_id = f.id
) cg_agg ON TRUE
LEFT JOIN LATERAL (
    SELECT m.subject
    FROM missive.attachments ma
    JOIN missive.messages m ON ma.message_id = m.id
    WHERE ma.id = f.source_missive_attachment_id
) src_email ON TRUE
WHERE f.deleted_at IS NULL
  AND (
    COALESCE(LOWER(SUBSTRING(f.full_path FROM '\.([^./]+)$')), '')
    != ALL(get_file_ignore_extensions())
  )
  AND NOT EXISTS (
    SELECT 1 FROM unnest(get_file_ignore_path_patterns()) AS pat
    WHERE f.full_path ILIKE pat
  );


-- ============================================================================
-- v_agent_items — Simplified cross-type search for agents
-- ============================================================================

CREATE OR REPLACE VIEW v_agent_items AS

-- Tasks
SELECT
    t.id::text AS item_id,
    'task' AS item_type,
    t.project_id,
    twp.name AS project_name,
    t.name,
    t.description,
    t.status,
    tl.name AS tasklist,
    assignee_agg.names AS assignees,
    tag_agg.names AS tags,
    cg_agg.codes AS cost_groups,
    t.due_date,
    t.created_at,
    t.updated_at,
    'https://ibhelm.teamwork.com/#/tasks/' || t.id AS url
FROM teamwork.tasks t
LEFT JOIN teamwork.projects twp ON t.project_id = twp.id
LEFT JOIN teamwork.tasklists tl ON t.tasklist_id = tl.id
LEFT JOIN LATERAL (
    SELECT string_agg(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), ', ') AS names
    FROM teamwork.task_assignees ta JOIN teamwork.users u ON ta.user_id = u.id
    WHERE ta.task_id = t.id
) assignee_agg ON TRUE
LEFT JOIN LATERAL (
    SELECT string_agg(tg.name, ', ') AS names
    FROM teamwork.task_tags ttg JOIN teamwork.tags tg ON ttg.tag_id = tg.id
    WHERE ttg.task_id = t.id
) tag_agg ON TRUE
LEFT JOIN LATERAL (
    SELECT string_agg(cg.code::text, ', ') AS codes
    FROM object_cost_groups ocg JOIN cost_groups cg ON ocg.cost_group_id = cg.id
    WHERE ocg.tw_task_id = t.id
) cg_agg ON TRUE
WHERE t.deleted_at IS NULL

UNION ALL

-- Emails
SELECT
    m.id::text AS item_id,
    'email' AS item_type,
    pc.tw_project_id AS project_id,
    twp.name AS project_name,
    m.subject AS name,
    m.preview AS description,
    NULL AS status,
    NULL AS tasklist,
    sender.name AS assignees,
    NULL AS tags,
    NULL AS cost_groups,
    NULL AS due_date,
    m.delivered_at AS created_at,
    m.delivered_at AS updated_at,
    c.web_url AS url
FROM project_conversations pc
JOIN missive.conversations c ON pc.m_conversation_id = c.id
JOIN missive.messages m ON m.conversation_id = c.id
LEFT JOIN teamwork.projects twp ON pc.tw_project_id = twp.id
LEFT JOIN missive.contacts sender ON m.from_contact_id = sender.id

UNION ALL

-- Craft Docs
SELECT
    cd.id::text AS item_id,
    'craft_doc' AS item_type,
    pcd.tw_project_id AS project_id,
    twp.name AS project_name,
    cd.title AS name,
    cd.markdown_content AS description,
    NULL AS status,
    NULL AS tasklist,
    NULL AS assignees,
    NULL AS tags,
    NULL AS cost_groups,
    NULL AS due_date,
    cd.craft_created_at AS created_at,
    cd.craft_last_modified_at AS updated_at,
    'craftdocs://open?blockId=' || cd.id AS url
FROM project_craft_documents pcd
JOIN craft_documents cd ON pcd.craft_document_id = cd.id
LEFT JOIN teamwork.projects twp ON pcd.tw_project_id = twp.id
WHERE NOT cd.is_deleted

UNION ALL

-- Files (junk-filtered)
SELECT
    f.id::text AS item_id,
    'file' AS item_type,
    f.project_id,
    twp.name AS project_name,
    SUBSTRING(f.full_path FROM '[^/]+$') AS name,
    regexp_replace(f.full_path, '^/data/', '') AS description,
    NULL AS status,
    NULL AS tasklist,
    NULL AS assignees,
    NULL AS tags,
    cg_agg.codes AS cost_groups,
    NULL AS due_date,
    f.fs_mtime AS created_at,
    f.db_created_at AS updated_at,
    NULL AS url
FROM files f
LEFT JOIN teamwork.projects twp ON f.project_id = twp.id
LEFT JOIN LATERAL (
    SELECT string_agg(cg.code::text, ', ') AS codes
    FROM object_cost_groups ocg JOIN cost_groups cg ON ocg.cost_group_id = cg.id
    WHERE ocg.file_id = f.id
) cg_agg ON TRUE
WHERE f.deleted_at IS NULL
  AND COALESCE(LOWER(SUBSTRING(f.full_path FROM '\.([^./]+)$')), '') != ALL(get_file_ignore_extensions())
  AND NOT EXISTS (
    SELECT 1 FROM unnest(get_file_ignore_path_patterns()) AS pat
    WHERE f.full_path ILIKE pat
  );


-- ============================================================================
-- get_agent_schema() — Compact schema doc for prompt inclusion
-- Auto-generated from actual view/table definitions
-- ============================================================================

CREATE OR REPLACE FUNCTION get_agent_schema()
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
WITH agent_objects(obj_name, obj_type, sort_order, description) AS (
    VALUES
        ('v_projects', 'view', 1, 'Projects with Tier 1 profile, Tier 2 status, client, defaults. Filter by project_id, status (active/inactive).'),
        ('v_project_tasks', 'view', 2, 'Tasks with assignees, tags, KGR codes, locations, tasklist. Filter by project_id. status: new/completed/reopened. priority: high/medium/low. task_type: Task/Anforderung/Hinweis.'),
        ('v_project_emails', 'view', 3, 'Emails linked to projects with sender, recipients, attachment filenames. Filter by project_id. Includes body_plain_text.'),
        ('v_project_craft_docs', 'view', 4, 'Craft documents linked to projects with full markdown_content. Filter by project_id.'),
        ('v_project_files', 'view', 5, 'NAS files with extracted_text, document_type, KGR codes, source email subject. Junk files auto-excluded. Filter by project_id.'),
        ('v_agent_items', 'view', 6, 'Unified search across tasks/emails/craft_docs/files. Simplified columns. Filter by project_id, item_type (task/email/craft_doc/file). ORDER BY updated_at DESC recommended.'),
        ('project_activity_log', 'table', 7, 'Tier 3: AI-generated activity entries. Columns: id uuid, tw_project_id, logged_at tstz, category (decision/blocker/resolution/progress/milestone/risk/scope_change/communication), summary, source_event_ids bigint[], kgr_codes text[], involved_persons text[], generated_at tstz.'),
        ('project_event_log', 'table', 8, 'Tier 4: Raw change events from triggers. Columns: id bigint, tw_project_id, occurred_at tstz, source_table (teamwork.tasks/craft_documents/project_conversations/...), source_id, event_type (created/changed/deleted), details jsonb, content_diff, processed_by_diff bool, processed_by_agent bool.'),
        ('project_contractors', 'table', 9, 'Project-person junction. Columns: tw_project_id, contractor_person_id uuid (→unified_persons), role.'),
        ('unified_person_details', 'view', 10, 'People across systems. Columns: id uuid, display_name, primary_email, is_internal, is_company, tw_user_id, tw_company_name, m_contact_email.'),
        ('get_public_emails()', 'function', 11, 'Returns text[] of team/public email addresses (e.g. hzb@ibhelm.de, desy@ibhelm.de). Use to identify project-related emails.'),
        ('get_sync_status()', 'function', 12, 'Returns TABLE(source, last_event_time, checkpoint_updated_at, pending_count, processing_count, failed_count, ...). System health: data freshness per source (teamwork/missive/craft/files/thumbnails).'),
        ('get_full_schema()', 'function', 13, 'Returns full database schema as text. Optional param: schema name (missive/public/teamwork). Use when you need tables/columns not covered by agent views.'),
        ('submit_agent_feedback(feedback, category)', 'function', 14, 'NOT for querying — call this to submit feedback about your environment. Report missing context that should have been provided upfront, missing views/joins that would simplify queries, unclear/confusing documentation, or general suggestions. Category is freeform (e.g. missing_context, missing_view, unclear_docs, suggestion). Context, model, and session are captured automatically. Call via: db("SELECT submit_agent_feedback($1, $2)", feedback_text, category)')
),
view_columns AS (
    SELECT c.table_name, string_agg(
        c.column_name
        || CASE
            WHEN c.udt_name = 'uuid' THEN ' uuid'
            WHEN c.udt_name = 'int4' THEN ''
            WHEN c.udt_name = 'int8' THEN ' bigint'
            WHEN c.udt_name = 'timestamptz' THEN ' tstz'
            WHEN c.udt_name = 'bool' THEN ' bool'
            WHEN c.udt_name = 'date' THEN ' date'
            ELSE ''
        END,
        ', ' ORDER BY c.ordinal_position
    ) AS columns
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name IN (SELECT obj_name FROM agent_objects WHERE obj_type = 'view')
    GROUP BY c.table_name
)
SELECT E'## Agent Views & Tables\n\nThese cover 95% of queries. For the complete schema, call: db("SELECT get_full_schema()")\n\n'
    || string_agg(
        '### ' || ao.obj_name || ' [' || ao.obj_type || ']' || E'\n'
        || ao.description || E'\n'
        || CASE
            WHEN vc.columns IS NOT NULL THEN 'Columns: ' || vc.columns || E'\n'
            ELSE ''
        END,
        E'\n'
        ORDER BY ao.sort_order
    )
FROM agent_objects ao
LEFT JOIN view_columns vc ON ao.obj_name = vc.table_name;
$$;

COMMENT ON FUNCTION get_agent_schema IS '@schema_doc Compact schema documentation for AI agent prompts. Returns descriptions and columns of agent-optimized views.';


-- ============================================================================
-- Grants: allow mcp_readonly to read agent views
-- ============================================================================

GRANT SELECT ON v_projects TO mcp_readonly;
GRANT SELECT ON v_project_tasks TO mcp_readonly;
GRANT SELECT ON v_project_emails TO mcp_readonly;
GRANT SELECT ON v_project_craft_docs TO mcp_readonly;
GRANT SELECT ON v_project_files TO mcp_readonly;
GRANT SELECT ON v_agent_items TO mcp_readonly;
GRANT EXECUTE ON FUNCTION get_full_schema TO mcp_readonly;
GRANT EXECUTE ON FUNCTION get_agent_schema TO mcp_readonly;
GRANT EXECUTE ON FUNCTION get_file_ignore_extensions TO mcp_readonly;
GRANT EXECUTE ON FUNCTION get_file_ignore_path_patterns TO mcp_readonly;
