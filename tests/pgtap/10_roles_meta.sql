-- Roles, flags, memberships, and the schema/sequence grants that back the matrix.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- ----- roles exist -----------------------------------------------------------
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'ow_anonymous'),         'role ow_anonymous exists');
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'ow_authenticated'),     'role ow_authenticated exists');
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'ow_agent_primary'),     'role ow_agent_primary exists');
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'ow_agent_sidecar'),'role ow_agent_sidecar exists');
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'ow_service'),           'role ow_service exists');
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'ow_dashboard'),         'role ow_dashboard exists');

-- ----- LOGIN flags (agent + dashboard are LOGIN; tiers + service are NOLOGIN) -
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'ow_anonymous'),         false, 'ow_anonymous is NOLOGIN');
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'ow_authenticated'),     false, 'ow_authenticated is NOLOGIN');
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'ow_agent_primary'),     true,  'ow_agent_primary is LOGIN');
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'ow_agent_sidecar'),true,  'ow_agent_sidecar is LOGIN');
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'ow_service'),           false, 'ow_service is NOLOGIN');
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'ow_dashboard'),         true,  'ow_dashboard is LOGIN');

-- ----- BYPASSRLS (only the trusted-compute + dashboard roles bypass RLS) -----
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'ow_anonymous'),         false, 'ow_anonymous is RLS-bound');
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'ow_authenticated'),     false, 'ow_authenticated is RLS-bound');
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'ow_agent_primary'),     false, 'ow_agent_primary is RLS-bound');
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'ow_agent_sidecar'),false, 'ow_agent_sidecar is RLS-bound');
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'ow_service'),           true,  'ow_service has BYPASSRLS');
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'ow_dashboard'),         true,  'ow_dashboard has BYPASSRLS');

-- ----- role memberships (the privilege-drop edges) ---------------------------
-- primary steps down to either user tier inside per-call tool instances;
-- sidecar steps down to ow_service.
SELECT ok(pg_has_role('ow_agent_primary', 'ow_anonymous', 'member'),      'primary is a member of ow_anonymous');
SELECT ok(pg_has_role('ow_agent_primary', 'ow_authenticated', 'member'),  'primary is a member of ow_authenticated');
SELECT ok(pg_has_role('ow_agent_sidecar', 'ow_service', 'member'),   'sidecar is a member of ow_service');
SELECT ok(NOT pg_has_role('ow_agent_primary', 'ow_service', 'member'),    'primary is NOT a member of service');
SELECT ok(NOT pg_has_role('ow_agent_sidecar', 'ow_anonymous', 'member'), 'sidecar is NOT a member of anonymous');

-- ----- deterministic agent-id guard -----------------------------------------
SELECT is((SELECT id FROM ow.agents WHERE slug = 'primary'),      1::bigint, 'primary agent id is 1 (suite assumes this)');
SELECT is((SELECT id FROM ow.agents WHERE slug = 'sidecar'), 2::bigint, 'sidecar agent id is 2 (suite assumes this)');

-- ----- schema USAGE ----------------------------------------------------------
-- tiers + service + agents get both schemas; dashboard gets them too.
SELECT ok( has_schema_privilege('ow_anonymous','ow','USAGE'),         'anonymous has USAGE on ow');
SELECT ok( has_schema_privilege('ow_authenticated','ow','USAGE'),     'authenticated has USAGE on ow');
SELECT ok( has_schema_privilege('ow_agent_primary','ow','USAGE'),     'primary has USAGE on ow');
SELECT ok( has_schema_privilege('ow_agent_sidecar','ow','USAGE'),'sidecar has USAGE on ow');
SELECT ok( has_schema_privilege('ow_service','ow','USAGE'),           'service has USAGE on ow');
SELECT ok( has_schema_privilege('ow_dashboard','ow','USAGE'),         'dashboard has USAGE on ow');
SELECT ok( has_schema_privilege('ow_anonymous','ow_tools','USAGE'),       'anonymous has USAGE on ow_tools');
SELECT ok( has_schema_privilege('ow_service','ow_tools','USAGE'),         'service has USAGE on ow_tools');
SELECT ok( has_schema_privilege('ow_dashboard','ow_tools','USAGE'),       'dashboard has USAGE on ow_tools');

-- ----- ffmpeg media page (read-only) -----------------------------------------
-- dashboard lists hls_playlists (joined to hls_segments) and renders a
-- per-row thumbnail via ffmpeg.thumbnail on the FIRST segment only. USAGE +
-- SELECT on the two tables + EXECUTE on the one transform used; no concat, no
-- INSERT, no sequences (it is read-only like the rest of the dashboard role).
SELECT ok( has_schema_privilege('ow_dashboard','ffmpeg','USAGE'),               'dashboard has USAGE on ffmpeg');
SELECT ok( has_table_privilege('ow_dashboard','ffmpeg.hls_playlists','SELECT'), 'dashboard can SELECT hls_playlists');
SELECT ok( has_table_privilege('ow_dashboard','ffmpeg.hls_segments','SELECT'),  'dashboard can SELECT hls_segments');
SELECT ok( has_function_privilege('ow_dashboard','ffmpeg.thumbnail(bytea,double precision,text)','EXECUTE'), 'dashboard can EXECUTE ffmpeg.thumbnail');
SELECT ok( NOT has_table_privilege('ow_dashboard','ffmpeg.hls_segments','INSERT'),  'dashboard CANNOT INSERT hls_segments (read-only)');

-- ----- sequence USAGE (only the roles that INSERT) ---------------------------
-- messages/memory/users seqs -> agent roles; agents/models/memory/users -> service.
SELECT ok( has_sequence_privilege('ow_agent_primary','ow.messages_id_seq','USAGE'),      'primary has USAGE on messages_id_seq');
SELECT ok( has_sequence_privilege('ow_agent_sidecar','ow.messages_id_seq','USAGE'),'sidecar has USAGE on messages_id_seq');
SELECT ok( has_sequence_privilege('ow_agent_primary','ow.users_id_seq','USAGE'),        'primary has USAGE on users_id_seq');
SELECT ok( has_sequence_privilege('ow_service','ow.agents_id_seq','USAGE'),             'service has USAGE on agents_id_seq');
SELECT ok( has_sequence_privilege('ow_service','ow.models_id_seq','USAGE'),             'service has USAGE on models_id_seq');
SELECT ok( NOT has_sequence_privilege('ow_anonymous','ow.messages_id_seq','USAGE'),     'anonymous has NO USAGE on messages_id_seq (no INSERT grant)');
SELECT ok( NOT has_sequence_privilege('ow_dashboard','ow.messages_id_seq','USAGE'),     'dashboard has NO USAGE on messages_id_seq (read-only)');

SELECT * FROM finish();
ROLLBACK;
