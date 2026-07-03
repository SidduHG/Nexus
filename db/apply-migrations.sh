#!/usr/bin/env bash
# Applies pending SQL migrations to the nexus Postgres container, in order.
# Idempotent: skips versions already recorded in public.schema_migrations.
# Usage: ./apply-migrations.sh   (from the db/ directory)
set -euo pipefail

container="nexus-postgres"
applied=$(docker exec "$container" psql -U nexus -d nexus -tAc \
    "SELECT version FROM public.schema_migrations" 2>/dev/null || true)

for f in "$(dirname "$0")"/migrations/*.sql; do
    version=$(basename "$f" .sql)
    if grep -qx "$version" <<<"$applied"; then
        echo "skip  $version (already applied)"
        continue
    fi
    echo "apply $version ..."
    docker exec "$container" psql -U nexus -d nexus -v ON_ERROR_STOP=1 -f "/migrations/$(basename "$f")"
done
echo "done."
