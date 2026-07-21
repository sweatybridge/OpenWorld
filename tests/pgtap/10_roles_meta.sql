-- Roles, flags, memberships, and the schema/sequence grants that back the matrix.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- ----- roles exist -----------------------------------------------------------
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'attobot_anonymous'),         'role attobot_anonymous exists');
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'attobot_authenticated'),     'role attobot_authenticated exists');
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'attobot_agent_primary'),     'role attobot_agent_primary exists');
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'attobot_agent_subconscious'),'role attobot_agent_subconscious exists');
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'attobot_service'),           'role attobot_service exists');
SELECT ok((SELECT rolname IS NOT NULL FROM pg_roles WHERE rolname = 'attobot_dashboard'),         'role attobot_dashboard exists');

-- ----- LOGIN flags (agent + dashboard are LOGIN; tiers + service are NOLOGIN) -
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'attobot_anonymous'),         false, 'attobot_anonymous is NOLOGIN');
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'attobot_authenticated'),     false, 'attobot_authenticated is NOLOGIN');
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'attobot_agent_primary'),     true,  'attobot_agent_primary is LOGIN');
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'attobot_agent_subconscious'),true,  'attobot_agent_subconscious is LOGIN');
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'attobot_service'),           false, 'attobot_service is NOLOGIN');
SELECT is((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'attobot_dashboard'),         true,  'attobot_dashboard is LOGIN');

-- ----- BYPASSRLS (only the trusted-compute + dashboard roles bypass RLS) -----
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'attobot_anonymous'),         false, 'attobot_anonymous is RLS-bound');
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'attobot_authenticated'),     false, 'attobot_authenticated is RLS-bound');
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'attobot_agent_primary'),     false, 'attobot_agent_primary is RLS-bound');
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'attobot_agent_subconscious'),false, 'attobot_agent_subconscious is RLS-bound');
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'attobot_service'),           true,  'attobot_service has BYPASSRLS');
SELECT is((SELECT rolbypassrls FROM pg_roles WHERE rolname = 'attobot_dashboard'),         true,  'attobot_dashboard has BYPASSRLS');

-- ----- role memberships (the privilege-drop edges) ---------------------------
-- primary steps down to either user tier inside per-call tool instances;
-- subconscious steps down to attobot_service.
SELECT ok(pg_has_role('attobot_agent_primary', 'attobot_anonymous', 'member'),      'primary is a member of attobot_anonymous');
SELECT ok(pg_has_role('attobot_agent_primary', 'attobot_authenticated', 'member'),  'primary is a member of attobot_authenticated');
SELECT ok(pg_has_role('attobot_agent_subconscious', 'attobot_service', 'member'),   'subconscious is a member of attobot_service');
SELECT ok(NOT pg_has_role('attobot_agent_primary', 'attobot_service', 'member'),    'primary is NOT a member of service');
SELECT ok(NOT pg_has_role('attobot_agent_subconscious', 'attobot_anonymous', 'member'), 'subconscious is NOT a member of anonymous');

-- ----- deterministic agent-id guard -----------------------------------------
SELECT is((SELECT id FROM attobot.agents WHERE slug = 'primary'),      1::bigint, 'primary agent id is 1 (suite assumes this)');
SELECT is((SELECT id FROM attobot.agents WHERE slug = 'subconscious'), 2::bigint, 'subconscious agent id is 2 (suite assumes this)');

-- ----- schema USAGE ----------------------------------------------------------
-- tiers + service + agents get both schemas; dashboard gets them too.
SELECT ok( has_schema_privilege('attobot_anonymous','attobot','USAGE'),         'anonymous has USAGE on attobot');
SELECT ok( has_schema_privilege('attobot_authenticated','attobot','USAGE'),     'authenticated has USAGE on attobot');
SELECT ok( has_schema_privilege('attobot_agent_primary','attobot','USAGE'),     'primary has USAGE on attobot');
SELECT ok( has_schema_privilege('attobot_agent_subconscious','attobot','USAGE'),'subconscious has USAGE on attobot');
SELECT ok( has_schema_privilege('attobot_service','attobot','USAGE'),           'service has USAGE on attobot');
SELECT ok( has_schema_privilege('attobot_dashboard','attobot','USAGE'),         'dashboard has USAGE on attobot');
SELECT ok( has_schema_privilege('attobot_anonymous','attotools','USAGE'),       'anonymous has USAGE on attotools');
SELECT ok( has_schema_privilege('attobot_service','attotools','USAGE'),         'service has USAGE on attotools');
SELECT ok( has_schema_privilege('attobot_dashboard','attotools','USAGE'),       'dashboard has USAGE on attotools');

-- ----- ffmpeg media page (read-only) -----------------------------------------
-- dashboard lists hls_playlists (joined to hls_segments) and renders a
-- per-row thumbnail via ffmpeg.thumbnail on the FIRST segment only. USAGE +
-- SELECT on the two tables + EXECUTE on the one transform used; no concat, no
-- INSERT, no sequences (it is read-only like the rest of the dashboard role).
SELECT ok( has_schema_privilege('attobot_dashboard','ffmpeg','USAGE'),               'dashboard has USAGE on ffmpeg');
SELECT ok( has_table_privilege('attobot_dashboard','ffmpeg.hls_playlists','SELECT'), 'dashboard can SELECT hls_playlists');
SELECT ok( has_table_privilege('attobot_dashboard','ffmpeg.hls_segments','SELECT'),  'dashboard can SELECT hls_segments');
SELECT ok( has_function_privilege('attobot_dashboard','ffmpeg.thumbnail(bytea,double precision,text)','EXECUTE'), 'dashboard can EXECUTE ffmpeg.thumbnail');
SELECT ok( NOT has_table_privilege('attobot_dashboard','ffmpeg.hls_segments','INSERT'),  'dashboard CANNOT INSERT hls_segments (read-only)');

-- ----- sequence USAGE (only the roles that INSERT) ---------------------------
-- messages/memory/users seqs -> agent roles; agents/models/memory/users -> service.
SELECT ok( has_sequence_privilege('attobot_agent_primary','attobot.messages_id_seq','USAGE'),      'primary has USAGE on messages_id_seq');
SELECT ok( has_sequence_privilege('attobot_agent_subconscious','attobot.messages_id_seq','USAGE'),'subconscious has USAGE on messages_id_seq');
SELECT ok( has_sequence_privilege('attobot_agent_primary','attobot.users_id_seq','USAGE'),        'primary has USAGE on users_id_seq');
SELECT ok( has_sequence_privilege('attobot_service','attobot.agents_id_seq','USAGE'),             'service has USAGE on agents_id_seq');
SELECT ok( has_sequence_privilege('attobot_service','attobot.models_id_seq','USAGE'),             'service has USAGE on models_id_seq');
SELECT ok( NOT has_sequence_privilege('attobot_anonymous','attobot.messages_id_seq','USAGE'),     'anonymous has NO USAGE on messages_id_seq (no INSERT grant)');
SELECT ok( NOT has_sequence_privilege('attobot_dashboard','attobot.messages_id_seq','USAGE'),     'dashboard has NO USAGE on messages_id_seq (read-only)');

SELECT * FROM finish();
ROLLBACK;
