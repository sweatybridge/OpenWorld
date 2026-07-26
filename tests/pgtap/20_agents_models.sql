-- agents + models: PUBLIC read; only service can write.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- ----- SELECT granted to everyone (PUBLIC read policy) -----------------------
SELECT ok( has_table_privilege('ow_anonymous','ow.agents','SELECT'),         'anonymous can SELECT agents');
SELECT ok( has_table_privilege('ow_authenticated','ow.agents','SELECT'),     'authenticated can SELECT agents');
SELECT ok( has_table_privilege('ow_agent_primary','ow.agents','SELECT'),     'primary can SELECT agents');
SELECT ok( has_table_privilege('ow_agent_sidecar','ow.agents','SELECT'),'sidecar can SELECT agents');
SELECT ok( has_table_privilege('ow_service','ow.agents','SELECT'),           'service can SELECT agents');
SELECT ok( has_table_privilege('ow_dashboard','ow.agents','SELECT'),         'dashboard can SELECT agents');
SELECT ok( has_table_privilege('ow_anonymous','ow.models','SELECT'),         'anonymous can SELECT models');

-- ----- writes are service-only ----------------------------------------------
SELECT ok( has_table_privilege('ow_service','ow.agents','INSERT,UPDATE,DELETE'), 'service can INSERT/UPDATE/DELETE agents');
SELECT ok( has_table_privilege('ow_service','ow.models','INSERT,UPDATE,DELETE'), 'service can INSERT/UPDATE/DELETE models');
SELECT ok( NOT has_table_privilege('ow_anonymous','ow.agents','INSERT'),         'anonymous CANNOT INSERT agents');
SELECT ok( NOT has_table_privilege('ow_anonymous','ow.agents','UPDATE'),         'anonymous CANNOT UPDATE agents');
SELECT ok( NOT has_table_privilege('ow_agent_primary','ow.agents','INSERT'),     'primary CANNOT INSERT agents');
SELECT ok( NOT has_table_privilege('ow_agent_primary','ow.models','UPDATE'),     'primary CANNOT UPDATE models');
SELECT ok( NOT has_table_privilege('ow_agent_primary','ow.agents','DELETE'),     'primary CANNOT DELETE agents');
SELECT ok( NOT has_table_privilege('ow_dashboard','ow.agents','INSERT'),         'dashboard CANNOT INSERT agents (read-only)');

-- ----- behavior: PUBLIC SELECT sees all rows ---------------------------------
SELECT is(pgtap_test.visible_count('ow_anonymous', $$SELECT 1 FROM ow.agents$$),         2::bigint, 'anonymous sees both agents');
SELECT is(pgtap_test.visible_count('ow_agent_primary', $$SELECT 1 FROM ow.agents$$),     2::bigint, 'primary sees both agents');
SELECT is(pgtap_test.visible_count('ow_service', $$SELECT 1 FROM ow.agents$$),           2::bigint, 'service sees both agents');
SELECT is(pgtap_test.visible_count('ow_dashboard', $$SELECT 1 FROM ow.agents$$),         2::bigint, 'dashboard sees both agents');

-- ----- behavior: service can create an agent; a tier/agent role cannot -------
SELECT ok(pgtap_test.can('ow_service',
  $$INSERT INTO ow.agents(slug, soul, model_id) SELECT 'svc-temp', 'x', id FROM ow.models LIMIT 1$$),
  'service can INSERT an agent');
SELECT ok(NOT pgtap_test.can('ow_agent_primary',
  $$INSERT INTO ow.agents(slug, soul, model_id) SELECT 'pri-temp', 'x', id FROM ow.models LIMIT 1$$),
  'primary CANNOT insert an agent');
SELECT ok(NOT pgtap_test.can('ow_anonymous',
  $$UPDATE ow.models SET name = name$$),
  'anonymous CANNOT update models');

SELECT * FROM finish();
ROLLBACK;
