// Atlas configuration for ibhelmDB
// Declarative schema management - edit SQL files directly, Atlas figures out the diff

env "dev" {
  // Connection string from environment variable  
  // Format: postgres://user:pass@host:port/dbname?sslmode=disable&search_path=public
  url = getenv("DATABASE_URL")
  
  // Schemas we manage (excludes supabase internals)
  schemas = ["public", "teamwork", "missive", "teamworkmissiveconnector"]
  
  // Schema definition files (tables only - code is applied via psql)
  src = "file://supabase/schema/tables"
  
  // Temporary database for computing diffs
  // Default: Use Docker (requires docker daemon)
  // Override: Set ATLAS_DEV_URL="postgres://user:pass@localhost:5432/dev_db?sslmode=disable"
  dev = getenv("ATLAS_DEV_URL") != "" ? getenv("ATLAS_DEV_URL") : "docker://postgres/16"
  
  // Exclude objects we don't manage
  exclude = [
    "auth.*",
    "storage.*",
    "realtime.*",
    "extensions.*",
    "graphql.*",
    "graphql_public.*",
    "pgsodium.*",
    "pgsodium_masks.*",
    "vault.*",
    "supabase_*",
    "_realtime.*",
    "pg_*",
    "cron.*",
  ]
}
