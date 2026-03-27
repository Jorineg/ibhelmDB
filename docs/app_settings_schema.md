# Settings Schema

This file documents the JSON schemas for `app_settings.body` (admin) and `user_settings.settings` (per-user). **Keep in sync with application code.**

---

## App Settings (Admin) - `app_settings.body`

Single-row table. Admin-only settings that affect all users.

```json
{
  "email_color": "#3b82f6",
  "craft_color": "#8b5cf6",
  "file_color": "#ef4444",
  "person_color": "#10b981",
  "project_color": "#f59e0b",
  "craft_space_id": "",
  "teamwork_base_url": "",
  "cost_group_prefixes": ["KGR"],
  "location_prefix": "O-",
  "file_ignore_patterns": [
    { "pattern": "%~$%", "label": "Office Lock Files", "enabled": true, "builtin": true }
  ],
  "public_email_addresses": []
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `email_color` | string (hex) | `#3b82f6` | Color for email items |
| `craft_color` | string (hex) | `#8b5cf6` | Color for Craft document items |
| `file_color` | string (hex) | `#ef4444` | Color for file items |
| `person_color` | string (hex) | `#10b981` | Color for person badges |
| `project_color` | string (hex) | `#f59e0b` | Color for project badges |
| `craft_space_id` | string | `""` | Craft Docs space ID for deep links |
| `teamwork_base_url` | string | `""` | Base URL for Teamwork links |
| `cost_group_prefixes` | string[] | `["KGR"]` | Tag prefixes for cost group extraction |
| `location_prefix` | string | `"O-"` | Tag prefix for location extraction |
| `file_ignore_patterns` | FileIgnorePattern[] | (builtin) | LIKE patterns to hide files |
| `public_email_addresses` | string[] | `[]` | Shared email addresses visible to all users (RLS) |
| `ai_agent_system_prompt` | string | (default template) | System prompt template for AI Email Agent with {variable} placeholders |
| `chat_models` | ChatModel[] | (fallback to CLAUDE_MODEL env) | Available AI models for the chat service |
| `default_chat_model_id` | string | `""` | Model ID used as default in chat when none selected |
| `agent_model_id` | string | `""` | Model ID for the background project activity agent |
| `vision_fallback_model_id` | string | `""` | Model ID for image description when active model lacks vision |
| `title_model_id` | string | `""` | Model ID for auto-generating chat session titles |

### Chat Models Schema

Each entry in `chat_models` defines an available model endpoint:

```json
[
  {
    "id": "claude-sonnet-4-20250514",
    "provider": "anthropic",
    "name": "Claude Sonnet 4",
    "context_window": 200000,
    "supports_vision": true,
    "input_price": 3.0,
    "output_price": 15.0,
    "cache_read_price": 0.3,
    "cache_write_price": 3.75
  },
  {
    "id": "moonshotai/Kimi-K2.5",
    "provider": "openai_compat",
    "base_url": "https://api.tokenfactory.eu-west1.nebius.com/v1/",
    "name": "Kimi K2.5",
    "context_window": 256000,
    "supports_vision": false,
    "input_price": 0.5,
    "output_price": 2.5
  },
  {
    "id": "zai-org/GLM-4.7-FP8",
    "provider": "openai_compat",
    "base_url": "https://api.tokenfactory.nebius.com/v1/",
    "name": "GLM 4.7",
    "context_window": 200000,
    "supports_vision": false,
    "input_price": 0.4,
    "output_price": 2.0
  }
]
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Model ID passed to the provider API |
| `provider` | `"anthropic"` \| `"openai_compat"` | yes | Which API provider to use |
| `name` | string | yes | Display name in the UI |
| `base_url` | string | no | Override base URL (required for OpenAI-compatible providers) |
| `context_window` | number | no | Max context tokens |
| `supports_vision` | boolean | no | Whether model accepts image inputs |
| `input_price` | number | no | Price per 1M input tokens (USD) |
| `output_price` | number | no | Price per 1M output tokens (USD) |
| `cache_read_price` | number | no | Price per 1M cache-read tokens (Anthropic only) |
| `cache_write_price` | number | no | Price per 1M cache-write tokens (Anthropic only) |
| `hidden` | boolean | no | If true, excluded from user-facing model picker in chat |
| `system_prompt_addition` | string | no | Extra text appended to system prompt when this model is active |
| `auto_execute_code_blocks` | boolean | no | Auto-extract and run Python code blocks from assistant text |

### AI Agent System Prompt Template Variables

The `ai_agent_system_prompt` field supports these placeholder variables:

| Variable | Description |
|----------|-------------|
| `{current_datetime}` | Current date/time in Europe/Berlin (e.g., "Monday, 19 January 2026, 14:35") |
| `{trigger_author}` | Name of user who triggered @ai |
| `{trigger_instruction}` | Text after @ai (or "(no specific instruction)") |
| `{conversation_subject}` | Email subject line |
| `{conversation_url}` | Missive web URL |
| `{project_name}` | Project name (or "Not assigned") |
| `{project_id}` | Teamwork project ID |
| `{emails_summary}` | Last 3 emails with ID, from, subject, date, body (truncated 2000 chars) |
| `{emails_metadata}` | All email IDs in conversation with subject, from, date |
| `{emails_count}` | Total email count |
| `{comments}` | All conversation comments with author and date |
| `{tasks}` | Last 10 tasks: name, status, assigned_to, updated_at, tasklist |
| `{anforderungen}` | Last 10 Anforderungen (same fields) |
| `{hinweise}` | Last 10 Hinweise (same fields) |
| `{files}` | Last 10 files: name, path, updated_at |
| `{craft_docs}` | Last 10 Craft documents: title, modified_at |

---

## User Settings (Per-user) - `user_settings.settings`

One row per user. Personal preferences synced across devices.

```json
{
  "hide_completed_tasks": false,
  "hide_inactive_projects": false,
  "default_sort_field": "updated_at",
  "default_sort_order": "desc",
  "filter_configurations": { ... },
  "key_bindings": { ... }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `hide_completed_tasks` | boolean | `false` | Hide completed tasks from Items view |
| `hide_inactive_projects` | boolean | `false` | Hide items from inactive projects (Items view) and hide inactive projects (Projects view) |
| `default_sort_field` | string | `"updated_at"` | Default sort field for new configs |
| `default_sort_order` | `"asc"` \| `"desc"` | `"desc"` | Default sort direction |
| `filter_configurations` | object | `{}` | All filter configs (previously localStorage) |
| `key_bindings` | object | `{}` | Custom keyboard shortcuts (previously localStorage) |
