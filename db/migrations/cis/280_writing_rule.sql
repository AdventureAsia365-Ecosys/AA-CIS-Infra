-- Migration 280: AA-917 (WM-09) — shared.writing_rule, the governed store of learned writing rules (scoped, typed,
-- capped, with provenance and expiry), plus the Model Gateway stage writing_memory_mine and its spend budget.
--
-- Why. App ADR 0010 (governed writing memory): signals (shared.writing_signal, CIS 277) turn into candidate rules
-- through the writing_memory_mine job (WM-12); a rule reaches a writer only inside an approved release (WM-15+).
-- There is no governed rule store today: shared.pipeline_lessons has no scope or tenant and is frozen (AA-915), and
-- acp_shared.acp_output_rules is dead (AA-603). Decisions 3 (rules only constrain), 4 (fact gates outrank rules),
-- 10 (scope and isolation) and 11 (tenant text only in deletable tables) shape this table.
--
-- What.
--   1. shared.writing_rule: rule_id uuid PK; kind lexicon | writer_instruction | repair_hint | preference_summary;
--      scope platform | tenant with tenant_id NULL exactly for platform (the acp_shared.facts / writing_signal
--      pattern); writer a1 | t2 | t9_blog | t9_social; applies_to (channels, at most 8); reason_code (the 8 codes of
--      CIS 277) and gate_class (the qtax-v1 taxonomy class of the gate: the key that survives a gate rename, AA-787);
--      cluster_key (the miner's cluster, one open rule per cluster); rule_text (pii:free_text: a tenant rule is
--      derived from tenant text) and replacement (lexicon "replace" only); match_phrases (at most 5 phrases the rule
--      targets, used by the PREDICT check and the R0 replay); token_estimate (generated: ceil(chars / 4) of the text
--      and the replacement); status candidate | rejected | approved | active | expired; provenance: signal_ids and the
--      support counts (signals, pieces, tenants, reviewers), lint (the lint / PREDICT result object), drafted_by (the
--      model), mine_job_id; expires_at (default now() + 60 days); approved_by / approved_at, rejected_by /
--      rejected_reason; created_at / updated_at.
--      Row CHECKs: one rule <= 25 words (a preference_summary <= 5 sentences and <= 125 words, tenant scope only);
--      a replacement only on a lexicon rule; approved / active only with approved_by and approved_at (nothing
--      auto-activates, decision 1); a platform rule drawn from tenant evidence needs >= 3 distinct tenants (D9) and a
--      tenant rule names at most its own tenant; support counts >= 0.
--      Indexes: one open rule (candidate / approved / active) per (writer, scope, tenant, cluster_key) — re-mining a
--      cluster is idempotent; (tenant_id, status) WHERE scope = 'tenant' (erasure, per-tenant reads); (writer,
--      status).
--   2. Token caps at write (WM-09 scope 2), an AFTER INSERT OR UPDATE row trigger
--      (shared.writing_rule_token_cap): the approved + active rules of one writer may hold at most 400 tokens for the
--      platform and 250 tokens per tenant. It takes a transaction advisory lock per (writer, scope, tenant) first, so
--      two concurrent approvals cannot both pass under the cap.
--   3. RLS ENABLE + FORCE (ADR 0010 decision 10):
--        writing_rule_cis_app_all   TO cis_app   USING (true) WITH CHECK (true)  X1 parity (CIS 244): the runtime (the
--                                   miner, the admin routes, later the writers) filters tenant_id in code;
--        writing_rule_cis_owner_all TO cis_owner USING (true) WITH CHECK (true)  X1 S21 (CIS 245) standing check;
--        tenant_isolation           TO aa_app_user, scope = 'tenant' AND tenant_id = NULLIF(app.tenant_id, '')::uuid:
--                                   rls_catalogue rule a (a tenant_id table needs an app.tenant_id policy); the tenant
--                                   pool gets no privilege on the table (tenants never see rules, ADR 0010 / D7).
--   4. Grants. REVOKE ALL from PUBLIC, cis_app, aa_app_user and catalog_owner first (it removes the DML the Dev
--      default ACL of cis_owner gives cis_app on every new table in shared, CIS 245), then cis_app SELECT, INSERT,
--      UPDATE, DELETE (DELETE: the AA-839 tenant erasure). Nothing for aa_app_user or catalog_owner. EXECUTE on the
--      trigger function is revoked from PUBLIC (a trigger does not need it at fire time).
--   5. Stage key writing_memory_mine (WM-12 rule drafter) in shared.llm_role_config: role judge (ADR 0010 decision 5,
--      ADR 0006 §5: rule drafting runs on the non-Anthropic judge route), the judge route of migration 224 —
--      gpt-5.6-luna on acc3, then gpt-6-luna, then gpt-6-luna-openai last — no shadow. WM-13 may reorder it after its
--      agreement check. Spend budget bedrock / job:writing_memory_mine: $1.00 a run, $2.00 a day, hard stop (the
--      $25 calendar-month cap of E4 is checked in code over the writing-memory stages of llm_call_log). Both ON
--      CONFLICT DO NOTHING: an admin change is never overwritten.
--   6. Register 280.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before: the roles exist; aa_app_user is not superuser / BYPASSRLS; the runner may create in shared;
--      shared.writing_signal (277) exists; the table, if present, has exactly this file's columns (re-run);
--   2. after: every named constraint validated; the three indexes; the trigger; RLS on AND forced; exactly the three
--      policies with this file's commands, roles and expressions; privileges exactly as in point 4, no column grants;
--      the AA-859 invariant v3; the stage row and the budget row exist;
--   3. behaviour (a sub-block that always rolls back): a platform and a tenant candidate insert and read back; a
--      platform rule with a tenant_id, a tenant rule without one, a 26-word rule, a replacement on a non-lexicon rule,
--      an approval without approver and a platform rule from 2 tenants are refused (check_violation); approving
--      rules over the platform cap (400 tokens) and the tenant cap (250 tokens) is refused (check_violation from the
--      trigger), the same rules as candidates are not.
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: NULL, 0, the 277 row):
--   SELECT to_regclass('shared.writing_rule') AS writing_rule,
--          (SELECT count(*) FROM shared.llm_role_config WHERE stage = 'writing_memory_mine') AS stage_rows,
--          (SELECT version FROM shared.schema_versions WHERE version = '277') AS signal_store;
--
-- Locks. CREATE TABLE / INDEX / POLICY / TRIGGER on a new, empty table; two INSERTs into small config tables.
-- lock_timeout 5s. Apply through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/) with shared.job and
-- booking.job idle (DM-11.4), after 279 (keys in order: the readiness check compares max(version)). Re-running is a
-- no-op apart from the guards (IF NOT EXISTS, CREATE OR REPLACE, DROP POLICY / TRIGGER IF EXISTS + CREATE, grants
-- from nothing, ON CONFLICT DO NOTHING).
--
-- Order with the code. Nothing reads or writes the table until the AA-917 code PR (services/writing_memory: the
-- backfill, the fact filter and the writing_memory_mine job; /admin/writing-memory) deploys, and that code needs it:
-- merge this file's PR, copy to Infra, DB Migrate check -> apply, merge the schema-reference bot PR, then merge and
-- deploy the code PR. The erasure inventory row (AA-839) ships with this file's PR: the planner reports a registered
-- table that is not applied yet as missing and skips it.
--
-- Undo (a NEW forward migration, after reverting the code that writes it):
--   DROP TABLE shared.writing_rule;                            -- -- migrate: destructive (MIG-9)
--   DROP FUNCTION shared.writing_rule_token_cap();
--   DELETE FROM shared.llm_role_config WHERE stage = 'writing_memory_mine';
--   DELETE FROM shared.spend_budget WHERE provider = 'bedrock' AND scope = 'job:writing_memory_mine';
--
-- X1. One BEGIN … COMMIT block, no role switch (role lint from 243). DB Migrate runs cis/ files as cis_owner, the owner
-- of shared (245), which then owns the table and the function.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Guard 1: roles, runner rights, the signal store, re-run shape ──────────────────────────────────────────────────
DO $$
DECLARE
    owner_ns name;
    cols     text;
    expect   text := 'rule_id uuid, kind text, scope text, tenant_id uuid, writer text, applies_to text[], '
                     'reason_code text, gate_class text, cluster_key text, rule_text text, replacement text, '
                     'match_phrases text[], token_estimate integer, status text, signal_ids uuid[], '
                     'support_signals integer, support_pieces integer, support_tenants integer, '
                     'support_reviewers integer, lint jsonb, drafted_by text, mine_job_id uuid, '
                     'expires_at timestamp with time zone, approved_by text, approved_at timestamp with time zone, '
                     'rejected_by text, rejected_reason text, created_at timestamp with time zone, '
                     'updated_at timestamp with time zone';
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL OR to_regrole('cis_owner') IS NULL
       OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 280: roles cis_app, aa_app_user, cis_owner and catalog_owner must exist';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aa_app_user' AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'migration 280: aa_app_user is superuser or BYPASSRLS: RLS would not apply to it';
    END IF;
    SELECT pg_get_userbyid(n.nspowner) INTO owner_ns FROM pg_namespace n WHERE n.nspname = 'shared';
    IF NOT has_schema_privilege(current_user, 'shared', 'CREATE') THEN
        RAISE EXCEPTION 'migration 280: % may not create in shared (owner %); run it through DB Migrate (cis_owner)',
                        current_user, owner_ns;
    END IF;
    IF to_regclass('shared.writing_signal') IS NULL THEN
        RAISE EXCEPTION 'migration 280: shared.writing_signal (CIS 277) is missing; apply 277 first';
    END IF;
    IF to_regclass('shared.writing_rule') IS NOT NULL THEN
        SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          INTO cols
          FROM pg_attribute a
         WHERE a.attrelid = 'shared.writing_rule'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        IF cols IS DISTINCT FROM expect THEN
            RAISE EXCEPTION 'migration 280: shared.writing_rule exists with other columns: %', cols;
        END IF;
    END IF;
