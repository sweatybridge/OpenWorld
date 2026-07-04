-- agents + models: PUBLIC read; only service can write.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- ----- SELECT granted to everyone (PUBLIC read policy) -----------------------
SELECT ok( has_table_privilege('attobot_anonymous','attobot.agents','SELECT'),         'anonymous can SELECT agents');
SELECT ok( has_table_privilege('attobot_authenticated','attobot.agents','SELECT'),     'authenticated can SELECT agents');
SELECT ok( has_table_privilege('attobot_agent_primary','attobot.agents','SELECT'),     'primary can SELECT agents');
SELECT ok( has_table_privilege('attobot_agent_subconscious','attobot.agents','SELECT'),'subconscious can SELECT agents');
SELECT ok( has_table_privilege('attobot_service','attobot.agents','SELECT'),           'service can SELECT agents');
SELECT ok( has_table_privilege('attobot_dashboard','attobot.agents','SELECT'),         'dashboard can SELECT agents');
SELECT ok( has_table_privilege('attobot_anonymous','attobot.models','SELECT'),         'anonymous can SELECT models');

-- ----- writes are service-only ----------------------------------------------
SELECT ok( has_table_privilege('attobot_service','attobot.agents','INSERT,UPDATE,DELETE'), 'service can INSERT/UPDATE/DELETE agents');
SELECT ok( has_table_privilege('attobot_service','attobot.models','INSERT,UPDATE,DELETE'), 'service can INSERT/UPDATE/DELETE models');
SELECT ok( NOT has_table_privilege('attobot_anonymous','attobot.agents','INSERT'),         'anonymous CANNOT INSERT agents');
SELECT ok( NOT has_table_privilege('attobot_anonymous','attobot.agents','UPDATE'),         'anonymous CANNOT UPDATE agents');
SELECT ok( NOT has_table_privilege('attobot_agent_primary','attobot.agents','INSERT'),     'primary CANNOT INSERT agents');
SELECT ok( NOT has_table_privilege('attobot_agent_primary','attobot.models','UPDATE'),     'primary CANNOT UPDATE models');
SELECT ok( NOT has_table_privilege('attobot_agent_primary','attobot.agents','DELETE'),     'primary CANNOT DELETE agents');
SELECT ok( NOT has_table_privilege('attobot_dashboard','attobot.agents','INSERT'),         'dashboard CANNOT INSERT agents (read-only)');

-- ----- behavior: PUBLIC SELECT sees all rows ---------------------------------
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.agents$$),         2::bigint, 'anonymous sees both agents');
SELECT is(pgtap_test.visible_count('attobot_agent_primary', $$SELECT 1 FROM attobot.agents$$),     2::bigint, 'primary sees both agents');
SELECT is(pgtap_test.visible_count('attobot_service', $$SELECT 1 FROM attobot.agents$$),           2::bigint, 'service sees both agents');
SELECT is(pgtap_test.visible_count('attobot_dashboard', $$SELECT 1 FROM attobot.agents$$),         2::bigint, 'dashboard sees both agents');

-- ----- behavior: service can create an agent; a tier/agent role cannot -------
SELECT ok(pgtap_test.can('attobot_service',
  $$INSERT INTO attobot.agents(slug, soul, model_id) SELECT 'svc-temp', 'x', id FROM attobot.models LIMIT 1$$),
  'service can INSERT an agent');
SELECT ok(NOT pgtap_test.can('attobot_agent_primary',
  $$INSERT INTO attobot.agents(slug, soul, model_id) SELECT 'pri-temp', 'x', id FROM attobot.models LIMIT 1$$),
  'primary CANNOT insert an agent');
SELECT ok(NOT pgtap_test.can('attobot_anonymous',
  $$UPDATE attobot.models SET name = name$$),
  'anonymous CANNOT update models');

SELECT * FROM finish();
ROLLBACK;
