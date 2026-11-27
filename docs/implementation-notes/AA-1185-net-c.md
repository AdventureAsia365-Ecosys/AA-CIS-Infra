# AA-1185 — network hygiene C: NAT destination allow-list, design only (S296, lane l10-net-hygiene)

## Decisions

- **Design note, no code** (`docs/nat-egress-allowlist.md`). The lane brief allowed code only for a small,
  low-risk `user_data` change. This is neither: `aws_instance.nat` ignores `user_data` (a change would stop the only
  NAT host), an SNI filter needs a userland proxy (Squid peek and splice) on the single egress path, and enforce mode
  needs decisions first (tenant-named hosts, fail-open or fail-closed, instance size).
- Chosen shape for the later build: SSM Command document + State Manager association (modes off / report / enforce),
  list in an SSM parameter from a Terraform local, report mode for a week before enforce.

## Changed (vs the issue scope)

- Scope 8 item 3 (domain allow-list) is not built in this wave; the follow-up is the Terraform PR of the rollout step 1.

## Tradeoffs

- Network Firewall (managed, no host to look after) was rejected on cost (about 290 USD/month).

## Should know

- Nothing to apply. The open decisions in the note go to the tech lead before the build.
