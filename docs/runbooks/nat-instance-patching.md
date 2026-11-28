# NAT instance: weekly patching and its swap (AA-1185)

All private egress of Dev (ECS tasks, Lambdas in the VPC) goes through one NAT instance (`module.vpc.aws_instance.nat`,
`t4g.nano`, 512 MB, Amazon Linux 2023). Two State Manager associations keep it patched without replacing it. Design:
`accounts/aa365/security_account_defaults.tf` sections 4 and 5.

| Association | Document | When | What |
|---|---|---|---|
| `aa-ecosys-dev-nat-swap` | `aa-ecosys-dev-nat-swap` (Command, this repo) | at creation, then Sunday 20:45 UTC | Makes a persistent 1 GB `/swapfile` (fstab `nofail`) if it is absent; a no-op otherwise. Timeout 600 s. |
| `aa-ecosys-dev-nat-patch` | `AWS-RunPatchBaseline` | Sunday 21:00 UTC (Monday 04:00 Vietnam) | Install, reboot only if a patch needs it. Step timeout 3,600 s. |

Why the swap: without it, dnf on 512 MB thrashed for 3 h 22 min on the first run (27/11/2026) and was killed at the
old 10,800 s default timeout, with no patch state recorded.

A reboot stops private egress for about a minute. IP forwarding and the MASQUERADE rule come back at boot. Do not
start, stop, resize or replace the instance as part of patching: a replacement cuts Dev egress.

All commands are single-line (WSL2), profile `aa365-admin`, region `us-west-1`.

## Run once by hand (after an apply, or to check)

1. Find the instance and the association IDs:
   - `aws ec2 describe-instances --filters Name=tag:Role,Values=nat Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text --profile aa365-admin --region us-west-1`
   - `aws ssm list-associations --query "Associations[?starts_with(AssociationName,'aa-ecosys-dev-nat')].[AssociationName,AssociationId,Overview.Status]" --output table --profile aa365-admin --region us-west-1`
2. Health before: `curl -s -o /dev/null -w '%{http_code}\n' https://api-cis.lumiguides.it.com/health/ready` returns
   200.
3. Swap first. After an apply it has already run. Otherwise:
   `aws ssm start-associations-once --association-ids <swap id> --profile aa365-admin --region us-west-1`. Wait about
   a minute, then read the output:
   - `aws ssm list-commands --filters key=DocumentName,value=aa-ecosys-dev-nat-swap --max-items 1 --query 'Commands[].[CommandId,Status]' --output text --profile aa365-admin --region us-west-1`
   - `aws ssm list-command-invocations --command-id <command id> --details --query 'CommandInvocations[].CommandPlugins[].[Status,ResponseCode,Output]' --output text --profile aa365-admin --region us-west-1`

   Expect `Success`, 0, and an output with `swap: /swapfile created (1024 MB) and active` (first time) or
   `already active`. The `swapon --show` line names `/swapfile`.
4. Patch: `aws ssm start-associations-once --association-ids <patch id> --profile aa365-admin --region us-west-1`.
   With swap a run takes minutes. Check every ~5 minutes (not continuously):
   `aws ssm list-commands --filters key=DocumentName,value=AWS-RunPatchBaseline --max-items 1 --query 'Commands[].[CommandId,Status,RequestedDateTime]' --output text --profile aa365-admin --region us-west-1`
5. Patch state:
   `aws ssm describe-instance-patch-states --instance-ids <instance id> --query 'InstancePatchStates[].[Operation,OperationEndTime,InstalledCount,InstalledPendingRebootCount,MissingCount,FailedCount,InstalledRejectedCount]' --output table --profile aa365-admin --region us-west-1`

   Expect `Install`, a fresh end time and `FailedCount` 0. `MissingCount` should be 0 after an Install.
6. Health after: `/health/ready` 200 again, and egress from an ECS task works: through ECS exec (S3-mediated pattern,
   root `docs/ops/runbooks/ecs-exec-s3-mediated.md`) run
   `python3 -c "import urllib.request;print(urllib.request.urlopen('https://checkip.amazonaws.com',timeout=10).read())"`
   in the CIS api container; it prints the NAT's public IP. The patched instance reports `PingStatus Online`:
   `aws ssm describe-instance-information --filters Key=InstanceIds,Values=<instance id> --query 'InstanceInformationList[].[PingStatus,AgentVersion]' --output text --profile aa365-admin --region us-west-1`

## When it fails

| Symptom | Meaning | Do |
|---|---|---|
| Swap run `Failed`, output `no swapfile made` | Less than 1.5 GB free on `/` | Free space (old journals: `journalctl --vacuum-size=100M` through an SSM session), then run the swap association again. Do not grow the volume in a hurry: a resize is a separate change. |
| Patch `TimedOut` again with swap active | dnf still too slow | Read the full step output (`--details`). If it thrashed again, the next step is `t4g.micro` (about 3 USD/month, instance replacement, its own approval). |
| Patch `Failed`, a package error | A package did not install | The output names it. The next Sunday run retries. A repeated failure is a ticket. |
| Instance `ConnectionLost` after a reboot | The instance did not come back | AWS Health / instance status checks; a stop/start keeps the instance (EBS-backed, EIP kept) and only the tech lead decides it. |

The association execution history also shows each run:
`aws ssm describe-association-executions --association-id <id> --max-results 3 --profile aa365-admin --region us-west-1`.