END $$;

-- ── 1. The rule store ──────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.writing_rule (
    rule_id           uuid NOT NULL DEFAULT gen_random_uuid(),
    kind              text NOT NULL,
    scope             text NOT NULL,
    tenant_id         uuid,
    writer            text NOT NULL,
    applies_to        text[] NOT NULL DEFAULT '{}'::text[],
    reason_code       text,
    gate_class        text,
    cluster_key       text NOT NULL,
    rule_text         text NOT NULL,
    replacement       text,
    match_phrases     text[] NOT NULL DEFAULT '{}'::text[],
    token_estimate    integer GENERATED ALWAYS AS
                          (ceil((char_length(rule_text) + coalesce(char_length(replacement), 0)) / 4.0)::integer)
                          STORED,
    status            text NOT NULL DEFAULT 'candidate',
    signal_ids        uuid[] NOT NULL DEFAULT '{}'::uuid[],
    support_signals   integer NOT NULL DEFAULT 0,
    support_pieces    integer NOT NULL DEFAULT 0,
    support_tenants   integer NOT NULL DEFAULT 0,
    support_reviewers integer NOT NULL DEFAULT 0,
    lint              jsonb NOT NULL DEFAULT '{}'::jsonb,
    drafted_by        text,
    mine_job_id       uuid,
    expires_at        timestamp with time zone NOT NULL DEFAULT (now() + interval '60 days'),
    approved_by       text,
    approved_at       timestamp with time zone,
    rejected_by       text,
    rejected_reason   text,
    created_at        timestamp with time zone NOT NULL DEFAULT now(),
    updated_at        timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT writing_rule_pkey PRIMARY KEY (rule_id),
    CONSTRAINT writing_rule_kind_check
        CHECK (kind IN ('lexicon', 'writer_instruction', 'repair_hint', 'preference_summary')),
    CONSTRAINT writing_rule_scope_check CHECK (scope IN ('platform', 'tenant')),
    CONSTRAINT writing_rule_scope_tenant_ck
        CHECK ((scope = 'platform' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)),
    CONSTRAINT writing_rule_writer_check CHECK (writer IN ('a1', 't2', 't9_blog', 't9_social')),
    CONSTRAINT writing_rule_reason_code_check
        CHECK (reason_code IS NULL
               OR reason_code IN ('fact_not_in_source', 'optional_as_included', 'wrong_place_or_time',
                                  'voice_off_brand', 'ai_phrasing', 'format_channel', 'repair_residue', 'style_only')),
    CONSTRAINT writing_rule_status_check
        CHECK (status IN ('candidate', 'rejected', 'approved', 'active', 'expired')),
    CONSTRAINT writing_rule_approval_check
        CHECK (status NOT IN ('approved', 'active') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
    CONSTRAINT writing_rule_replacement_check CHECK (replacement IS NULL OR kind = 'lexicon'),
    CONSTRAINT writing_rule_summary_scope_check CHECK (kind <> 'preference_summary' OR scope = 'tenant'),
    CONSTRAINT writing_rule_words_check
        CHECK (char_length(btrim(rule_text)) > 0
               AND CASE WHEN kind = 'preference_summary'
                        THEN array_length(regexp_split_to_array(btrim(rule_text), '\s+'), 1) <= 125
                             AND char_length(regexp_replace(regexp_replace(btrim(rule_text), '[.!?]+', '.', 'g'),
                                                            '[^.]', '', 'g')) <= 5
                        ELSE array_length(regexp_split_to_array(btrim(rule_text), '\s+'), 1) <= 25 END),
    CONSTRAINT writing_rule_support_check
        CHECK (support_signals >= 0 AND support_pieces >= 0 AND support_tenants >= 0 AND support_reviewers >= 0
               AND (scope = 'tenant' OR support_tenants = 0 OR support_tenants >= 3)
               AND (scope = 'platform' OR support_tenants <= 1)),
    CONSTRAINT writing_rule_size_check
        CHECK (char_length(rule_text) <= 1000 AND coalesce(char_length(replacement), 0) <= 200
               AND char_length(cluster_key) BETWEEN 1 AND 200 AND coalesce(char_length(gate_class), 0) <= 128
               AND cardinality(applies_to) <= 8 AND cardinality(match_phrases) <= 5
               AND char_length(array_to_string(match_phrases, '')) <= 400
               AND cardinality(signal_ids) <= 500 AND coalesce(char_length(drafted_by), 0) <= 128
               AND coalesce(char_length(approved_by), 0) <= 128 AND coalesce(char_length(rejected_by), 0) <= 128
               AND coalesce(char_length(rejected_reason), 0) <= 500),
    CONSTRAINT writing_rule_lint_check CHECK (jsonb_typeof(lint) = 'object')
);

CREATE UNIQUE INDEX IF NOT EXISTS writing_rule_open_cluster_uq
    ON shared.writing_rule (writer, scope, coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid),
                            cluster_key)
    WHERE status IN ('candidate', 'approved', 'active');
