#!/usr/bin/env bash
# AA-1023 (data standards DM-11.4 for Infra applies): the job-idle gate of terraform-apply.yml. Runs the migrator task
# (the DB Migrate task definition, .github/scripts/migrator-task.sh) once with MIGRATION_MODE=idle-gate: db/run_migration.py
# reads every owner job table (shared.job, booking.job, crm.job, tripplanner.job) and open shared.rerun_wave rows with
# the same query, exempt kinds and 3 x 20 s re-check as DB Migrate apply, in a read-only session, and exits 0 (idle)
# or 7 (still busy). Nothing is written to the database.
#
#   job-idle-gate.sh            run the gate; exit 0 = the apply may go on, 1 = refused (busy, or no clean answer)
#
# Fail closed: a busy table, an unreadable table, a task that does not stop, or a missing result line refuses. With
# OVERRIDE set (the workflow input override_busy_jobs, the tech lead only; one line, at most 200 characters) the gate
# still runs and logs the report, but no answer refuses: the apply goes on with a ::warning:: (also the way through
# when the database or the migrator task itself is what the apply fixes).
#
# Needs the job env CLUSTER, SERVICE, BUCKET, LOG_GROUP, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, AWS credentials
# (aa-cis-infra-tf-apply, the role DB Migrate runs with) and jq. GITHUB_STEP_SUMMARY optional. MIGRATOR_TASK
# (tests only) replaces the path of migrator-task.sh. Uploads go under db-migrate/<run id>-<attempt>-idle-gate/ and
# are removed at exit, the per-run task revision is deregistered at exit.
set -euo pipefail

: "${CLUSTER:?CLUSTER is not set}" "${SERVICE:?SERVICE is not set}" "${BUCKET:?BUCKET is not set}"
: "${LOG_GROUP:?LOG_GROUP is not set}" "${GITHUB_RUN_ID:?GITHUB_RUN_ID is not set}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MIGRATOR_TASK="${MIGRATOR_TASK:-$HERE/migrator-task.sh}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
PREFIX="db-migrate/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}-idle-gate"
OVERRIDE="${OVERRIDE:-}"
# Trimmed the way the runner .strip()s MIGRATION_IDLE_OVERRIDE, so this script and the task agree.
OVR="${OVERRIDE#"${OVERRIDE%%[![:space:]]*}"}"
OVR="${OVR%"${OVR##*[![:space:]]}"}"

if [ -n "$OVERRIDE" ] && [ -z "$OVR" ]; then
  echo "::error::override_busy_jobs is blank: leave it empty, or give a reason"; exit 1
fi
if [ -n "$OVR" ] && { [ "${#OVR}" -gt 200 ] || [[ "$OVR" == *$'\n'* ]]; }; then
  echo "::error::override_busy_jobs must be one line of at most 200 characters"; exit 1
fi

TD_ARN=""
UPLOADED=""
WORK="$(mktemp -d)"
cleanup() {
  if [ -n "$TD_ARN" ]; then bash "$MIGRATOR_TASK" deregister "$TD_ARN" || echo "::warning::deregister of $TD_ARN failed"; fi
  if [ -n "$UPLOADED" ]; then aws s3 rm "s3://$BUCKET/$PREFIX/" --recursive --only-show-errors || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Ends the gate: refuses (exit 1), or with an override passes with a warning.
verdict_fail() {
  if [ -n "$OVR" ]; then
    echo "::warning::job-idle gate OVERRIDDEN ($OVR): $1"
    echo "- **job-idle gate overridden:** $OVR ($1)" >> "$SUMMARY"
    exit 0
  fi
  echo "::error::job-idle gate refused the apply: $1"
  echo "- **job-idle gate: refused** ($1). Wait until every job table is idle and no rerun wave is open, then dispatch again; or dispatch with override_busy_jobs=<reason> (tech lead only)" >> "$SUMMARY"
  exit 1
}

# 1. The per-run migrator revision (api image), as DB Migrate.
GITHUB_OUTPUT="$WORK/td.out" bash "$MIGRATOR_TASK" prepare || verdict_fail "the migrator task definition could not be prepared"
TD_ARN="$(sed -n 's/^arn=//p' "$WORK/td.out" | tail -1)"
NET="$(sed -n 's/^network=//p' "$WORK/td.out" | tail -1)"
[ -n "$TD_ARN" ] && [ -n "$NET" ] || verdict_fail "migrator-task.sh prepare gave no arn/network"

# 2. Runner upload + one-off task. The presigned URL is created and used here only (masked).
UPLOADED=1
aws s3 cp "$ROOT/db/run_migration.py" "s3://$BUCKET/$PREFIX/run_migration.py" --only-show-errors \
  || verdict_fail "the runner upload failed"
RUNNER_URL="$(aws s3 presign "s3://$BUCKET/$PREFIX/run_migration.py" --expires-in 900)" || verdict_fail "presign failed"
echo "::add-mask::$RUNNER_URL"
OVERRIDES="$(jq -nc --arg runner "$RUNNER_URL" --arg override "$OVR" \
  '{containerOverrides: [{name: "migrate",
    command: ["python3", "-c", "import os,urllib.request;exec(urllib.request.urlopen(os.environ[\"RUNNER_URL\"],timeout=30).read())"],
    environment: [
      {name: "RUNNER_URL", value: $runner}, {name: "MIGRATION_URL", value: ""},
      {name: "MIGRATION_FILE", value: ""}, {name: "MIGRATION_VERSION", value: ""},
      {name: "MIGRATION_SHA256", value: ""}, {name: "MIGRATION_MODE", value: "idle-gate"},
      {name: "MIGRATION_IDLE_OVERRIDE", value: $override}]}]}')"
