-- Migration crm-048: AA-1066 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-travel-plugin-
-- comparison.md, items crm-05 / crm-06 / crm-07) — retail pricing in the proposal builder: a price per traveller type
-- on an option, the agency's own retail price rules (season, group size, early booking, last minute), and a proposal
-- discount that needs the agency owner's approval above a limit.
--
-- Owner: AA-Partner (api/migrations/048_crm_retail_pricing.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-048: crm-047 is the highest on main; if main moves, renumber: file
-- name, this header, the guards and the registration below, app/db.py REQUIRED_SCHEMA_VERSIONS.
--
-- What:
--   1. crm.tenant_settings (three columns, owner-set in Settings > Pricing): child_age_max (default 11) and
--      infant_age_max (default 1), the agency's own age bands for retail prices (a traveller up to infant_age_max is an
--      infant, up to child_age_max a child, older an adult; AA's Booking quote keeps AA's own rule, infants under 2);
--      discount_owner_limit_pct (default 10): a proposal discount above it needs the owner's approval.
--   2. crm.proposal.discount_pct (NULL = no discount, else 0.01 to 100 with two decimals): a discount on the charged
--      total of a builder version (pay-on-arrival items are never discounted); the amounts, the deposit and the price
--      hash follow it. Sealed with the other money columns once the version leaves draft: crm.proposal_sealed is
--      recreated with the crm-019 column list plus discount_pct (CRM31), so no write path can change the discount of a
--      published, sent or accepted version.
--   3. crm.option.price_rules (NULL, else a JSON array of at most 20 {rule_id, name, adjust_pct} objects, at most
--      4 KB): the agency price rules the option's sell was suggested with, copied when the agent used the suggestion
--      (a snapshot: a later rename or delete of a rule does not change it).
--   4. crm.option_price (base template): one row per traveller type of an option (adult | child | infant |
--      single_supp): unit sell, unit net (agency items only; an AA item's net is the quote's), quantity. With rows the
--      option's sell is their sum (the API writes both in one transaction). Changes only while its proposal is a draft
--      (crm.guard_proposal_draft, CRM35). Cascades from its option (ON DELETE CASCADE on (tenant_id, proposal_id,
--      option_id)), so a deleted option, block, day, trip or agency takes its rows along, and crm.erase_subject is not
--      replaced (the crm-029 / crm-040 pattern; tests/integration/test_crm010_schema.py lists it as cascade-erased).
--   5. crm.retail_price_rule (base template): the agency's retail price rules, owner-set: name, kind (season:
--      date_from..date_to of the service date; group_size: min_pax travellers or more; early_booking: days_before or
--      more until the service date; last_minute: days_before or fewer), the AA product scope (all, or one Booking
--      component kind; optionally one AA tour), adjust_pct (-90 to 300, not 0), priority (1 = first), stacking (add:
--      sums with the other matching add rules; best_only: of the matching best_only rules only the first by priority
--      applies, on top of the add rules), active. Commercial data, no personal data. Cascades from the agency's
--      crm.tenant_settings row (the agency erase deletes that row; listed as cascade-erased).
--   6. crm.discount_approval (base template): one request for the owner's approval of a builder version's discount
--      (discount_pct, below_cost = the discounted total is below the net, the agency limit at the time), status
--      pending -> approved | rejected (the owner) | superseded (a newer request of the same version); at most one
--      pending row per version. The requester is created_by (member:<id>), the decider decided_by. An owner who sets a
--      discount above the limit leaves an approved row of their own (the audit of who allowed it). No personal data.
--      Cascades from its proposal. Guard crm.guard_discount_approval (SQLSTATE CRM48; crm-040 used CRM47).
--   7. crm.status_transition rows for crm.discount_approval and its transition trigger.
--
-- Behaviour on apply: none. Every agency reads the defaults (bands 11 / 1, limit 10 %), no proposal has a discount, no
-- option has rows or rules, until the AA-Partner code PR deploys.
--
-- Class: contract (ALTER of crm.tenant_settings, crm.proposal and crm.option, the crm.proposal seal trigger recreated, rows in
-- crm.status_transition). MIG-4:
-- this migration-only PR, then the code PR once it is applied on Dev. DM-7.1: crm.option_price and
-- crm.discount_approval go with their trip, crm.retail_price_rule with the agency (root data standards Part B §7 rows
-- added with this key).
--
-- Rollback (a NEW forward migration, after the code is reverted): DROP TABLE crm.discount_approval,
-- crm.retail_price_rule, crm.option_price; DROP FUNCTION crm.guard_discount_approval(); DELETE FROM
-- crm.status_transition WHERE table_name = 'discount_approval'; ALTER TABLE crm.option DROP COLUMN price_rules;
-- recreate crm.proposal_sealed with the crm-019 list (without discount_pct), then ALTER TABLE crm.proposal DROP COLUMN
-- discount_pct; ALTER TABLE crm.tenant_settings DROP COLUMN child_age_max, DROP COLUMN infant_age_max, DROP COLUMN
-- discount_owner_limit_pct.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Re-runnable (IF NOT EXISTS, DROP …
-- IF EXISTS before each ADD, CREATE OR REPLACE, ON CONFLICT DO NOTHING).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- ── Guard 0: runs as the owner, after crm-047 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-048: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-047') THEN
        RAISE EXCEPTION 'crm-048: crm-047 (AA-1038) lands first';
    END IF;
    IF to_regclass('crm.option') IS NULL OR to_regclass('crm.tenant_settings') IS NULL
       OR to_regprocedure('crm.guard_proposal_draft()') IS NULL
       OR to_regprocedure('crm.enforce_status_transition()') IS NULL THEN
        RAISE EXCEPTION 'crm-048: crm.option / crm.guard_proposal_draft (crm-019), crm.tenant_settings (crm-005) or crm.enforce_status_transition (crm-002) missing';
    END IF;
