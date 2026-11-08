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

## Changed

- `accounts/aa365/tripplanner_web_edge.tf`: two variables removed, window default false, record + output `dns_target`
  always the distribution, comments.
- `accounts/aa365/terraform.tfvars`: `tripplanner_web_dns_on_cloudfront = true` -> `tripplanner_web_dns_switch_window = false`.
- `accounts/aa365/main.tf`: the purge URL expression.
- Comments only: `custom_domains.tf`, `custom_domains_variables.tf`, `modules/ecs/main.tf`, `modules/ecs/variables.tf`;
  `CONTEXT.md`.
- Tests: `test_aa1038_tripplanner_web.py` (record always to the distribution, no switch / Vercel target / tfvars line,
  window closed, purge URL), `test_aa1004_environment_moves.py` (root-only edge settings list),
  `test_aa911_staff_web.py` (no Vercel CNAME left; the label parser gets its own self-test on invented targets).

## Tradeoffs

- No DNS rollback to Vercel any more: rollback of the TripPlanner web is now an ECS redeploy of the previous image
  (the Vercel project is gone). Accepted by the runbook (section 4 runs a working day after a clean switch watch).
- Kept the window variable rather than deleting it: same shape as `staff_web_dns_switch_window`, and a later move
  (prod, another CDN) needs the same 60 s option.

## Should know

- Expected Terraform plan: **1 to change**, `aws_route53_record.tripplanner_web[0]` in place, `ttl` 60 -> 300 (records
  unchanged: the distribution name). Nothing else: no task definition of the CIS api / worker (same env value), no
  destroy. Anything more in the plan: stop.
- Merge after the Vercel domain is removed from the project? Not needed for safety: the record already points at
  CloudFront; the order in the lane is Infra, CIS, TripPlanner, root.