CREATE INDEX IF NOT EXISTS writing_rule_tenant_status_idx
    ON shared.writing_rule (tenant_id, status) WHERE scope = 'tenant';
CREATE INDEX IF NOT EXISTS writing_rule_writer_status_idx ON shared.writing_rule (writer, status);

COMMENT ON TABLE shared.writing_rule IS
    'AA-917 WM-09 (CIS 280, app ADR 0010): learned writing rules (lexicon, writer_instruction, repair_hint, '
    'preference_summary) of the A1 / T2 / T9 writers, platform or tenant scope, with provenance (writing_signal ids, '
    'support counts), lint result and expiry. Mined by the writing_memory_mine job; reach a writer only through an '
    'approved release. Approved + active rules capped at 400 tokens per writer (platform) and 250 per tenant '
    '(trigger writing_rule_token_cap). RLS ENABLE + FORCE: cis_app filters tenant_id in code; the tenant pool has no '
    'privilege. Tenant rows go with the tenant (AA-839 erasure inventory).';
COMMENT ON COLUMN shared.writing_rule.rule_text IS
    'pii:free_text; AA-917 (280): the rule (one constraint, <= 25 words; a preference_summary <= 5 sentences). A '
    'tenant rule is derived from that tenant''s text and is deleted with the tenant; a platform rule never holds '
    'tenant text (5-gram overlap lint, ADR 0010 decision 10).';
