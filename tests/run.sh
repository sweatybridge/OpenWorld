#!/bin/bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"

# 0. Change to the current script directory
cd "$(dirname "${BASH_SOURCE[0]}")"

# 1. pgTAP extension + test helpers (committed), then baseline fixtures.
psql -v ON_ERROR_STOP=1 \
    -f ./pgtap/00_setup.sql \
    -f ./pgtap/00_fixtures.sql

# 2. Run the matrix suite ([1-9]*.sql skips the 00_* setup/fixture files).
pg_prove -d postgres ./pgtap/[1-9]*.sql
