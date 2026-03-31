-- Test suite for prompt_templates: resolver, validation trigger, function index
-- Run after applying schema changes. Inspect output for correctness.

-- ============================================================
-- 1. Basic: resolve_prompt_template_raw with no directives
-- ============================================================
SELECT '=== Test 1: plain text ===' AS test;
SELECT resolve_prompt_template_raw('Hello world, no directives here.');
-- Expected: "Hello world, no directives here."

-- ============================================================
-- 2. Variable substitution
-- ============================================================
SELECT '=== Test 2: variable substitution ===' AS test;
SELECT resolve_prompt_template_raw(
    'Hello ${name}, your email is ${email}.',
    '{"name": "Alice", "email": "alice@example.com"}'::jsonb
);
-- Expected: "Hello Alice, your email is alice@example.com."

-- ============================================================
-- 3. Unmatched variables left as-is
-- ============================================================
SELECT '=== Test 3: unmatched variables ===' AS test;
SELECT resolve_prompt_template_raw('Hello ${name}, ${unknown} here.', '{"name": "Bob"}'::jsonb);
-- Expected: "Hello Bob, ${unknown} here."

-- ============================================================
-- 4. SQL directive — single scalar
-- ============================================================
SELECT '=== Test 4: SQL scalar ===' AS test;
SELECT resolve_prompt_template_raw('Today is {{sql: SELECT current_date::text}}.');
-- Expected: "Today is YYYY-MM-DD."

-- ============================================================
-- 5. SQL directive — with prefix and fallback (has results)
-- ============================================================
SELECT '=== Test 5: SQL with prefix ===' AS test;
SELECT resolve_prompt_template_raw(
    'Projects: {{sql: SELECT name FROM teamwork.projects WHERE status = ''active'' LIMIT 3 ||| Active: ||| (none)}}'
);
-- Expected: "Projects: Active:\n..." (with project names)

-- ============================================================
-- 6. SQL directive — fallback (no results)
-- ============================================================
SELECT '=== Test 6: SQL fallback ===' AS test;
SELECT resolve_prompt_template_raw(
    '{{sql: SELECT name FROM teamwork.projects WHERE id = -999 ||| Found: ||| (No such project)}}'
);
-- Expected: "(No such project)"

-- ============================================================
-- 7. SQL directive — multi-row TOON table
-- ============================================================
SELECT '=== Test 7: SQL TOON table ===' AS test;
SELECT resolve_prompt_template_raw(
    '{{sql: SELECT id, title FROM prompt_templates ORDER BY id LIMIT 3}}'
);
-- Expected: "rows[3]{id,title}:\n  ..."

-- ============================================================
-- 8. Escaped directives preserved
-- ============================================================
SELECT '=== Test 8: escaped directives ===' AS test;
SELECT resolve_prompt_template_raw(E'Show literal: \\{{include:foo}} and \\${var}');
-- Expected: "Show literal: {{include:foo}} and ${var}"

-- ============================================================
-- 9. Include — not found
-- ============================================================
SELECT '=== Test 9: include not found ===' AS test;
SELECT resolve_prompt_template_raw('{{include:nonexistent.template}}');
-- Expected: '{{error: template "nonexistent.template" not found}}'

-- ============================================================
-- 10. Validation: doc cannot have directives
-- ============================================================
SELECT '=== Test 10: doc rejects include ===' AS test;
DO $$
BEGIN
    INSERT INTO prompt_templates (id, title, category, content)
    VALUES ('doc.test-bad', 'test', 'doc', '{{include:doc.test-bad}}');
    RAISE NOTICE 'FAIL: should have raised exception';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

SELECT '=== Test 10b: doc rejects sql ===' AS test;
DO $$
BEGIN
    INSERT INTO prompt_templates (id, title, category, content)
    VALUES ('doc.test-bad2', 'test', 'doc', '{{sql: SELECT 1}}');
    RAISE NOTICE 'FAIL: should have raised exception';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

