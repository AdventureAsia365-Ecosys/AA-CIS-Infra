#!/usr/bin/env bash
# X1 plan S12 (AA-852, ADR 0004b decision 4): DB Migrate, DB Schema Dump and DB Isolation Probe run their
# one-off ECS task from the migrator task definition (accounts/aa365/db_migrator.tf: family
# aa-cis-dev-db-migrate, container "migrate", own execution + task role, master DSN secret, log stream
# migrate/migrate/<task id>) instead of an override of the CIS api service's task definition.
#
# run-task cannot override the image, and the CIS tag changes on every deploy (immutable dev-<sha>,
# AA-869), so the Terraform revision carries a ":latest" placeholder. Per run this script registers a
# revision copied from the Terraform revision with ONLY containerDefinitions[0].image replaced by the
# image the api service runs now (roles, secrets, logs, cpu/memory, command unchanged), and the workflow
# runs that revision by ARN and deregisters it at the end (if: always()).
#
# Base = the newest ACTIVE revision of the family whose image is still the ":latest" placeholder, i.e.
# Terraform's, never a per-run copy left ACTIVE by a failed deregister. The base must also match the
# fixed shape of accounts/aa365/db_migrator.tf (check-base): the two migrator roles, exactly one secret
# DATABASE_URL from aa-cis/dev/rds or aa-cis/dev/db-migrator (X1 S22), no plain environment. A revision
# registered by hand with other roles or secrets is refused, not copied.
#
#   migrator-task.sh prepare            register the revision; resolve the network configuration (subnets of
#                                       the api service + the security group named aa-cis-dev-sg-db-migrate,
#                                       exactly one). Writes arn, network, api_task_definition, image to
#                                       $GITHUB_OUTPUT (none of them is secret).
#   migrator-task.sh deregister <arn>   deregister a revision this script registered (family checked).
#   migrator-task.sh render <image>     stdin: describe-task-definition JSON; stdout: the register input.
#                                       No AWS call (used by prepare and for a local check).
#   migrator-task.sh check-base         stdin: describe-task-definition JSON; exit 1 with the reasons if it
#                                       is not the Terraform shape above. No AWS call.
#
# Needs the job env CLUSTER and SERVICE, AWS credentials (aa-cis-infra-tf-apply: ecs:Register/Deregister/
# Describe*/List* from AmazonECS_FullAccess, iam:PassRole on aa-*-dev-* from IAMRoleManageStack, ec2:Describe*
# from AmazonVPCFullAccess) and jq. No environment variable is passed to the task from here.
set -euo pipefail

FAMILY="aa-cis-dev-db-migrate"
CONTAINER="migrate"
SG_NAME="aa-cis-dev-sg-db-migrate"
API_CONTAINER="api"
TASK_ROLE="aa-cis-dev-db-migrate-task-role"
EXECUTION_ROLE="aa-cis-dev-db-migrate-execution-role"
DSN_ENV="DATABASE_URL"
# Secrets Manager ARN of the master DSN (today) or db_migrator's DSN (X1 S22): name + 6-character suffix.
# aa-cis/dev/rds-cis-app and the other rds-* secrets do not match (the suffix is exactly 6 characters).
DSN_SECRET_RE=':secret:aa-cis/dev/(rds|db-migrator)-[A-Za-z0-9]{6}$'

fail() { echo "::error::$*" >&2; exit 1; }

render() {
  [ -n "${1:-}" ] || fail "render: image missing"
  jq --arg image "$1" --arg c "$CONTAINER" '
    .taskDefinition
    | if (.containerDefinitions | length) != 1 or .containerDefinitions[0].name != $c
      then error("the migrator task definition must have exactly one container named \($c)") else . end
    | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities,
          .registeredAt, .registeredBy, .deregisteredAt)
    | .containerDefinitions[0].image = $image'
}

