# App Settings Schema

This file documents the JSON schema for the `app_settings.body` column. **Keep this in sync with application code.**

## Schema

```json
{
  "email_color": "#3b82f6",
  "craft_color": "#8b5cf6",
  "craft_space_id": "",
  "person_color": "#10b981",
  "project_color": "#f59e0b",
  "teamwork_base_url": "",
  "cost_group_prefixes": ["KGR"]
}
```

## Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `email_color` | string (hex color) | `#3b82f6` | Color for email items (badges, link buttons, color bars) |
| `craft_color` | string (hex color) | `#8b5cf6` | Color for Craft document items (badges, link buttons, color bars) |
| `craft_space_id` | string | `""` | Craft Docs space ID for building proper deep links (`craftdocs://open?spaceId=...&blockId=...`) |
| `person_color` | string (hex color) | `#10b981` | Color for person type badges and link buttons in the People view |
| `project_color` | string (hex color) | `#f59e0b` | Color for project type badges and link buttons in the Projects view |
| `teamwork_base_url` | string | `""` | Base URL for Teamwork project links (e.g., `https://yourcompany.teamwork.com`) |
| `cost_group_prefixes` | string[] | `["KGR"]` | Tag prefixes for cost group extraction. Tags matching `PREFIX CODE NAME` pattern (e.g., "KGR 456 demo kostengruppe") are auto-linked |