SELECT '=== Test 10c: doc rejects vars ===' AS test;
DO $$
BEGIN
    INSERT INTO prompt_templates (id, title, category, content)
    VALUES ('doc.test-bad3', 'test', 'doc', '${some_var}');
    RAISE NOTICE 'FAIL: should have raised exception';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

-- ============================================================
-- 11. Validation: skill cannot include skills/prompts or use vars
-- ============================================================
SELECT '=== Test 11: skill rejects prompt include ===' AS test;
DO $$
BEGIN
    INSERT INTO prompt_templates (id, title, category, content)
    VALUES ('skill.test-bad', 'test', 'skill', '{{include:prompt.chat-system}}');
    RAISE NOTICE 'FAIL: should have raised exception';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

SELECT '=== Test 11b: skill rejects vars ===' AS test;
DO $$
BEGIN
    INSERT INTO prompt_templates (id, title, category, content)
    VALUES ('skill.test-bad3', 'test', 'skill', '${user_name}');
    RAISE NOTICE 'FAIL: should have raised exception';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

-- ============================================================
-- 11c. Validation: skill CAN include other skills (should succeed)
-- ============================================================
SELECT '=== Test 11c: skill includes skill (allowed) ===' AS test;
INSERT INTO prompt_templates (id, title, category, content)
VALUES ('skill.test-base', 'Base Skill', 'skill', 'base content')
ON CONFLICT (id) DO UPDATE SET content = EXCLUDED.content;
DO $$
BEGIN
    INSERT INTO prompt_templates (id, title, category, content)
    VALUES ('skill.test-includes-skill', 'Skill With Skill', 'skill', '{{include:skill.test-base}}')
    ON CONFLICT (id) DO UPDATE SET content = EXCLUDED.content;
    RAISE NOTICE 'OK: skill→skill include accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'FAIL: %', SQLERRM;
END;
$$;

-- ============================================================
-- 11d. Validation: circular skill reference detected
-- ============================================================
SELECT '=== Test 11d: circular skill reference ===' AS test;
DO $$
BEGIN
    UPDATE prompt_templates SET content = '{{include:skill.test-includes-skill}}'
    WHERE id = 'skill.test-base';
    RAISE NOTICE 'FAIL: should have detected circular reference';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;
DELETE FROM prompt_templates WHERE id IN ('skill.test-base', 'skill.test-includes-skill');

-- ============================================================
-- 12. Validation: prompt cannot include prompts
-- ============================================================
SELECT '=== Test 12: prompt rejects prompt include ===' AS test;
DO $$
BEGIN
    INSERT INTO prompt_templates (id, title, category, content)
    VALUES ('prompt.test-bad', 'test', 'prompt', '{{include:prompt.other}}');
    RAISE NOTICE 'FAIL: should have raised exception';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

-- ============================================================
-- 13. Validation: ID prefix must match category
-- ============================================================
SELECT '=== Test 13: ID prefix mismatch ===' AS test;
DO $$
BEGIN
    INSERT INTO prompt_templates (id, title, category, content)
    VALUES ('wrong.prefix', 'test', 'skill', 'content');
    RAISE NOTICE 'FAIL: should have raised exception';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

-- ============================================================
-- 14. Validation: prompt_role only for prompts
-- ============================================================
SELECT '=== Test 14: prompt_role on skill rejected ===' AS test;
DO $$
BEGIN
    INSERT INTO prompt_templates (id, title, category, content, prompt_role)
    VALUES ('skill.test-role', 'test', 'skill', 'content', 'system');
    RAISE NOTICE 'FAIL: should have raised exception';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

-- ============================================================
-- 15. Validation: functions only for skills
-- ============================================================
SELECT '=== Test 15: functions on doc rejected ===' AS test;
DO $$
BEGIN
    INSERT INTO prompt_templates (id, title, category, content, db_functions)
    VALUES ('doc.test-fns', 'test', 'doc', 'content', ARRAY['some_fn']);
    RAISE NOTICE 'FAIL: should have raised exception';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

