// Atlas configuration for ibhelmDB
// Declarative schema management - edit SQL files directly, Atlas figures out the diff

env "dev" {
  // Connection string from environment variable  
  // Format: postgres://user:pass@host:port/dbname?sslmode=disable&search_path=public
  url = getenv("DATABASE_URL")
  
  // Schemas we manage (excludes supabase internals: auth, storage, realtime, etc.)
  schemas = ["public", "teamwork", "missive", "teamworkmissiveconnector"]
  
  // Schema definition files
  src = "file://supabase/schema"
  
  // Temporary database for computing diffs (requires Docker)
  dev = "docker://postgres/15"
  
  // Exclude objects we don't manage within public schema
  exclude = [
    "public.uuid_generate_*",
    "public.gen_random_*",
  ]
}
