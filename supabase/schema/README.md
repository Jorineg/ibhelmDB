# Database Schema

Organized schema for the ibhelm database system.

## Structure

```
supabase/schema/
├── tables/          # DDL only - Atlas diffs these
│   ├── 000_stubs.sql       # Supabase role stubs
│   ├── 001_types.sql       # Extensions, types, enums, config tables
│   ├── 002_teamwork.sql    # teamwork schema
│   ├── 003_missive.sql     # missive schema
│   ├── 004_public.sql      # public schema (ibhelm core)
│   └── 005_connector.sql   # teamworkmissiveconnector schema
│
├── code/            # Functions, triggers, views - always re-run (idempotent)
│   ├── functions.sql       # All CREATE OR REPLACE FUNCTION
│   ├── triggers.sql        # DROP TRIGGER IF EXISTS + CREATE TRIGGER
│   └── views.sql           # Views and materialized views
│
└── manual/          # Special cases (run after everything)
    └── indexes.sql         # GiST/GIN indexes (CREATE INDEX IF NOT EXISTS)
```

## Idempotency Rules

### Functions
Already idempotent with `CREATE OR REPLACE FUNCTION`.

### Views  
Already idempotent with `CREATE OR REPLACE VIEW`.

### Materialized Views
Use `DROP MATERIALIZED VIEW IF EXISTS ... CASCADE` before `CREATE MATERIALIZED VIEW`.

### Triggers (CRITICAL)
Triggers are **NOT** idempotent by default. Always use:
```sql
DROP TRIGGER IF EXISTS trigger_name ON table_name;
CREATE TRIGGER trigger_name ...
```

### Indexes
Use `CREATE INDEX IF NOT EXISTS` for idempotency.

## How to Apply

```bash
./apply_schema.sh           # Normal apply
./apply_schema.sh --cron    # Also setup pg_cron jobs (first deploy only)
```

The script automatically discovers and runs all `.sql` files from `code/` and `manual/` (sorted alphabetically). Just add new files - no script changes needed.

## Editing Rules

### Tables (tables/)
- Edit CREATE TABLE directly (no ALTER TABLE)
- Atlas handles the diff
- Add new files only if existing ones get too long

### Code (code/)
- Functions: Just edit, `CREATE OR REPLACE` handles it
- Views: Just edit, `CREATE OR REPLACE` handles it  
- Triggers: **ALWAYS** use `DROP TRIGGER IF EXISTS` before `CREATE TRIGGER`
- Materialized Views: **ALWAYS** use `DROP ... CASCADE` before `CREATE`

### Manual (manual/)
- Use `CREATE INDEX IF NOT EXISTS`
- For indexes Atlas has trouble with (GiST, complex expressions)

## 3 Schemas

- **`teamwork`** - External data from Teamwork project management
- **`missive`** - External data from Missive email system
- **`public`** - Main ibhelm business logic
- **`teamworkmissiveconnector`** - Connector application state
