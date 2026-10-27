#!/usr/bin/env bash
# Install the repo's git hooks (AA-993 H1): git config core.hooksPath .githooks
#
#   scripts/install-hooks.sh             point core.hooksPath at .githooks (shared by every worktree of this clone)
#   scripts/install-hooks.sh --venv      also create .venv with the Python packages the CI test steps install
#   scripts/install-hooks.sh --force     replace (or, with --uninstall, remove) a core.hooksPath other than .githooks
#   scripts/install-hooks.sh --uninstall git config --unset core.hooksPath (only when it is .githooks, else --force)
#
# The hook runs scripts/pre-push.sh before every push (fast mode). Bypass once: git push --no-verify
# A tool a selected check needs and that is missing fails the push; AA_PREPUSH_ALLOW_MISSING=1 skips it instead.

set -euo pipefail

top=$(git rev-parse --show-toplevel)
cd "$top"

venv=0
force=0
uninstall=0
for a in "$@"; do
  case "$a" in
    --venv) venv=1 ;;
    --force) force=1 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install-hooks: unknown option $a" >&2; exit 2 ;;
  esac
done

# Hooks in the clone's own hooks folder (shared by its worktrees) that are not git's *.sample files.
hooks_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd)/hooks"
own_hooks() {
  local f
  [ -d "$hooks_dir" ] || return 0
  for f in "$hooks_dir"/*; do
    [ -f "$f" ] && [ -x "$f" ] && [[ "$f" != *.sample ]] && printf '%s ' "$(basename "$f")"
  done
  return 0
}

current=$(git config --get core.hooksPath || true)

if [ "$uninstall" -eq 1 ]; then
  if [ -z "$current" ]; then
    echo "core.hooksPath is not set; nothing to undo."
    exit 0
  fi
  if [ "$current" != ".githooks" ] && [ "$force" -ne 1 ]; then
    echo "install-hooks: core.hooksPath is '$current', not .githooks (not set by this script). Re-run with --force to remove it." >&2
    exit 1
  fi
  git config --unset core.hooksPath
  echo "core.hooksPath ('$current') removed; git uses $hooks_dir again."
  hooks=$(own_hooks)
  [ -z "$hooks" ] || echo "  warning: these hooks in $hooks_dir run again from now on: $hooks"
  exit 0
fi

if [ -n "$current" ] && [ "$current" != ".githooks" ] && [ "$force" -ne 1 ]; then
  echo "install-hooks: core.hooksPath is already '$current'. Re-run with --force to replace it." >&2
  exit 1
fi
chmod +x .githooks/pre-push scripts/pre-push.sh
git config core.hooksPath .githooks
echo "core.hooksPath = .githooks (every worktree of this clone). Undo: scripts/install-hooks.sh --uninstall"
hooks=$(own_hooks)
[ -z "$hooks" ] || echo "  warning: core.hooksPath disables these hooks in $hooks_dir: $hooks(move what you still need into .githooks)"

# The packages the CI test steps pip-install (alb-rule-order, identity-triggers, managed-login-branding,
# secrets-register-check-test, tf-plan-guard-test and docs-lint workflows). Same line as PIP_LINE in pre-push.sh.
if [ "$venv" -eq 1 ]; then
  python3 -m venv .venv
  .venv/bin/python -m pip install --quiet "pytest>=8,<10" pyyaml==6.0.2 "boto3>=1.36,<2" -r tools/docs/requirements.txt
  echo ".venv ready; scripts/pre-push.sh uses it automatically."
fi

echo
echo "Tools the checks use (a missing one fails the steps that need it; AA_PREPUSH_ALLOW_MISSING=1 skips them):"
pinned=$(sed -n 's/.*terraform_version:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' .github/workflows/terraform-plan.yml | head -1)
if command -v terraform >/dev/null 2>&1; then
  echo "  terraform $(terraform version | sed -n '1s/^Terraform v//p') (CI pins $pinned)"
else
  echo "  terraform: missing (CI pins $pinned). Install: Terraform $pinned (HashiCorp apt repo, or: tfenv install $pinned)"
fi
for t in jq lychee shellcheck; do
  if command -v "$t" >/dev/null 2>&1; then echo "  $t: ok"; continue; fi
  case "$t" in
    lychee) hint="download the release binary from github.com/lycheeverse/lychee/releases (or: cargo install lychee)" ;;
    *) hint="sudo apt-get install -y $t" ;;
  esac
  echo "  $t: missing. Install: $hint"
done
py=python3
for p in "${AA_PREPUSH_PYTHON:-}" "$top/.venv/bin/python"; do
  if [ -n "$p" ] && [ -x "$p" ]; then py=$p; break; fi
done
py_missing=0
for m in pytest yaml jsonschema boto3; do
  if "$py" -c "import $m" >/dev/null 2>&1; then echo "  python $m: ok ($py)"; else echo "  python $m: missing ($py)"; py_missing=1; fi
done
if [ "$py_missing" -eq 1 ]; then
  echo "  Python modules: scripts/install-hooks.sh --venv (or: $py -m pip install \"pytest>=8,<10\" pyyaml==6.0.2 \"boto3>=1.36,<2\" -r tools/docs/requirements.txt)"
fi
