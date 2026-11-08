-- Migration 391: AA-1050 (Quality W4, root ADR 0020 "Layers" 6 Measurement, D6 / D7) — the shadow verdicts of the
-- pinned claim instrument next to the live T9 F9 and T2 decisions, and its verdict cache.
--
-- Why. ADR 0020 W4: "Claim engine in shadow beside the interim T9 F9 and the T2 shadow verifier, on cassettes of
-- recent objects and audit-tenant writes. The tech lead labels about 30 disagreements" (root audit
-- docs/audits/2026-11-06-S271-writing-quality-audit/, data/design-review.json arch.roadmap[4]). Proof: "shadow
-- < $0.30, mostly from the cache"; "the new instrument is right in >= 80% of the sampled disagreements with F9"; "0
-- hold verdicts from a non-pinned rung". No existing table holds a per-object instrument verdict next to the live
-- decision it shadows: shared.llm_call_log has one row per billed call (a cache hit bills nothing and must still be
-- counted), shared.llm_shadow_log compares two models' raw outputs per stage with no object or tenant, and the piece /
-- version rows are the tenant's content (the shadow must never write them: it never changes a status).
--
-- What.
--   1. shared.claim_shadow_verdict: one row per (run, object, instrument input). An object is a T9 piece
--      (acp_shared.content_piece.piece_id, surface t9_blog / t9_social) or a T2 tenant version
--      (gold_aa_internal.tenant_tour_versions.id, surface t2), named by id, no foreign key (the owners prune on their
--      own windows). run_kind live = written by the T9 / T2 job after the piece / version was saved (run_id = the job
--      id); replay = the replay corpus runner (run_id = its run id). verdict is the instrument's (supported |
--      unsupported | unverified: a miss, a refusal, a split vote, an answer from another model or connection, or the
--      spend guard; never a pass, D7) with a typed reason ('<verdict>:<class or cause>'); baseline is the live
--      decision it shadows (F9_cta_fact for T9; the brand-claim check of the saved T2 version), agreement compares
--      the two. shadow_action is what the per-(writer, class) enforce map would do (all 'warn' until a class passes
--      W2; nothing acts on it). cache_key = sha256 of the instrument id, the votes, the prompt sha and every field's
--      user prompt: a later object with the same text and source reuses the last definitive verdict (cached true,
--      cost 0, 0 calls). details holds positions, claim hashes, classes and vote patterns only: no text.
--   2. RLS like the neighbouring shared eval tables (CIS 388 eval_claim_label): ENABLE + FORCE,
--      claim_shadow_verdict_cis_app_all and claim_shadow_verdict_cis_owner_all (X1 runtime parity, CIS 244 / 245),
--      and tenant_isolation for aa_app_user (the tenant pool holds no privilege: shadow verdicts are admin data, the
--      policy is the floor if one is ever granted).
--   3. Grants: REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (cis_owner's default privileges
--      in shared, CIS 245, would give cis_app UPDATE), then GRANT cis_app SELECT, INSERT, DELETE (the shadow writes
--      and reads, the tenant erasure deletes). No UPDATE: a verdict is never rewritten.
--   4. Register 391.
--
-- PII (DM-6.1). No text column: details carries spans, claim hashes, classes and votes. tenant_id links a row to the
-- agency. Tenant erasure (AA-839, services/erasure/inventory.py): delete the tenant's rows.
--
-- Retention (DM-7.1). Proposed: 180 days (created_at), like shared.llm_call_log that bills the same calls; the rows a
-- measurement record names are kept with it. Row in root data standards Part B section 7, in the root PR of this
-- change (merged before the Infra copy). No deletion job yet (proposed TTL kind retention_claim_shadow_verdict, DRY
-- RUN first).
--
-- Behaviour. None on apply: the table is new and empty. The code that writes it (the next PR) runs only when
-- CLAIM_SHADOW=on (default off); without the table the shadow fails open (logged, no row, no status change) and the
-- admin summary answers 503.
--
-- Class: contract (no '-- migrate:' directive), like CIS 388: the expand lint refuses the REVOKE that keeps UPDATE
-- away from cis_app (cis_owner's default privileges in shared) and the DROP POLICY IF EXISTS that keeps a re-apply a
-- no-op. MIG-4: this migration-only PR, the Infra copy, the Migration Apply run (every job table idle, root ADR 0017a),
-- then the code PR. No readiness raise: nothing on a live path needs the table (the shadow is off by default and fails
-- open).
--
-- Rollback (a new forward migration, after the code is reverted): DROP TABLE shared.claim_shadow_verdict (a
-- destructive file, DRY RUN). Nothing on a live path reads it.
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of shared.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS shared.claim_shadow_verdict (
    verdict_id      uuid          NOT NULL DEFAULT gen_random_uuid(),
    created_at      timestamptz   NOT NULL DEFAULT now(),
    run_kind        text          NOT NULL,
    run_id          text          NOT NULL,
    surface         text          NOT NULL,
    tenant_id       uuid,
    piece_id        uuid,
    version_id      uuid,
    job_id          uuid,
    content_sha256  text          NOT NULL,
    cache_key       text          NOT NULL,
    instrument_id   text          NOT NULL,
    policy_sha      text,
    cached          boolean       NOT NULL DEFAULT false,
    verdict         text          NOT NULL,
    reason          text          NOT NULL,
    shadow_action   text          NOT NULL DEFAULT 'none',
    baseline        text          NOT NULL,
    baseline_status text,
    agreement       text          NOT NULL,
    pinned          boolean       NOT NULL,
    calls           integer       NOT NULL DEFAULT 0,
    cost_usd        numeric(10,6) NOT NULL DEFAULT 0,
    answered_model  text,
    max_rung        smallint,
    details         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT claim_shadow_verdict_pkey PRIMARY KEY (verdict_id),
    CONSTRAINT claim_shadow_verdict_run_key UNIQUE (run_kind, run_id, cache_key),
    CONSTRAINT claim_shadow_verdict_run_check CHECK (
        run_kind IN ('live', 'replay') AND run_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'),
    CONSTRAINT claim_shadow_verdict_surface_check CHECK (surface IN ('t9_blog', 't9_social', 't2')),
    -- a T9 object is a piece, a T2 object a tenant version: exactly one id, the one of its surface
    CONSTRAINT claim_shadow_verdict_object_check CHECK (
        (surface = 't2' AND version_id IS NOT NULL AND piece_id IS NULL)
        OR (surface <> 't2' AND piece_id IS NOT NULL AND version_id IS NULL)),
    CONSTRAINT claim_shadow_verdict_sha_check CHECK (
        content_sha256 ~ '^[0-9a-f]{64}$' AND cache_key ~ '^[0-9a-f]{64}$'
        AND (policy_sha IS NULL OR policy_sha ~ '^[0-9a-f]{64}$')),
    CONSTRAINT claim_shadow_verdict_instrument_check CHECK (
        instrument_id ~ '^[a-z0-9][a-z0-9._-]{0,63}@[a-z0-9][a-z0-9._-]{0,63}:(extraction|entailment)$'),
    CONSTRAINT claim_shadow_verdict_verdict_check CHECK (verdict IN ('supported', 'unsupported', 'unverified')),
    -- the typed reason starts with its verdict: 'unsupported:fact.inclusion', 'unverified:miss', 'supported:clear'
    CONSTRAINT claim_shadow_verdict_reason_check CHECK (
        reason ~ '^(supported|unsupported|unverified):[a-z0-9_.]{1,60}$' AND split_part(reason, ':', 1) = verdict),
    CONSTRAINT claim_shadow_verdict_action_check CHECK (shadow_action IN ('none', 'warn', 'review', 'hold')),
    CONSTRAINT claim_shadow_verdict_baseline_check CHECK (
        baseline IN ('pass', 'flag', 'warn', 'unavailable', 'none')
        AND (baseline_status IS NULL OR baseline_status ~ '^[a-z_]{1,32}$')),
    CONSTRAINT claim_shadow_verdict_agreement_check CHECK (
        agreement IN ('agree', 'disagree', 'unverified', 'no_baseline')),
    -- a cache hit bills nothing and makes no call
    CONSTRAINT claim_shadow_verdict_counts_check CHECK (
        calls >= 0 AND cost_usd >= 0 AND (max_rung IS NULL OR max_rung >= 0)
        AND (NOT cached OR (calls = 0 AND cost_usd = 0))),
    CONSTRAINT claim_shadow_verdict_model_check CHECK (
        answered_model IS NULL OR char_length(answered_model) BETWEEN 1 AND 200),
    CONSTRAINT claim_shadow_verdict_details_check CHECK (
        jsonb_typeof(details) = 'object' AND octet_length(details::text) <= 65536)
);

-- the cache read: the newest definitive verdict of one cache key
CREATE INDEX IF NOT EXISTS claim_shadow_verdict_cache_idx ON shared.claim_shadow_verdict (cache_key, created_at DESC)
    WHERE NOT cached AND verdict <> 'unverified';
CREATE INDEX IF NOT EXISTS claim_shadow_verdict_created_idx ON shared.claim_shadow_verdict (created_at DESC);
CREATE INDEX IF NOT EXISTS claim_shadow_verdict_tenant_idx ON shared.claim_shadow_verdict (tenant_id)
    WHERE tenant_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS claim_shadow_verdict_piece_idx ON shared.claim_shadow_verdict (piece_id)
    WHERE piece_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS claim_shadow_verdict_version_idx ON shared.claim_shadow_verdict (version_id)
    WHERE version_id IS NOT NULL;

COMMENT ON TABLE shared.claim_shadow_verdict IS
    'AA-1050 (CIS 391, root ADR 0020 W4): the pinned claim instrument''s shadow verdict of one T9 piece or T2 '
    'version next to the live decision it shadows (F9_cta_fact / the T2 brand-claim check), and its verdict cache. '
    'Never changes a status. No text (spans, claim hashes, classes, votes). Admin data: no tenant route reads it. '
    'Goes with the tenant (AA-839).';
COMMENT ON COLUMN shared.claim_shadow_verdict.reason IS
    'AA-1050 (391): typed reason "<verdict>:<class or cause>": unsupported:<policy class>, unverified:miss | refused '
    '| split | identity | budget | error, supported:clear. A miss or a refusal is unverified, never a pass (D7).';
COMMENT ON COLUMN shared.claim_shadow_verdict.shadow_action IS
    'AA-1050 (391): what the per-(writer, class) enforce map would do: warn for every class until a class passes W2 '
    '(hold / review only for an enforce class, from pinned votes). Recorded only: nothing acts on it.';
COMMENT ON COLUMN shared.claim_shadow_verdict.cache_key IS
    'AA-1050 (391): sha256 of the instrument id, the votes, the system prompt + schema sha and each field''s user '
    'prompt; a cached row (cached = true, 0 calls, cost 0) reused the newest definitive verdict of the key.';

ALTER TABLE shared.claim_shadow_verdict ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.claim_shadow_verdict FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS claim_shadow_verdict_cis_app_all ON shared.claim_shadow_verdict;
CREATE POLICY claim_shadow_verdict_cis_app_all ON shared.claim_shadow_verdict AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS claim_shadow_verdict_cis_owner_all ON shared.claim_shadow_verdict;
CREATE POLICY claim_shadow_verdict_cis_owner_all ON shared.claim_shadow_verdict AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON shared.claim_shadow_verdict;
CREATE POLICY tenant_isolation ON shared.claim_shadow_verdict AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.claim_shadow_verdict IS
    'AA-1050 (CIS 391): own tenant rows only; the tenant pool holds no privilege (shadow verdicts are admin data), '
    'the policy is the floor if one is ever granted.';

-- Narrow cis_owner's default privileges (CIS 245) before the grant: without the REVOKE cis_app could UPDATE a verdict.
REVOKE ALL ON shared.claim_shadow_verdict FROM PUBLIC;
REVOKE ALL ON shared.claim_shadow_verdict FROM cis_app, aa_app_user, catalog_owner;
GRANT SELECT, INSERT, DELETE ON shared.claim_shadow_verdict TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('391', now(), 'AA-1050: shared.claim_shadow_verdict (claim instrument shadow verdicts + verdict cache)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
