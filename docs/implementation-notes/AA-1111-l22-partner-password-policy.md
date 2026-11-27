# AA-1111 / AA-1166 — partner pool password policy (S294, lane l22, DRAFT until the sign-in change window)

## Decisions

- **Length only** on the partner pool (`identity_partner.tf`): minimum 14 characters kept, the four character-class
  rules off. Current guidance prefers a long passphrase to forced classes; Cognito's managed login shows the remaining
  rule on its own.
- **Temporary password: one day** (was 7). The CRM claim page shows it once and the person signs in with it at once
  (first sign-in sets their own password and the authenticator). A claimed invitation cannot be claimed again, so an
  unused one is replaced by a new invitation (see "Should know"); the new claim RESENDs a fresh temporary password.
- The WORKFORCE and EXTERNAL pools are not touched in this PR.

## Changed

- `accounts/aa365/identity_partner.tf`: `password_policy` and the file header.

## Tradeoffs

- Existing passwords keep working (Cognito checks the policy only when a password is set).
- These values live in Terraform: Cognito reads them from the pool, so they cannot be admin-editable settings of an
  app; a change is a reviewed Terraform PR.
- Composition rules off follows ASVS 5.0 V6.2.5 and NIST SP 800-63B-4; the common/breached password list those
  standards pair with it (ASVS V6.2.4) is a Cognito tier decision (paid Plus tier), accepted for Dev because this pool
  requires TOTP; tracked in AA-1166, to revisit with the tier cost before the first paying tenant.

## Should know

- Expected plan once main is applied (and the WAF_FILTERED convergence fix, Infra
  `fix/aa-1111-apigw-gateway-response-converge`, is merged and applied first): `aws_cognito_user_pool.partner` updated
  in place (`password_policy`: the four `require_*` true -> false, `temporary_password_validity_days` 7 -> 1,
  `minimum_length` unchanged); `aws_iam_role_policy.cis_ecs_task_partner_pool_read` shows known-after-apply (same JSON,
  the data source depends on the pool). Nothing replaced. Any API Gateway deployment / stage / gateway response line
  in the plan is not from this PR: stop and apply that fix first.
- The CRM's temporary password generator (24 characters, every class) still satisfies the policy.
- Apply through the Terraform Apply workflow (apply role); a hand apply pages via
  `aa-identity-<env>-partner-pool-config` (UpdateUserPool by anyone but the apply role).
- An invitee who misses the 24 h window gets Cognito's "temporary password has expired" error: the owner revokes and
  re-invites (first owner: AA withdraws in the L1 console); the new claim RESENDs a fresh temporary password.
- The two AA-Partner comments that describe the old policy (`api/app/members/directory.py` lines 13 and 49) change in a
  small AA-Partner PR in the same window.
