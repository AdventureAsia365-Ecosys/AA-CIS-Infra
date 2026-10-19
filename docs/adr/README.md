# AA-CIS-Infra ADRs

Infrastructure-only decisions: a decision that, if reversed, changes only this repo (IAM, network, Terraform
roots, CI roles, alarms). A decision that also changes an app repo or the shared database is an ecosystem ADR in
the AA-Ecosys repo under `docs/adr/`; an infra ADR that implements one cites it.

There is no infra-only ADR yet. The ecosystem ADRs this repo implements today:

| Root ADR | Decision | What it means here |
|---|---|---|
| 0001 | Ecosystem target architecture | One AWS account (acc2) for all apps; satellite accounts only for Bedrock |
| 0003, 0003a | One durable job model; one job table per owner schema | DB Migrate deploy guard on queued or running jobs |
| 0004 | AA-Booking stack and bootstrap | `accounts/aa365/booking.tf`, Booking deploy role, `db/migrations/booking/` |
| 0004b | One security group per caller | Per-app security groups and the RDS ingress rules |
| 0006, 0006a | Ecosystem identity on Cognito | `accounts/aa365/identity.tf`, staff pools and triggers |
| 0008 | New-app integration and data platform rules | Tags, schema ownership, migration copies, isolation probe |

Older decisions recorded as `ADR-2026-NNN` (for example ADR-2026-022, acc1 kept for the Bedrock fallback, and
ADR-2026-023, trunk-based development) predate the ADR folders and live in the team's Notion. Design notes in
[`docs/`](../) (CI role split, agent session role, WAF count review) explain how things are built; they are not
decisions and do not need an ADR entry.

Each ADR is `docs/adr/NNNN-<slug>.md`, numbered from `0001`, with a status line near the top
(`- **Status:** Accepted (dd/mm/yyyy, S<nnn>)`). Add it to the table below in the same PR.

| ADR | Decision | Status | Implements | Linear |
|---|---|---|---|---|
| — | none yet | — | — | — |

Template: the ecosystem ADR template (AA-Ecosys `docs/templates/adr.md`).
