-- Migration 456: AA-1143 (tech lead decision G3, S285 19/11/2026; root ADR 0009 decisions 6 and 13) — the connection
-- budget rows of CIS 455 seeded from today's values, published to TripPlanner as catalog.v_llm_connection_cap_v2 (one
-- row per connection and app), and TripPlanner's log-only switch for its own share.
--
-- What:
--   1. The seed (only while shared.llm_connection_budget is empty; read at apply time, never literals). For every
--      registry connection with a CIS monthly budget C (shared.llm_provider_connection.monthly_budget_usd) or a
--      provider budget P (the approved platform value in force of setting cis.spend.connection_provider_budget_usd,
--      CIS 453; an entry that is not a number >= 0 is ignored):
--        - the total row (app NULL) = P, else C (a connection with no provider budget keeps its CIS cap as its total);
--        - a crm row = P - C when both are set and P > C. The CIS role cannot read the CRM's setting
--          crm.ai.connection_monthly_cap_usd (root ADR 0008a: no grant on CRM data), and the tech lead kept the two
--          values in sum by hand (acc1: provider 100, CIS 95, CRM 5; acc2 the same way), so P - C is the CRM share
--          today. AI gateway > Budgets compares the row with the CRM setting (crm.ops.v1 relay) and flags a difference;
--        - no tripplanner or booking row: TripPlanner stays inside the CIS remainder (as today), Booking has no AI.
--      After each INSERT statement CIS 455's apply trigger sets monthly_budget_usd to the remainder: P - (P - C) = C when P >= C, so the
--      CIS cap is unchanged; P when P < C or C is NULL (the provider budget, declared by the tech lead, now bounds
--      CIS too). The file checks both before it commits and logs one NOTICE per
--      connection. No connection is uncapped at any point: the rows and the cap change in the same transaction.
--   2. catalog.v_llm_connection_cap_v2 (security_barrier, owner catalog_owner, SELECT to tripplanner only), one row per
--      connection that has a total and per app (shared.llm_app_profile, plus cis):
--        connection_key, app, total_usd, share_usd (cis: the remainder; another app: its row, NULL when it has none),
--        in_cis_pool (an app other than cis without a share: counted inside the CIS remainder, as TripPlanner today),
--        month_start (UTC), month_spent_usd / month_calls (this app's rows of this UTC month in shared.llm_call_log
--        whose account is the connection; a NULL app counts as cis), cis_pool_spent_usd (the CIS remainder's spend:
--        every app without its own share, plus what an app with a share spent above it), alert_pct and hard_stop
--        (shared.llm_connection_cost_policy, defaults 80 / true), over_cap (the pool against the remainder for cis
--        and for an app in the pool; the app's own spend against its share otherwise) and stops (over_cap AND
--        hard_stop). The CRM keeps its own ledger (crm.llm_call): its row here shows its share; its spend and its
--        stop are the CRM's (it receives its share through crm.ops.v1). The CIS gateway enforces the same rule
--        (shared/cost_guard.py, AA-CIS-App code PR). Contract v2 (v1, CIS 452, stays as it is until the contract step).
--   3. One row in shared.setting_definition (seed block below; shared/settings/compiled_defaults.json in this PR):
--        tripplanner.spend.connection_share_enforce  bool, default false = TripPlanner reads its row of the v2 view
--          and only logs a reached share (log-only first, decision of the lane); true = under the dev spend rules it
--          leaves an over-share connection out of the route. Read by AA-TripPlanner-Web through
--          catalog.v_app_settings_v1 (CIS 415). Impact high, maker-checker, platform scope, enforced, guided.
--   4. Register 456.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): rows INSERTed into an existing table, an UPDATE
-- of shared.llm_provider_connection (the apply trigger), a new catalog view through the catalog recipe (ACL change on
-- schema catalog). MIG-4: migration-only PR with 455 (batch cis 455-456), applied on Dev by Infra Migration Apply when
-- every job table is idle (root ADR 0017a), then the code PRs. DM-7.1: no new table here (455's). DM-6.1: no personal
-- data.
--
-- Recipe. The X1 S22 catalog recipe (as 347 / 452): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE
-- catalog_owner; the view DDL; SET LOCAL ROLE cis_owner; REVOKE CREATE. Never RESET ROLE, no SECURITY DEFINER, no role
-- DDL. The conftest replay runs only the settings-seed block of this file;
-- tests/integration/test_aa1143_migration_455_456.py applies the whole file the DB Migrate way and undoes it.
--
-- Number. 455 (same PR) comes first; renumber both together (see 455).
--
-- Locks. INSERT into the new table; at most one UPDATE per registry row of shared.llm_provider_connection (row locks,
-- eleven rows); GRANTs; CREATE OR REPLACE VIEW of a new view. lock_timeout 5s, statement_timeout 1min. Idempotent (the
-- seed runs only on an empty table, CREATE OR REPLACE, ON CONFLICT DO NOTHING), one transaction, self-registering.
--
-- Rollback (a NEW forward migration under the same recipe, after the code PRs are reverted): DROP VIEW
-- catalog.v_llm_connection_cap_v2; REVOKE SELECT ON shared.llm_connection_budget_current FROM catalog_owner (the column
-- grants repeated from 323 / 347 / 452 stay); DELETE the
-- setting key's value rows, then the key. The seeded rows stay (append-only); the CIS caps they wrote stay in force.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

-- ── Preconditions (as the file's role: cis_owner on Dev) ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '455')
       OR to_regclass('shared.llm_connection_budget_current') IS NULL THEN
        RAISE EXCEPTION 'migration 456: apply 455 (shared.llm_connection_budget) first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '453') THEN
        RAISE EXCEPTION 'migration 456: apply 453 (the provider budget setting) first';
    END IF;
    IF to_regclass('shared.llm_connection_cost_policy') IS NULL THEN
        RAISE EXCEPTION 'migration 456: shared.llm_connection_cost_policy missing (317)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'shared' AND table_name = 'setting_definition' AND column_name = 'guide') THEN
        RAISE EXCEPTION 'migration 456: shared.setting_definition.guide missing (apply 416 first)';
    END IF;
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') <> 'cis_owner' THEN
        RAISE EXCEPTION 'migration 456: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
END $$;

-- ── 1. The seed ──────────────────────────────────────────────────────────────────────────────────────────────────
CREATE TEMP TABLE aa1143_seed ON COMMIT DROP AS
WITH provider_value AS (
    SELECT v.value
      FROM shared.setting_value v
     WHERE v.key = 'cis.spend.connection_provider_budget_usd'
       AND v.tenant_id IS NULL AND v.status = 'approved' AND v.effective_from <= now()
     ORDER BY v.effective_from DESC, v.version DESC
     LIMIT 1
), provider AS (
    SELECT e.key AS connection_key,
           CASE WHEN jsonb_typeof(e.value) = 'number' THEN (e.value #>> '{}')::numeric
                WHEN jsonb_typeof(e.value) = 'string' AND (e.value #>> '{}') ~ '^[0-9]{1,7}(\.[0-9]{1,6})?$'
                    THEN (e.value #>> '{}')::numeric END AS usd
      FROM provider_value p
     CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(p.value) = 'object' THEN p.value ELSE '{}'::jsonb END) e
)
SELECT c.connection_key,
       c.monthly_budget_usd                                   AS cis_before,
       round(p.usd, 2)                                        AS provider_usd
  FROM shared.llm_provider_connection c
  LEFT JOIN provider p ON p.connection_key = c.connection_key AND p.usd IS NOT NULL AND p.usd <= 1000000
 WHERE NOT EXISTS (SELECT 1 FROM shared.llm_connection_budget)
   AND (c.monthly_budget_usd IS NOT NULL OR (p.usd IS NOT NULL AND p.usd <= 1000000));

INSERT INTO shared.llm_connection_budget (connection_key, app, budget_usd, version, reason, actor)
SELECT s.connection_key, NULL, coalesce(s.provider_usd, s.cis_before), 1,
       'Seeded at migration 456: the provider budget setting, else the CIS monthly budget of the connection',
       'migration:456'
  FROM aa1143_seed s
ON CONFLICT ON CONSTRAINT llm_connection_budget_version_key DO NOTHING;

INSERT INTO shared.llm_connection_budget (connection_key, app, budget_usd, version, reason, actor)
SELECT s.connection_key, 'crm', s.provider_usd - s.cis_before, 1,
       'Seeded at migration 456: provider budget minus the CIS monthly budget, the share the CRM was given by hand',
       'migration:456'
  FROM aa1143_seed s
 WHERE s.provider_usd IS NOT NULL AND s.cis_before IS NOT NULL AND s.provider_usd > s.cis_before
   AND EXISTS (SELECT 1 FROM shared.llm_app_profile a WHERE a.app = 'crm')
ON CONFLICT ON CONSTRAINT llm_connection_budget_version_key DO NOTHING;

-- 455's apply trigger ran after each INSERT statement: the CIS caps are the remainders now. The check:
DO $$
DECLARE
    r record;
    bad text;
BEGIN
    FOR r IN
        SELECT s.connection_key, s.cis_before, s.provider_usd, t.budget_usd AS total_usd, crm.budget_usd AS crm_usd,
               c.monthly_budget_usd AS cis_after,
               CASE WHEN s.cis_before IS NULL THEN s.provider_usd
                    ELSE least(s.cis_before, coalesce(s.provider_usd, s.cis_before)) END AS cis_expected
          FROM aa1143_seed s
          JOIN shared.llm_provider_connection c USING (connection_key)
          LEFT JOIN shared.llm_connection_budget_current t ON t.connection_key = s.connection_key AND t.app IS NULL
          LEFT JOIN shared.llm_connection_budget_current crm ON crm.connection_key = s.connection_key AND crm.app = 'crm'
         ORDER BY s.connection_key
    LOOP
        RAISE NOTICE 'migration 456: % total % (provider %, CIS before %), crm %, CIS remainder %',
            r.connection_key, r.total_usd, coalesce(r.provider_usd::text, 'unset'), coalesce(r.cis_before::text, 'none'),
            coalesce(r.crm_usd::text, 'none'), r.cis_after;
        IF r.total_usd IS DISTINCT FROM coalesce(r.provider_usd, r.cis_before) THEN
            bad := concat_ws('; ', bad, r.connection_key || ': total is not the provider budget');
        END IF;
        IF r.cis_after IS DISTINCT FROM r.cis_expected THEN
            bad := concat_ws('; ', bad, r.connection_key || ': CIS remainder ' || coalesce(r.cis_after::text, 'none')
                                         || ' is not ' || coalesce(r.cis_expected::text, 'none'));
        END IF;
        IF r.cis_after + coalesce(r.crm_usd, 0) > r.total_usd THEN
            bad := concat_ws('; ', bad, r.connection_key || ': shares above the total');
        END IF;
    END LOOP;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 456: the seed does not match today''s values: %', bad;
    END IF;
END $$;

-- ── 2. The v2 cap view (catalog recipe) ──────────────────────────────────────────────────────────────────────────
-- What catalog_owner reads: the rows in force (455's view), and the columns CIS 323 / 347 / 452 granted already (the
-- same grants repeated, so this file stands on its own; a re-grant changes nothing on Dev).
GRANT SELECT ON shared.llm_connection_budget_current TO catalog_owner;
GRANT SELECT (app) ON shared.llm_app_profile TO catalog_owner;
GRANT SELECT (account, app, cost_usd, created_at) ON shared.llm_call_log TO catalog_owner;
GRANT SELECT (connection_key, alert_pct, hard_stop) ON shared.llm_connection_cost_policy TO catalog_owner;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

CREATE OR REPLACE VIEW catalog.v_llm_connection_cap_v2 WITH (security_barrier = true) AS
WITH month AS (
    SELECT date_trunc('month', now() AT TIME ZONE 'utc') AT TIME ZONE 'utc' AS start
), total AS (
    SELECT b.connection_key, b.budget_usd AS total_usd
      FROM shared.llm_connection_budget_current b
     WHERE b.app IS NULL
), share AS (
    SELECT b.connection_key, b.app, b.budget_usd AS share_usd
      FROM shared.llm_connection_budget_current b
     WHERE b.app IS NOT NULL
), remainder AS (
    SELECT t.connection_key, t.total_usd,
           greatest(t.total_usd - coalesce((SELECT sum(s.share_usd) FROM share s
                                             WHERE s.connection_key = t.connection_key), 0), 0) AS cis_usd
      FROM total t
), spent AS (
    SELECT l.account AS connection_key, coalesce(l.app, 'cis') AS app,
           coalesce(sum(l.cost_usd), 0) AS usd, count(*)::integer AS calls
      FROM shared.llm_call_log l, month m
     WHERE l.account IN (SELECT connection_key FROM total)
       AND l.created_at >= m.start
     GROUP BY l.account, coalesce(l.app, 'cis')
), pool AS (
    -- The CIS remainder's spend: every app without its own share, plus what an app with a share spent above it.
    SELECT sp.connection_key,
           sum(CASE WHEN sh.app IS NULL THEN sp.usd ELSE greatest(sp.usd - sh.share_usd, 0) END) AS usd
      FROM spent sp
      LEFT JOIN share sh ON sh.connection_key = sp.connection_key AND sh.app = sp.app
     GROUP BY sp.connection_key
), apps AS (
    SELECT a.app FROM shared.llm_app_profile a
    UNION
    SELECT 'cis'
), grid AS (
    SELECT r.connection_key, a.app, r.total_usd, r.cis_usd,
           CASE WHEN a.app = 'cis' THEN r.cis_usd ELSE sh.share_usd END        AS share_usd,
           (a.app <> 'cis' AND sh.share_usd IS NULL)                           AS in_cis_pool
      FROM remainder r
     CROSS JOIN apps a
      LEFT JOIN share sh ON sh.connection_key = r.connection_key AND sh.app = a.app
)
SELECT g.connection_key,
       g.app,
       g.total_usd,
       g.share_usd,
       g.in_cis_pool,
       m.start                                                                  AS month_start,
       coalesce(sp.usd, 0)::numeric(14,6)                                       AS month_spent_usd,
       coalesce(sp.calls, 0)                                                    AS month_calls,
       coalesce(pl.usd, 0)::numeric(14,6)                                       AS cis_pool_spent_usd,
       coalesce(p.alert_pct, 80)                                                AS alert_pct,
       coalesce(p.hard_stop, true)                                              AS hard_stop,
       CASE WHEN g.app = 'cis' OR g.in_cis_pool THEN coalesce(pl.usd, 0) >= g.cis_usd
            ELSE coalesce(sp.usd, 0) >= g.share_usd END                         AS over_cap,
       (CASE WHEN g.app = 'cis' OR g.in_cis_pool THEN coalesce(pl.usd, 0) >= g.cis_usd
             ELSE coalesce(sp.usd, 0) >= g.share_usd END
        AND coalesce(p.hard_stop, true))                                        AS stops
  FROM grid g
 CROSS JOIN month m
  LEFT JOIN spent sp ON sp.connection_key = g.connection_key AND sp.app = g.app
  LEFT JOIN pool pl ON pl.connection_key = g.connection_key
  LEFT JOIN shared.llm_connection_cost_policy p ON p.connection_key = g.connection_key;

COMMENT ON VIEW catalog.v_llm_connection_cap_v2 IS
    'AA-1143 (456, decision G3): one row per LLM connection with a total and per app: the app''s share (cis: the '
    'remainder), in_cis_pool (no share of its own: counted inside the CIS remainder), this UTC month''s spend in the '
    'CIS ledger, the CIS remainder''s spend, the connection policy, over_cap and stops. TripPlanner only. The CRM '
    'enforces its share on its own ledger. Contract v2: columns are only appended; a change of meaning is a _v3 view.';

GRANT SELECT ON catalog.v_llm_connection_cap_v2 TO tripplanner;

DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM catalog.v_llm_connection_cap_v2;
    RAISE NOTICE 'migration 456: as catalog_owner, % connection x app row(s)', n;
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Closing check as cis_owner: columns, owner, barrier, exact consumer ──────────────────────────────────────────
DO $$
DECLARE
    v constant text := 'catalog.v_llm_connection_cap_v2';
    r text;
    cols text;
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = v::regclass) <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 456: % is not catalog_owner''s', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v::regclass AND 'security_barrier=true' = ANY(reloptions)) THEN
        RAISE EXCEPTION 'migration 456: % is not security_barrier', v;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tripplanner')
       AND NOT pg_catalog.has_table_privilege('tripplanner', v, 'SELECT') THEN
        RAISE EXCEPTION 'migration 456: tripplanner cannot read %', v;
    END IF;
    FOREACH r IN ARRAY ARRAY['booking', 'aa_app_user', 'cis_app', 'crm_app'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND pg_catalog.has_table_privilege(r, v, 'SELECT') THEN
            RAISE EXCEPTION 'migration 456: % can read % (tripplanner only)', r, v;
        END IF;
    END LOOP;
    FOREACH r IN ARRAY ARRAY['tripplanner', 'crm_app', 'booking'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r)
           AND (pg_catalog.has_table_privilege(r, 'shared.llm_connection_budget', 'SELECT')
                OR pg_catalog.has_table_privilege(r, 'shared.llm_connection_budget_current', 'SELECT')) THEN
            RAISE EXCEPTION 'migration 456: % can read the connection budget rows directly', r;
        END IF;
    END LOOP;
    SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'connection_key,app,total_usd,share_usd,in_cis_pool,month_start,month_spent_usd,'
                             'month_calls,cis_pool_spent_usd,alert_pct,hard_stop,over_cap,stops' THEN
        RAISE EXCEPTION 'migration 456: % columns are %', v, cols;
    END IF;
    IF pg_catalog.has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 456: catalog_owner still has CREATE on schema catalog';
    END IF;
END $$;

-- ── 3. TripPlanner's log-only switch ─────────────────────────────────────────────────────────────────────────────
-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "tripplanner.spend.connection_share_enforce", "app": "tripplanner", "area": "spend", "label": "TripPlanner: stop at its connection budget share", "description": "Whether TripPlanner stops using a model connection once its own monthly share of that connection's budget is used up (AI gateway > Budgets; when TripPlanner has no share there, the CIS remainder it is counted in). false = log only: TripPlanner writes a log line and goes on (the first release of the per-app shares). true = under tripplanner.spend.environment dev the connection is left out of the route and the next one answers; under prod a reached share only alerts. Read by AA-TripPlanner-Web backend/shared/connection_share.py through catalog.v_app_settings_v1 and catalog.v_llm_connection_cap_v2.", "value_type": "bool", "unit": null, "min_value": null, "max_value": null, "allowed_values": null, "default_value": false, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 30, "enforced": true, "guide": {"en": {"what": "Whether TripPlanner stops calling a model connection when its own monthly share of that connection's budget is used up. Off, TripPlanner only logs it; on, it moves to the next connection of the route.", "raise": "On (the stricter choice): TripPlanner can no longer spend past its share, so the connection's total holds for every app; a planner may get a slower or simpler model, or none, near the month end.", "lower": "Off (log only): TripPlanner keeps calling past its share and the connection's total can be exceeded by what TripPlanner spends above it.", "when": "Switch it on once TripPlanner has its own share on AI gateway > Budgets and the log lines show the share fits its real use.", "example": "TripPlanner has 10 USD of acc2 and spent 10 USD this month. With the default off: the next planner request still goes to acc2 and a log line says the share is used up. Switched on: the request goes to the next connection of the route."}, "vi": {"what": "TripPlanner có ngừng gọi một kết nối model khi đã dùng hết phần ngân sách tháng của mình trên kết nối đó hay không. Tắt thì TripPlanner chỉ ghi log; bật thì chuyển sang kết nối kế tiếp của route.", "raise": "Bật (lựa chọn chặt hơn): TripPlanner không còn tiêu vượt phần của mình, nên tổng của kết nối giữ được cho mọi app; gần cuối tháng trang lập kế hoạch có thể dùng model chậm hơn, đơn giản hơn, hoặc không có AI.", "lower": "Tắt (chỉ ghi log): TripPlanner vẫn gọi tiếp khi vượt phần của mình và tổng của kết nối có thể bị vượt đúng bằng phần TripPlanner tiêu thêm.", "when": "Bật khi TripPlanner đã có phần riêng ở AI gateway > Budgets và log cho thấy phần đó vừa với mức dùng thật.", "example": "TripPlanner có 10 USD trên acc2 và tháng này đã tiêu 10 USD. Với mặc định tắt: yêu cầu lập kế hoạch tiếp theo vẫn đi acc2 và log ghi phần đã hết. Khi bật: yêu cầu đi sang kết nối kế tiếp của route."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('456', now(), 'AA-1143: connection budget rows seeded, catalog.v_llm_connection_cap_v2 for TripPlanner, '
                      'TripPlanner connection share switch')
ON CONFLICT (version) DO NOTHING;

COMMIT;
