#!/usr/bin/env bash
# AA-993 Phase E slice I1 (root ADR 0017 decisions 6 + 8, design §2 I1): the GitHub side of the auto-apply gate on
# AA-CIS-Infra. GitHub settings are not in Terraform here, and the GitHub Apps have no Administration / Environments /
# Secrets permission (root ADR 0011 decision 1), so this runs with Nghiệp's own `gh` login (an org owner).
#
#   tools/github/db_auto_apply_gate.sh show        read only: ruleset(s) on main, environment dev-db-auto + its branch
#                                                  rule, the environment's secret names, repo variable DB_AUTO_APPLY
#   tools/github/db_auto_apply_gate.sh env         create/update environment dev-db-auto, deployment branches = main
#   tools/github/db_auto_apply_gate.sh secret      AWS_ROLE_ARN of the environment <- ARN of aa-cis-infra-db-auto-apply
#                                                  (read with the aa365-admin profile, piped; never printed)
#   tools/github/db_auto_apply_gate.sh ruleset     create, or update in place, the ruleset in infra-main-ruleset.json
#   tools/github/db_auto_apply_gate.sh rollback    delete the ruleset and the environment (with its secret)
#
# Order (orchestrator_steps of the I1 PR): merge I1 -> local MFA terraform apply of cicd_db_auto_apply.tf -> env ->
# secret -> ruleset -> proofs. The ruleset requires "Copies match owner main" and "Migration lint and unique numbers",
# which run on every PR only once the I1 change to migration-copy-guard.yml is on main: apply the ruleset after merge.
#
# On GitHub Free a ruleset and environment branch rules work only while the repo is public (root ADR 0014). When
# AA-CIS-Infra goes private they stop being enforced: set the repo variable DB_AUTO_APPLY=false the same day
# (ADR 0017 decision 8, Q16).
set -euo pipefail

REPO="${REPO:-AdventureAsia365-Ecosys/AA-CIS-Infra}"
ENV_NAME="dev-db-auto"
ROLE_NAME="aa-cis-infra-db-auto-apply"
PROFILE="${AWS_PROFILE_ADMIN:-aa365-admin}"
REGION="us-west-1"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULESET_FILE="$here/infra-main-ruleset.json"
RULESET_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$RULESET_FILE")"

ruleset_id() {
  gh api "repos/$REPO/rulesets" | python3 -c 'import json,sys; n=sys.argv[1]; print("\n".join(str(r["id"]) for r in json.load(sys.stdin) if r["name"]==n))' "$RULESET_NAME"
}

show() {
  echo "== rulesets on $REPO"
  gh api "repos/$REPO/rulesets" | python3 -c 'import json,sys; [print("  %s  %-8s  %s" % (r["id"], r["enforcement"], r["name"])) for r in json.load(sys.stdin)]'
  echo "== rules that apply to main (GET /rules/branches/main)"
  gh api "repos/$REPO/rules/branches/main" | python3 -c 'import json,sys; [print("  %s: %s" % (r["type"], json.dumps(r.get("parameters", {}))[:200])) for r in json.load(sys.stdin)]'
  echo "== environment $ENV_NAME"
  if gh api "repos/$REPO/environments/$ENV_NAME" >/dev/null 2>&1; then
    gh api "repos/$REPO/environments/$ENV_NAME" | python3 -c 'import json,sys; e=json.load(sys.stdin); print("  deployment_branch_policy:", json.dumps(e.get("deployment_branch_policy")), " protection_rules:", [r["type"] for r in e.get("protection_rules", [])])'
    gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" | python3 -c 'import json,sys; [print("  branch rule: %s %s" % (p.get("type"), p["name"])) for p in json.load(sys.stdin).get("branch_policies", [])]'
    echo "  secrets (names only):"; gh secret list --repo "$REPO" --env "$ENV_NAME" | sed 's/^/    /'
  else
    echo "  (absent)"
  fi
  echo "== repo variable DB_AUTO_APPLY: $(gh variable get DB_AUTO_APPLY --repo "$REPO" 2>/dev/null || echo '(unset)')"
}

env_apply() {
  gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input - >/dev/null <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
  existing=$(gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
    | python3 -c 'import json,sys; print(" ".join("%s:%s" % (p.get("type"), p["name"]) for p in json.load(sys.stdin).get("branch_policies", [])))')
  case " $existing " in
    *" branch:main "*) ;;
    *) gh api -X POST "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" -f name=main -f type=branch >/dev/null ;;
  esac
  echo "environment $ENV_NAME: deployment branches = main (rules now: $(gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
    | python3 -c 'import json,sys; print(", ".join("%s %s" % (p.get("type"), p["name"]) for p in json.load(sys.stdin).get("branch_policies", [])))'))"
}

secret_apply() {
  local arn
  arn=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text --profile "$PROFILE" --region "$REGION" </dev/null) \
    || { echo "cannot read role $ROLE_NAME (not applied yet, or MFA expired: aws sts get-caller-identity --profile $PROFILE)" >&2; exit 1; }
  [[ "$arn" == arn:aws:iam::*:role/"$ROLE_NAME" ]] || { echo "unexpected role ARN shape" >&2; exit 1; }
  printf '%s' "$arn" | gh secret set AWS_ROLE_ARN --repo "$REPO" --env "$ENV_NAME"
  unset arn
  echo "secret AWS_ROLE_ARN set in environment $ENV_NAME (value not printed)"
}

ruleset_apply() {
  local id
  id=$(ruleset_id | head -1)
  if [ -n "$id" ]; then
    gh api -X PUT "repos/$REPO/rulesets/$id" --input "$RULESET_FILE" >/dev/null
    echo "ruleset $id updated: $RULESET_NAME"
  else
    id=$(gh api -X POST "repos/$REPO/rulesets" --input "$RULESET_FILE" --jq .id)
    echo "ruleset $id created: $RULESET_NAME"
  fi
}

rollback() {
  local id
  for id in $(ruleset_id); do
    gh api -X DELETE "repos/$REPO/rulesets/$id" && echo "ruleset $id deleted"
  done
  if gh api "repos/$REPO/environments/$ENV_NAME" >/dev/null 2>&1; then
    gh api -X DELETE "repos/$REPO/environments/$ENV_NAME" && echo "environment $ENV_NAME deleted (its secrets with it)"
  fi
}

case "${1:-}" in
  show) show ;;
  env) env_apply ;;
  secret) secret_apply ;;
  ruleset) ruleset_apply ;;
  rollback) rollback ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
