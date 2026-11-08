# AA-1024 lane l15: every GitHub Action pinned to a full-length commit SHA

Session S273 (08/11/2026). Goal: the tech lead can switch on the org setting "Require actions to be pinned to a
full-length commit SHA" (root ADR 0021, decision 2.3) without a red run in any of the six repositories.

## Decisions

- Each tag was resolved to the commit it points to today with read-only `gh api repos/<owner>/<repo>/git/ref/tags/<tag>`
  (annotated tags dereferenced to their commit). No version moved: a moving major tag (`v7`) was pinned to the commit
  it names today, and the comment is the most precise release tag on that same commit (`v7` -> `# v7.0.1`), the
  AA-CIS-Infra style, so Dependabot and readers see the exact release.
- New rule **WL6 action-pin** in `.github/scripts/workflow_lint.py` (the file stays byte-identical in all six repos):
  every `uses:` of a reusable-workflow job, a job step or a composite action step must be
  `<owner>/<repo>[/<path>]@<40-hex sha>` with a trailing `# vX.Y.Z` comment. Exempt: local `./` paths and
  `docker://<image>@sha256:<digest>`. `--skip` cannot turn WL6 off (the org setting refuses a tag pin anyway).
- WL4 read the setup-node major from the tag; a SHA pin hides it (YAML drops comments), so `_major` now also reads the
  `# vN` comment of the same line (`pin_tags`). Without it setup-node v4 pins would be asked for
  `package-manager-cache: false`, an input v4 does not have.
- Dependabot: the existing `github-actions` entry (weekly, grouped) now reads `directories: ["/", "/.github/actions/*"]`
  so the composite actions are bumped too. The root repo had no `.github/dependabot.yml`; it gets one (weekly, one
  group, limit 1). Dependabot PRs are reviewed and merged like any PR; no auto-merge (a unit test refuses a workflow
  that merges or approves a Dependabot PR).

## Changed

- Pinned here: none: every one of the 132 `uses:` was already pinned (this repo is the style reference).
- `workflow-lint.yml`: a header line for WL6, and `.github/dependabot.yml` in its trigger paths (the Dependabot shape is
  checked by the workflow-lint unit tests).
- The Infra copy of the tests is `tools/terraform/tests/test_workflow_lint.py` (pytest): one bad and one good shape of WL6,
  the setup-node major from the pin comment, and the Dependabot shape.
- Job and step names unchanged; only `uses:` lines, the lint, its tests and Dependabot changed.

## Tradeoffs

- Pinning to today's commit of a major tag (instead of picking the latest patch) keeps behaviour identical to the last
  green runs; upgrades come through the weekly Dependabot PR.
- WL6 checks both the parsed YAML (every `uses:` value, quoted or not) and the raw lines (the tag comment, which YAML
  drops). A shell comment line that mentions `uses:` is ignored.

## Should know

- Third-party actions in use (for the org allow-list of decision 2.3): aws-actions/configure-aws-credentials,
  aws-actions/amazon-ecr-login, aquasecurity/trivy-action, googleapis/release-please-action; everything else is
  GitHub-owned (actions/*) or local.
- Rebased onto the CI-hygiene lane (l14), which added WL4/WL5 and the release-bin / lychee composite actions; this lane's
  rule is therefore WL6.
