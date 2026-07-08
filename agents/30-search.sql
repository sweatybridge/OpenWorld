-- Per-agent Exa API key for the SEARCH tool, shared by both agents (one Exa
-- account). Stored as a secret in each agent's config so either agent's SEARCH
-- graph builder can read its own key under RLS. Must run after both agent files
-- (10-primary.sql, 20-subconscious.sql); no-op when the key is unset.
SELECT attobot.set_config(slug, 'exa_api_key', to_jsonb(NULLIF(:'exa_api_key', '')), true)
FROM (VALUES ('primary'), ('subconscious')) AS t(slug)
WHERE NULLIF(:'exa_api_key', '') IS NOT NULL;
