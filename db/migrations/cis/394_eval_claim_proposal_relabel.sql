-- migrate: expand
-- Migration 394: AA-1063 (Writing Lab claim ground truth in the admin; Quality W2, root ADR 0020) — the agent's
-- proposal for a golden_claim queue item, and the tech lead's later corrections of a final claim label.
--
-- Why. The tech lead adjudicates the W2 claim labels (shared.eval_claim_label, CIS 388) in the disagreement queue
-- (shared.writing_memory_disagreement, source golden_claim). In S275 the 284 items were reviewed on a temporary page
-- that held an agent's proposal per item (a label and a plain-language reason); the proposals lived in that page only.
-- The Writing Lab review view (api/routers/admin_claim_labels.py, frontend Writing memory › Claim labels) reads them
-- from the DB, and an import endpoint loads the proposals an agent panel makes. The tech lead also asked (S275) that
-- "labels must be viewable and correctable later": a final label can be changed from the label set browser, append
-- only, with its history kept. shared.eval_claim_label allows one tech-lead row per claim and set version (its
-- judgement key) and no UPDATE, so a correction is a row of its own here.
--
-- What.
--   1. shared.eval_claim_proposal: one row per (queue item, agent run). item_id names the queue item
--      (shared.writing_memory_disagreement.item_id, FK ON DELETE CASCADE: the item's erasure takes its proposals);
--      label (violation | ok | unsure), reason_en / reason_vi (one or two plain-language lines, at least one),
--      bad_part (the unsupported part of the sentence, highlighted in the view), confidence (high | medium | low),
--      run_id (the agent run that made it), notes (jsonb object of optional plain-language extras: the sentence in
--      Vietnamese, what the source says, the doubt; <= 8 KiB), imported_by (admin:<id>). A re-import of the same run is
--      a no-op (unique item + run); the view reads the newest proposal of an item.
--   2. shared.eval_claim_relabel: one row per correction of a claim's final label in a label set version. anchor
--      label_id = a row of the claim in shared.eval_claim_label (FK ON DELETE CASCADE: the claim's erasure takes its
--      corrections); set_id / set_version / claim_hash name the claim; claim_class + label the new label; reason (why,
--      required); labeller (admin:<id>); previous_label / previous_class / previous_source (what it replaced: a
--      tech-lead row, the agreed panel or an earlier correction); supersedes = the correction it replaces (NULL for the
--      first one). One correction may supersede a given one (unique set + claim + supersedes, NULLS NOT DISTINCT), so
--      the history is a single chain and a stale second click is refused. The newest correction is the claim's final
--      label (services/ground_truth/review.py effective_rows; the report and finals routes read it).
--   3. Both tables append only: a BEFORE UPDATE trigger refuses every UPDATE (shared.eval_claim_review_append_only;
--      cis_owner's default privileges, CIS 245, give cis_app UPDATE on new tables and an expand file cannot REVOKE).
--      DELETE stays for the erasure and the TTL.
--   4. RLS ENABLE + FORCE with the X1 runtime-parity policies (cis_app / cis_owner), like CIS 388. No tenant column:
--      a row reaches its tenant through its FK (the queue item, the claim label), which the erasure walks.
--   5. GRANT cis_app SELECT, INSERT, DELETE. Register 394.
--
-- PII (DM-6.1). reason_en / reason_vi / bad_part / notes / reason may quote the sentence (tour text or, on T2 / T9
-- objects, the agency's own copy): tagged pii:free_text like shared.eval_claim_label.reason. No traveller data. Never
-- read by a tenant route, never exported.
--
-- Retention (DM-7.1). Proposed: a proposal follows its queue item and a correction its label set version (kept while
-- the version is active or a measurement record names it; a superseded version 12 months), both deleted with them
-- (FK cascade) or by a future TTL kind (DRY RUN first). Rows in root data standards Part B section 7, in the root PR
-- of this change (merged before the Infra copy).
--
-- Behaviour. None on apply: both tables are empty. Before this file is applied the new routes answer 503
-- `unavailable` and the report / finals routes read no corrections (the effective rows are the label rows).
--
-- Class: expand (root ADR 0017 d3): two new tables with their constraints, indexes, RLS, policies, a new trigger
-- function and its triggers on the new tables, grants on them and comments; the FKs point from the new tables at
-- existing ones (allowed: the internal RI triggers of a new table's FK). No existing object changes, no seed row, no
-- DO block. Ships in the code PR (ADR 0017 d1).
--
-- Number. 393 is the highest on main (10/11/2026).
--
-- Rollback (a new forward migration, after the code is reverted): DROP TABLE shared.eval_claim_relabel,
-- shared.eval_claim_proposal; DROP FUNCTION shared.eval_claim_review_append_only() (a destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- shared, of shared.writing_memory_disagreement and of shared.eval_claim_label (the FK targets).

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 1. shared.eval_claim_proposal ─────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared.eval_claim_proposal (
    proposal_id   uuid         NOT NULL DEFAULT gen_random_uuid(),
    created_at    timestamptz  NOT NULL DEFAULT now(),
    item_id       uuid         NOT NULL,
    run_id        text         NOT NULL,
    label         text         NOT NULL,
    reason_en     text,
    reason_vi     text,
    bad_part      text,
    confidence    text,
    notes         jsonb        NOT NULL DEFAULT '{}'::jsonb,
    imported_by   text         NOT NULL,
    CONSTRAINT eval_claim_proposal_pkey PRIMARY KEY (proposal_id),
    CONSTRAINT eval_claim_proposal_item_fk FOREIGN KEY (item_id)
        REFERENCES shared.writing_memory_disagreement (item_id) ON DELETE CASCADE,
    CONSTRAINT eval_claim_proposal_run_key UNIQUE (item_id, run_id),
    CONSTRAINT eval_claim_proposal_run_check CHECK (run_id ~ '^[A-Za-z0-9][A-Za-z0-9:@._-]{0,63}$'),
    CONSTRAINT eval_claim_proposal_label_check CHECK (label IN ('violation', 'ok', 'unsure')),
    CONSTRAINT eval_claim_proposal_reason_check CHECK (
        (reason_en IS NOT NULL OR reason_vi IS NOT NULL)
        AND coalesce(char_length(reason_en), 0) <= 600 AND coalesce(char_length(reason_vi), 0) <= 600
        AND coalesce(char_length(bad_part), 0) <= 600),
    CONSTRAINT eval_claim_proposal_confidence_check CHECK (confidence IS NULL OR confidence IN ('high', 'medium', 'low')),
    CONSTRAINT eval_claim_proposal_notes_check CHECK (
        jsonb_typeof(notes) = 'object' AND pg_column_size(notes) <= 8192),
    CONSTRAINT eval_claim_proposal_by_check CHECK (char_length(imported_by) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS eval_claim_proposal_item_idx ON shared.eval_claim_proposal (item_id, created_at DESC);

COMMENT ON TABLE shared.eval_claim_proposal IS
    'AA-1063 (CIS 394, root ADR 0020 W2): an agent''s proposal for a golden_claim item of the disagreement queue '
    '(label, plain-language reason in English and / or Vietnamese, the unsupported part, confidence, the agent run). '
    'One row per item and run, append only; the Writing Lab review view shows the newest. Goes with its queue item '
    '(FK cascade; tenant erasure AA-839). Admin data: no tenant route reads it.';
COMMENT ON COLUMN shared.eval_claim_proposal.reason_en IS
    'pii:free_text; AA-1063 (394): the proposal''s plain-language reason in English (may quote the sentence).';
COMMENT ON COLUMN shared.eval_claim_proposal.reason_vi IS
    'pii:free_text; AA-1063 (394): the proposal''s plain-language reason in Vietnamese (may quote the sentence).';
COMMENT ON COLUMN shared.eval_claim_proposal.bad_part IS
    'pii:free_text; AA-1063 (394): the part of the sentence the source does not support (a substring of the claim).';
COMMENT ON COLUMN shared.eval_claim_proposal.notes IS
    'pii:free_text; AA-1063 (394): optional plain-language extras (claim_vi, source_says_en / _vi, doubt_en / _vi).';

-- 2. shared.eval_claim_relabel ─────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared.eval_claim_relabel (
    relabel_id        uuid         NOT NULL DEFAULT gen_random_uuid(),
    created_at        timestamptz  NOT NULL DEFAULT clock_timestamp(),
    set_id            text         NOT NULL,
    set_version       text         NOT NULL,
    claim_hash        text         NOT NULL,
    anchor_label_id   uuid         NOT NULL,
    claim_class       text         NOT NULL,
    label             text         NOT NULL,
    reason            text         NOT NULL,
    labeller          text         NOT NULL,
    supersedes        uuid,
    previous_label    text         NOT NULL,
    previous_class    text         NOT NULL,
    previous_source   text         NOT NULL,
    CONSTRAINT eval_claim_relabel_pkey PRIMARY KEY (relabel_id),
    CONSTRAINT eval_claim_relabel_anchor_fk FOREIGN KEY (anchor_label_id)
        REFERENCES shared.eval_claim_label (label_id) ON DELETE CASCADE,
    CONSTRAINT eval_claim_relabel_chain_key
        UNIQUE NULLS NOT DISTINCT (set_id, set_version, claim_hash, supersedes),
    CONSTRAINT eval_claim_relabel_set_check CHECK (
        set_id ~ '^[A-Za-z0-9][A-Za-z0-9@._-]{0,31}$' AND set_version ~ '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'),
    CONSTRAINT eval_claim_relabel_hash_check CHECK (claim_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT eval_claim_relabel_class_check CHECK (
        claim_class ~ '^[a-z]+\.[a-z0-9_]{1,40}$' AND previous_class ~ '^([a-z]+\.[a-z0-9_]{1,40})?$'),
    CONSTRAINT eval_claim_relabel_label_check CHECK (
        label IN ('violation', 'ok', 'unsure') AND previous_label IN ('violation', 'ok', 'unsure')),
    CONSTRAINT eval_claim_relabel_source_check CHECK (previous_source IN ('tech_lead', 'panel_agreed', 'relabel')),
    CONSTRAINT eval_claim_relabel_reason_check CHECK (char_length(reason) BETWEEN 3 AND 600),
    CONSTRAINT eval_claim_relabel_by_check CHECK (char_length(labeller) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS eval_claim_relabel_claim_idx
    ON shared.eval_claim_relabel (set_id, set_version, claim_hash, created_at);
CREATE INDEX IF NOT EXISTS eval_claim_relabel_anchor_idx ON shared.eval_claim_relabel (anchor_label_id);

COMMENT ON TABLE shared.eval_claim_relabel IS
    'AA-1063 (CIS 394, root ADR 0020 W2): a tech lead''s correction of a claim''s final label in a label set version '
    '(shared.eval_claim_label keeps one tech-lead row per claim and no UPDATE). Append only, one chain per claim '
    '(supersedes); the newest is the final label the report and finals read. Goes with its anchor label row (FK '
    'cascade; tenant erasure AA-839). Admin data: no tenant route reads it.';
COMMENT ON COLUMN shared.eval_claim_relabel.reason IS
    'pii:free_text; AA-1063 (394): why the label was changed (may quote the claim).';
COMMENT ON COLUMN shared.eval_claim_relabel.supersedes IS
    'AA-1063 (394): the correction this one replaces; NULL = the first correction (it replaces the tech-lead row or '
    'the agreed panel label).';

-- 3. append only ─────────────────────────────────────────────────────────────────────────────────────────────────

CREATE FUNCTION shared.eval_claim_review_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: UPDATE refused (AA-1063)', TG_TABLE_NAME USING ERRCODE = '42501';
END;
$$;
COMMENT ON FUNCTION shared.eval_claim_review_append_only() IS
    'AA-1063 (CIS 394): refuses UPDATE on shared.eval_claim_proposal and shared.eval_claim_relabel (append only).';

CREATE TRIGGER eval_claim_proposal_append_only BEFORE UPDATE ON shared.eval_claim_proposal
    FOR EACH ROW EXECUTE FUNCTION shared.eval_claim_review_append_only();
CREATE TRIGGER eval_claim_relabel_append_only BEFORE UPDATE ON shared.eval_claim_relabel
    FOR EACH ROW EXECUTE FUNCTION shared.eval_claim_review_append_only();

-- 4. RLS ───────────────────────────────────────────────────────────────────────────────────────────────────────────

ALTER TABLE shared.eval_claim_proposal ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.eval_claim_proposal FORCE ROW LEVEL SECURITY;
CREATE POLICY eval_claim_proposal_cis_app_all ON shared.eval_claim_proposal AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY eval_claim_proposal_cis_owner_all ON shared.eval_claim_proposal AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);

ALTER TABLE shared.eval_claim_relabel ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.eval_claim_relabel FORCE ROW LEVEL SECURITY;
CREATE POLICY eval_claim_relabel_cis_app_all ON shared.eval_claim_relabel AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY eval_claim_relabel_cis_owner_all ON shared.eval_claim_relabel AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);

-- 5. grants ────────────────────────────────────────────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT, DELETE ON shared.eval_claim_proposal TO cis_app;
GRANT SELECT, INSERT, DELETE ON shared.eval_claim_relabel TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('394', now(), 'AA-1063: shared.eval_claim_proposal + shared.eval_claim_relabel (claim review in the admin)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
