# AA-1091 — A10e-2 pricing pair (Infra side)

Lane l29 of S279; root ADR 0006a A10e-2. The AA-1091 live check runs with SYNTHETIC prices on Dev with E2E
identities (tech lead, S279, runbook option G1): a maker and a checker that AA-Booking holds to the pricing steps on
synthetic trip plans.

## Decisions

- **Maker = the A10d address with the Pricing team preset.** `workforce.py` keeps `E2E_CIS_CS_TEST_STAFF_GROUPS =
  ("cis-customer_success",)` and adds one more exact set for the address, `E2E_CIS_CS_PRICING_TEST_STAFF_GROUPS =
  ("cis-customer_success", "booking-contracting")`, in a new read-only map `E2E_DEV_ONLY_EXTRA_GROUP_SETS`, consulted
  only while the Dev flag is on. Any other set still denies the token.
- **Why not replace the A10d tuple with the pair** (the lane brief's wording): the preset is granted for the live check
  and removed at cleanup (runbook step 10); with only the pair, the A10d account could no longer sign in after the
  removal, and before the grant. Accepting exactly either set keeps A10d working and adds no privilege beyond the pair.
- **Checker = a new Dev-only address** `e2e-booking-pricing-checker@`, exactly `booking-contracting`, one more entry of
  `E2E_DEV_ONLY_TEST_STAFF`, a recipient of `e2e-cognito-admin` (codes in `inbound-admin/`, MFA admin only), created by
  `crm_dev_identity.py e2e-booking-writers --apply` (fourth row of `E2E_BOOKING_WRITERS`).

## Changed

- `accounts/aa365/lambda_src/identity_triggers/workforce.py`, `accounts/aa365/e2e_mailbox.tf`,
  `tools/identity/crm_dev_identity.py`, `tools/identity/README.md`, `CONTEXT.md`; tests in
  `identity_triggers_tests/test_workforce.py` and `tools/identity/tests/test_crm_dev_identity.py`.

## Tradeoffs

- One more Cognito user and one more recipient versus giving a finance A10e address `booking-contracting`: a separate
  address keeps each identity's group set single-purpose and its Booking allow-list readable.

## Should know

- After merge: Terraform Apply (aa365 root: the trigger Lambdas and the receipt rule), then
  `crm_dev_identity.py e2e-booking-writers` (dry run: one `would_create`), then `--apply`.
- Removal with the A10 family (AA-1054): delete the Cognito user, drop the entries, the extra set and the recipient.