END $$;

-- ── 1. crm.tenant_settings: age bands and the discount limit ────────────────────────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS child_age_max SMALLINT NOT NULL DEFAULT 11;
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS infant_age_max SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS discount_owner_limit_pct NUMERIC(5,2) NOT NULL DEFAULT 10;
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_pricing_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_pricing_chk CHECK (
    infant_age_max BETWEEN 0 AND 5
    AND child_age_max BETWEEN 1 AND 17
    AND infant_age_max < child_age_max
    AND discount_owner_limit_pct BETWEEN 0 AND 100
);
COMMENT ON COLUMN crm.tenant_settings.child_age_max IS 'AA-1066 (crm-048): the oldest age priced as a child in the agency''s retail prices (default 11); older = adult. AA''s Booking quote keeps AA''s own bands.';
COMMENT ON COLUMN crm.tenant_settings.infant_age_max IS 'AA-1066 (crm-048): the oldest age priced as an infant in the agency''s retail prices (default 1, i.e. under 2); below child_age_max.';
COMMENT ON COLUMN crm.tenant_settings.discount_owner_limit_pct IS 'AA-1066 (crm-048): a proposal discount above this percent needs the agency owner''s approval (crm.discount_approval) before a non-owner publishes it (default 10).';

-- ── 2. crm.proposal.discount_pct ─────────────────────────────────────────────────────────────────
ALTER TABLE crm.proposal ADD COLUMN IF NOT EXISTS discount_pct NUMERIC(5,2);
ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_discount_chk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_discount_chk CHECK (
    discount_pct IS NULL OR (kind = 'builder' AND discount_pct > 0 AND discount_pct <= 100)
);
COMMENT ON COLUMN crm.proposal.discount_pct IS 'AA-1066 (crm-048): a discount in percent on the charged total of a builder version (pay-on-arrival items excluded); NULL = none. Covered by the price hash. Above crm.tenant_settings.discount_owner_limit_pct it needs an approved crm.discount_approval before a non-owner publishes.';
-- The crm-019 seal (the content and the published amounts of a builder version never change after draft) plus the
-- discount: the client total, deposit and balance are rebuilt from it, so it is a money column like total_amount.
CREATE OR REPLACE TRIGGER proposal_sealed BEFORE UPDATE ON crm.proposal FOR EACH ROW
    EXECUTE FUNCTION crm.guard_sealed_row('draft', 'trip_id', 'version', 'body_enc', 'currency', 'total_amount',
        'deposit_amount', 'balance_due_on', 'terms_doc_id', 'price_hash', 'tenant_id', 'kind', 'price_visibility',
        'room_config', 'deposit_pct', 'starts_on', 'published_at', 'discount_pct');

