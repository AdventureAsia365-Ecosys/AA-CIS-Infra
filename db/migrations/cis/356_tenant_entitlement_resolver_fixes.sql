-- Migration 356: AA-1028 R1 slice 2 (root ADR 0019 d1, d2) — resolver fixes from the slice-1 review: a platform key
-- (ai.budget_usd_monthly, policy.notice_days) needs a live content subscription, a per-tenant
-- shared.tenants.rate_limit_rpm is published as the content.rate_limit_rpm entitlement, and the writer guard of 355
-- checks one privilege per call.
--
-- Why.
--   * 353's resolver applied every platform-key candidate (an override, the legacy shared.tenant_ai_budget row)
--     whatever the tenant's subscriptions: an offboarded tenant (content subscription canceled by the 355 bridge)
--     kept ai.budget_usd_monthly in shared.tenant_entitlement and in tenant.entitlements.v1. Platform keys belong to
--     no single product, but a tenant only has them while it is a customer: from now on they need a live content
--     subscription, as an add-on key needs its own product's.
--   * shared.tenants.rate_limit_rpm is what the CIS public API limiter enforces (api/middleware/rate_limit.py); the
--     AA-766 admin PATCH sets a per-tenant value. The contract published the plan's content.rate_limit_rpm only, so a
--     tenant with an RPM override was served a wrong limit. The column stays the limiter's source until slice 3 moves
--     the limiter onto the entitlement; until then the entitlement mirrors it: when the column differs from the live
--     content plan's value it is the entitlement (source override), and it wins over an explicit
--     tenant_entitlement_override of the same key (that would publish a limit nobody enforces).
--   * 355's guard 2 passed several privileges in one has_table_privilege() call ('SELECT, INSERT, UPDATE'), which is
--     true when ANY of them is held, so a writer with SELECT only would have passed. The guard is re-run here with
--     one call per privilege (355 is applied on Dev and is never re-run, so the fix lives in this file).
--   * A trialing subscription whose trial_ends_at has passed stayed live: 353's live_sub took every 'trialing' row,
--     so the plan's keys (trade.book included) stayed served with an expires_at in the past, and nothing ends a trial
--     yet (the trial-end tick is slice 3 work; the tenant_provision saga refuses trial_days until then). From now on
--     a trialing row is live only while trial_ends_at > now() (353 requires trial_ends_at while trialing), so every
--     reader of the live resolver (tenant.entitlements.v1 snapshot, catalog.v_tenant_account_v1.trade_book of 357)
--     stops serving it at the trial end.
--   * Wording: 353's "Order" header line says "353 (expand)"; 353 is a contract file, as its "Class" paragraph
--     states. 353 is applied on Dev and its bytes are not edited (an edit to an applied file is a silent no-op).
--
-- What.
--   1. CREATE OR REPLACE VIEW shared.v_tenant_entitlement_resolved, same columns: (a) a platform-key candidate other
--      than the plan's needs a live content subscription; (b) a new candidate of rank 0, shared.tenants.rate_limit_rpm
--      as content.rate_limit_rpm (source override), only when it differs from the live content plan's value; (c) a
--      trialing subscription is live only until its trial_ends_at.
--   2. Trigger tenants_rate_limit_resync on shared.tenants (AFTER UPDATE OF rate_limit_rpm, the 353 function
--      shared.tenant_entitlement_resync_row): an RPM change re-syncs that tenant's entitlements (entitlement.changed).
--      The name sorts after tenants_content_subscription_upd, so on a PATCH that moves plan_tier and rate_limit_rpm
--      together the bridge moves the subscription first.
--   3. Re-sync every tenant (shared.tenant_entitlement_sync): an offboarded tenant loses its platform keys, a tenant
--      whose RPM differs from its plan gets the override row; each change writes entitlement.changed (actor
--      migration:356).
--   4. Guard (one privilege per has_*_privilege call): every real writer of shared.tenants (owner, grantee of the
--      table or a column, or a member of one, as 354 / 355) holds each privilege the 355 bridge and the trigger of
--      item 2 need.
--   5. Register 356.
--
-- Behaviour. The limiter, the gateway budget check and every CIS reader are unchanged. tenant.entitlements.v1
-- serves the corrected rows at once (the snapshot reads the live contract view); the feed gets the re-sync events.
-- Nothing reads ai.budget_usd_monthly from the entitlement yet (the gateway reads shared.tenant_ai_budget).
--
-- Class: contract (CREATE OR REPLACE of an existing view, a trigger on an existing table, writes rows through the
-- sync). MIG-4: migration-only PR with 357. On Dev: Infra Migration Apply stops at the pending CIS 336
-- (out-of-order), so a person applies 356 then 357 with DB Migrate apply (every job table idle, DM-11.4), as 353-355.
--
-- Rollback (a NEW forward migration): restate 353's view; DROP TRIGGER tenants_rate_limit_resync ON shared.tenants;
-- SELECT shared.tenant_entitlement_sync(tenant_id) FROM shared.tenants.
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of shared.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/; keep the two byte-identical. After
-- apply: the DB Schema Dump bot PR regenerates docs/architecture/db-schema-reference.md.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('aa.actor', 'migration:356', true);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '355')
       OR to_regclass('shared.v_tenant_entitlement_v1') IS NULL THEN
        RAISE EXCEPTION 'migration 356: apply 355 first';
    END IF;
