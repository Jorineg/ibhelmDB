// Atlas configuration for ibhelmDB
// Declarative schema management - edit SQL files directly, Atlas figures out the diff

env "dev" {
  // Connection string from environment variable
  url = getenv("DATABASE_URL")
  
  // Schema definition files
  src = "file://supabase/schema"
  
  // Temporary database for computing diffs (requires Docker)
  dev = "docker://postgres/15/dev?search_path=public"
  
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
