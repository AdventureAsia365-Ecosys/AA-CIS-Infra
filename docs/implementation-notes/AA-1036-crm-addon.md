# AA-1036 R3 — M2M scope cis.tenant/addons (CRM add-on requests without a Content studio membership)

## Decisions

- One new scope `addons` on the existing `cis.tenant` resource server (`accounts/aa365/identity_m2m.tf`), served by
  AA-CIS-App under the root contract `tenant.addons.v1` (`GET /tenant/v1/tenants/{id}/add-ons`,
  `POST /tenant/v1/tenants/{id}/add-on-requests`). The CRM client `m2m_crm` takes every scope of the server, so it
  gets the new one with no other change.
- A scope of its own, not `cis.tenant/read` (read-only, no free text) nor `cis.tenant/activate` (identity binding):
  CIS pins one scope per route class.

## Changed

- `accounts/aa365/identity_m2m.tf`: `idm2m_tenant_scopes.addons`. Nothing else: the API Gateway route
  `/tenant/v1/{tenant_v1_proxy+}` is ANY already (AA-1028), and CIS reads no new variable.

## Tradeoffs

- None of cost: a scope is free; the CRM asks for a token of this scope only when an owner opens or uses the CRM's
  Add-ons page (cached 6 h).

## Should know

- Lessons (S252, AA-979): the client's `allowed_oauth_scopes` follows `scope_identifiers`, known only after the first
  apply, so the first apply updates the resource server and a second apply updates the client. Re-plan after the apply
  until "No changes".
- The `scopes` value of the `aa-crm/dev/m2m-booking-client` JSON is informational (the CRM asks for one scope per
  call); adding `cis.tenant/addons` to it is optional.
- Until the client holds the scope, the CRM's Add-ons page says the add-ons cannot be read (the token endpoint answers
  `invalid_scope`); nothing else in the CRM changes.
