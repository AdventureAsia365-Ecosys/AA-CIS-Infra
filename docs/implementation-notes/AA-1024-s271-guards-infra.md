# AA-1024 S271: Infra lessons guards (G9, G13, G15)

Lane l23-guards-infra of S271. Design: root `.tmp-session/S271/lessons-guards.json` (guards G9, G13, G15 and the
critique). Lessons: root `skill/aa-lessons/lessons.md` (state lock: Vận hành, two Terraform runs racing the S3 lock;
trust audits must read Federated and Service, not only Principal.AWS; Playwright runner pin; `vars.*` ARNs in a
public repo; a workflow must run once before it is called done).

## Decisions

- **G9, `-lock-timeout` on every CI plan / apply; no concurrency group on the PR plans** (changed in the review
  pass, see Changed). The design asked for one group `tf-state-<root>` shared by plan and apply; the first version
  used a job-level group per root for the PR plans. Both fail on GitHub's semantics: a group keeps one PENDING job and
  cancels the older pending one, so a burst of N PRs (bot migration copies arrive 5-6 at a time) would leave N-2
  required "Terraform Plan (dev)" checks cancelled, to rerun by hand. The lock wait alone lets every plan of the burst
  pass one after the other, so the PR plans have no group. Dispatched applies keep their own group
  (`terraform-apply-prod`, name unchanged, AA-1023 note), where one pending run at a time is intended.
  `-lock-timeout` was rejected alone in S252 (I1) only because it does not serialise; the plans do not need to be
  serialised, they need to not fail on the lock.
- **20 minutes on the PR plans and the Dev apply, 10 minutes elsewhere.** A Dev PR plan takes 1-2 minutes (AA-879
  note), the Dev apply a few minutes; 20 minutes covers an apply plus a burst of five or six plans queued on the lock,
  and a really stale lock still fails, just later. The management and prod roots have rare PR plans and no bursts:
  10 minutes there. The test refuses a PR plan below 20 minutes and a job whose `timeout-minutes` ends before its lock
  wait (the management PR plan job went from 20 to 30 minutes).
- **`-lock=false` stays exempt** (the nightly drift report, read only, AA-879).
- **G13, three modes in one stdlib tool** (`tools/terraform/iam_trust_inventory.py`): `static` (Terraform source, no
  credentials), `plan` (resolved policies from `terraform show -json`), `live` (read-only `sts get-caller-identity`,
  `iam list-roles`, `iam get-role` for the ManagedBy tag, optional `accessanalyzer list-analyzers` +
  `list-findings-v2`). Static is wired into the required **Terraform Plan (dev)** check (before any credential), so a
  new flagged trust fails the PR; live is for audits.
- **Every principal kind is classified**: AWS (this account / ecosystem account named at run time / external),
  Federated (GitHub OIDC must pin `sub`; SAML always flagged, AWSSSO_ called out as Identity Center; other OIDC or web
  identity flagged unless its issuer is allowlisted; a provider in another account flagged), Service (allowlist),
  CanonicalUser, NotPrincipal and `*` (always flagged). Deny statements are skipped.
- **No account id in the repo.** Ecosystem accounts are trusted only through env `IAM_TRUST_ACCOUNTS=alias=id,...` at
  run time; the allowlist refuses any 12-digit number; report output goes through `tools/docs/aws_mask.py`.
- **Acknowledged, not hidden.** A reviewed trust stays in the table as `acknowledged` with its reason. The two acc3
  satellite roles (Bedrock invoker, Cost Explorer reader) trust acc2 roles by literal ARN and are acknowledged. The
  allowlist test refuses an acknowledgement of an `AWSReservedSSO*` role: the reseller's Identity Center role must stay
  red in every live audit until acc2 is in our organization.
- **An acknowledgement is per principal, not per role** (review pass). Each entry carries `principal`, one glob or a
  list (`arn:*:iam::*:role/<name>`: the account is a wildcard because no account id may go in the file). `*` and `?`
  never cross a ':' or '/', an AWS glob must name one role or user (never `:root`, no wildcard in the name), and
  `*`, NotPrincipal and unresolved trusts are never acknowledged (the loader refuses such entries). So `AWS = "*"` or
  a new outside account added to the acc3 Bedrock invoker stays FLAG and fails the required plan check.
