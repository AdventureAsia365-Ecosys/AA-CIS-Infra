# AA-1185 — NAT patch run fix: swap before the patch, explicit timeout (S297, lane l10-natpatch)

Follow-up of the NAT patching item (`accounts/aa365/security_account_defaults.tf` section 4).

## What happened

The first run of the association `aa-ecosys-dev-nat-patch` (27/11/2026, started 13:47Z, on-demand) ended `TimedOut`
/ `ExecutionTimedOut`. Read back on 28/11 (`aws ssm list-command-invocations --details`): the `PatchLinux` step ran
from 13:47:25Z to 17:10:07Z (3 h 22 min) and ended with response code 137. 10,800 s is the default of the
document's `StepTimeoutSeconds` parameter, so the agent killed the step at the timeout. The only output was the payload
download and the start of the dnf work. No patch state was recorded. The NAT instance is a `t4g.nano` (512 MB, Amazon
Linux 2023, no swap): dnf metadata plus the patch payload's Python thrashed memory for the whole run. Egress kept
working (CIS ready 200 throughout, S296 snapshot).

## Decisions

- **Two associations, not a composite document.** A new Command document `aa-ecosys-dev-nat-swap` (one
  `aws:runShellScript` step) runs from its own association `aa-ecosys-dev-nat-swap`: at creation (and when its target
  changes, so a new NAT instance gets swap at once) and every Sunday at 20:45 UTC, 15 minutes before the patch. The
  patch association keeps `AWS-RunPatchBaseline` directly. Considered: one composite document (swap step, then
  `aws:runDocument` AWS-RunPatchBaseline). Rejected because the reboot handling and the patch compliance report of
  RunPatchBaseline are documented for a direct run, and a nested reboot is less certain. The swap is persistent
  (fstab), so the order only matters on the first run, and that one is watched (live steps).
- **Swapfile: 1 GB at `/swapfile`, fstab `defaults,nofail`.** `nofail` means a missing file never blocks the NAT boot
  after a patch reboot. Written as `/swapfile.new` with `dd` (not `fallocate`: swap on a fallocated file is refused on
  some xfs and kernel combinations), `chmod 600`, `mkswap`, then renamed. An interrupted run never leaves a half file
  under the real name. A `/swapfile` that does not activate is rebuilt. The step fails, and makes nothing, when fewer
  than 1,024 + 512 MB are free on `/`.
- **Explicit timeouts.** Patch: `StepTimeoutSeconds = 3600` (was the 10,800 s default). Swap step: 600 s.
- **The patch association is updated in place.** Only its `parameters` map changes. The schedule (Sunday 21:00 UTC),
  `RebootIfNeeded`, `apply_only_at_cron_interval = true` and the target stay as they were.
- **IAM:** `aa-cis-infra-tf-apply-sec` gets the statement `NatSwapDocument` (create, update, delete and read
  documents named `aa-ecosys-*` in this account) and the `aa-ecosys-*` document ARN in `NatPatchAssociation`. It
  grants no `ssm:SendCommand`, no `StartAssociationsOnce` and no `ModifyDocumentPermission`. The plan role reads
  through ReadOnlyAccess. Policy size, rendered offline: 4,407 to 4,787 of the 6,144 characters a managed policy allows.

## Changed (vs the lane brief)

- The brief suggested "an SSM association or a small custom SSM Command document ... then runs the patch baseline".
  This change uses both pieces, but as separate associations (see Decisions), not one document that also runs the
  patch.
- The network runbook did not exist. New page: `docs/runbooks/nat-instance-patching.md` (run, read back, swap
  check, failure cases).

## Tradeoffs

- The values (1,024 MB swap, 512 MB minimum free space, 600 s and 3,600 s timeouts) are Terraform locals reviewed in
  the PR. They are not admin-editable settings: the Infra repo has no settings mechanism, and an app's admin settings do
  not reach an SSM document. Follow-up in the PR body.
- Swap on the NAT root volume (gp3) costs nothing extra. Packet forwarding is kernel work and does not page, so swap
  only slows dnf, never NAT traffic.
- A bigger instance (`t4g.micro`, about 3 USD/month) would also fix it, but it replaces the instance (egress outage)
  and needs its own approval. Not done.

## Should know

- **Bootstrap first:** `aws_iam_policy.tf_apply_sec` changes, so the local MFA targeted apply
  (`-target=aws_iam_policy.tf_apply_sec`) must run BEFORE the CI apply. Otherwise `CreateDocument` is AccessDenied.
- Expected CI plan after the bootstrap: `aws_ssm_document.nat_swap` and `aws_ssm_association.nat_swap` to add,
  `aws_ssm_association.nat_patch` updated in place (`parameters` gains `StepTimeoutSeconds`). Nothing else. In
  particular no `module.vpc.aws_instance.nat` change.
- The swap association runs right after the apply. The patch does not (cron interval only). The live steps run it once
  by hand after the swap run reads Success.
- Guard: `tools/terraform/tests/test_aa1185_nat_swap.py`. It runs the rendered script against stub commands (first
  run, second run, after reboot, broken file, too little disk) and checks the schedules, timeouts and IAM scope.
