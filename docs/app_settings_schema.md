# App Settings Schema

This file documents the JSON schema for the `app_settings.body` column. **Keep this in sync with application code.**

## Schema

```json
{
  "email_color": "#3b82f6",
  "craft_color": "#8b5cf6",
  "craft_space_id": ""
}
```

## Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `email_color` | string (hex color) | `#3b82f6` | Color for email items (badges, link buttons, color bars) |
| `craft_color` | string (hex color) | `#8b5cf6` | Color for Craft document items (badges, link buttons, color bars) |
| `craft_space_id` | string | `""` | Craft Docs space ID for building proper deep links (`craftdocs://open?spaceId=...&blockId=...`) |
