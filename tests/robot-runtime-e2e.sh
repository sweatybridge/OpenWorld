#!/usr/bin/env bash
set -euo pipefail

# Run after pgTAP, against the disposable test-db service. Never targets harness.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
compose=(docker compose -f docker-compose.test.yml)
phase() {
  # Git Bash must not translate the container's /tests path into a Windows path.
  MSYS_NO_PATHCONV=1 "${compose[@]}" exec -T -e ROBOT_RUNTIME_TEST=1 test-db \
    bash /tests/robot-runtime-integration.sh "$1"
}
phase run
phase prepare-restart
"${compose[@]}" restart test-db
ready=false
for _ in $(seq 1 100); do
  if "${compose[@]}" exec -T test-db pg_isready -U postgres >/dev/null 2>&1; then ready=true; break; fi
  sleep 0.3
done
[[ "$ready" == true ]] || { echo 'Test PostgreSQL did not restart' >&2; exit 1; }
phase verify-restart
phase backup-restore