COMMENT ON COLUMN shared.writing_rule.replacement IS
    'pii:free_text; AA-917 (280): the replacement of a lexicon "replace" rule (NULL = ban). Checked with new_specifics: '
    'it may add no number, place, time, price or service (ADR 0010 decision 3).';
COMMENT ON COLUMN shared.writing_rule.gate_class IS
    'AA-917 (280): the qtax-v1 taxonomy class of the gate the rule targets (services/quality/taxonomy.yaml); the key '
    'that survives a gate rename (AA-787), with reason_code.';
COMMENT ON COLUMN shared.writing_rule.cluster_key IS
    'AA-917 (280): the miner''s cluster (writer, scope, reason / class); one open rule per cluster.';
COMMENT ON COLUMN shared.writing_rule.match_phrases IS
    'pii:free_text; AA-917 (280): at most 5 (entity-masked) phrases the rule targets: the PREDICT check counts the '
    'held-out edits that remove one, the R0 replay counts how often one appears.';
COMMENT ON COLUMN shared.writing_rule.signal_ids IS
    'AA-917 (280): provenance, the shared.writing_signal ids of the cluster (ids only; no FK, the erasure order stays '
    'free).';
COMMENT ON COLUMN shared.writing_rule.support_tenants IS
    'AA-917 (280): distinct tenants of the evidence. A platform rule drawn from tenant evidence needs >= 3 (D9); 0 = '
    'platform (A1) evidence only.';
