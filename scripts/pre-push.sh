#!/usr/bin/env bash
# AA-CIS-Infra pre-push checks (AA-993 H1, design D5): run the repo's CI checks locally before a push.
#
# Every command below is taken from a workflow in .github/workflows/ (named next to each check). A check runs in
# fast mode when the push touches one of the paths in that workflow's `pull_request.paths` filter, so the local
# run picks the same workflows CI would run. Steps that need AWS or the network stay in CI (listed at the end).
#
# Usage:
#   scripts/pre-push.sh               fast mode: checks for the files changed vs origin/main (target <= 90 s)
#   scripts/pre-push.sh --full        every check, whatever changed (also AA_PREPUSH=full)
#   scripts/pre-push.sh --ci          reserved for H2 (CI calls this script): implies --full, never skips by diff,
#                                     ignores AA_PREPUSH_ALLOW_MISSING
#   scripts/pre-push.sh --list        print the checks the current diff selects, run nothing
#   scripts/pre-push.sh --self-test   run the selection logic on fixture diffs (plus scratch git repos for the diff)
#   scripts/pre-push.sh --base REF    diff base (default origin/main; the script never fetches)
#
# Installed as the pre-push hook by scripts/install-hooks.sh (.githooks/pre-push calls this file).
# Bypass for one push: git push --no-verify
#
# A tool or Python module a selected step needs and that is missing here FAILS the run, with an install hint.
# AA_PREPUSH_ALLOW_MISSING=1 turns that into a skip (printed; CI still runs the step).
#
# Python: $AA_PREPUSH_PYTHON, else .venv/bin/python of this worktree or of the main checkout, else python3.
# The pytest-based checks need pytest (CI pins "pytest>=8,<10"); see scripts/install-hooks.sh for the venv line.

set -uo pipefail

MODE=fast
CI_MODE=0
LIST_ONLY=0
BASE=origin/main

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --full) MODE=full ;;
    --ci) CI_MODE=1; MODE=full ;;
    --list) LIST_ONLY=1 ;;
    --self-test) MODE=self-test ;;
    --base) shift; BASE="${1:-}"; [ -n "$BASE" ] || { echo "pre-push: --base needs a ref" >&2; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) echo "pre-push: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
if [ "$MODE" = fast ] && [ "${AA_PREPUSH:-}" = full ]; then MODE=full; fi

