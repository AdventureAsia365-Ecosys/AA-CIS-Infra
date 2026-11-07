-- Migration 386: AA-1047 (Quality W1, root ADR 0020 "Four sources of truth") — the persisted FactSheet, and the
-- fs_id that ties an S1 Master version and a T2 tenant version to the FactSheet it was written from.
--
-- Why. ADR 0020: "Every consumer reads the FactSheet by fs_sha" (audit invariant 2). The FactSheet module
-- (services/quality/factsheet.py: a tour builder for S1 / T2 and a route builder for T9) builds one typed sheet per
-- write, each line with its id, kind, provenance (source_raw, human_verified, tenant_asserted, llm_derived,
-- external), its pointer into the source and its anchor flag, plus what the sheet left out and why. Today nothing
-- keeps it: a stored Master, a tenant version or a blog cannot say which facts its writer and its checks saw, so a
-- replay, the claim engine (W2) and the REPORT-mode final_contract each rebuild "the source" their own way. The audit
-- (root docs/audits/2026-11-06-S271-writing-quality-audit/, README W1, data/design-review.json arch.roadmap[1]) asks
-- for "a CIS table + fs_id on generated_content, content_piece.writer_input and tenant_tour_versions".
--
-- What.
--   1. acp_shared.fact_sheet: one row per distinct FactSheet of a tenant and workflow (the writer code stores a sheet
--      once and reuses the row when the same inputs give the same fs_sha: UNIQUE (tenant_id, workflow, fs_sha)).
--      Columns: workflow (s1 | t2 | t9), builder (tour | route), schema_version / builder_version (the module's
--      SCHEMA / BUILDER_VERSION), fs_sha (sha256 hex of the canonical record + rendered text), tour_id (the raw_tours
--      tour of a tour sheet, the trip's tour of a route sheet when known), counts (lines, exclusions, pointer
--      failures), lines / excluded / pointer_failures / meta (jsonb, the module's FactSheet.record()) and render_text
--      (what the writer and the checks read). No foreign key: the owning objects (Master versions, tenant versions,
--      pieces) are pruned and erased on their own windows, and a sheet outlives none of them by design.
--   2. silver_aa_internal.generated_content.fs_id and gold_aa_internal.tenant_tour_versions.fs_id (uuid, NULL until
--      the writer code stamps them; no default, so the ADD COLUMN rewrites nothing). A T9 piece keeps its fs_id in
--      acp_shared.content_piece.writer_input (jsonb, key fs_id): no DDL there.
--   3. RLS like the neighbouring acp_shared tables (CIS 360): ENABLE + FORCE, <table>_cis_app_all and
--      <table>_cis_owner_all (X1 runtime parity, CIS 244 / 245), and tenant_isolation for aa_app_user (the tenant pool
--      holds no privilege: a FactSheet is admin data; the policy is the floor if one is ever granted).
--   4. Grants: REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (cis_owner's default privileges in
--      acp_shared would give cis_app UPDATE), then GRANT cis_app SELECT, INSERT, DELETE (the writers insert, replay
--      and the measurement read, the tenant erasure deletes). No UPDATE: a sheet never changes; a new input is a new
--      fs_sha and a new row.
--   5. Register 386.
--
-- PII (DM-6.1). lines and render_text carry tour text and, on a T2 / T9 sheet, the agency's own facts, brand and
-- audience lines: tenant content, tagged pii:free_text like shared.llm_cassette.reply_text. No traveller data by
-- construction (the inputs hold none). Never read by a tenant route, never exported. Tenant erasure (AA-839,
-- services/erasure/inventory.py): delete the tenant's rows.
--
-- Retention (DM-7.1). Proposed: kept while an object that names it exists; a row no generated_content /
-- tenant_tour_versions / content_piece references, older than 90 days, is pruned by a future TTL job kind
-- (retention_fact_sheet, DRY RUN first). Row in root data standards Part B section 7, in the root PR of this change
-- (merged before the Infra copy). Until the TTL kind exists nothing is deleted; Dev volume is about one row per
-- write (a few KB, TOAST-compressed).
--
-- Behaviour. None on apply: the table is empty and the two columns are NULL. The code PR (after this file is applied)
-- writes a sheet best-effort per S1 / T2 / T9 write and stamps fs_id; a failed write is logged and the write goes on.
--
-- Class: contract (no '-- migrate:' directive). It ALTERs two existing tables (ADD COLUMN) and the new table has a
-- tenant_id column; MIG-4: this migration-only PR, the Migration Apply run, then the code PR.
--
-- Rollback (a new forward migration, after the code is reverted): ALTER TABLE … DROP COLUMN fs_id on both tables and
-- DROP TABLE acp_shared.fact_sheet (a destructive file, DRY RUN). Nothing on a live path reads them.
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of acp_shared,
-- silver_aa_internal.generated_content and gold_aa_internal.tenant_tour_versions.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 1. acp_shared.fact_sheet ──────────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS acp_shared.fact_sheet (
    fs_id                  uuid         NOT NULL DEFAULT gen_random_uuid(),
    created_at             timestamptz  NOT NULL DEFAULT now(),
    tenant_id              uuid         NOT NULL,
    workflow               text         NOT NULL,
    builder                text         NOT NULL,
    schema_version         text         NOT NULL,
    builder_version        text         NOT NULL,
    fs_sha                 text         NOT NULL,
    tour_id                uuid,
    line_count             integer      NOT NULL,
    excluded_count         integer      NOT NULL DEFAULT 0,
    pointer_failure_count  integer      NOT NULL DEFAULT 0,
    lines                  jsonb        NOT NULL,
    excluded               jsonb        NOT NULL DEFAULT '[]'::jsonb,
    pointer_failures       jsonb        NOT NULL DEFAULT '[]'::jsonb,
    meta                   jsonb        NOT NULL DEFAULT '{}'::jsonb,
    render_text            text         NOT NULL,
    CONSTRAINT fact_sheet_pkey PRIMARY KEY (fs_id),
    CONSTRAINT fact_sheet_sha_key UNIQUE (tenant_id, workflow, fs_sha),
    CONSTRAINT fact_sheet_workflow_check CHECK (workflow IN ('s1', 't2', 't9')),
    CONSTRAINT fact_sheet_builder_check CHECK (builder IN ('tour', 'route')),
    CONSTRAINT fact_sheet_sha_check CHECK (fs_sha ~ '^[0-9a-f]{64}$'),
    CONSTRAINT fact_sheet_version_check CHECK (
        length(schema_version) BETWEEN 1 AND 64 AND length(builder_version) BETWEEN 1 AND 64),
    CONSTRAINT fact_sheet_counts_check CHECK (
        line_count >= 0 AND excluded_count >= 0 AND pointer_failure_count >= 0),
    CONSTRAINT fact_sheet_shape_check CHECK (
        jsonb_typeof(lines) = 'array' AND jsonb_typeof(excluded) = 'array'
        AND jsonb_typeof(pointer_failures) = 'array' AND jsonb_typeof(meta) = 'object'),
    -- 1 MiB of UTF-8 for the rendered text (the largest T9 seed today is a few tens of KB).
    CONSTRAINT fact_sheet_text_cap_check CHECK (octet_length(render_text) <= 1048576)
);

CREATE INDEX IF NOT EXISTS fact_sheet_tenant_idx ON acp_shared.fact_sheet (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS fact_sheet_tour_idx ON acp_shared.fact_sheet (tour_id) WHERE tour_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS fact_sheet_created_idx ON acp_shared.fact_sheet (created_at, fs_id);

COMMENT ON TABLE acp_shared.fact_sheet IS
    'AA-1047 (CIS 386, root ADR 0020): one FactSheet per distinct input of a tenant and workflow (s1 / t2 / t9), as '
    'services/quality/factsheet.py builds it: typed lines with id, kind, provenance, pointer and anchor, the recorded '
    'exclusions and the rendered text. Named by generated_content.fs_id, tenant_tour_versions.fs_id and '
    'content_piece.writer_input->>''fs_id''. Admin data: no tenant route reads it. Goes with the tenant (AA-839).';
COMMENT ON COLUMN acp_shared.fact_sheet.fs_sha IS
    'AA-1047 (386): sha256 hex of the canonical JSON of FactSheet.record() plus the rendered text (FactSheet.sha()). '
    'The same inputs give the same sha, and the writer reuses the row.';
COMMENT ON COLUMN acp_shared.fact_sheet.lines IS
    'pii:free_text; AA-1047 (386): [{id, kind, text, provenance, anchored?, field?, quote?, ref?, block?, place?}] '
    '(tour text; agency facts, brand and audience lines on t2 / t9 sheets). Never shown to a tenant, never exported.';
COMMENT ON COLUMN acp_shared.fact_sheet.render_text IS
    'pii:free_text; AA-1047 (386): FactSheet.render(), the text the writer and the checks read (byte-equal to the '
    'pre-W1 builders). Never shown to a tenant, never exported.';
COMMENT ON COLUMN acp_shared.fact_sheet.excluded IS
    'AA-1047 (386): what the inputs offered and the sheet left out, each {id, kind, reason, chars, scope?}: '
    'facts_budget (T9 facts budget), figures_cap (S1 figures list).';
COMMENT ON COLUMN acp_shared.fact_sheet.pointer_failures IS
    'AA-1047 (386): s1_facts.verify_pointers of a tour sheet ({section, value, field}); [] is the W1 bar.';

ALTER TABLE acp_shared.fact_sheet ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.fact_sheet FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fact_sheet_cis_app_all ON acp_shared.fact_sheet;
CREATE POLICY fact_sheet_cis_app_all ON acp_shared.fact_sheet AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS fact_sheet_cis_owner_all ON acp_shared.fact_sheet;
CREATE POLICY fact_sheet_cis_owner_all ON acp_shared.fact_sheet AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON acp_shared.fact_sheet;
CREATE POLICY tenant_isolation ON acp_shared.fact_sheet AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON acp_shared.fact_sheet IS
    'AA-1047 (CIS 386): own tenant rows only; the tenant pool holds no privilege (a FactSheet is admin data), the '
    'policy is the floor if one is ever granted.';

-- Narrow cis_owner's default privileges before the grant: without the REVOKE cis_app could UPDATE a sheet.
REVOKE ALL ON acp_shared.fact_sheet FROM PUBLIC;
REVOKE ALL ON acp_shared.fact_sheet FROM cis_app, aa_app_user, catalog_owner;
GRANT SELECT, INSERT, DELETE ON acp_shared.fact_sheet TO cis_app;

-- 2. fs_id on the S1 Master versions and the T2 tenant versions ───────────────────────────────────────────────────

ALTER TABLE silver_aa_internal.generated_content ADD COLUMN IF NOT EXISTS fs_id uuid;
COMMENT ON COLUMN silver_aa_internal.generated_content.fs_id IS
    'AA-1047 (386): the acp_shared.fact_sheet row (tour builder) the S1 writer of this version read; NULL before W1 '
    'or when the best-effort write failed. No FK (the sheet store is pruned on its own window).';

-- tenant_tour_versions is created by CIS 001, which the CI test replay skips (tests/integration/_replay_guard.py:
-- 297 and 300 fail there for that reason). Here the column is added only when the table exists, so the replay
-- still creates acp_shared.fact_sheet for the integration tests; on Dev the table exists and the live step checks
-- the column.
DO $$
BEGIN
    IF to_regclass('gold_aa_internal.tenant_tour_versions') IS NULL THEN
        RAISE NOTICE 'migration 386: gold_aa_internal.tenant_tour_versions is missing (CIS 001); fs_id not added';
    ELSE
        ALTER TABLE gold_aa_internal.tenant_tour_versions ADD COLUMN IF NOT EXISTS fs_id uuid;
        COMMENT ON COLUMN gold_aa_internal.tenant_tour_versions.fs_id IS
            'AA-1047 (386): the acp_shared.fact_sheet row (tour builder, raw source of the tour) of this T2 version; '
            'NULL before W1, for a tenant edit, or when the best-effort write failed. No FK. Admin data, never shown '
            'to a tenant: the tenant pool''s table-level grant covers this column, so the tenant read projection '
            '(TENANT_HIDDEN_VERSION_FIELDS) is what hides it.';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('386', now(), 'AA-1047: acp_shared.fact_sheet + fs_id on generated_content and tenant_tour_versions')
ON CONFLICT (version) DO NOTHING;

COMMIT;