COMMENT ON COLUMN shared.writing_rule.lint IS
    'AA-917 (280): the lint result: constraint_only, lexicon_new_specifics, five_gram_overlap, predict (explained / '
    'held_out), each {ok, detail}.';
COMMENT ON COLUMN shared.writing_rule.approved_by IS
    'AA-917 (280): the shared.admin_users id of the human who approved the rule (never a job label: nothing '
    'auto-activates, ADR 0010 decision 1).';

-- ── 2. Token caps at write ─────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION shared.writing_rule_token_cap() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    cap   integer := CASE WHEN NEW.scope = 'platform' THEN 400 ELSE 250 END;
    total integer;
BEGIN
    IF NEW.status NOT IN ('approved', 'active') THEN
        RETURN NULL;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'shared.writing_rule:' || NEW.writer || ':' || NEW.scope || ':' || coalesce(NEW.tenant_id::text, '-'), 280));
    SELECT coalesce(sum(r.token_estimate), 0) INTO total
      FROM shared.writing_rule r
     WHERE r.writer = NEW.writer AND r.scope = NEW.scope AND r.tenant_id IS NOT DISTINCT FROM NEW.tenant_id
       AND r.status IN ('approved', 'active');
    IF total > cap THEN
        RAISE EXCEPTION 'shared.writing_rule: the approved and active % rules of writer % would hold % tokens, over '
                        'the cap of % (AA-917 WM-09)', NEW.scope, NEW.writer, total, cap
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$fn$;
REVOKE ALL ON FUNCTION shared.writing_rule_token_cap() FROM PUBLIC;
COMMENT ON FUNCTION shared.writing_rule_token_cap() IS
    'AA-917 WM-09 (CIS 280): AFTER INSERT OR UPDATE row trigger of shared.writing_rule; the approved + active rules of '
    'one writer hold <= 400 tokens (platform) or <= 250 tokens (per tenant); advisory lock per writer / scope / tenant.';

DROP TRIGGER IF EXISTS writing_rule_token_cap ON shared.writing_rule;
CREATE TRIGGER writing_rule_token_cap
    AFTER INSERT OR UPDATE ON shared.writing_rule
    FOR EACH ROW EXECUTE FUNCTION shared.writing_rule_token_cap();

-- ── 3. RLS ─────────────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE shared.writing_rule ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared.writing_rule FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS writing_rule_cis_app_all ON shared.writing_rule;
CREATE POLICY writing_rule_cis_app_all ON shared.writing_rule AS PERMISSIVE FOR ALL TO cis_app
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS writing_rule_cis_owner_all ON shared.writing_rule;
CREATE POLICY writing_rule_cis_owner_all ON shared.writing_rule AS PERMISSIVE FOR ALL TO cis_owner
    USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS tenant_isolation ON shared.writing_rule;