# AA_PREPUSH_PYTHON is resolved against the directory the script was started from, before the cd below: a relative
# value would otherwise break the steps that cd into accounts/aa365.
PY_OVERRIDE=""
if [ -n "${AA_PREPUSH_PYTHON:-}" ]; then
  case "$AA_PREPUSH_PYTHON" in
    */*) [ -e "$AA_PREPUSH_PYTHON" ] && PY_OVERRIDE="$(cd "$(dirname "$AA_PREPUSH_PYTHON")" && pwd)/$(basename "$AA_PREPUSH_PYTHON")" ;;
    *) PY_OVERRIDE=$(command -v "$AA_PREPUSH_PYTHON" 2>/dev/null || true) ;;
  esac
  [ -n "$PY_OVERRIDE" ] || echo "pre-push: AA_PREPUSH_PYTHON=$AA_PREPUSH_PYTHON not found; falling back" >&2
fi

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "pre-push: not inside a git work tree" >&2; exit 2; }
cd "$TOP" || exit 2
GIT_DIR_ABS=$(git rev-parse --absolute-git-dir)
COMMON_DIR=$(cd "$(git rev-parse --git-common-dir)" && pwd)
MAIN_TOP=$(dirname "$COMMON_DIR")

# ---------------------------------------------------------------------------------------------------------------
# Checks and their path filters. Patterns use the GitHub Actions glob rules: `*` stops at `/`, `**` crosses it.
# Order here is the run order. tf-validate expands to one check per touched root (tf-validate:<root>).
# ---------------------------------------------------------------------------------------------------------------
CHECKS=(tf-fmt tf-validate alb-rule-order connection-budget contract-copy docs-gen docs-lint identity-triggers
        managed-login-branding migration-guard ops-probe rds-snapshot-expiry secrets-register tf-plan-guard
        hook-self-test)

patterns_for() {
  case "$1" in
    tf-fmt) # D5 (CI gap until H2 adds `terraform fmt -check` to terraform-plan.yml)
      printf '%s\n' '**/*.tf' '**/*.tfvars' ;;
    alb-rule-order) # alb-rule-order.yml
      printf '%s\n' 'accounts/aa365/**' 'modules/alb/**' 'tools/terraform/**' '.github/workflows/alb-rule-order.yml' ;;
    connection-budget) # connection-budget.yml
      printf '%s\n' 'db/connection_budget.json' 'db/check_connection_budget.py' 'db/migrations/roles/**' \
        'db/migrations/cis/**' 'modules/ecs/**' 'modules/rds/**' 'accounts/aa365/*.tf' \
        '.github/workflows/connection-budget.yml' ;;
    contract-copy) # contract-copy-guard.yml
      printf '%s\n' 'tools/contracts/**' '.github/workflows/contract-copy-guard.yml' ;;
    docs-gen) # docs-gen-test.yml
      printf '%s\n' 'tools/docs/**' 'accounts/**/*.tf' 'modules/**/*.tf' '.github/workflows/docs-gen.yml' \
        '.github/workflows/docs-gen-test.yml' ;;
    docs-lint) # docs-lint.yml
      printf '%s\n' '**/*.md' 'tools/docs/**' 'docs/templates/**' '.github/workflows/docs-lint.yml' ;;
    identity-triggers) # identity-triggers-test.yml
      printf '%s\n' 'accounts/aa365/lambda_src/identity_triggers/**' 'accounts/aa365/lambda_src/identity_triggers_tests/**' \
        'accounts/aa365/identity.tf' 'accounts/aa365/identity_variables.tf' 'accounts/aa365/e2e_mailbox.tf' \
        'tools/identity/**' '.github/workflows/identity-triggers-test.yml' ;;
    managed-login-branding) # managed-login-branding.yml
      printf '%s\n' 'accounts/aa365/**' 'tools/terraform/managed_login_branding.py' \
        'tools/terraform/tests/test_managed_login_branding.py' '.github/workflows/managed-login-branding.yml' ;;
    # AA-993 I1: the workflow no longer filters by path; this list = db/migration_guard_scope.py PATHS (its scope job;
    # db/tests/test_migration_guard_scope.py checks both agree).
    migration-guard) # migration-copy-guard.yml
      printf '%s\n' 'db/migrations/**' 'db/check_migration_copies.py' 'db/rls_catalogue_rules.py' \
        'db/replay_migrations.py' 'db/schema_drift.py' 'db/schema_drift_decisions.json' 'db/replay_baseline/**' \
        'db/gen_replay_baseline.py' 'db/gen_schema_reference.py' 'db/schema_dump_automerge.py' 'db/gen_erd.py' 'tools/docs/aws_mask.py' \
        'db/check_erd_drift.py' 'db/schema_dump.py' 'db/check_migration_files.py' 'db/check_migration_ownership.py' \
        'db/check_retention_rows.py' 'db/run_migration.py' 'db/expand_check.py' 'db/migration_guard_scope.py' 'db/tests/**' 'db/owners.yaml' 'db/isolation_probe.py' \
        'db/tour_liveness_gate.py' 'db/freshness_gate.py' 'db/scripts/**' 'db/templates/**' '.github/scripts/**' \
        '.github/workflows/db-isolation-probe.yml' '.github/workflows/db-tour-liveness-gate.yml' \
        '.github/workflows/db-freshness-probe.yml' '.github/workflows/db-migrate.yml' \
        '.github/workflows/db-schema-dump.yml' '.github/workflows/migration-copy-guard.yml' \
        'db/apply_pending.py' 'db/migration_sync.py' '.github/workflows/migration-apply.yml' \
        '.github/workflows/migration-sync.yml' 'tools/github/infra-main-ruleset.json' ;;
    ops-probe) # ops-probe-test.yml
      printf '%s\n' 'accounts/aa365/lambda_src/dfs_balance_check/**' 'accounts/aa365/lambda_src/dfs_balance_check_tests/**' \
        '.github/workflows/ops-probe-test.yml' ;;
    rds-snapshot-expiry) # rds-snapshot-expiry-test.yml
      printf '%s\n' 'accounts/aa365/lambda_src/rds_snapshot_expiry/**' 'accounts/aa365/lambda_src/rds_snapshot_expiry_tests/**' \
        '.github/workflows/rds-snapshot-expiry-test.yml' ;;
    secrets-register) # secrets-register-check-test.yml
      printf '%s\n' 'tools/secrets/**' '.github/workflows/secrets-register-check-test.yml' ;;
    tf-plan-guard) # tf-plan-guard-test.yml
      printf '%s\n' 'tools/terraform/**' '.github/workflows/terraform-apply.yml' '.github/workflows/tf-plan-guard-test.yml' \
        'accounts/aa365/crm_storage.tf' '.github/workflows/crm-key-policy-diff.yml' \
        '.github/workflows/terraform-drift.yml' '.github/workflows/terraform-plan.yml' 'tools/docs/aws_mask.py' \
        'accounts/management/**' ;;
    hook-self-test) # this hook
      printf '%s\n' 'scripts/pre-push.sh' 'scripts/install-hooks.sh' '.githooks/**' ;;
  esac
}

# GitHub glob -> anchored ERE, memoised in RE_CACHE (sets ERE).
declare -A RE_CACHE=()
glob_to_ere() {
  if [ -n "${RE_CACHE[$1]+x}" ]; then ERE=${RE_CACHE[$1]}; return; fi
  ERE=$(printf '%s' "$1" | sed -e 's/[.+^$(){}|[\]/\\&/g' -e 's#\*\*/#\x01#g' -e 's#\*\*#\x02#g' \
    -e 's#\*#[^/]*#g' -e 's#?#[^/]#g' -e 's#\x01#(.*/)?#g' -e 's#\x02#.*#g')
  ERE="^${ERE}\$"
  RE_CACHE[$1]=$ERE
}

