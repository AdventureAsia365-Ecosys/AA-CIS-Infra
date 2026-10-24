-- Migration crm-014: AA-944 (partner CRM, design v3 card CRM-16) — the agency-line ledger and the supplier directory:
-- the agency's own booking lines (M6, non-AA), its suppliers with Adventure Asia as a built-in row (M15), money rows
-- with a frozen FX block (R17), the line status and the validation level (R18), and the erasure / hold rule extended
-- to the new tables.
--
-- Owner: AA-Partner (api/migrations/014_crm_ledger_suppliers.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-014 (S250 schedule §1: crm-012 = AA-943, crm-013 = AA-978,
-- crm-015 = AA-945). crm.erase_subject below is the crm-013 text plus the ledger steps; crm-015 starts from THIS text.
--
-- Why. Design v3 §6.3 card CRM-16 (M6 non-AA, M15, R17, R18; checklist: line statuses, frozen FX, strictness default
-- Basic, AA as a built-in supplier), data lane §2.7 group F, §3.1 FX rules, §3.2 line status. Card R: a duplicate
-- confirmation number under Strict -> 409. Card E: a later FX row does not change past margins.
--
-- What:
--   1. crm.tenant_settings: base_currency (char(3), default USD: an assumption, the design names none; owner-editable
--      in Settings > Payments), booking_validation_level off | basic | strict (default basic, R18), fx_mode
--      automatic | manual (manual = the owner's overrides only, no platform rate).
--   2. crm.agency_supplier (base template; group F, M15): kind aa | own, name, category, contact_name_enc /
--      contact_email_enc (vault DEK, pii:name / pii:contact), default_commission_pct, confirmation_unique. At most one
--      kind = aa row per agency (partial UNIQUE), created only by crm.ensure_aa_supplier() (SECURITY DEFINER: the
--      provisioning code and the supplier list call it; existing agencies are backfilled below). crm.guard_agency_supplier:
--      crm_app never inserts, changes or trashes the aa row and never changes a kind (SQLSTATE CRM22
--      aa_supplier_builtin); a supplier that live lines name is not trashed (CRM27 supplier_in_use).
--   3. crm.booking_line (base template; lane §2.7 column list): (tenant, trip) key, supplier_kind aa | agency matching
--      the supplier's kind, same-agency key to agency_supplier, the Booking references bk_hold_id / bk_booking_id /
--      departure_id (AA lines, CRM-19), status planning -> confirmed -> cancelled (planning -> cancelled too;
--      crm.status_transition rows), aa_sub_status (AA lines only), title, confirmation_no, service_from / service_to,
--      collect agency | on_arrival (R25), confirm_class (R26), visible_to_travelers, confirmed_at, trash columns.
--      crm.guard_booking_line (BEFORE INSERT OR UPDATE OR DELETE):
--      a. an aa line is written only by a job: / platform: actor (the CRM-19 Booking feed); any other crm_app session
--         -> CRM24 aa_line_read_only;
--      b. the supplier's kind must match supplier_kind (aa <-> aa, own <-> agency);
--      c. an agency line becomes confirmed only through crm.booking_line_confirm() (it freezes the money first): a
--         crm_app statement that confirms one -> CRM26 line_not_editable;
--      d. confirmed_at is NULL until the line first becomes confirmed, then set once (a client value on a planning
--         line is dropped, so it always matches the FX basis date of the frozen money); a cancelled line is never
--         visible to travellers (R22); a confirmed agency line keeps its confirmation_no while the agency's level is
--         basic or strict (clearing it -> CRM23 line_incomplete:confirmation_no);
--      e. only a planning line goes to the trash (CRM26);
--      f. conf_unique_key = the normalised confirmation_no (upper case, letters and digits only: "hp 1001" =
--         "HP-1001") while the line is a confirmed agency line and the agency is strict or the supplier is
--         confirmation_unique; NULL otherwise. UNIQUE
--         (tenant_id, agency_supplier_id, conf_unique_key): two confirmed lines of one supplier with one number ->
--         unique_violation booking_line_conf_uq (the API's 409 duplicate_confirmation_no; race-free, card R). A
--         cancelled line frees its number. A line confirmed before the agency went strict (no key) still counts:
--         the trigger also looks for a confirmed un-keyed line with the same normalised number (same unique_violation).
--         The key and that scan run only when the line becomes confirmed or its number or supplier changes; any other
--         edit keeps the stored key, so two lines confirmed with one number before strict can still be edited.
--   4. crm.booking_line_money (append-only variant; lane §2.1 money columns): one chain per (line, kind cost | sell |
--      commission_expected): amount numeric(14,2) >= 0, currency char(3), and the FX block (base_currency,
--      amount_base, fx_rate, fx_rate_date, fx_source aa_quote_lock | platform_daily | manual, fx_basis booking_date |
--      receipt_date | quote_lock, stale_days) all NULL (a planning line) or all set (CHECK; amount_base =
--      round(amount * fx_rate, 2)). A change is a new row with supersedes_id (UNIQUE (tenant_id, supersedes_id): one
--      successor per row, so each chain is linear; crm.booking_line_money_chain checks the predecessor is the same
--      line and kind, and a chain starts once). Append-only (crm.ledger_append_only: UPDATE and TRUNCATE always
--      refused, DELETE only as crm_owner inside crm.erase_subject). Margin protection (lane §2.7, S:§3): the
--      tenant_isolation policy of the template, plus the RESTRICTIVE policy booking_line_money_margin_roles FOR SELECT
--      TO crm_app: app.member_role IN (owner, agent), or no member role and a job: / seed: actor. A platform: actor
--      (AA staff, the L1 console) reads none: AA is a supplier in this ledger, and staff reach an agency only through
--      the consented support reader. The assistant reads 0 rows. crm_app has SELECT only: every write goes through crm.booking_line_money_put() /
--      crm.booking_line_confirm() (SECURITY DEFINER, which also re-check the role). No reader grant. The view
--      crm.v_booking_line_money_current (the head of each chain) is security_invoker, so it reads through the
--      caller's policies, never crm_owner's.
--   5. crm.booking_line_confirm_check(line) (SECURITY DEFINER, EXECUTE crm_app): the codes a confirm would miss at the
--      agency's level (off: none; basic: confirmation_no, cost, sell; strict: + commission), without returning any
--      amount, so the API words an assistant's refusal without reading money.
--      crm.booking_line_confirm(line) (SECURITY DEFINER, EXECUTE crm_app): re-checks the level (an assistant is never
--      blocked by a missing commission: the API then opens the owner task "Add commission", R18), freezes every
--      unfrozen head money row at the line's confirmation date in the agency timezone (fx_basis booking_date), then
--      moves the line to confirmed. Refusals: CRM23 line_incomplete:<codes>, CRM25 fx_rate_missing:<currency>, CRM26.
--      crm.booking_line_money_put(line, kind, amount, currency) (SECURITY DEFINER, EXECUTE crm_app): owner / agent
--      (or a job / seed actor) only (42501 otherwise); a new head row for the kind (nothing when the head
--      already has that amount and currency); on a confirmed line frozen at once, re-using the head's rate when the
--      currency is unchanged (no drift on a correction), else resolved for the confirmation date. Not on an aa line
--      (CRM24, the feed's card adds its own path) nor a cancelled or trashed one (CRM26).
--      crm.fx_resolve(from, to, date) (invoker, EXECUTE crm_app): the rate of one unit of from in to (R17 §3.1): the
--      agency override of that day, else the platform rate of that day, else the latest earlier day within 30 days
--      (stale_days = the gap); an override wins a tie; platform rates direct, inverse or crossed through USD / EUR on
--      one day and source, source priority booking_b2b, manual_aa, ecb, exchangerate_api, sbv, synthetic
--      (fawazahmed0 rows are a cross-check only, never used); fx_mode manual reads overrides only. from = to: rate 1.
--   6. crm.fx_rate_platform (platform reference table, no tenant column, no RLS; lane §2.7): PK (rate_date, base,
--      quote, source), rate numeric(20,10) > 0 (1 base = rate quote), fetched_at. crm_app SELECT + INSERT only.
--      Filled by the daily job crm_fx_fetch (synthetic rates on Dev).
--   7. crm.fx_rate_override (append-only variant): the owner's rate for a day (base, quote, rate, set_by = a member of
--      the agency, same-agency key); the latest row of a day wins.
--   8. The hold rule and erasure (crm-010 items 4, 10) extended:
--      a. crm.erase_held (4e), the crm-012 text plus scopes booking_line (its trip held) and agency_supplier (the
--         agency hold only); a trip erase reaches its lines and their money through hold_trip (they name the trip).
--      b. crm.erase_subject, the crm-013 text plus: trip scope deletes the trip's line money and lines before the trip;
--         new scopes booking_line (its money, then the line: the trash purge of a planning line) and agency_supplier
--         (refused for the aa row, CRM22, and while any line names it, CRM27); the agency erase deletes line money,
--         lines, suppliers (the aa row too) and overrides. Without these steps every offboarding refuses with CRM16.
--      c. crm.guard_held_change (4h) on booking_line (trip_id guarded: no delete, trash or move of a held trip's line)
--         and on agency_supplier (agency hold: no delete or trash).
--      CRM-16 writes nothing to crm.trip_commitment: agency lines do not block a trip delete (design §3.5).
--   No NOLOGIN reader gets anything on the new tables. SQLSTATEs CRM22-CRM27 are this file's; crm-015 starts at CRM28.
--
-- Order: after crm-012 (AA-943) and crm-013 (AA-978); Guard 0 refuses to run before both are registered
-- (erase_subject must build on the crm-013 text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before the AA-944
-- code deploys nothing reads these objects, and the code merges only after this file is applied (S249 lesson).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-012 and crm-013 ────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-014: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-012') THEN
        RAISE EXCEPTION 'crm-014: crm-012 is not registered (CRM-15 modules 1 + 2, AA-943, lands first)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-013') THEN
        RAISE EXCEPTION 'crm-014: crm-013 is not registered (CIS membership feed, AA-978, lands first)';
    END IF;
    IF to_regclass('crm.membership_inbox') IS NULL OR to_regclass('crm.client_link') IS NULL
       OR to_regprocedure('crm.erase_subject(text,uuid,uuid,boolean)') IS NULL
       OR to_regprocedure('crm.erase_held(text,uuid,uuid)') IS NULL
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL THEN
        RAISE EXCEPTION 'crm-014: crm.membership_inbox (crm-013), crm.client_link (crm-012) or the crm-010 erase functions missing';
    END IF;
END $$;

-- ── 1. crm.tenant_settings ───────────────────────────────────────────────────────────────────────
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS base_currency CHAR(3) NOT NULL DEFAULT 'USD';
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS booking_validation_level TEXT NOT NULL DEFAULT 'basic';
ALTER TABLE crm.tenant_settings ADD COLUMN IF NOT EXISTS fx_mode TEXT NOT NULL DEFAULT 'automatic';
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_base_currency_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_base_currency_chk CHECK (base_currency ~ '^[A-Z]{3}$');
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_validation_level_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_validation_level_chk
    CHECK (booking_validation_level IN ('off', 'basic', 'strict'));
ALTER TABLE crm.tenant_settings DROP CONSTRAINT IF EXISTS tenant_settings_fx_mode_chk;
ALTER TABLE crm.tenant_settings ADD CONSTRAINT tenant_settings_fx_mode_chk CHECK (fx_mode IN ('automatic', 'manual'));
COMMENT ON COLUMN crm.tenant_settings.base_currency IS 'AA-944 (crm-014, R17): the agency''s reporting currency (ISO 4217). Every money row stores its base amount in it, frozen. Default USD is an assumption (the design names none); the owner changes it in Settings > Payments, which never re-converts stored rows';
COMMENT ON COLUMN crm.tenant_settings.booking_validation_level IS 'AA-944 (crm-014, R18): what an agency line needs before confirmed: off (nothing), basic (confirmation_no + cost + sell, default), strict (basic + commission, and confirmation_no unique per supplier)';
COMMENT ON COLUMN crm.tenant_settings.fx_mode IS 'AA-944 (crm-014, R17): automatic (the agency override of the day, else the platform daily rate) or manual (the agency''s own overrides only)';

-- ── 2. crm.agency_supplier ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.agency_supplier (
    agency_supplier_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id              UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                           REFERENCES crm.tenant (tenant_id),
    kind                   TEXT NOT NULL DEFAULT 'own',
    name                   TEXT NOT NULL,
    category               TEXT NOT NULL DEFAULT 'other',
    contact_name_enc       BYTEA,
    contact_email_enc      BYTEA,
    default_commission_pct NUMERIC(5, 2),
    confirmation_unique    BOOLEAN NOT NULL DEFAULT false,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by             TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at             TIMESTAMPTZ,
    deleted_by             TEXT,
    purge_after            TIMESTAMPTZ,
    CONSTRAINT agency_supplier_tenant_id_uq UNIQUE (tenant_id, agency_supplier_id),
    CONSTRAINT agency_supplier_kind_chk CHECK (kind IN ('aa', 'own')),
    CONSTRAINT agency_supplier_name_chk CHECK (char_length(btrim(name)) BETWEEN 1 AND 120 AND name !~ '[[:cntrl:]]'),
    CONSTRAINT agency_supplier_category_chk CHECK (
        category IN ('accommodation', 'transport', 'activity', 'guide', 'restaurant', 'flight', 'insurance', 'visa',
                     'dmc', 'other')
    ),
    CONSTRAINT agency_supplier_contact_chk CHECK (
        coalesce(octet_length(contact_name_enc), 30) >= 30 AND coalesce(octet_length(contact_email_enc), 30) >= 30
        AND (kind = 'own' OR (contact_name_enc IS NULL AND contact_email_enc IS NULL))
    ),
    CONSTRAINT agency_supplier_commission_chk CHECK (
        default_commission_pct IS NULL OR default_commission_pct BETWEEN 0 AND 100
    ),
    CONSTRAINT agency_supplier_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
-- Adventure Asia is one built-in row per agency (M15).
CREATE UNIQUE INDEX IF NOT EXISTS agency_supplier_aa_uq ON crm.agency_supplier (tenant_id) WHERE kind = 'aa';
CREATE INDEX IF NOT EXISTS agency_supplier_tenant_idx ON crm.agency_supplier (tenant_id, name) WHERE deleted_at IS NULL;
REVOKE DELETE, TRUNCATE ON crm.agency_supplier FROM crm_app;
COMMENT ON TABLE crm.agency_supplier IS 'AA-944 (crm-014; design v3 M15, lane §2.7): the agency''s supplier directory. kind aa = Adventure Asia, one built-in row per agency (crm.ensure_aa_supplier, never changed or trashed by crm_app, CRM22); kind own = the agency''s own suppliers. Contact fields are vault-encrypted. confirmation_unique: confirmation numbers of this supplier are unique even below the strict level. crm_app never deletes a supplier; erasure through crm.erase_subject.';
COMMENT ON COLUMN crm.agency_supplier.contact_name_enc IS 'pii:name; the supplier contact''s name, AES-256-GCM under the tenant vault DEK (AAD tenant, agency_supplier, contact_name_enc, row id)';
COMMENT ON COLUMN crm.agency_supplier.contact_email_enc IS 'pii:contact; the supplier contact''s e-mail, AES-256-GCM under the tenant vault DEK (AAD tenant, agency_supplier, contact_email_enc, row id)';
COMMENT ON COLUMN crm.agency_supplier.default_commission_pct IS 'conf:commercial; the commission the agency expects from this supplier, in percent (suggests commission_expected on a line)';

-- ── 3. crm.booking_line ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.booking_line (
    booking_line_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                         REFERENCES crm.tenant (tenant_id),
    trip_id              UUID NOT NULL,
    supplier_kind        TEXT NOT NULL DEFAULT 'agency',
    agency_supplier_id   UUID NOT NULL,
    bk_hold_id           TEXT,
    bk_booking_id        TEXT,
    departure_id         TEXT,
    status               TEXT NOT NULL DEFAULT 'planning',
    aa_sub_status        TEXT,
    title                TEXT NOT NULL,
    confirmation_no      TEXT,
    conf_unique_key      TEXT,
    service_from         DATE,
    service_to           DATE,
    collect              TEXT NOT NULL DEFAULT 'agency',
    confirm_class        TEXT,
    visible_to_travelers BOOLEAN NOT NULL DEFAULT false,
    confirmed_at         TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ,
    deleted_by           TEXT,
    purge_after          TIMESTAMPTZ,
    CONSTRAINT booking_line_tenant_id_uq UNIQUE (tenant_id, booking_line_id),
    CONSTRAINT booking_line_conf_uq UNIQUE (tenant_id, agency_supplier_id, conf_unique_key),
    CONSTRAINT booking_line_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT booking_line_supplier_fk FOREIGN KEY (tenant_id, agency_supplier_id)
        REFERENCES crm.agency_supplier (tenant_id, agency_supplier_id),
    CONSTRAINT booking_line_supplier_kind_chk CHECK (supplier_kind IN ('aa', 'agency')),
    CONSTRAINT booking_line_status_chk CHECK (status IN ('planning', 'confirmed', 'cancelled')),
    CONSTRAINT booking_line_aa_chk CHECK (
        (supplier_kind = 'aa' OR (aa_sub_status IS NULL AND bk_hold_id IS NULL AND bk_booking_id IS NULL))
        AND (aa_sub_status IS NULL OR aa_sub_status IN ('held', 'on_request', 'declined', 'expired'))
    ),
    CONSTRAINT booking_line_refs_chk CHECK (
        coalesce(bk_hold_id, 'x') ~ '^[A-Za-z0-9:_.-]{1,80}$'
        AND coalesce(bk_booking_id, 'x') ~ '^[A-Za-z0-9:_.-]{1,80}$'
        AND coalesce(departure_id, 'x') ~ '^[A-Za-z0-9:_.-]{1,80}$'
    ),
    CONSTRAINT booking_line_title_chk CHECK (char_length(btrim(title)) BETWEEN 1 AND 200 AND title !~ '[[:cntrl:]]'),
    CONSTRAINT booking_line_confirmation_chk CHECK (
        confirmation_no IS NULL OR (char_length(btrim(confirmation_no)) BETWEEN 1 AND 80
                                    AND confirmation_no !~ '[[:cntrl:]]')
    ),
    CONSTRAINT booking_line_dates_chk CHECK (service_to IS NULL OR service_from IS NULL OR service_to >= service_from),
    CONSTRAINT booking_line_collect_chk CHECK (collect IN ('agency', 'on_arrival')),
    CONSTRAINT booking_line_confirm_class_chk CHECK (
        confirm_class IS NULL OR confirm_class IN ('confirmed', 'aa_on_request', 'agency_booking')
    ),
    CONSTRAINT booking_line_confirmed_at_chk CHECK (status <> 'confirmed' OR confirmed_at IS NOT NULL),
    CONSTRAINT booking_line_cancelled_hidden_chk CHECK (status <> 'cancelled' OR NOT visible_to_travelers),
    CONSTRAINT booking_line_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS booking_line_trip_idx ON crm.booking_line (tenant_id, trip_id);
CREATE INDEX IF NOT EXISTS booking_line_supplier_idx ON crm.booking_line (tenant_id, agency_supplier_id);
CREATE INDEX IF NOT EXISTS booking_line_status_idx ON crm.booking_line (tenant_id, status, service_from)
    WHERE deleted_at IS NULL;
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('booking_line', 'planning', 'confirmed'),
    ('booking_line', 'planning', 'cancelled'),
    ('booking_line', 'confirmed', 'cancelled')
ON CONFLICT DO NOTHING;
REVOKE DELETE, TRUNCATE ON crm.booking_line FROM crm_app;
COMMENT ON TABLE crm.booking_line IS 'AA-944 (crm-014; design v3 M6, R18, R22, R25, R26; lane §2.7): one booked or planned service of a trip. supplier_kind agency = the agency''s own supplier (written by members, confirmed only through crm.booking_line_confirm), aa = an Adventure Asia line from the Booking feed (CRM-19; job / platform actors only, CRM24). Status planning -> confirmed -> cancelled; only confirmed lines count in margins and reports, planning is pipeline value. conf_unique_key backs the strict duplicate check (booking_line_conf_uq). Agency lines do not block a trip delete (no trip_commitment row). conf:commercial; no PII. crm_app never deletes a line; erasure through crm.erase_subject.';
COMMENT ON COLUMN crm.booking_line.conf_unique_key IS 'AA-944: set by crm.guard_booking_line, never by a client: upper(confirmation_no) with letters and digits only while the line is a confirmed agency line and the agency is strict or the supplier is confirmation_unique; else NULL';
COMMENT ON COLUMN crm.booking_line.confirmed_at IS 'AA-944: when the line first became confirmed (set once by the trigger); its date in the agency timezone is the FX basis date (booking_date) of the line''s money';
COMMENT ON COLUMN crm.booking_line.aa_sub_status IS 'AA-944: AA lines only, from the Booking feed (CRM-19): held | on_request | declined | expired';

-- ── 4. crm.booking_line_money (append-only) ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.booking_line_money (
    booking_line_money_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    booking_line_id       UUID NOT NULL,
    kind                  TEXT NOT NULL,
    amount                NUMERIC(14, 2) NOT NULL,
    currency              CHAR(3) NOT NULL,
    base_currency         CHAR(3),
    amount_base           NUMERIC(14, 2),
    fx_rate               NUMERIC(20, 10),
    fx_rate_date          DATE,
    fx_source             TEXT,
    fx_basis              TEXT,
    stale_days            SMALLINT,
    supersedes_id         UUID,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT booking_line_money_tenant_id_uq UNIQUE (tenant_id, booking_line_money_id),
    CONSTRAINT booking_line_money_successor_uq UNIQUE (tenant_id, supersedes_id),
    CONSTRAINT booking_line_money_line_fk FOREIGN KEY (tenant_id, booking_line_id)
        REFERENCES crm.booking_line (tenant_id, booking_line_id),
    CONSTRAINT booking_line_money_supersedes_fk FOREIGN KEY (tenant_id, supersedes_id)
        REFERENCES crm.booking_line_money (tenant_id, booking_line_money_id),
    CONSTRAINT booking_line_money_kind_chk CHECK (kind IN ('cost', 'sell', 'commission_expected')),
    CONSTRAINT booking_line_money_amount_chk CHECK (amount >= 0 AND currency ~ '^[A-Z]{3}$'),
    CONSTRAINT booking_line_money_fx_chk CHECK (
        num_nulls(base_currency, amount_base, fx_rate, fx_rate_date, fx_source, fx_basis, stale_days) IN (0, 7)
        AND (base_currency IS NULL OR (
            base_currency ~ '^[A-Z]{3}$'
            AND fx_rate > 0
            AND amount_base = round(amount * fx_rate, 2)
            AND (base_currency <> currency OR fx_rate = 1)
            AND fx_source IN ('aa_quote_lock', 'platform_daily', 'manual')
            AND fx_basis IN ('booking_date', 'receipt_date', 'quote_lock')
            AND stale_days BETWEEN 0 AND 366
        ))
    ),
    CONSTRAINT booking_line_money_supersedes_chk CHECK (supersedes_id IS NULL OR supersedes_id <> booking_line_money_id)
);
CREATE INDEX IF NOT EXISTS booking_line_money_line_idx ON crm.booking_line_money (tenant_id, booking_line_id, kind);
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON crm.booking_line_money FROM crm_app;
COMMENT ON TABLE crm.booking_line_money IS 'AA-944 (crm-014; design v3 R17, lane §2.1 / §2.7): the money of a booking line, one append-only chain per (line, kind cost | sell | commission_expected); the head (no successor) is current. The FX block is all NULL while the line is planning and frozen (rate, rate date, source, basis booking_date, stale days, base amount) once it is confirmed: a later FX row never changes a stored base amount (card E). A correction is a new row with supersedes_id. Margin protection: crm_app reads it only as owner / agent (or a job / seed actor; never a platform: actor), booking_line_money_margin_roles; writes only through crm.booking_line_money_put / crm.booking_line_confirm. conf:commercial.';
COMMENT ON COLUMN crm.booking_line_money.fx_rate IS 'one unit of currency in base_currency (amount_base = round(amount * fx_rate, 2)); 1 when they are equal';
COMMENT ON COLUMN crm.booking_line_money.stale_days IS 'days between the basis date and the date of the rate used (0 = the rate of that day; the platform had no rate for it otherwise)';

-- ── 6. crm.fx_rate_platform (platform reference table) ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.fx_rate_platform (
    rate_date  DATE NOT NULL,
    base       CHAR(3) NOT NULL,
    quote      CHAR(3) NOT NULL,
    source     TEXT NOT NULL,
    rate       NUMERIC(20, 10) NOT NULL,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (rate_date, base, quote, source),
    CONSTRAINT fx_rate_platform_pair_chk CHECK (base ~ '^[A-Z]{3}$' AND quote ~ '^[A-Z]{3}$' AND base <> quote),
    CONSTRAINT fx_rate_platform_rate_chk CHECK (rate > 0),
    CONSTRAINT fx_rate_platform_source_chk CHECK (
        source IN ('ecb', 'exchangerate_api', 'fawazahmed0', 'sbv', 'booking_b2b', 'manual_aa', 'synthetic')
    )
);
CREATE INDEX IF NOT EXISTS fx_rate_platform_pair_idx ON crm.fx_rate_platform (base, quote, rate_date DESC);
REVOKE UPDATE, DELETE, TRUNCATE ON crm.fx_rate_platform FROM crm_app;
COMMENT ON TABLE crm.fx_rate_platform IS 'AA-944 (crm-014; design v3 R17, lane §2.7 / §3.1): reference FX rates per day, no tenant column, no personal data: 1 base = rate quote, by source (ecb, exchangerate_api for the VND crosses, sbv, booking_b2b = Booking approved rates (CRM-19), manual_aa, synthetic = Dev; fawazahmed0 = cross-check only, never used by crm.fx_resolve). Written by the daily job crm_fx_fetch (ON CONFLICT DO NOTHING); crm_app SELECT + INSERT only. Kept (money rows freeze the rate they used). Never redistributed to agencies as a feed.';

-- ── 7. crm.fx_rate_override (append-only) ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.fx_rate_override (
    fx_rate_override_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    rate_date           DATE NOT NULL,
    base                CHAR(3) NOT NULL,
    quote               CHAR(3) NOT NULL,
    rate                NUMERIC(20, 10) NOT NULL,
    set_by              UUID NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT fx_rate_override_member_fk FOREIGN KEY (tenant_id, set_by) REFERENCES crm.member (tenant_id, member_id),
    CONSTRAINT fx_rate_override_pair_chk CHECK (base ~ '^[A-Z]{3}$' AND quote ~ '^[A-Z]{3}$' AND base <> quote),
    CONSTRAINT fx_rate_override_rate_chk CHECK (rate > 0)
);
CREATE INDEX IF NOT EXISTS fx_rate_override_pair_idx
    ON crm.fx_rate_override (tenant_id, base, quote, rate_date DESC, created_at DESC);
REVOKE UPDATE, DELETE, TRUNCATE ON crm.fx_rate_override FROM crm_app;
COMMENT ON TABLE crm.fx_rate_override IS 'AA-944 (crm-014; design v3 R17): the agency owner''s own rate for a day (1 base = rate quote; e.g. VND), set_by = the member. Append-only: the latest row of a day wins in crm.fx_resolve; rows already frozen into money keep their rate. Erased with the agency.';

-- ── RLS + triggers on the new tenant tables ──────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['agency_supplier', 'booking_line', 'booking_line_money', 'fx_rate_override'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['agency_supplier', 'booking_line'] LOOP
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()',
            t || '_set_updated_at', t);
    END LOOP;
    EXECUTE 'CREATE OR REPLACE TRIGGER booking_line_status_transition BEFORE UPDATE OF status ON crm.booking_line '
            'FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition()';
    -- 8c. Hold rule 4h: a held trip keeps its lines (no delete, trash or move); the agency hold keeps the suppliers.
    EXECUTE 'DROP TRIGGER IF EXISTS booking_line_hold_guard ON crm.booking_line';
    EXECUTE 'CREATE TRIGGER booking_line_hold_guard BEFORE DELETE OR UPDATE ON crm.booking_line FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_held_change(''trip_id'')';
    EXECUTE 'DROP TRIGGER IF EXISTS agency_supplier_hold_guard ON crm.agency_supplier';
    EXECUTE 'CREATE TRIGGER agency_supplier_hold_guard BEFORE DELETE OR UPDATE ON crm.agency_supplier FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_held_change()';
END $$;

-- Margin protection (lane §2.7, S:§3). RESTRICTIVE: ANDed with tenant_isolation, so crm_app reads a money row only in
-- its agency AND as owner / agent (or a context without a member: a job or the seeder; never AA platform staff).
DROP POLICY IF EXISTS booking_line_money_margin_roles ON crm.booking_line_money;
CREATE POLICY booking_line_money_margin_roles ON crm.booking_line_money
    AS RESTRICTIVE
    FOR SELECT TO crm_app
    USING (
        COALESCE(current_setting('app.member_role', true), '') IN ('owner', 'agent')
        OR (COALESCE(current_setting('app.member_role', true), '') = ''
            AND COALESCE(current_setting('app.actor', true), '') ~ '^(job|seed):')
    );
COMMENT ON POLICY booking_line_money_margin_roles ON crm.booking_line_money IS 'AA-944 (crm-014): RESTRICTIVE: crm_app reads money rows only as an owner or agent (app.member_role, set by tenant_tx), or without a member role as a job: / seed: actor. A platform: actor (AA staff) and the assistant read none.';

-- The append-only rule of crm.erasable_append_only() (crm-010) for the two ledger tables: its own function, because
-- crm-010's Guard 1 allows that one on consent / trip_stage_history / llm_call only (as crm-013 did for the inbox).
CREATE OR REPLACE FUNCTION crm.ledger_append_only() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- Only DELETE, only inside crm.erase_subject (it runs as crm_owner and sets app.erasing for its own transaction).
    IF TG_OP = 'DELETE' AND current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'crm: % is append-only (% refused)', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$;
REVOKE ALL ON FUNCTION crm.ledger_append_only() FROM PUBLIC;
COMMENT ON FUNCTION crm.ledger_append_only() IS 'AA-944 (crm-014): crm.booking_line_money and crm.fx_rate_override are append-only; DELETE only as crm_owner inside crm.erase_subject (app.erasing), the crm.erasable_append_only() rule (crm-010) for these tables.';
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['booking_line_money', 'fx_rate_override'] LOOP
        EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE UPDATE OR DELETE ON crm.%I '
                       'FOR EACH ROW EXECUTE FUNCTION crm.ledger_append_only()', t || '_append_only', t);
        EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE TRUNCATE ON crm.%I '
                       'FOR EACH STATEMENT EXECUTE FUNCTION crm.ledger_append_only()', t || '_no_truncate', t);
    END LOOP;
END $$;

-- ── 2. The supplier guard and the built-in AA row ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.guard_agency_supplier() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF current_user::text <> 'crm_app' THEN
        RETURN NEW;  -- crm.ensure_aa_supplier / crm.erase_subject (crm_owner) and unscoped sessions
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.kind = 'aa' THEN
            RAISE EXCEPTION 'crm: aa_supplier_builtin (the Adventure Asia row comes from crm.ensure_aa_supplier)'
                USING ERRCODE = 'CRM22';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.kind = 'aa' OR NEW.kind IS DISTINCT FROM OLD.kind THEN
        RAISE EXCEPTION 'crm: aa_supplier_builtin (the Adventure Asia row and a supplier''s kind do not change)'
            USING ERRCODE = 'CRM22';
    END IF;
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL
       AND EXISTS (SELECT 1 FROM crm.booking_line l
                    WHERE l.agency_supplier_id = OLD.agency_supplier_id AND l.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'crm: supplier_in_use (live booking lines name this supplier)' USING ERRCODE = 'CRM27';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_agency_supplier() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_agency_supplier() IS 'AA-944 (crm-014): for crm_app: no insert of a kind aa row and no change or trash of it, no kind change (CRM22 aa_supplier_builtin); no trash of a supplier that live booking lines name (CRM27 supplier_in_use).';
CREATE OR REPLACE TRIGGER agency_supplier_guard
    BEFORE INSERT OR UPDATE ON crm.agency_supplier
    FOR EACH ROW EXECUTE FUNCTION crm.guard_agency_supplier();

CREATE OR REPLACE FUNCTION crm.ensure_aa_supplier() RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_id uuid;
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: ensure_aa_supplier needs app.tenant_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT s.agency_supplier_id INTO v_id FROM crm.agency_supplier s WHERE s.kind = 'aa';
    IF v_id IS NULL THEN
        INSERT INTO crm.agency_supplier (kind, name, category)
        VALUES ('aa', 'Adventure Asia', 'dmc')
        ON CONFLICT (tenant_id) WHERE kind = 'aa' DO NOTHING
        RETURNING agency_supplier_id INTO v_id;
        IF v_id IS NULL THEN  -- a concurrent call inserted it
            SELECT s.agency_supplier_id INTO v_id FROM crm.agency_supplier s WHERE s.kind = 'aa';
        END IF;
    END IF;
    RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION crm.ensure_aa_supplier() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.ensure_aa_supplier() TO crm_app;
COMMENT ON FUNCTION crm.ensure_aa_supplier() IS 'AA-944 (crm-014, M15): the id of the Adventure Asia supplier row of the agency of app.tenant_id, created when missing (one per agency, agency_supplier_aa_uq). Called by app.agencies.provision_agency and by the supplier list. EXECUTE: crm_app.';

-- ── 3. The booking line guard ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.guard_booking_line() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_app boolean := current_user::text = 'crm_app';
    v_feed boolean := COALESCE(current_setting('app.actor', true), '') ~ '^(job|platform):';
    v_kind text;
    v_unique boolean;
    v_level text;
    v_rekey boolean;
BEGIN
    -- a. AA lines are the Booking feed's (CRM-19): read-only for members.
    IF v_app AND NOT v_feed
       AND ((TG_OP <> 'INSERT' AND OLD.supplier_kind = 'aa') OR (TG_OP <> 'DELETE' AND NEW.supplier_kind = 'aa')) THEN
        RAISE EXCEPTION 'crm: aa_line_read_only (Adventure Asia lines come from the Booking feed)'
            USING ERRCODE = 'CRM24';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    -- b. The supplier's kind matches.
    SELECT s.kind, s.confirmation_unique INTO v_kind, v_unique
      FROM crm.agency_supplier s
     WHERE s.tenant_id = NEW.tenant_id AND s.agency_supplier_id = NEW.agency_supplier_id;
    IF v_kind IS NOT NULL AND (v_kind = 'aa') <> (NEW.supplier_kind = 'aa') THEN
        RAISE EXCEPTION 'crm: supplier_kind_mismatch (an aa line names the Adventure Asia supplier, an agency line an own one)'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'confirmed' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'confirmed') THEN
        -- c. An agency line is confirmed only through crm.booking_line_confirm (runs as crm_owner, freezes the money).
        IF v_app AND NEW.supplier_kind = 'agency' THEN
            RAISE EXCEPTION 'crm: line_not_editable (confirm an agency line through crm.booking_line_confirm)'
                USING ERRCODE = 'CRM26';
        END IF;
    END IF;
    -- d. confirmed_at: NULL until the line is confirmed, then set once.
    IF TG_OP = 'UPDATE' AND OLD.confirmed_at IS NOT NULL THEN
        NEW.confirmed_at := OLD.confirmed_at;
    ELSIF NEW.status = 'confirmed' THEN
        NEW.confirmed_at := COALESCE(NEW.confirmed_at, now());
    ELSE
        NEW.confirmed_at := NULL;
    END IF;
    IF NEW.status = 'cancelled' THEN
        NEW.visible_to_travelers := false;  -- R22
    END IF;
    -- e. Only a planning line goes to the trash (a confirmed one is cancelled first).
    IF TG_OP = 'UPDATE' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND OLD.status <> 'planning' THEN
        RAISE EXCEPTION 'crm: line_not_editable (only a planning line goes to the trash; cancel a % line)', OLD.status
            USING ERRCODE = 'CRM26';
    END IF;
    SELECT COALESCE((SELECT ts.booking_validation_level FROM crm.tenant_settings ts WHERE ts.tenant_id = NEW.tenant_id),
                    'basic')
      INTO v_level;
    -- d'. A confirmed agency line keeps the number its level asked for at confirm (R18 is not undone by an edit).
    IF TG_OP = 'UPDATE' AND OLD.status = 'confirmed' AND NEW.status = 'confirmed' AND NEW.supplier_kind = 'agency'
       AND OLD.confirmation_no IS NOT NULL AND NEW.confirmation_no IS NULL AND v_level <> 'off' THEN
        RAISE EXCEPTION 'crm: line_incomplete:confirmation_no (a confirmed line keeps its confirmation number)'
            USING ERRCODE = 'CRM23';
    END IF;
    -- f. The strict duplicate key (card R). Computed (and the un-keyed lines scanned) only when the line becomes
    -- confirmed or its number or supplier changes: any other edit keeps the stored key, so lines confirmed with one
    -- number before the agency went strict stay editable (title, dates, visibility).
    v_rekey := TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status
               OR OLD.confirmation_no IS DISTINCT FROM NEW.confirmation_no
               OR OLD.agency_supplier_id IS DISTINCT FROM NEW.agency_supplier_id
               OR OLD.supplier_kind IS DISTINCT FROM NEW.supplier_kind;
    IF NEW.supplier_kind = 'agency' AND NEW.status = 'confirmed' AND NEW.confirmation_no IS NOT NULL
       AND (v_level = 'strict' OR COALESCE(v_unique, false)) AND NOT v_rekey THEN
        NEW.conf_unique_key := OLD.conf_unique_key;
    ELSIF NEW.supplier_kind = 'agency' AND NEW.status = 'confirmed' AND NEW.confirmation_no IS NOT NULL
       AND (v_level = 'strict' OR COALESCE(v_unique, false)) THEN
        NEW.conf_unique_key := upper(regexp_replace(NEW.confirmation_no, '[^[:alnum:]]+', '', 'g'));
        -- A line confirmed before the agency went strict (or the supplier became confirmation_unique) has no key; it
        -- still counts. It is committed, so this read sees it; two new confirms racing each other meet in the UNIQUE.
        IF EXISTS (SELECT 1 FROM crm.booking_line o
                    WHERE o.tenant_id = NEW.tenant_id AND o.agency_supplier_id = NEW.agency_supplier_id
                      AND o.booking_line_id <> NEW.booking_line_id AND o.status = 'confirmed'
                      AND o.supplier_kind = 'agency' AND o.conf_unique_key IS NULL AND o.confirmation_no IS NOT NULL
                      AND upper(regexp_replace(o.confirmation_no, '[^[:alnum:]]+', '', 'g')) = NEW.conf_unique_key) THEN
            RAISE EXCEPTION 'crm: duplicate_confirmation_no (a confirmed line of this supplier has this number)'
                USING ERRCODE = 'unique_violation', CONSTRAINT = 'booking_line_conf_uq';
        END IF;
    ELSE
        NEW.conf_unique_key := NULL;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_booking_line() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_booking_line() IS 'AA-944 (crm-014, file header item 3a-3f): aa lines only from a job: / platform: actor (CRM24 aa_line_read_only); the supplier''s kind matches; an agency line is confirmed only through crm.booking_line_confirm (CRM26); confirmed_at NULL until confirmed, then set once; a confirmed agency line keeps its confirmation_no unless the level is off (CRM23); a cancelled line is hidden from travellers; only a planning line is trashed (CRM26); conf_unique_key for the strict duplicate check, recomputed only when the line becomes confirmed or its number or supplier changes.';
CREATE OR REPLACE TRIGGER booking_line_guard
    BEFORE INSERT OR UPDATE OR DELETE ON crm.booking_line
    FOR EACH ROW EXECUTE FUNCTION crm.guard_booking_line();

-- ── 4. The money chain ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.booking_line_money_chain() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_line uuid;
    v_kind text;
BEGIN
    -- One writer per line at a time: the chain head read below cannot move under us.
    PERFORM 1 FROM crm.booking_line l WHERE l.tenant_id = NEW.tenant_id AND l.booking_line_id = NEW.booking_line_id
       FOR UPDATE;
    IF NEW.supersedes_id IS NULL THEN
        IF EXISTS (SELECT 1 FROM crm.booking_line_money m
                    WHERE m.booking_line_id = NEW.booking_line_id AND m.kind = NEW.kind) THEN
            RAISE EXCEPTION 'crm: money_chain (the % chain of this line exists: supersede its head)', NEW.kind
                USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        SELECT m.booking_line_id, m.kind INTO v_line, v_kind
          FROM crm.booking_line_money m WHERE m.booking_line_money_id = NEW.supersedes_id;
        IF v_line IS DISTINCT FROM NEW.booking_line_id OR v_kind IS DISTINCT FROM NEW.kind THEN
            RAISE EXCEPTION 'crm: money_chain (a row supersedes a row of the same line and kind)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.booking_line_money_chain() FROM PUBLIC;
COMMENT ON FUNCTION crm.booking_line_money_chain() IS 'AA-944 (crm-014): a money chain per (line, kind) starts once and each row supersedes a row of the same line and kind (with booking_line_money_successor_uq: linear chains, the head is current).';
CREATE OR REPLACE TRIGGER booking_line_money_chain
    BEFORE INSERT ON crm.booking_line_money
    FOR EACH ROW EXECUTE FUNCTION crm.booking_line_money_chain();

-- The head of each chain, read through the caller's own policies (security_invoker: never crm_owner's, so the margin
-- policy still hides every row from the assistant).
CREATE OR REPLACE VIEW crm.v_booking_line_money_current WITH (security_invoker = true) AS
SELECT m.*
  FROM crm.booking_line_money m
 WHERE NOT EXISTS (SELECT 1 FROM crm.booking_line_money n
                    WHERE n.tenant_id = m.tenant_id AND n.supersedes_id = m.booking_line_money_id);
REVOKE ALL ON crm.v_booking_line_money_current FROM crm_app;
GRANT SELECT ON crm.v_booking_line_money_current TO crm_app;
COMMENT ON VIEW crm.v_booking_line_money_current IS 'AA-944 (crm-014): the head row of every money chain (cost, sell, commission_expected per line). security_invoker: reads through the caller''s policies (the assistant sees none).';

-- ── 5. FX resolution, the confirm check, the confirm and the money writer ────────────────────────
CREATE OR REPLACE FUNCTION crm.fx_resolve(p_from text, p_to text, p_date date)
    RETURNS TABLE (rate numeric, rate_date date, fx_source text, stale_days integer)
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_mode text;
    v_override numeric;
    v_override_date date;
    v_platform numeric;
    v_platform_date date;
BEGIN
    IF p_from IS NULL OR p_to IS NULL OR p_date IS NULL THEN
        RAISE EXCEPTION 'crm: fx_resolve needs two currencies and a date' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_from = p_to THEN
        RETURN QUERY SELECT 1::numeric, p_date, 'platform_daily'::text, 0;
        RETURN;
    END IF;
    SELECT COALESCE((SELECT ts.fx_mode FROM crm.tenant_settings ts), 'automatic') INTO v_mode;
    -- The agency override (direct or inverse), latest day <= p_date, latest row of that day.
    SELECT x.r, x.d INTO v_override, v_override_date
      FROM (SELECT f.rate AS r, f.rate_date AS d, f.created_at AS c FROM crm.fx_rate_override f
             WHERE f.base = p_from AND f.quote = p_to AND f.rate_date BETWEEN p_date - 30 AND p_date
            UNION ALL
            SELECT round(1 / f.rate, 10), f.rate_date, f.created_at FROM crm.fx_rate_override f
             WHERE f.base = p_to AND f.quote = p_from AND f.rate_date BETWEEN p_date - 30 AND p_date) x
     ORDER BY x.d DESC, x.c DESC
     LIMIT 1;
    IF v_mode = 'automatic' THEN
        -- Platform rates: direct, inverse, or crossed through USD / EUR on one day and source.
        WITH legs AS (
            SELECT f.rate_date AS d, f.source AS s, f.base AS a, f.quote AS b, f.rate AS r
              FROM crm.fx_rate_platform f
             WHERE f.rate_date BETWEEN p_date - 30 AND p_date AND f.source <> 'fawazahmed0'
            UNION ALL
            SELECT f.rate_date, f.source, f.quote, f.base, round(1 / f.rate, 10)
              FROM crm.fx_rate_platform f
             WHERE f.rate_date BETWEEN p_date - 30 AND p_date AND f.source <> 'fawazahmed0'
        ), candidates AS (
            SELECT l.d, l.s, l.r, 0 AS hops FROM legs l WHERE l.a = p_from AND l.b = p_to
            UNION ALL
            SELECT l1.d, l1.s, round(l1.r * l2.r, 10), 1
              FROM legs l1 JOIN legs l2 ON l2.d = l1.d AND l2.s = l1.s AND l2.a = l1.b
             WHERE l1.a = p_from AND l2.b = p_to AND l1.b IN ('USD', 'EUR')
        )
        SELECT c.r, c.d INTO v_platform, v_platform_date
          FROM candidates c
         ORDER BY c.d DESC,
                  array_position(ARRAY['booking_b2b', 'manual_aa', 'ecb', 'exchangerate_api', 'sbv', 'synthetic'], c.s),
                  c.hops
         LIMIT 1;
    END IF;
    -- The override of a day wins over the platform rate of the same day; otherwise the later day wins.
    IF v_override IS NOT NULL AND (v_platform IS NULL OR v_override_date >= v_platform_date) THEN
        RETURN QUERY SELECT v_override, v_override_date, 'manual'::text, (p_date - v_override_date)::integer;
    ELSIF v_platform IS NOT NULL THEN
        RETURN QUERY SELECT v_platform, v_platform_date, 'platform_daily'::text, (p_date - v_platform_date)::integer;
    END IF;
    -- No row: no rate within 30 days.
END;
$$;
REVOKE ALL ON FUNCTION crm.fx_resolve(text, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.fx_resolve(text, text, date) TO crm_app;
COMMENT ON FUNCTION crm.fx_resolve(text, text, date) IS 'AA-944 (crm-014, R17 §3.1): the rate of one unit of p_from in p_to for p_date in the agency of app.tenant_id: the agency override of that day, else the platform rate of that day, else the latest earlier day within 30 days (stale_days = the gap); an override wins a tie; platform rates direct, inverse or crossed through USD / EUR on one day and source (priority booking_b2b, manual_aa, ecb, exchangerate_api, sbv, synthetic; fawazahmed0 never); fx_mode manual: overrides only. p_from = p_to: 1. No row = no rate. fx_source = manual (override) or platform_daily. Invoker rights.';

CREATE OR REPLACE FUNCTION crm.booking_line_confirm_check(p_line uuid) RETURNS text[]
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_line record;
    v_level text;
    v_missing text[] := '{}';
BEGIN
    SELECT l.confirmation_no, l.supplier_kind INTO v_line FROM crm.booking_line l WHERE l.booking_line_id = p_line;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (booking_line %)', p_line USING ERRCODE = 'CRM13';
    END IF;
    SELECT COALESCE((SELECT ts.booking_validation_level FROM crm.tenant_settings ts), 'basic') INTO v_level;
    IF v_line.supplier_kind <> 'agency' OR v_level = 'off' THEN
        RETURN v_missing;
    END IF;
    IF v_line.confirmation_no IS NULL THEN
        v_missing := v_missing || 'confirmation_no'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM crm.booking_line_money m WHERE m.booking_line_id = p_line AND m.kind = 'cost') THEN
        v_missing := v_missing || 'cost'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM crm.booking_line_money m WHERE m.booking_line_id = p_line AND m.kind = 'sell') THEN
        v_missing := v_missing || 'sell'::text;
    END IF;
    IF v_level = 'strict' AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money m
                                           WHERE m.booking_line_id = p_line AND m.kind = 'commission_expected') THEN
        v_missing := v_missing || 'commission'::text;
    END IF;
    RETURN v_missing;
END;
$$;
REVOKE ALL ON FUNCTION crm.booking_line_confirm_check(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.booking_line_confirm_check(uuid) TO crm_app;
COMMENT ON FUNCTION crm.booking_line_confirm_check(uuid) IS 'AA-944 (crm-014, R18): what an agency line of the agency of app.tenant_id still misses before confirmed at the agency''s level: codes confirmation_no, cost, sell (basic, strict), commission (strict). Codes only, never an amount, so an assistant''s confirm is checked without reading money. SECURITY DEFINER (crm_owner under FORCE RLS: one agency); EXECUTE crm_app.';

-- The money writer both entry points share (not executable by anyone but its owner).
CREATE OR REPLACE FUNCTION crm.booking_line_money_write(p_line uuid, p_kind text, p_amount numeric, p_currency text,
                                                        p_status text, p_confirmed_at timestamptz) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_head record;
    v_base text;
    v_tz text;
    v_date date;
    v_fx record;
    v_id uuid;
BEGIN
    SELECT m.* INTO v_head
      FROM crm.booking_line_money m
     WHERE m.booking_line_id = p_line AND m.kind = p_kind
       AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money n WHERE n.supersedes_id = m.booking_line_money_id);
    IF v_head.booking_line_money_id IS NOT NULL AND v_head.amount = p_amount AND v_head.currency = p_currency
       AND (p_status <> 'confirmed' OR v_head.fx_rate IS NOT NULL) THEN
        RETURN v_head.booking_line_money_id;  -- nothing changes
    END IF;
    IF p_status <> 'confirmed' THEN
        INSERT INTO crm.booking_line_money (booking_line_id, kind, amount, currency, supersedes_id)
        VALUES (p_line, p_kind, p_amount, p_currency, v_head.booking_line_money_id)
        RETURNING booking_line_money_id INTO v_id;
        RETURN v_id;
    END IF;
    SELECT COALESCE((SELECT ts.base_currency FROM crm.tenant_settings ts), 'USD'),
           COALESCE((SELECT ts.timezone FROM crm.tenant_settings ts), 'Asia/Ho_Chi_Minh')
      INTO v_base, v_tz;
    IF v_head.fx_rate IS NOT NULL AND v_head.currency = p_currency THEN
        -- A correction in the same currency keeps the frozen rate (R17: no drift).
        INSERT INTO crm.booking_line_money (booking_line_id, kind, amount, currency, base_currency, amount_base,
                                            fx_rate, fx_rate_date, fx_source, fx_basis, stale_days, supersedes_id)
        VALUES (p_line, p_kind, p_amount, p_currency, v_head.base_currency, round(p_amount * v_head.fx_rate, 2),
                v_head.fx_rate, v_head.fx_rate_date, v_head.fx_source, v_head.fx_basis, v_head.stale_days,
                v_head.booking_line_money_id)
        RETURNING booking_line_money_id INTO v_id;
        RETURN v_id;
    END IF;
    v_date := (p_confirmed_at AT TIME ZONE v_tz)::date;  -- booking_date in the agency timezone
    SELECT r.rate, r.rate_date, r.fx_source, r.stale_days INTO v_fx FROM crm.fx_resolve(p_currency, v_base, v_date) r;
    IF v_fx.rate IS NULL THEN
        RAISE EXCEPTION 'crm: fx_rate_missing:% (no rate % -> % within 30 days of %)', p_currency, p_currency, v_base,
            v_date USING ERRCODE = 'CRM25';
    END IF;
    INSERT INTO crm.booking_line_money (booking_line_id, kind, amount, currency, base_currency, amount_base, fx_rate,
                                        fx_rate_date, fx_source, fx_basis, stale_days, supersedes_id)
    VALUES (p_line, p_kind, p_amount, p_currency, v_base, round(p_amount * v_fx.rate, 2), v_fx.rate, v_fx.rate_date,
            v_fx.fx_source, 'booking_date', LEAST(v_fx.stale_days, 366), v_head.booking_line_money_id)
    RETURNING booking_line_money_id INTO v_id;
    RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION crm.booking_line_money_write(uuid, text, numeric, text, text, timestamptz) FROM PUBLIC;
COMMENT ON FUNCTION crm.booking_line_money_write(uuid, text, numeric, text, text, timestamptz) IS 'AA-944 (crm-014): the one money writer behind crm.booking_line_money_put and crm.booking_line_confirm (no EXECUTE for anyone else): a new head row of the (line, kind) chain; nothing when the head already has the amount and currency (and is frozen on a confirmed line); on a confirmed line frozen at once, re-using the head''s rate in the same currency, else crm.fx_resolve for the confirmation date in the agency timezone (CRM25 fx_rate_missing).';

CREATE OR REPLACE FUNCTION crm.booking_line_money_put(p_line uuid, p_kind text, p_amount numeric, p_currency text)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_role text := COALESCE(current_setting('app.member_role', true), '');
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_line record;
BEGIN
    IF NOT (v_role IN ('owner', 'agent') OR (v_role = '' AND v_actor ~ '^(job|seed):')) THEN
        RAISE EXCEPTION 'crm: margin_forbidden (only an owner or an agent writes line money)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('cost', 'sell', 'commission_expected') OR p_amount IS NULL OR p_amount < 0
       OR p_currency IS NULL OR p_currency !~ '^[A-Z]{3}$' THEN
        RAISE EXCEPTION 'crm: money_invalid (kind, amount >= 0 and an ISO currency)' USING ERRCODE = 'check_violation';
    END IF;
    SELECT l.status, l.supplier_kind, l.confirmed_at, l.deleted_at INTO v_line
      FROM crm.booking_line l WHERE l.booking_line_id = p_line FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (booking_line %)', p_line USING ERRCODE = 'CRM13';
    END IF;
    IF v_line.supplier_kind = 'aa' THEN
        RAISE EXCEPTION 'crm: aa_line_read_only (Adventure Asia lines come from the Booking feed)'
            USING ERRCODE = 'CRM24';
    END IF;
    IF v_line.status = 'cancelled' OR v_line.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'crm: line_not_editable (% line)', CASE WHEN v_line.deleted_at IS NOT NULL THEN 'trashed'
                                                                ELSE v_line.status END
            USING ERRCODE = 'CRM26';
    END IF;
    RETURN crm.booking_line_money_write(p_line, p_kind, round(p_amount, 2), p_currency, v_line.status,
                                        v_line.confirmed_at);
END;
$$;
REVOKE ALL ON FUNCTION crm.booking_line_money_put(uuid, text, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.booking_line_money_put(uuid, text, numeric, text) TO crm_app;
COMMENT ON FUNCTION crm.booking_line_money_put(uuid, text, numeric, text) IS 'AA-944 (crm-014, R17): writes the cost, sell or commission_expected of an agency line of the agency of app.tenant_id as a new head row (crm.booking_line_money_write). Owner / agent, or a job / seed actor without a member role (42501 margin_forbidden otherwise; a platform: actor too); not an aa line (CRM24), a cancelled or trashed line (CRM26). Returns the head row id. SECURITY DEFINER; EXECUTE crm_app.';

CREATE OR REPLACE FUNCTION crm.booking_line_confirm(p_line uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_role text := COALESCE(current_setting('app.member_role', true), '');
    v_line record;
    v_missing text[];
    v_blocking text[];
    v_at timestamptz := now();
    v_frozen integer := 0;
    v_stale integer := 0;
    m record;
    v_id uuid;
BEGIN
    SELECT l.status, l.supplier_kind, l.deleted_at INTO v_line
      FROM crm.booking_line l WHERE l.booking_line_id = p_line FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (booking_line %)', p_line USING ERRCODE = 'CRM13';
    END IF;
    IF v_line.supplier_kind = 'aa' THEN
        RAISE EXCEPTION 'crm: aa_line_read_only (Adventure Asia lines come from the Booking feed)'
            USING ERRCODE = 'CRM24';
    END IF;
    IF v_line.status <> 'planning' OR v_line.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'crm: line_not_editable (only a planning line is confirmed)' USING ERRCODE = 'CRM26';
    END IF;
    v_missing := crm.booking_line_confirm_check(p_line);
    -- R18: the assistant is never blocked by a missing commission (the API opens the owner task instead).
    SELECT COALESCE(array_agg(x), '{}') INTO v_blocking
      FROM unnest(v_missing) x WHERE NOT (x = 'commission' AND v_role = 'assistant');
    IF cardinality(v_blocking) > 0 THEN
        RAISE EXCEPTION 'crm: line_incomplete:%', array_to_string(v_blocking, ',') USING ERRCODE = 'CRM23';
    END IF;
    -- Freeze every unfrozen head at the confirmation date (fx_basis booking_date).
    FOR m IN SELECT h.kind, h.amount, h.currency FROM crm.booking_line_money h
              WHERE h.booking_line_id = p_line AND h.fx_rate IS NULL
                AND NOT EXISTS (SELECT 1 FROM crm.booking_line_money n WHERE n.supersedes_id = h.booking_line_money_id)
              ORDER BY h.kind LOOP
        v_id := crm.booking_line_money_write(p_line, m.kind, m.amount, m.currency, 'confirmed', v_at);
        v_frozen := v_frozen + 1;
        v_stale := GREATEST(v_stale, (SELECT x.stale_days FROM crm.booking_line_money x
                                       WHERE x.booking_line_money_id = v_id));
    END LOOP;
    UPDATE crm.booking_line SET status = 'confirmed', confirmed_at = v_at WHERE booking_line_id = p_line;
    RETURN jsonb_build_object('frozen', v_frozen, 'stale_days', v_stale, 'pending', to_jsonb(v_missing));
END;
$$;
REVOKE ALL ON FUNCTION crm.booking_line_confirm(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.booking_line_confirm(uuid) TO crm_app;
COMMENT ON FUNCTION crm.booking_line_confirm(uuid) IS 'AA-944 (crm-014, R17, R18): confirms a planning agency line of the agency of app.tenant_id: the level''s missing codes refuse it (CRM23 line_incomplete:<codes>), except a missing commission for the assistant (returned in pending: the API opens the owner task); every unfrozen money head is frozen at the confirmation date (CRM25 fx_rate_missing); then status confirmed (the strict duplicate key may raise unique_violation booking_line_conf_uq). Returns {frozen, stale_days, pending}, codes and counts only. CRM13 unknown line, CRM24 aa line, CRM26 not planning. SECURITY DEFINER; EXECUTE crm_app.';

-- ── 8a. crm.erase_held (crm-010 hold rule 4e): the crm-012 text plus the ledger scopes ───────────
CREATE OR REPLACE FUNCTION crm.erase_held(p_scope text, p_subject uuid, p_token uuid DEFAULT NULL) RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM crm.legal_hold h WHERE h.status = 'active') THEN
        RETURN false;  -- nothing is held in this agency
    END IF;
    IF p_scope = 'tenant' THEN
        RETURN true;  -- the agency erase reaches every subject: any active hold stops it
    END IF;
    IF p_subject IS NULL THEN
        RETURN crm.hold_row(NULL, NULL);
    END IF;
    IF p_scope = 'trip' THEN
        -- dispatch_queue, trip_commitment, document, note, task, trip_stage_history, trip_party, trip_traveler,
        -- client_link, meeting_slot, form_submission (trip_id := NULL), booking_line (and its money) and the trip: all
        -- carry trip_id = the trip (4d through hold_trip), and these name a traveller too.
        RETURN crm.hold_trip(p_subject) OR EXISTS (
            SELECT 1
              FROM (SELECT tt.traveler_id FROM crm.trip_traveler tt WHERE tt.trip_id = p_subject
                    UNION ALL
                    SELECT n.traveler_id FROM crm.note n WHERE n.trip_id = p_subject
                    UNION ALL
                    SELECT d.traveler_id FROM crm.document d WHERE d.trip_id = p_subject
                    UNION ALL
                    SELECT f.traveler_id FROM crm.form_submission f WHERE f.trip_id = p_subject
                    UNION ALL
                    SELECT q.traveler_id FROM crm.dispatch_queue q WHERE q.trip_id = p_subject
                    UNION ALL
                    SELECT l.traveler_id FROM crm.client_link l WHERE l.trip_id = p_subject
                    UNION ALL
                    SELECT m.traveler_id FROM crm.meeting_slot m WHERE m.trip_id = p_subject) x
             WHERE x.traveler_id IS NOT NULL AND crm.hold_traveler(x.traveler_id));
    ELSIF p_scope = 'traveler' THEN
        -- dispatch_queue, traveler_health, document, note, trip_traveler, consent, form_submission, client_link and the
        -- traveller carry traveler_id = the traveller (4d through hold_traveler); trip_party / profile_history /
        -- traveler_profile are the traveller's own F2 rows (by token); these name a trip too; every relation from or
        -- to them (both rows); every client they referred (referrer_traveler_id := NULL rewrites that client's row);
        -- every call slot of theirs or booked by one of their submissions (it may name another traveller).
        RETURN crm.hold_traveler(p_subject)
            OR EXISTS (
                SELECT 1
                  FROM (SELECT tt.trip_id FROM crm.trip_traveler tt WHERE tt.traveler_id = p_subject
                        UNION ALL
                        SELECT n.trip_id FROM crm.note n WHERE n.traveler_id = p_subject
                        UNION ALL
                        SELECT d.trip_id FROM crm.document d WHERE d.traveler_id = p_subject
                        UNION ALL
                        SELECT f.trip_id FROM crm.form_submission f WHERE f.traveler_id = p_subject
                        UNION ALL
                        SELECT q.trip_id FROM crm.dispatch_queue q WHERE q.traveler_id = p_subject
                        UNION ALL
                        SELECT l.trip_id FROM crm.client_link l WHERE l.traveler_id = p_subject
                        UNION ALL
                        SELECT p.trip_id FROM crm.trip_party p
                         WHERE p_token IS NOT NULL AND p.traveler_token = p_token) x
                 WHERE x.trip_id IS NOT NULL AND crm.hold_trip(x.trip_id))
            OR EXISTS (
                SELECT 1 FROM crm.meeting_slot m
                 WHERE (m.traveler_id = p_subject
                        OR m.form_submission_id IN (SELECT s.submission_id FROM crm.form_submission s
                                                     WHERE s.traveler_id = p_subject))
                   AND crm.hold_row(m.trip_id, m.traveler_id))
            OR EXISTS (
                SELECT 1 FROM crm.traveler_relation rel
                 WHERE (rel.from_traveler_id = p_subject OR rel.to_traveler_id = p_subject)
                   AND (crm.hold_traveler(rel.from_traveler_id) OR crm.hold_traveler(rel.to_traveler_id)))
            OR EXISTS (
                SELECT 1 FROM crm.traveler t
                 WHERE t.referrer_traveler_id = p_subject AND crm.hold_traveler(t.traveler_id));
    ELSIF p_scope = 'task' THEN
        RETURN EXISTS (SELECT 1 FROM crm.task k WHERE k.task_id = p_subject AND crm.hold_trip(k.trip_id));
    ELSIF p_scope = 'note' THEN
        RETURN EXISTS (SELECT 1 FROM crm.note n WHERE n.note_id = p_subject AND crm.hold_row(n.trip_id, n.traveler_id));
    ELSIF p_scope = 'document' THEN
        RETURN EXISTS (SELECT 1 FROM crm.document d
                        WHERE d.document_id = p_subject AND crm.hold_row(d.trip_id, d.traveler_id));
    ELSIF p_scope = 'relation' THEN
        -- The row and its inverse (crm-006 mirrors the delete) have the same two ends.
        RETURN EXISTS (SELECT 1 FROM crm.traveler_relation rel
                        WHERE rel.relation_id = p_subject
                          AND (crm.hold_traveler(rel.from_traveler_id) OR crm.hold_traveler(rel.to_traveler_id)));
    ELSIF p_scope = 'booking_line' THEN
        -- crm-014: the line and its money carry the line's trip.
        RETURN EXISTS (SELECT 1 FROM crm.booking_line l
                        WHERE l.booking_line_id = p_subject AND crm.hold_trip(l.trip_id));
    END IF;
    -- Subject-less data (llm_call, placeholder_map) and agency_supplier (crm-014; it names no trip or traveller): the
    -- agency hold only.
    RETURN crm.hold_row(NULL, NULL);
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_held(text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_held(text, uuid, uuid) TO crm_app;
COMMENT ON FUNCTION crm.erase_held(text, uuid, uuid) IS 'AA-942 (crm-010, hold rule 4e), extended by AA-943 (crm-012) to client_link and meeting_slot and by AA-944 (crm-014) to the scopes booking_line (its trip held) and agency_supplier (the agency hold): true when crm.erase_subject(scope, subject, token) would delete or update a held row (every step''s rows, both rows of a relation, the clients a traveller referred, the submissions a trip unlinks, the call slots a traveller''s submissions booked); scope tenant: any active hold of the agency. crm.erase_subject refuses with CRM10 on it, dry run too. Invoker rights.';

-- ── 8b. crm.erase_subject: the crm-013 text plus the ledger ──────────────────────────────────────
-- crm-015 starts from THIS text.
CREATE OR REPLACE FUNCTION crm.erase_subject(p_scope text, p_subject uuid, p_profile_token uuid DEFAULT NULL,
                                             p_dry_run boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tenant uuid := NULLIF(current_setting('app.tenant_id', true), '')::uuid;
    v_actor text := COALESCE(current_setting('app.actor', true), '');
    v_counts jsonb := '{}'::jsonb;
    v_blockers text[];
    v_status text;
    v_has_token boolean;
    v_step text[];
    v_left text[] := '{}';
    r record;
    -- Tables an agency erase keeps: the agency row (status offboarded), the destroyed key rows, the audit and its
    -- export registry and chain (crm-007: they leave with the partition drops / the archive), the erasure receipts,
    -- the lifecycle counts and the holds (ids and codes only).
    c_keep CONSTANT text[] := ARRAY['tenant', 'tenant_key', 'audit_event', 'audit_export_tenant',
                                    'audit_export_manifest', 'erasure_request', 'lifecycle_run', 'legal_hold'];
BEGIN
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs app.tenant_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_dry_run IS NULL OR p_subject IS NULL THEN
        RAISE EXCEPTION 'crm: erase_subject needs a subject and dry_run true or false'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_scope NOT IN ('trip', 'traveler', 'task', 'note', 'document', 'relation', 'booking_line', 'agency_supplier',
                       'tenant') THEN
        RAISE EXCEPTION 'crm: erase_subject scope % is unknown', p_scope USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Hold rule 4g: serialise with hold placement. SHARE conflicts with the ROW EXCLUSIVE of an INSERT / UPDATE on
    -- crm.legal_hold: a hold placed now waits until this transaction ends; a hold being placed makes this wait, then
    -- the check below (a new snapshot: this function is VOLATILE) sees it.
    LOCK TABLE crm.legal_hold IN SHARE MODE;

    -- The subject must exist in this agency (FORCE RLS: crm_owner sees app.tenant_id's rows only).
    IF p_scope = 'trip' THEN
        -- FOR UPDATE: a row that would reference the subject (FOR KEY SHARE of its foreign key) waits until this erase
        -- ends, so nothing is attached to it between the hold check and the deletes (the hold guard triggers catch
        -- any other change).
        PERFORM 1 FROM crm.trip WHERE trip_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'traveler' THEN
        SELECT profile_token_enc IS NOT NULL INTO v_has_token FROM crm.traveler WHERE traveler_id = p_subject
           FOR UPDATE;
    ELSIF p_scope = 'task' THEN
        PERFORM 1 FROM crm.task WHERE task_id = p_subject;
    ELSIF p_scope = 'note' THEN
        PERFORM 1 FROM crm.note WHERE note_id = p_subject;
    ELSIF p_scope = 'document' THEN
        PERFORM 1 FROM crm.document WHERE document_id = p_subject;
    ELSIF p_scope = 'relation' THEN
        PERFORM 1 FROM crm.traveler_relation WHERE relation_id = p_subject;
    ELSIF p_scope = 'booking_line' THEN
        PERFORM 1 FROM crm.booking_line WHERE booking_line_id = p_subject FOR UPDATE;
    ELSIF p_scope = 'agency_supplier' THEN
        SELECT kind INTO v_status FROM crm.agency_supplier WHERE agency_supplier_id = p_subject FOR UPDATE;
    ELSE
        IF p_subject <> v_tenant THEN
            RAISE EXCEPTION 'crm: subject_not_found (a tenant erase names the agency of app.tenant_id)'
                USING ERRCODE = 'CRM13';
        END IF;
        SELECT status INTO v_status FROM crm.tenant WHERE tenant_id = v_tenant;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'crm: subject_not_found (% %)', p_scope, p_subject USING ERRCODE = 'CRM13';
    END IF;

    -- Hold rule 4e: any held row among those this erase would delete or update refuses it, dry run included.
    IF crm.erase_held(p_scope, p_subject, p_profile_token) THEN
        RAISE EXCEPTION 'crm: legal_hold (an active legal hold reaches a row the erase of % % would change)',
            p_scope, p_subject USING ERRCODE = 'CRM10';
    END IF;

    IF p_scope = 'trip' THEN
        v_blockers := crm.trip_delete_blockers(p_subject);
        IF cardinality(v_blockers) > 0 THEN
            RAISE EXCEPTION 'crm: delete_blocked %', array_to_string(v_blockers, ',') USING ERRCODE = 'CRM11';
        END IF;
    ELSIF p_scope = 'traveler' THEN
        IF EXISTS (SELECT 1 FROM crm.trip_traveler tt JOIN crm.trip t ON t.trip_id = tt.trip_id
                    WHERE tt.traveler_id = p_subject AND t.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'crm: traveler_on_trip (delete or erase the client''s live trips first)'
                USING ERRCODE = 'CRM12';
        END IF;
        IF v_has_token AND p_profile_token IS NULL THEN
            RAISE EXCEPTION 'crm: profile_token_required' USING ERRCODE = 'CRM15';
        END IF;
        -- Consistency guard (the database cannot open the encrypted pointer; the caller decrypted it from this row,
        -- bound by its AAD): every party row of the token is the F2 twin of one of the traveller's own party rows
        -- (same trip, same role).
        IF p_profile_token IS NOT NULL AND EXISTS (
            SELECT 1 FROM crm.trip_party p
             WHERE p.traveler_token = p_profile_token
               AND NOT EXISTS (SELECT 1 FROM crm.trip_traveler tt
                                WHERE tt.trip_id = p.trip_id AND tt.traveler_id = p_subject AND tt.role = p.role)) THEN
            RAISE EXCEPTION 'crm: profile_token_mismatch' USING ERRCODE = 'CRM15';
        END IF;
    ELSIF p_scope = 'agency_supplier' THEN
        -- crm-014: the built-in Adventure Asia row leaves only with the agency; a supplier lines still name stays.
        IF v_status = 'aa' THEN
            RAISE EXCEPTION 'crm: aa_supplier_builtin (the Adventure Asia row leaves with the agency only)'
                USING ERRCODE = 'CRM22';
        END IF;
        IF EXISTS (SELECT 1 FROM crm.booking_line l WHERE l.agency_supplier_id = p_subject) THEN
            RAISE EXCEPTION 'crm: supplier_in_use (booking lines name this supplier)' USING ERRCODE = 'CRM27';
        END IF;
    ELSIF p_scope = 'tenant' AND NOT p_dry_run AND v_status <> 'offboarding' THEN
        -- A dry run (the counts the owner sees before confirming) works on an active agency.
        RAISE EXCEPTION 'crm: tenant_not_offboarding (status %)', v_status USING ERRCODE = 'CRM14';
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', 'on', true);
    END IF;

    IF p_scope = 'trip' THEN
        -- crm-012: the trip's submissions let go of the trip and of its links first, then the links and slots go.
        -- crm-014: the trip's line money, then its lines.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['form_submission', 'trip_id = $1', 'trip_id = NULL, client_link_id = NULL'],
            ['client_link', 'trip_id = $1', ''],
            ['meeting_slot', 'trip_id = $1', ''],
            ['dispatch_queue', 'trip_id = $1', ''],
            ['trip_commitment', 'trip_id = $1', ''],
            ['booking_line_money', 'booking_line_id IN (SELECT l.booking_line_id FROM crm.booking_line l '
                                   'WHERE l.trip_id = $1)', ''],
            ['booking_line', 'trip_id = $1', ''],
            ['document', 'trip_id = $1', ''],
            ['note', 'trip_id = $1', ''],
            ['task', 'trip_id = $1', ''],
            ['trip_stage_history', 'trip_id = $1', ''],
            ['trip_party', 'trip_id = $1', ''],
            ['trip_traveler', 'trip_id = $1', ''],
            ['trip', 'trip_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] <> '' THEN '_unlinked' ELSE '' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, NULL, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope = 'traveler' THEN
        -- crm-012: their call slots (also those their submissions booked) before the submissions, their links after.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['meeting_slot', 'traveler_id = $1 OR form_submission_id IN (SELECT s.submission_id '
                             'FROM crm.form_submission s WHERE s.traveler_id = $1)', ''],
            ['dispatch_queue', 'traveler_id = $1', ''],
            ['traveler_health', 'traveler_id = $1', ''],
            ['document', 'traveler_id = $1', ''],
            ['note', 'traveler_id = $1', ''],
            ['traveler_relation', 'from_traveler_id = $1 OR to_traveler_id = $1', ''],
            ['trip_traveler', 'traveler_id = $1', ''],
            ['trip_party', 'traveler_token = $2', ''],
            ['profile_history', 'traveler_token = $2', ''],
            ['traveler_profile', 'traveler_token = $2', ''],
            ['consent', 'traveler_id = $1', ''],
            ['form_submission', 'traveler_id = $1', ''],
            ['client_link', 'traveler_id = $1', ''],
            ['traveler', 'referrer_traveler_id = $1', 'referrer_traveler_id = NULL'],
            ['traveler', 'traveler_id = $1', '']
        ] LOOP
            v_counts := v_counts || jsonb_build_object(
                v_step[1] || CASE WHEN v_step[3] <> '' THEN '_referrer_unlinked' ELSE '' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, p_profile_token, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope IN ('task', 'note', 'document') THEN
        v_counts := jsonb_build_object(p_scope,
            crm.erase_rows(p_scope, p_scope || '_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'relation' THEN
        v_counts := jsonb_build_object('traveler_relation',
            crm.erase_rows('traveler_relation', 'relation_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'booking_line' THEN
        -- crm-014: the trash purge of a planning line: its money, then the line.
        v_counts := jsonb_build_object(
            'booking_line_money', crm.erase_rows('booking_line_money', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
            'booking_line', crm.erase_rows('booking_line', 'booking_line_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'agency_supplier' THEN
        v_counts := jsonb_build_object('agency_supplier',
            crm.erase_rows('agency_supplier', 'agency_supplier_id = $1', p_subject, NULL, p_dry_run));
    ELSE
        -- The whole agency. Memberships are deleted as a platform action (crm-008 guard_member_write lets only an
        -- unscoped or platform context delete a member); the caller's actor is restored afterwards.
        PERFORM set_config('app.actor', 'platform:crm_offboarding', true);
        -- crm-013: the agency's CIS membership feed records (ids and codes) go first.
        -- crm-014: line money, lines and suppliers before the trips; the FX overrides before the members (set_by).
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''],
            ['dispatch_queue', ''], ['trip_commitment', ''], ['booking_line_money', ''], ['booking_line', ''],
            ['agency_supplier', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['meeting_slot', ''], ['form_submission', ''],
            ['client_link', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['integration_credential', ''], ['fx_rate_override', ''], ['tenant_settings', ''],
            ['member_invitation', 'optional'], ['owner_recovery_request', 'optional'],
            ['tenant_entitlement', 'optional'], ['member', '']
        ] LOOP
            CONTINUE WHEN v_step[2] = 'optional' AND to_regclass('crm.' || v_step[1]) IS NULL;
            IF v_step[2] = 'unlink' THEN
                v_counts := v_counts || jsonb_build_object('traveler_referrer_unlinked',
                    crm.erase_rows('traveler', 'referrer_traveler_id IS NOT NULL', p_subject, NULL, p_dry_run,
                                   'referrer_traveler_id = NULL'));
            ELSE
                v_counts := v_counts || jsonb_build_object(v_step[1],
                    crm.erase_rows(v_step[1], 'true', p_subject, NULL, p_dry_run));
            END IF;
        END LOOP;
        PERFORM set_config('app.actor', v_actor, true);
        -- Nothing of the agency may be left in a tenant table outside the keep list: a table added later that this
        -- function does not know fails the erase (rolled back) instead of keeping personal data silently.
        IF NOT p_dry_run THEN
            FOR r IN SELECT c.relname::text AS name
                       FROM pg_catalog.pg_class c
                       JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
                      WHERE c.relnamespace = 'crm'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
                        AND c.relname <> ALL (c_keep) AND c.relname NOT LIKE 'audit_event%'
                      ORDER BY 1 LOOP
                IF NOT (SELECT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = ('crm.' || quote_ident(r.name))::regclass) THEN
                    v_left := v_left || r.name;  -- without FORCE RLS the owner would see every agency: refuse
                ELSE
                    EXECUTE format('SELECT EXISTS (SELECT 1 FROM crm.%I)', r.name) INTO v_has_token;
                    IF v_has_token THEN
                        v_left := v_left || r.name;
                    END IF;
                END IF;
            END LOOP;
            IF cardinality(v_left) > 0 THEN
                RAISE EXCEPTION 'crm: erase_incomplete (rows left in %)', array_to_string(v_left, ', ')
                    USING ERRCODE = 'CRM16';
            END IF;
        END IF;
    END IF;

    IF NOT p_dry_run THEN
        PERFORM set_config('app.erasing', '', true);
    END IF;
    RETURN jsonb_build_object('scope', p_scope, 'dry_run', p_dry_run, 'counts', v_counts);
END;
$$;
REVOKE ALL ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) TO crm_eraser;
COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope) and by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── 2. Backfill: the Adventure Asia row of every existing active or locked agency ────────────────
-- FORCE RLS hides crm.tenant from the owner, so the agency ids come from the crm-007 export registry (one row per
-- agency, RLS enabled but not forced: its owner reads every row) and each agency is entered through app.tenant_id.
DO $$
DECLARE
    v_id uuid;
BEGIN
    FOR v_id IN SELECT x.tenant_id FROM crm.audit_export_tenant x ORDER BY 1 LOOP
        PERFORM set_config('app.tenant_id', v_id::text, true);
        IF EXISTS (SELECT 1 FROM crm.tenant t WHERE t.status IN ('active', 'locked')) THEN
            PERFORM crm.ensure_aa_supplier();
        END IF;
    END LOOP;
    PERFORM set_config('app.tenant_id', '', true);
END $$;

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.agency_supplier', 'crm.booking_line', 'crm.booking_line_money',
                             'crm.fx_rate_override'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-014: % must have ENABLE + FORCE row level security', t;
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['crm.agency_supplier', 'crm.booking_line', 'crm.booking_line_money',
                             'crm.fx_rate_override', 'crm.fx_rate_platform', 'crm.v_booking_line_money_current'] LOOP
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-014: reader % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
        IF pg_catalog.has_table_privilege('crm_app', t, 'DELETE') OR pg_catalog.has_table_privilege('crm_app', t, 'TRUNCATE')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'SELECT') THEN
            RAISE EXCEPTION 'crm-014: crm_app must read and never delete %', t;
        END IF;
    END LOOP;
    -- Money is written only through the definer functions; the platform rates and overrides are append-only.
    IF pg_catalog.has_table_privilege('crm_app', 'crm.booking_line_money', 'INSERT')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.booking_line_money', 'UPDATE')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.v_booking_line_money_current', 'INSERT')
       OR pg_catalog.has_table_privilege('crm_app', 'crm.v_booking_line_money_current', 'UPDATE') THEN
        RAISE EXCEPTION 'crm-014: crm_app writes line money only through crm.booking_line_money_put / _confirm';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.fx_rate_platform', 'crm.fx_rate_override'] LOOP
        IF pg_catalog.has_table_privilege('crm_app', t, 'UPDATE') OR NOT pg_catalog.has_table_privilege('crm_app', t, 'INSERT') THEN
            RAISE EXCEPTION 'crm-014: % is insert-only for crm_app', t;
        END IF;
    END LOOP;
    IF (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'crm.fx_rate_platform'::regclass) THEN
        RAISE EXCEPTION 'crm-014: crm.fx_rate_platform is reference data without a tenant (no RLS)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy WHERE polrelid = 'crm.booking_line_money'::regclass
                    AND polname = 'booking_line_money_margin_roles' AND NOT polpermissive AND polcmd = 'r'
                    AND polroles = ARRAY['crm_app'::regrole::oid]) THEN
        RAISE EXCEPTION 'crm-014: booking_line_money_margin_roles must be RESTRICTIVE FOR SELECT TO crm_app';
    END IF;
    -- AA staff (platform: actors, the L1 console) never read or write agency line money.
    IF (SELECT pg_catalog.pg_get_expr(polqual, polrelid) FROM pg_catalog.pg_policy
         WHERE polrelid = 'crm.booking_line_money'::regclass AND polname = 'booking_line_money_margin_roles')
           LIKE '%platform%'
       OR position('platform' IN (SELECT prosrc FROM pg_catalog.pg_proc
                                   WHERE oid = 'crm.booking_line_money_put(uuid,text,numeric,text)'::regprocedure)) > 0 THEN
        RAISE EXCEPTION 'crm-014: a platform: actor must not pass the margin gate (policy or crm.booking_line_money_put)';
    END IF;
    IF NOT COALESCE((SELECT 'security_invoker=true' = ANY (reloptions) FROM pg_catalog.pg_class
                      WHERE oid = 'crm.v_booking_line_money_current'::regclass), false) THEN
        RAISE EXCEPTION 'crm-014: crm.v_booking_line_money_current must be security_invoker';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-014: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-014: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.booking_line_money_write(uuid,text,numeric,text,text,timestamptz)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-014: crm.booking_line_money_write is internal to the definer functions';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.ledger_append_only()', 'crm.guard_agency_supplier()', 'crm.ensure_aa_supplier()',
                             'crm.guard_booking_line()', 'crm.booking_line_money_chain()',
                             'crm.fx_resolve(text,text,date)', 'crm.booking_line_confirm_check(uuid)',
                             'crm.booking_line_money_write(uuid,text,numeric,text,text,timestamptz)',
                             'crm.booking_line_money_put(uuid,text,numeric,text)', 'crm.booking_line_confirm(uuid)',
                             'crm.erase_held(text,uuid,uuid)', 'crm.erase_subject(text,uuid,uuid,boolean)'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-014: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['booking_line_money', 'booking_line', 'agency_supplier', 'fx_rate_override',
                             'membership_inbox', 'client_link', 'meeting_slot'] LOOP
        IF position(quote_literal(t) IN (SELECT prosrc FROM pg_catalog.pg_proc
                     WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
            RAISE EXCEPTION 'crm-014: crm.erase_subject does not erase crm.%', t;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-014', now(), 'AA-944: CRM-16 agency-line ledger + suppliers (tenant_settings base_currency / booking_validation_level / fx_mode, agency_supplier with the built-in AA row, booking_line, booking_line_money with the frozen FX block, fx_rate_platform, fx_rate_override, confirm / money definer functions, fx_resolve, erase_subject + hold rule for the ledger)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
