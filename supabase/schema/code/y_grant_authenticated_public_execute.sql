-- Most public-schema RPCs are executable via the PUBLIC pseudo-role only (no GRANT TO authenticated).
-- z_revoke_anon_and_public_privileges.sql revokes EXECUTE from PUBLIC; without this, PostgREST breaks for logged-in users.
-- Idempotent.

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA public TO authenticated;