# matches_any <newline-separated globs> <file>
matches_any() {
  local pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    glob_to_ere "$pat"
    [[ "$2" =~ $ERE ]] && return 0
  done <<<"$1"
  return 1
}

# Terraform roots: accounts/<root>/ with .tf files.
tf_roots() {
  local d
  for d in accounts/*/; do
    d=${d%/}
    compgen -G "$d/*.tf" >/dev/null && printf '%s\n' "${d#accounts/}"
  done
}

# Roots that call modules/<name> directly; the live root aa365 when none does (a module used only by another module).
roots_for_module() {
  local r found=0
  while IFS= read -r r; do
    if grep -qE "source[[:space:]]*=[[:space:]]*\"[./]*modules/$1\"" "accounts/$r"/*.tf 2>/dev/null; then
      printf '%s\n' "$r"; found=1
    fi
  done < <(tf_roots)
  [ "$found" = 1 ] || printf '%s\n' aa365
}

# Roots whose `terraform validate` a change set touches (the Terraform Plan workflow runs on every PR; locally only
# the roots whose HCL, lock file or modules changed).
touched_roots() {
  local f r m
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      accounts/*/*)
        r=${f#accounts/}; r=${r%%/*}
        if [[ "$f" =~ \.(tf|tfvars)$ ]] || [[ "$f" == "accounts/$r/.terraform.lock.hcl" ]]; then printf '%s\n' "$r"; fi ;;
      modules/*/*)
        m=${f#modules/}; m=${m%%/*}
        [[ "$f" =~ \.tf$ ]] && roots_for_module "$m" ;;
      .github/workflows/terraform-plan.yml) printf '%s\n' aa365 management ;;
    esac
  done | awk '!seen[$0]++'
}

# select_checks <fast|full> : reads the changed files on stdin, prints one check per line.
select_checks() {
  local mode=$1 files c r pats f
  files=$(cat)
  for c in "${CHECKS[@]}"; do
    if [ "$c" = tf-validate ]; then
      if [ "$mode" = full ]; then
        while IFS= read -r r; do echo "tf-validate:$r"; done < <(tf_roots)
      else
        # A root whose directory the change deleted has nothing left to init or validate.
        while IFS= read -r r; do
          [ -n "$r" ] && compgen -G "accounts/$r/*.tf" >/dev/null && echo "tf-validate:$r"
        done < <(printf '%s\n' "$files" | touched_roots)
      fi
      continue
    fi
    if [ "$mode" = full ]; then echo "$c"; continue; fi
    pats=$(patterns_for "$c")
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if matches_any "$pats" "$f"; then echo "$c"; break; fi
    done <<<"$files"
  done
}

# Changed .tf / .tfvars files that still exist (fast-mode targets of terraform fmt).
fmt_targets() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [[ "$f" =~ \.(tf|tfvars)$ ]] && [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# changed_files <base ref>: files changed on HEAD since its merge base with <base>, plus tracked edits not committed
# yet, one per line and never quoted (-z, so spaces, non-ASCII, quotes and backslashes come through as they are).
# Exit 1: no merge base (orphan branch, shallow clone). Exit 2: a path holds a newline. Any other git error: non-zero.
# The caller runs every check on a non-zero exit, so a listing that cannot be trusted never selects too little.
changed_files() {
  local mb f
  mb=$(git merge-base "$1" HEAD 2>/dev/null) || return 1
  { git -c core.quotePath=false diff -z --name-only --no-renames "$mb" HEAD &&
    git -c core.quotePath=false diff -z --name-only --no-renames HEAD; } |
    { while IFS= read -r -d '' f; do
        case "$f" in *$'\n'*) exit 2 ;; esac
        printf '%s\n' "$f"
      done; } |
    awk 'length && !seen[$0]++'
}

# ---------------------------------------------------------------------------------------------------------------
# --self-test: fixture diffs -> expected checks. Pure bash, no tool is invoked.
# ---------------------------------------------------------------------------------------------------------------
self_test() {
  local pass=0 fail=0 got want name files
  expect() { # expect <name> <files, comma-separated> <expected checks, space-separated>
    name=$1; files=$(tr ',' '\n' <<<"$2"); want=$3
    got=$(printf '%s\n' "$files" | select_checks fast | xargs)
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1)); printf 'FAIL %s\n  files: %s\n  want:  %s\n  got:   %s\n' "$name" "$2" "$want" "$got"
    fi
  }
  expect "empty diff" "" ""
  expect "doc page" "docs/runbooks/x.md" "docs-lint"
  expect "repo context" "CONTEXT.md" "docs-lint"
  expect "live root .tf" "accounts/aa365/alb.tf" \
    "tf-fmt tf-validate:aa365 alb-rule-order connection-budget docs-gen managed-login-branding"
  expect "identity .tf" "accounts/aa365/identity.tf" \
    "tf-fmt tf-validate:aa365 alb-rule-order connection-budget docs-gen identity-triggers managed-login-branding"
  expect "lambda source (no HCL)" "accounts/aa365/lambda_src/rds_snapshot_expiry/handler.py" \
    "alb-rule-order managed-login-branding rds-snapshot-expiry"
  expect "single * stops at /" "accounts/aa365/sub/deep.tf" \
    "tf-fmt tf-validate:aa365 alb-rule-order docs-gen managed-login-branding"
  expect "tfvars" "accounts/aa365/terraform.tfvars" "tf-fmt tf-validate:aa365 alb-rule-order managed-login-branding"
  expect "lock file" "accounts/aa365/.terraform.lock.hcl" "tf-validate:aa365 alb-rule-order managed-login-branding"
  expect "satellite root" "accounts/acc3-bedrock/batch.tf" "tf-fmt tf-validate:acc3-bedrock docs-gen"
  expect "module" "modules/rds/main.tf" "tf-fmt tf-validate:aa365 connection-budget docs-gen"
  expect "migration copy" "db/migrations/cis/300_x.sql" "connection-budget migration-guard"
  expect "crm migration copy" "db/migrations/crm/030_x.sql" "migration-guard"
  expect "plan guard tool" "tools/terraform/plan_guard.py" "alb-rule-order tf-plan-guard"
  expect "docs tool" "tools/docs/check_docs_text.py" "docs-gen docs-lint"
  expect "aws_mask (shared by db)" "tools/docs/aws_mask.py" "docs-gen docs-lint migration-guard tf-plan-guard"
  expect "secrets tool" "tools/secrets/register_check.py" "secrets-register"
  expect "contracts" "tools/contracts/contract_copies.json" "contract-copy"
  expect "identity tool" "tools/identity/workforce_bootstrap.py" "identity-triggers"
  expect "workflow file" "README.md,.github/workflows/identity-triggers-test.yml" "docs-lint identity-triggers"
  expect "terraform-plan workflow" ".github/workflows/terraform-plan.yml" "tf-validate:aa365 tf-validate:management tf-plan-guard"
  expect "management root (AA-1004)" "accounts/management/cicd.tf" "tf-fmt tf-validate:management docs-gen tf-plan-guard"
  expect "ci helper script" ".github/scripts/migrator-task.sh" "migration-guard"
  expect "this hook" "scripts/pre-push.sh,.githooks/pre-push" "hook-self-test"
  expect "untracked-like path" "dist/whatever.zip" ""
  expect "two roots" "accounts/aa365/lambda.tf,accounts/acc3-bedrock/batch.tf" \
    "tf-fmt tf-validate:aa365 tf-validate:acc3-bedrock alb-rule-order connection-budget docs-gen managed-login-branding"
  expect "space + Vietnamese .md" "docs/ghi chú.md" "docs-lint"
  expect "space + Vietnamese .tf" "accounts/aa365/tên mới.tf" \
    "tf-fmt tf-validate:aa365 alb-rule-order connection-budget docs-gen managed-login-branding"
  expect "deleted root (no .tf left)" "accounts/zz-deleted-root/main.tf,accounts/zz-deleted-root/.terraform.lock.hcl" \
    "tf-fmt docs-gen"

  # Full mode: every check, every root, whatever changed.
  got=$(printf '' | select_checks full | xargs)
  want="tf-fmt $(tf_roots | sed 's/^/tf-validate:/' | xargs) ${CHECKS[*]:2}"
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL full mode\n  want: %s\n  got:  %s\n' "$want" "$got"; fi

  # Glob translation edge cases.
  local cases=('**/*.md|README.md|y' '**/*.md|docs/a/b.md|y' 'accounts/aa365/*.tf|accounts/aa365/x/y.tf|n'
               'db/migrations/**|db/migrations/cis/1.sql|y' 'tools/docs/aws_mask.py|tools/docs/aws_maskXpy|n'
               'accounts/**/*.tf|accounts/aa365/a.tf|y' '.githooks/**|.githooks/pre-push|y')
  local c pat file exp res
  for c in "${cases[@]}"; do
    IFS='|' read -r pat file exp <<<"$c"
    if matches_any "$pat" "$file"; then res=y; else res=n; fi
    if [ "$res" = "$exp" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1)); printf 'FAIL glob %s vs %s: want %s got %s\n' "$pat" "$file" "$exp" "$res"; fi
  done

  # fmt targets: only changed .tf/.tfvars that exist.
  got=$(printf '%s\n' accounts/aa365/variables.tf accounts/aa365/gone_deleted.tf README.md | fmt_targets | xargs)
  if [ "$got" = "accounts/aa365/variables.tf" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL fmt_targets: got %s\n' "$got"; fi

  # changed_files on scratch git repos (git only): odd names come through unquoted, no merge base is an error.
  local scratch out
  scratch=$(mktemp -d) || { echo "FAIL scratch repo: mktemp"; return 1; }
  out=$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX
    cd "$scratch" || exit 1
    g() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@example.invalid "$@"; }
    { g init -q . && g checkout -q -b main && mkdir -p docs accounts/aa365 && echo a >docs/a.md &&
      g add -A && g commit -qm base && g branch -q base &&
      echo x >"docs/ghi chú.md" && echo x >'docs/q"b\c.md' && echo '# x' >"accounts/aa365/tên mới.tf" &&
      g add -A && g commit -qm odd && echo b >>docs/a.md; } >/dev/null 2>&1 || { echo "setup failed"; exit 1; }
    printf 'committed+dirty=%s\n' "$(changed_files base | tr '\n' '|')"
    g checkout -q --orphan lone >/dev/null 2>&1 && g commit -qm lone >/dev/null 2>&1
    changed_files base >/dev/null 2>&1; printf 'orphan-rc=%s\n' "$?"
  )
  rm -rf "$scratch"
  local want_cf='committed+dirty=accounts/aa365/tên mới.tf|docs/ghi chú.md|docs/q"b\c.md|docs/a.md|'
  if grep -qxF "$want_cf" <<<"$out"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL changed_files odd names\n  want: %s\n  got:  %s\n' "$want_cf" "$out"; fi
  if grep -qx 'orphan-rc=1' <<<"$out"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL changed_files without merge base: want exit 1\n  got: %s\n' "$out"; fi

  echo "pre-push self-test: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

if [ "$MODE" = self-test ]; then self_test; exit $?; fi

# ---------------------------------------------------------------------------------------------------------------
# Environment: Python, Terraform, log folder.
# ---------------------------------------------------------------------------------------------------------------
pick_python() {
  local p
  for p in "$PY_OVERRIDE" "$TOP/.venv/bin/python" "$MAIN_TOP/.venv/bin/python"; do
    [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return; }
  done
  command -v python3 || command -v python
}
PY=$(pick_python)
[ -n "$PY" ] || { echo "pre-push: no python3 on PATH" >&2; exit 2; }
PYQ=$(printf '%q' "$PY")
PY_PINNED=$(sed -n 's/.*python-version:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' .github/workflows/*.yml | sort -u | head -1)

TF_PINNED=$(sed -n 's/.*terraform_version:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' .github/workflows/terraform-plan.yml | head -1)
LOG_DIR="$GIT_DIR_ABS/aa-prepush/last-run"
rm -rf "$LOG_DIR" && mkdir -p "$LOG_DIR"

# Changed files: committed vs the merge base with BASE, plus tracked edits not committed yet.
CHANGED=""
if [ "$MODE" = fast ]; then
  if ! git rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
    echo "pre-push: $BASE is not available locally (the hook never fetches); running every check (--full)."
    MODE=full
  else
    CHANGED=$(changed_files "$BASE")
    rc=$?
    if [ "$rc" -ne 0 ]; then
      case "$rc" in
        1) echo "pre-push: no merge base with $BASE; running every check (--full)" ;;
        2) echo "pre-push: a changed path holds a newline; running every check (--full)" ;;
        *) echo "pre-push: listing the files changed vs $BASE failed (exit $rc); running every check (--full)" ;;
      esac
      MODE=full
      CHANGED=""
    fi
  fi
fi
DIRTY=$(git -c core.quotePath=false diff --name-only HEAD | head -1)

mapfile -t SELECTED < <(printf '%s\n' "$CHANGED" | select_checks "$MODE")

if [ "$LIST_ONLY" = 1 ]; then
  printf 'mode: %s, base: %s, changed files: %s\n' "$MODE" "$BASE" "$(printf '%s' "$CHANGED" | grep -c . || true)"
  printf '%s\n' "${SELECTED[@]}"
  exit 0
fi

# ---------------------------------------------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------------------------------------------
# Failures as parallel arrays: a command can hold `|` and newlines.
F_CHECK=(); F_LABEL=(); F_CMD=(); F_LOG=(); F_HINT=()
SKIPPED=()     # "check / label: reason"
CI_ONLY=()     # "what (workflow)"
N_OK=0

add_failure() { F_CHECK+=("$1"); F_LABEL+=("$2"); F_CMD+=("$3"); F_LOG+=("$4"); F_HINT+=("$5"); }

now_ms() { date +%s%3N; }
elapsed() { local ms=$(( $(now_ms) - $1 )); printf '%d.%01ds' $((ms / 1000)) $(((ms % 1000) / 100)); }

# The packages the CI test steps pip-install (same line as scripts/install-hooks.sh --venv).
PIP_LINE='-m pip install "pytest>=8,<10" pyyaml==6.0.2 "boto3>=1.36,<2" -r tools/docs/requirements.txt'

# install_hint <bin name | py:module>
install_hint() {
  case "$1" in
    terraform) printf 'install Terraform %s (HashiCorp apt repo, or: tfenv install %s)' "${TF_PINNED:-<CI version>}" "${TF_PINNED:-<CI version>}" ;;
    jq|shellcheck) printf 'sudo apt-get install -y %s' "$1" ;;
    lychee) printf 'download the release binary from github.com/lycheeverse/lychee/releases (or: cargo install lychee)' ;;
    py:*) printf 'scripts/install-hooks.sh --venv (or: %s %s)' "$PYQ" "$PIP_LINE" ;;
    *) printf 'install %s' "$1" ;;
  esac
}

# missing_reqs "py:pytest,py:yaml,bin:jq" -> one line per missing requirement: "<what><TAB><install hint>"
missing_reqs() {
  local req IFS=,
  for req in $1; do
    case "$req" in
      py:*) "$PY" -c "import ${req#py:}" >/dev/null 2>&1 ||
        printf 'python module %s (in %s)\t%s\n' "${req#py:}" "$PY" "$(install_hint "$req")" ;;
      bin:*) command -v "${req#bin:}" >/dev/null 2>&1 ||
        printf '%s on PATH\t%s\n' "${req#bin:}" "$(install_hint "${req#bin:}")" ;;
    esac
  done
}

# step <check> <label> <requirements> <command> [fix hint]
# A missing requirement fails the step (install hint in the report); AA_PREPUSH_ALLOW_MISSING=1 makes it a skip,
# except under --ci. The command runs with `bash -e -c`, as a GitHub `run:` step without `shell:` (bash -e {0}).
step() {
  local check=$1 label=$2 reqs=$3 cmd=$4 hint=${5:-} miss names hints t0 log rc
  miss=$(missing_reqs "$reqs")
  if [ -n "$miss" ]; then
    names=$(cut -f1 <<<"$miss" | paste -sd, - | sed 's/,/, /g')
    hints=$(cut -f2 <<<"$miss" | awk '!seen[$0]++' | sed 's/^/install: /')
    if [ "$CI_MODE" = 1 ] || [ "${AA_PREPUSH_ALLOW_MISSING:-}" != 1 ]; then
      add_failure "$check" "$label" "$cmd" "" "missing: $names"$'\n'"$hints"
      printf '  FAIL  %-24s %s (missing: %s)\n' "$check" "$label" "$names"
    else
      SKIPPED+=("$check / $label: missing $names"); printf '  skip  %-24s %s (missing: %s)\n' "$check" "$label" "$names"
    fi
    return
  fi
  log="$LOG_DIR/$check.$(tr -c 'a-zA-Z0-9' '_' <<<"$label").log"
  t0=$(now_ms)
  bash -e -c "$cmd" >"$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    N_OK=$((N_OK + 1)); printf '  ok    %-24s %s (%s)\n' "$check" "$label" "$(elapsed "$t0")"
  else
    add_failure "$check" "$label" "$cmd" "$log" "$hint"; printf '  FAIL  %-24s %s (%s, exit %d)\n' "$check" "$label" "$(elapsed "$t0")" "$rc"
  fi
}

ci_only() { CI_ONLY+=("$1"); }

# Shape of db/scripts files: the loop of migration-copy-guard.yml (job lint), with the same interpreter.
SHAPE_LOOP='status=0
for f in db/scripts/*.py; do
  [ -e "$f" ] || continue
  if ! [[ "$f" =~ ^db/scripts/[a-z0-9_]+\.py$ ]]; then
    echo "::error file=$f::name must be db/scripts/<lower case, digits, underscores>.py"; status=1; continue
  fi
  out=$(@PY@ db/run_migration.py --inspect-script "$f") || status=1
  jq -r --arg f "$f" '"'"'.errors[] | "::error file=" + $f + "::" + .'"'"' <<<"$out"
done
exit "$status"'

# Root repo checkout that holds the DM-7 retention registry (for scoped CRM copies), when it sits next to us.
root_registry() {
  # Called in a command substitution (subshell): a hook environment must not point these git calls at this repo.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX
  local root=${AA_ECOSYS_ROOT:-$(cd "$MAIN_TOP/../.." 2>/dev/null && pwd)} path=docs/architecture/data-standards/02-data-management.md
  [ -n "$root" ] && git -C "$root" rev-parse --verify -q origin/master >/dev/null 2>&1 || return 1
  git -C "$root" show "origin/master:$path" >"$LOG_DIR/registry.md" 2>/dev/null && printf '%s' "$LOG_DIR/registry.md"
}

run_check() {
  local c=$1 files root tfdata cache scoped reg
  case "$c" in
    tf-fmt)
      if [ -n "$TF_PINNED" ] && command -v terraform >/dev/null 2>&1; then
        local have; have=$(terraform version 2>/dev/null | sed -n '1s/^Terraform v//p')
        [ "$have" = "$TF_PINNED" ] || echo "  note  terraform $have locally, CI pins $TF_PINNED (terraform-plan.yml): fmt rules can differ"
      fi
      if [ "$MODE" = full ]; then
        step "$c" "terraform fmt (all)" bin:terraform "terraform fmt -check -diff -recursive -no-color" \
          "terraform fmt -recursive"
      else
        files=$(printf '%s\n' "$CHANGED" | fmt_targets | while IFS= read -r f; do printf '%q ' "$f"; done)
        files=${files% }
        [ -n "$files" ] || return 0
        step "$c" "terraform fmt (changed files)" bin:terraform "terraform fmt -check -diff -no-color $files" \
          "terraform fmt $files"
      fi ;;
    tf-validate:*) # terraform-plan.yml runs init + validate (+ plan, CI only); init here is backend-less
      root=${c#tf-validate:}
      tfdata="$GIT_DIR_ABS/aa-prepush/tf-data/$root"
      cache=${TF_PLUGIN_CACHE_DIR:-}
      if [ -z "$cache" ]; then
        if [ -d "$HOME/.terraform.d/plugin-cache" ]; then cache="$HOME/.terraform.d/plugin-cache"
        else cache="$COMMON_DIR/aa-prepush/tf-plugin-cache"; mkdir -p "$cache"; fi
      fi
      step "$c" "terraform init -backend=false + validate" bin:terraform \
        "export TF_DATA_DIR=$(printf '%q' "$tfdata") TF_PLUGIN_CACHE_DIR=$(printf '%q' "$cache") TF_IN_AUTOMATION=1 && terraform -chdir=accounts/$root init -backend=false -input=false -lockfile=readonly -no-color && terraform -chdir=accounts/$root validate -no-color"
      [ "$root" = aa365 ] && ci_only "terraform plan (Terraform Plan, needs AWS)" ;;
    alb-rule-order)
      step "$c" "pytest" py:pytest "$PYQ -B -m pytest -p no:cacheprovider -q tools/terraform/tests/test_alb_rule_order.py tools/terraform/tests/test_crm_edge_live_check.py tools/terraform/tests/test_crm_kms_alarm_check.py"
      step "$c" "alb_rule_order.py" "" "$PYQ -B tools/terraform/alb_rule_order.py --source accounts/aa365" ;;
    connection-budget)
      step "$c" "unittest" "" "$PYQ -B -m unittest db/tests/test_connection_budget.py -v"
      if [ "$CI_MODE" = 1 ]; then
        step "$c" "budget --verify-sources" "" "$PYQ -B db/check_connection_budget.py --verify-sources"
      else
        step "$c" "budget (no source verify)" "" "$PYQ -B db/check_connection_budget.py"
        ci_only "connection budget --verify-sources (reads app sources on GitHub)"
      fi ;;
    contract-copy)
      step "$c" "unittest" "" "$PYQ -m unittest discover -s tools/contracts/tests -v"
      ci_only "contract copies vs pins (Contract Copy Guard, network)" ;;
    docs-gen)
      step "$c" "unittest" "" "$PYQ -m unittest discover -s tools/docs/tests -v"
      step "$c" "gen_docs check-source" "" "$PYQ tools/docs/gen_docs.py check-source accounts modules" ;;
    docs-lint)
      step "$c" "unittest" py:jsonschema,py:yaml "$PYQ -m unittest discover -s tools/docs -p 'test_*.py'"
      step "$c" "front-matter" py:jsonschema,py:yaml "$PYQ tools/docs/check_frontmatter.py"
      step "$c" "ADR index" "" "$PYQ tools/docs/check_adr_index.py docs/adr"
      step "$c" "single-line AWS CLI" "" "$PYQ tools/docs/check_docs_text.py aws-multiline --all"
      step "$c" "resource IDs" "" "$PYQ tools/docs/check_docs_text.py resource-ids --all --mode warn --block vpc,apigw"
      step "$c" "internal links (lychee, offline)" bin:lychee "lychee --config tools/docs/lychee.toml './**/*.md'" ;;
    identity-triggers)
      step "$c" "trigger tests" py:pytest "cd accounts/aa365 && $PYQ -m pytest -p no:cacheprovider -q lambda_src/identity_triggers_tests"
      step "$c" "bootstrap tool tests" py:pytest,py:boto3 "$PYQ -m pytest -p no:cacheprovider -q tools/identity/tests" ;;
    managed-login-branding)
      step "$c" "pytest" py:pytest "$PYQ -B -m pytest -p no:cacheprovider -q tools/terraform/tests/test_managed_login_branding.py"
      step "$c" "coverage" "" "$PYQ -B tools/terraform/managed_login_branding.py --source accounts/aa365" ;;
    migration-guard)
      step "$c" "guard unit tests" py:yaml "$PYQ -m unittest discover -s db/tests -v"
      step "$c" "migration lint + numbers" "" "$PYQ db/check_migration_files.py"
      step "$c" "db/scripts shape" bin:jq "${SHAPE_LOOP//@PY@/$PYQ}"
      scoped=$("$PY" db/check_retention_rows.py --scoped 2>/dev/null)
      if [ "$scoped" = yes ]; then
        if reg=$(root_registry); then
          step "$c" "retention rows (root master)" "" "$PYQ db/check_retention_rows.py --registry $(printf '%q' "$reg")"
        else
          ci_only "retention rows for new-app tables (needs the root repo registry; set AA_ECOSYS_ROOT)"
        fi
      else
        step "$c" "retention rows" "" "$PYQ db/check_retention_rows.py"
      fi
      ci_only "migration copies vs owner main (Migration Copy Guard, network)" ;;
    ops-probe)
      step "$c" "unittest" "" "cd accounts/aa365 && $PYQ -B -m unittest discover -s lambda_src/dfs_balance_check_tests -v" ;;
    rds-snapshot-expiry)
      step "$c" "unittest" "" "cd accounts/aa365 && $PYQ -B -m unittest discover -s lambda_src/rds_snapshot_expiry_tests -v" ;;
    secrets-register)
      step "$c" "pytest" py:pytest,py:yaml "$PYQ -m pytest -p no:cacheprovider -q tools/secrets/tests" ;;
    tf-plan-guard)
      step "$c" "pytest" py:pytest,py:yaml "$PYQ -m pytest -p no:cacheprovider -q tools/terraform/tests"
      step "$c" "guarded fixture is refused" "" \
        "set +e; $PYQ -B tools/terraform/plan_guard.py tools/terraform/tests/fixtures/plan_guarded.json; rc=\$?; set -e; [ \"\$rc\" -eq 1 ] || { echo \"expected exit 1 (refused), got \$rc\" >&2; exit 1; }" ;;
    hook-self-test)
      step "$c" "--self-test" "" "bash scripts/pre-push.sh --self-test"
      step "$c" "shellcheck" bin:shellcheck "shellcheck -S warning scripts/pre-push.sh scripts/install-hooks.sh .githooks/pre-push" ;;
  esac
}

