#!/usr/bin/env bash
set -euo pipefail

# This provisions committed fixtures and changes scheduler settings. Use only
# the disposable test-db service, never the application's harness database.
[[ "${ROBOT_RUNTIME_TEST:-}" == 1 ]] || { echo 'Set ROBOT_RUNTIME_TEST=1 for the disposable test database' >&2; exit 1; }
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-postgres}"
cd "$(dirname "${BASH_SOURCE[0]}")"
sql() { psql -XqAt -v ON_ERROR_STOP=1 -c "$1"; }
expect() {
  local actual
  actual=$(sql "$2")
  [[ "$actual" == "$1" ]] || { printf 'FAIL: %s (expected %s, got %s)\n' "$3" "$1" "$actual" >&2; exit 1; }
  printf 'PASS: %s\n' "$3"
}
await_value() {
  local i
  for i in $(seq 1 150); do
    if [[ $(sql "$2") == "$1" ]]; then printf 'PASS: %s\n' "$3"; return; fi
    sleep 0.4
  done
  sql 'SELECT * FROM robot_runtime.worker_health; SELECT id,lifecycle,state FROM robot_runtime.activity_instance;'
  echo "FAIL: timed out: $3" >&2; exit 1
}

case "${1:-run}" in
run)
  psql -Xq -v ON_ERROR_STOP=1 -f robot-runtime-fixture.sql >/dev/null
  sql "SELECT robot_runtime.define('stress',1,'rr_test.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context)',
    '{\"count\":0}',contract||'{\"max_mailbox\":256}') FROM robot_runtime.activity_definition WHERE name='counter';
    UPDATE robot_runtime.settings SET executors=2;
    SELECT robot_runtime.ensure_scheduler();" >/dev/null
  aid=$(sql "SET ROLE rr_owner; SELECT (robot_runtime.start('stress',1,'{}','integration')).activity_id;")
  sql "CREATE TABLE rr_test.expectation(activity_id uuid PRIMARY KEY,expected_count integer); INSERT INTO rr_test.expectation VALUES('$aid',0);" >/dev/null
  await_value active "SELECT lifecycle FROM robot_runtime.activity_instance WHERE id='$aid'" 'pg_durable activates committed activity'

  pids=()
  for i in $(seq 1 8); do
    sql "SET ROLE rr_owner; SELECT robot_runtime.send(ROW('$aid',1)::robot_runtime.activity_ref,'add','{\"value\":1}');" >/dev/null &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  await_value 8 "SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id='$aid'" 'concurrent senders serialize into one revision chain'
  pids=()
  for i in $(seq 1 8); do
    sql "SET ROLE rr_owner; SELECT robot_runtime.send(ROW('$aid',1)::robot_runtime.activity_ref,'add','{\"value\":1}','11111111-0000-0000-0000-000000000001');" >/dev/null &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  await_value 9 "SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id='$aid'" 'concurrent duplicate requests reduce once'
  expect 10 "SELECT count(*) FROM robot_runtime.activity_history WHERE activity_id='$aid'" 'history has no duplicate revisions'

  sql "BEGIN; SET ROLE rr_owner; SELECT robot_runtime.send(ROW('$aid',1)::robot_runtime.activity_ref,'add','{\"value\":1000}'); ROLLBACK;" >/dev/null
  expect 0 "SELECT count(*) FROM robot_runtime.activity_inbox WHERE activity_id='$aid' AND payload='{\"value\":1000}'" 'rolled-back ingress is invisible to scheduler'

  bad=$(sql "SET ROLE rr_owner; SELECT (robot_runtime.start('stress',1)).activity_id;")
  await_value active "SELECT lifecycle FROM robot_runtime.activity_instance WHERE id='$bad'" 'second activity starts independently'
  sql "SET ROLE rr_owner; SELECT robot_runtime.send(ROW('$bad',1)::robot_runtime.activity_ref,'fail');" >/dev/null
  await_value faulted "SELECT lifecycle FROM robot_runtime.activity_instance WHERE id='$bad'" 'poison intent records fault instead of killing scheduler'
  expect P0001 "SELECT error_code FROM robot_runtime.activity_history WHERE activity_id='$bad' AND error_code IS NOT NULL" 'reducer error leaves durable diagnostic'
  slow=$(sql "SET ROLE rr_owner; SELECT (robot_runtime.start('stress',1)).activity_id;")
  await_value active "SELECT lifecycle FROM robot_runtime.activity_instance WHERE id='$slow'" 'timeout fixture starts'
  sql "SET ROLE rr_owner; SELECT robot_runtime.send(ROW('$slow',1)::robot_runtime.activity_ref,'slow');" >/dev/null
  await_value faulted "SELECT lifecycle FROM robot_runtime.activity_instance WHERE id='$slow'" 'worker statement timeout bounds reducer execution'
  expect 57014 "SELECT error_code FROM robot_runtime.activity_history WHERE activity_id='$slow' AND error_code IS NOT NULL" 'timeout diagnostic survives cancellation'
  sql "SET ROLE rr_owner; SELECT robot_runtime.send(ROW('$aid',1)::robot_runtime.activity_ref,'add','{\"value\":1}');" >/dev/null
  await_value 10 "SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id='$aid'" 'scheduler continues after reducer timeout'

  sql "SET ROLE rr_owner; SELECT robot_runtime.send(ROW('$aid',1)::robot_runtime.activity_ref,'emit',
    jsonb_build_object('effects',jsonb_build_array(rr_test.effect())));" >/dev/null
  await_value 1 "SELECT count(*) FROM robot_runtime.effect_outbox WHERE activity_id='$aid' AND status='pending'" 'worker commits effect outbox'
  fence=$(sql "SET ROLE rr_adapter; SELECT robot_runtime.acquire_capability('mock','arm','r1','integration')->>'fence';")
  claim=$(sql "SET ROLE rr_adapter; SELECT id::text||','||claim_token::text FROM robot_runtime.claim_effects('mock','arm','r1','integration',$fence);")
  IFS=, read -r eid token <<< "$claim"
  sql "SET ROLE rr_adapter; SELECT robot_runtime.complete_effect('$eid','$token','mock','integration',$fence,'succeeded');" >/dev/null
  await_value 20 "SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id='$aid'" 'mock adapter completes through running scheduler'
  sql "SET ROLE rr_owner; SELECT robot_runtime.send(ROW('$aid',1)::robot_runtime.activity_ref,'emit',
    jsonb_build_object('timers',jsonb_build_array(jsonb_build_object('timer_id','live','due_at',clock_timestamp()+interval '2 seconds'))));" >/dev/null
  await_value 120 "SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id='$aid'" 'durable timer fires under live scheduler'

  old=$(sql 'SELECT instance_id FROM robot_runtime.worker_epoch WHERE slot=1')
  sql "SELECT df.cancel('$old');" >/dev/null
  await_value t "SELECT instance_id<>'$old' FROM robot_runtime.worker_epoch WHERE slot=1" 'supervisor replaces cancelled executor'
  expect 0 "SELECT count(*) FROM robot_runtime.worker_epoch WHERE last_error IS NOT NULL" 'scheduler health has no hidden errors'
  sql "SET ROLE rr_owner; SELECT robot_runtime.send(ROW('$bad',1)::robot_runtime.activity_ref,'add','{\"value\":1}') FROM generate_series(1,100);" >/dev/null
  expect t "SELECT rejected_count>=100 FROM robot_runtime.activity_instance WHERE id='$bad'" 'overload diagnostics count rejected traffic'
  expect t "SELECT count(*)<=16 FROM robot_runtime.dead_letter WHERE activity_id='$bad' AND intent_id IS NULL" 'rejection audit storage stays bounded'
  echo 'Runtime worker integration passed.'
  ;;
