# AA-1024: the lychee binary from a cached, hash-checked copy (lane l12-ci-lychee-cache, S273, AA-CIS-Infra)

The full notes are in the AA-Ecosys root repo, `docs/implementation-notes/AA-1024-l12-ci-lychee-cache.md`. The same
change goes into the root repo, AA-Booking, AA-Partner, AA-TripPlanner-Web and AA-CIS-Infra.

## Decisions

- lycheeverse/lychee-action v2.9.0 downloaded lychee v0.24.2 from github.com on every run, with one `curl` and no
  retry. On 08/11 that download failed several Docs lint runs and took pull requests out of the merge queues. The action
  has no input that skips its download, so the "Internal links (offline)" step now uses the local composite action
  `.github/actions/lychee`. It runs the same lychee command with the same `args`, `fail` and `jobSummary`. The
  report, the step summary and the exit code are the same.
- The binary comes from `actions/cache` (restore and save pinned by SHA, v6.1.0). The key is version + platform + the
  release sha256 from `.github/actions/lychee/pins.txt`. The download runs only on a miss: urllib over HTTP/1.1, 6
  attempts with backoff. Every copy is checked against the pinned sha256 (`.github/scripts/lychee_bin.py`).
- A new job, `lychee-cache` ("Lychee cache (default branch)"), saves the entry on main. It runs on a push to main that
  changes the action or the script, on the weekly schedule and on a manual run. The required job "Docs lint" keeps its
  name. It now skips `push` as well as `schedule`.
- Docs lint is path-filtered here, so its pull-request paths now also list `.github/actions/lychee/**` and `.github/scripts/lychee_bin.py`. This repo has no `test_workflow_lint.py`, so Workflow Lint runs only `test_lychee_bin.py` before `workflow_lint.py`.

## Changed

- New: `.github/actions/lychee/{action.yml,pins.txt}`, `.github/scripts/lychee_bin.py` and
  `.github/scripts/test_lychee_bin.py`, byte-identical in all five repos. Edited: `docs-lint.yml` and
  `workflow-lint.yml` (it runs `test_lychee_bin.py` and lists both script files in its path filters).
- `scripts/pre-push.sh` and `scripts/install-hooks.sh`: the hint for a missing lychee no longer names lychee-action.
  It says how to fetch the same verified binary with `lychee_bin.py fetch`. Only the hint text changed.

## Tradeoffs

- The action's `GITHUB_TOKEN` export is dropped. `tools/docs/lychee.toml` has `offline = true`, so lychee makes
  no HTTP request.

## Should know

- To move the lychee version, change `pins.txt` in all five repos in one wave, with each sha256 taken from the
  release's `.sha256` files.
- Checked locally: the script ran the real lychee v0.24.2 (downloaded and verified by the script) on this repo's
  pages with this workflow's arguments, and it found 0 errors and exited 0, the same as the action.
