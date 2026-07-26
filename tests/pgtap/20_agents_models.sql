-- agents + models: PUBLIC read; only service can write.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- ----- SELECT granted to everyone (PUBLIC read policy) -----------------------
SELECT ok( has_table_privilege('OpenWorld_anonymous','OpenWorld.agents','SELECT'),         'anonymous can SELECT agents');
SELECT ok( has_table_privilege('OpenWorld_authenticated','OpenWorld.agents','SELECT'),     'authenticated can SELECT agents');
SELECT ok( has_table_privilege('OpenWorld_agent_primary','OpenWorld.agents','SELECT'),     'primary can SELECT agents');
SELECT ok( has_table_privilege('OpenWorld_agent_sidecar','OpenWorld.agents','SELECT'),'sidecar can SELECT agents');
SELECT ok( has_table_privilege('OpenWorld_service','OpenWorld.agents','SELECT'),           'service can SELECT agents');
SELECT ok( has_table_privilege('OpenWorld_dashboard','OpenWorld.agents','SELECT'),         'dashboard can SELECT agents');
SELECT ok( has_table_privilege('OpenWorld_anonymous','OpenWorld.models','SELECT'),         'anonymous can SELECT models');

-- ----- writes are service-only ----------------------------------------------
SELECT ok( has_table_privilege('OpenWorld_service','OpenWorld.agents','INSERT,UPDATE,DELETE'), 'service can INSERT/UPDATE/DELETE agents');
SELECT ok( has_table_privilege('OpenWorld_service','OpenWorld.models','INSERT,UPDATE,DELETE'), 'service can INSERT/UPDATE/DELETE models');
SELECT ok( NOT has_table_privilege('OpenWorld_anonymous','OpenWorld.agents','INSERT'),         'anonymous CANNOT INSERT agents');
SELECT ok( NOT has_table_privilege('OpenWorld_anonymous','OpenWorld.agents','UPDATE'),         'anonymous CANNOT UPDATE agents');
SELECT ok( NOT has_table_privilege('OpenWorld_agent_primary','OpenWorld.agents','INSERT'),     'primary CANNOT INSERT agents');
SELECT ok( NOT has_table_privilege('OpenWorld_agent_primary','OpenWorld.models','UPDATE'),     'primary CANNOT UPDATE models');
SELECT ok( NOT has_table_privilege('OpenWorld_agent_primary','OpenWorld.agents','DELETE'),     'primary CANNOT DELETE agents');
SELECT ok( NOT has_table_privilege('OpenWorld_dashboard','OpenWorld.agents','INSERT'),         'dashboard CANNOT INSERT agents (read-only)');

-- ----- behavior: PUBLIC SELECT sees all rows ---------------------------------
SELECT is(pgtap_test.visible_count('OpenWorld_anonymous', $$SELECT 1 FROM OpenWorld.agents$$),         2::bigint, 'anonymous sees both agents');
SELECT is(pgtap_test.visible_count('OpenWorld_agent_primary', $$SELECT 1 FROM OpenWorld.agents$$),     2::bigint, 'primary sees both agents');
SELECT is(pgtap_test.visible_count('OpenWorld_service', $$SELECT 1 FROM OpenWorld.agents$$),           2::bigint, 'service sees both agents');
SELECT is(pgtap_test.visible_count('OpenWorld_dashboard', $$SELECT 1 FROM OpenWorld.agents$$),         2::bigint, 'dashboard sees both agents');

-- ----- behavior: service can create an agent; a tier/agent role cannot -------
SELECT ok(pgtap_test.can('OpenWorld_service',
  $$INSERT INTO OpenWorld.agents(slug, soul, model_id) SELECT 'svc-temp', 'x', id FROM OpenWorld.models LIMIT 1$$),
  'service can INSERT an agent');
SELECT ok(NOT pgtap_test.can('OpenWorld_agent_primary',
  $$INSERT INTO OpenWorld.agents(slug, soul, model_id) SELECT 'pri-temp', 'x', id FROM OpenWorld.models LIMIT 1$$),
  'primary CANNOT insert an agent');
SELECT ok(NOT pgtap_test.can('OpenWorld_anonymous',
  $$UPDATE OpenWorld.models SET name = name$$),
  'anonymous CANNOT update models');

SELECT * FROM finish();
ROLLBACK;