- **Live managed status**: `/aws-reserved/sso.amazonaws.com/` = Identity Center (not Terraform), `/aws-service-role/` =
  service-linked (its Service principals are not flagged), a name in `--managed-from` (plan/state JSON) = terraform,
  else the `ManagedBy=terraform` tag, else unmanaged. A flagged trust on a role not managed by Terraform is reported as
  `UNMANAGED external trust`; an ARCHIVED Access Analyzer finding is called out (that is how S271 missed it).
- **G15, actionlint pinned by version and SHA-256** (1.7.12, the latest release, 30/03/2026; checksum from the
  release's checksums file), verified before extraction, in a new `workflow-lint.yml` (paths: `.github/**` workflow
  files and the lint script). Plus `.github/scripts/workflow_lint.py` for the repo rules from the lessons: WL1 no
  sensitive `vars.*` (ARN / role / key / token / password), WL2 Playwright jobs on `ubuntu-24.04`, WL3 `npm ci` only
  with a git-tracked lockfile. Placed in `.github/scripts/` as the design names, so the app repos can vendor the same
  file.

## Changed (vs. the design)

- G9: no PR-plan group at all, only the lock wait (review pass: the first version's per-root group would cancel
  pending required checks in a burst of PRs; it also needed a separate `management-paths` job, now reverted to the
  path filter step of `main`).
- G13: acknowledgements match the principal too (review pass: role + kind alone covered any new principal).
- G13: no root docs-lint keyword rule for `docs/audits` (the critique called it weak and rewording bypasses it); the
  static check in the required plan job is the guard, the live mode is the audit tool.
- G15: in Infra only (other repos are other lanes); shellcheck and pyflakes inside actionlint are off for now, see
  Should know.

## Tradeoffs

- Without a group, a burst of PR plans holds one runner each while they wait on the lock (free runners on this public
  repo; a plan wait costs minutes, not money). A plan that waits longer than 20 minutes (a stuck apply or a stale
  lock) still goes red, which is the signal to look at the lock.
- Principal globs wildcard the account (no account id in the public file): a role of the same name in an outside
  account would also match. A name change or a new principal fails; pinning the account would need the id at run
  time (IAM_TRUST_ACCOUNTS), which the static CI step does not have.
- The static parser is a heuristic over HCL (brace matching, `jsonencode` maps, `aws_iam_policy_document` principals).
  Anything it cannot read (a `file()` policy, a dynamic principals block, an unknown expression) is flagged as
  `unresolved` rather than passed. The plan mode reads resolved JSON when exactness matters.
- Workflow Lint is not a required check: making it required is a ruleset change (tech lead).

## Should know

- Verified locally: `pytest tools/terraform/tests tools/finops/tests` green; actionlint 1.7.12 (`-shellcheck=
  -pyflakes=`) clean on all workflows; `workflow_lint.py` 0 findings; `iam_trust_inventory.py static` on this repo:
  42 roles, 0 flagged, 3 acknowledged (the two acc3 satellite roles). Review pass: the same, plus a fixture with the
  shipped allowlist where `AWS = ["*", "<outside>:root", "<outside>:role/x"]` on the Bedrock invoker stays FLAG.
- Live mode was run read-only against acc2 on 07/11/2026 (output kept outside the repo): 61 roles, exactly one flag,
  the Identity Center `AWSReservedSSO_AdministratorAccess_*` role, reported as an unmanaged external trust with its
  Access Analyzer finding ARCHIVED.
- Follow-ups: run actionlint's shellcheck integration once and fix or ignore its findings (shellcheck was not
  available locally), then drop `-shellcheck=`; make **Workflow lint** a required check; the bronze bucket name (with
  the account id) is still a literal in four workflows; vendor `workflow_lint.py` into the app repos.
