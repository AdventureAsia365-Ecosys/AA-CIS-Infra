-- migrate: expand
-- Migration crm-052: AA-1069 (S275 study of a tour and travel app, root docs/research/2026-11-10-odoo-tour-travel-
-- plugin-comparison.md, item crm-23; behaviour only, no plugin code) — the agency's own service catalogue: the
-- ancillaries it sells beside AA's tours (root ADR 0019 b6: flights, insurance, visa, transfers, fees), each with a unit
-- net, a unit sell and a quantity basis, so the trip builder adds them in one click instead of typing each one.
--
-- Owner: AA-Partner (api/migrations/052_crm_agency_service_catalogue.sql). AA-CIS-Infra db/migrations/crm/ holds the
-- byte copy DB Migrate applies (Migration Copy Guard). Key crm-052: crm-051 is the highest on main; if main moves,
-- renumber: file name, this header, the registration below, crm-053's guard, app/db.py REQUIRED_SCHEMA_VERSIONS and the
-- tests that name it (git grep '052_' and 'crm-052').
--
-- What (DM-7.1: root data standards Part B §7 rows added with this key; no personal data in either table):
--   1. crm.agency_service (base template): one service of the agency's catalogue: the own supplier that provides it
--      (NULL = the agency's own fee), category (flight | insurance | visa | transfer | fee, ADR 0019 b6), name,
--      unit_net (what the supplier charges per unit, NULL = not known; commercial), unit_sell (the price per unit to
--      the traveller), currency, qty_basis (per_person | per_adult | per_booking | per_room | per_night |
--      per_person_night: how the builder counts the units from the party, the rooms and the nights), valid_from /
--      valid_to (NULL = open), active. Cascades from the agency's crm.tenant_settings row (the agency erase deletes it)
--      and from its supplier (a supplier purged from the trash takes its services with it).
--   2. crm.agency_service_tier (base template): a group-size net price of one service: from min_pax to max_pax
--      (NULL = no upper bound) travellers the unit net is unit_net. One tier per min_pax. Cascades from its service.
--   3. An option the builder adds from the catalogue is a SNAPSHOT (title, supplier, sell, net copied at that moment);
--      no key from crm.option to a service, so editing or deleting a service never changes a proposal.
--   4. Write guard crm.guard_agency_service (SQLSTATE CRM52; crm-051 used CRM51) on both tables: a member writes them
--      only as owner or agent (the prices are money fields); a service names an own, live supplier of the agency
--      (never the Adventure Asia row: AA's tours come from the AA drawer); a tier's range is checked against the
--      others of its service (no two tiers overlap). A cascade (trigger depth > 1), crm_owner and a job / seed actor
--      pass the role check.
--   5. RLS (ENABLE + FORCE, tenant_isolation TO the CRM roles); crm_app keeps the default DML of crm-001 (the guard
--      decides); no reader grant: AI context, insights and support never read them. The API never builds unit_net for
--      a role without view_margin, and the margin serializer strips it by name (``*_net``) as a backstop.
--
-- Class: expand (root ADR 0017 d3): two new tables and one new trigger function with their constraints, indexes,
-- triggers, policies and comments; foreign keys from the new tables (to crm.tenant, crm.tenant_settings,
-- crm.agency_supplier and each other); no change to an existing object, no DO block, no CREATE OR REPLACE. Not
-- re-runnable by itself (plain CREATE POLICY / TRIGGER / FUNCTION); DB Migrate never applies a registered key again
-- and the test conftest skips it. Ships in the migration-only PR with crm-053 (batch crm 052-053), applied before the
-- code PR.
--
-- Rollback (a forward crm- file, after the code that reads them is reverted): DROP TABLE crm.agency_service_tier,
-- crm.agency_service; DROP FUNCTION crm.guard_agency_service().
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ── 1. crm.agency_service ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.agency_service (
    service_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    agency_supplier_id UUID,
    category           TEXT NOT NULL,
    name               TEXT NOT NULL,
    unit_net           NUMERIC(14,2),
    unit_sell          NUMERIC(14,2) NOT NULL,
    currency           CHARACTER(3) NOT NULL,
    qty_basis          TEXT NOT NULL,
    valid_from         DATE,
    valid_to           DATE,
    active             BOOLEAN NOT NULL DEFAULT true,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT agency_service_tenant_id_uq UNIQUE (tenant_id, service_id),
    CONSTRAINT agency_service_settings_fk FOREIGN KEY (tenant_id)
        REFERENCES crm.tenant_settings (tenant_id) ON DELETE CASCADE,
    CONSTRAINT agency_service_supplier_fk FOREIGN KEY (tenant_id, agency_supplier_id)
        REFERENCES crm.agency_supplier (tenant_id, agency_supplier_id) ON DELETE CASCADE,
    CONSTRAINT agency_service_category_chk CHECK (
        category IN ('flight', 'insurance', 'visa', 'transfer', 'fee')
    ),
    CONSTRAINT agency_service_qty_basis_chk CHECK (
        qty_basis IN ('per_person', 'per_adult', 'per_booking', 'per_room', 'per_night', 'per_person_night')
    ),
    CONSTRAINT agency_service_values_chk CHECK (
        char_length(btrim(name)) BETWEEN 1 AND 120 AND name !~ '[[:cntrl:]]'
        AND currency ~ '^[A-Z]{3}$'
        AND unit_sell >= 0 AND unit_sell <= 99999999.99
        AND (unit_net IS NULL OR (unit_net >= 0 AND unit_net <= 99999999.99))
        AND (valid_from IS NULL OR valid_to IS NULL OR valid_to >= valid_from)
    ),
    CONSTRAINT agency_service_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS agency_service_tenant_idx ON crm.agency_service (tenant_id, category, name)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS agency_service_supplier_idx ON crm.agency_service (tenant_id, agency_supplier_id)
    WHERE agency_supplier_id IS NOT NULL;
COMMENT ON TABLE crm.agency_service IS 'AA-1069 (crm-052, item crm-23): one service of the agency''s own catalogue (root ADR 0019 b6 ancillaries: flight, insurance, visa, transfer, fee), with the own supplier that provides it (NULL = the agency''s own fee), unit_net (commercial, owner / agent), unit_sell, currency, qty_basis and an optional validity window. The trip builder''s "Add from catalogue" copies it into an option as a snapshot (no key from crm.option). Commercial, no personal data. Cascades from the agency''s tenant_settings row and from its supplier. Guard crm.guard_agency_service (CRM52).';
COMMENT ON COLUMN crm.agency_service.qty_basis IS 'how the builder counts the units: per_person (every traveller), per_adult, per_booking (1), per_room (the proposal''s rooms), per_night (the trip''s nights), per_person_night (travellers x nights)';
COMMENT ON COLUMN crm.agency_service.unit_net IS 'what the supplier charges per unit (NULL = not known); a tier of crm.agency_service_tier replaces it for its group size. A margin field: never returned to the assistant';

-- ── 2. crm.agency_service_tier ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.agency_service_tier (
    tier_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                REFERENCES crm.tenant (tenant_id),
    service_id  UUID NOT NULL,
    min_pax     SMALLINT NOT NULL,
    max_pax     SMALLINT,
    unit_net    NUMERIC(14,2) NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,
    deleted_by  TEXT,
    purge_after TIMESTAMPTZ,
    CONSTRAINT agency_service_tier_tenant_id_uq UNIQUE (tenant_id, tier_id),
    CONSTRAINT agency_service_tier_min_uq UNIQUE (tenant_id, service_id, min_pax),
    CONSTRAINT agency_service_tier_service_fk FOREIGN KEY (tenant_id, service_id)
        REFERENCES crm.agency_service (tenant_id, service_id) ON DELETE CASCADE,
    CONSTRAINT agency_service_tier_values_chk CHECK (
        min_pax BETWEEN 1 AND 999
        AND (max_pax IS NULL OR (max_pax BETWEEN min_pax AND 999))
        AND unit_net >= 0 AND unit_net <= 99999999.99
    ),
    CONSTRAINT agency_service_tier_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
COMMENT ON TABLE crm.agency_service_tier IS 'AA-1069 (crm-052, item crm-23): a group-size net price of one catalogue service: a party of min_pax to max_pax (NULL = no upper bound) travellers is charged unit_net per unit by the supplier (the service''s unit_sell stays). Ranges of one service never overlap (CRM52). Cascades from its service. Commercial (owner / agent), no personal data.';

-- ── RLS, policies and triggers of the two tables (no DO block: an expand file) ───────────────────
ALTER TABLE crm.agency_service ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.agency_service FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.agency_service
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE crm.agency_service_tier ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm.agency_service_tier FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON crm.agency_service_tier
    TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE TRIGGER agency_service_set_updated_at
    BEFORE UPDATE ON crm.agency_service
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();
CREATE TRIGGER agency_service_tier_set_updated_at
    BEFORE UPDATE ON crm.agency_service_tier
    FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at();

CREATE FUNCTION crm.guard_agency_service() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor text := COALESCE(NULLIF(current_setting('app.actor', true), ''), '');
    v_role text := COALESCE(NULLIF(current_setting('app.member_role', true), ''), '');
    v_kind text;
    v_deleted timestamptz;
BEGIN
    -- A cascade (the agency erase, a supplier purge: trigger depth > 1) and the owner role (migrations, tests) pass.
    IF pg_catalog.pg_trigger_depth() > 1 OR current_user = 'crm_owner' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    -- The catalogue's prices are money fields: a member writes them as owner or agent; a job / seed actor passes.
    IF v_actor !~ '^(job|seed):' AND v_role NOT IN ('owner', 'agent') THEN
        RAISE EXCEPTION 'crm: catalogue_owner_agent (the service catalogue is edited by an owner or an agent, role %)',
            NULLIF(v_role, '') USING ERRCODE = 'CRM52';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    IF TG_TABLE_NAME = 'agency_service' THEN
        IF NEW.agency_supplier_id IS NOT NULL
           AND (TG_OP = 'INSERT' OR NEW.agency_supplier_id IS DISTINCT FROM OLD.agency_supplier_id) THEN
            SELECT s.kind, s.deleted_at INTO v_kind, v_deleted
              FROM crm.agency_supplier s
             WHERE s.tenant_id = NEW.tenant_id AND s.agency_supplier_id = NEW.agency_supplier_id;
            IF v_kind IS DISTINCT FROM 'own' OR v_deleted IS NOT NULL THEN
                RAISE EXCEPTION 'crm: catalogue_supplier (a service names a live own supplier of the agency, never Adventure Asia)'
                    USING ERRCODE = 'CRM52';
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    -- crm.agency_service_tier: the ranges of one service never overlap (a reversed range is the values CHECK's).
    IF NEW.max_pax IS NOT NULL AND NEW.max_pax < NEW.min_pax THEN
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM crm.agency_service_tier t
                WHERE t.tenant_id = NEW.tenant_id AND t.service_id = NEW.service_id AND t.tier_id <> NEW.tier_id
                  AND t.deleted_at IS NULL
                  AND int4range(t.min_pax, COALESCE(t.max_pax, 999), '[]')
                      && int4range(NEW.min_pax, COALESCE(NEW.max_pax, 999), '[]')) THEN
        RAISE EXCEPTION 'crm: catalogue_tier_overlap (the group sizes of two tiers of one service overlap)'
            USING ERRCODE = 'CRM52';
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION crm.guard_agency_service() IS 'AA-1069 (crm-052, SQLSTATE CRM52): who may write the service catalogue: a member as owner or agent (catalogue_owner_agent), a job / seed actor; a service names a live own supplier of the agency or none (catalogue_supplier); the tiers of one service never overlap (catalogue_tier_overlap). A cascade (depth > 1) and crm_owner pass. Invoker rights.';
CREATE TRIGGER agency_service_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.agency_service
    FOR EACH ROW EXECUTE FUNCTION crm.guard_agency_service();
CREATE TRIGGER agency_service_tier_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.agency_service_tier
    FOR EACH ROW EXECUTE FUNCTION crm.guard_agency_service();

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-052', now(), 'AA-1069: the agency service catalogue (crm.agency_service with unit net, unit sell, quantity basis and validity; crm.agency_service_tier group-size net prices); guard CRM52; cascades from tenant_settings / agency_supplier, no erase_subject change')
ON CONFLICT (version) DO NOTHING;

COMMIT;
