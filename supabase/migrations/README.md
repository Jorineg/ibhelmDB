# Database Migrations

Diese Migrations implementieren das vollständige Schema für das ibhelm Datenmanagement-System.

## Struktur

### 3 Separate Schemas:
- **`teamwork`** - Externe Daten aus Teamwork Projektmanagement
- **`missive`** - Externe Daten aus Missive Email-System
- **`public`** - Hauptlogik für ibhelm (Parties, Projects, Locations, Files, etc.)

## Migration Files

### 001_extensions.sql
- PostgreSQL Extensions aktivieren
  - `uuid-ossp` - UUID Generierung
  - `pg_trgm` - Trigram-Suche für Fuzzy Matching
  - `unaccent` - Akzent-Entfernung für Volltext-Suche

### 002_types_and_enums.sql
- Custom Types und ENUMs:
  - `party_type` - 'company' oder 'person'
  - `location_type` - 'building', 'level', 'room'
  - `task_extension_type` - 'todo', 'info_item'

### 003_teamwork_schema.sql
- Schema `teamwork` mit allen Tabellen:
  - companies, users, teams, tags
  - projects, tasklists, tasks
  - Junction Tables: task_tags, task_assignees, user_teams

### 004_missive_schema.sql
- Schema `missive` mit allen Tabellen:
  - contacts, users, teams, shared_labels
  - conversations, messages, attachments
  - message_recipients, conversation_authors
  - Junction Tables: conversation_users, conversation_assignees, conversation_labels

### 005_ibhelm_schema.sql
- Schema `public` (Hauptlogik):
  - **Master Data:** parties, projects, project_contractors
  - **Hierarchien:** locations, cost_groups
  - **Files:** document_types, files
  - **The Glue:** project_files, object_locations, object_cost_groups, task_extensions
- Generated Columns:
  - `parties.display_name` - Auto-generierter Anzeigename
  - `locations.search_text` - Rekursiv generierte Hierarchie für Suche
- Materialized Paths:
  - `locations.path` und `path_ids` - Effiziente Hierarchie-Queries
  - `cost_groups.path` - Code-basierte Hierarchie

### 006_indexes.sql
- **GiST Indexes** (Trigram für Fuzzy Search):
  - Location names, paths
  - File names, folder paths
  - Party names
  - Project names, cost groups
  - Task names, company names
  - Contact names, emails
- **GIN Indexes** (Full-Text Search):
  - File extracted text
  - Task descriptions
  - Message body/subject
  - Location search text
  - Project descriptions
- **Performance Indexes:**
  - Composite indexes für häufige Queries

### 007_functions_and_triggers.sql
- **Auto-Update Timestamps:**
  - `update_updated_at_column()` - Trigger für alle `db_updated_at` Felder
- **Location Hierarchy:**
  - `update_location_hierarchy()` - Automatische Pflege von path, path_ids, search_text
  - `update_location_children()` - Rekursives Update bei Parent-Änderungen
- **Cost Group Hierarchy:**
  - `update_cost_group_path()` - Automatische Pflege von path
- **Search Functions:**
  - `search_locations(TEXT, FLOAT)` - Typo-resistente Location-Suche
  - `search_all_objects(...)` - Unified Search über Files, Tasks, Messages

### 008_views.sql
- **unified_items** - Tasks + Emails in einer View
- **party_details** - Enriched Party View mit External System Data
- **project_overview** - Projects mit aggregierten Counts
- **file_details** - Files mit allen Metadaten und Relationships
- **location_hierarchy** - Locations mit Parent/Child Info

## Features

### 🔍 Fuzzy Search (Tippfehler-Resistent)
- Trigram-basierte Ähnlichkeitssuche
- Funktioniert für Locations, Files, Parties, etc.
- `search_locations()` Function implementiert Requirements aus `additional_requirements_unstructured.md`

### 🌳 Hierarchische Strukturen
- Locations: Building > Level > Room
- Cost Groups: Materialized Path via Code
- Automatische Pflege durch Triggers

### 🔗 Polymorphe Relationships
- `object_locations` und `object_cost_groups` verbinden Files/Tasks/Messages
- Constraint-gesichert (genau ein Objekt-Typ pro Row)

### 🎯 Generated Columns
- `parties.display_name` - Automatisch generiert je nach Type
- `locations.search_text` - Rekursiv alle Parent-Namen

### 📊 Cross-Schema Relationships
- `public.parties` → `teamwork.companies`, `teamwork.users`, `missive.contacts`
- `public.projects` → `teamwork.projects`
- `public.object_locations` → `teamwork.tasks`, `missive.messages`

## Deployment

```bash
# Migrations ausführen (in Reihenfolge)
supabase db reset
# oder
supabase migration up
```

## Hinweise

- **tasks.id ist INTEGER** (Primary Key)
- **storage.objects FK** ist korrekt gesetzt in `files.storage_object_id`
- Alle Timestamps sind `TIMESTAMP`, außer file_created_at/file_modified_at (mit `WITH TIME ZONE`)
- Deutsche Volltext-Suche konfiguriert (`to_tsvector('german', ...)`)
