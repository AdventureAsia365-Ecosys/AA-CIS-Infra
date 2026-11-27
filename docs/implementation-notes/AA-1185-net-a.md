# AA-1185 — network hygiene A: remove the legacy shared app security group (S296, lane l10-net-hygiene)

Issue scope 7 (S295 audit SA-57). One of three separate Infra PRs (A: this cleanup, B: egress narrowing, C: NAT
domain filter design), so each is applied and watched alone.

## Decisions

- **Inventory first, read-only (27/11/2026, acc2 us-west-1).** `aa-cis-dev-sg-app` is referenced by nothing but two
  network interfaces in status `available` (no attachment), both described `AWS Lambda VPC ENI-aa-cis-dev-ingestion`;
  that Lambda no longer exists (`GetFunctionConfiguration` → ResourceNotFound). Checked and empty: every ECS service's
  awsvpc groups (8 services, all on their own ADR 0004b groups), the four VPC Lambdas (tp-lambda / ops-lambda groups),
  RDS and ElastiCache group lists, both load balancers, EC2 instances, launch templates (none), VPC endpoints (S3
  gateway only, no groups), EFS (none), and every inbound/outbound rule of the 20 groups in the region (no rule names
  the group).
- **The two network interfaces are not Terraform resources** (the Lambda service created them), so they are deleted by
  a hand step (single-line `aws ec2 delete-network-interface`, in the PR body) before the apply, not by code. In S242
  (X1 S14) they were still `in-use` owned by the Lambda service and could not be deleted; AWS has released them since.
- **No fallback stays behind.** The modules used the shared group as the default when a caller list or a CIS service
  group was missing (`rds_ingress_sg_ids = null`, `ingress_sg_ids = null`, `coalesce(var.sg_api_id, var.sg_app_id)`).
  Those inputs are now required, so a caller without its own group fails at plan instead of landing on a wide group.
- `network_security_group_ids` output drops `app_shared`.

## Changed (vs the issue scope)

- The ALB header and deletion-protection items of scope 7 already shipped in the first AA-1185 wave; only the group
  and the interfaces are left, plus the root security baseline row (root PR of this lane).

## Tradeoffs

- Making the module inputs required is a module interface change; only `accounts/aa365` calls these modules (checked
  with `git grep`), and it passes all of them.

## Should know

- **Order:** delete the two interfaces first, then apply. If the apply runs while an interface still names the group,
  `DeleteSecurityGroup` fails with `DependencyViolation` after the provider's delete retries (minutes), and the apply
  ends red with nothing else changed.
- **Expected plan:** 1 to destroy (`module.vpc.aws_security_group.app`), 0 to add, 0 to change, plus the
  `network_security_group_ids` output change. Any other line is unexpected (the RDS / Redis ingress lists and the CIS
  service groups resolve to the same ids as today).
- The SG-change alert ignores the Terraform apply role, so the destroy does not page; the hand `DeleteNetworkInterface`
  is not in that rule's event list.
- Generated root docs (`docs/generated/network.md`, `inventory.md`) still list the group until their next regeneration.
