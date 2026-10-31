# Public-repo trim of security notes (S261, lane l10-infra-redact)

Session S261 (31/10/2026), Claude Code. Branch `docs/aa-873-trim-public-security-notes`. Refs AA-873.
This repo is public. A read-only sweep (private root audit, S261) listed notes and code comments that described
open or recently closed privilege paths in operational detail. This change trims them to one-line pointers.

## Decisions

- **Comments and Markdown only.** No resource, policy statement, variable or output changes: every changed line in
  `.tf` / `.yml` is a comment (checked on the diff). Terraform Plan should show no changes.
- **Pointer wording:** operational detail is replaced by "tracked in Linear AA-873" (with TL-7 for the apply
  path); the decision record of each note stays readable (what was decided, which statement or file holds it).
- **Main-only gate:** docs now say main-only for the apply role is enforced by the IAM OIDC `ref` condition, and
  GitHub environment rules are tracked in Linear AA-873 (TL-7). The old `docs/ci-role-split.md` sentence claiming a
  protected environment was wrong and is corrected.
- **AA-841:** no longer states a rotation status (a public "pending" tells a reader the old value is live) and no
  longer ties the removed legacy scaffold to credentials; it points to Linear AA-873. CONTEXT.md drops the sentence
  that the scaffold's variables file held plaintext credentials. The `.gitleaksignore` history pins still name the
  file and commits: the full-history scan needs them, so they stay. Text cannot hide what history holds; the real
  fix is rotating the credential (private audit S261, section 6, step 1), which is outside this branch.
- **AA-866:** the accepted-risk record no longer assumes a single pusher; the aa-agent GitHub App pushes too.

## Changed

- Code comments: `accounts/aa365/identity_iam.tf`, `accounts/aa365/cicd_split.tf` (apply role trust),
  `accounts/aa365/ops_secret_guard.tf` (header), `modules/ecs/main.tf` (CIS Deny-list comment),
  `.github/workflows/terraform-apply.yml` (job guard comment).
- Notes: `docs/ci-role-split.md` (residual-risk sections), implementation notes AA-807, AA-816, AA-841, AA-866 and
  AA-873-s261-secret-read (also fixes its false "this repo is private" sentence); CONTEXT.md (legacy scaffold
  paragraph).

## Tradeoffs

- Git history, old commit messages and old PR bodies still hold the earlier text; trimming HEAD only stops new
  readers being guided. Rewriting history was not considered (not proportionate, and it breaks every clone).
- Lower-risk historical notes from the sweep are left as they are.

## Should know

- Several older notes still say "this repo is private" (historical wording from before the ADR 0014 amendment);
  they do not describe privilege paths and are not changed here.
- `terraform fmt -check -recursive modules` reports `modules/monitoring/main.tf` on main already; untouched here.
- The credential behind the `.gitleaksignore` history pins was already rotated in S251 (25/10/2026); the root
  secrets register records it (corrected in S261).
