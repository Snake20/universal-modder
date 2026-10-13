#!/usr/bin/env bash
# Apply the shim + every migration to a throwaway database and run the RLS tests.
#   PGHOST/PGUSER/PGPORT select the server (default: local socket, user postgres).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
db="mashworks_test_$$"
export PGUSER="${PGUSER:-postgres}"
createdb "$db"
trap 'dropdb --if-exists "$db"' EXIT
psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$here/supabase_shim.sql"
for m in "$here"/../migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$m"
done
psql -qtA -v ON_ERROR_STOP=1 -d "$db" -f "$here/rls.sql" 2>&1 | sed -e "s/^psql:[^ ]* NOTICE:  //" -e "/^$/d"
