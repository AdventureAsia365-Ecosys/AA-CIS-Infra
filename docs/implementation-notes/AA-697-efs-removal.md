# AA-697 drift finding — remove the unused EFS `aa-cis-dev-efs` (S257)

Session S257 (29/10/2026), Claude Code Infra lane. Branch `chore/efs-removal`. Refs AA-697 (the S256 drift
audit, root `docs/audits/2026-10-28-S256-aa697-drift/README.md` row 9, found the file system with no consumer;
there is no separate Linear issue).

## Decisions

- **Remove the whole module, not just the mount targets.** `modules/efs` held exactly one file system, one mount
  target per private subnet, two access points (`/chromadb`, `/langgraph`) and its own security group
  `aa-cis-dev-sg-efs`. All of it served the old ChromaDB + LangGraph SqliteSaver persistence, which the CIS app no
  longer has (no `chromadb` dependency, no LangGraph graph, CIS 122 dropped the LangGraph tables).
- **DRY RUN in the repo (read-only, this branch):**
  - Task definition families in Terraform: `api`, `worker` (`modules/ecs`), `booking`, `crm_api`, `crm_web`,
    `crm_portal`, `db_migrate`. None has a `volume {}` block, `efsVolumeConfiguration`, `mountPoints` or
    `sourceVolume`.
  - No IAM statement grants `elasticfilesystem:Client*` to any task or Lambda role. No `aws_backup_*` resource.
    No output of the root reads `module.efs`. The only reader of `local.efs_ingress_sg_ids` was the module call.
  - App repos (CIS, Booking, Partner, TripPlanner) on `origin/main`: 0 hits for `efsVolumeConfiguration`,
    `fileSystemId`, `accessPointId`, `elasticfilesystem`, `/mnt/efs`, `aa-cis-dev-efs` outside docs. CIS deploys
    copy the latest Terraform task definition, so a live revision cannot carry a volume Terraform never had.
- **Keep `elasticfilesystem:Describe*` / `List*` in `cicd.tf` `RefreshRead` for now.** The plan role needs them to
  refresh the EFS resources while they are still in state; the statement is a bootstrap object (local MFA apply).
  Remove it in a follow-up after the destroy.
- **Keep the `egress` descriptions of `cis_api` / `cis_worker` ("…; RDS, Redis, EFS").** Changing an inline rule
  description is an in-place SG update; leaving the text keeps the plan to EFS destroys only. Follow-up: drop
  "EFS" from both descriptions in a later no-risk PR (or together with the RefreshRead change).

## Changed

- `accounts/aa365/main.tf`: `module "efs"` removed (comment left in its place).
- `accounts/aa365/app_security_groups.tf`: `local.efs_ingress_sg_ids` removed; header comment notes the removal.
- `modules/efs/` deleted (main.tf, outputs.tf, variables.tf).
- `accounts/aa365/observability.tf` comment and `CONTEXT.md` module list: `efs` dropped.
- `tools/docs/gen_docs.py` keeps `aws_efs_mount_target` in its generic child-resource type set (harmless, type list
  only).

## Tradeoffs

- Destroy vs keep: an empty EFS costs close to 0 USD (bursting, billed per GB stored), but it is an orphan with
  mount-target ENIs in both private subnets and an extra SG admitting the two CIS groups on 2049. Removing it
  shrinks the attack surface and the diagrams. The data inside (if any) is checked before apply (see Should know).
- `removed {}` block vs deleting the module call: a plain deletion gives the same plan (Terraform plans destroys
  for resources in state but not in config) and needs no later clean-up.

## Should know

- **Expected plan:** `0 to add, 0 to change, 4 + N to destroy`, all under `module.efs`:
  `aws_security_group.efs`, `aws_efs_file_system.main`, `aws_efs_mount_target.main[0..N-1]` (N = private subnets,
  2 today per the S256 audit), `aws_efs_access_point.chromadb`, `aws_efs_access_point.langgraph`. Anything else in
  the plan is unrelated drift: stop and look.
- **CI apply cannot destroy it.** The apply role `aa-cis-infra-tf-apply` has only `elasticfilesystem:Describe*` /
  `List*` (`cicd.tf` RefreshRead; no AmazonElasticFileSystem managed policy). `DeleteAccessPoint`,
  `DeleteMountTarget` and `DeleteFileSystem` would be AccessDenied mid-apply. Apply this locally with the MFA admin
  profile (`aa365-admin`) from merged `main`, after the read-only checks in the PR body.
- **Backups:** Terraform never set `aws_efs_backup_policy`; check `describe-backup-policy` and AWS Backup recovery
  points before the apply. Recovery points in a vault outlive the file system (and keep costing); keeping or
  deleting them is the orchestrator's decision.
- After apply: Docs Gen regenerates root `docs/generated/inventory.md` / `network.md`; the root diagram source
  `docs/architecture/diagrams/infra.py` still draws "Amazon EFS (no task mounts it)" and needs a root PR.
