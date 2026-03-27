-- =====================================
-- PROMPT TEMPLATES: Functions & Triggers
-- =====================================
-- All statements are idempotent (CREATE OR REPLACE, DROP IF EXISTS)

-- =====================================
-- 1. NOTIFY FUNCTION (cache invalidation)
-- =====================================

CREATE OR REPLACE FUNCTION notify_prompt_template_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('prompt_templates_changed', COALESCE(NEW.id, OLD.id));
    RETURN COALESCE(NEW, OLD);
END;
$$;

-- =====================================
-- 2. DEPENDENCY HELPERS (for UI)
-- =====================================

-- Which templates does this template include?
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

-- Which templates include this template?
CREATE OR REPLACE FUNCTION get_prompt_template_used_by(p_id TEXT)
RETURNS TEXT[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(id ORDER BY id), ARRAY[]::TEXT[])
    FROM prompt_templates
    WHERE content LIKE '%{{include:' || p_id || '}}%';
$$;

GRANT EXECUTE ON FUNCTION get_prompt_template_dependencies(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_prompt_template_used_by(TEXT) TO authenticated;
