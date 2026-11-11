-- Migration 398: AA-1049 (tech lead decision S277, 11/11/2026; root ADR 0020 D8) — a Master switched off by the
-- elephant-riding policy records its own reason, 'policy_hold'.
--
-- Why. The business owner policy (08/10/2026) keeps a tour whose product offers elephant riding as it is and sends it
-- to a human review. Since S271 S1 never auto-publishes such a version, but Masters written before the detector are on
-- sale with no review, and tech lead decision S277 says a Master that offers elephant riding must not be on sale until
-- a person reviews it: it goes to the Review Queue and only an approval puts it back on sale. The tour lifecycle
-- service (services/tour_lifecycle, ADR 0015 decision 2) switches such a Master off with master_status 'inactive' and
-- needs a reason of its own, so that only the Review Queue approval lifts it (not Set Active, not a source restore or
-- set-active, which re-enable only their own reasons) and the hold is counted and told apart from a staff deactivation.
--
-- What.
--   1. gold_aa_internal.published_tours_master_status_reason_check (CIS 272) gains 'policy_hold':
--        staff_deactivated  staff_trashed  source_deleted  superseded  (272)
--        policy_hold        the lifecycle service held the Master for the elephant-riding policy review (398)
--      NULL stays "active, or switched off before 272". The constraint is dropped and re-added in one transaction
--      (the ~1,070 rows are re-checked: every stored value is one of the 272 values, a subset).
--   2. The column comment names the new value.
--   3. Register 398.
--
-- Behaviour on apply. No row changes. Until the code PR deploys nothing writes 'policy_hold'; after it, the hold
-- script (scripts/quality/hold_elephant_masters.py, DRY RUN then APPLY with the pin) and the publish / activate guard
-- write it. The code that writes it must deploy after this file (lesson: a value written into a CHECK column must be
-- in the CHECK before that code deploys).
--
-- Class: contract (root ADR 0017 decision 3; no '-- migrate:' directive line): it replaces a CHECK constraint on an
-- existing table. MIG-4: this migration-only PR, applied on Dev by Infra Migration Apply when every job table is idle
-- (ADR 0017a), then the code PR that raises readiness to 398. No new table, so no new DM-7.1 retention row.
--
-- PII (DM-6.1). None: a reason code.
--
-- Guards (RAISE rolls the whole file back): before — 272 registered, the column present (nullable text) and every
-- stored reason one of the 272 values. After — the constraint exists and is validated, accepts each of the five
-- values and NULL, and refuses an unknown value (probed on one row inside a sub-transaction that is rolled back; no
-- probe when the table is empty).
--
-- Number. 397 is the highest number taken in this wave (CIS main is at 396 on 11/11; 397 is taken by another lane
-- of S277), so 398. If main moves, renumber to main max + 1: the file name, this header, the registration
-- below, tests/integration/test_aa1049_migration_398.py, the code PR (api/core/readiness.py,
-- tests/unit/test_aa884_health.py, services/tour_lifecycle/policy.py POLICY_HOLD_MIGRATION, the implementation notes,
-- CONTEXT.md) (git grep '398_' and git grep '398').
--
-- Locks. ALTER TABLE DROP / ADD CONSTRAINT take ACCESS EXCLUSIVE on published_tours for the re-check of ~1,070 rows
-- (milliseconds); lock_timeout 5s gives up instead of queueing the readers, statement_timeout 1min. Idempotent (the
-- constraint is dropped and re-added), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the code that writes 'policy_hold' is reverted and no row holds it):
-- re-add the constraint with the four 272 values.
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of
-- gold_aa_internal and of published_tours (245).

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('aa.actor', 'migration:398', true);

-- ── Preconditions ──────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    bad bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '272') THEN
        RAISE EXCEPTION 'migration 398: apply 272 (published_tours.master_status_reason) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = 'gold_aa_internal.published_tours'::regclass
                      AND a.attname = 'master_status_reason' AND NOT a.attisdropped
                      AND format_type(a.atttypid, a.atttypmod) = 'text' AND NOT a.attnotnull) THEN
        RAISE EXCEPTION 'migration 398: published_tours.master_status_reason missing or not a nullable text';
    END IF;
    SELECT count(*) INTO bad FROM gold_aa_internal.published_tours
     WHERE master_status_reason IS NOT NULL
       AND master_status_reason NOT IN ('staff_deactivated', 'staff_trashed', 'source_deleted', 'superseded',
                                        'policy_hold');
    IF bad <> 0 THEN
        RAISE EXCEPTION 'migration 398: % published_tours rows hold an unknown master_status_reason', bad;
    END IF;
END $$;

-- ── 1. the reason a Master is not active, with policy_hold ─────────────────────────────────────────────────────────
ALTER TABLE gold_aa_internal.published_tours DROP CONSTRAINT IF EXISTS published_tours_master_status_reason_check;
ALTER TABLE gold_aa_internal.published_tours ADD CONSTRAINT published_tours_master_status_reason_check
    CHECK (master_status_reason IS NULL
           OR master_status_reason IN ('staff_deactivated', 'staff_trashed', 'source_deleted', 'superseded',
                                       'policy_hold'));

-- ── 2. the column comment ──────────────────────────────────────────────────────────────────────────────────────────
COMMENT ON COLUMN gold_aa_internal.published_tours.master_status_reason IS
    'AA-986 L2 (ADR 0015): why this Master is not active. staff_deactivated / staff_trashed = a staff action; '
    'source_deleted / superseded = the tour lifecycle service switched it off (only those come back on restore / '
    'set-active); policy_hold = held for the elephant-riding policy review (CIS 398, AA-1049, root ADR 0020 D8): only '
    'a Review Queue approval puts it back on sale. NULL = active, or switched off before CIS 272. Written only by '
    'services/tour_lifecycle.';

-- ── Guards ─────────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    probe   uuid;
    v       text;
    refused boolean := false;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'gold_aa_internal.published_tours'::regclass
                      AND conname = 'published_tours_master_status_reason_check' AND convalidated) THEN
        RAISE EXCEPTION 'migration 398: published_tours_master_status_reason_check missing or not validated';
    END IF;
    SELECT id INTO probe FROM gold_aa_internal.published_tours ORDER BY id LIMIT 1;
    IF probe IS NULL THEN
        RAISE NOTICE 'migration 398: published_tours is empty, the CHECK probe is skipped';
        RETURN;
    END IF;
    FOREACH v IN ARRAY ARRAY['staff_deactivated', 'staff_trashed', 'source_deleted', 'superseded', 'policy_hold']
    LOOP
        BEGIN
            UPDATE gold_aa_internal.published_tours SET master_status_reason = v WHERE id = probe;
            RAISE EXCEPTION USING ERRCODE = 'P0398', MESSAGE = 'probe rollback';
        EXCEPTION WHEN SQLSTATE 'P0398' THEN
            NULL;   -- accepted; the sub-transaction rolled the probe write back
        END;
    END LOOP;
    BEGIN
        UPDATE gold_aa_internal.published_tours SET master_status_reason = 'not_a_reason' WHERE id = probe;
    EXCEPTION WHEN check_violation THEN
        refused := true;
    END;
    IF NOT refused THEN
        RAISE EXCEPTION 'migration 398: the CHECK accepts an unknown master_status_reason';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('398', now(), 'AA-1049 (S277): published_tours.master_status_reason policy_hold, a Master held for the '
                      'elephant-riding policy review')
ON CONFLICT (version) DO NOTHING;

COMMIT;
