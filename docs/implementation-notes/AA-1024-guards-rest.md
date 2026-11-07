# AA-1024: PR text guard (lane l8-lessons-guards-rest, S272)

Guard G11 of the S271 lessons-to-guards design (root repo `docs/audits/2026-11-07-S271-lessons-to-guards/`).

## Decisions

- `.github/workflows/pr-title.yml` now refuses an issue id anywhere in the PR title (it refused only `[AA-123]`):
  Linear reads "fix: AA-123 ..." as a closing phrase and moved issues to Done on merge (lessons S246).
- The body check also refuses an issue id outside the one `Refs AA-<n>, ...` line: Linear links every id in a PR body
  and its Git automation moved linked issues to Done on merge (lessons S243, S244). Bot PRs (Dependabot,
  release-please, `bot/*` branches) skip only this rule.
- The same file (rules and wording) is in every repo: root, AA-CIS-App, AA-Booking, AA-Partner, AA-TripPlanner-Web,
  AA-CIS-Infra; only the merge-queue branch (`merge_group`) differs. The orchestrator's PR opener applies the same rules
  before it pushes (root `tools/github`).

## Changed

- Nothing else: the job keeps its name `PR title`, so a required check that matches it stays matched.

## Tradeoffs

- A PR that joins another issue's work now writes that issue on the Refs line (`Refs AA-1, AA-2`) or in words.

## Should know

- The check reads the PR event payload: after editing a title or body, the `edited` event reruns it.
