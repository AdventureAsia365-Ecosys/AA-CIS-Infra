-- Migration crm-019: AA-949 (partner CRM, design v3 card CRM-21a) — the interactive proposal model and the day-list
-- builder, agency side: a builder version of crm.proposal with its days, option blocks, options (the agency's own items
-- and AA items priced by a live Booking quote), requires / excludes rules and the client's selections; the publish of
-- a version (vN); the version counters that surface a concurrent client selection to the agent.
--
-- Owner: AA-Partner (api/migrations/019_crm_proposal_builder.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-019. crm.erase_subject below is the crm-017 text plus this file's
-- tables; a later key that replaces it starts from THIS text. crm.erase_held is unchanged (crm-016): every new row
-- carries trip_id, which its trip scope already reaches through crm.hold_trip. crm.lifecycle_purge_expired is
-- unchanged (crm-018).
--
-- Why. Design v3 §6.3 card CRM-21a (deps CRM-19; implements M3 agent side, spec rule 5 "Stage 2 answers set the
-- default options", §11.2 concurrent edits, R33 per-day time zones, R38 slot), §2.7 F3 (build) / F5 (client choice),
-- §2.8 WF-4 (builder, Fix E1), §3.3 group E (proposal_day, option_block, option, option_rule, selection; DM-7 rows
-- exist since v1.3), Fix A5 / Decision D1 (price_visibility), Fix B9 (choose later: agency items only), Fix B10 (the
-- agent sets the rooms). Card R: an excludes violation -> 422 option_conflict (the API evaluates the rules). Card E: an
-- agent edit concurrent with a client selection -> version conflict surfaced (proposal.selection_seq /
-- based_on_selection_seq below); a Nepal day shows +05:45 (proposal_day.tz, an IANA name; the API renders the offset).
--
-- What:
--   1. crm.proposal: kind text (AA-946) | builder; price_visibility total_with_deltas (default, D1) | total_only;
--      room_config (the agent's rooms, counts only, Fix B10); deposit_pct (builder: the deposit share, the amounts are
--      computed at publish); starts_on (day 1's date); edit_seq (the working copy's write counter: every builder write
--      names the counter it read, a stale one is a version conflict); selection_seq (client picks on this version);
--      based_on_proposal_id + based_on_selection_seq (the version a working copy was copied from and its pick counter
--      at copy time: a client pick made since is surfaced at publish); published_at. Status published (builder only):
--      draft -> published -> sent | superseded | withdrawn (sending a published version and the client page are
--      CRM-21b). One published version per trip. A builder draft may hold zero amounts until publish. sent_at is now
--      guarded by crm.guard_set_once (once set it never changes) instead of the draft-only seal, so CRM-21b can send a
--      published version; the other sealed columns stay sealed after draft (CRM31), plus this card's.
--   2. crm.proposal_day (base template): day_no 0 (Before you go, R38 slot) .. 90, title, place, tz (IANA, R33),
--      notes_enc (vault DEK, pii:free_text), source_day_id (the copied day).
--   3. crm.option_block (base template): one choice on a day: title, type (lodging | activity | transport | meal |
--      guide | other), sort_order, client_may_swap (default true, Fix E1), default_option_id (one of its own options).
--   4. crm.option (base template): source aa | agency; title; tier (lodging: matches the Stage 2 accommodation tier);
--      sell_amount (the client's price for the party, the proposal currency); net_amount (cost; for an AA item the live
--      quote's b2b_price; conf:commercial, margin-bearing: never sent to the assistant or a client page); pay_on_arrival
--      (R25: listed, never charged); choose_later_allowed (agency items only, Fix B9); availability instant |
--      on_request | sold_out (AA, from the quote) | agency (the agent books); the AA reference (tour, Booking
--      component, departure, quote id and validity, the public "from" price and below_from_price: warn only).
--   5. crm.option_rule (base template): requires | excludes between two options of the proposal (the Advanced section).
--   6. crm.selection (base template): the client's current pick per block of a published or sent version (chosen_by
--      client | agent | carried), choose_later (CRM-21b). Written only while the version is published or sent (CRM36).
--   7. crm.guard_proposal_draft(): days, blocks, options and rules change only while their proposal is a draft (CRM35
--      proposal_not_draft); an option of a published or sent version may change its availability only (an option
--      that sells out mid-session, CRM-21b).
--   8. crm.erase_subject (the crm-017 text) + the five tables (trip and agency scopes); the hold guard on all five.
--   No foreign key here has an ON DELETE action: a referential action runs its query, and the triggers it fires, with
--   row security off for the table owner, so crm.guard_held_change would read every agency's legal holds there. The
--   API deletes a draft's rows child first; the two self / circular keys (option_block.default_option_id,
--   proposal.based_on_proposal_id) are DEFERRABLE INITIALLY DEFERRED so one transaction can delete both ends.
--   SQLSTATEs CRM35 and CRM36 are this file's; the next key starts at CRM37.
--
-- Order: after crm-018 (AA-978 follow-up) and crm-017 (AA-947); Guard 0 refuses to run before both are registered
-- (erase_subject builds on the crm-017 text).
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before the AA-949
-- code deploys nothing reads these objects, and the code merges only after this file is applied (S249 lesson).

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-017 and crm-018 ───────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-019: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-017')
       OR NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-018') THEN
        RAISE EXCEPTION 'crm-019: crm-017 (AA-947) and crm-018 (AA-978 follow-up) land first';
    END IF;
    IF to_regclass('crm.proposal') IS NULL OR to_regclass('crm.agency_supplier') IS NULL
       OR to_regprocedure('crm.guard_sealed_row()') IS NULL
       OR to_regprocedure('crm.guard_held_change()') IS NULL
       OR to_regprocedure('crm.erase_rows(text,text,uuid,uuid,boolean,text)') IS NULL THEN
        RAISE EXCEPTION 'crm-019: crm.proposal / crm.guard_sealed_row (crm-016), crm.agency_supplier (crm-014) or crm.guard_held_change / crm.erase_rows (crm-010) missing';
    END IF;
END $$;

-- ── 1. crm.proposal: the builder columns ─────────────────────────────────────────────────────────
ALTER TABLE crm.proposal
    ADD COLUMN IF NOT EXISTS kind                   TEXT NOT NULL DEFAULT 'text',
    ADD COLUMN IF NOT EXISTS price_visibility       TEXT NOT NULL DEFAULT 'total_with_deltas',
    ADD COLUMN IF NOT EXISTS room_config            JSONB,
    ADD COLUMN IF NOT EXISTS deposit_pct            NUMERIC(5, 2),
    ADD COLUMN IF NOT EXISTS starts_on              DATE,
    ADD COLUMN IF NOT EXISTS edit_seq               INTEGER NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS selection_seq          INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS based_on_proposal_id   UUID,
    ADD COLUMN IF NOT EXISTS based_on_selection_seq INTEGER,
    ADD COLUMN IF NOT EXISTS published_at           TIMESTAMPTZ;
ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_based_on_fk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_based_on_fk FOREIGN KEY (tenant_id, based_on_proposal_id)
    REFERENCES crm.proposal (tenant_id, proposal_id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_status_chk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_status_chk
    CHECK (status IN ('draft', 'published', 'sent', 'accepted', 'superseded', 'withdrawn'));
ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_kind_chk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_kind_chk CHECK (
    kind IN ('text', 'builder')
    AND price_visibility IN ('total_with_deltas', 'total_only')
    AND edit_seq >= 1 AND selection_seq >= 0 AND coalesce(based_on_selection_seq, 0) >= 0
    AND (room_config IS NULL OR (jsonb_typeof(room_config) = 'array' AND jsonb_array_length(room_config) BETWEEN 1 AND 20))
    AND (deposit_pct IS NULL OR (deposit_pct >= 1 AND deposit_pct <= 100))
    AND (kind = 'builder' OR (room_config IS NULL AND deposit_pct IS NULL AND starts_on IS NULL
                              AND based_on_proposal_id IS NULL AND based_on_selection_seq IS NULL
                              AND published_at IS NULL AND selection_seq = 0))
    AND (kind = 'text' OR deposit_pct IS NOT NULL)
);
-- A builder version holds the computed amounts; until it is first published they may be zero.
ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_amounts_chk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_amounts_chk CHECK (
    (kind = 'builder' AND published_at IS NULL
     AND total_amount >= 0 AND deposit_amount >= 0 AND deposit_amount <= total_amount)
    OR (total_amount > 0 AND deposit_amount > 0 AND deposit_amount <= total_amount
        AND (balance_due_on IS NULL) = (deposit_amount = total_amount))
);
ALTER TABLE crm.proposal DROP CONSTRAINT IF EXISTS proposal_sent_chk;
ALTER TABLE crm.proposal ADD CONSTRAINT proposal_sent_chk CHECK (
    CASE
        WHEN status = 'draft' THEN price_hash IS NULL AND sent_at IS NULL AND published_at IS NULL
        WHEN status = 'published' THEN kind = 'builder' AND price_hash IS NOT NULL AND published_at IS NOT NULL
                                       AND sent_at IS NULL
        WHEN status = 'withdrawn' THEN (price_hash IS NULL) = (sent_at IS NULL AND published_at IS NULL)
        ELSE price_hash IS NOT NULL AND (sent_at IS NOT NULL OR (status = 'superseded' AND published_at IS NOT NULL))
    END
    AND (kind = 'text' OR status IN ('draft', 'withdrawn') OR published_at IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS proposal_one_published_uq ON crm.proposal (tenant_id, trip_id)
    WHERE status = 'published' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS proposal_based_on_idx ON crm.proposal (tenant_id, based_on_proposal_id)
    WHERE based_on_proposal_id IS NOT NULL;
INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('proposal', 'draft', 'published'),
    ('proposal', 'published', 'sent'),
    ('proposal', 'published', 'superseded'),
    ('proposal', 'published', 'withdrawn')
ON CONFLICT DO NOTHING;

-- crm.guard_set_once: a column that holds a value keeps it (sent_at: set by the send of a draft text version, or by
-- CRM-21b's send of a published builder version; never changed afterwards).
CREATE OR REPLACE FUNCTION crm.guard_set_once() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    o jsonb := to_jsonb(OLD);
    n jsonb := to_jsonb(NEW);
    c text;
BEGIN
    IF current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN NEW;
    END IF;
    FOREACH c IN ARRAY TG_ARGV LOOP
        IF o->c <> 'null'::jsonb AND (n->c) IS DISTINCT FROM (o->c) THEN
            RAISE EXCEPTION 'crm: row_sealed (% of a % row is set once)', c, TG_TABLE_NAME USING ERRCODE = 'CRM31';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_set_once() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_set_once() IS 'AA-949 (crm-019): BEFORE UPDATE trigger; the arguments are columns that, once they hold a value, never change (CRM31 row_sealed); only crm.erase_subject (crm_owner with app.erasing on) may. crm.proposal.sent_at: a text version sets it at its send, a builder version at the send of its published version (CRM-21b).';

DO $$
BEGIN
    -- The crm-016 seal minus sent_at (now set-once, so a published builder version can be sent), plus this card's
    -- builder columns: after draft, the content and the published amounts never change.
    EXECUTE 'CREATE OR REPLACE TRIGGER proposal_sealed BEFORE UPDATE ON crm.proposal FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_sealed_row(''draft'', ''trip_id'', ''version'', ''body_enc'', ''currency'', '
            '''total_amount'', ''deposit_amount'', ''balance_due_on'', ''terms_doc_id'', ''price_hash'', '
            '''tenant_id'', ''kind'', ''price_visibility'', ''room_config'', ''deposit_pct'', ''starts_on'', '
            '''published_at'')';
    EXECUTE 'CREATE OR REPLACE TRIGGER proposal_sent_once BEFORE UPDATE ON crm.proposal FOR EACH ROW '
            'EXECUTE FUNCTION crm.guard_set_once(''sent_at'')';
END $$;
COMMENT ON COLUMN crm.proposal.kind IS 'AA-949 (crm-019): text (AA-946: one text and sell amounts) | builder (the day-list builder: days, option blocks, options, rules; amounts computed from the default options at publish)';
COMMENT ON COLUMN crm.proposal.price_visibility IS 'AA-949 (crm-019; Fix A5, Decision D1): what the client page shows: total_with_deltas (default: the total and each option''s sell difference) | total_only. Never per-line prices';
COMMENT ON COLUMN crm.proposal.room_config IS 'AA-949 (crm-019; Fix B10): the rooms the agent set in the builder, [{type single|double|twin|triple|family, adults, children}]; counts only, never a person. The client confirms them at accept (CRM-21b)';
COMMENT ON COLUMN crm.proposal.deposit_pct IS 'AA-949 (crm-019): builder versions: the deposit share of the total (1-100); deposit_amount is computed at publish';
COMMENT ON COLUMN crm.proposal.starts_on IS 'AA-949 (crm-019): builder versions: the date of day 1 (day N = starts_on + N - 1); default the trip''s start date';
COMMENT ON COLUMN crm.proposal.edit_seq IS 'AA-949 (crm-019; §11.2): the working copy''s write counter. Every builder write sends the counter it read; a different one is 409 version_conflict (two editors, or two tabs)';
COMMENT ON COLUMN crm.proposal.selection_seq IS 'AA-949 (crm-019; §11.2): the number of client picks made on this published / sent version; a working copy copied from it records the value it saw (based_on_selection_seq), and publishing it while the client picked since is 409 version_conflict until the agent acknowledges';
COMMENT ON COLUMN crm.proposal.based_on_proposal_id IS 'AA-949 (crm-019): the version this working copy was copied from (same trip; the key is deferred, so the trip erase deletes every version in one statement)';
COMMENT ON COLUMN crm.proposal.published_at IS 'AA-949 (crm-019): builder versions: when the version was published (Publish vN); the price hash is fixed then';

-- ── 2. crm.proposal_day ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.proposal_day (
    proposal_day_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    proposal_id     UUID NOT NULL,
    trip_id         UUID NOT NULL,
    day_no          SMALLINT NOT NULL,
    title           TEXT,
    place           TEXT,
    tz              TEXT NOT NULL,
    notes_enc       BYTEA,
    source_day_id   UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT proposal_day_tenant_id_uq UNIQUE (tenant_id, proposal_day_id),
    CONSTRAINT proposal_day_proposal_uq UNIQUE (tenant_id, proposal_id, proposal_day_id),
    CONSTRAINT proposal_day_no_uq UNIQUE (tenant_id, proposal_id, day_no) DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT proposal_day_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id),
    CONSTRAINT proposal_day_no_chk CHECK (day_no BETWEEN 0 AND 90),
    CONSTRAINT proposal_day_text_chk CHECK (
        (title IS NULL OR (char_length(title) BETWEEN 1 AND 120 AND title !~ '[[:cntrl:]]'))
        AND (place IS NULL OR (char_length(place) BETWEEN 1 AND 120 AND place !~ '[[:cntrl:]]'))
        AND coalesce(octet_length(notes_enc), 30) >= 30
    ),
    CONSTRAINT proposal_day_tz_chk CHECK (tz = 'UTC' OR tz ~ '^[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+){1,2}$'),
    CONSTRAINT proposal_day_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS proposal_day_trip_idx ON crm.proposal_day (tenant_id, trip_id);
COMMENT ON TABLE crm.proposal_day IS 'AA-949 (crm-019; design v3 group E, M3, R33, R38): one day of a builder proposal version: day_no 0 = "Before you go" (the R38 slot, CRM-22 fills it), 1..90 the trip days in order (day N is proposal.starts_on + N - 1); tz = the IANA zone of the day (R33; the API shows its UTC offset on that date, e.g. Asia/Kathmandu +05:45). Changes only while the proposal is a draft (CRM35). Erased with its trip / agency (crm.erase_subject)';
COMMENT ON COLUMN crm.proposal_day.notes_enc IS 'pii:free_text — AA-949 (crm-019): the day''s text for the client, under the agency vault DEK';
COMMENT ON COLUMN crm.proposal_day.source_day_id IS 'AA-949 (crm-019): the day of the version this one was copied from (lineage for carried picks; no foreign key, the source may be erased)';

-- ── 3. crm.option_block ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.option_block (
    option_block_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                      REFERENCES crm.tenant (tenant_id),
    proposal_id       UUID NOT NULL,
    trip_id           UUID NOT NULL,
    proposal_day_id   UUID NOT NULL,
    sort_order        SMALLINT NOT NULL DEFAULT 0,
    title             TEXT NOT NULL,
    type              TEXT NOT NULL DEFAULT 'other',
    client_may_swap   BOOLEAN NOT NULL DEFAULT true,
    default_option_id UUID,
    source_block_id   UUID,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    deleted_by        TEXT,
    purge_after       TIMESTAMPTZ,
    CONSTRAINT option_block_tenant_id_uq UNIQUE (tenant_id, option_block_id),
    CONSTRAINT option_block_proposal_uq UNIQUE (tenant_id, proposal_id, option_block_id),
    CONSTRAINT option_block_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id),
    CONSTRAINT option_block_day_fk FOREIGN KEY (tenant_id, proposal_id, proposal_day_id)
        REFERENCES crm.proposal_day (tenant_id, proposal_id, proposal_day_id),
    CONSTRAINT option_block_values_chk CHECK (
        sort_order BETWEEN 0 AND 99
        AND char_length(title) BETWEEN 1 AND 120 AND title !~ '[[:cntrl:]]'
        AND type IN ('lodging', 'activity', 'transport', 'meal', 'guide', 'other')
    ),
    CONSTRAINT option_block_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS option_block_day_idx ON crm.option_block (tenant_id, proposal_day_id, sort_order);
CREATE INDEX IF NOT EXISTS option_block_trip_idx ON crm.option_block (tenant_id, trip_id);
COMMENT ON TABLE crm.option_block IS 'AA-949 (crm-019; design v3 group E, WF-4 Fix E1): one choice on a day of a builder proposal: its options, the default (default_option_id, one of its own options; Stage 2 rule 5 sets it from the accommodation tier for lodging), client_may_swap (default true: the client may swap to another option on C-03). A block with one option is a fixed item. Changes only while the proposal is a draft (CRM35)';

-- ── 4. crm.option ────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.option (
    option_id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                             REFERENCES crm.tenant (tenant_id),
    proposal_id              UUID NOT NULL,
    trip_id                  UUID NOT NULL,
    option_block_id          UUID NOT NULL,
    sort_order               SMALLINT NOT NULL DEFAULT 0,
    source                   TEXT NOT NULL,
    title                    TEXT NOT NULL,
    tier                     TEXT,
    agency_supplier_id       UUID,
    sell_amount              NUMERIC(14, 2) NOT NULL DEFAULT 0,
    net_amount               NUMERIC(14, 2),
    pay_on_arrival           BOOLEAN NOT NULL DEFAULT false,
    choose_later_allowed     BOOLEAN NOT NULL DEFAULT false,
    availability             TEXT NOT NULL,
    availability_checked_at  TIMESTAMPTZ,
    aa_tour_source_id        TEXT,
    aa_component_id          TEXT,
    aa_component_kind        TEXT,
    aa_departure_id          TEXT,
    aa_quote_id              TEXT,
    aa_quote_valid_until     TIMESTAMPTZ,
    aa_from_price            NUMERIC(14, 2),
    below_from_price         BOOLEAN,
    source_option_id         UUID,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at               TIMESTAMPTZ,
    deleted_by               TEXT,
    purge_after              TIMESTAMPTZ,
    CONSTRAINT option_tenant_id_uq UNIQUE (tenant_id, option_id),
    CONSTRAINT option_block_uq UNIQUE (tenant_id, option_block_id, option_id),
    CONSTRAINT option_proposal_uq UNIQUE (tenant_id, proposal_id, option_id),
    CONSTRAINT option_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id),
    CONSTRAINT option_block_fk FOREIGN KEY (tenant_id, proposal_id, option_block_id)
        REFERENCES crm.option_block (tenant_id, proposal_id, option_block_id),
    CONSTRAINT option_supplier_fk FOREIGN KEY (tenant_id, agency_supplier_id)
        REFERENCES crm.agency_supplier (tenant_id, agency_supplier_id),
    CONSTRAINT option_values_chk CHECK (
        sort_order BETWEEN 0 AND 99
        AND source IN ('aa', 'agency')
        AND char_length(title) BETWEEN 1 AND 200 AND title !~ '[[:cntrl:]]'
        AND (tier IS NULL OR tier IN ('budget', 'comfort', 'premium', 'luxury'))
        AND sell_amount >= 0 AND (net_amount IS NULL OR net_amount >= 0)
        AND availability IN ('instant', 'on_request', 'sold_out', 'agency')
        AND (aa_from_price IS NULL OR aa_from_price >= 0)
    ),
    CONSTRAINT option_source_chk CHECK (
        (source = 'aa' AND agency_supplier_id IS NULL AND NOT choose_later_allowed
         AND availability IN ('instant', 'on_request', 'sold_out')
         AND aa_tour_source_id IS NOT NULL AND char_length(aa_tour_source_id) BETWEEN 1 AND 128
         AND aa_tour_source_id !~ '[[:cntrl:]]'
         AND aa_component_id ~ '^[A-Za-z0-9:_.-]{1,64}$'
         AND aa_component_kind IN ('trip_plan', 'hotel_room', 'transfer', 'guide', 'activity', 'entrance', 'meal')
         AND coalesce(aa_departure_id, 'x') ~ '^[A-Za-z0-9:_.-]{1,64}$'
         AND coalesce(aa_quote_id, 'x') ~ '^[A-Za-z0-9:_.-]{1,64}$')
        OR (source = 'agency' AND availability = 'agency'
            AND num_nonnulls(aa_tour_source_id, aa_component_id, aa_component_kind, aa_departure_id, aa_quote_id,
                             aa_quote_valid_until, aa_from_price, below_from_price) = 0)
    ),
    CONSTRAINT option_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS option_block_idx ON crm.option (tenant_id, option_block_id, sort_order);
CREATE INDEX IF NOT EXISTS option_trip_idx ON crm.option (tenant_id, trip_id);
CREATE INDEX IF NOT EXISTS option_supplier_idx ON crm.option (tenant_id, agency_supplier_id)
    WHERE agency_supplier_id IS NOT NULL;
COMMENT ON TABLE crm.option IS 'AA-949 (crm-019; design v3 group E, F3, WF-4): one option of a block: an agency item (source agency, optional supplier, availability agency = the agent books; choose later allowed, Fix B9) or an AA item (source aa: an AA tour and Booking component priced by a live Booking quote in the proposal currency: net_amount = the quote''s b2b_price, availability from the quote, the public "from" price and below_from_price: a warning, never a block). sell_amount = the client''s price for the party. pay_on_arrival (R25) is listed and never charged. Changes only while the proposal is a draft, except availability on a published / sent version (CRM35)';
COMMENT ON COLUMN crm.option.net_amount IS 'conf:commercial — AA-949 (crm-019): the cost of the option for the party in the proposal currency (AA: the live quote''s b2b_price). Margin-bearing (design §4.6): never sent to the assistant role or to a client page';
COMMENT ON COLUMN crm.option.tier IS 'AA-949 (crm-019; spec rule 5): the accommodation tier of a lodging option; an option whose tier is the lead''s Stage 2 accommodation_tier becomes its block''s default';
COMMENT ON COLUMN crm.option.source_option_id IS 'AA-949 (crm-019): the option of the version this one was copied from (lineage: a client pick on that option carries over at publish; no foreign key, the source may be erased)';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname = 'option_block_default_fk'
                   AND conrelid = 'crm.option_block'::regclass) THEN
        ALTER TABLE crm.option_block ADD CONSTRAINT option_block_default_fk
            FOREIGN KEY (tenant_id, option_block_id, default_option_id)
            REFERENCES crm.option (tenant_id, option_block_id, option_id) DEFERRABLE INITIALLY DEFERRED;
    END IF;
END $$;

-- ── 5. crm.option_rule ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.option_rule (
    option_rule_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    proposal_id      UUID NOT NULL,
    trip_id          UUID NOT NULL,
    kind             TEXT NOT NULL,
    option_id        UUID NOT NULL,
    target_option_id UUID NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT option_rule_tenant_id_uq UNIQUE (tenant_id, option_rule_id),
    CONSTRAINT option_rule_uq UNIQUE (tenant_id, proposal_id, kind, option_id, target_option_id),
    CONSTRAINT option_rule_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id),
    CONSTRAINT option_rule_option_fk FOREIGN KEY (tenant_id, proposal_id, option_id)
        REFERENCES crm.option (tenant_id, proposal_id, option_id),
    CONSTRAINT option_rule_target_fk FOREIGN KEY (tenant_id, proposal_id, target_option_id)
        REFERENCES crm.option (tenant_id, proposal_id, option_id),
    CONSTRAINT option_rule_values_chk CHECK (kind IN ('requires', 'excludes') AND option_id <> target_option_id),
    CONSTRAINT option_rule_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS option_rule_target_idx ON crm.option_rule (tenant_id, target_option_id);
CREATE INDEX IF NOT EXISTS option_rule_trip_idx ON crm.option_rule (tenant_id, trip_id);
COMMENT ON TABLE crm.option_rule IS 'AA-949 (crm-019; design v3 group E, WF-4 Advanced): a dependency between two options of one proposal version: requires (choosing option_id needs target_option_id chosen) | excludes (the two are never chosen together). The API evaluates them on the defaults (builder, publish) and on every pick: a violation is 422 option_conflict (card R). Changes only while the proposal is a draft (CRM35)';

-- ── 6. crm.selection ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.selection (
    selection_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                    REFERENCES crm.tenant (tenant_id),
    proposal_id     UUID NOT NULL,
    trip_id         UUID NOT NULL,
    option_block_id UUID NOT NULL,
    option_id       UUID NOT NULL,
    chosen_by       TEXT NOT NULL,
    choose_later    BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    deleted_by      TEXT,
    purge_after     TIMESTAMPTZ,
    CONSTRAINT selection_tenant_id_uq UNIQUE (tenant_id, selection_id),
    CONSTRAINT selection_block_uq UNIQUE (tenant_id, proposal_id, option_block_id),
    CONSTRAINT selection_proposal_fk FOREIGN KEY (tenant_id, proposal_id, trip_id)
        REFERENCES crm.proposal (tenant_id, proposal_id, trip_id),
    CONSTRAINT selection_block_fk FOREIGN KEY (tenant_id, proposal_id, option_block_id)
        REFERENCES crm.option_block (tenant_id, proposal_id, option_block_id),
    CONSTRAINT selection_option_fk FOREIGN KEY (tenant_id, option_block_id, option_id)
        REFERENCES crm.option (tenant_id, option_block_id, option_id),
    CONSTRAINT selection_values_chk CHECK (chosen_by IN ('client', 'agent', 'carried')),
    CONSTRAINT selection_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS selection_option_idx ON crm.selection (tenant_id, option_block_id, option_id);
CREATE INDEX IF NOT EXISTS selection_trip_idx ON crm.selection (tenant_id, trip_id);
COMMENT ON TABLE crm.selection IS 'AA-949 (crm-019; design v3 group E, F5): the current pick of one block of a published or sent proposal version (one row per block; a block without a row keeps its default): chosen_by client (C-03, CRM-21b) | agent (on the client''s behalf) | carried (a pick on the previous version whose option was copied into this one, carried at publish); choose_later (agency items only, CRM-21b). Every pick moves proposal.selection_seq. Written only while the version is published or sent (CRM36)';

-- ── 7. The draft guard and the selection guard ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.guard_proposal_draft() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    o jsonb := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END;
    n jsonb := CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END;
    v_status text;
    v_ids uuid[] := ARRAY[]::uuid[];
    v_id uuid;
BEGIN
    IF current_user = 'crm_owner' AND current_setting('app.erasing', true) = 'on' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF o IS NOT NULL THEN
        v_ids := v_ids || (o->>'proposal_id')::uuid;
    END IF;
    IF n IS NOT NULL AND (o IS NULL OR n->>'proposal_id' IS DISTINCT FROM o->>'proposal_id') THEN
        v_ids := v_ids || (n->>'proposal_id')::uuid;
    END IF;
    FOREACH v_id IN ARRAY v_ids LOOP
        SELECT p.status INTO v_status FROM crm.proposal p WHERE p.proposal_id = v_id;
        IF v_status IS NULL OR v_status = 'draft' THEN
            CONTINUE;  -- an unknown proposal fails on the foreign key
        END IF;
        -- An option of a published / sent version may change its availability only (sold out mid-session, CRM-21b).
        IF TG_TABLE_NAME = 'option' AND TG_OP = 'UPDATE' AND v_status IN ('published', 'sent')
           AND (n - 'availability' - 'availability_checked_at' - 'updated_at')
               = (o - 'availability' - 'availability_checked_at' - 'updated_at') THEN
            CONTINUE;
        END IF;
        RAISE EXCEPTION 'crm: proposal_not_draft (% of a % proposal refused on %)', lower(TG_OP), v_status,
            TG_TABLE_NAME USING ERRCODE = 'CRM35';
    END LOOP;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_proposal_draft() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_proposal_draft() IS 'AA-949 (crm-019): BEFORE INSERT OR UPDATE OR DELETE trigger on crm.proposal_day, option_block, option and option_rule: the row changes only while its proposal is a draft (CRM35 proposal_not_draft), except the availability of an option of a published or sent version (an option that sells out mid-session, CRM-21b); crm.erase_subject (crm_owner with app.erasing on) passes.';

CREATE OR REPLACE FUNCTION crm.guard_selection() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_status text;
BEGIN
    SELECT p.status INTO v_status FROM crm.proposal p WHERE p.proposal_id = NEW.proposal_id;
    IF v_status IS NOT NULL AND v_status NOT IN ('published', 'sent') THEN
        RAISE EXCEPTION 'crm: selection_closed (a pick on a % proposal refused)', v_status USING ERRCODE = 'CRM36';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.guard_selection() FROM PUBLIC;
COMMENT ON FUNCTION crm.guard_selection() IS 'AA-949 (crm-019): BEFORE INSERT OR UPDATE trigger on crm.selection: a pick is written only while its proposal version is published or sent (CRM36 selection_closed); a draft, an accepted, superseded or withdrawn version takes none.';

-- ── RLS, triggers and the hold guard on the new tenant tables ────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['proposal_day', 'option_block', 'option', 'option_rule', 'selection'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format('CREATE POLICY tenant_isolation ON crm.%I '
                       'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
                       'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
                       'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
        EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I '
                       'FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()', t || '_set_updated_at', t);
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON crm.%I', t || '_hold_guard', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE DELETE OR UPDATE ON crm.%I FOR EACH ROW '
                       'EXECUTE FUNCTION crm.guard_held_change(''trip_id'')', t || '_hold_guard', t);
        EXECUTE format('REVOKE TRUNCATE ON crm.%I FROM crm_app', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['proposal_day', 'option_block', 'option', 'option_rule'] LOOP
        EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE INSERT OR UPDATE OR DELETE ON crm.%I '
                       'FOR EACH ROW EXECUTE FUNCTION crm.guard_proposal_draft()', t || '_draft_only', t);
    END LOOP;
    EXECUTE 'CREATE OR REPLACE TRIGGER selection_open_version BEFORE INSERT OR UPDATE ON crm.selection '
            'FOR EACH ROW EXECUTE FUNCTION crm.guard_selection()';
END $$;

-- ── 8. crm.erase_subject: the crm-017 text plus the builder tables ──────────────────────────────
-- A later key that replaces it starts from THIS text.
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
                       'conversation', 'tenant') THEN
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
    ELSIF p_scope = 'conversation' THEN
        PERFORM 1 FROM crm.conversation WHERE conversation_id = p_subject FOR UPDATE;
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
        -- crm-014: the trip's line money, then its lines. crm-015: the messages of its conversations, then those.
        -- crm-016: signatures, codes, portal access, payments, schedule rows and proposals before the links.
        -- crm-017: the trip's AA requests (the outage queue) before its lines.
        -- crm-019: the builder rows (picks, rules, options, blocks, days) before the proposals.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['signature_request', 'trip_id = $1', ''],
            ['otp_challenge', 'trip_id = $1', ''],
            ['traveler_access', 'trip_id = $1', ''],
            ['payment', 'trip_id = $1', ''],
            ['payment_schedule', 'trip_id = $1', ''],
            ['selection', 'trip_id = $1', ''],
            ['option_rule', 'trip_id = $1', ''],
            ['option', 'trip_id = $1', ''],
            ['option_block', 'trip_id = $1', ''],
            ['proposal_day', 'trip_id = $1', ''],
            ['proposal', 'trip_id = $1', ''],
            ['form_submission', 'trip_id = $1', 'trip_id = NULL, client_link_id = NULL'],
            ['client_link', 'trip_id = $1', ''],
            ['meeting_slot', 'trip_id = $1', ''],
            ['dispatch_queue', 'trip_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c WHERE c.trip_id = $1)', ''],
            ['conversation', 'trip_id = $1', ''],
            ['trip_commitment', 'trip_id = $1', ''],
            ['aa_request', 'trip_id = $1', ''],
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
        -- crm-015: the messages of their conversations, then those. crm-016: the name they typed to accept a proposal
        -- (the proposal's link names them; before their links go), their signatures, codes and portal access.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['proposal', 'accepted_name_enc IS NOT NULL AND link_id IN (SELECT l.link_id FROM crm.client_link l '
                         'WHERE l.traveler_id = $1)', 'accepted_name_enc = NULL, accepted_name_erased_at = now()'],
            ['signature_request', 'traveler_id = $1', ''],
            ['otp_challenge', 'traveler_id = $1', ''],
            ['traveler_access', 'traveler_id = $1', ''],
            ['meeting_slot', 'traveler_id = $1 OR form_submission_id IN (SELECT s.submission_id '
                             'FROM crm.form_submission s WHERE s.traveler_id = $1)', ''],
            ['dispatch_queue', 'traveler_id = $1', ''],
            ['message', 'conversation_id IN (SELECT c.conversation_id FROM crm.conversation c '
                        'WHERE c.traveler_id = $1)', ''],
            ['conversation', 'traveler_id = $1', ''],
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
                v_step[1] || CASE WHEN v_step[3] = '' THEN '' WHEN v_step[1] = 'proposal' THEN '_acceptance_name_erased'
                                  ELSE '_referrer_unlinked' END,
                crm.erase_rows(v_step[1], v_step[2], p_subject, p_profile_token, p_dry_run, NULLIF(v_step[3], '')));
        END LOOP;
    ELSIF p_scope IN ('task', 'note', 'document') THEN
        v_counts := jsonb_build_object(p_scope,
            crm.erase_rows(p_scope, p_scope || '_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'relation' THEN
        v_counts := jsonb_build_object('traveler_relation',
            crm.erase_rows('traveler_relation', 'relation_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'booking_line' THEN
        -- crm-014: the trash purge of a planning line: its money, then the line. crm-017: its AA requests first (an
        -- agency line has none; an AA line never reaches the trash, the guard refuses it).
        v_counts := jsonb_build_object(
            'aa_request', crm.erase_rows('aa_request', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
            'booking_line_money', crm.erase_rows('booking_line_money', 'booking_line_id = $1', p_subject, NULL, p_dry_run),
            'booking_line', crm.erase_rows('booking_line', 'booking_line_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'agency_supplier' THEN
        v_counts := jsonb_build_object('agency_supplier',
            crm.erase_rows('agency_supplier', 'agency_supplier_id = $1', p_subject, NULL, p_dry_run));
    ELSIF p_scope = 'conversation' THEN
        -- crm-015: the trash purge of a conversation (an Unmatched one the agent deleted): its messages, then it. Kept
        -- attachments are documents of the trip / traveller and stay with them.
        v_counts := jsonb_build_object(
            'message', crm.erase_rows('message', 'conversation_id = $1', p_subject, NULL, p_dry_run),
            'conversation', crm.erase_rows('conversation', 'conversation_id = $1', p_subject, NULL, p_dry_run));
    ELSE
        -- The whole agency. Memberships are deleted as a platform action (crm-008 guard_member_write lets only an
        -- unscoped or platform context delete a member); the caller's actor is restored afterwards.
        PERFORM set_config('app.actor', 'platform:crm_offboarding', true);
        -- crm-013: the agency's CIS membership feed records (ids and codes) go first.
        -- crm-014: line money, lines and suppliers before the trips; the FX overrides before the members (set_by).
        -- crm-015: messages and conversations before the trips and travellers; saved replies, imports, the forward-in
        -- address and the mailboxes before the credentials and the members.
        -- crm-016: signatures, codes, portal access, payments, schedule rows, proposals and agreement versions first.
        -- crm-017: the Booking feed records and cursor, then the AA requests before the lines.
        -- crm-019: the builder rows before the proposals.
        FOREACH v_step SLICE 1 IN ARRAY ARRAY[
            ['membership_inbox', ''], ['inbox_events', ''], ['booking_feed_state', ''],
            ['signature_request', ''], ['otp_challenge', ''], ['traveler_access', ''], ['payment', ''],
            ['payment_schedule', ''], ['selection', ''], ['option_rule', ''], ['option', ''], ['option_block', ''],
            ['proposal_day', ''], ['proposal', ''], ['agreement_doc', ''],
            ['dispatch_queue', ''], ['message', ''], ['conversation', ''],
            ['trip_commitment', ''], ['aa_request', ''], ['booking_line_money', ''], ['booking_line', ''],
            ['agency_supplier', ''], ['document', ''], ['traveler_health', ''],
            ['note', ''], ['task', ''], ['trip_stage_history', ''], ['trip_party', ''], ['trip_traveler', ''],
            ['traveler_relation', ''], ['consent', ''], ['meeting_slot', ''], ['form_submission', ''],
            ['client_link', ''], ['profile_history', ''],
            ['traveler_profile', ''], ['placeholder_map', 'optional'], ['llm_call', ''], ['trip', ''],
            ['traveler', 'unlink'], ['traveler', ''], ['intake_form', ''], ['form_definition', ''],
            ['saved_reply', ''], ['mail_import', ''], ['ingest_address', ''], ['channel_account', ''],
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

COMMENT ON FUNCTION crm.erase_subject(text, uuid, uuid, boolean) IS 'AA-942 (crm-010, design §4.10, Fix B16), extended by AA-943 (crm-012) to client_link and meeting_slot, by AA-978 (crm-013) to membership_inbox (agency scope), by AA-944 (crm-014) to the ledger (trip and agency scopes: booking_line_money, booking_line; agency scope: agency_supplier, fx_rate_override; new scopes booking_line and agency_supplier for the trash purge), by AA-945 (crm-015) to mail (trip, traveller and agency scopes: message, conversation; agency scope: saved_reply, mail_import, ingest_address, channel_account; new scope conversation for the trash purge), by AA-946 (crm-016) to the lifecycle tables (trip and agency scopes: signature_request, otp_challenge, traveler_access, payment, payment_schedule, proposal; traveller scope: signature_request, otp_challenge, traveler_access, and the typed acceptance name of the proposals their links carried (accepted_name_enc := NULL); agency scope: agreement_doc) by AA-947 (crm-017) to the AA lines (trip, booking_line and agency scopes: aa_request; agency scope: inbox_events, booking_feed_state) and by AA-949 (crm-019) to the proposal builder (trip and agency scopes: selection, option_rule, option, option_block, proposal_day): the only hard-delete path of agency data. Scopes trip, traveler (needs the decrypted F2 profile token), task, note, document, relation, booking_line, agency_supplier, conversation, tenant (status offboarding, except a dry run; every tenant table except the keep list). Used by the trash purge and by erasure / offboarding (which skip the trash). Refuses: CRM10 legal_hold (the hold rule: any held row among those the erase would delete or update, crm.erase_held), CRM11 delete_blocked, CRM12 traveler_on_trip, CRM13 subject_not_found, CRM14 tenant_not_offboarding, CRM15 profile token, CRM16 erase_incomplete, CRM22 the Adventure Asia supplier row, CRM27 a supplier lines name. Never touches audit_event. Takes LOCK TABLE crm.legal_hold IN SHARE MODE first (serialised with hold placement). EXECUTE: crm_eraser only (SET LOCAL ROLE inside the lifecycle context).';

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.proposal_day', 'crm.option_block', 'crm.option', 'crm.option_rule',
                             'crm.selection'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-019: % must have ENABLE + FORCE row level security', t;
        END IF;
        IF pg_catalog.has_table_privilege('crm_app', t, 'TRUNCATE')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'SELECT')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'INSERT')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'UPDATE')
           OR NOT pg_catalog.has_table_privilege('crm_app', t, 'DELETE') THEN
            RAISE EXCEPTION 'crm-019: crm_app must read and write % (the draft working copy) and never truncate it', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-019: reader % may % on %', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.proposal', 'DELETE') THEN
        RAISE EXCEPTION 'crm-019: crm_app never deletes a proposal version';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-019: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF pg_catalog.has_function_privilege('crm_app', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('crm_eraser', 'crm.erase_subject(text,uuid,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-019: crm.erase_subject must be executable by crm_eraser only';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.erase_subject(text,uuid,uuid,boolean)', 'crm.guard_set_once()',
                             'crm.guard_proposal_draft()', 'crm.guard_selection()'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-019: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
    -- Every table an earlier key taught erase_subject, and this key's.
    FOREACH t IN ARRAY ARRAY['selection', 'option_rule', 'option', 'option_block', 'proposal_day',
                             'aa_request', 'inbox_events', 'booking_feed_state', 'signature_request',
                             'otp_challenge', 'traveler_access', 'payment', 'payment_schedule', 'proposal',
                             'agreement_doc', 'message', 'conversation', 'saved_reply', 'mail_import',
                             'ingest_address', 'channel_account', 'booking_line_money', 'booking_line',
                             'agency_supplier', 'fx_rate_override', 'membership_inbox', 'client_link',
                             'meeting_slot'] LOOP
        IF position(quote_literal(t) IN (SELECT prosrc FROM pg_catalog.pg_proc
                     WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
            RAISE EXCEPTION 'crm-019: crm.erase_subject does not erase crm.%', t;
        END IF;
    END LOOP;
    IF position('accepted_name_erased_at' IN (SELECT prosrc FROM pg_catalog.pg_proc
                 WHERE oid = 'crm.erase_subject(text,uuid,uuid,boolean)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'crm-019: crm.erase_subject lost the crm-016 typed acceptance name step';
    END IF;
    -- The proposal seal: sent_at is set-once now, the builder columns are sealed after draft.
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'proposal_sent_once'
                   AND tgrelid = 'crm.proposal'::regclass) THEN
        RAISE EXCEPTION 'crm-019: crm.proposal lost its sent_at set-once guard';
    END IF;
    FOREACH t IN ARRAY ARRAY['proposal_day', 'option_block', 'option', 'option_rule'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = t || '_draft_only'
                       AND tgrelid = ('crm.' || t)::regclass) THEN
            RAISE EXCEPTION 'crm-019: crm.% lost its draft-only guard', t;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-019', now(), 'AA-949: CRM-21a proposal model + day-list builder (proposal kind builder, price_visibility, room_config, deposit_pct, starts_on, edit_seq / selection_seq version counters, status published; proposal_day, option_block, option, option_rule, selection; draft-only and selection guards CRM35 / CRM36; sent_at set-once; erase_subject + hold guard for the new tables)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
