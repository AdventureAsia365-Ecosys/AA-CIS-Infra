# Design note — destination allow-list on the NAT instance (AA-1185)

Status: **design, not built** (S296, 27/11/2026). Approved in principle by the tech lead on 27/11/2026 as a 0 USD
item (the instance may need to grow from `t4g.nano` to `t4g.micro`, about +3 USD/month, which needs its own yes).
This note says how it would be built, what it costs, how it fails and what has to be decided first. Nothing in
Terraform changes with this note.

## Where it sits

Every outbound connection from the private subnets to the internet goes through one NAT instance
(`module.vpc.aws_instance.nat`, `t4g.nano`, Amazon Linux 2023, iptables MASQUERADE). Same-region S3 uses the S3
gateway endpoint and never reaches it. Since the egress change of this issue (PR B, `accounts/aa365/app_egress.tf`),
the app security groups let out only TCP 443 to the internet (plus agency SMTP from the CRM api); the security groups
decide **ports**, this allow-list would decide **host names** for 443.

## Options weighed

| Option | Filters on | Cost | Verdict |
|---|---|---|---|
| Squid on the NAT instance, transparent `ssl_bump` peek + splice (no decryption) | TLS SNI of 443 | 0 USD (+3 USD if `t4g.micro`) | **Chosen design** |
| nftables / iptables only | IP and port; SNI only by raw string match in the ClientHello | 0 USD | Rejected: provider IPs change (CDNs), string match on TLS is fragile and misses split ClientHellos |
| AWS Network Firewall (domain list rule group) | SNI and Host | about 290 USD/month per endpoint plus data | Rejected: cost |
| VPC interface endpoints for AWS APIs | removes AWS traffic from the NAT | about 96 USD/month | Rejected in S295 |
| Route 53 Resolver DNS Firewall | DNS names | per query | Separate approved item (managed threat lists); complements, does not replace, an SNI check |

## Design

1. **Interception.** iptables on the NAT instance redirects TCP 443 that arrives from the VPC CIDR
   (`PREROUTING -s <vpc cidr> -p tcp --dport 443 -j REDIRECT --to-port 3130`) to Squid's intercept port. Every other
   port keeps today's MASQUERADE path (agency SMTP cannot be filtered by name: STARTTLS on 25/587 has no SNI before
   the upgrade, and the agency names the host).
2. **Squid (AL2023 package), peek and splice only.** `https_port 3130 intercept ssl-bump`; step 1 peeks at the
   ClientHello; an SNI on the list is spliced (passed through untouched, end-to-end TLS as today); anything else is
   logged (report mode) or terminated (enforce mode). The CA that `ssl-bump` requires is generated on the host and
   never signs anything (no bump step). A connection without SNI is treated as "not on the list".
3. **Modes**, one parameter: `off` (no redirect rule, Squid stopped), `report` (splice everything, log the SNI of each
   connection and whether it is on the list), `enforce` (splice the list, terminate the rest).
4. **Fail-open in report mode, fail-closed only by decision.** A systemd unit with a watchdog checks Squid every 30 s;
   in `report` mode a failed check removes the REDIRECT rule, so traffic goes straight through MASQUERADE as today.
   Whether `enforce` fails open or closed is a decision below.
5. **Delivery without touching `user_data`.** `aws_instance.nat` ignores `ami` and `user_data` (a change would stop
   the only NAT host). The setup lives in an SSM Command document (`aa-cis-dev-nat-egress-filter`, parameters `mode`
   and the list), run by hand through SSM Run Command for each mode change, and attached as a State Manager association
   so a replaced instance gets it back (same pattern as the weekly patch association of this issue). The list itself is
   a Terraform local written to an SSM parameter (String), so a change is a PR, an apply and a rerun.
6. **Logs.** Squid access log on the host, rotated daily; a small script in the document sends the per-hour count of
   "not on the list" SNIs (name and count only, no path, no client data) to a CloudWatch log group with 30-day retention
   (well under 1 USD/month at Dev volume). No CloudWatch agent.

## Initial allow-list (from the PR B inventory)

`*.amazonaws.com` (every AWS API the tasks call: ECR, Logs, Secrets Manager, SSM and ECS Exec, STS, SES v2, SQS,
Cognito, Bedrock), `*.amazoncognito.com`, `public.ecr.aws`, the zone's own hosts (`*.<zone>`: api-cis., api-booking.,
api-tripplanner., portal., tripplanner., staff-auth.), `api.anthropic.com`, `api.openai.com`, `api.dataforseo.com`,
`api.geoapify.com`, `overpass-api.de`, `*.googleapis.com`, `*.sentry.io`, the Jev API host, `api.mapbox.com`, and the
CRM providers (payments, messaging, social) read from the AA-Partner provider registry when the list is built.

## Open decisions (before any code)

1. **Tenant-named hosts.** CIS publishes to the tenant's own WordPress site and the CRM uses the agency's own vendor
   accounts (bring your own). Those host names are not known in advance. Options: (a) a sync job that writes the hosts
   registered in the apps' integration settings into the list parameter; (b) splice any SNI that resolves to a public
   address and only block known-bad categories (then this is a log, not an allow-list); (c) send tenant-URL calls
   through a separate path. Recommendation: (a) for enforce, with report mode first to measure how many hosts that is.
2. **Enforce failure mode.** Fail-open keeps the apps running if Squid dies but lets anything out while it is down;
   fail-closed stops all HTTPS egress (every app, every AWS API call from tasks) until someone acts. Recommendation:
   fail-open plus an alarm on the watchdog event, until prod moves to a NAT gateway.
3. **Instance size.** The 7-day load read on 27/11/2026 is small (CPU average 0.3 %, maximum 1.6 %, full CPU credit
   balance, network out peaking around 300 MB per 5 minutes). Squid's memory, not CPU, is the risk on 512 MiB. Report
   mode for one week on `t4g.nano` with memory watched by SSM, then decide on `t4g.micro` (+3 USD/month).
4. **Prod.** A NAT gateway (prod plan) has no host to run Squid on; prod would need Network Firewall, DNS Firewall
   only, or a proxy tier. Decide with the prod network design, not here.

## Rollout and rollback

1. Terraform PR: the SSM document, the list parameter, the log group (30 days), the association with `mode = off`.
2. Run the document with `mode = report`; watch for a week: app `/health` and `/health/ready`, Bedrock and provider
   calls, CRM jobs, Squid memory, the "not on the list" log. Extend the list until report mode is quiet.
3. Tech lead decides on the open items, then `mode = enforce`.
4. Rollback at any step: run the document with `mode = off` (removes the REDIRECT rule and stops Squid: one SSM Run
   Command, under a minute). If SSM is unreachable, the NAT recover alarm and a deliberate instance replacement bring
   back the plain MASQUERADE host (`user_data` has no filter).
