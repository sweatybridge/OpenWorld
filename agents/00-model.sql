-- Shared LLM model definition. Runs first: \gset publishes :model_id, which the
-- per-agent files (10-primary.sql, 20-subconscious.sql) consume. psql variables
-- persist for the whole agent-init session across --file boundaries, so the
-- load order in docker-compose.yml must keep this ahead of the agent files.
SELECT attobot.upsert_model(
  p_model => COALESCE(NULLIF(:'model', ''), 'deepseek-v4-pro'),
  p_api_base => COALESCE(NULLIF(:'api_base', ''), 'https://api.deepseek.com/v1'),
  p_temperature => COALESCE(NULLIF(:'temperature', ''), '1.0')::numeric,
  p_reasoning_effort => COALESCE(NULLIF(:'reasoning_effort', ''), 'medium'),
  p_context_tokens => COALESCE(NULLIF(:'context_tokens', ''), '1000000')::integer,
  p_multimodal_support => COALESCE(NULLIF(:'multimodal_support', ''), 'false')::boolean
) AS model_id
\gset
