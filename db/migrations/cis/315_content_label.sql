-- migrate: expand
-- Migration 315: AA-923 (WM-32) — acp_shared.content_label: the human label of a T2 tour version or an A1 (S1)
-- rewrite, next to the T9 piece labels of acp_shared.content_piece_label (CIS 231).
--
-- Why. S245 writing-learning-loop audit, Group 9: the soft-stop KPIs (minutes_to_fix, light-edit share; AA-922) and
-- the judge / human disagreement queue exist only for T9, because content_piece_label (primary key (piece_id,
-- labelled_by), FK to content_piece) cannot hold a T2 version or an A1 rewrite. A sibling table with the same CHECKs
-- keeps every existing T9 label and its readers exactly as they are (changing 231's key would be a contract change on
-- a live table).
--
-- What. One new table in acp_shared:
--   acp_shared.content_label: subject_type t2_version | a1_content and subject_id (the id of
--   gold_aa_internal.tenant_tour_versions / silver_aa_internal.generated_content; no FK: tenant_tour_versions is a
--   live-only table absent from the CI replay, and the erasure keys the rows on tenant_id below); tenant_id (the
--   subject's tenant at label time: the platform tenant for Master Content, the agency for a T2 version; the AA-839
--   erasure key); labelled_by (`admin:<admin_users.id>`), label as_is | light | heavy | reject, defects (object;
--   keys and levels validated by the API, AA-783 criteria pack), minutes_to_fix 0..600, reason <= 4000 characters,
--   content_sha256 (sha256 of the labelled text: a later edit shows as "changed since label"), labelled_at.
--   One row per (subject_type, subject_id, labelled_by): a second save overwrites the labeller's own row (same rule
--   as 231; two labellers = agreement).
--   Admin-only data: written and read only by /admin/content-quality (staff role admin). RLS ENABLE + FORCE with the
--   X1 parity policies <t>_cis_app_all / <t>_cis_owner_all and tenant_isolation TO aa_app_user (rule a of the RLS
--   catalogue; the tenant pool holds no privilege: tenants never see labels).
--   Grants: cis_app SELECT, INSERT, UPDATE, DELETE (DELETE: the AA-839 erasure). Nothing for aa_app_user.
--
-- Class: expand (root ADR 0017 d3): one new table with its indexes, RLS flags, policies, grants and comments; no change
-- to any existing object, no DO block, no REVOKE. Auto-applied on Dev by the AA-CIS-Infra migration-apply pipeline
-- after the app PR merges, before Deploy Dev's schema gate lets the code roll (readiness.REQUIRED_CIS_SCHEMA = 315 in
-- the same PR).
--
-- Number. 312 is the highest on main; 313 (AA-921) and 314 (AA-922) are stacked before this file (S260). Renumber at
-- merge to main max + 1 if main moved (file name, this header, the registration below, readiness, tests,
-- CONTEXT.md).
--
-- Rollback (a new forward migration, after the code that reads it is reverted): DROP TABLE acp_shared.content_label;
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema
-- acp_shared, which then owns the table.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE acp_shared.content_label (
    subject_type    text NOT NULL,
    subject_id      uuid NOT NULL,
    tenant_id       uuid NOT NULL,
    labelled_by     text NOT NULL,
    label           text NOT NULL,
    defects         jsonb NOT NULL DEFAULT '{}'::jsonb,
    minutes_to_fix  smallint,
    reason          text,
    content_sha256  text,
    labelled_at     timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT content_label_pkey PRIMARY KEY (subject_type, subject_id, labelled_by),
    CONSTRAINT content_label_subject_type_check CHECK (subject_type IN ('t2_version', 'a1_content')),
    CONSTRAINT content_label_labelled_by_check CHECK (length(btrim(labelled_by)) BETWEEN 1 AND 128),
    CONSTRAINT content_label_label_check CHECK (label IN ('as_is', 'light', 'heavy', 'reject')),
    CONSTRAINT content_label_defects_check CHECK (jsonb_typeof(defects) = 'object'),
    CONSTRAINT content_label_minutes_to_fix_check
        CHECK (minutes_to_fix IS NULL OR minutes_to_fix BETWEEN 0 AND 600),
    CONSTRAINT content_label_reason_check CHECK (reason IS NULL OR length(reason) <= 4000),
    CONSTRAINT content_label_content_sha256_check CHECK (content_sha256 IS NULL OR content_sha256 ~ '^[0-9a-f]{64}$')
);
CREATE INDEX content_label_label_idx ON acp_shared.content_label (subject_type, label, labelled_at DESC);
CREATE INDEX content_label_tenant_idx ON acp_shared.content_label (tenant_id);

COMMENT ON TABLE acp_shared.content_label IS
    'AA-923 WM-32 (CIS 315): human verdict on one T2 tour version or one A1 (S1) rewrite per labeller (AA-783 '
    'criteria, same shape as content_piece_label for T9). Admin-only (Content Quality); never in a tenant projection. '
    'Goes with the tenant (AA-839 erasure, tenant_id).';
COMMENT ON COLUMN acp_shared.content_label.subject_id IS
    'AA-923 (315): gold_aa_internal.tenant_tour_versions.id (t2_version) or silver_aa_internal.generated_content.id '
    '(a1_content); no FK (tenant_tour_versions is absent from the CI replay).';
COMMENT ON COLUMN acp_shared.content_label.tenant_id IS
    'AA-923 (315): the subject''s tenant at label time (platform tenant for Master Content); the erasure key.';
COMMENT ON COLUMN acp_shared.content_label.defects IS
    'AA-923 (315): {"fact"|"voice"|"format"|"ai_phrasing": "none"|"light"|"heavy"}; keys optional (API-validated).';
COMMENT ON COLUMN acp_shared.content_label.content_sha256 IS
    'AA-923 (315): sha256 of the labelled text (T2: rewritten_content::text; A1: the rewrite fields joined); differs '
    'once the text is edited.';

ALTER TABLE acp_shared.content_label ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.content_label FORCE ROW LEVEL SECURITY;

CREATE POLICY content_label_cis_app_all ON acp_shared.content_label AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
CREATE POLICY content_label_cis_owner_all ON acp_shared.content_label AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
CREATE POLICY tenant_isolation ON acp_shared.content_label AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON acp_shared.content_label IS
    'AA-923 (CIS 315): own tenant rows only; the tenant pool holds no privilege (labels are admin data), the policy '
    'is the floor if one is ever granted.';

GRANT SELECT, INSERT, UPDATE, DELETE ON acp_shared.content_label TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('315', now(), 'AA-923: acp_shared.content_label (human labels on T2 versions and A1 rewrites)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