END $$;

-- ── 1. The resolver ─────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW shared.v_tenant_entitlement_resolved AS
WITH live_sub AS (
    SELECT s.tenant_id, s.product, s.plan_key, s.status, s.trial_ends_at, s.seats
      FROM shared.tenant_subscription s
     WHERE s.status IN ('active', 'past_due')
        -- 356: a trial is live only until it ends (353 requires trial_ends_at while trialing)
        OR (s.status = 'trialing' AND s.trial_ends_at > now())
),
candidate AS (
    -- 356: the limiter's per-tenant RPM (shared.tenants.rate_limit_rpm) when it differs from the live content plan.
    SELECT t.tenant_id, 'content.rate_limit_rpm'::text AS feature_key, t.rate_limit_rpm::numeric(14,2) AS limit_value,
           true AS enabled, 'override'::text AS source, NULL::text AS plan_key,
           NULL::timestamp with time zone AS expires_at, 0 AS rank
      FROM shared.tenants t
      JOIN live_sub ls ON ls.tenant_id = t.tenant_id AND ls.product = 'content'
      LEFT JOIN shared.plan_feature pf ON pf.plan_key = ls.plan_key AND pf.feature_key = 'content.rate_limit_rpm'
     WHERE pf.limit_value IS DISTINCT FROM t.rate_limit_rpm::numeric(14,2)
    UNION ALL
    SELECT o.tenant_id, o.feature_key, o.limit_value, o.enabled, 'override'::text, NULL::text, o.expires_at, 1
      FROM shared.tenant_entitlement_override o
     WHERE o.expires_at IS NULL OR o.expires_at > now()
    UNION ALL
    -- AA-1016's per-tenant AI budget acts as the override of ai.budget_usd_monthly until slice 3 retires the table.
    SELECT b.tenant_id, 'ai.budget_usd_monthly'::text, b.monthly_usd::numeric(14,2), true, 'override'::text,
           NULL::text, NULL::timestamp with time zone, 2
      FROM shared.tenant_ai_budget b
    UNION ALL
    SELECT ls.tenant_id, pf.feature_key,
           CASE WHEN f.value_kind = 'seats' THEN coalesce(ls.seats::numeric(14,2), pf.limit_value)
                ELSE pf.limit_value END,
           true,
           CASE WHEN ls.status = 'trialing' THEN 'trial' ELSE 'plan' END,
           ls.plan_key,
           CASE WHEN ls.status = 'trialing' THEN ls.trial_ends_at END,
           3
      FROM live_sub ls
      JOIN shared.plan_feature pf ON pf.plan_key = ls.plan_key
      JOIN shared.entitlement_feature f ON f.feature_key = pf.feature_key
),
ranked AS (
    SELECT c.tenant_id, c.feature_key, c.limit_value, c.enabled, c.source, c.plan_key, c.expires_at,
           f.product, f.value_kind, f.unit,
           row_number() OVER (PARTITION BY c.tenant_id, c.feature_key ORDER BY c.rank) AS rn
      FROM candidate c
      JOIN shared.entitlement_feature f ON f.feature_key = c.feature_key
     WHERE f.retired_at IS NULL
       -- a candidate that is not the plan's own needs a live subscription of the key's product; a platform key's
       -- product is content (356: before, platform keys applied with no live subscription at all)
       AND (c.rank = 3
            OR EXISTS (SELECT 1 FROM live_sub ls
                        WHERE ls.tenant_id = c.tenant_id
                          AND ls.product = CASE WHEN f.product = 'platform' THEN 'content' ELSE f.product END))
)
SELECT r.tenant_id, r.feature_key, r.product, r.value_kind, r.unit,
       CASE WHEN r.value_kind = 'flag' THEN NULL ELSE r.limit_value END AS limit_value,
       r.source, r.plan_key, r.expires_at
  FROM ranked r
 WHERE r.rn = 1 AND r.enabled;
