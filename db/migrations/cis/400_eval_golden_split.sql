-- migrate: expand
-- Migration 400: AA-1051 (Quality W5 code part, root ADR 0020; S275 decision "code eval part first") — the frozen
-- DEV / CAL / GATE split of the golden set items.
--
-- Why. The Writing Lab evaluates writer changes on the golden set (shared.eval_golden_item, CIS 284). Its only split is
-- tune / holdout / trap (the R2 phases), so the same items serve rubric and policy work, judge calibration and release
-- decisions. The S271 writing-quality audit (data/design-review.json, Writing Lab redesign "golden v2") fixes three
-- disjoint uses by a hash of the sample: DEV (rubric and policy work), CAL (judge calibration) and GATE (sealed: release
-- and W5 proof decisions only). The S275 decision page put the split in its own migration before the W5 eval code.
-- A sample keeps its side across golden versions (the hash reads the sample id, stable across versions), and a stored
-- row is never rewritten: the readers (the R2 runner, the W5 proof runner) read the stored side, so a later change of
-- the rule in code cannot move an item between sides of an existing set version.
--
-- What.
--   1. shared.eval_golden_split: one row per golden item (set_id, sample_id), FK to shared.eval_golden_item
--      (set_id, sample_id) ON DELETE CASCADE (the item's erasure or a set's removal takes its split row).
--        eval_split   dev | cal | gate
--        rule         the assignment rule that placed it (services/writer_proof/splits.py RULE, e.g. aa1051-split-v1)
--        bucket       the sample's position in the hash space, 0 <= bucket < 1 (audit trail of the assignment)
--        assigned_by  who wrote it (golden_import:<who>, split_backfill:<who>)
--   2. Append only: a BEFORE UPDATE trigger refuses every UPDATE (shared.eval_golden_split_frozen; cis_owner's default
--      privileges, CIS 245, give cis_app UPDATE on new tables and an expand file cannot REVOKE). DELETE stays for the
--      erasure and the FK cascade.
--   3. RLS ENABLE + FORCE with the X1 runtime-parity policies (cis_app / cis_owner), like CIS 388 / 394. No tenant
--      column and no text: a row reaches its tenant through its golden item (FK), which the erasure walks.
--   4. GRANT cis_app SELECT, INSERT, DELETE. Register 400.
--
-- PII (DM-6.1). None: ids, a split name, a rule id, a number and an actor id (admin or job label). No free text.
--
-- Retention (DM-7.1). Proposed: follows its golden item (FK cascade; a superseded set version is kept while a
-- measurement record or a release names it). Row in root data standards Part B section 7, in the root PR of this
-- change (merged before the Infra copy).
--
-- Behaviour. None on apply: the table is empty. The code PR (W5 eval code) writes it at golden import and with a
-- backfill command (DRY RUN first) for the active set; until then a reader asked for a split refuses at $0 ("the set
-- has no split rows") and every other reader is unchanged.
--
-- Class: expand (root ADR 0017 d3): a new table with its constraints, index, RLS, policies, a new trigger function and
-- its trigger on the new table, grants on it and comments; the FK points from the new table at an existing one
-- (allowed: the internal RI triggers of a new table's FK). No existing object changes, no seed row, no DO block.
-- Migration-only PR first (lane decision S278), then the code PR ("chain: cis/400").
--
-- Number. 398 is the highest on main (12/11/2026).
--
-- Rollback (a new forward migration, after the code is reverted): DROP TABLE shared.eval_golden_split; DROP FUNCTION
-- shared.eval_golden_split_frozen() (a destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- shared and of shared.eval_golden_item (the FK target).

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 1. shared.eval_golden_split ─────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shared.eval_golden_split (
    set_id        uuid          NOT NULL,
    sample_id     text          NOT NULL,
    eval_split    text          NOT NULL,
    rule          text          NOT NULL,
    bucket        numeric(7,6)  NOT NULL,
    assigned_by   text          NOT NULL,
    assigned_at   timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT eval_golden_split_pkey PRIMARY KEY (set_id, sample_id),
    CONSTRAINT eval_golden_split_item_fk FOREIGN KEY (set_id, sample_id)
        REFERENCES shared.eval_golden_item (set_id, sample_id) ON DELETE CASCADE,
    CONSTRAINT eval_golden_split_split_check CHECK (eval_split IN ('dev', 'cal', 'gate')),
    CONSTRAINT eval_golden_split_rule_check CHECK (rule ~ '^[a-z0-9][a-z0-9_.:-]{0,39}$'),
    CONSTRAINT eval_golden_split_bucket_check CHECK (bucket >= 0 AND bucket < 1),
    CONSTRAINT eval_golden_split_by_check CHECK (char_length(assigned_by) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS eval_golden_split_set_split_idx ON shared.eval_golden_split (set_id, eval_split);

COMMENT ON TABLE shared.eval_golden_split IS
    'AA-1051 (CIS 400, root ADR 0020 W5): the frozen DEV / CAL / GATE side of each golden item (dev = rubric and '
    'policy work, cal = judge calibration, gate = sealed release and W5 proof decisions), placed by a hash of the '
    'sample id under a named rule. Append only; goes with its golden item (FK cascade; tenant erasure AA-839). No '
    'text, no tenant column. Admin data: no tenant route reads it.';
COMMENT ON COLUMN shared.eval_golden_split.rule IS
    'AA-1051 (400): the assignment rule (services/writer_proof/splits.py RULE); a new rule never rewrites a row.';
COMMENT ON COLUMN shared.eval_golden_split.bucket IS
    'AA-1051 (400): the sample''s position in the hash space of the rule, 0 <= bucket < 1.';

-- 2. append only ─────────────────────────────────────────────────────────────────────────────────────────────────

CREATE FUNCTION shared.eval_golden_split_frozen() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'shared.eval_golden_split is append-only: UPDATE refused (AA-1051)' USING ERRCODE = '42501';
END;
$$;
COMMENT ON FUNCTION shared.eval_golden_split_frozen() IS
    'AA-1051 (CIS 400): refuses UPDATE on shared.eval_golden_split (a split side is frozen once written).';

CREATE TRIGGER eval_golden_split_frozen BEFORE UPDATE ON shared.eval_golden_split
    FOR EACH ROW EXECUTE FUNCTION shared.eval_golden_split_frozen();

-- 3. RLS ───────────────────────────────────────────────────────────────────────────────────────────────────────────

ALTER TABLE shared.eval_golden_split ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.eval_golden_split FORCE ROW LEVEL SECURITY;
CREATE POLICY eval_golden_split_cis_app_all ON shared.eval_golden_split AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY eval_golden_split_cis_owner_all ON shared.eval_golden_split AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);

-- 4. grants ────────────────────────────────────────────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT, DELETE ON shared.eval_golden_split TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('400', now(), 'AA-1051: shared.eval_golden_split (frozen DEV / CAL / GATE side of each golden item)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
