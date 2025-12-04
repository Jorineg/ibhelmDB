#!/bin/bash
# Quick update: git pull, reset, and apply migrations
# Usage: ./update_db.sh [--full] [--force]

set -e

cd "$(dirname "$0")"

echo "=== Git Pull ==="
git pull

echo ""
echo "=== Reset Database ==="
./reset_db.sh "$@"

echo ""
echo "=== Apply Migrations ==="
./apply_migrations.sh

echo ""
echo "✓ Update complete!"

