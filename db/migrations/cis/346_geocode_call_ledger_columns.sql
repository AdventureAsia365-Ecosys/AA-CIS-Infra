-- Migration 346: AA-1025 (S263 gateway plan, slice D3) — geo.geocode_call gains the ledger facts the other ledgers
-- carry: status, latency_ms, app, stage.
--
-- Why. Root ADR 0009 decision 8 (amended in S264, D3, tech lead T-14 option b): the ledger contract is read
-- federated: shared.llm_call_log for LLM and Jev calls, the domain ledgers shared.dfs_call_log and geo.geocode_call
-- for DataForSEO and Geoapify, each with the contract's own facts, read together by the admin (Calls tab, job / tour
-- trace, Providers). geo.geocode_call had none of them: its status was derived (every request failed = error), it
-- had no latency (the Providers page showed no p50 / p95 for Geoapify), no app and no stage (the Calls tab could not
-- filter it by stage).
--
-- What.
--   1. ALTER TABLE geo.geocode_call ADD COLUMN (all nullable, no default: rows before this file keep NULL and the
--      readers derive them as before):
--        status      ok | refused | error (ledger v2 statuses a geocoder batch can have; NULL = written before 346);
--        latency_ms  the batch's provider time in milliseconds (the sum over its HTTP requests), >= 0;
--        app         the app that paid for the batch ('cis' today), lower case;
--        stage       the work that sent it (place_geocode, place_relocate, place_shape, adhoc_conn_test), lower case.
--      CHECKs on each, the shapes of llm_call_log's (319) and of the Calls tab's filters.
--   2. Register 346.
--
-- Behaviour. None on apply: the writers (services/places/store.log_geocode_calls) fill the columns once the code PR
-- is deployed; before that, and on rows written before it, they stay NULL and the readers keep their derivation
-- (status: every request failed = error, else ok; app: cis). geo.geocode_call is small (~100 rows) and not a hot
-- table (Infra owners.yaml expand_hot_tables): ADD COLUMN without a default and a CHECK on an all-NULL column take a
-- short ACCESS EXCLUSIVE lock.
--
-- Class: contract (root ADR 0017 d3): new constraints on an existing table. No readiness raise in this migration-only
-- PR (MIG-4); on Dev, Infra Migration Apply applies it once every job table is idle (root ADR 0017a). Order: after 345
-- (same PR).
--
-- Rollback (a new forward migration, after the code is reverted): ALTER TABLE geo.geocode_call DROP COLUMN status,
-- DROP COLUMN latency_ms, DROP COLUMN app, DROP COLUMN stage; (a destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema geo.

BEGIN;

SET LOCAL lock_timeout = '5s';

ALTER TABLE geo.geocode_call
    ADD COLUMN IF NOT EXISTS status     text,
    ADD COLUMN IF NOT EXISTS latency_ms integer,
    ADD COLUMN IF NOT EXISTS app        text,
    ADD COLUMN IF NOT EXISTS stage      text;

ALTER TABLE geo.geocode_call DROP CONSTRAINT IF EXISTS geocode_call_status_chk;
ALTER TABLE geo.geocode_call ADD CONSTRAINT geocode_call_status_chk
    CHECK (status IS NULL OR status IN ('ok', 'refused', 'error'));
ALTER TABLE geo.geocode_call DROP CONSTRAINT IF EXISTS geocode_call_latency_ms_chk;
ALTER TABLE geo.geocode_call ADD CONSTRAINT geocode_call_latency_ms_chk
    CHECK (latency_ms IS NULL OR latency_ms >= 0);
ALTER TABLE geo.geocode_call DROP CONSTRAINT IF EXISTS geocode_call_app_chk;
ALTER TABLE geo.geocode_call ADD CONSTRAINT geocode_call_app_chk
    CHECK (app IS NULL OR app ~ '^[a-z][a-z0-9_]{0,30}$');
ALTER TABLE geo.geocode_call DROP CONSTRAINT IF EXISTS geocode_call_stage_chk;
ALTER TABLE geo.geocode_call ADD CONSTRAINT geocode_call_stage_chk
    CHECK (stage IS NULL OR stage ~ '^[a-z0-9_]{1,64}$');

COMMENT ON COLUMN geo.geocode_call.status IS
    'AA-1025 D3 (CIS 346): ok | refused | error of the batch (ledger v2 statuses). NULL = written before 346: readers '
    'derive it (every request failed = error, else ok).';
COMMENT ON COLUMN geo.geocode_call.latency_ms IS
    'AA-1025 D3 (346): the batch''s provider time in ms, the sum over its HTTP requests (NULL before 346).';
COMMENT ON COLUMN geo.geocode_call.app IS
    'AA-1025 D3 (346): the app that paid for the batch (cis); NULL before 346 = cis.';
COMMENT ON COLUMN geo.geocode_call.stage IS
    'AA-1025 D3 (346): the work that sent the batch (place_geocode, place_relocate, place_shape, adhoc_conn_test).';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('346', now(), 'AA-1025 D3: geo.geocode_call status / latency_ms / app / stage (ledger contract, federated '
                      'read)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
