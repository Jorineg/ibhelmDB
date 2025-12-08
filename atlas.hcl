// Atlas configuration for ibhelmDB
// Declarative schema management - edit SQL files directly, Atlas figures out the diff

env "dev" {
  // Connection string from environment variable  
  // Format: postgres://user:pass@host:port/dbname?sslmode=disable&search_path=public
  url = getenv("DATABASE_URL")
  
  // Schemas we manage + storage (needed for FK resolution, but excluded from changes)
  schemas = ["public", "teamwork", "missive", "teamworkmissiveconnector", "storage"]
  
  // Schema definition files
  src = "file://supabase/schema"
  
  // Temporary database for computing diffs (requires Docker)
  dev = "docker://postgres/16"
  
  // Exclude objects we don't manage
  exclude = [
    "storage.*",  // Supabase manages storage, we just need it for FK resolution
    "public.uuid_generate_*",
    "public.gen_random_*",
  ]
}
