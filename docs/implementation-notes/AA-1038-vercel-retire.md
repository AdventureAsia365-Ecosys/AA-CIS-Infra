# AA-1038 — R5 hosting, final step: the tripplanner. record without the Vercel switch

Root runbook `docs/ops/runbooks/tripplanner-web-ecs-cutover.md` section 4 step 4. Since the S272 cut-over
(`tripplanner_web_dns_on_cloudfront = true`, PR "point tripplanner. at the CloudFront distribution") the host is served
by the ECS service behind CloudFront. The Vercel project `aa-tripplanner` is deleted by the orchestrator at this step.

## Decisions

- **The record always names the distribution:** `records = [one(aws_cloudfront_distribution.tripplanner_web[*].domain_name)]`
  with a precondition `local.tp_web_edge_on == 1` (clear error instead of an index error if the edge is ever switched
  off). The variables `tripplanner_web_dns_on_cloudfront` and `tripplanner_web_vercel_target` are removed: a CNAME to
  Vercel with no project claiming the host is a takeover risk, so no Vercel target may stay in code.
- **Window closed like the staff web (AA-911):** `tripplanner_web_dns_switch_window` stays as a variable (the 60 s
  option for a later move of this host), its default becomes `false` and the tfvars line says `false` (it replaces
  the old switch line). TTL 60 -> 300.
- **CIS purge target without the switch:** `tripplanner_revalidate_url = "https://${local.tp_web_host}/api/revalidate/catalog"`.
  The same value the switch gave since the cut-over, so the CIS api / worker task definitions do not change. Kept
  explicit (not null = app default) so the target follows `var.dns_zone_name`; the CIS default changes to the same
  URL in the AA-CIS-App PR of this step.

- **Cognito client URLs (review fix):** the EXTERNAL pool's `tripplanner` app client drops
  `https://aa-tripplanner.vercel.app/auth/callback` and `https://aa-tripplanner.vercel.app/`. The client is public
  (PKCE, no secret), so once the project is deleted anyone could claim the `aa-tripplanner.vercel.app` name, send a
  traveller an authorize link with that `redirect_uri` and redeem the code with their own verifier. Same reason AA-911
  dropped the `aa-booking-admin.vercel.app` URLs and the CIS PR of this step drops the host from the subject gate.

## Changed

- `accounts/aa365/tripplanner_web_edge.tf`: two variables removed, window default false, record + output `dns_target`
  always the distribution, comments.
- `accounts/aa365/terraform.tfvars`: `tripplanner_web_dns_on_cloudfront = true` -> `tripplanner_web_dns_switch_window = false`.
- `accounts/aa365/main.tf`: the purge URL expression.
- `accounts/aa365/identity_variables.tf`: the `tripplanner` client keeps `tripplanner.lumiguides.it.com` and
  `localhost:3003` only (callback + sign-out); comment and variable description updated.
- `accounts/aa365/identity.tf`: comments only (the BFF key and sign-up proof key are read by the ECS task, not a
  Vercel env). The two secrets' `description` strings still say "Vercel env": left as is so the plan stays small;
  change them with the next identity edit.
- Comments only: `custom_domains.tf`, `custom_domains_variables.tf`, `modules/ecs/main.tf`, `modules/ecs/variables.tf`;
  `CONTEXT.md`.
- Tests: `test_aa1038_tripplanner_web.py` (record always to the distribution, no switch / Vercel target / tfvars line,
  window closed, purge URL), `test_aa1004_environment_moves.py` (root-only edge settings list),
  `test_aa911_staff_web.py` (no Vercel CNAME left; the label parser gets its own self-test on invented targets);
  `test_aa1038_tripplanner_web.py::test_no_cognito_client_url_on_a_vercel_host` (no `vercel.app` URL in any app
  client, the tripplanner client's exact list).

## Tradeoffs

- No DNS rollback to Vercel any more: rollback of the TripPlanner web is now an ECS redeploy of the previous image
  (the Vercel project is gone). Accepted by the runbook (section 4 runs a working day after a clean switch watch).
- Kept the window variable rather than deleting it: same shape as `staff_web_dns_switch_window`, and a later move
  (prod, another CDN) needs the same 60 s option.

## Should know

- Expected Terraform plan: **2 to change**, both in place, 0 to add, 0 to destroy:
  `aws_route53_record.tripplanner_web[0]` `ttl` 60 -> 300 (records unchanged: the distribution name), and the
  EXTERNAL pool's app client `tripplanner` (`callback_urls` / `logout_urls` lose the two `aa-tripplanner.vercel.app`
  entries). Nothing else: no task definition of the CIS api / worker (same env value), no destroy. Anything more in
  the plan: stop.
- Apply this PR **before (or together with) deleting the Vercel project**: until it is applied the Cognito client
  still accepts the `vercel.app` callback, and that name must not be claimable while it does.
- Merge after the Vercel domain is removed from the project? Not needed for safety: the record already points at
  CloudFront; the order in the lane is Infra, CIS, TripPlanner, root.
