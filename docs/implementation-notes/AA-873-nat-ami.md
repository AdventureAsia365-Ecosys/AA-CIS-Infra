# NAT AMI fix (S255, root audit finding F-4) — plain AL2023 image through the public SSM parameter

Session S255 (28/10/2026), Claude Code Infra lane. Branch `fix/aa-873-nat-ami-ssm`. Refs AA-873 (it removes
management-event noise GuardDuty would bill) and AA-896 (FinOps finding).
Source: root audit `docs/audits/2026-10-28-S255-finops-security/` F-4 and draft `tf/vpc_nat_ami_fix.tf`.

## Decisions

- **Root cause confirmed live (28/10/2026, read-only):** the running NAT instance was launched 07/10/2026 from
  `al2023-ami-ecs-hvm-2023.0.20260701-kernel-6.1-arm64` (the ECS-optimized image). The filter
  `al2023-ami-*-arm64` + `most_recent` matches it. Its ECS agent calls `RegisterContainerInstance` in a loop
  (3,586 CloudTrail events on 26/10).
- **`data.aws_ssm_parameter.nat_al2023_arm64`** (`/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64`,
  `ami-097a0378c5bf95711` on 28/10) replaces `data.aws_ami.nat_al2023`. `insecure_value` is used: `value` is marked
  sensitive by the provider and an AMI id is not secret.
- **`ignore_changes = [ami, user_data]`** (was `[ami]`). The draft only added a line to `user_data`, which would have
  been an in-place update that **stops and starts** the NAT instance (provider: `user_data_replace_on_change` false
  -> modify the attribute on a stopped instance) = egress outage for every private subnet. Proven offline (provider
  6.69.1, fake credentials, `plan -refresh=false` on a crafted state, probe in root `.tmp-session/S255/infra/
  provider_probe/nat_gen.py`): `[ami]` -> "1 to change" (`user_data`); `[ami, user_data]` -> "No changes", with
  both the AMI and the user data different from the state.
- **user_data gains `systemctl disable --now ecs || true`** as a guard for the next deliberate replacement.
- **The running instance is fixed by SSM Run Command** (orchestrator: root `.tmp-session/S255/infra/
  nat_disable_ecs_agent.sh`), not by Terraform.

## Changed

- `modules/vpc/main.tf`: data source, `ami` argument, user_data line, lifecycle + comments.

## Tradeoffs

- Ignoring `user_data` means a future edit to the NAT bootstrap script never reaches the running instance through
  Terraform; it only applies at a replacement (`-replace=module.vpc.aws_instance.nat` in a planned window). That is
  the same contract `ami` already had; the comment says so.
- The tightened `aws_ami` filter (`al2023-ami-2023.*-kernel-6.1-arm64`) would have needed no new grant; the SSM
  parameter was chosen because it is the AWS-documented pointer to the current plain image and cannot match a
  variant by accident.

## Should know

- **Cost: 0 USD** (removes ~0.11 M management events/month, ~0.5 USD/month of GuardDuty once it is on).
- **Prerequisite:** the apply role needs `ssm:GetParameter` on `arn:aws:ssm:us-west-1::parameter/aws/service/
  ami-amazon-linux-latest/*` (`AmazonECS_FullAccess` only covers `/aws/service/ecs*`). The grant is Sid
  `PublicAmiParameterRead` in `accounts/aa365/cicd_sec.tf` of PR `feat/aa-873-security-baseline-free`; apply that
  bootstrap first, or CI apply fails on refresh. The plan role reads it through ReadOnlyAccess.
- **Expected CI plan:** 0 add, 0 change, 0 destroy (only a data source swap). Any diff on `module.vpc.aws_instance.nat`
  = stop and investigate before applying.
