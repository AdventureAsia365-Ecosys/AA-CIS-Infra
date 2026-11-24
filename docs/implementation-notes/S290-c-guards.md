# S290 lane c-guards: red scheduled guards (no Linear issue; CI hygiene follow-up)

## Decisions

- **Root cause of the red Secret Scan (full history)** in the root (run 45326217737, 33 findings) and AA-CIS-Infra
  (run 45325621288, 6 findings): the S287 history rewrite (21/11/2026) gave the branch commits new SHAs, and the
  follow-up PRs (root #922, AA-CIS-Infra #953) *replaced* every pinned fingerprint with its rewritten twin. GitHub
  keeps every pull request head (`refs/pull/*/head`) for ever, and the old commits stay reachable through ~600-950 of
  them, so the nightly job reads them. The findings are exactly the lines those two PRs removed (set-equal, checked).
- **Classification**: each old-commit line was compared (sha256 of the line) with the line of the rewritten commit
  that is pinned today: all identical, so the same values already reviewed (AA-981 S248, S261, S283). Root: audit
  evidence (Jev question keys, S3 object keys, a public Cognito client id, a design-note table cell), the fake AWS key
  of a redaction test, the invented 22-character key of the rehearsal test, CRM agency slugs. AA-CIS-Infra: the April
  `envs/dev/terraform.tfvars` lines of the AA-981 full-history baseline; their handling and status stay in the
  private record (AA-981), as the header of `.gitleaksignore` says, and were re-checked in S290 (rotation metadata
  read live, no value read). No real live credential.
- **Fix**: add the old pins back next to the new ones (one block per repo, with the reason). Not a global
  `file:rule:line` entry: it would hide a future real secret at the same place.
- **Guard**: `tools/repo/gitleaksignore_guard.py` (stdlib, byte-identical in root and AA-CIS-Infra): a change that
  drops a commit-pinned fingerprint fails unless the head copy retires it with `# retired <fingerprint> <reason>`.
  Replayed on #922 it reports the 33 drops. Runs in the root `lean-guard.yml` job and the Infra `change-guard.yml`
  job `lean` (no path filter, PR's own copy) and at push time.
- Chose "append-only baseline" over teaching the history job to skip commits that no branch reaches: those commits
  are public (anyone can fetch a PR head), so they must stay scanned.

## Changed

- Root: `.gitleaksignore` (+33 pins, header note), `tools/repo/gitleaksignore_guard.py` + test, `lean-guard.yml`
  step, `scripts/pre-push.sh` check `baseline-guard` (when `.gitleaksignore` or `tools/repo/` changes),
  `tools/repo/README.md`.
- AA-CIS-Infra: `.gitleaksignore` (+6 pins, header note), the guard + test, `change-guard.yml` job `lean` step,
  `scripts/pre-push.sh` (second step of the `lean-guard` check).

## Tradeoffs

- The baseline only grows. A pin can go only once GitHub Support purged the PR refs that reach its commit; the
  retire line keeps that decision visible in the file.
- The four app repos are not touched: no rewritten history there yet. Vendor the guard before rewriting one.

## Should know

- The PR changes `.gitleaksignore`, so the `gitleaks` check needs the label `secret-scan-baseline-reviewed`, added
  after the last push (lessons: label only counts on its own `labeled` run).
- After merge, dispatch Secret Scan (full history) once: it must be green.
