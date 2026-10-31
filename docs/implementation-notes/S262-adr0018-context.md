# S262 — CONTEXT.md account model after root ADR 0018 and ADR 0009 were accepted

Source: root `docs/audits/2026-10-31-S262-tl-decisions/README.md` item TL-1 ("ADR 0018 → Accepted; C7.2a/c, DM-9.6,
Infra CONTEXT.md in the same root/Infra PR"). The root PR (branch `docs/s262-tl-decisions`) carries the ADR and the
data standards v1.9; this PR only updates this repo's map.

## Decisions

- A second table under the account model names the target accounts (`aa-management`, `aa-nonprod`, `aa-prod`,
  `aa-ai`) with their roots. No new account ID is written: the management ID stays in the root onboarding map and the
  `MGMT_ACCOUNT_ID` secret.
- The "acc3 only" sentence is reworded to the accepted ADR 0009 decision 14: acc2 may serve chat models for eval, judge
  and validate stages after qualification; no acc2 chat route exists yet (route snapshot 29/10/2026).

## Changed

- `CONTEXT.md` only. No Terraform change, so the plan is empty.

## Tradeoffs

- The existing acc1/acc2/acc3 table is kept as the "today" view; renaming roots is optional clean-up in ADR 0018.

## Should know

- `last_reviewed` is not moved: no live check was run for this edit.