TASK_ARN="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TD_ARN" --launch-type FARGATE \
  --network-configuration "$NET" --overrides "$OVERRIDES" --started-by "gh-tf-apply-idle-gate-${GITHUB_RUN_ID}" \
  --query 'tasks[0].taskArn' --output text)" || verdict_fail "run-task failed"
{ [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; } || verdict_fail "run-task returned no task"
echo "idle-gate task: $TASK_ARN (task definition $TD_ARN)"
# The gate itself takes about a minute (3 x 20 s at most); the waiter gives up after 10 min.
for _ in 1 2; do aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN" && break; done

# 3. Log + exit code.
STREAM="migrate/migrate/${TASK_ARN##*/}"
: > "$WORK/task.log"
TOKEN=""
for _ in $(seq 1 20); do
  if [ -z "$TOKEN" ]; then
    R="$(aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$STREAM" --start-from-head --output json)" || break
  else
    R="$(aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$STREAM" --next-token "$TOKEN" --output json)" || break
  fi
  jq -r '.events[].message' <<<"$R" >> "$WORK/task.log"
  NEXT="$(jq -r '.nextForwardToken' <<<"$R")"
  [ "$NEXT" = "$TOKEN" ] && break
  TOKEN="$NEXT"
done
cat "$WORK/task.log"
{ echo "### Job-idle gate"; echo; grep '^MIGRATE' "$WORK/task.log" | sed 's/^/    /' || true; echo; } >> "$SUMMARY"
DESC="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --output json)"
EXIT="$(jq -r '[.tasks[0].containers[]? | select(.name=="migrate") | .exitCode][0] // "none"' <<<"$DESC")"
STATUS="$(jq -r '.tasks[0].lastStatus // "unknown"' <<<"$DESC")"
echo "idle-gate exit code: $EXIT  status: $STATUS"
[ "$STATUS" = "STOPPED" ] || verdict_fail "the gate task is still $STATUS after the wait"
case "$EXIT" in
  0)
    grep -q '^MIGRATE idle-gate: pass' "$WORK/task.log" || verdict_fail "the task exited 0 without an idle-gate pass line"
    echo "- **job-idle gate: pass**" >> "$SUMMARY"
    echo "job-idle gate: pass" ;;
  7) verdict_fail "a job table is busy or a rerun wave is open (see the MIGRATE busy lines)" ;;
  *) verdict_fail "the gate task exited $EXIT (no idle answer; see the task log)" ;;
esac