COMMENT ON VIEW shared.v_tenant_entitlement_resolved IS
    'AA-1028 R1 (CIS 353, 356): the resolver, computed live: shared.tenants.rate_limit_rpm when it differs from the '
    'content plan (the limiter''s value, 356) > override (unexpired) > shared.tenant_ai_budget (as the '
    'ai.budget_usd_monthly override) > the plan of a live subscription (trial while trialing, until trial_ends_at, '
    '356). A non-plan candidate '
    'needs a live subscription of its product (content for platform keys, 356). Internal: the contract view is '
    'shared.v_tenant_entitlement_v1 (355).';

-- ── 2. An RPM change re-syncs the tenant ────────────────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS tenants_rate_limit_resync ON shared.tenants;
CREATE TRIGGER tenants_rate_limit_resync
    AFTER UPDATE OF rate_limit_rpm ON shared.tenants
    FOR EACH ROW
    WHEN (OLD.rate_limit_rpm IS DISTINCT FROM NEW.rate_limit_rpm)
    EXECUTE FUNCTION shared.tenant_entitlement_resync_row();

-- ── 3. Re-sync every tenant ─────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    before_n bigint;
    changed  bigint := 0;
    t        record;
BEGIN
    SELECT count(*) INTO before_n FROM shared.tenant_account_event WHERE type = 'entitlement.changed';
    FOR t IN SELECT tenant_id FROM shared.tenants ORDER BY created_at, tenant_id LOOP
        changed := changed + shared.tenant_entitlement_sync(t.tenant_id);
    END LOOP;
    RAISE NOTICE 'migration 356: re-sync changed % entitlement row(s) (% entitlement.changed event(s))', changed,
        (SELECT count(*) FROM shared.tenant_account_event WHERE type = 'entitlement.changed') - before_n;
END $$;

-- ── 4. Guards ───────────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    bad text;
    n   bigint;
