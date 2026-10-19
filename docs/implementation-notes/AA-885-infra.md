# AA-885 (infra part, PR-A) — portal.lumiguides.it.com + cis-portal client URLs (S243)

Context: the CIS tenant portal moves out of the admin frontend (Vercel project `aa-cis-frontend`,
host `aa-cis.lumiguides.it.com`) into its own Next.js app `portal/` in AA-CIS-App, deployed as a
second Vercel project `aa-cis-portal` on `portal.lumiguides.it.com` (Nghiệp, S243). This PR only
adds the DNS record and re-points the (still unused) Cognito `cis-portal` app client.

## Decisions

- **DNS in the existing pattern**: one more entry `portal` in `var.custom_domain_vercel_hosts`
  (`custom_domains_variables.tf`), so `aws_route53_record.vercel_frontend["portal"]` is a CNAME in the
  existing `lumiguides.it.com` zone, TTL 300, gated by `custom_domains_enabled` (already `true`).
  No new resource type, no new IAM.
- **CNAME target**: the `aa-cis-portal` Vercel project did not exist yet when this was written
  (read-only `list_projects search=portal` → empty), so the project-specific `*.vercel-dns-017.com`
  target was unknown. The value committed is Vercel's generic `cname.vercel-dns.com`, which Vercel
  accepts for any project-attached sub-domain. The main session swaps in the `recommendedCNAME` from
  `get_project_domain` / `get_domain_config` after S0, to match the tripplanner / booking entries.
  It is one line: replace the whole `portal = ...` line (value and its PLACEHOLDER comment) with
  `portal = "<recommendedCNAME>" # S243 AA-885: tenant portal, domain added to aa-cis-portal first (verified)`,
  commit, and only then push, so the CI plan shows the real target. The placeholder is never pushed.
- **Callback / logout paths for `cis-portal`** (EXTERNAL pool, confidential client):
  - callback `https://portal.lumiguides.it.com/api/auth/callback/cognito` and
    `http://localhost:3004/api/auth/callback/cognito`;
  - logout `https://portal.lumiguides.it.com/tenant-login` and `http://localhost:3004/tenant-login`.
  - Same callback path shape as `cis-admin` (`/api/auth/callback/cognito` on its own host): the portal
    is its own app now, so the old `/portal/api/...` prefix (a path inside the admin app) is dropped.
    The logout lands on the portal's existing `/tenant-login` page. 3004 is the portal dev port
    (`next dev -p 3004`, AA-885 plan S4a).
  - Still placeholders: tenants sign in with an API key until AA-813 (Phase 3) implements the Cognito
    callback route. AA-813 must use exactly these paths, or change them here.

## Changed

- `accounts/aa365/custom_domains_variables.tf`: `portal` entry + description line.
- `accounts/aa365/identity_variables.tf`: `cis-portal` URLs + description line.
- `CONTEXT.md`: Vercel host list on the `custom_domains.tf` line.
- Nothing else; the plan in the issue asked for exactly this.

## Tradeoffs

- Generic vs project-specific CNAME target: both resolve to Vercel's edge; project-specific is
  Vercel's current recommendation and what the other two hosts use, hence the swap before push.
  Shipping the generic target is safe functionally but still needs the project to claim the host first.
- Keeping the same `/api/auth/callback/cognito` path name for admin and portal: different hosts,
  different clients, different pools, so no clash; it keeps one convention for AA-813.

## Should know

- **Order (takeover risk):** the domain must be added to `aa-cis-portal` (S0) BEFORE this applies.
  A CNAME to Vercel that no project claims can be served by another Vercel account.
- **Expected `terraform plan` (CI and the apply run), nothing else:**
  - `+ aws_route53_record.vercel_frontend["portal"]` (CNAME `portal.lumiguides.it.com` → target, ttl 300);
  - `~ aws_cognito_user_pool_client.external["cis-portal"]` update in-place: `callback_urls` and
    `logout_urls` only (the 2 old aa-cis/localhost:3000 URLs out, the 2 new ones in, each list);
  - `Changes to Outputs: ~ custom_domain_urls.frontends` gains `https://portal.lumiguides.it.com`.
  - Plan: 1 to add, 1 to change, 0 to destroy. Anything else = stop.
- The Cognito client update goes through Terraform Apply (environment `prod`); the client is unused
  today, so there is no user impact. Cost: $0/month (record in an existing zone, in-place client edit).
