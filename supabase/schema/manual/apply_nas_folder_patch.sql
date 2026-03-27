-- One-off: NAS folder mapping + Craft/file linking + suggestions (idempotent CREATE OR REPLACE)
SET search_path TO public, extensions;
SET client_min_messages TO WARNING;

CREATE OR REPLACE FUNCTION normalized_nas_folder_segment(p_raw TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT NULLIF(
        TRIM(BOTH FROM
            reverse(split_part(reverse(TRIM(BOTH FROM regexp_replace(COALESCE(p_raw, ''), '/+$', ''))), '/', 1))
        ),
        ''
    );
$$;

CREATE OR REPLACE FUNCTION fold_de_for_match(p_text TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT regexp_replace(
        regexp_replace(
        regexp_replace(
        regexp_replace(lower(COALESCE(p_text, '')),
            'ä', 'ae', 'g'),
            'ö', 'oe', 'g'),
            'ü', 'ue', 'g'),
            'ß', 'ss', 'g');
$$;

CREATE OR REPLACE FUNCTION link_file_to_project(p_file_id UUID)
RETURNS INTEGER SECURITY DEFINER SET search_path = public, teamwork, missive AS $$
DECLARE
    v_full_path TEXT;
    v_project_id INTEGER;
BEGIN
    SELECT full_path INTO v_full_path FROM files WHERE id = p_file_id;
    IF NOT FOUND OR v_full_path IS NULL THEN RETURN NULL; END IF;

    SELECT p.id INTO v_project_id
    FROM teamwork.projects p
    LEFT JOIN project_extensions pe ON pe.tw_project_id = p.id
    CROSS JOIN LATERAL (
        SELECT COALESCE(normalized_nas_folder_segment(pe.nas_folder_path), p.name) AS storage_key
    ) k
    WHERE v_full_path ILIKE '%' || k.storage_key || '%'
    ORDER BY LENGTH(k.storage_key) DESC
    LIMIT 1;

    IF v_project_id IS NOT NULL THEN
        UPDATE files SET project_id = v_project_id WHERE id = p_file_id;
    END IF;

    RETURN v_project_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION link_craft_document_to_project(p_craft_document_id TEXT)
RETURNS INTEGER SECURITY DEFINER SET search_path = public, teamwork AS $$
DECLARE
    v_folder_path TEXT;
    v_fold TEXT;
    v_project RECORD;
    v_tag_row RECORD;
    v_links_created INTEGER := 0;
    v_pass1 BOOLEAN;
BEGIN
    SELECT folder_path INTO v_folder_path FROM craft_documents WHERE id = p_craft_document_id;
    IF NOT FOUND OR v_folder_path IS NULL OR v_folder_path = '' THEN RETURN 0; END IF;

    v_fold := fold_de_for_match(v_folder_path);

    SELECT EXISTS (
        SELECT 1 FROM teamwork.projects p
        WHERE v_fold LIKE '%' || fold_de_for_match(p.name) || '%'
    ) INTO v_pass1;

    IF v_pass1 THEN
        FOR v_project IN
            SELECT p.id, p.name FROM teamwork.projects p
            WHERE v_fold LIKE '%' || fold_de_for_match(p.name) || '%'
        LOOP
            INSERT INTO project_craft_documents (craft_document_id, tw_project_id, assigned_at)
            VALUES (p_craft_document_id, v_project.id, NOW())
            ON CONFLICT (tw_project_id, craft_document_id) DO NOTHING;
            IF FOUND THEN
                v_links_created := v_links_created + 1;
            END IF;
        END LOOP;
    ELSE
        FOR v_tag_row IN
            SELECT DISTINCT t.project_id AS pid
            FROM task_extensions te
            JOIN teamwork.tasks t ON t.id = te.tw_task_id
            WHERE te.type_source_tag_name IS NOT NULL
              AND btrim(te.type_source_tag_name) <> ''
              AND v_fold LIKE '%' || fold_de_for_match(te.type_source_tag_name) || '%'
        LOOP
            INSERT INTO project_craft_documents (craft_document_id, tw_project_id, assigned_at)
            VALUES (p_craft_document_id, v_tag_row.pid, NOW())
            ON CONFLICT (tw_project_id, craft_document_id) DO NOTHING;
            IF FOUND THEN
                v_links_created := v_links_created + 1;
            END IF;
        END LOOP;
    END IF;

    RETURN v_links_created;
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS get_pending_project_attachments(INTEGER, INTEGER);

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
    storage_folder_name TEXT,
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
        COALESCE(normalized_nas_folder_segment(pe.nas_folder_path), p.name) AS storage_folder_name,
        msg.delivered_at,
        c.email AS sender_email,
        COALESCE(msg.subject, conv.subject, conv.latest_message_subject) AS email_subject
    FROM email_attachment_files eaf
    JOIN missive.messages msg ON eaf.missive_message_id = msg.id
    JOIN missive.conversations conv ON msg.conversation_id = conv.id
    JOIN project_conversations pc ON msg.conversation_id = pc.m_conversation_id
    JOIN teamwork.projects p ON pc.tw_project_id = p.id
    LEFT JOIN project_extensions pe ON pe.tw_project_id = p.id
    LEFT JOIN missive.contacts c ON msg.from_contact_id = c.id
    WHERE eaf.status = 'pending'
      AND eaf.retry_count < p_max_retries
    ORDER BY eaf.missive_attachment_id, eaf.created_at ASC
    LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION suggest_nas_folder_names_for_project(
    p_tw_project_id INTEGER,
    p_limit INTEGER DEFAULT 80
)
RETURNS TABLE(folder_name TEXT, score REAL)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, teamwork, extensions
AS $$
    WITH proj AS (
        SELECT trim(name) AS pname FROM teamwork.projects WHERE id = p_tw_project_id
    ),
    folders AS (
        SELECT DISTINCT split_part(trim(leading '/' from f.full_path), '/', 3) AS folder_name
        FROM files f
        WHERE (f.full_path LIKE '/data/projekte/%' OR f.full_path LIKE '/data/projekte-erledigt/%')
          AND split_part(trim(leading '/' from f.full_path), '/', 3) <> ''
    )
    SELECT f.folder_name,
           similarity((SELECT pname FROM proj), f.folder_name)::REAL AS score
    FROM folders f
    WHERE (SELECT pname FROM proj) IS NOT NULL
    ORDER BY score DESC NULLS LAST, f.folder_name ASC
    LIMIT COALESCE(NULLIF(p_limit, 0), 80);
$$;

COMMENT ON COLUMN project_extensions.nas_folder_path IS 'NAS project directory name (one segment, e.g. 2021005-DESY-San-Heiz-MK). May include slashes; last segment is used. Drives attachment downloader + file/Craft linking when set.';
COMMENT ON COLUMN task_extensions.type_source_tag_name IS 'Teamwork tag that triggered task type; also used for Craft folder_path linking when project name does not match (see link_craft_document_to_project)';

GRANT EXECUTE ON FUNCTION get_pending_project_attachments(INTEGER, INTEGER) TO mad_downloader;
GRANT EXECUTE ON FUNCTION suggest_nas_folder_names_for_project(INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION suggest_nas_folder_names_for_project(INTEGER, INTEGER) TO service_role;
