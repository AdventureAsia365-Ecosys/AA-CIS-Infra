-- Migration 257: AA-847 Problem 2 — storage for the automatic duplicate-place merge (owner decision S246: duplicates
-- are merged AUTOMATICALLY and correctly; an admin merging by hand is an override, not the normal path).
--
-- Why. The same place is often two destinations ("Kuang Si Falls" / "Tat Kuang Si", "Mekong" / "Mekong River"). The
-- job kind place_dedupe (services/jobs/place_dedupe_job.py) decides each pair with services/places/dedupe.decide
-- (rules r1.4; the middle band by two models that must agree), merges with duplicate_of = keeper and repoints the CIS
-- rows. Every merge must be logged, explainable and reversible; a model verdict is paid once; countries are switched
-- to `apply` one by one after their dry run was approved. Design + skeptic pass: root
-- docs/audits/2026-10-21-S246-aa847/dedupe/ and the revised plan (it named 256; the lines lane took 256 for its catalog
-- views, so this is 257 — independent of 256, applied after it by number).
--
-- What:
--   1. geo.place_merge — one row per merge (job or admin): who (merged_id → keeper_id, country), how (decided_by,
--      rule_version, score, features = every factor of the decision, verdict = the pair-verdict key), what moved
--      (repointed = table → key rows; prior = rows whose duplicate_of moved from merged_id to keeper_id because the
--      merged row was itself a keeper), when / by whom, and the undo (undone_at / by / reason). At most one active
--      merge per merged row. Not repointed (left on the merged id, hidden by the duplicate_of filters): geo.place_shape
--      and geo.place_outlier (their primary keys would collide), the build-versioned geo.tour_segment and graph tables
--      (the graph build the merge enqueues rebuilds them).
--   2. geo.place_pair_verdict — the cache of the two-model check: PK (lo_id, hi_id, input_hash), verdict same /
--      different / unsure, every answer, the models, the cost and the job. A pin (source undo / admin / recheck) has
--      input_hash '*' and holds for any input: an undone merge is never re-made by the job.
--   3. geo.place_dedupe_country — the allow-list: a listed country gets the model band (paid) and, in mode `apply`,
--      its merges written; mode `apply` needs the hash (and the content) of the dry-run diff an admin approved, for
--      the rule version in force (the job drops a country back to dry_run when the rule version changes).
--   4. shared.llm_role_config: a3_place_dedupe (validate, GPT-6 Luna on Bedrock acc3; the OpenAI platform only as
--      the last-resort fallback, S235) and a3_place_dedupe_check (validate, Claude Haiku on acc3: another vendor).
--      ON CONFLICT DO NOTHING (an admin change is never overwritten); SAFE_DEFAULTS mirrors them.
--   5. shared.spend_budget bedrock / job:place_dedupe: $0.50 per run, hard stop.
--   6. catalog.v_destination_redirect (destination_id → keeper_id, merged rows only; duplicate_of always names a
--      root — the job asserts it) for TripPlanner / Booking to resolve an old destination id. Built with the X1 S22
--      catalog recipe (as 253): owner catalog_owner, SELECT to tripplanner and booking.
--   7. Privileges: cis_app SELECT / INSERT / UPDATE / DELETE on the three geo tables; nothing for tripplanner,
--      booking, aa_app_user or PUBLIC (geo is CIS-internal).
--   8. Register 257.
--
-- Guards (RAISE, nothing changes): 0. before: shared.destinations, geo.place_shape (255), schema catalog owned by
--   cis_owner (245). 1. after: tables with their named CHECKs, both stage rows, the budget row, the view's owner and
--   grants, cis_app DML, no consumer privilege on the geo tables.
--
-- Recipe. Schema catalog belongs to cis_owner and its views to catalog_owner (X1 S22): GRANT CREATE ON SCHEMA catalog
-- TO catalog_owner; SET LOCAL ROLE catalog_owner; the view; SET LOCAL ROLE cis_owner; REVOKE CREATE. DB Migrate runs
-- the file as cis_owner (login db_migrator). The conftest replay skips this file (the recipe needs 245);
-- tests/integration/test_aa847_migration_257.py applies it the DB Migrate way.
--
-- Locks: three new tables, two INSERTs, one new view — nothing existing is rewritten. lock_timeout 5s. Re-running is
-- a no-op. The SQL applied on Dev is the byte-identical copy in AA-CIS-Infra db/migrations/cis/ (Copy Guard).
--
-- Rollback: DROP VIEW catalog.v_destination_redirect (recipe); DROP TABLE geo.place_dedupe_country,
-- geo.place_pair_verdict, geo.place_merge — only after every active merge is undone (or the log is lost: duplicate_of
-- stays, the merges just have no record); DELETE the two stage rows and the budget row; DELETE schema_versions 257.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Guard 0 ──────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('shared.destinations') IS NULL THEN
        RAISE EXCEPTION 'migration 257: shared.destinations does not exist';
    END IF;
    IF to_regclass('geo.place_shape') IS NULL THEN
        RAISE EXCEPTION 'migration 257: geo.place_shape missing (apply 255 first)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 257: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. geo.place_merge ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS geo.place_merge (
    id            uuid         NOT NULL DEFAULT gen_random_uuid(),
    merged_id     uuid         NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    keeper_id     uuid         NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    country       text         NOT NULL,
    decided_by    text         NOT NULL,
    rule_version  text         NOT NULL,
    score         numeric(6, 3),
    features      jsonb        NOT NULL DEFAULT '{}'::jsonb,
    verdict       jsonb,
    repointed     jsonb        NOT NULL DEFAULT '{}'::jsonb,
    prior         jsonb        NOT NULL DEFAULT '{}'::jsonb,
    job_id        uuid,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    created_by    text         NOT NULL,
    undone_at     timestamptz,
    undone_by     text,
    undo_reason   text,
    CONSTRAINT place_merge_pkey PRIMARY KEY (id),
    CONSTRAINT place_merge_not_self_chk CHECK (merged_id <> keeper_id),
    CONSTRAINT place_merge_decided_by_chk
        CHECK (decided_by IN ('provider_id', 'osm_id', 'place_card', 'line_overlap', 'rule', 'llm', 'admin')),
    CONSTRAINT place_merge_undo_chk CHECK ((undone_at IS NULL) = (undone_by IS NULL)
                                           AND (undone_at IS NULL OR undo_reason IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS place_merge_active_uidx ON geo.place_merge (merged_id) WHERE undone_at IS NULL;
CREATE INDEX IF NOT EXISTS place_merge_keeper_idx ON geo.place_merge (keeper_id);
CREATE INDEX IF NOT EXISTS place_merge_country_idx ON geo.place_merge (country, created_at DESC);

COMMENT ON TABLE geo.place_merge IS
    'AA-847 (257): every duplicate-place merge (job place_dedupe or the admin fix): merged_id gets duplicate_of = keeper_id, the CIS rows in `repointed` moved to the keeper. Undo (by id) clears duplicate_of, restores the pointers that still hold the keeper and writes a `different` pin in geo.place_pair_verdict.';
COMMENT ON COLUMN geo.place_merge.decided_by IS
    'provider_id (same Geoapify POI object) | osm_id (same OSM line) | place_card | line_overlap | rule (score) | llm (two models agreed) | admin (validity fix)';
COMMENT ON COLUMN geo.place_merge.repointed IS
    '{table: [[key, …], …]} of the rows moved from merged_id to keeper_id: geo.tour_place, geo.tour_day (overnight), geo.place_name, acp_shared.place_card, shared.place_photo';
COMMENT ON COLUMN geo.place_merge.prior IS
    '{"flattened": [destination ids]}: rows merged into merged_id before, moved to keeper_id so duplicate_of always names a root';

-- ── 2. geo.place_pair_verdict ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS geo.place_pair_verdict (
    lo_id         uuid           NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    hi_id         uuid           NOT NULL REFERENCES shared.destinations(id) ON DELETE CASCADE,
    input_hash    text           NOT NULL,
    verdict       text           NOT NULL,
    source        text           NOT NULL DEFAULT 'model',
    answers       jsonb          NOT NULL DEFAULT '[]'::jsonb,
    models        jsonb          NOT NULL DEFAULT '[]'::jsonb,
    rule_version  text           NOT NULL,
    prompt_sha    text,
    cost_usd      numeric(10, 6) NOT NULL DEFAULT 0,
    job_id        uuid,
    created_at    timestamptz    NOT NULL DEFAULT now(),
    created_by    text           NOT NULL,
    CONSTRAINT place_pair_verdict_pkey PRIMARY KEY (lo_id, hi_id, input_hash),
    CONSTRAINT place_pair_verdict_order_chk CHECK (lo_id < hi_id),
    CONSTRAINT place_pair_verdict_verdict_chk CHECK (verdict IN ('same', 'different', 'unsure')),
    CONSTRAINT place_pair_verdict_source_chk CHECK (source IN ('model', 'undo', 'admin', 'recheck')),
    CONSTRAINT place_pair_verdict_pin_chk CHECK ((source = 'model') = (input_hash <> '*')),
    CONSTRAINT place_pair_verdict_cost_chk CHECK (cost_usd >= 0)
);
CREATE INDEX IF NOT EXISTS place_pair_verdict_hi_idx ON geo.place_pair_verdict (hi_id);

COMMENT ON TABLE geo.place_pair_verdict IS
    'AA-847 (257): the two-model check of a destination pair (lo_id < hi_id), cached by input_hash (names, rounded points, kinds, line status, rule version, prompt sha, models): a pair is asked again only when its input changes. A pin (input_hash ''*'', source undo / admin / recheck) holds for any input.';
COMMENT ON COLUMN geo.place_pair_verdict.answers IS
    '[[step, verdict, confidence], …]: primary (A/B), primary_swapped (B/A), check (another vendor); calls stop at the first answer that is not same with confidence >= 0.8';

-- ── 3. geo.place_dedupe_country ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS geo.place_dedupe_country (
    country             text         NOT NULL,
    mode                text         NOT NULL DEFAULT 'dry_run',
    approved_diff_hash  text,
    approved_diff       jsonb        NOT NULL DEFAULT '[]'::jsonb,
    rule_version        text         NOT NULL,
    updated_by          text         NOT NULL,
    updated_at          timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT place_dedupe_country_pkey PRIMARY KEY (country),
    CONSTRAINT place_dedupe_country_norm_chk CHECK (country = lower(btrim(country)) AND country <> ''),
    CONSTRAINT place_dedupe_country_mode_chk CHECK (mode IN ('dry_run', 'apply')),
    CONSTRAINT place_dedupe_country_apply_chk CHECK (mode <> 'apply' OR approved_diff_hash IS NOT NULL)
);

COMMENT ON TABLE geo.place_dedupe_country IS
    'AA-847 (257): countries the place_dedupe job may spend on (the model band) and, in mode apply, write merges for. apply needs the approved dry-run diff of the same rule_version; the job counts changes outside it against the circuit breaker (max(5, 1 % of the country''s usable destinations)).';

-- ── 4. Stage keys (validate, two vendors) ───────────────────────────────────────────────────────
INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
VALUES
    ('a3_place_dedupe',       'validate', 'openai', 'gpt-6-luna', 'acc3', true, ARRAY['gpt-6-luna-openai']::text[],
     NULL, 0, 'migration-257'),
    ('a3_place_dedupe_check', 'validate', 'claude', 'haiku',      'acc3', true, ARRAY[]::text[],
     NULL, 0, 'migration-257')
ON CONFLICT (stage) DO NOTHING;

-- ── 5. Budget ────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.spend_budget (provider, scope, per_run_usd, per_day_usd, hard_stop, updated_by)
VALUES ('bedrock', 'job:place_dedupe', 0.50, NULL, true, 'migration-257')
ON CONFLICT (provider, scope) DO NOTHING;

-- ── 7. Privileges (geo) ──────────────────────────────────────────────────────────────────────────
REVOKE ALL ON geo.place_merge, geo.place_pair_verdict, geo.place_dedupe_country FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON geo.place_merge, geo.place_pair_verdict, geo.place_dedupe_country TO cis_app;
DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['tripplanner', 'booking', 'aa_app_user'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r) THEN
            EXECUTE format('REVOKE ALL ON geo.place_merge, geo.place_pair_verdict, geo.place_dedupe_country FROM %I',
                           r);
        END IF;
    END LOOP;
END $$;

-- ── 6. catalog.v_destination_redirect (X1 S22 catalog recipe) ───────────────────────────────────
GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

CREATE OR REPLACE VIEW catalog.v_destination_redirect WITH (security_barrier = true) AS
SELECT d.id AS destination_id, d.duplicate_of AS keeper_id
  FROM shared.destinations d
 WHERE d.duplicate_of IS NOT NULL;
COMMENT ON VIEW catalog.v_destination_redirect IS
    'AA-847 (257): a merged destination id → its keeper (duplicate_of always names a root). A reader that finds no catalog.v_destination row for an id looks here and redirects (TripPlanner: 301). After an undo the row disappears and the old id is live again. catalog.graph contract: appended in the next minor version.';
GRANT SELECT ON catalog.v_destination_redirect TO tripplanner, booking;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Guard 1 ──────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    missing text;
BEGIN
    SELECT string_agg(x, ', ') INTO missing
      FROM unnest(ARRAY['place_merge_not_self_chk', 'place_merge_decided_by_chk', 'place_merge_undo_chk']) AS x
     WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                        WHERE conrelid = 'geo.place_merge'::regclass AND conname = x AND contype = 'c');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 257: geo.place_merge lacks CHECK constraint(s) %', missing;
    END IF;
    SELECT string_agg(x, ', ') INTO missing
      FROM unnest(ARRAY['place_pair_verdict_order_chk', 'place_pair_verdict_verdict_chk',
                        'place_pair_verdict_source_chk', 'place_pair_verdict_pin_chk']) AS x
     WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                        WHERE conrelid = 'geo.place_pair_verdict'::regclass AND conname = x AND contype = 'c');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 257: geo.place_pair_verdict lacks CHECK constraint(s) %', missing;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                    WHERE conrelid = 'geo.place_dedupe_country'::regclass AND conname = 'place_dedupe_country_apply_chk') THEN
        RAISE EXCEPTION 'migration 257: geo.place_dedupe_country lacks place_dedupe_country_apply_chk';
    END IF;
    IF (SELECT count(*) FROM shared.llm_role_config
         WHERE stage IN ('a3_place_dedupe', 'a3_place_dedupe_check') AND role = 'validate') <> 2 THEN
        RAISE EXCEPTION 'migration 257: stage rows a3_place_dedupe / a3_place_dedupe_check missing or not validate';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.spend_budget WHERE provider = 'bedrock' AND scope = 'job:place_dedupe') THEN
        RAISE EXCEPTION 'migration 257: budget row bedrock / job:place_dedupe missing';
    END IF;
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'catalog.v_destination_redirect'::regclass)
       <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 257: catalog.v_destination_redirect is not catalog_owner''s';
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 257: catalog_owner still has CREATE on schema catalog';
    END IF;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'booking'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND NOT pg_catalog.has_table_privilege(r, 'catalog.v_destination_redirect', 'SELECT') THEN
            RAISE EXCEPTION 'migration 257: % cannot read catalog.v_destination_redirect', r;
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['geo.place_merge', 'geo.place_pair_verdict', 'geo.place_dedupe_country'] LOOP
        IF NOT pg_catalog.has_table_privilege('cis_app', t, 'SELECT, INSERT, UPDATE, DELETE') THEN
            RAISE EXCEPTION 'migration 257: cis_app lacks DML on %', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['tripplanner', 'booking', 'aa_app_user'] LOOP
            IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
               AND pg_catalog.has_table_privilege(r, t, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE') THEN
                RAISE EXCEPTION 'migration 257: % has a privilege on % (geo is CIS-internal)', r, t;
            END IF;
        END LOOP;
    END LOOP;
END $$;

-- ── 8. Register ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('257', now(), 'AA-847: automatic duplicate-place merge storage (geo.place_merge, geo.place_pair_verdict, '
                      'geo.place_dedupe_country), stages a3_place_dedupe / a3_place_dedupe_check (validate), budget '
                      'bedrock/job:place_dedupe $0.50/run, catalog.v_destination_redirect')
ON CONFLICT (version) DO NOTHING;

COMMIT;