-- ============================================================
-- 16. Valid inserts should succeed
-- ============================================================
SELECT '=== Test 16: valid doc ===' AS test;
INSERT INTO prompt_templates (id, title, category, content)
VALUES ('doc.test-valid', 'Valid Doc', 'doc', 'Pure text, no directives.')
ON CONFLICT (id) DO UPDATE SET content = EXCLUDED.content;
SELECT 'OK: inserted doc.test-valid';

SELECT '=== Test 16b: valid skill with doc include and sql ===' AS test;
INSERT INTO prompt_templates (id, title, category, content, db_functions, py_functions)
VALUES ('skill.test-dep', 'Dep Skill', 'skill',
        '## Dependency\n{{include:doc.test-valid}}',
        ARRAY['dep_fn'], ARRAY[])
ON CONFLICT (id) DO UPDATE SET content = EXCLUDED.content, db_functions = EXCLUDED.db_functions, py_functions = EXCLUDED.py_functions;

INSERT INTO prompt_templates (id, title, category, content, db_functions, py_functions)
VALUES ('skill.test-valid', 'Valid Skill', 'skill',
        '## Skill\n{{include:doc.test-valid}}\n{{include:skill.test-dep}}\n{{sql: SELECT 1}}',
        ARRAY['some_fn'], ARRAY['bridge_fn'])
ON CONFLICT (id) DO UPDATE SET content = EXCLUDED.content, db_functions = EXCLUDED.db_functions, py_functions = EXCLUDED.py_functions;
SELECT 'OK: inserted skill.test-valid (includes skill.test-dep)';

SELECT '=== Test 16c: valid prompt ===' AS test;
INSERT INTO prompt_templates (id, title, category, content, prompt_role)
VALUES ('prompt.test-valid', 'Valid Prompt', 'prompt',
        'You are ${role}.\n{{include:skill.test-valid}}\n{{include:doc.test-valid}}\n{{sql: SELECT 1}}',
        'system')
ON CONFLICT (id) DO UPDATE SET content = EXCLUDED.content, prompt_role = EXCLUDED.prompt_role;
SELECT 'OK: inserted prompt.test-valid';

-- ============================================================
-- 17. Function index helper
-- ============================================================
SELECT '=== Test 17: get_prompt_functions ===' AS test;
SELECT * FROM get_prompt_functions('prompt.test-valid');
-- Expected: py_fns = {bridge_fn}, db_fns = {dep_fn,some_fn} (aggregated from both skills)

-- ============================================================
-- 18. Resolve the test prompt
-- ============================================================
SELECT '=== Test 18: resolve test prompt ===' AS test;
SELECT resolve_prompt_template('prompt.test-valid', '{"role": "assistant"}'::jsonb);
-- Expected: "You are assistant.\n## Skill\nPure text, no directives.\n1\nPure text, no directives.\n1"

-- ============================================================
-- 19. Smoke test all stored templates
-- ============================================================
SELECT '=== Test 19: smoke test all templates ===' AS test;
SELECT
    id,
    CASE
        WHEN resolved LIKE '%{{error:%' THEN 'HAS_ERROR: ' || substring(resolved FROM '\{\{error:[^}]+\}\}')
        WHEN resolved LIKE '%{{sql_error:%' THEN 'SQL_ERROR: ' || substring(resolved FROM '\{\{sql_error:[^}]+\}\}')
        ELSE 'OK (' || length(resolved) || ' chars)'
    END AS status
FROM (
    SELECT id, resolve_prompt_template(id) AS resolved
    FROM prompt_templates
    WHERE category IN ('prompt', 'skill')
) t
ORDER BY id;

-- ============================================================
-- Cleanup test data
-- ============================================================
DELETE FROM prompt_templates WHERE id IN ('prompt.test-valid', 'skill.test-valid', 'skill.test-dep', 'doc.test-valid');
SELECT 'Cleaned up test data';
