-- =============================================================================
-- pgTAP setup for the OpenWorld RBAC / RLS permission-matrix suite.
-- Loaded once (committed) before pg_prove runs the [1-9]*.sql test files.
-- =============================================================================
-- The matrix under test is the one ENFORCED by
-- docker-entrypoint-initdb.d/40-ow-rbac.sql (+ dashboard/dashboard-role.sql
-- for ow_dashboard). It matches docs/abac-rls-security-design.md §7 and the
-- docs/ARCHITECTURE.md access matrix; tests/README.md notes the few cells whose
-- least-privilege shape is non-obvious.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE SCHEMA IF NOT EXISTS pgtap_test;

-- The two AFTER-INSERT triggers on ow.messages call df.start (a durable
-- workflow) on insert. They are orthogonal to GRANT/RLS and would abort
-- superuser fixture inserts (pg_durable forbids superuser-owned instances) and
-- turn every INSERT-capability test into a durable side effect. Disable them
-- for the whole test database; the suite concerns itself only with privileges
-- and row-level security, not the loop machinery.
ALTER TABLE ow.messages DISABLE TRIGGER messages_outbound_send_trigger;
ALTER TABLE ow.messages DISABLE TRIGGER messages_user_loop_trigger;

-- -----------------------------------------------------------------------------
-- Helpers. Both SET ROLE to a capability role, run the statement, and ALWAYS
-- RESET ROLE (success and error paths) so the dropped role never leaks back to
-- the superuser test session. They are SECURITY INVOKER (SET ROLE is forbidden
-- inside SECURITY DEFINER) and rely on the caller being a superuser.
--
-- GUCs (ow.current_agent_id, .current_chat_id, .current_user_id) are set
-- by the caller with set_config(..., true) immediately before each call; they
-- are transaction-local and therefore visible inside the helper's EXECUTE.
-- -----------------------------------------------------------------------------

-- Rows visible to p_role through p_sql (a SELECT).
--  -1  => the statement raised (e.g. no GRANT -> permission denied)
--   0  => GRANT exists but RLS filtered every row out (default-deny)
--  >0  => visible rows
CREATE OR REPLACE FUNCTION pgtap_test.visible_count(p_role text, p_sql text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    n bigint;
BEGIN
    EXECUTE format('SET ROLE %I', p_role);
    EXECUTE 'SELECT count(*)::bigint FROM (' || p_sql || ') q' INTO n;
    EXECUTE 'RESET ROLE';
    RETURN coalesce(n, 0);
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN -1;
END;
$$;

-- Whether p_dml (an INSERT/UPDATE/DELETE) succeeds as p_role.
-- true => allowed by GRANT + RLS USING/WITH CHECK; false => denied.
CREATE OR REPLACE FUNCTION pgtap_test.can(p_role text, p_dml text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
    EXECUTE format('SET ROLE %I', p_role);
    EXECUTE p_dml;
    EXECUTE 'RESET ROLE';
    RETURN true;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN false;
END;
$$;