prepare-restart)
  aid=$(sql 'SELECT activity_id FROM rr_test.expectation')
  # Transaction commits queued intents and a future timer atomically. Restart
  # may process some intents first; the final count must still be exact.
  sql "BEGIN; UPDATE rr_test.expectation SET expected_count=(SELECT (state->>'count')::integer+108 FROM robot_runtime.activity_instance WHERE id='$aid');
    SET LOCAL ROLE rr_owner;
    SELECT robot_runtime.send(ROW('$aid',1)::robot_runtime.activity_ref,'add','{\"value\":1}') FROM generate_series(1,8);
    SELECT robot_runtime.send(ROW('$aid',1)::robot_runtime.activity_ref,'emit',
      jsonb_build_object('timers',jsonb_build_array(jsonb_build_object('timer_id','restart','due_at',clock_timestamp()+interval '10 seconds')))); COMMIT;" >/dev/null
  echo 'Restart fixtures committed.'
  ;;
verify-restart)
  aid=$(sql 'SELECT activity_id FROM rr_test.expectation')
  target=$(sql 'SELECT expected_count FROM rr_test.expectation')
  await_value "$target" "SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id='$aid'" 'PostgreSQL restart preserves pending intents and timer'
  expect 1 "SELECT count(*) FROM robot_runtime.activity_inbox WHERE activity_id='$aid' AND kind='timer.fired' AND payload->>'timer_id'='restart'" 'restart timer materializes exactly once'
  expect 0 'SELECT count(*) FROM robot_runtime.worker_epoch WHERE last_error IS NOT NULL' 'scheduler recovers without persistent errors'
  ;;
backup-restore)
  pg_dump -Fc --schema=robot_runtime --schema=rr_test --file=/tmp/robot-runtime.dump
  createdb rr_restore
  pg_restore --exit-on-error --dbname=rr_restore /tmp/robot-runtime.dump
  aid=$(sql 'SELECT activity_id FROM rr_test.expectation')
  target=$(sql "SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id='$aid'")
  export PGDATABASE=rr_restore
  expect "$target" "SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id='$aid'" 'logical restore preserves durable activity state'
  sql "SET ROLE rr_owner; SELECT robot_runtime.send(ROW('$aid',1)::robot_runtime.activity_ref,'add','{\"value\":1}');" >/dev/null
  sql 'SELECT robot_runtime.process_one();' >/dev/null
  expect "$((target+1))" "SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id='$aid'" 'restored reducer signature resolves despite changed OIDs'
  ;;
*) echo 'Unknown integration phase' >&2; exit 1 ;;
esac