CREATE POLICY tenant_isolation ON shared.writing_rule AS PERMISSIVE FOR ALL TO aa_app_user
    USING (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (scope = 'tenant' AND tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON shared.writing_rule IS
    'AA-917 (CIS 280): own tenant rows only, never a platform row; the tenant pool holds no privilege on the table '
    'today (tenants never see rules), the policy is the floor if one is ever granted.';

-- ── 4. Grants ──────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON shared.writing_rule FROM PUBLIC;
REVOKE ALL ON shared.writing_rule FROM cis_app, aa_app_user, catalog_owner;   -- also column grants: from nothing
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.writing_rule TO cis_app;

-- ── 5. Stage key and spend budget ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
VALUES
    ('writing_memory_mine', 'judge', 'openai', 'gpt-5.6-luna', 'acc3', true,
     ARRAY['gpt-6-luna', 'gpt-6-luna-openai']::text[], NULL, 0, 'migration-280-aa917')
ON CONFLICT (stage) DO NOTHING;

INSERT INTO shared.spend_budget (provider, scope, per_run_usd, per_day_usd, hard_stop, updated_by)
VALUES ('bedrock', 'job:writing_memory_mine', 1.00, 2.00, true, 'migration-280-aa917')
ON CONFLICT (provider, scope) DO NOTHING;

-- ── Guard 2: constraints, indexes, trigger, RLS, policies, privileges, AA-859 invariant, config rows ─────────────
DO $$
DECLARE
    tbl     oid := 'shared.writing_rule'::regclass;
    missing text;
    pols    text;
    privs   text;
    bad     text;
BEGIN
    SELECT string_agg(want, ', ' ORDER BY want) INTO missing
      FROM unnest(ARRAY['writing_rule_pkey', 'writing_rule_kind_check', 'writing_rule_scope_check',
                        'writing_rule_scope_tenant_ck', 'writing_rule_writer_check', 'writing_rule_reason_code_check',
                        'writing_rule_status_check', 'writing_rule_approval_check', 'writing_rule_replacement_check',
                        'writing_rule_summary_scope_check', 'writing_rule_words_check', 'writing_rule_support_check',
                        'writing_rule_size_check', 'writing_rule_lint_check']) AS want
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = tbl AND c.conname = want AND c.convalidated);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 280: constraints missing or not validated: %', missing;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                    WHERE x.indrelid = tbl AND c.relname = 'writing_rule_open_cluster_uq' AND x.indisunique
                      AND pg_get_expr(x.indpred, x.indrelid) LIKE '%candidate%approved%active%')
       OR NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                       WHERE x.indrelid = tbl AND c.relname = 'writing_rule_tenant_status_idx'
                         AND pg_get_expr(x.indpred, x.indrelid) = '(scope = ''tenant''::text)')
       OR NOT EXISTS (SELECT 1 FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
                       WHERE x.indrelid = tbl AND c.relname = 'writing_rule_writer_status_idx') THEN
        RAISE EXCEPTION 'migration 280: the indexes are missing or not as this file defines them';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                    WHERE t.tgrelid = tbl AND t.tgname = 'writing_rule_token_cap' AND NOT t.tgisinternal
                      AND t.tgfoid = 'shared.writing_rule_token_cap()'::regprocedure
                      AND t.tgenabled = 'O') THEN
        RAISE EXCEPTION 'migration 280: trigger writing_rule_token_cap missing or disabled';
    END IF;

    IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = tbl) THEN
        RAISE EXCEPTION 'migration 280: shared.writing_rule RLS is not on and forced (ADR 0010 decision 10)';
    END IF;
    SELECT string_agg(p.polname || ':' || CASE WHEN p.polpermissive THEN 'permissive' ELSE 'restrictive' END || ':'
                      || p.polcmd::text || ':'
                      || array_to_string(ARRAY(SELECT pg_get_userbyid(r) FROM unnest(p.polroles) r ORDER BY 1), ',')
                      || ':' || pg_get_expr(p.polqual, p.polrelid) || ':' || pg_get_expr(p.polwithcheck, p.polrelid),
                      ' | ' ORDER BY p.polname)
      INTO pols FROM pg_policy p WHERE p.polrelid = tbl;
    IF pols IS DISTINCT FROM
         'tenant_isolation:permissive:*:aa_app_user:'
         || '((scope = ''tenant''::text) AND (tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, true), '
         || '''''::text))::uuid)):'
         || '((scope = ''tenant''::text) AND (tenant_id = (NULLIF(current_setting(''app.tenant_id''::text, true), '
         || '''''::text))::uuid))'
         || ' | writing_rule_cis_app_all:permissive:*:cis_app:true:true'
         || ' | writing_rule_cis_owner_all:permissive:*:cis_owner:true:true' THEN
        RAISE EXCEPTION 'migration 280: unexpected policies on shared.writing_rule: %', pols;
    END IF;

    SELECT string_agg(r || ':' || p, ', ' ORDER BY r COLLATE "C", p COLLATE "C") INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r, a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid = tbl
           AND (a.grantee = 0 OR a.grantee IN ('cis_app'::regrole, 'aa_app_user'::regrole,
                                               'catalog_owner'::regrole))) x;
    IF privs IS DISTINCT FROM 'cis_app:DELETE, cis_app:INSERT, cis_app:SELECT, cis_app:UPDATE' THEN
        RAISE EXCEPTION 'migration 280: unexpected privileges on shared.writing_rule: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = tbl AND a.attacl IS NOT NULL) THEN
        RAISE EXCEPTION 'migration 280: column-level grants on shared.writing_rule';
    END IF;
    IF has_function_privilege('public', 'shared.writing_rule_token_cap()', 'EXECUTE') THEN
        RAISE EXCEPTION 'migration 280: PUBLIC may execute shared.writing_rule_token_cap()';
    END IF;

    -- the AA-859 invariant, version 3 (same text as 277 guard 2 / NO_PRIVILEGE_WITHOUT_RLS_SQL_V3)
    SELECT string_agg(rel || ' ' || privilege_type || COALESCE('(' || column_name || ')', ''), ', ') INTO bad FROM (
SELECT c.oid::regclass::text AS rel, a.privilege_type, NULL::text AS column_name
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
 CROSS JOIN LATERAL aclexplode(c.relacl) a
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT c.relrowsecurity
   AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ns.nspname NOT LIKE 'pg_toast%'
   AND a.grantee = 'aa_app_user'::regrole
   AND NOT (ns.nspname = 'catalog'
            AND c.relowner IS NOT DISTINCT FROM to_regrole('catalog_owner')
            AND a.privilege_type = 'SELECT')
   AND NOT (ns.nspname || '.' || c.relname = ANY (ARRAY['acp_contract.route', 'acp_contract.atom_segment',
                                                        'acp_contract.atom_segment_member',
                                                        'acp_contract.atom_segment_alias',
                                                        'acp_shared.place_card_alias', 'acp_shared.atom_place_card',
                                                        'gold_aa_internal.v_tour_liveness'])
            AND a.privilege_type = 'SELECT')
UNION ALL
SELECT c.oid::regclass::text, a.privilege_type, att.attname::text
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  JOIN pg_attribute att ON att.attrelid = c.oid AND att.attacl IS NOT NULL AND NOT att.attisdropped
 CROSS JOIN LATERAL aclexplode(att.attacl) a
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT c.relrowsecurity
   AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ns.nspname NOT LIKE 'pg_toast%'
   AND a.grantee = 'aa_app_user'::regrole
   AND NOT (ns.nspname || '.' || c.relname = 'acp_shared.place_card'
            AND att.attname IN ('card_id', 'status')
            AND a.privilege_type = 'SELECT')
ORDER BY 1, 3, 2
    ) v;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 280: aa_app_user holds privileges on relations without RLS: % (AA-859 invariant v3)',
            bad;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM shared.llm_role_config WHERE stage = 'writing_memory_mine' AND role = 'judge') THEN
        RAISE EXCEPTION 'migration 280: stage row writing_memory_mine missing or not judge';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.spend_budget WHERE provider = 'bedrock' AND scope = 'job:writing_memory_mine')
    THEN
        RAISE EXCEPTION 'migration 280: spend budget bedrock / job:writing_memory_mine missing';
    END IF;
