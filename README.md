# ibhelmDB - Central Data Warehouse

PostgreSQL 17 database management for the IBHelm ecosystem, featuring automated synchronization schemas, triggers for auto-categorization, and declarative schema management via Atlas.

## 🏗 Schema Overview

The database is organized into four main functional schemas:

| Schema | Purpose |
|--------|---------|
| `public` | Core business logic, unified tables (persons, locations, cost_groups, files). |
| `teamwork` | Mirrors Teamwork API data structure (projects, tasks, users, tags). |
| `missive` | Mirrors Missive API data structure (conversations, messages, contacts). |
| `teamworkmissiveconnector` | Internal state management for the sync engine (queues, checkpoints). |

## 🚀 Key Features

- **Polymorphic Linking**: A unified metadata system for linking files, emails, and tasks to locations and cost groups.
- **Auto-Categorization**: Robust SQL triggers automatically extract project metadata (building, floor, room, Kostengruppe) from tags and labels.
- **Unified Persons**: Merges identity data from Teamwork and Missive into a canonical person registry.
- **Searchable Files**: Metadata for every file on the NAS is indexed and linked to its respective email attachment.
- **Processing Queues**: Built-in queues for background tasks like thumbnail generation and file downloads.

## 🛠 Management with Atlas

This project uses [Atlas](https://atlasgo.io/) for declarative schema management. Instead of writing migration scripts, you edit the SQL files in `supabase/schema/` and Atlas computes the necessary diffs.

### Installation

```bash
curl -sSf https://atlasgo.sh | sh
```

### Workflow

1. **Edit Schema**: Modify files in `supabase/schema/tables/`.
2. **Preview Changes**:
   ```bash
   atlas schema apply --env dev --dry-run
   ```
3. **Apply Changes**:
   ```bash
   atlas schema apply --env dev
   ```

### Directory Structure

```
ibhelmDB/supabase/
├── schema/
│   ├── tables/      # DDL (Tables, Indexes) - Managed by Atlas
│   ├── code/        # Idempotent Logic (Functions, Triggers, Views)
│   └── manual/      # Specialized setup (Full-text search, etc.)
└── migrations/      # (Optional) Versioned migrations
```

## 📋 Prerequisites

- **Supabase** (PostgreSQL 17 compatible)
- **Docker** (Required by Atlas for computing diffs in a temporary container)
- **Environment Variables**:
  - `DATABASE_URL`: Connection string to your target database.

## 📜 Procedures

- **Apply full schema**: Use `./apply_schema.sh` to apply tables via Atlas and then reload all idempotent logic (functions/triggers/views).
- **Robust Apply**: Use `./apply_schema_robust.sh` for a safer application with better error handling.

## 🤝 Component Integration

`ibhelmDB` serves as the backbone for:
- [TeamworkMissiveConnector](../TeamworkMissiveConnector) (Data Ingestion)
- [ibhelm dashboard](../ibhelm%20dashboard) (Visualization)
- [ThumbnailTextExtractor](../ThumbnailTextExtractor) (Transformation)
- [MCP Server](../mcp) (AI Interface)