# Fixed expectations on the base revision (Terraform's shape), one line per violation; empty = ok.
base_errors() {
  jq -r --arg family "$FAMILY" --arg c "$CONTAINER" --arg task "$TASK_ROLE" --arg exec "$EXECUTION_ROLE" \
        --arg env "$DSN_ENV" --arg secret "$DSN_SECRET_RE" '
    .taskDefinition as $t | ($t.containerDefinitions // []) as $cs | ($cs[0] // {}) as $c0
    | [ (if $t.family != $family then "family is \($t.family), not \($family)" else empty end),
        (if (($t.taskRoleArn // "") | endswith(":role/" + $task)) then empty
         else "taskRoleArn is \($t.taskRoleArn), not role/\($task)" end),
        (if (($t.executionRoleArn // "") | endswith(":role/" + $exec)) then empty
         else "executionRoleArn is \($t.executionRoleArn), not role/\($exec)" end),
        (if ($cs | length) != 1 or $c0.name != $c then "needs exactly one container named \($c)" else empty end),
        (if (($c0.image // "") | endswith(":latest")) then empty
         else "image is \($c0.image), not the :latest placeholder (a per-run copy, not the Terraform revision)" end),
        (if (($c0.environment // []) | length) == 0 then empty else "container has plain environment entries" end),
        (if (($c0.secrets // []) | length) == 1 and $c0.secrets[0].name == $env
              and (($c0.secrets[0].valueFrom // "") | test($secret))
         then empty
         else "secrets must be exactly [\($env) <- aa-cis/dev/rds or aa-cis/dev/db-migrator], got \([($c0.secrets // [])[] | "\(.name) <- \(.valueFrom)"] | join(", "))" end)
      ] | .[]'
}

check_base() {
  local errs
  errs=$(base_errors) || fail "check-base: unreadable task definition JSON"
  [ -z "$errs" ] || fail "base revision is not the Terraform migrator shape: $(tr '\n' ';' <<<"$errs")"
}

# Newest ACTIVE revision of the family that is still the Terraform placeholder (image ":latest").
pick_base() {
  local arns arn td
  arns=$(aws ecs list-task-definitions --family-prefix "$FAMILY" --status ACTIVE --sort DESC \
    --max-items 25 --query 'taskDefinitionArns' --output json)
  for arn in $(jq -r '.[]' <<<"$arns"); do
    [[ "$arn" =~ :task-definition/${FAMILY}:[0-9]+$ ]] || continue     # --family-prefix also matches longer names
    td=$(aws ecs describe-task-definition --task-definition "$arn" --output json)
    if jq -e '.taskDefinition.containerDefinitions[0].image // "" | endswith(":latest")' <<<"$td" >/dev/null; then
      printf '%s' "$td"
      return 0
    fi
    echo "::warning::skipping $arn: not the :latest placeholder (a per-run copy left ACTIVE; deregister it)" >&2
  done
  fail "no ACTIVE revision of $FAMILY with the :latest placeholder image (X1 S11 Terraform)"
}

# What must not change between the base revision and the registered one (besides the image).
invariant() {
  jq -S '.taskDefinition | {family, taskRoleArn, executionRoleArn, networkMode, cpu, memory,
         requiresCompatibilities, container: (.containerDefinitions[0]
           | {name, command, secrets, environment, logConfiguration})}'
}

prepare() {
  : "${CLUSTER:?CLUSTER is not set}" "${SERVICE:?SERVICE is not set}" "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
  local svc api_td rollout image subnet vpc sgs sg net base input arn got
  svc=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --output json)
  api_td=$(jq -r '.services[0].taskDefinition // empty' <<<"$svc")
  [ -n "$api_td" ] || fail "service $SERVICE not found in $CLUSTER"
  # services[0].taskDefinition is the newest deployment's target, even while it rolls out or fails.
  rollout=$(jq -r '[.services[0].deployments[]? | select(.status == "PRIMARY") | .rolloutState][0] // "unknown"' <<<"$svc")
  [ "$rollout" = "COMPLETED" ] \
    || echo "::warning::api service PRIMARY deployment is $rollout, not COMPLETED: the migrator uses its image anyway ($api_td)"
  image=$(aws ecs describe-task-definition --task-definition "$api_td" --output json \
    | jq -r --arg c "$API_CONTAINER" '[.taskDefinition.containerDefinitions[] | select(.name == $c) | .image][0] // empty')
  [ -n "$image" ] || fail "api task definition $api_td has no container named $API_CONTAINER"

  subnet=$(jq -r '.services[0].networkConfiguration.awsvpcConfiguration.subnets[0] // empty' <<<"$svc")
  [ -n "$subnet" ] || fail "service $SERVICE has no awsvpc subnets"
  vpc=$(aws ec2 describe-subnets --subnet-ids "$subnet" --query 'Subnets[0].VpcId' --output text)
  sgs=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$vpc" \
    --query 'SecurityGroups[].GroupId' --output json)
  [ "$(jq 'length' <<<"$sgs")" = "1" ] \
    || fail "expected exactly one security group named $SG_NAME in $vpc, found $(jq -c . <<<"$sgs") (X1 S11 Terraform)"
  sg=$(jq -r '.[0]' <<<"$sgs")
  net=$(jq -c --arg sg "$sg" '.services[0].networkConfiguration.awsvpcConfiguration
    | {awsvpcConfiguration: {subnets: .subnets, securityGroups: [$sg], assignPublicIp: (.assignPublicIp // "DISABLED")}}' <<<"$svc")

  base=$(pick_base)
  check_base <<<"$base"
  input=$(render "$image" <<<"$base")
  arn=$(aws ecs register-task-definition --cli-input-json "$input" --query 'taskDefinition.taskDefinitionArn' --output text)
  [ -n "$arn" ] && [ "$arn" != "None" ] || fail "register-task-definition returned no ARN"
  # Output the ARN before any further check, so the deregister step always sees it.
  echo "arn=$arn" >> "$GITHUB_OUTPUT"
  got=$(aws ecs describe-task-definition --task-definition "$arn" --output json)
  [ "$(invariant <<<"$got")" = "$(invariant <<<"$base")" ] \
    || fail "registered $arn differs from $(jq -r '.taskDefinition.taskDefinitionArn' <<<"$base") beyond the image"
  [ "$(jq -r '.taskDefinition.containerDefinitions[0].image' <<<"$got")" = "$image" ] || fail "registered $arn has the wrong image"
  {
    echo "network=$net"
    echo "api_task_definition=$api_td"
    echo "image=$image"
  } >> "$GITHUB_OUTPUT"
  echo "migrator task definition: $arn (copied from $(jq -r '.taskDefinition.taskDefinitionArn' <<<"$base"))"
  echo "image (api service $api_td): $image"
  echo "security group: $SG_NAME ($sg)"
}

deregister() {
  [[ "${1:-}" =~ :task-definition/${FAMILY}:[0-9]+$ ]] || fail "deregister: not a revision of $FAMILY: ${1:-<empty>}"
  aws ecs deregister-task-definition --task-definition "$1" --query 'taskDefinition.[taskDefinitionArn,status]' --output text
}

case "${1:-}" in
  prepare) prepare ;;
  deregister) deregister "${2:-}" ;;
  render) render "${2:-}" ;;
  check-base) check_base ;;
  *) fail "usage: $0 prepare | deregister <arn> | render <image> | check-base" ;;
esac
