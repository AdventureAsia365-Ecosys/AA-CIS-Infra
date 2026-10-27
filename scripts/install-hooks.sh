#!/usr/bin/env bash
# Install the repo's git hooks (AA-993 H1): git config core.hooksPath .githooks
#
#   scripts/install-hooks.sh             point core.hooksPath at .githooks (shared by every worktree of this clone)
#   scripts/install-hooks.sh --venv      also create .venv with the Python packages the CI test steps install
#   scripts/install-hooks.sh --force     replace a different core.hooksPath that is already set
#   scripts/install-hooks.sh --uninstall git config --unset core.hooksPath
#
# The hook runs scripts/pre-push.sh before every push (fast mode). Bypass once: git push --no-verify

set -euo pipefail

top=$(git rev-parse --show-toplevel)
cd "$top"

venv=0
force=0
for a in "$@"; do
  case "$a" in
    --venv) venv=1 ;;
    --force) force=1 ;;
    --uninstall)
      git config --unset core.hooksPath || true
      echo "core.hooksPath removed; git uses .git/hooks again."
      exit 0 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install-hooks: unknown option $a" >&2; exit 2 ;;
  esac
done

current=$(git config --get core.hooksPath || true)
if [ -n "$current" ] && [ "$current" != ".githooks" ] && [ "$force" -ne 1 ]; then
  echo "install-hooks: core.hooksPath is already '$current'. Re-run with --force to replace it." >&2
  exit 1
fi
chmod +x .githooks/pre-push scripts/pre-push.sh
git config core.hooksPath .githooks
echo "core.hooksPath = .githooks (every worktree of this clone). Undo: scripts/install-hooks.sh --uninstall"

# The packages the CI test steps pip-install (alb-rule-order, identity-triggers, managed-login-branding,
# secrets-register-check-test, tf-plan-guard-test and docs-lint workflows).
if [ "$venv" -eq 1 ]; then
  python3 -m venv .venv
  .venv/bin/python -m pip install --quiet "pytest>=8,<10" pyyaml==6.0.2 "boto3>=1.36,<2" -r tools/docs/requirements.txt
  echo ".venv ready; scripts/pre-push.sh uses it automatically."
fi

echo
echo "Tools the checks use (missing ones are skipped locally, CI still runs them):"
pinned=$(sed -n 's/.*terraform_version:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' .github/workflows/terraform-plan.yml | head -1)
if command -v terraform >/dev/null 2>&1; then
  echo "  terraform $(terraform version | sed -n '1s/^Terraform v//p') (CI pins $pinned)"
else
  echo "  terraform: missing (CI pins $pinned)"
fi
for t in jq lychee shellcheck; do
  if command -v "$t" >/dev/null 2>&1; then echo "  $t: ok"; else echo "  $t: missing"; fi
done
py=python3
for p in "${AA_PREPUSH_PYTHON:-}" "$top/.venv/bin/python"; do
  if [ -n "$p" ] && [ -x "$p" ]; then py=$p; break; fi
done
for m in pytest yaml jsonschema boto3; do
  if "$py" -c "import $m" >/dev/null 2>&1; then echo "  python $m: ok ($py)"; else echo "  python $m: missing ($py)"; fi
done
