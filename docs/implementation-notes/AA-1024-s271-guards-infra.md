# AA-1024 S271: Infra lessons guards (G9, G13, G15)

Lane l23-guards-infra of S271. Design: root `.tmp-session/S271/lessons-guards.json` (guards G9, G13, G15 and the
critique). Lessons: root `skill/aa-lessons/lessons.md` (state lock: Vận hành, two Terraform runs racing the S3 lock;
trust audits must read Federated and Service, not only Principal.AWS; Playwright runner pin; `vars.*` ARNs in a
public repo; a workflow must run once before it is called done).

## Decisions

- **G9, a plan group per root, not shared with the apply.** The design asked for one group `tf-state-<root>` shared by
  plan and apply. GitHub keeps one PENDING job per concurrency group and cancels the older pending one, so a PR plan
  queued behind a running plan would cancel a dispatched apply waiting in the same group. The PR plans therefore use
  `tf-state-aa365-plan` / `tf-state-management-plan` (job level, `cancel-in-progress: false`), the apply keeps its
  workflow group `terraform-apply-prod` (name unchanged, AA-1023 note), and plan versus apply is covered by
  `-lock-timeout=10m` on every CI plan and apply (Dev apply, management review plan, management apply, Deploy Prod).
  `-lock-timeout` was rejected alone in S252 (I1) only because it does not serialise; here it is the second layer.
- **10 minutes.** A Dev PR plan takes 1-2 minutes (AA-879 note), the apply a few minutes; 10 minutes covers a queue of
  a few runs, and a really stale lock still fails, just later.
- **Management plan path filter moved to its own job (`management-paths`).** Otherwise every PR, even one that does
  not touch the root, would queue in `tf-state-management-plan` for its skip run. The plan job now `needs` it and is
  skipped when the root is untouched (it was green-with-skipped-steps before; it is not a required check).
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

- G9: per-root plan groups instead of one group shared with the apply (above).
- G13: no root docs-lint keyword rule for `docs/audits` (the critique called it weak and rewording bypasses it); the
  static check in the required plan job is the guard, the live mode is the audit tool.
- G15: in Infra only (other repos are other lanes); shellcheck and pyflakes inside actionlint are off for now, see
  Should know.

## Tradeoffs

- Three PR plans of one root at once: the middle pending one is cancelled by GitHub (concurrency semantics) and must be
  rerun. Still better than today (two of three fail on the lock); a pending job held no lock, so nothing is left stale.
- The static parser is a heuristic over HCL (brace matching, `jsonencode` maps, `aws_iam_policy_document` principals).
  Anything it cannot read (a `file()` policy, a dynamic principals block, an unknown expression) is flagged as
  `unresolved` rather than passed. The plan mode reads resolved JSON when exactness matters.
- Workflow Lint is not a required check: making it required is a ruleset change (tech lead).

## Should know

- Verified locally: `pytest tools/terraform/tests tools/finops/tests` green; actionlint 1.7.12 (`-shellcheck=
  -pyflakes=`) clean on all workflows; `workflow_lint.py` 0 findings; `iam_trust_inventory.py static` on this repo:
  42 roles, 0 flagged, 3 acknowledged (the two acc3 satellite roles).
- Live mode was run read-only against acc2 on 07/11/2026 (output kept outside the repo): 61 roles, exactly one flag,
  the Identity Center `AWSReservedSSO_AdministratorAccess_*` role, reported as an unmanaged external trust with its
  Access Analyzer finding ARCHIVED.
- Follow-ups: run actionlint's shellcheck integration once and fix or ignore its findings (shellcheck was not
  available locally), then drop `-shellcheck=`; make **Workflow lint** a required check; the bronze bucket name (with
  the account id) is still a literal in four workflows; vendor `workflow_lint.py` into the app repos.
