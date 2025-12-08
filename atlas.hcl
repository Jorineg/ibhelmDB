// Atlas configuration for ibhelmDB
// Declarative schema management - edit SQL files directly, Atlas figures out the diff

env "dev" {
  // Connection string from environment variable  
  // Format: postgres://user:pass@host:port/dbname?sslmode=disable
  url = getenv("DATABASE_URL")
  
  // Schema definition files
  src = "file://supabase/schema"
  
  // Temporary database for computing diffs (requires Docker)
  dev = "docker://postgres/15"
  
  // Exclude Supabase internals and system objects from diff
  exclude = [
    // Supabase internal schemas
    "auth.*",
    "storage.*", 
    "realtime.*",
    "extensions.*",
    "graphql.*",
    "graphql_public.*",
    "pgsodium.*",
    "pgsodium_masks.*",
    "vault.*",
    // System patterns
    "supabase_*",
    "_realtime.*",
    "pg_*",
    "cron.*",
    // Supabase functions we don't manage
    "public.extensions",
    "public.uuid_generate_*",
    "public.gen_random_*",
  ]
}
