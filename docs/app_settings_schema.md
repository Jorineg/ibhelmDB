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
  ]
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

---

## User Settings (Per-user) - `user_settings.settings`

One row per user. Personal preferences synced across devices.

```json
{
  "hide_completed_tasks": false,
  "default_sort_field": "updated_at",
  "default_sort_order": "desc",
  "filter_configurations": { ... },
  "key_bindings": { ... }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `hide_completed_tasks` | boolean | `false` | Hide completed tasks from Items view |
| `default_sort_field` | string | `"updated_at"` | Default sort field for new configs |
| `default_sort_order` | `"asc"` \| `"desc"` | `"desc"` | Default sort direction |
| `filter_configurations` | object | `{}` | All filter configs (previously localStorage) |
| `key_bindings` | object | `{}` | Custom keyboard shortcuts (previously localStorage) |