BEGIN
    -- Every real writer of shared.tenants can run the 355 bridge and the item-2 trigger: one privilege per call
    -- (has_table_privilege('SELECT, INSERT') is true when ANY of them is held).
    WITH grantee AS (
        SELECT c.relowner AS oid FROM pg_class c WHERE c.oid = 'shared.tenants'::regclass
        UNION
        SELECT a.grantee FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid = 'shared.tenants'::regclass AND a.privilege_type IN ('INSERT', 'UPDATE')
        UNION
        SELECT a.grantee FROM pg_attribute att CROSS JOIN LATERAL aclexplode(att.attacl) a
         WHERE att.attrelid = 'shared.tenants'::regclass AND NOT att.attisdropped
           AND a.privilege_type IN ('INSERT', 'UPDATE')
    ),
    writer AS (
        SELECT r.oid, r.rolname FROM pg_roles r
         WHERE r.rolname NOT LIKE 'pg\_%' AND NOT r.rolsuper
           AND EXISTS (SELECT 1 FROM grantee g WHERE g.oid = 0 OR pg_has_role(r.oid, g.oid, 'USAGE'))
    ),
    need (obj, priv) AS (
        VALUES ('shared.plan', 'SELECT'), ('shared.plan_feature', 'SELECT'),
               ('shared.tenant_subscription', 'SELECT'), ('shared.tenant_subscription', 'INSERT'),
               ('shared.tenant_subscription', 'UPDATE'),
               ('shared.tenant_entitlement', 'SELECT'), ('shared.tenant_entitlement', 'INSERT'),
               ('shared.tenant_entitlement', 'UPDATE'), ('shared.tenant_entitlement', 'DELETE'),
               ('shared.tenant_account_event', 'INSERT'), ('shared.v_tenant_entitlement_resolved', 'SELECT')
    ),
    fn (sig) AS (
        VALUES ('shared.tenant_entitlement_sync(uuid)'), ('shared.tenant_account_closed(uuid)'),
               ('shared.tenant_account_emit(text, uuid, jsonb)')
    )
    SELECT string_agg(DISTINCT w.rolname || ':' || x.what, ', ') INTO bad
      FROM writer w
      CROSS JOIN LATERAL (
          SELECT n.obj || ' ' || n.priv AS what FROM need n WHERE NOT has_table_privilege(w.oid, n.obj, n.priv)
          UNION ALL
          SELECT f.sig || ' EXECUTE' FROM fn f WHERE NOT has_function_privilege(w.oid, f.sig, 'EXECUTE')
      ) x;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 356: writers of shared.tenants miss what the bridge and the RPM re-sync need: %',
                        bad;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger tg
                    WHERE tg.tgrelid = 'shared.tenants'::regclass AND tg.tgname = 'tenants_rate_limit_resync'
                      AND tg.tgfoid = 'shared.tenant_entitlement_resync_row()'::regprocedure AND NOT tg.tgisinternal) THEN
        RAISE EXCEPTION 'migration 356: trigger tenants_rate_limit_resync missing';
    END IF;
    -- The materialisation equals the resolver after the re-sync.
    SELECT count(*) INTO n
      FROM shared.v_tenant_entitlement_resolved r
      FULL JOIN shared.tenant_entitlement e ON e.tenant_id = r.tenant_id AND e.feature_key = r.feature_key
     WHERE r.feature_key IS NULL OR e.feature_key IS NULL OR r.limit_value IS DISTINCT FROM e.limit_value
        OR r.source IS DISTINCT FROM e.source;
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 356: % materialised row(s) differ from the resolver', n;
    END IF;
    -- No tenant without a live content subscription keeps a platform key.
    SELECT count(*) INTO n
      FROM shared.tenant_entitlement e
      JOIN shared.entitlement_feature f ON f.feature_key = e.feature_key AND f.product = 'platform'
     WHERE NOT EXISTS (SELECT 1 FROM shared.tenant_subscription s
                        WHERE s.tenant_id = e.tenant_id AND s.product = 'content'
                          AND (s.status IN ('active', 'past_due')
                               OR (s.status = 'trialing' AND s.trial_ends_at > now())));
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 356: % platform entitlement(s) without a live content subscription', n;
    END IF;
    -- Every tenant with a live content subscription is served the limiter's RPM.
    SELECT count(*) INTO n
      FROM shared.tenants t
      JOIN shared.tenant_subscription s ON s.tenant_id = t.tenant_id AND s.product = 'content'
                                       AND (s.status IN ('active', 'past_due')
                                            OR (s.status = 'trialing' AND s.trial_ends_at > now()))
      LEFT JOIN shared.tenant_entitlement e ON e.tenant_id = t.tenant_id AND e.feature_key = 'content.rate_limit_rpm'
     WHERE e.limit_value IS DISTINCT FROM t.rate_limit_rpm::numeric(14,2)
       -- an explicit override on a tenant whose column equals its plan still wins (slice 3 moves the limiter)
       AND NOT EXISTS (SELECT 1 FROM shared.tenant_entitlement_override o
                        WHERE o.tenant_id = t.tenant_id AND o.feature_key = 'content.rate_limit_rpm');
    IF n > 0 THEN
        RAISE EXCEPTION 'migration 356: % live tenant(s) served another content.rate_limit_rpm than the limiter''s', n;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('356', now(), 'AA-1028 R1 slice 2: resolver fixes (platform keys need a live content subscription, '
                      'rate_limit_rpm mirrored, an ended trial is not live), writer guard per privilege')
ON CONFLICT (version) DO NOTHING;

COMMIT;
