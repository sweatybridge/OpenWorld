CREATE SCHEMA IF NOT EXISTS OpenWorld;
CREATE SCHEMA IF NOT EXISTS OpenWorld_tools;

CREATE TABLE IF NOT EXISTS OpenWorld.models (
  id bigserial PRIMARY KEY,
  name text NOT NULL DEFAULT 'Gemma4-26B-A4B',
  api_base text NOT NULL DEFAULT 'http://localhost:11434/v1',
  temperature numeric NOT NULL DEFAULT 1.0,
  reasoning_effort text NOT NULL DEFAULT 'medium',
  context_tokens integer NOT NULL DEFAULT 131072,
  multimodal_support boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name, api_base, temperature, reasoning_effort, context_tokens, multimodal_support)
);

CREATE TABLE IF NOT EXISTS OpenWorld.agents (
  id bigserial PRIMARY KEY,
  slug text NOT NULL UNIQUE,
  soul text NOT NULL DEFAULT '',
  model_id bigint NOT NULL REFERENCES OpenWorld.models(id) ON DELETE RESTRICT,
  enabled boolean NOT NULL DEFAULT true,
  max_turn integer NOT NULL DEFAULT 10,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS OpenWorld.config (
  agent_id bigint NOT NULL REFERENCES OpenWorld.agents(id) ON DELETE CASCADE,
  key text NOT NULL,
  value jsonb NOT NULL,
  secret boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_id, key)
);

CREATE TABLE IF NOT EXISTS OpenWorld.messages (
  id bigserial PRIMARY KEY,
  agent_id bigint NOT NULL REFERENCES OpenWorld.agents(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
  content text NOT NULL DEFAULT '',
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  channel text,
  chat_id text,
  tool_call_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS messages_agent_id_id_idx ON OpenWorld.messages(agent_id, id);

CREATE UNIQUE INDEX IF NOT EXISTS messages_telegram_update_agent_idx
  ON OpenWorld.messages(agent_id, ((payload #>> '{telegram_update,update_id}')))
  WHERE payload #>> '{telegram_update,update_id}' IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS messages_tool_call_agent_idx
  ON OpenWorld.messages(agent_id, tool_call_id)
  WHERE role = 'tool' AND tool_call_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS OpenWorld.memory (
  id bigserial PRIMARY KEY,
  agent_id bigint NOT NULL REFERENCES OpenWorld.agents(id) ON DELETE CASCADE,
  content text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (btrim(content) <> '')
);

CREATE INDEX IF NOT EXISTS memory_agent_enabled_id_idx
  ON OpenWorld.memory(agent_id, enabled, id);

-- Referential-integrity backing for the (agent_id, id) pairs the composite
-- foreign keys below target. id is already the primary key, so these unique
-- constraints add no new uniqueness; they exist only as FK targets.
ALTER TABLE OpenWorld.messages ADD CONSTRAINT messages_agent_id_id_key UNIQUE (agent_id, id);
ALTER TABLE OpenWorld.memory   ADD CONSTRAINT memory_id_agent_key     UNIQUE (id, agent_id);

-- Junction table replacing memory.source_message_ids. The two composite foreign
-- keys force memory.agent_id == messages.agent_id declaratively (same-agent
-- integrity, with no trigger), and both cascade on delete of either parent. A
-- memory may legitimately have zero sources.
CREATE TABLE IF NOT EXISTS OpenWorld.memory_sources (
  memory_id  bigint NOT NULL,
  agent_id   bigint NOT NULL,
  message_id bigint NOT NULL,
  PRIMARY KEY (memory_id, message_id),
  FOREIGN KEY (memory_id, agent_id)
    REFERENCES OpenWorld.memory(id, agent_id) ON DELETE CASCADE,
  FOREIGN KEY (agent_id, message_id)
    REFERENCES OpenWorld.messages(agent_id, id) ON DELETE CASCADE
);

-- Channel-agnostic identity ledger. One row per (channel, external_id); today
-- only 'telegram' is populated (by process_telegram_updates), but the shape
-- supports future channels (discord, whatsapp) by new channel values.
-- `tier` maps the user to an RLS role suffix (OpenWorld_<tier>); it defaults to
-- 'anonymous' and is promoted to 'authenticated' by an operator.
CREATE TABLE IF NOT EXISTS OpenWorld.users (
  id bigserial PRIMARY KEY,
  channel text NOT NULL CHECK (channel IN ('telegram', 'discord', 'whatsapp')),
  external_id text NOT NULL,
  username text,
  display_name text,
  tier text NOT NULL DEFAULT 'anonymous' CHECK (tier IN ('anonymous', 'authenticated')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (channel, external_id)
);
