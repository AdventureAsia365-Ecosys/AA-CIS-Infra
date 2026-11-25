# AA-1111 / AA-1166 — partner pool password policy (S294, lane l22, DRAFT until the sign-in change window)

## Decisions

- **Length only** on the partner pool (`identity_partner.tf`): minimum 14 characters kept, the four character-class
  rules off. Current guidance prefers a long passphrase to forced classes; Cognito's managed login shows the remaining
  rule on its own.
- **Temporary password: one day** (was 7). The CRM claim page shows it once and the person signs in with it at once
  (first sign-in sets their own password and the authenticator). An unused one is replaced by claiming a new
  invitation (the CRM's `AdminCreateUser` RESEND path), so nothing else changes.
- The WORKFORCE and EXTERNAL pools are not touched in this PR.

## Changed

- `accounts/aa365/identity_partner.tf`: `password_policy` and the file header.

## Tradeoffs

- Existing passwords keep working (Cognito checks the policy only when a password is set).
- These values live in Terraform: Cognito reads them from the pool, so they cannot be admin-editable settings of an
  app; a change is a reviewed Terraform PR.

## Should know

- Expected plan: one in-place update of `aws_cognito_user_pool.partner` (password policy only), nothing replaced.
- The CRM's temporary password generator (24 characters, every class) still satisfies the policy.
