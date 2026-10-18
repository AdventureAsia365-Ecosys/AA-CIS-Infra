#!/usr/bin/env bash
# X1 plan S12 (AA-852, ADR 0004b decision 4): DB Migrate, DB Schema Dump and DB Isolation Probe run their
# one-off ECS task from the migrator task definition (accounts/aa365/db_migrator.tf: family
# aa-cis-dev-db-migrate, container "migrate", own execution + task role, master DSN secret, log stream
# migrate/migrate/<task id>) instead of an override of the CIS api service's task definition.
#
# run-task cannot override the image, and the CIS tag changes on every deploy (immutable dev-<sha>,
# AA-869), so the Terraform revision carries a ":latest" placeholder. Per run this script registers a
# revision copied from the family's latest ACTIVE revision with ONLY containerDefinitions[0].image
# replaced by the image the api service runs now (roles, secrets, logs, cpu/memory, command unchanged),
# and the workflow runs that revision by ARN and deregisters it at the end (if: always()).
#
#   migrator-task.sh prepare            register the revision; resolve the network configuration (subnets of
#                                       the api service + the security group named aa-cis-dev-sg-db-migrate,
#                                       exactly one). Writes arn, network, api_task_definition, image to
#                                       $GITHUB_OUTPUT (none of them is secret).
#   migrator-task.sh deregister <arn>   deregister a revision this script registered (family checked).
#   migrator-task.sh render <image>     stdin: describe-task-definition JSON; stdout: the register input.
#                                       No AWS call (used by prepare and for a local check).
#
# Needs the job env CLUSTER and SERVICE, AWS credentials (aa-cis-infra-tf-apply: ecs:Register/Deregister/
# Describe* from AmazonECS_FullAccess, iam:PassRole on aa-*-dev-* from IAMRoleManageStack, ec2:Describe*
# from AmazonVPCFullAccess) and jq. No environment variable is passed to the task from here.
set -euo pipefail

FAMILY="aa-cis-dev-db-migrate"
CONTAINER="migrate"
SG_NAME="aa-cis-dev-sg-db-migrate"
API_CONTAINER="api"

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

# What must not change between the base revision and the registered one (besides the image).
invariant() {
  jq -S '.taskDefinition | {family, taskRoleArn, executionRoleArn, networkMode, cpu, memory,
         requiresCompatibilities, container: (.containerDefinitions[0]
           | {name, command, secrets, environment, logConfiguration})}'
}

prepare() {
  : "${CLUSTER:?CLUSTER is not set}" "${SERVICE:?SERVICE is not set}" "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
  local svc api_td image subnet vpc sgs sg net base input arn got
  svc=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --output json)
  api_td=$(jq -r '.services[0].taskDefinition // empty' <<<"$svc")
  [ -n "$api_td" ] || fail "service $SERVICE not found in $CLUSTER"
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

  base=$(aws ecs describe-task-definition --task-definition "$FAMILY" --output json)
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
  *) fail "usage: $0 prepare | deregister <arn> | render <image>" ;;
esac
