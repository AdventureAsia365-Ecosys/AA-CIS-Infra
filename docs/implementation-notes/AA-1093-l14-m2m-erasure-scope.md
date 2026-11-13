# AA-1093 lane L2 (S279 l14) — M2M scope cis.tenant/erasure

## Decisions
- One new scope `erasure` on the existing resource server `cis.tenant` (root contract `tenant.erasure.v1`
  securitySchemes.m2m: `cis.tenant/erasure`). The CRM client `m2m_crm` takes every scope of this server, so it gets
  the new one with no other change. AA-CIS-App pins the scope per route (`api/core/m2m_auth.SCOPE_TENANT_ERASURE`).

## Changed
- `accounts/aa365/identity_m2m.tf`: `idm2m_tenant_scopes` gains `erasure`. Nothing else.

## Tradeoffs
- Its own scope rather than reusing `cis.tenant/read`: the report route writes, and CIS pins one scope per route class
  (as `cis.tenant/addons` did, AA-1036).

## Should know
- In-place update of the resource server and of the client's allowed scopes; re-plan after the apply ("No changes"
  expected; the client may take the new scope on a second apply, S252 lesson).
- Until applied, the CRM gets 403 from `/tenant/v1/erasure-requests` (the CIS routes are live after the CIS deploy).
