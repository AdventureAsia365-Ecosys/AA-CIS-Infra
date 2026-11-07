-- Migration 388: AA-1048 (Quality W2, root ADR 0020 "Layers" 6 Measurement) — claim-level ground truth: the store of
-- human-anchored claim labels, and the 'golden_claim' source of the disagreement queue.
--
-- Why. ADR 0020: "A gate may hold content only with a passing measurement record (precision lower bound and recall on
-- enough labelled fires)". Today no gate has one: the blog golden set labels whole items (pass / fail), one of its
-- human labels is a test stub, the first-line panel agrees with the final labels at kappa 0.35, and nothing records a
-- label per claim. The audit (root docs/audits/2026-11-06-S271-writing-quality-audit/, README W2,
-- data/design-review.json arch.roadmap[2], critic fixes F2 / F14) asks for "shared.eval_claim_label + the
-- 'golden_claim' disagreement source; strata and hash splits; the private Dev DB is the master copy, with a manifest
-- in the root repo".
--
-- What.
--   1. shared.eval_claim_label: one row per judgement of one claim. A claim is a span of one stored object (a golden
--      item's frozen output, a T9 piece, an S1 Master version or a T2 tenant version, named by id: sample_id /
--      piece_id / tour_id / version_id; no foreign key, the owners prune on their own windows; content_sha256 = the
--      sha of the object's canonical JSON) identified by claim_hash = sha256 of the content sha, the field and the
--      normalised span text (services/ground_truth/claims.py); span_start / span_end index the field's text.
--      A judgement is a label (violation | ok | unsure) of the claim under a policy class (claim_class, a class id of
--      the policy registry: today services/quality/taxonomy.yaml) by a labeller: one row per lens of the 3-lens agent
--      panel (labeller_kind agent_panel, lens required) and one row per tech-lead adjudication (labeller_kind
--      tech_lead, adjudication 'final'). Panel rows carry the claim's state after the panel: agreed, disputed (the
--      lenses differ: the tech lead decides) or audit (an agreed claim drawn into the random 20% audit, critic F14).
--      Rows are grouped in a label set and its version (set_id CL-1 / L2 / t2@2, set_version x.y.z); a version is
--      immutable (no UPDATE grant): a relabel is a new version. split (train | held_out) is frozen by a hash of the
--      object's group key (its tour_id, else sample_id, piece_id or version_id, else its content sha), so every
--      object of one tour (master versions, tenant versions, blog and social pieces) falls on the same side and a
--      regenerated object keeps its side; stratum (hard | representative | mutants | traps) is the audit's sampling
--      stratum. policy_sha (nullable) is the sha of the policy text the
--      label was made under.
--   2. The disagreement queue (shared.writing_memory_disagreement, CIS 314) accepts source 'golden_claim': a disputed
--      or audit-drawn claim (source_ref = the label_id of its first panel row) waiting for the tech lead's one-click
--      resolution (judge_right = the panel label stands, human_right = it flips, unclear).
--   3. RLS like the neighbouring shared eval tables (CIS 284 eval_golden_item): ENABLE + FORCE,
--      eval_claim_label_cis_app_all and eval_claim_label_cis_owner_all (X1 runtime parity, CIS 244 / 245), and
--      tenant_isolation for aa_app_user (scope 'tenant' rows of the session's tenant; the tenant pool holds no
--      privilege: labels are admin data, the policy is the floor if one is ever granted).
--   4. Grants: REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (cis_owner's default privileges in
--      shared, CIS 245, would give cis_app UPDATE), then GRANT cis_app SELECT, INSERT, DELETE (the label importer and
--      the measurement harness write and read, the tenant erasure deletes). No UPDATE.
--   5. Register 388.
--
-- PII (DM-6.1). claim_text and reason carry tour text and, on T2 / T9 objects, the agency's own copy: tagged
-- pii:free_text like shared.eval_golden_item.label. No traveller data by construction. Never read by a tenant route,
-- never exported, never copied to a public repo (the label manifest in the root repo holds hashes and counts only).
-- Tenant erasure (AA-839, services/erasure/inventory.py): delete the tenant's rows.
--
-- Retention (DM-7.1). Proposed: kept while its label set version is the active one or a measurement record names it;
-- a superseded version is kept 12 months (an instrument's record must stay reproducible), then deleted by a future TTL
-- job kind (DRY RUN first). Row in root data standards Part B section 7, in the root PR of this change (merged before
-- the Infra copy). Until the TTL kind exists nothing is deleted; volume is a few hundred rows per set version.
--
-- Behaviour. None on apply: the table is empty and no code writes the new queue source yet. The code PR (after this
-- file is applied) adds the panel export / import (DRY RUN by default) and the measurement harnesses.
--
-- Class: contract (no '-- migrate:' directive). It changes a CHECK of an existing table
-- (writing_memory_disagreement_source_check) and the new table has a tenant_id column; MIG-4: this migration-only PR,
-- the Migration Apply run, then the code PR.
--
-- Rollback (a new forward migration, after the code is reverted): put the 314 CHECK back (after deleting any
-- 'golden_claim' queue rows) and DROP TABLE shared.eval_claim_label (a destructive file, DRY RUN). Nothing on a live
-- path reads either.
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of shared and
-- of shared.writing_memory_disagreement.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 1. shared.eval_claim_label ────────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared.eval_claim_label (
    label_id        uuid         NOT NULL DEFAULT gen_random_uuid(),
    created_at      timestamptz  NOT NULL DEFAULT now(),
    set_id          text         NOT NULL,
    set_version     text         NOT NULL,
    writer          text         NOT NULL,
    scope           text         NOT NULL,
    tenant_id       uuid,
    sample_id       text,
    piece_id        uuid,
    tour_id         uuid,
    version_id      uuid,
    content_sha256  text         NOT NULL,
    field           text         NOT NULL,
    span_start      integer      NOT NULL,
    span_end        integer      NOT NULL,
    claim_text      text         NOT NULL,
    claim_hash      text         NOT NULL,
    claim_class     text         NOT NULL,
    label           text         NOT NULL,
    labeller_kind   text         NOT NULL,
    labeller        text         NOT NULL,
    lens            text,
    reason          text,
    split           text         NOT NULL,
    stratum         text         NOT NULL DEFAULT 'representative',
    adjudication    text         NOT NULL,
    policy_sha      text,
    CONSTRAINT eval_claim_label_pkey PRIMARY KEY (label_id),
    CONSTRAINT eval_claim_label_judgement_key
        UNIQUE NULLS NOT DISTINCT (set_id, set_version, claim_hash, labeller_kind, lens),
    CONSTRAINT eval_claim_label_set_check CHECK (
        set_id ~ '^[A-Za-z0-9][A-Za-z0-9@._-]{0,31}$' AND set_version ~ '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'),
    CONSTRAINT eval_claim_label_writer_check CHECK (writer IN ('a1', 't2', 't9_blog', 't9_social')),
    CONSTRAINT eval_claim_label_scope_check CHECK (scope IN ('platform', 'tenant')),
    CONSTRAINT eval_claim_label_scope_tenant_ck CHECK (
        (scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT eval_claim_label_writer_scope_check CHECK ((writer = 'a1') = (scope = 'platform')),
    CONSTRAINT eval_claim_label_ref_check CHECK (
        (sample_id IS NOT NULL OR piece_id IS NOT NULL OR version_id IS NOT NULL)
        AND (sample_id IS NULL OR sample_id ~ '^[a-z0-9-]{1,40}$')),
    CONSTRAINT eval_claim_label_sha_check CHECK (
        content_sha256 ~ '^[0-9a-f]{64}$' AND claim_hash ~ '^[0-9a-f]{64}$'
        AND (policy_sha IS NULL OR policy_sha ~ '^[0-9a-f]{64}$')),
    CONSTRAINT eval_claim_label_field_check CHECK (field ~ '^[a-z][a-z0-9_.]{0,39}$'),
    -- the span indexes the field's text; claim_text is that span, so its length is the span's
    CONSTRAINT eval_claim_label_span_check CHECK (
        span_start >= 0 AND span_end > span_start AND char_length(claim_text) = span_end - span_start
        AND char_length(claim_text) <= 2000),
    CONSTRAINT eval_claim_label_class_check CHECK (claim_class ~ '^[a-z]+\.[a-z0-9_]{1,40}$'),
    CONSTRAINT eval_claim_label_label_check CHECK (label IN ('violation', 'ok', 'unsure')),
    CONSTRAINT eval_claim_label_labeller_check CHECK (
        labeller_kind IN ('agent_panel', 'tech_lead') AND char_length(labeller) BETWEEN 1 AND 128
        AND (lens IS NULL OR lens ~ '^[a-z_]{1,32}$')
        AND (labeller_kind = 'tech_lead' OR lens IS NOT NULL)),
    CONSTRAINT eval_claim_label_adjudication_check CHECK (
        adjudication IN ('agreed', 'disputed', 'audit', 'final')
        AND ((labeller_kind = 'tech_lead') = (adjudication = 'final'))),
    CONSTRAINT eval_claim_label_split_check CHECK (split IN ('train', 'held_out')),
    CONSTRAINT eval_claim_label_stratum_check CHECK (stratum IN ('hard', 'representative', 'mutants', 'traps')),
    CONSTRAINT eval_claim_label_reason_check CHECK (coalesce(char_length(reason), 0) <= 600)
);

CREATE INDEX IF NOT EXISTS eval_claim_label_set_class_idx
    ON shared.eval_claim_label (set_id, set_version, claim_class);
CREATE INDEX IF NOT EXISTS eval_claim_label_claim_idx ON shared.eval_claim_label (claim_hash);
CREATE INDEX IF NOT EXISTS eval_claim_label_tenant_idx ON shared.eval_claim_label (tenant_id) WHERE scope = 'tenant';
CREATE INDEX IF NOT EXISTS eval_claim_label_piece_idx ON shared.eval_claim_label (piece_id) WHERE piece_id IS NOT NULL;

COMMENT ON TABLE shared.eval_claim_label IS
    'AA-1048 (CIS 388, root ADR 0020 W2): claim-level ground truth. One row per judgement of one claim (a span of a '
    'stored object, named by id) under a policy class: one per lens of the agent panel, one per tech-lead '
    'adjudication. Grouped by label set and version (CL-1 / L2 / t2@2); a version never changes. Admin data: no '
    'tenant route reads it. Goes with the tenant (AA-839).';
COMMENT ON COLUMN shared.eval_claim_label.claim_text IS
    'pii:free_text; AA-1048 (388): the claim span of the field text (tour or agency copy). Never shown to a tenant, '
    'never exported, never copied to a public repo.';
COMMENT ON COLUMN shared.eval_claim_label.reason IS
    'pii:free_text; AA-1048 (388): the labeller''s reason (may quote the claim).';
COMMENT ON COLUMN shared.eval_claim_label.claim_hash IS
    'AA-1048 (388): sha256 hex of "<content_sha256>:<field>:<normalised span text>" '
    '(services/ground_truth/claims.py); the key of the panel export / import JSONL.';
COMMENT ON COLUMN shared.eval_claim_label.split IS
    'AA-1048 (388): train | held_out, frozen by a hash of the object''s group key (tour_id, else sample_id, '
    'piece_id or version_id, else content_sha256): every object of one tour on one side.';
COMMENT ON COLUMN shared.eval_claim_label.adjudication IS
    'AA-1048 (388): on panel rows the claim''s state after the panel (agreed | disputed | audit: drawn into the '
    'random 20% audit of agreed claims); final on a tech-lead row, which wins over the panel.';

ALTER TABLE shared.eval_claim_label ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.eval_claim_label FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS eval_claim_label_cis_app_all ON shared.eval_claim_label;
CREATE POLICY eval_claim_label_cis_app_all ON shared.eval_claim_label AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS eval_claim_label_cis_owner_all ON shared.eval_claim_label;
CREATE POLICY eval_claim_label_cis_owner_all ON shared.eval_claim_label AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON shared.eval_claim_label;
CREATE POLICY tenant_isolation ON shared.eval_claim_label AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.eval_claim_label IS
    'AA-1048 (CIS 388): own tenant rows only; the tenant pool holds no privilege (labels are admin data), the policy '
    'is the floor if one is ever granted.';

-- Narrow cis_owner's default privileges (CIS 245) before the grant: without the REVOKE cis_app could UPDATE a label.
REVOKE ALL ON shared.eval_claim_label FROM PUBLIC;
REVOKE ALL ON shared.eval_claim_label FROM cis_app, aa_app_user, catalog_owner;
GRANT SELECT, INSERT, DELETE ON shared.eval_claim_label TO cis_app;

-- 2. the 'golden_claim' source of the disagreement queue ──────────────────────────────────────────────────────────

ALTER TABLE shared.writing_memory_disagreement DROP CONSTRAINT IF EXISTS writing_memory_disagreement_source_check;
ALTER TABLE shared.writing_memory_disagreement ADD CONSTRAINT writing_memory_disagreement_source_check
    CHECK (source IN ('golden', 'piece_label', 'golden_claim'));
COMMENT ON CONSTRAINT writing_memory_disagreement_source_check ON shared.writing_memory_disagreement IS
    'CIS 314 (golden, piece_label); AA-1048 (388) golden_claim: a disputed or audit-drawn claim of '
    'shared.eval_claim_label (source_ref = its first panel row) for the tech lead.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('388', now(), 'AA-1048: shared.eval_claim_label + the golden_claim disagreement source')
ON CONFLICT (version) DO NOTHING;

COMMIT;
