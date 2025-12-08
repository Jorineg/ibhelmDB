#!/bin/bash
# Apply schema changes using Atlas
# Usage: ./apply_schema.sh [--dry-run]

set -e
cd "$(dirname "$0")"

command -v atlas &>/dev/null || { echo "❌ Atlas not installed. Run: curl -sSf https://atlasgo.sh | sh"; exit 1; }
docker info &>/dev/null 2>&1 || { echo "❌ Docker not running."; exit 1; }
[ -z "$DATABASE_URL" ] && { echo "❌ DATABASE_URL not set."; exit 1; }

echo "🔍 Comparing supabase/schema/ to live database..."
atlas schema apply --env dev ${1:+$1}

