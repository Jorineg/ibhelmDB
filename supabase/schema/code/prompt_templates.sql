-- =====================================
-- PROMPT TEMPLATES: Functions & Triggers
-- =====================================
-- All statements are idempotent (CREATE OR REPLACE, DROP IF EXISTS)

-- =====================================
-- 1. NOTIFY TRIGGER (cache invalidation)
-- =====================================

CREATE OR REPLACE FUNCTION notify_prompt_template_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('prompt_templates_changed', COALESCE(NEW.id, OLD.id));
    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_prompt_template_notify ON prompt_templates;
CREATE TRIGGER trg_prompt_template_notify
    AFTER INSERT OR UPDATE OR DELETE ON prompt_templates
    FOR EACH ROW EXECUTE FUNCTION notify_prompt_template_change();

-- =====================================
-- 2. VALIDATION TRIGGER (inclusion hierarchy)
-- =====================================
-- Enforces the DAG: prompt → skill → doc, prompt → doc
-- Docs: no directives at all
-- Skills: can include docs and use {{sql:}}, no skills/prompts/variables
-- Prompts: can include skills and docs, no other prompts

CREATE OR REPLACE FUNCTION _check_skill_cycle(p_from TEXT, p_target TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    match_arr TEXT[];
    tid TEXT;
    c TEXT;
BEGIN
    SELECT replace(content, E'\\{{', '') INTO c FROM prompt_templates WHERE id = p_target;
    IF c IS NULL THEN RETURN FALSE; END IF;
    FOR match_arr IN SELECT regexp_matches(c, '\{\{include:(skill\.[^}]+)\}\}', 'g')
    LOOP
        tid := trim(match_arr[1]);
        IF tid = p_from THEN RETURN TRUE; END IF;
        IF _check_skill_cycle(p_from, tid) THEN RETURN TRUE; END IF;
    END LOOP;
    RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION validate_prompt_template()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    c TEXT;
    has_include_prompt BOOLEAN;
    has_include_skill BOOLEAN;
    has_include_any BOOLEAN;
    has_sql BOOLEAN;
    has_vars BOOLEAN;
    match_arr TEXT[];
    tid TEXT;
    target_cat TEXT;
BEGIN
    c := NEW.content;

    -- Strip escaped sequences for detection
    c := replace(replace(c, E'\\{{', ''), E'\\${', '');

    has_include_any   := c ~ '\{\{include:';
    has_include_prompt := c ~ '\{\{include:prompt\.';
    has_include_skill  := c ~ '\{\{include:skill\.';
    has_sql            := c ~ '\{\{sql:';
    has_vars           := c ~ '\$\{[a-zA-Z_]';

    IF NEW.category = 'doc' THEN
        IF has_include_any THEN
            RAISE EXCEPTION 'Docs cannot contain {{include:}} directives (id: %)', NEW.id;
        END IF;
        IF has_sql THEN
            RAISE EXCEPTION 'Docs cannot contain {{sql:}} directives (id: %)', NEW.id;
        END IF;
        IF has_vars THEN
            RAISE EXCEPTION 'Docs cannot contain ${variable} directives (id: %)', NEW.id;
        END IF;

    ELSIF NEW.category = 'skill' THEN
        IF has_include_prompt THEN
            RAISE EXCEPTION 'Skills cannot include prompts (id: %)', NEW.id;
        END IF;
        IF has_vars THEN
            RAISE EXCEPTION 'Skills cannot contain ${variable} directives (id: %)', NEW.id;
        END IF;
        -- Skills CAN include docs, other skills, and use {{sql:}}

    ELSIF NEW.category = 'prompt' THEN
        IF has_include_prompt THEN
            RAISE EXCEPTION 'Prompts cannot include other prompts (id: %)', NEW.id;
        END IF;
    END IF;

    -- Validate include targets and detect cycles
    FOR match_arr IN SELECT regexp_matches(c, '\{\{include:([^}]+)\}\}', 'g')
    LOOP
        tid := trim(match_arr[1]);
        SELECT category INTO target_cat FROM prompt_templates WHERE id = tid;
        IF target_cat IS NOT NULL THEN
            IF NEW.category = 'skill' AND target_cat = 'prompt' THEN
                RAISE EXCEPTION 'Skill "%" cannot include prompt "%"', NEW.id, tid;
            END IF;
            -- Cycle detection for skill→skill
            IF NEW.category = 'skill' AND target_cat = 'skill' THEN
                IF _check_skill_cycle(NEW.id, tid) THEN
                    RAISE EXCEPTION 'Circular skill reference: "%" → "%" → ... → "%"', NEW.id, tid, NEW.id;
                END IF;
            END IF;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prompt_template_validate ON prompt_templates;
CREATE TRIGGER trg_prompt_template_validate
    BEFORE INSERT OR UPDATE ON prompt_templates
    FOR EACH ROW EXECUTE FUNCTION validate_prompt_template();

-- =====================================
-- 3. DEPENDENCY HELPERS (for UI)
-- =====================================

CREATE OR REPLACE FUNCTION get_prompt_template_dependencies(p_id TEXT)
RETURNS TEXT[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        array_agg(DISTINCT m[1] ORDER BY m[1]),
        ARRAY[]::TEXT[]
    )
    FROM prompt_templates,
         regexp_matches(content, '\{\{include:([^}]+)\}\}', 'g') AS m
    WHERE id = p_id;
$$;

CREATE OR REPLACE FUNCTION get_prompt_template_used_by(p_id TEXT)
RETURNS TEXT[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(id ORDER BY id), ARRAY[]::TEXT[])
    FROM prompt_templates
    WHERE content LIKE '%{{include:' || p_id || '}}%';
$$;

GRANT EXECUTE ON FUNCTION get_prompt_template_dependencies(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_prompt_template_used_by(TEXT) TO authenticated;

-- =====================================
-- 4. FUNCTION INDEX HELPER
-- =====================================
-- Collects all py_functions and db_functions from skills included by a prompt.

CREATE OR REPLACE FUNCTION get_prompt_functions(p_prompt_id TEXT)
RETURNS TABLE(py_fns TEXT[], db_fns TEXT[]) LANGUAGE sql STABLE AS $$
    WITH RECURSIVE all_skills AS (
        -- Direct skill includes from the prompt
        SELECT DISTINCT trim(m[1]) AS skill_id
        FROM prompt_templates pt,
             regexp_matches(pt.content, '\{\{include:(skill\.[^}]+)\}\}', 'g') AS m
        WHERE pt.id = p_prompt_id
        UNION
        -- Transitive skill includes (skill→skill)
        SELECT DISTINCT trim(m[1])
        FROM all_skills a
        JOIN prompt_templates pt ON pt.id = a.skill_id,
             regexp_matches(pt.content, '\{\{include:(skill\.[^}]+)\}\}', 'g') AS m
    )
    SELECT
        COALESCE((SELECT array_agg(DISTINCT fn ORDER BY fn) FROM all_skills s JOIN prompt_templates pt ON pt.id = s.skill_id, unnest(pt.py_functions) fn), ARRAY[]::TEXT[]),
        COALESCE((SELECT array_agg(DISTINCT fn ORDER BY fn) FROM all_skills s JOIN prompt_templates pt ON pt.id = s.skill_id, unnest(pt.db_functions) fn), ARRAY[]::TEXT[]);
$$;

GRANT EXECUTE ON FUNCTION get_prompt_functions(TEXT) TO authenticated, service_role;

-- =====================================
-- 5. TEMPLATE RESOLVER
-- =====================================
-- Resolves three directive types in order:
--   1. {{include:template_id}} — recursive (DAG enforced by trigger, depth ≤ 3 in practice)
--   2. ${runtime_var} — replaced from caller-provided JSONB
--   3. {{sql:query |||prefix|||fallback}} — execute read-only SQL, format result
-- Escaped directives: \{{ and \${ are preserved as literals.

-- Escape placeholders (used during resolution to protect escaped directives)
-- Using Unicode private-use chars to avoid any collision with real content
CREATE OR REPLACE FUNCTION _resolve_tpl_includes(
    p_content TEXT, p_depth INT
) RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    content  TEXT := p_content;
    full_match TEXT;
    tid      TEXT;
    included TEXT;
    replacement TEXT;
    pos      INT;
BEGIN
    IF p_depth > 10 THEN RETURN content; END IF;

    LOOP
        full_match := regexp_substr(content, '\{\{include:[^}]+\}\}');
        EXIT WHEN full_match IS NULL;

        tid := trim(substring(full_match FROM 11 FOR length(full_match) - 12));

        SELECT pt.content INTO included FROM public.prompt_templates pt WHERE pt.id = tid;
        IF included IS NULL THEN
            replacement := '{{error: template "' || tid || '" not found}}';
        ELSE
            included := replace(replace(included,
                E'\\{{', '__TPL_ESC_BRACE__'),
                E'\\${', '__TPL_ESC_DOLLAR__');
            replacement := _resolve_tpl_includes(included, p_depth + 1);
        END IF;

        pos := position(full_match IN content);
        content := left(content, pos - 1) || replacement || substr(content, pos + length(full_match));
    END LOOP;

    RETURN content;
END;
$$;

-- Variable substitution from JSONB
CREATE OR REPLACE FUNCTION _resolve_tpl_vars(p_content TEXT, p_vars JSONB)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    content TEXT := p_content;
    var_key TEXT;
    var_val TEXT;
BEGIN
    IF p_vars IS NULL OR p_vars = '{}'::jsonb THEN RETURN content; END IF;
    FOR var_key, var_val IN SELECT key, value FROM jsonb_each_text(p_vars)
    LOOP
        content := replace(content, '${' || var_key || '}', COALESCE(var_val, ''));
    END LOOP;
    RETURN content;
END;
$$;

-- SQL directive execution with TOON formatting
CREATE OR REPLACE FUNCTION _resolve_tpl_sql(p_content TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    result    TEXT := '';
    remaining TEXT := p_content;
    full_match TEXT;
    pos       INT;
    block     TEXT;
    parts     TEXT[];
    query     TEXT;
    prefix    TEXT;
    fallback  TEXT;
    sql_out   TEXT;
BEGIN
    LOOP
        full_match := regexp_substr(remaining, '\{\{sql:.*?\}\}', 1, 1, 's');
        EXIT WHEN full_match IS NULL;

        pos := position(full_match IN remaining);
        result := result || left(remaining, pos - 1);

        block := trim(substring(full_match FROM 7 FOR length(full_match) - 8));
        parts := string_to_array(block, '|||');
        query := trim(parts[1]);
        prefix := CASE WHEN array_length(parts, 1) >= 2 THEN trim(parts[2]) ELSE NULL END;
        fallback := CASE WHEN array_length(parts, 1) >= 3 THEN trim(parts[3]) ELSE NULL END;

        sql_out := _exec_tpl_sql(query);

        IF sql_out IS NOT NULL AND sql_out != '' THEN
            IF prefix IS NOT NULL AND prefix != '' THEN
                sql_out := prefix || E'\n' || sql_out;
            END IF;
        ELSE
            sql_out := COALESCE(fallback, '');
        END IF;

        result := result || sql_out;
        remaining := substr(remaining, pos + length(full_match));
    END LOOP;

    RETURN result || remaining;
END;
$$;

-- Execute a single SQL directive, return formatted text
CREATE OR REPLACE FUNCTION _exec_tpl_sql(p_query TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    q         TEXT;
    q_upper   TEXT;
    json_result JSON;
    col_names TEXT[];
    row_count INT;
    col_count INT;
    val_text  TEXT;
    val_json  JSON;
    formatted TEXT;
    row_json  JSON;
    cells     TEXT[];
    i INT;
    j INT;
BEGIN
    q := trim(trailing ';' FROM trim(p_query));
    q_upper := upper(ltrim(q));
    IF NOT (q_upper LIKE 'SELECT%' OR q_upper LIKE 'WITH%') THEN
        RETURN '{{sql_error: only SELECT/WITH queries allowed}}';
    END IF;

    BEGIN
        EXECUTE format('SELECT json_agg(row_to_json(sub)) FROM (%s) sub', q) INTO json_result;
    EXCEPTION WHEN OTHERS THEN
        RETURN '{{sql_error: ' || SQLERRM || '}}';
    END;

    IF json_result IS NULL THEN RETURN NULL; END IF;

    row_count := json_array_length(json_result);
    SELECT array_agg(key ORDER BY ordinality) INTO col_names
    FROM json_object_keys(json_result->0) WITH ORDINALITY AS t(key, ordinality);
    col_count := array_length(col_names, 1);

    IF row_count = 1 AND col_count = 1 THEN
        val_text := json_result->0->>col_names[1];
        IF val_text IS NULL THEN RETURN NULL; END IF;
        IF val_text ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' THEN
            val_text := replace(left(val_text, 16), 'T', ' ');
        END IF;
        RETURN val_text;
    END IF;

    formatted := 'rows[' || row_count || ']{' || array_to_string(col_names, ',') || '}:';
    FOR i IN 0..row_count - 1 LOOP
        row_json := json_result->i;
        cells := ARRAY[]::TEXT[];
        FOR j IN 1..col_count LOOP
            val_json := row_json->col_names[j];
            val_text := row_json->>col_names[j];

            IF val_text IS NULL THEN
                cells := array_append(cells, '∅');
            ELSIF json_typeof(val_json) = 'boolean' THEN
                cells := array_append(cells, CASE WHEN val_text = 'true' THEN 'T' ELSE 'F' END);
            ELSIF json_typeof(val_json) = 'string' THEN
                IF val_text ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' THEN
                    val_text := replace(left(val_text, 16), 'T', ' ');
                ELSIF val_text ~ '^\d{2}:\d{2}:\d{2}$' THEN
                    val_text := left(val_text, 5);
                END IF;
                val_text := replace(replace(replace(val_text, E'\r', ''), E'\n', '↵'), E'\t', '→');
                IF position(',' IN val_text) > 0 OR position('"' IN val_text) > 0 THEN
                    val_text := '"' || replace(val_text, '"', '""') || '"';
                END IF;
                cells := array_append(cells, val_text);
            ELSE
                cells := array_append(cells, val_text);
            END IF;
        END LOOP;
        formatted := formatted || E'\n  ' || array_to_string(cells, ',');
    END LOOP;

    RETURN formatted;
END;
$$;

-- ---------------------------------------------------------------------------
-- Public API: resolve a stored template by ID
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION resolve_prompt_template(
    p_template_id TEXT,
    p_vars JSONB DEFAULT '{}'::JSONB
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    content TEXT;
BEGIN
    SELECT pt.content INTO content FROM public.prompt_templates pt WHERE pt.id = p_template_id;
    IF content IS NULL THEN
        RETURN '{{error: template "' || p_template_id || '" not found}}';
    END IF;

    content := replace(replace(content, E'\\{{', '__TPL_ESC_BRACE__'), E'\\${', '__TPL_ESC_DOLLAR__');
    content := _resolve_tpl_includes(content, 0);
    content := _resolve_tpl_vars(content, p_vars);
    content := _resolve_tpl_sql(content);
    content := replace(replace(content, '__TPL_ESC_BRACE__', '{{'), '__TPL_ESC_DOLLAR__', '${');
    RETURN content;
END;
$$;

-- ---------------------------------------------------------------------------
-- Public API: resolve arbitrary text with directives
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION resolve_prompt_template_raw(
    p_content TEXT,
    p_vars JSONB DEFAULT '{}'::JSONB
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    content TEXT;
BEGIN
    content := replace(replace(p_content, E'\\{{', '__TPL_ESC_BRACE__'), E'\\${', '__TPL_ESC_DOLLAR__');
    content := _resolve_tpl_includes(content, 0);
    content := _resolve_tpl_vars(content, p_vars);
    content := _resolve_tpl_sql(content);
    content := replace(replace(content, '__TPL_ESC_BRACE__', '{{'), '__TPL_ESC_DOLLAR__', '${');
    RETURN content;
END;
$$;

GRANT EXECUTE ON FUNCTION resolve_prompt_template(TEXT, JSONB) TO authenticated, service_role, mcp_readonly;
GRANT EXECUTE ON FUNCTION resolve_prompt_template_raw(TEXT, JSONB) TO authenticated, service_role, mcp_readonly;
