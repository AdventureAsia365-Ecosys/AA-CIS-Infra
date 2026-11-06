# AA-1004 lane l8: tagging standard in Infra (S271)

Root page: `AA-Ecosys/docs/architecture/tagging-standard.md` (FIN-03). This file covers the Infra side.

## Decisions

- **Eight mandatory keys**: Environment, Project, App, Component, Owner, ManagedBy, CostCenter, DataClassification.
  Values lower-case kebab. Machine copy: `tools/terraform/tag_policy.json` (the root page is the source).
- **App and Component never in `accounts/aa365` default_tags.** Same reasoning as AA-828: a default App bills every
  forgotten resource to one app. The guard now refuses a resource without them, so a forgotten tag fails the PR plan
  instead of becoming untagged spend. The management and acc3 roots are single-purpose and do default them.
- **No new App values.** The seven values Cost Explorer already shows stay (cis, booking, tripplanner, crm, identity,
  shared, ecosystem). Security and CI/CD are Components of `shared`, not Apps: moving CloudTrail etc. to a new App
  would leave the per-App budgets (sum precondition) and change attribution mid-month.
- **Environment values**: dev, staging, prod (root ADR 0018 decision 2: "staging", not "stg") plus `shared` for
  organization-level resources (the management root already used it).
- **DataClassification**: default `internal`; `restricted` on RDS, every Secrets Manager secret, Cognito pools, the CRM
  buckets and KMS keys; `confidential` on content buckets, ElastiCache, CloudTrail and ALB log buckets, Booking ops
  docs, the E2E mailbox; `public` on the photos CDN.
- **Retired keys**: `Account` (Cost Explorer has the linked-account dimension), `Service` (replaced by Component).
  Both, plus Env/env and other duplicate spellings, are refused by the guard (`forbidden_keys`).
- **ManagedBy must be `terraform` in a plan**; `ci` (DB Migrate snapshots), `manual` and `aws` exist for resources
  made outside Terraform (the report accepts them).
- **Exempt type**: only `aws_s3_object` (object tags are not cost allocation tags; the TripPlanner placeholder zips
  carry none on purpose, AA-846 `override_provider`).
- **Spend part of the report reads the stored CIS bundle**, not Cost Explorer: root FIN-01 forbids a new Cost Explorer
  script (DM-10.4). The Tagging API part is free.

## Changed (vs the lane brief)

- Brief said Environment `dev|stg|prod`: ADR 0018 fixes `staging`; `shared` added for the management account.
- Brief listed `security` as an App: kept as Component (see Decisions).
- Brief said "Cost Explorer by tag" in the report: replaced by the CIS bundle (FIN-01 rule). Per-Component spend needs
  a new grouping in the CIS cost client (follow-up).
- Brief said "the Plan workflow already exports plan JSON": it did not (only the apply did); the dev plan now writes
  `-out=tfplan` and the guard step exports JSON with `terraform-bin show -json`, then deletes it.
- Added: DB Migrate pre-apply snapshots get the mandatory keys (`ManagedBy = ci`), since manual snapshots were a
  visible untagged storage line.

## Tradeoffs

- One big tag-only plan (326 in-place updates in aa365, 7 in acc3) instead of a slow rollout: tags change nothing at
  runtime, and a single local apply is easier to verify than many partial ones.
- Local MFA admin apply instead of the CI apply: the CI role cannot tag bootstrap IAM objects, KMS keys outside its
  tag conditions, or pass the plan guard on `aws_db_instance` (tag update = update). Widening the CI role for a one-off
  re-tag would be a bigger risk than one human apply.
- Component granularity is "the main part a resource serves" (e.g. the ECS log group of api + worker says `api`).

## Should know

- Local read-only plan (`-lock=false -refresh=false`, admin MFA, 06/11/2026): `0 to add, 326 to change, 0 to destroy`,
  zero replacements. Non-tag diffs in that plan, all no-ops at apply: 19 data sources read at apply time
  (`read_because_dependency_pending`: IAM policy documents and the CloudFront prefix list) make 18 policies and the
  NLB security group show "known after apply" with identical values; `aws_instance.nat` shows `force_destroy`
  null -> false (provider 6.x schema default, no API call); `volume_tags` on the NAT root volume gets the full set.
- The apply touches ECS services and task definitions (tags only, no new revision, no restart): run the job idle gate
  anyway (the job-idle scope tool flags them).
- `test_tag_guard.py` also checks every root's `versions.tf` and that no tag map re-adds Project / ManagedBy /
  Service / Account (resource tags beat default_tags).
- Live report (06/11/2026, Tagging API): 434 resources, 0 compliant before the apply (old Project values, no
  Component / Owner / CostCenter). Outside Terraform: 14 E2E / app secrets and 10 manual RDS snapshots without Project
  (tag by hand or in the tools that create them, follow-up).