END $$;

-- ── Guard 3: behaviour (a sub-block that always rolls back) ────────────────────────────────────────────────────────
DO $$
DECLARE
    probe   uuid := gen_random_uuid();
    n       bigint;
    refused boolean;
    bad     text;
    i       integer;
BEGIN
    BEGIN
        INSERT INTO shared.writing_rule (kind, scope, tenant_id, writer, cluster_key, rule_text)
        VALUES ('writer_instruction', 'platform', NULL, 'a1', 'migration-280-probe', 'Cut stock openers.'),
               ('lexicon', 'tenant', probe, 't9_blog', 'migration-280-probe', 'nestled');
        SELECT count(*) INTO n FROM shared.writing_rule WHERE cluster_key = 'migration-280-probe';
        IF n <> 2 THEN
            RAISE EXCEPTION 'migration 280: the runner reads % of its 2 probe rows (FORCE RLS without its policy?)', n;
        END IF;

        FOREACH bad IN ARRAY ARRAY[
            $q$('writer_instruction', 'platform', gen_random_uuid(), 'x', NULL, 'candidate', NULL, 0)$q$,  -- platform + tenant
            $q$('writer_instruction', 'tenant', NULL, 'x', NULL, 'candidate', NULL, 0)$q$,                 -- tenant, none
            $q$('writer_instruction', 'platform', NULL, repeat('w ', 26), NULL, 'candidate', NULL, 0)$q$,   -- 26 words
            $q$('writer_instruction', 'platform', NULL, 'x', 'y', 'candidate', NULL, 0)$q$,                -- replacement
            $q$('writer_instruction', 'platform', NULL, 'x', NULL, 'approved', NULL, 0)$q$,                -- no approver
            $q$('writer_instruction', 'platform', NULL, 'x', NULL, 'candidate', NULL, 2)$q$,               -- 2 tenants
            $q$('preference_summary', 'platform', NULL, 'x', NULL, 'candidate', NULL, 0)$q$]               -- summary
        LOOP
            refused := false;
            BEGIN
                EXECUTE 'INSERT INTO shared.writing_rule (kind, scope, tenant_id, writer, cluster_key, rule_text, '
                        'replacement, status, approved_by, support_tenants) '
                        'SELECT k, s, t::uuid, ''a1'', ''migration-280-refused'', r, rp, st, ab, nt FROM (VALUES '
                        || bad || ') v(k, s, t, r, rp, st, ab, nt)';
            EXCEPTION WHEN check_violation THEN refused := true;
            END;
            IF NOT refused THEN
                RAISE EXCEPTION 'migration 280: the CHECKs accepted %', bad;
            END IF;
        END LOOP;

        -- the caps: 12 approved platform rules of 25 words (~ 40 tokens each) exceed 400 tokens; as candidates they
        -- do not count; a 6th approved tenant rule of the same size exceeds 250 (5 x 44 = 220, 6 x 44 = 264)
        FOR i IN 1..12 LOOP
            INSERT INTO shared.writing_rule (kind, scope, writer, cluster_key, rule_text)
            VALUES ('writer_instruction', 'platform', 't9_social', 'migration-280-cap-' || i,
                    rtrim(repeat('abcdef ', 25)));
        END LOOP;
        refused := false;
        BEGIN
            UPDATE shared.writing_rule SET status = 'approved', approved_by = 'migration-280-probe', approved_at = now()
             WHERE cluster_key LIKE 'migration-280-cap-%' AND scope = 'platform';
        EXCEPTION WHEN check_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 280: approving 12 platform rules over 400 tokens was accepted';
        END IF;
        FOR i IN 1..6 LOOP
            INSERT INTO shared.writing_rule (kind, scope, tenant_id, writer, cluster_key, rule_text, status,
                                             approved_by, approved_at)
            VALUES ('writer_instruction', 'tenant', probe, 't9_social', 'migration-280-tcap-' || i,
                    rtrim(repeat('abcdef ', 25)), CASE WHEN i < 6 THEN 'approved' ELSE 'candidate' END,
                    'migration-280-probe', now());
        END LOOP;
        refused := false;
        BEGIN
            UPDATE shared.writing_rule SET status = 'approved'
             WHERE cluster_key = 'migration-280-tcap-6';
        EXCEPTION WHEN check_violation THEN refused := true;
        END;
        IF NOT refused THEN
            RAISE EXCEPTION 'migration 280: approving a 6th tenant rule over 250 tokens was accepted';
        END IF;

        RAISE EXCEPTION 'probe done' USING ERRCODE = 'ZZ280';
    EXCEPTION WHEN SQLSTATE 'ZZ280' THEN
        NULL;
    END;
    IF EXISTS (SELECT 1 FROM shared.writing_rule WHERE cluster_key LIKE 'migration-280-%') THEN
        RAISE EXCEPTION 'migration 280: the behaviour probe was not rolled back';
    END IF;
    SELECT count(*) INTO n FROM shared.writing_rule;
    RAISE NOTICE 'migration 280: shared.writing_rule under RLS (forced), % rows', n;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('280', now(), 'AA-917 WM-09: shared.writing_rule, scoped learned writing rules with token caps, RLS forced; '
                      'llm_role_config writing_memory_mine (judge route), spend budget job:writing_memory_mine')
ON CONFLICT (version) DO NOTHING;

COMMIT;
