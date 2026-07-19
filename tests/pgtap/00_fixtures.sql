-- =============================================================================
-- Baseline data shared across the matrix suite.
-- Inserted as the superuser (BYPASSRLS) and COMMITTED before pg_prove runs.
-- Each per-domain test file executes inside its own BEGIN/ROLLBACK, so it reads
-- this baseline but never mutates it.
--
-- The bigserial ids are deterministic:
--   attobot.models.id = 1
--   attobot.agents.id = 1 (primary), 2 (subconscious)
-- 10_roles_meta.sql asserts that mapping before anything depends on it.
-- =============================================================================

\set ON_ERROR_STOP on

-- Reset the domain tables to a clean slate with sequences restarted, so the
-- suite is re-runnable even when `docker compose run` reuses the (persistent)
-- test-db container. RESTART IDENTITY resets the bigserial sequences so the
-- agent/model ids stay 1/2. The message triggers are disabled in 00_setup.sql,
-- so truncating messages fires no durable side effects. Runs as superuser.
TRUNCATE attobot.memory_sources, attobot.memory, attobot.messages,
         attobot.config, attobot.users,
         attobot.agents, attobot.models
RESTART IDENTITY CASCADE;

-- one model row
INSERT INTO attobot.models(name, api_base, temperature, reasoning_effort, context_tokens, multimodal_support)
VALUES ('pgtap-model', 'https://example.test', 1.0, 'medium', 1000000, false)
ON CONFLICT (name, api_base, temperature, reasoning_effort, context_tokens, multimodal_support)
DO NOTHING;

-- primary (1) + subconscious (2)
INSERT INTO attobot.agents(slug, soul, model_id)
SELECT 'primary', 'primary soul', m.id FROM attobot.models m
WHERE m.name = 'pgtap-model'
ON CONFLICT (slug) DO NOTHING;
INSERT INTO attobot.agents(slug, soul, model_id)
SELECT 'subconscious', 'subconscious soul', m.id FROM attobot.models m
WHERE m.name = 'pgtap-model'
ON CONFLICT (slug) DO NOTHING;

-- config: one secret + one public row per agent (mirrors api_key / model_id shape)
INSERT INTO attobot.config(agent_id, key, value, secret)
SELECT a.id, 'probe_secret', to_jsonb('TOPSECRET-' || a.slug), true
FROM attobot.agents a WHERE a.slug IN ('primary', 'subconscious')
ON CONFLICT (agent_id, key) DO NOTHING;
INSERT INTO attobot.config(agent_id, key, value, secret)
SELECT a.id, 'probe_public', to_jsonb('hi-' || a.slug), false
FROM attobot.agents a WHERE a.slug IN ('primary', 'subconscious')
ON CONFLICT (agent_id, key) DO NOTHING;

-- messages: primary's chat is CZ1 (user + assistant); subconscious's chat is CZ2
INSERT INTO attobot.messages(agent_id, role, content, chat_id, channel)
SELECT a.id, 'user', 'user-msg-' || a.slug, 'CZ1', 'telegram'
FROM attobot.agents a WHERE a.slug = 'primary';
INSERT INTO attobot.messages(agent_id, role, content, chat_id, channel)
SELECT a.id, 'assistant', 'asst-msg-' || a.slug, 'CZ1', 'telegram'
FROM attobot.agents a WHERE a.slug = 'primary';
INSERT INTO attobot.messages(agent_id, role, content, chat_id, channel)
SELECT a.id, 'user', 'user-msg-' || a.slug, 'CZ2', 'telegram'
FROM attobot.agents a WHERE a.slug = 'subconscious';

-- memory: one row per agent
INSERT INTO attobot.memory(agent_id, content)
SELECT a.id, 'mem-' || a.slug FROM attobot.agents a
WHERE a.slug IN ('primary', 'subconscious')
ON CONFLICT DO NOTHING;

-- channel identity ledger: one anonymous + one authenticated telegram user
INSERT INTO attobot.users(channel, external_id, username, tier)
VALUES
  ('telegram', '9001', 'alice', 'anonymous'),
  ('telegram', '9002', 'bob',   'authenticated')
ON CONFLICT (channel, external_id) DO NOTHING;
