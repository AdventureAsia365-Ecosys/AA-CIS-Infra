# AA-1024: PR text guard and workflow lint (lane l8-lessons-guards-rest, S272)

Guards G11 and G15 of the S271 lessons-to-guards design (root repo `docs/audits/2026-11-07-S271-lessons-to-guards/`).

## Decisions

- `.github/workflows/pr-title.yml` now refuses an issue id anywhere in the PR title (it refused only `[AA-123]`):
  Linear reads "fix: AA-123 ..." as a closing phrase and moved issues to Done on merge (lessons S246).
- The body check also refuses an issue id that the `Refs AA-<n>, ...` line does not name: Linear links every id in a
  PR body and its Git automation moved linked issues to Done on merge (lessons S243, S244). An id the Refs line names
  may appear anywhere (the PR's own issue in prose), and an id inside a file path (`implementation-notes/AA-1024-x.md`)
  is ignored (review fix pass). Bot PRs skip only this rule, by login (Dependabot, github-actions, the CI bot) or by a
  `bot/*` / release-please head branch, never by `user.type`: the orchestrator's App `aa-agent[bot]` is a Bot too.
- The same file (rules and wording) is in every repo: root, AA-CIS-App, AA-Booking, AA-Partner, AA-TripPlanner-Web,
  AA-CIS-Infra; only the merge-queue branch (`merge_group`) differs. The orchestrator's PR opener applies the same rules
  before it pushes (root `tools/github`).
- G15 workflow lint (review fix pass): `.github/scripts/workflow_lint.py` is now the one copy vendored into the root,
  AA-CIS-App, AA-Booking, AA-Partner and AA-TripPlanner-Web. Changes: `--skip WL1[,..]` for a repo that still has uses
  to move; shell comments inside a `run:` are not a Playwright use (CIS kit-consumers.yml mentioned Playwright in a
  comment); an `npm ci` in an expression `working-directory` (a matrix of other repos' apps) is listed as unchecked, not
  refused. Tests updated (`tools/terraform/tests/test_workflow_lint.py`).

## Changed

- Nothing else: the job keeps its name `PR title`, so a required check that matches it stays matched.

## Tradeoffs

- A PR that joins another issue's work now writes that issue on the Refs line (`Refs AA-1, AA-2`) or in words.

## Should know

- The check reads the PR event payload: after editing a title or body, the `edited` event reruns it.