# ---------------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------------
T_START=$(now_ms)
n_changed=$(printf '%s' "$CHANGED" | grep -c . || true)
if [ "$MODE" = full ]; then
  echo "pre-push ($([ "$CI_MODE" = 1 ] && echo ci || echo full)): every check; python $PY"
else
  echo "pre-push (fast): $n_changed changed file(s) vs $BASE; python $PY"
fi
[ -n "$DIRTY" ] && echo "  note  uncommitted changes in tracked files: the checks see the working tree, the push sends commits only"
PY_HAVE=$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo unknown)
if [ -n "$PY_PINNED" ] && [ "$PY_HAVE" != "$PY_PINNED" ]; then
  echo "  note  python $PY_HAVE locally, CI pins $PY_PINNED (setup-python in the workflows): results can differ"
fi

if [ ${#SELECTED[@]} -eq 0 ]; then
  echo "pre-push: no check covers the changed files. ok ($(elapsed "$T_START"))"
  exit 0
fi

for c in "${SELECTED[@]}"; do run_check "$c"; done
ci_only "gitleaks (Secret Scan)"

echo
if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "Skipped (AA_PREPUSH_ALLOW_MISSING=1 and a tool or module is missing here; CI still runs these steps):"
  for s in "${SKIPPED[@]}"; do echo "  - $s"; done
  if printf '%s\n' "${SKIPPED[@]}" | grep -q 'python module'; then
    echo "  Python modules: point AA_PREPUSH_PYTHON at a venv, or create one with scripts/install-hooks.sh --venv"
  fi
fi
echo "CI only (not run here): $(printf '%s; ' "${CI_ONLY[@]}" | sed 's/; $//')"

if [ ${#F_CHECK[@]} -gt 0 ]; then
  echo
  echo "pre-push: ${#F_CHECK[@]} step(s) failed, push blocked ($(elapsed "$T_START"))."
  for i in "${!F_CHECK[@]}"; do
    c=${F_CHECK[$i]} l=${F_LABEL[$i]} cmd=${F_CMD[$i]} log=${F_LOG[$i]} hint=${F_HINT[$i]}
    echo
    echo "FAIL $c / $l"
    echo "  command (run from the repo root):"
    printf '%s\n' "$cmd" | sed 's/^/    /'
    if [ -n "$log" ] && [ -s "$log" ]; then
      echo "  output (last 25 lines, full log: $log):"
      tail -n 25 "$log" | sed 's/^/    | /'
    fi
    if [ -n "$hint" ]; then
      case "$hint" in
        missing:*) printf '%s\n' "$hint" | sed 's/^/  /'; any_missing=1 ;;
        *) echo "  fix: $hint" ;;
      esac
    fi
  done
  echo
  echo "Re-run: scripts/pre-push.sh$([ "$MODE" = full ] && echo ' --full')"
  if [ "${any_missing:-0}" = 1 ] && [ "$CI_MODE" != 1 ]; then
    echo "Skip the steps whose tool is missing, for one run (CI still runs them): AA_PREPUSH_ALLOW_MISSING=1 git push"
  fi
  echo "Bypass for this push only (CI still checks the PR): git push --no-verify"
  exit 1
fi

echo "pre-push: $N_OK step(s) ok, ${#SKIPPED[@]} skipped ($(elapsed "$T_START"))."
exit 0