-- ── 3. crm.option.price_rules ────────────────────────────────────────────────────────────────────
ALTER TABLE crm.option ADD COLUMN IF NOT EXISTS price_rules JSONB;
ALTER TABLE crm.option DROP CONSTRAINT IF EXISTS option_price_rules_chk;
ALTER TABLE crm.option ADD CONSTRAINT option_price_rules_chk CHECK (
    price_rules IS NULL
    OR (jsonb_typeof(price_rules) = 'array' AND jsonb_array_length(price_rules) <= 20
        AND octet_length(price_rules::text) <= 4096)
);
COMMENT ON COLUMN crm.option.price_rules IS 'AA-1066 (crm-048): the agency price rules the sell was suggested with ([{rule_id, name, adjust_pct}], a snapshot taken when the agent used the suggestion); NULL = priced by hand. Commercial, no personal data.';

-- ── 4. crm.option_price ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.option_price (
    option_price_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    proposal_id     UUID NOT NULL,
    option_id       UUID NOT NULL,
    pax_type        TEXT NOT NULL,
    unit_sell       NUMERIC(14,2) NOT NULL,
    unit_net        NUMERIC(14,2),
    qty             SMALLINT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT option_price_tenant_id_uq UNIQUE (tenant_id, option_price_id),
    CONSTRAINT option_price_type_uq UNIQUE (tenant_id, option_id, pax_type),
    CONSTRAINT option_price_option_fk FOREIGN KEY (tenant_id, proposal_id, option_id)
        REFERENCES crm.option (tenant_id, proposal_id, option_id) ON DELETE CASCADE,
    CONSTRAINT option_price_values_chk CHECK (
        pax_type IN ('adult', 'child', 'infant', 'single_supp')
        AND unit_sell >= 0 AND unit_sell <= 99999999.99
        AND (unit_net IS NULL OR (unit_net >= 0 AND unit_net <= 99999999.99))
        AND qty BETWEEN 0 AND 99
    ),
    CONSTRAINT option_price_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS option_price_proposal_idx ON crm.option_price (tenant_id, proposal_id);
COMMENT ON TABLE crm.option_price IS 'AA-1066 (crm-048, item crm-05): the price per traveller type of one builder option (adult, child, infant, single_supp = the single room supplement): unit sell, unit net (agency items only), quantity. With rows, crm.option.sell_amount is their sum (and an agency item''s net_amount the sum of the unit nets when every row has one); the client page shows the types and quantities, never a net. Changes only while its proposal is a draft (crm.guard_proposal_draft, CRM35). Cascades from its option. Commercial, no personal data.';
COMMENT ON COLUMN crm.option_price.unit_net IS 'conf:commercial; the agency''s cost per traveller of an agency item (an AA item''s net is the Booking quote''s); owner / agent only (margin serializer)';

-- ── 5. crm.retail_price_rule ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.retail_price_rule (
    retail_price_rule_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                         REFERENCES crm.tenant (tenant_id),
    name                 TEXT NOT NULL,
    kind                 TEXT NOT NULL,
    product_scope        TEXT NOT NULL DEFAULT 'all',
    aa_tour_source_id    TEXT,
    date_from            DATE,
    date_to              DATE,
    min_pax              SMALLINT,
    days_before          SMALLINT,
    adjust_pct           NUMERIC(6,2) NOT NULL,
    priority             SMALLINT NOT NULL DEFAULT 100,
    stacking             TEXT NOT NULL DEFAULT 'add',
    active               BOOLEAN NOT NULL DEFAULT true,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ,
    deleted_by           TEXT,
    purge_after          TIMESTAMPTZ,
    CONSTRAINT retail_price_rule_tenant_id_uq UNIQUE (tenant_id, retail_price_rule_id),
    CONSTRAINT retail_price_rule_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT retail_price_rule_values_chk CHECK (
        char_length(btrim(name)) BETWEEN 1 AND 80 AND name !~ '[[:cntrl:]]'
        AND kind IN ('season', 'group_size', 'early_booking', 'last_minute')
        AND product_scope IN ('all', 'trip_plan', 'hotel_room', 'transfer', 'guide', 'activity', 'entrance', 'meal')
        AND (aa_tour_source_id IS NULL
             OR (char_length(aa_tour_source_id) BETWEEN 1 AND 128 AND aa_tour_source_id !~ '[[:cntrl:]]'))
        AND adjust_pct BETWEEN -90 AND 300 AND adjust_pct <> 0
        AND priority BETWEEN 1 AND 999
        AND stacking IN ('add', 'best_only')
    ),
    -- Each kind carries exactly its own condition.
    CONSTRAINT retail_price_rule_condition_chk CHECK (
        CASE kind
            WHEN 'season' THEN date_from IS NOT NULL AND date_to IS NOT NULL AND date_from <= date_to
                               AND date_to - date_from <= 366 AND min_pax IS NULL AND days_before IS NULL
            WHEN 'group_size' THEN min_pax BETWEEN 2 AND 99 AND date_from IS NULL AND date_to IS NULL
                                   AND days_before IS NULL
            WHEN 'early_booking' THEN days_before BETWEEN 1 AND 730 AND date_from IS NULL AND date_to IS NULL
                                      AND min_pax IS NULL
            ELSE days_before BETWEEN 0 AND 365 AND date_from IS NULL AND date_to IS NULL AND min_pax IS NULL
        END
    ),
    CONSTRAINT retail_price_rule_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS retail_price_rule_tenant_idx ON crm.retail_price_rule (tenant_id, priority)
    WHERE deleted_at IS NULL;
COMMENT ON TABLE crm.retail_price_rule IS 'AA-1066 (crm-048, item crm-06): the agency''s retail price rules, set by the owner in Settings > Pricing: season (service date in date_from..date_to), group_size (min_pax travellers or more), early_booking (days_before days or more before the service date), last_minute (days_before days or fewer); adjust_pct on the suggested sell of a new AA option (after the agency markup or AA''s RRP); priority (1 first); stacking add (sums with the other add rules) or best_only (only the first matching best_only rule by priority, on top of the add rules). Commercial, no personal data. Cascades from the agency''s tenant_settings row.';

-- ── 6. crm.discount_approval ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.discount_approval (
    discount_approval_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                         REFERENCES crm.tenant (tenant_id),
    trip_id              UUID NOT NULL,
    proposal_id          UUID NOT NULL,
    discount_pct         NUMERIC(5,2) NOT NULL,
    below_cost           BOOLEAN NOT NULL DEFAULT false,
    limit_pct            NUMERIC(5,2) NOT NULL,
    status               TEXT NOT NULL DEFAULT 'pending',
    decided_by           TEXT,
    decided_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ,
    deleted_by           TEXT,
    purge_after          TIMESTAMPTZ,
    CONSTRAINT discount_approval_tenant_id_uq UNIQUE (tenant_id, discount_approval_id),
    CONSTRAINT discount_approval_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id) ON DELETE CASCADE,
    CONSTRAINT discount_approval_values_chk CHECK (
        discount_pct BETWEEN 0 AND 100 AND limit_pct BETWEEN 0 AND 100
        AND (discount_pct > limit_pct OR below_cost)
    ),
    CONSTRAINT discount_approval_status_chk CHECK (
        status IN ('pending', 'approved', 'rejected', 'superseded')
        AND (status IN ('approved', 'rejected')) = (decided_at IS NOT NULL)
        AND (decided_at IS NULL) = (decided_by IS NULL)
    ),
    CONSTRAINT discount_approval_by_chk CHECK (decided_by IS NULL OR decided_by ~ '^[A-Za-z0-9:_-]{1,80}$'),
    CONSTRAINT discount_approval_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS discount_approval_one_pending_uq ON crm.discount_approval (tenant_id, proposal_id)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS discount_approval_trip_idx ON crm.discount_approval (tenant_id, trip_id, created_at DESC);
COMMENT ON TABLE crm.discount_approval IS 'AA-1066 (crm-048, item crm-07): a request for the agency owner''s approval of a builder version''s discount above the agency limit (or of a discounted total below the net): discount_pct, below_cost, the limit at the time; pending -> approved | rejected by an owner, or superseded by a newer request of the same version; one pending row per version. created_by = the requester, decided_by = the owner. An approved row covers this trip''s discounts up to its percent. Guard crm.guard_discount_approval (CRM48). No personal data. Cascades from its proposal.';

CREATE OR REPLACE FUNCTION crm.guard_discount_approval() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    v_role text := COALESCE(NULLIF(current_setting('app.member_role', true), ''), '');
    -- The columns a decision may change; everything else stays as requested.
    v_decision_cols text[] := ARRAY['status', 'decided_at', 'decided_by', 'updated_at'];
BEGIN
    -- A cascade from the proposal (an erase, trigger depth > 1) and the owner role (migrations, tests) pass.
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user = 'crm_owner' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF v_actor NOT LIKE 'member:%' THEN
        RAISE EXCEPTION 'crm: discount_approval_guard (a member writes a discount approval, actor %)', v_actor
            USING ERRCODE = 'CRM48';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'crm: discount_approval_guard (an approval leaves only with its proposal)' USING ERRCODE = 'CRM48';
    END IF;
    IF TG_OP = 'INSERT' THEN
        -- A request is pending; an owner may record their own discount as approved at once (decided by themselves).
        IF NEW.status = 'pending' AND NEW.decided_at IS NULL THEN
            RETURN NEW;
        END IF;
        IF NEW.status = 'approved' AND v_role = 'owner' AND NEW.decided_by = v_actor THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'crm: discount_approval_guard (a new approval is pending, or an owner''s own)' USING ERRCODE = 'CRM48';
    END IF;
    -- UPDATE: only the decision columns change, from pending.
    IF (pg_catalog.to_jsonb(NEW) - v_decision_cols) IS DISTINCT FROM (pg_catalog.to_jsonb(OLD) - v_decision_cols) THEN
        RAISE EXCEPTION 'crm: discount_approval_guard (only the decision of an approval changes)' USING ERRCODE = 'CRM48';
    END IF;
    IF NEW.status IN ('approved', 'rejected') AND (v_role <> 'owner' OR NEW.decided_by IS DISTINCT FROM v_actor) THEN
        RAISE EXCEPTION 'crm: discount_approval_guard (only an owner decides, as themselves)' USING ERRCODE = 'CRM48';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_discount_approval() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_discount_approval() IS 'AA-1066 (crm-048, SQLSTATE CRM48): who may write crm.discount_approval. INSERT: a member, pending; or an owner (app.member_role) recording their own approved discount (decided_by = app.actor). UPDATE: a member; only status, decided_at, decided_by (and updated_at) change; approved / rejected only by an owner as themselves (the moves themselves: crm.status_transition). DELETE: refused (the row leaves with its proposal by cascade, depth > 1). crm_owner unguarded (migrations, tests). Invoker rights.';

-- ── RLS, triggers, grants of the three tables ────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['option_price', 'retail_price_rule', 'discount_approval'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()',
            t || '_set_updated_at', t);
    END LOOP;
    -- A published / sent version's per-traveller prices never change (CRM35), whatever path writes.
    EXECUTE 'CREATE OR REPLACE TRIGGER option_price_draft_only BEFORE INSERT OR UPDATE OR DELETE '
            'ON crm.option_price FOR EACH ROW EXECUTE FUNCTION crm.guard_proposal_draft()';
    EXECUTE 'CREATE OR REPLACE TRIGGER discount_approval_guard BEFORE INSERT OR UPDATE OR DELETE '
            'ON crm.discount_approval FOR EACH ROW EXECUTE FUNCTION crm.guard_discount_approval()';
    -- crm_app: the default privileges gave table-wide DML; no TRUNCATE; no DELETE of an approval (the guard refuses
    -- it too).
    EXECUTE 'REVOKE TRUNCATE ON crm.option_price, crm.retail_price_rule, crm.discount_approval FROM crm_app';
    EXECUTE 'REVOKE DELETE ON crm.discount_approval FROM crm_app';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON crm.option_price, crm.retail_price_rule TO crm_app';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE ON crm.discount_approval TO crm_app';
END $$;

-- ── 7. Status moves of crm.discount_approval ─────────────────────────────────────────────────────
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('discount_approval', 'pending', 'approved'),
    ('discount_approval', 'pending', 'rejected'),
    ('discount_approval', 'pending', 'superseded')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE TRIGGER discount_approval_status_transition
    BEFORE UPDATE OF status ON crm.discount_approval
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition();

-- ── Post-checks ──────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT has_table_privilege('crm_app', 'crm.option_price', 'INSERT')
       OR NOT has_table_privilege('crm_app', 'crm.retail_price_rule', 'DELETE')
       OR NOT has_table_privilege('crm_app', 'crm.discount_approval', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-048: crm_app is missing a write privilege on the new tables';
    END IF;
    IF has_table_privilege('crm_app', 'crm.discount_approval', 'DELETE') THEN
        RAISE EXCEPTION 'crm-048: crm_app must not delete a discount approval';
    END IF;
    IF NOT has_column_privilege('crm_app', 'crm.tenant_settings', 'discount_owner_limit_pct', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.proposal', 'discount_pct', 'UPDATE')
       OR NOT has_column_privilege('crm_app', 'crm.option', 'price_rules', 'INSERT') THEN
        RAISE EXCEPTION 'crm-048: crm_app cannot write the new columns';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'proposal_sealed'
                   AND tgrelid = 'crm.proposal'::regclass
                   AND position('discount_pct' IN pg_catalog.encode(tgargs, 'escape')) > 0
                   AND position('published_at' IN pg_catalog.encode(tgargs, 'escape')) > 0) THEN
        RAISE EXCEPTION 'crm-048: the proposal seal must cover discount_pct and keep the crm-019 columns';
    END IF;
    IF has_table_privilege('crm_support_reader', 'crm.option_price', 'SELECT')
       OR has_column_privilege('crm_support_reader', 'crm.tenant_settings', 'discount_owner_limit_pct', 'SELECT') THEN
        RAISE EXCEPTION 'crm-048: crm_support_reader must not read the retail pricing data';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-048', now(), 'AA-1066: retail pricing: crm.option_price (price per traveller type), crm.retail_price_rule (season / group / early / last-minute), crm.discount_approval (owner approval above the limit, CRM48); tenant_settings age bands + discount limit, proposal.discount_pct, option.price_rules')
ON CONFLICT (version) DO NOTHING;

COMMIT;
