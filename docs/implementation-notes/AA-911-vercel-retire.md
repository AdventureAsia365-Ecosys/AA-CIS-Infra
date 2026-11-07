# AA-911 — Vercel retirement of the staff frontends, Infra side (lane l4-aa911-vercel-retire, S272)

Source: root runbook `docs/ops/runbooks/staff-web-ecs-cutover.md` section 4 steps 2-4 (approved by the tech lead on
07/11/2026), root ADR 0019 d23, root ADR 0006a A11 / A13. Two PRs, in this order:

1. **Apex PR** (`chore/aa911-apex-on-alb`): `staff_web_apex_on_alb = true` in `accounts/aa365/terraform.tfvars` (+ a
   tfvars guard test). Plan: exactly one in-place update, `aws_route53_record.apex` (records -> alias to the ALB).
2. **Retirement PR** (`chore/aa911-retire-preview-hosts`, stacked on 1; rebase on main after 1 merges): this note.

## Decisions

- **No Vercel target is left for a staff name.** Once the `aa-cis-frontend` / `aa-booking-admin` projects are deleted,
  any record that can still point at their Vercel targets is a takeover risk (dns.tf). So the cut-over switch
  `staff_web_dns_on_ecs`, the apex switch `staff_web_apex_on_alb` and `dns_apex_a_records` (Vercel's anycast IP) are
  removed, not just set: the runbook's "Vercel rollback targets" go with them.
- **The two staff records move to `staff_web_edge.tf`** (`aws_route53_record.staff_web["cis" | "booking"]`) with
  `moved` blocks from `parity["aa-cis|CNAME"]` and `vercel_frontend["booking"]`. Same Route 53 records, never
  destroyed: the names never stop resolving. `vercel_frontend` keeps only `tripplanner.` (still on Vercel until the
  TripPlanner move of ADR 0019 d23).
- **`staff_web_dns_switch_window` stays as a variable, set to false.** TTLs go back to 1800 s (aa-cis.) and 300 s
  (booking.), as before the window. The variable is kept for a later move of these hosts (e.g. a CDN in front).
- **Preview-only clients deleted**: `cis-admin-preview`, `booking-staff-preview` (and their managed login styles, which
  follow the client map). The app PRs (AA-CIS-App, AA-Booking) of this lane already stop accepting them by default.
- **`booking-staff` loses `aa-booking-admin.vercel.app`** (callback and sign-out URL).

## Changed

- `accounts/aa365/staff_web_edge.tf` (header, variables, `staff_web_dns_ttl`, the records + moved blocks),
  `dns.tf` (parity entry removed, apex alias only), `custom_domains.tf` (`vercel_frontend` plain; output
  `custom_domain_urls.frontends` lists the staff hosts), `custom_domains_variables.tf` (booking, booking-preview,
  aa-cis-preview removed), `ses_variables.tf` (`dns_apex_a_records` removed), `identity.tf`, `identity_variables.tf`,
  `alb_rules.tf` (comments), `booking_variables.tf` + module copy (description), `terraform.tfvars`,
  `modules/environment/staff_web.tf` (comment), `crm_variables.tf` + module `crm_app.tf` (description of
  `crm_booking_admin_url`: ECS, no plan change), `CONTEXT.md`.
- `tools/docs/gen_env_config.py` (required runtimes), `tools/docs/env_config_vercel.json`, `tools/docs/tests/test_gen_env_config.py`.
- `tools/terraform/tests/test_aa911_staff_web.py`: the switch tests become "no switch, no Vercel target, records moved,
  window closed, apex alias only, Preview clients and Vercel callbacks gone".

## Expected Terraform plan (retirement PR, after the apex PR is applied)

- `aws_route53_record.parity["aa-cis|CNAME"]` has moved to `aws_route53_record.staff_web["cis"]`: update in place,
  `ttl` 60 -> 1800 (records unchanged: the ALB DNS name).
- `aws_route53_record.vercel_frontend["booking"]` has moved to `aws_route53_record.staff_web["booking"]`: update in
  place, `ttl` 60 -> 300 (records unchanged).
- destroy `aws_route53_record.vercel_frontend["aa-cis-preview"]` and `["booking-preview"]`.
- destroy `aws_cognito_managed_login_branding.workforce["cis-admin-preview"]` and `["booking-staff-preview"]`.
- destroy `aws_cognito_user_pool_client.workforce["cis-admin-preview"]` and `["booking-staff-preview"]`.
- update in place `aws_cognito_user_pool_client.workforce["booking-staff"]`: `callback_urls` / `logout_urls` lose the
  two `aa-booking-admin.vercel.app` entries.
- Output changes only: `identity_workforce_client_ids`, `identity_workforce_branding_ids`, `custom_domain_urls`.
- Nothing else: in particular no change to `aws_route53_record.apex` (already an alias after the apex PR), to any other
  client, to the pools or to the WAF. 6 destroy, 3 update. If the apex PR is not applied yet, the apex update shows
  here too: stop and apply the apex PR first.

## Tradeoffs

- Removing the switches makes a DNS rollback to Vercel a code change, which is the point: Vercel is gone.
- The rest of the cut-over code (wildcard certificate, WAF rule, host rules) stays: it serves the ECS staff web.

## Should know

- `terraform validate` passes offline; the plan above is read from the code (no AWS from the lane).
- Env config register (`tools/docs/gen_env_config.py`, Docs Gen): `REQUIRED_VERCEL` is now `aa-tripplanner` only and
  `REQUIRED_ECS` adds `aa-cis-dev-admin` / `aa-booking-dev-admin`; the names-only snapshot
  `tools/docs/env_config_vercel.json` drops the two retired projects. Without this, a live Docs Gen run (VERCEL_TOKEN
  set) after the project deletion would fail closed ("required runtime missing: Vercel project ..."). The tests use an
  invented CLI-shaped project (`aa-booking-sample`) instead of the retired name.
- **Gap stated, not replaced: CIS signed-in pages before merge.** The fixed Preview host `aa-cis-preview.` (deleted
  here with `cis-admin-preview`) was the only way to see unmerged CIS code signed in (viewer-capped E2E user, label
  `preview-signin` / `alias_only_url`). After this PR, CIS staff pages are verified signed in only after merge
  (`smoke-production` / `visual-production` on `aa-cis.lumiguides.it.com`, called by `Deploy Admin Dev`, plus the
  A10b `admin-evidence` run on the same production host). Before merge CIS has only `Visual (next start)` on the
  public pages and the kit gallery. Booking keeps its mocked-API staff pages in Visual. A mocked-API staff run for
  CIS Visual is a follow-up (root note `docs/implementation-notes/AA-911-vercel-retire.md`, skill `aa-ui-verify`).
- The apex redirect answers `location: https://aa-cis.lumiguides.it.com:443/` (the rule's explicit port 443 is kept by
  the ALB); live checks accept the URL with or without `:443`.
- `docs/generated/*` (inventory, network) still show the Preview hosts and clients until the docs bot regenerates them.
