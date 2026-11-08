# AA-1024 lane l14 (S273): CI cache hygiene and cached, pinned release binaries

## Problem

GitHub Actions keeps at most 10 GB of caches per repo and evicts least-recently-used entries above it. On 08/11/2026
AA-CIS-App was at 10.7 GB (setup-uv 4.0 GB in 20 entries, CodeQL overlay 2.7 GB, trivy DB 1.9 GB, npm 1.8 GB; 7.5 GB
on pull request / merge-queue refs) and AA-Booking at 9.2 GB; the orchestrator freed ~13.8 GB by hand. A cache saved on
`refs/pull/<n>/merge` is readable only by that pull request, one saved on a `gh-readonly-queue/...` ref only by that
queue group, so those copies are dead weight once the PR closes or the group ends. The same day GitHub throttled
unauthenticated release downloads: lychee and the spaCy wheel had moved to cached, sha256-pinned copies, but syft
(anchore/sbom-action's installer: "The Syft installer failed to install v1.54.0", HTTP 504), trivy (setup-trivy),
actionlint and oasdiff (`curl`) still downloaded on every run.

## Decisions

- **One release-binary path for every tool:** `.github/actions/release-bin` + `.github/scripts/release_bin.py`
  (stdlib) + `pins.txt` (`<tool> <version> <arch> <sha256> <url> <member>`). Same shape as the lychee action: actions/cache
  keyed on tool + version + arch + sha256, a verified copy kept on a hit, else an authenticated `gh release download`
  (then plain HTTPS) with retries and backoff, sha256 checked on every run, only the pinned member extracted. Pins were
  checked against the downloaded files AND the releases' own checksums files (syft, trivy, actionlint, oasdiff); the
  Session Manager plugin has no checksums file, its pin is the sha256 of the versioned 1.2.896.0 .deb (= plugin/latest
  that day). One identical pins.txt in all six repos (unused lines are harmless; a pin moves in one wave).
- **release-bin saves on a miss on any ref** (like lychee / url-wheels): a few tens of MB keyed on the pin, the
  throttling safety net; the default branch normally has the entry (Workflow Lint on push, Cache warm) and the Cache
  cleanup workflow deletes a PR's copy when it closes.
- **Caches save only on the default branch (WL4):** setup-python / setup-node `cache:` inputs replaced by an explicit
  `actions/cache/restore` (key `pip-<os>-<arch>-py3.12-<hash of the requirement files>` / `npm-<os>-<arch>-<hash of the
  lock>`, restore-keys on the prefix) and, in workflows that run on the default branch, an `actions/cache/save` under
  `if: github.ref == 'refs/heads/<default>'`. setup-node v5+ gets `package-manager-cache: false` (its automatic cache
  saves on every ref). setup-uv gets `save-cache: ${{ github.ref == 'refs/heads/main' }}`. trivy-action runs with
  `cache: "false"` + `skip-setup-trivy: "true"`; the trivy DB is restored by our own step (`trivy-db-<UTC day>`, restore
  prefix `trivy-db-`), a stale or missing DB is downloaded by trivy itself as before.
- **Cache cleanup workflow** (identical in all six repos): `pull_request: closed` deletes that PR's caches
  (`refs/pull/<n>/merge` and `/head`), a daily schedule deletes merge-queue caches idle for more than 2 h. Logic in
  `.github/scripts/cache_cleanup.py` (gh CLI, dry run unless `--apply`), the same selection the orchestrator's one-off
  script used. Permissions `actions: write` + `contents: read` (the checkout of the script; the default branch, never
  the closed PR's code). `pull_request`, not `pull_request_target`: a fork PR gets a read-only token and its caches wait
  for the 7-day eviction (the root `ci_hygiene.py --clean` covers them).
- **Static guards in `workflow_lint.py`** (identical in six repos): WL4 (the rules above, plus "no `${{` nested inside
  an expression" in cache inputs: a nested expression is a literal string, the key never matches; actionlint does not
  catch it) and WL5 (no action that downloads its own binary: sbom-action, scan-action, setup-trivy, trivy-action
  without skip-setup-trivy, lychee-action, gitleaks-action; a `run:` that fetches a release asset / archive / install
  script needs an earlier cache restore in its job AND a sha256 check). WL5 also scans the composite actions. Playwright
  browser installs and setup-terraform / setup-uv downloads are not flagged (version-locked and verified by their tool;
  Playwright advises against caching browsers).
- **CodeQL overlay caches left alone:** they come from CodeQL default setup (a repository setting, no workflow file, no
  documented input to limit them). Cost on 08/11: AA-CIS-App ~3.6 GB, AA-Booking ~4.0 GB (90 entries),
  AA-TripPlanner-Web ~1.8 GB. `ci_hygiene.py` reports them per repo.

## Changed (AA-CIS-Infra)

- `docs-lint.yml`: pip restore, freshness saves on main. `workflow-lint.yml`: actionlint from release-bin, runs the
  new tests; `tools/terraform/tests/test_workflow_lint.py` follows (release-bin pin, WL4/WL5 smoke, composite actions).
- hashicorp/setup-terraform is not flagged (HashiCorp releases site, checksums verified by the action, no GitHub
  throttling); no Cache warm needed.

## Tradeoffs

- Explicit restore/save steps are more YAML than `cache: pip`, but they are the only way to keep pull request and
  queue runs restore-only (setup-python / setup-node have no save switch).
- A pull request that changes a lock file misses the exact key until main has it (falls back to the prefix entry);
  before, it saved its own copy that nobody else could read.
- The trivy DB entry is one per UTC day on main (~100 MB); the old trivy-action cache saved one per day per ref.

## Should know

- The shared files (`workflow_lint.py`, `release_bin.py`, `cache_cleanup.py`, their tests, `release-bin/`,
  `cache-cleanup.yml`) are byte-identical in the six repos: change them in all of them in one wave.
- `ci_hygiene.py` (root, session start) exits 1 when a repo is over 8 GB or a WL5 finding exists on a default branch.
