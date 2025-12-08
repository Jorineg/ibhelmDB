// Atlas configuration for ibhelmDB
// Declarative schema management - edit SQL files directly, Atlas figures out the diff

env "dev" {
  // Connection string from environment variable  
  // Format: postgres://user:pass@host:port/dbname
  url = getenv("DATABASE_URL")
  
  // Schema definition files
  src = "file://supabase/schema"
  
  // Temporary database for computing diffs (requires Docker)
  dev = "docker://postgres/15"
  
  // All schemas managed by ibhelm
  schemas = ["public", "teamwork", "missive", "teamworkmissiveconnector"]
  
  // Exclude Supabase internals from diff
  exclude = [
    "auth.*",
    "storage.*", 
    "realtime.*",
    "supabase_*",
    "_realtime.*",
    "pg_*",
    "cron.*",
  ]
}
