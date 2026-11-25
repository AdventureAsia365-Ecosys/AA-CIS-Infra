# AA-1164 (S294 lane imgscan): WordPress test sidecar, libzstd1 exception until 02/12

## Decisions
- The nightly Image Scan (running images, run of 25/11) failed on CVE-2026-124851 (libzstd1, HIGH, P1, fixed in
  Debian 1.5.7+dfsg-1+deb13u1) in the WordPress test sidecar pinned by `test_wp_image`.
- No fixed image exists upstream yet: on 25/11 the tags `7.1.5-php8.4-apache`, `7.1-php8.4-apache`,
  `7-php8.4-apache` and `php8.4-apache` on public.ecr.aws all still resolve to the pinned index digest, Docker Hub lists
  the same digest, and the other PHP variants of 7.1.5 (php8.3, php8.5) were built on 24/11 05:27-05:29 UTC too (arm64
  image config `created`), before the Debian fix. So the pin stays and the finding is accepted for 7 days: a row in the
  root register `docs/security/vuln-exceptions.toml` (repo AA-CIS-Infra, source trivy, expires 2026-12-02) and the
  same entry in a new `.trivyignore` at this repo's root (the file the monthly triage cross-checks).

- Review fix: the nightly workflow runs `image_scan.py scan` from this repo's root and Trivy reads `.trivyignore`
  from its working directory when no `--ignorefile` is given, so the new file would have dropped CVE-2026-124851 from
  EVERY scanned image (Booking, CIS, CRM, TripPlanner), not only the WordPress digest, before the repo-scoped register
  check. `sbom_args()` and `trivy_args()` now pass `--ignorefile /dev/null` (`os.devnull`): the gate stays
  register-only and `.trivyignore` is only the mirror the monthly triage cross-checks.

## Changed
- `.trivyignore` (new): one entry, `CVE-2026-124851 exp:2026-12-02`, with its reason.
- `tools/security/image_scan.py`: every Trivy call (SBOM pull and vulnerability scan) gets `--ignorefile /dev/null`;
  test `test_every_trivy_call_ignores_a_cwd_trivyignore` runs the scan from a directory holding a `.trivyignore`.
- `modules/environment/test_wp.tf`: comment only (why the pin did not move, when to move it). No plan change.

## Tradeoffs
- `os.devnull` rather than a missing path or a changed working directory: Trivy 0.70.0 exits with "ignore file not
  found" on a missing `--ignorefile`, and the workflow passes relative output paths, so a different cwd would break them.
  Checked with the pinned Trivy 0.70.0: a cwd `.trivyignore` hides a finding without the flag and no longer does with
  `--ignorefile /dev/null` (exit 0).
- Building our own WordPress image with `apt-get upgrade` was not done: a new ECR repository, a build workflow and a
  digest bump path for a test-only sidecar, against a 7-day wait for the official rebuild.
- Another PHP variant was not taken: same build day, same libzstd1.

## Should know
- Merge order no longer matters for the proof of the Booking fix: with the tool change the Booking image is judged on
  its own (the register row is scoped to AA-CIS-Infra), whether or not this PR has merged when the scan re-runs.
- The nightly gate reads the register from root master, so the root PR must merge before the scan is re-run.
- When the official image is rebuilt (check `7.1.5-php8.4-apache` or a newer 7.1.x tag on public.ecr.aws), bump the
  digest, roll it out with Terraform, redeploy the Booking admin, then remove the register row and the `.trivyignore`
  entry.
