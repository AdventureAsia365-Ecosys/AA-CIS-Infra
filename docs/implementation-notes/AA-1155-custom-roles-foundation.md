# AA-1155 — custom staff roles, Infra foundation (S286, lane l4-custom-roles-foundation)

Spec: root `.kiro/specs/AA-1155-custom-staff-roles/` (task T2 of `tasks.md`). Decision record: root ADR 0006a A14
(transport view, Q2 option A), A10f, A10g.

## Decisions
- Two WORKFORCE groups, `cis-custom` (precedence 32, inside the CIS band 10-39) and `booking-custom` (77, after
  `booking-finance` 75, before the CRM groups 80+). A group only says "this person holds a custom role"; WHICH role is
  CIS directory data (`shared.admin_users.custom_role`, `shared.staff_app_grant.role`). Alone it grants nothing: the
  apps fail closed when they cannot read the directory.
- A10f `e2e-cis-content-lead@`: exactly `cis-content_lead`, Dev only, in the CIS directory (CIS 462 widens
  `admin_users_email_chk`). The second person of two-person content publishing.
- A10g `e2e-custom-maker@`: exactly `cis-custom` + `booking-custom`, Dev only. It mirrors the real target person (a CIS
  custom "Content" role plus the Booking "Product, ops & accounting" role). One exact set, no extra set: any other set
  denies the token, like every A10 entry.
- The maker is created by `tools/identity/crm_dev_identity.py e2e-custom-maker` (SUPPRESS, no password) so the token
  proof (`cognito:groups` carries `booking-custom`) runs right after Terraform Apply, before any app code; the CIS code
  lane links its directory row afterwards.
- Both new addresses join the admin mail rule (`e2e-cognito-admin`, prefix `inbound-admin/`, MFA admin reads only),
  never `e2e-cognito`: both sessions write.
- `db/owners.yaml` consumer grants + isolation probe: booking `USAGE, SELECT` on `shared.v_staff_booking_grant`
  (expected from CIS 462), cis_app `USAGE, SELECT` on `booking.v_staff_role_capability` (expected from bk-062). New
  CROSS_APP rows keep the base tables closed: booking on `shared.admin_users`, `shared.staff_app_grant` (always),
  `shared.staff_role` (from 462); cis_app on `booking.staff_role` (from bk-062).

## Changed
- Nothing beyond the issue's Infra scope. The tool subcommand is new (the issue said "follow how existing E2E
  identities are defined"; A10e used the same tool).

## Tradeoffs
- `USAGE` on schema `shared` is new for the `booking` role. tripplanner and aa_app_user already hold it; no `shared`
  function is SECURITY DEFINER (schema reference, Functions), so USAGE alone reaches nothing but the granted view.
- One exact group set for the maker means it cannot sign in with CIS until the CIS code maps `cis-custom`; CIS then
  answers 403 (no known CIS group), which is the intended fail-closed state.

## Should know
- Cost: 0 USD a month (two Cognito groups, two Lambda env entries, two SES recipients on an existing rule).
- Apply order: this PR (Terraform Apply Dev, MFA) before anyone is put in a custom group: the pre token trigger strips
  every group not in `STAFF_GROUPS`.
- Removal: with the A10 family at the end of project code (trigger entries, mailbox recipients, tool command).
