-- migrate: expand
-- Migration 480: AA-838 (S291, C4.3 W48 finding 1) — an index on the catalog key expression of
-- silver_aa_internal.raw_tours, so a read of gold_aa_internal.v_tour_liveness for ONE key is an index probe.
--
-- Why. v_tour_liveness (CIS 272) groups raw_tours by the key expression (COALESCE(source_group_id, tour_id))::text,
-- written out (not the stored raw_tours.source_key of CIS 258) so the view does not depend on that column. A filter on
-- the view's source_id is pushed into that GROUP BY as a filter on the expression, which no index serves (the
-- raw_tours_source_key_idx of 258 is on the stored column, a different expression for the planner), so even a
-- one-key read scans every raw_tours row. The tenant served-badge lookup (shared/tour_liveness.py REQUEST_TOURS_SQL,
-- role aa_app_user) missed the tenant-read objective in W48 (806 calls, mean 121.6 ms, p95 ~155 ms, ~29,000 buffers a
-- call): it joined the view on the key expression, which recomputed the whole view per request row. The code PR of
-- the same wave reads the view per request through a LATERAL lookup keyed on the stored source_key; with this index
-- each lookup becomes an Index Cond on the expression. The lifecycle service's own key reads
-- (services/tour_lifecycle/service.py KEY_EXPR = $1: the key's versions, the dead-Master switch-off, the review
-- dismissal) use the same expression and gain the same index.
--
-- What. One non-unique btree on ((COALESCE(source_group_id, tour_id))::text), the exact expression of the view's
-- GROUP BY and of KEY_EXPR (an index is used only for the same expression tree). Nothing else changes: no view text,
-- no grant. The code works without the index (slower), so readiness does not require 480.
--
-- Class: expand (root ADR 0017 d3): a new non-unique index on an existing table. raw_tours is ~987 rows (2026-11-24
-- dump, far below the 100k MIG-10 lock-risk threshold), so a plain CREATE INDEX inside the transaction is allowed; it
-- holds a SHARE lock for milliseconds (writers of raw_tours wait; readers do not). Idempotent (IF NOT EXISTS),
-- self-registering, lock_timeout 5s. DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. Owner main max (479) + 1 on 24/11/2026. If another file takes 480 first, renumber (git grep '480_' and
-- '480' in this file, tests/integration/test_aa838_migration_480.py and docs/implementation-notes/S291-cis-followups.md).
--
-- Rollback (a new forward migration): DROP INDEX silver_aa_internal.raw_tours_key_expr_idx. Readers are unaffected
-- (no statement names the index).

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE INDEX IF NOT EXISTS raw_tours_key_expr_idx
    ON silver_aa_internal.raw_tours (((COALESCE(source_group_id, tour_id))::text));

COMMENT ON INDEX silver_aa_internal.raw_tours_key_expr_idx IS
    'AA-838 (480): the catalog key expression of v_tour_liveness / the lifecycle KEY_EXPR, so a one-key read is a probe';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('480', now(), 'AA-838: raw_tours index on the catalog key expression (one-key v_tour_liveness reads)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
