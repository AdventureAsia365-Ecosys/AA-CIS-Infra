#!/usr/bin/env bash
# AA-1004 P0 (prod plan P0): the one guard in front of every prod path of this repo — Deploy Prod
# (.github/workflows/deploy-prod.yml) and DB Migrate environment=prod (.github/workflows/db-migrate.yml).
#
# The prod account does not exist yet (prod plan P2). Until it does, every prod run stops at `ready`, before any
# GitHub environment `prod` job starts and before any AWS call. After P2, the identity check still refuses a run whose
# credentials land in the Dev account, whatever secrets or variables say: a prod workflow can never target Dev.
#
#   prod-guard.sh ready      env PROD_ACCOUNT_READY (repo variable), DEV_ROLE_ARN (repo secret AWS_ROLE_ARN: the Dev
#                            plan role). Refuses unless PROD_ACCOUNT_READY is exactly "true". Writes
#                            dev_account_sha256=<sha256 of the Dev account id> to $GITHUB_OUTPUT: a hash, not the id,
#                            so it can cross jobs (GitHub drops job outputs that hold a secret) and never shows in logs.
#   prod-guard.sh identity   env CALLER_ACCOUNT (sts get-caller-identity after OIDC), PROD_ACCOUNT_ID (environment
#                            secret of `prod`), DEV_ACCOUNT_SHA256 (from `ready`). Refuses unless the caller is the
#                            configured prod account and is not the Dev account.
#   prod-guard.sh names NAME=VALUE...
#                            Refuses an empty value or one that names a Dev resource (a `dev` token: aa-cis-dev-cluster,
#                            /ecs/aa-cis-dev, dev/terraform.tfstate). For resource names that come from variables.
#
# Prints no account id, ARN or value (public repo, public logs). Exit 0 = pass, 1 = refused, 2 = bad usage.
set -euo pipefail

fail() {
  echo "::error::prod guard: $*"
  exit 1
}

sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

cmd_ready() {
  if [ "${PROD_ACCOUNT_READY:-}" != "true" ]; then
    fail "the prod account is not ready (repo variable PROD_ACCOUNT_READY is not 'true'; set in prod plan P2 once the account, its roles and its state bucket exist). Nothing ran."
  fi
  local role="${DEV_ROLE_ARN:-}"
  if ! [[ "$role" =~ ^arn:aws:iam::([0-9]{12}):role/.+$ ]]; then
    fail "repo secret AWS_ROLE_ARN (the Dev plan role) is missing or not a role ARN: without it the run cannot prove it is not targeting Dev."
  fi
  local dev_sha
  dev_sha=$(sha "${BASH_REMATCH[1]}")
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "dev_account_sha256=$dev_sha" >> "$GITHUB_OUTPUT"
  fi
  echo "prod guard: ready (PROD_ACCOUNT_READY=true)"
}

cmd_identity() {
  local caller="${CALLER_ACCOUNT:-}" want="${PROD_ACCOUNT_ID:-}" dev_sha="${DEV_ACCOUNT_SHA256:-}"
  [[ "$caller" =~ ^[0-9]{12}$ ]] || fail "could not read the caller account after OIDC."
  [[ "$want" =~ ^[0-9]{12}$ ]] || fail "environment secret PROD_ACCOUNT_ID is missing or not a 12-digit account id."
  [[ "$dev_sha" =~ ^[0-9a-f]{64}$ ]] || fail "the Dev account fingerprint from the guard job is missing."
  if [ "$(sha "$caller")" = "$dev_sha" ]; then
    fail "the credentials belong to the Dev account. A prod run never targets Dev. Nothing ran."
  fi
  if [ "$want" != "$caller" ]; then
    fail "the credentials do not belong to the configured prod account (PROD_ACCOUNT_ID). Nothing ran."
  fi
  if [ "$(sha "$want")" = "$dev_sha" ]; then
    fail "PROD_ACCOUNT_ID names the Dev account. Nothing ran."
  fi
  echo "prod guard: identity is the prod account, not Dev"
}

cmd_names() {
  [ "$#" -gt 0 ] || { echo "usage: prod-guard.sh names NAME=VALUE..." >&2; exit 2; }
  local pair name value
  for pair in "$@"; do
    [[ "$pair" == *=* ]] || { echo "usage: prod-guard.sh names NAME=VALUE..." >&2; exit 2; }
    name="${pair%%=*}"
    value="${pair#*=}"
    [ -n "$value" ] || fail "$name is empty (set it as a variable of the GitHub environment prod)."
    if [[ "$value" =~ (^|[-_/.:])dev([-_/.:]|$) ]]; then
      fail "$name names a Dev resource. A prod run never targets Dev."
    fi
  done
  echo "prod guard: $# prod resource names set, none names Dev"
}

case "${1:-}" in
  ready) shift; cmd_ready "$@" ;;
  identity) shift; cmd_identity "$@" ;;
  names) shift; cmd_names "$@" ;;
  *) echo "usage: prod-guard.sh ready | identity | names NAME=VALUE..." >&2; exit 2 ;;
esac
