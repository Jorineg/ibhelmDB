# Atlas Schema Management

Declarative schema management - edit SQL files directly, Atlas computes the diff.

## Installation (on server)

```bash
curl -sSf https://atlasgo.sh | sh
atlas version
```

## Prerequisites

- **Docker** running (Atlas uses temp container for diffs)
- **DATABASE_URL** set

```bash
export DATABASE_URL="postgres://postgres:YOUR_PASSWORD@localhost:5432/postgres"
```

## Daily Workflow

```bash
cd ibhelmDB

# Preview changes (safe, no modifications)
atlas schema apply --env dev --dry-run

# Apply changes
atlas schema apply --env dev

# Inspect current database
atlas schema inspect --env dev
```

## How It Works

```
supabase/schema/        Live Database
     │                       │
     ▼                       ▼
┌─────────┐            ┌─────────┐
│ Desired │            │ Current │
│  State  │            │  State  │
└────┬────┘            └────┬────┘
     │                       │
     └───────┬───────────────┘
             ▼
      ┌─────────────┐
      │ Atlas Diff  │
      └──────┬──────┘
             ▼
    ┌─────────────────┐
    │ Minimal Changes │
    │ ALTER TABLE ... │
    │ CREATE FUNC ... │
    └─────────────────┘
```

## Data Safety

| You Change | Atlas Does |
|------------|------------|
| Add column | `ALTER TABLE ADD COLUMN` |
| Remove column | `ALTER TABLE DROP COLUMN` (asks confirmation) |
| Add/change function | `CREATE OR REPLACE FUNCTION` |
| Remove function | `DROP FUNCTION` |

**Renames:** Atlas sees "old gone, new added". Use hint:
```sql
-- atlas:rename users.email users.email_address
```

## Troubleshooting

```bash
# Docker not running
sudo systemctl start docker

# See detailed diff
atlas schema diff --env dev --format '{{ sql . }}'
```

## Managed Schemas

- `public` - ibhelm business logic
- `teamwork` - Teamwork API data
- `missive` - Missive API data  
- `teamworkmissiveconnector` - Connector app state
