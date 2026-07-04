#!/usr/bin/env bash
# pgTAP runner. pgtap-db is already up and has the schema + RBAC layer loaded
# (depends_on: service_healthy in docker-compose.yml). This script creates the
# dashboard role exactly as production's agent-init job does, loads pgTAP helpers
# + baseline fixtures, then runs the matrix suite with pg_prove. Exits non-zero
# on any failure. Connection params come from PGHOST/PGUSER/PGPASSWORD env.
set -euo pipefail

# 1. attobot_dashboard role: BYPASSRLS, SELECT/EXECUTE only (faithful to prod).
psql -v ON_ERROR_STOP=1 \
    -v dashboard_db_password="${DASHBOARD_DB_PASSWORD:-dashboard}" \
    -f /attobot/dashboard-role.sql

# 2. pgTAP extension + test helpers (committed), then baseline fixtures.
psql -v ON_ERROR_STOP=1 -f /tests/pgtap/00_setup.sql
psql -v ON_ERROR_STOP=1 -f /tests/pgtap/00_fixtures.sql

# 3. Run the matrix suite ([1-9]*.sql skips the 00_* setup/fixture files).
pg_prove -d postgres /tests/pgtap/[1-9]*.sql
