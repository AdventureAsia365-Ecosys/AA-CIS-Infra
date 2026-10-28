# AA-979 P2b clean-up (runbook §4.5): Infra side

Session S256, agent Claude Code. Branch `chore/aa-979-portal-cleanup`. Runbook: root
`docs/audits/2026-10-26-S252-aa979-p2b/RUNBOOK.md` §4.5; design §2.5 / §5 (redirect table) in the same folder. Pulled
ahead of the "from 03/11" gate (Dev has no real users). Companion PRs: AA-Partner `chore/aa-979-portal-cleanup`,
AA-CIS-App `chore/aa-979-remove-frozen-portal`, root `docs/aa-979-portal-cleanup`.

## Decisions

- **`crm_portal_api_key_signin` default `false`** (no tfvars override): the studio task gets
  `PORTAL_API_KEY_SIGNIN=false`; its `/tenant-login` answers 308 to the partner sign-in (AA-Partner PR).
- **Cutover switch removed**: `crm_agency_live`, `crm_agency_vercel_target`, `crm_agency_dns_ttl` are gone; the
  `portal.` CNAME always targets the `crm_agency` distribution, TTL 300 (was 60 for the window). The `moved` block from
  `vercel_frontend["portal"]` stays (harmless, documents the history). The record's precondition now says the agency
  host needs the CRM edge.
- **`partner-dev.` → `portal.` 301 at the edge**: a viewer-request CloudFront Function (`cloudfront-js-2.0`,
  `cloudfront_functions/crm_partner_to_agency.js`, `templatefile` fills the agency origin) on the partner distribution's
  default behaviour. It keeps the path and the query (multi-value keys too) and lets `/crm` and `/crm/*` through (the
  Partner deploy gates and server-to-server callers POST there; design: "except `/crm/*`"). `Cache-Control:
  max-age=3600` on the 301 (browsers keep 301s anyway; the header only bounds shared caches). One function, no new
  cache behaviour: the default behaviour already carries every path.
- **CRM API origins moved** to the agency host: `PARTNER_WEB_ORIGIN` (join links) and `MAIL_OAUTH_REDIRECT_BASE` (mail
  OAuth callback `https://portal.<zone>/connect/mail/callback`). `CRM_API_ORIGIN` (web → API, server to server) stays on
  `partner-dev.` (not redirected).
- **CRM web `WEB_PUBLIC_ORIGIN`** (the fallback origin) moved to `portal.`; `WEB_PARTNER_HOSTS` keeps both hosts, so
  taking the 301 away again needs no web change.
- **EXTERNAL `cis-portal` client**: the tenant portal's placeholder callback / sign-out URLs (`portal.`
  `/api/auth/callback/cognito`, `/tenant-login`, `localhost:3004`) are removed (design: "remove the `cis-portal`
  EXTERNAL client callbacks to `portal.`"). The partner-host entries stay for the CRM web's fallback.
- **Env config register**: `aa-cis-portal` leaves `REQUIRED_VERCEL` and the Vercel snapshot (the nightly page would
  otherwise report a collection problem once the project is deleted).
- **Live check** `tools/terraform/crm_edge_live_check.py`: partner `/`, `/crmx?x=1`, `/healthz` must be 301 to the same
  path on `portal.`; `crm-health` on the partner host must still reach the API; the agency checks gain `agency-healthz`
  and `agency-studio` now wants the 308 (`next=%2Fportal%2Fdashboard`). The function itself is unit-tested by running
  it in Node (`test_crm_edge_live_check.py`, already in the ALB Rule Order workflow).

## Changed

- Runbook "optional portal.-only certificate": not done. The wildcard keeps working; swapping the certificate on a
  live distribution is risk without a Dev benefit.
- Runbook "`/trip` 307 → 301" lives in AA-CIS-App (`frontend/next.config.ts`), not here.

## Tradeoffs

- 301 (not 308) as the runbook says: for the browser GET navigations that reach `partner-dev.` now, the two are the
  same; the only POSTs that matter (`/crm/*`) are excluded.
- Query values are copied as CloudFront hands them to the function (no decode / re-encode); verify a percent-encoded
  query live once (orchestrator step).

## Should know

- **Before the apply (vendor console, browser)**: add `https://portal.lumiguides.it.com/connect/mail/callback` to the
  Google OAuth client's authorised redirect URIs (the client whose id/secret are in `crm/dev/mail-oauth`); keep the
  `partner-dev.` URI until the next Partner API deploy is verified. No Microsoft app exists yet (AA-945 M365 blocked).
- Apply effects: new task definition revisions for `aa-crm-dev-api` (2 env values), `aa-crm-dev-web`
  (`WEB_PUBLIC_ORIGIN`) and `aa-crm-dev-portal` (`PORTAL_API_KEY_SIGNIN`); the services keep running the old revision
  until the AA-Partner deploys (the API deploy waits for an idle `crm.job`). Route 53: TTL 60 → 300 in place.
  CloudFront: one function created + the partner distribution updated in place. Cognito: `cis-portal` client
  updated in place (same id). Re-plan "No changes" after.
- After the apply, `partner-dev.` (except `/crm/*`) answers 301: set the AA-Partner repository variable
  `E2ECRMPARTNER` (and the `dev` environment variable `CRM_WEB_BASE_URL`, if it is set) to `https://portal.lumiguides.it.com`.
- Cost: CloudFront Functions $0.10 per million invocations beyond the always-free 2 M/month; Dev traffic is inside it
  ($0). Nothing else new.
