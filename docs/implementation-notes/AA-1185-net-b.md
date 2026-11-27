# AA-1185 — network hygiene B: narrowed outbound rules on the per-caller security groups (S296, lane l10-net-hygiene)

Issue comment "scope 8" item 1 (tech lead approval 27/11/2026, S295 audit SA-37 / DB-07). 0 USD. One of three
separate Infra PRs (A: legacy group cleanup, B: this, C: NAT domain filter design), each applied and watched alone.

## Decisions

- **Scope: the ten per-caller groups of ADR 0004b** (`app_security_groups.tf`): cis-api, cis-worker, booking-api,
  crm-api, crm-web, staff-web, tp-web, tp-lambda, db-migrate, ops-lambda. Not changed: the NAT group (it forwards
  everything by design), the ALB and NLB groups (edge path, own change), the CloudFront VPC origin group (AWS-managed),
  the default groups (no workload).
- **Rules, from the outbound inventory (27/11, app code + this repo):**

  | Caller | 443 out | 5432 to db subnets | 6379 to private subnets | SMTP 25/465/587/2525 |
  |---|---|---|---|---|
  | cis-api, cis-worker | yes | yes | yes | |
  | booking-api | yes | yes | | |
  | crm-api | yes | yes | | yes |
  | tp-lambda, db-migrate | yes | yes | | |
  | crm-web, staff-web, tp-web, ops-lambda | yes | | | |

  443 covers: ECR pull, CloudWatch Logs, Secrets Manager, SSM and ECS Exec, STS, SES v2 (Booking `backend/app/mailer.py`
  and CIS `shared/aws_client/ses_mailer.py` use the API, not SMTP), SQS, S3 (gateway endpoint), Cognito (JWKS, token
  endpoint), Bedrock (this account and the cross-account invoker roles), Anthropic, OpenAI, DataForSEO, Geoapify,
  Overpass, Google APIs (Drive photos), Jev, Mapbox, Sentry, the public app hosts, and the tenant HTTPS sites behind the
  CIS SSRF-safe client. Plain HTTP (80): no call site in the four apps (searched for `http://` URLs outside tests).
  SMTP: only AA-Partner `api/app/mail/providers/smtp.py` (its `PORTS` set is the only list it dials). No IMAP/POP,
  FTP, SSH, gRPC or broker clients in any app.
- **No DNS rule.** DHCP options are AmazonProvidedDNS (read live), and security groups never filter traffic to the
  Amazon resolver, the instance / task metadata endpoints or Amazon Time Sync.
- **Data stores by subnet CIDR, not by group.** The RDS and Redis groups admit the ids of these groups, so an egress
  rule naming them back would be a Terraform cycle. The data-store side still admits only the listed callers.
- **One-variable rollback:** `sg_egress_narrowed = false` puts the old all-outbound rule back on every group, in place.
  Plan checked locally (read-only, `-lock=false`, targeted on the ten groups): `0 to add, 10 to change, 0 to destroy`
  for the change, and the rollback value plans back to one `-1 / 0.0.0.0/0` rule per group (description text only
  differs from today).

## Changed (vs the approved plan)

- crm-web, staff-web and tp-web (no database) get 443 only; the plan text named "app SGs" generally.
- ops-lambda (dfs-balance check) gets 443 only (no data store).

## Tradeoffs

- 443 to `0.0.0.0/0` still lets a compromised task talk HTTPS to any host; the domain allow-list on the NAT instance
  (PR C, design) is the layer that narrows destinations. This PR removes every other port and protocol.
- A tenant WordPress site on a non-standard HTTPS port (for example `:8443`) is no longer reachable from CIS (the
  SSRF-safe client allowed any port). None is configured on Dev; a follow-up can make CIS refuse such a URL up front
  with a clear message.
- The provider revokes the old rule before it authorizes the new ones on each group, so new outbound connections can
  wait about a second during the apply (TCP retries the SYN). Existing connections are tracked and continue.

## Should know

- **Watch after apply** (orchestrator live steps in the PR body): every app `/health` and `/health/ready`, a CIS gateway
  health call (Bedrock / Anthropic / OpenAI), a CIS worker job, CRM jobs and a CRM SMTP test send if an agency mailbox
  is configured, TripPlanner browse (Lambda to RDS), a DB Schema Dump run (db-migrate group), and the VPC flow logs
  (REJECT only on Dev) for rejected outbound flows from the private subnets on any port other than 443 / 5432 / 6379.
- No new AWS resource, no IAM change, no bootstrap step. The SG-change alert ignores the Terraform apply role.
- Generated root docs (`docs/generated/network.md`) show the new egress after their next regeneration.
