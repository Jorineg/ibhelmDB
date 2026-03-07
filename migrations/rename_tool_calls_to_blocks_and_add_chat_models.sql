-- Migration: Rename chat_messages.tool_calls → blocks + insert chat_models config
-- Run ONCE on the production database before deploying the new chat service version.

-- 1. Rename column
ALTER TABLE chat_messages RENAME COLUMN tool_calls TO blocks;

COMMENT ON COLUMN chat_messages.blocks IS 'Neutral content blocks: [{type:"text",text}, {type:"tool_call",id,code,result|[{type:"text"},{type:"image",storage_path,media_type}],error}, {type:"thinking",text}]';

-- 2. Insert chat_models into app_settings (merges into existing JSONB body)
UPDATE app_settings
SET body = body || jsonb_build_object('chat_models', '[
  {
    "id": "claude-sonnet-4-20250514",
    "provider": "anthropic",
    "name": "Claude Sonnet 4",
    "default": true,
    "context_window": 200000,
    "supports_vision": true,
    "input_price": 3.0,
    "output_price": 15.0,
    "cache_read_price": 0.3,
    "cache_write_price": 3.75
  },
  {
    "id": "moonshotai/Kimi-K2.5",
    "provider": "nebius",
    "base_url": "https://api.tokenfactory.eu-west1.nebius.com/v1/",
    "name": "Kimi K2.5",
    "context_window": 256000,
    "supports_vision": false,
    "input_price": 0.5,
    "output_price": 2.5
  },
  {
    "id": "zai-org/GLM-4.7-FP8",
    "provider": "nebius",
    "base_url": "https://api.tokenfactory.nebius.com/v1/",
    "name": "GLM 4.7",
    "context_window": 200000,
    "supports_vision": false,
    "input_price": 0.4,
    "output_price": 2.0
  }
]'::jsonb);
