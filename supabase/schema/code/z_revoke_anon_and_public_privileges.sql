-- Lock down anon and PUBLIC on every non-system schema:
--   - anon: no direct/default grants (PostgREST unauthenticated must not touch DB objects).
--   - PUBLIC: no implicit grants (anon/surprise roles lose table + routine access).
-- authenticated keeps RPCs via y_grant_authenticated_public_execute.sql (runs before this file).
-- Default privileges: objects created BY postgres do not grant to anon or PUBLIC.
-- Each REVOKE is isolated so vault (etc.) can fail on FUNCTIONS while TABLES still revoke.
-- Idempotent.

SET client_min_messages TO ERROR;

DO $$
DECLARE
  sch text;
  r name := 'anon';
BEGIN
  FOR sch IN
    SELECT nspname
    FROM pg_namespace
    WHERE nspname NOT LIKE 'pg\_%' ESCAPE '\'
      AND nspname <> 'information_schema'
    ORDER BY 1
  LOOP
    BEGIN EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM %I', sch, r);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM %I', sch, r);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM %I', sch, r);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN EXECUTE format('REVOKE ALL ON ALL ROUTINES IN SCHEMA %I FROM %I', sch, r);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN EXECUTE format('REVOKE ALL PRIVILEGES ON SCHEMA %I FROM %I', sch, r);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
END $$;

DO $$
DECLARE
  sch text;
BEGIN
  FOR sch IN
    SELECT nspname
    FROM pg_namespace
    WHERE nspname NOT LIKE 'pg\_%' ESCAPE '\'
      AND nspname <> 'information_schema'
    ORDER BY 1
  LOOP
    BEGIN EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC', sch);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM PUBLIC', sch);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC', sch);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN EXECUTE format('REVOKE ALL ON ALL ROUTINES IN SCHEMA %I FROM PUBLIC', sch);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN EXECUTE format('REVOKE ALL PRIVILEGES ON SCHEMA %I FROM PUBLIC', sch);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
END $$;

DO $$
DECLARE
  sch text;
BEGIN
  FOR sch IN
    SELECT nspname
    FROM pg_namespace
    WHERE nspname NOT LIKE 'pg\_%' ESCAPE '\'
      AND nspname <> 'information_schema'
    ORDER BY 1
  LOOP
    BEGIN EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I REVOKE ALL ON TABLES FROM anon',
      sch
    );
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    WHEN undefined_object THEN NULL;
    END;
    BEGIN EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I REVOKE ALL ON SEQUENCES FROM anon',
      sch
    );
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    WHEN undefined_object THEN NULL;
    END;
    BEGIN EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I REVOKE ALL ON FUNCTIONS FROM anon',
      sch
    );
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    WHEN undefined_object THEN NULL;
    END;
    BEGIN EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I REVOKE ALL ON ROUTINES FROM anon',
      sch
    );
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    WHEN undefined_object THEN NULL;
    END;

    BEGIN EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I REVOKE ALL ON TABLES FROM PUBLIC',
      sch
    );
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    WHEN undefined_object THEN NULL;
    END;
    BEGIN EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I REVOKE ALL ON SEQUENCES FROM PUBLIC',
      sch
    );
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    WHEN undefined_object THEN NULL;
    END;
    BEGIN EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I REVOKE ALL ON FUNCTIONS FROM PUBLIC',
      sch
    );
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    WHEN undefined_object THEN NULL;
    END;
    BEGIN EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I REVOKE ALL ON ROUTINES FROM PUBLIC',
      sch
    );
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    WHEN undefined_object THEN NULL;
    END;
  END LOOP;
END $$;

-- mcp_readonly: no longer inherits PUBLIC execute; grant all public RPCs then strip writes (was rls.sql)
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO mcp_readonly;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA public TO mcp_readonly;

REVOKE EXECUTE ON FUNCTION rerun_all_task_type_extractions() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_person_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_project_conversation_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_cost_group_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_location_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_file_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION rerun_all_craft_linking() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION purge_excluded_teamwork_data() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION get_or_create_location(TEXT, TEXT, TEXT) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION get_or_create_cost_group(INTEGER, TEXT) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION link_file_to_project(UUID) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION link_craft_document_to_project(TEXT) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_locations_for_task(INTEGER) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_locations_for_conversation(UUID) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_cost_groups_for_task(INTEGER) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_cost_groups_for_conversation(UUID) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_cost_groups_for_file(UUID) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_file_metadata(UUID) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION extract_craft_metadata(TEXT) FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION trigger_extract_file_metadata() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION trigger_extract_craft_metadata() FROM mcp_readonly;
REVOKE EXECUTE ON FUNCTION trigger_delete_s3_content() FROM mcp_readonly;

RESET client_min_messages;
