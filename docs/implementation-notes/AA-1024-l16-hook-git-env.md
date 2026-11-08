# AA-1024 l16 — the pre-push hook drops git's repo-local variables (S273)

## Problem

Git exports `GIT_DIR` (and in some setups `GIT_WORK_TREE`, `GIT_INDEX_FILE`, ...) to the hooks it runs. In a linked
worktree `GIT_DIR` is `<clone>/.git/worktrees/<name>`. Under the pre-push hook:

- the docs unittest `tools/docs/test_docs_tools.py::test_journals_are_out_of_scope` listed the real repo
  (`git -C <tmp> ls-files` still follows `GIT_DIR`) instead of its temporary dir, and failed;
- `tools/terraform/tests/test_workflow_lint.py::test_wl3_npm_ci_needs_a_tracked_lockfile` ran `git init <tmp>` with
  the inherited `GIT_DIR`. Git then initialises `GIT_DIR`, not the temp dir, and guesses a bare repo for a path that
  does not end in `/.git`: `core.bare=true` landed in the config every worktree of the clone shares, and the main
  checkout broke until `git config --local core.bare false`.

The root repo fixed the same class in S272 (root `.githooks/pre-push`, `tools/github/test_git_env_isolation.py`).

## Decisions

- **Same three layers as the root fix.** `.githooks/pre-push` cds to the top level and runs
  `unset $(git rev-parse --local-env-vars)` before reading stdin or running anything; `scripts/pre-push.sh` does the
  same right after its own `cd "$TOP"` (it is also run by hand and by other wrappers), and `--self-test` reports
  `ok   no GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE in the environment`; the one Infra test that runs git in a temp
  repo drops the variables itself.
- **The list comes from git** (`--local-env-vars`) in the shell scripts and in the new test, so a newer git that adds a
  variable is covered without an edit. The Python test keeps a static tuple (`GIT_REPO_VARS`, same as the root
  helpers); the scan test fails when git reports a name the tuple lacks.
- **The two partial `unset` lines in `pre-push.sh`** (self-test scratch repo, `root_registry`) are removed: the
  top-level unset covers both, and their lists missed `GIT_ALTERNATE_OBJECT_DIRECTORIES` and others.
- **Regression test `scripts/test_git_env_isolation.py`** (unittest) builds a sentinel clone with a linked worktree
  (the incident shape) and checks, with `GIT_DIR` of that worktree leaked: the hook passes no repo-local variable to
  the check runner and runs it from the top level, and the docs unittest and the git-init test pass through it;
  `pre-push.sh --self-test` drops them; the git-init test alone leaves the sentinel untouched; `core.bare` stays
  `false` and `core.hooksPath` stays `.githooks`. A control test proves the sentinel sees a leak (the docs unittest
  fails when run with the leak and no hook).
- **Where it runs:** the `hook-self-test` check of `scripts/pre-push.sh` (paths: the hook, the two scripts, the new
  test and `test_workflow_lint.py`). It is not wired into a CI workflow: no workflow runs the hook files today.

## Changed

- `.gitignore` gets `!/scripts/test_git_env_isolation.py` (the root `scripts/*` is ignored except the hook scripts).
- `docslib.py` / `test_docs_tools.py` are not changed: they are vendored copies of the root `tools/docs/` (and
  AA-Booking's); the hook fix is what keeps the docs unittest correct here.

## Tradeoffs

- `unset $(git rev-parse --local-env-vars)` also drops `GIT_CONFIG_PARAMETERS` (`git -c x=y push`): the checks then do
  not see one-off `-c` settings. Same choice as the root repo; the checks never relied on them.

## Should know

- The app repos (CIS, Booking, Partner, TripPlanner) were checked: their `scripts/pre-push.sh` already drops the
  variables first thing (S272), and their hooks only run read-only git commands before calling it. No change there.
- Follow-up idea, not done here: `docslib.list_markdown` could drop the repo-local variables for its `git -C` call; it
  is a vendored file, so that change starts in the root repo and is copied to Booking and Infra.
