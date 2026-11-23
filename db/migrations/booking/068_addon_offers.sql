-- Migration bk-068: AA-1151 (S289 lane b-1151; S285 advisories PR-29 optional activities, T7, slice L8 of
-- root docs/audits/2026-11-19-S285-session/advisory-r2-plan.md) — optional activities as AA add-on offers: an offer
-- wraps one Booking service (an AA supplier's activity) with the places it is sold at and its sale rules, a second
-- person publishes it, and a read model lists the place add-ons on the days they have an in-force price.
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/068_addon_offers.sql and Migration Apply applies it on Dev as bk_owner once every job table is
-- idle (root ADR 0017a). Never run it from a laptop.
--
-- Depends on bk-008 (suppliers, supplier_contracts), bk-010 (services, supplier_rates), bk-039 (role tripplanner
-- reads booking views), bk-050 (pricing_policy), bk-060 (supply_restrictions, pax_type), bk-064
-- (owner_self_approval_guard).
--
-- Why: an activity is today a loose booking.services row: one place at most, no sale rules, and the only way to put
-- it in front of a traveller is a trip plan component, which adds it to the tour price (mandatory). PR-29 wants
-- optional activities per place and day, sold only with an AA supplier, approved by a second person, hidden on a day
-- without an in-force price (B3), with the T7 sale rules. Booking owns the commercial side (root ADR 0004a); CIS
-- writes the customer content from the service facts it already pulls (supply.service.v1, CIS 278).
--
-- What:
--   1. booking.addon_offers: one offer per service (UNIQUE service_id). Sale rules: min_pax, cutoff_hours, ISO
--      operating_weekdays (1 = Monday .. 7 = Sunday), start_times (local departure times, empty = flexible); the B4
--      child % override (child_pct: wins over the contract's child % when the supplier gives no child rate) and the
--      cancellation tier override (cancellation_tiers, the bk-060 shape; the contract's tiers are the default);
--      display order (sort_order, featured). Status draft -> published -> retired; a published offer is fixed (the
--      guard refuses a rule change in place): staff reopen it to draft, which empties the writer list to the person
--      who reopened it, so a second person publishes it again (a draft retired before any publish keeps its writers
--      on reopen: nobody approved its rules). Maker-checker like bk-064 contracts: writers (kept by
--      trigger addon_offers_writers, the client value is ignored), addon_offers_maker_checker_chk,
--      addon_offers_owner_self_chk and the owner_self_approval_guard trigger (mutable, recheck published_at: a
--      reopened and republished offer is checked again). Inventory (on request by default, free sale up to N,
--      stop-sale, allotment) is NOT on the offer: it stays the rows of the shared booking.supply_restrictions (bk-060)
--      for the service, so activities and hotels use one model (advisory T7, critic point 3).
--   2. booking.addon_offer_places: the CIS places (catalog.v_destination ids, soft key, checked by the API) where the
--      offer is sold, role operates | pickup. Written while the offer is a draft only; an insert also records its
--      writer on the offer (so adding a place makes that person a maker).
--   3. Two pricing policy parameters (Pricing > Policy, version 1 made by the migration, submitted and approved, in
--      force from 2026-01-01 like bk-063): addon_days_ahead = 365 (how many days ahead the read model lists) and
--      contract_expiry_alert_days = 60 (the daily contract expiry job warns this many days before a published supplier
--      contract ends; advisory B3, tech lead "60 days").
--   4. booking.v_place_addons (security barrier, contract supply.place_addons.v1 in the root docs/contracts): one row
--      per published offer, place and day from today (UTC) for addon_days_ahead days on which the offer runs (its
--      weekday) AND an adult rate of the service is in force under a published contract of its supplier AND no
--      stop-sale of the service is in effect (pending or approved, not ended: T13). The service and its supplier are
--      active. inventory_kind = free_sale | allotment (a contract term of that day) else on_request, with the
--      free-sale limit. No net, no price, no supplier identity: a reader quotes the component through booking.b2b.v1
--      (prices are fixed at quote time). SELECT to role tripplanner (the TripPlanner day cards, next slice; + USAGE on
--      schema booking, held since bk-039) and to booking.
--
-- Class: contract (root ADR 0017 d3): a foreign key to an existing table, guard functions, config rows. Migration-only
-- PR first (MIG-4); the code PR raises readiness to bk-068. The running code before the code PR never reads the new
-- tables, the view or the two keys (app.pricing.policy_values ignores a key the code does not know).
-- DM-6.1: no personal data (staff keys, sale rules). Commercial columns are tagged conf:commercial.
-- DM-7.1: both new tables have their row in the root data standards (root PR merged before the Infra copy).
-- Locks: services takes a SHARE ROW EXCLUSIVE lock for the foreign key (small table); lock_timeout 5s.
-- Re-runnable (the Integration Tests replay every file): IF NOT EXISTS, DROP CONSTRAINT IF EXISTS + ADD, CREATE OR
-- REPLACE, ON CONFLICT DO NOTHING.
-- Number: owner main max + 1 at ship (bk-067 is held by another lane of S289). If it moves, renumber: file name, this
-- header, the post-check, the registration, the seed ids (…b68000…) and the tests that name it (git grep '068_' and
-- 'bk-068').
-- Undo (a later bk- file, after the code is reverted): DROP the view, the two tables and their functions, DELETE the
-- seed:bk-068 policy events and versions.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF to_regclass('booking.supply_restrictions') IS NULL OR to_regprocedure('booking.owner_self_approval_guard()') IS NULL THEN
        RAISE EXCEPTION 'bk-068: needs bk-060 and bk-064 first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions
                WHERE version = 'bk-068' AND description NOT LIKE 'AA-1151:%') THEN
        RAISE EXCEPTION 'bk-068: the key bk-068 is already held by another migration (not AA-1151): renumber one';
    END IF;
END $$;

-- ── 1. Add-on offers ────────────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.addon_offers (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id           uuid NOT NULL REFERENCES booking.services (id),
    status               text NOT NULL DEFAULT 'draft',
    min_pax              smallint NOT NULL DEFAULT 1,
    cutoff_hours         smallint NOT NULL,
    operating_weekdays   smallint[] NOT NULL DEFAULT '{1,2,3,4,5,6,7}',
    start_times          time[] NOT NULL DEFAULT '{}',
    child_pct            numeric(5,2),
    cancellation_tiers   jsonb,
    sort_order           smallint NOT NULL DEFAULT 0,
    featured             boolean NOT NULL DEFAULT false,
    created_by           text NOT NULL,
    updated_by           text,
    writers              text[] NOT NULL DEFAULT '{}',
    published_by         text,
    published_at         timestamptz,
    owner_self_approved  boolean NOT NULL DEFAULT false,
    retired_by           text,
    retired_at           timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT addon_offers_service_uq UNIQUE (service_id),
    CONSTRAINT addon_offers_status_chk CHECK (status IN ('draft', 'published', 'retired')),
    CONSTRAINT addon_offers_rules_chk CHECK (
        min_pax BETWEEN 1 AND 999
        AND cutoff_hours BETWEEN 0 AND 720
        AND cardinality(operating_weekdays) BETWEEN 1 AND 7
        AND operating_weekdays <@ ARRAY[1, 2, 3, 4, 5, 6, 7]::smallint[]
        AND array_position(operating_weekdays, NULL) IS NULL
        AND cardinality(start_times) <= 24
        AND array_position(start_times, NULL) IS NULL
        AND sort_order BETWEEN -999 AND 999),
    CONSTRAINT addon_offers_child_chk CHECK (child_pct IS NULL OR child_pct BETWEEN 0 AND 100),
    CONSTRAINT addon_offers_tiers_chk CHECK (
        cancellation_tiers IS NULL OR (
            jsonb_typeof(cancellation_tiers) = 'array'
            AND jsonb_array_length(cancellation_tiers) BETWEEN 1 AND 20
            AND jsonb_path_exists(cancellation_tiers, '$[*] ? (@.min_days == 0)')
            AND NOT jsonb_path_exists(
                cancellation_tiers,
                '$[*] ? (!(exists(@.min_days) && @.min_days.type() == "number" && @.min_days >= 0'
                ' && @.min_days <= 730 && exists(@.fee_pct) && @.fee_pct.type() == "number" && @.fee_pct >= 0'
                ' && @.fee_pct <= 100))'))),
    CONSTRAINT addon_offers_published_chk CHECK (
        (status = 'draft' AND published_by IS NULL AND published_at IS NULL)
        OR (status = 'published' AND published_by IS NOT NULL AND published_at IS NOT NULL)
        OR status = 'retired'),
    CONSTRAINT addon_offers_retired_chk CHECK (
        (status = 'retired') = (retired_by IS NOT NULL)
        AND (retired_by IS NULL) = (retired_at IS NULL)),
    CONSTRAINT addon_offers_maker_checker_chk CHECK (
        published_by IS NULL OR NOT (published_by = ANY (writers)) OR owner_self_approved),
    CONSTRAINT addon_offers_owner_self_chk CHECK (
        owner_self_approved = (published_by IS NOT NULL AND published_by = ANY (writers))),
    CONSTRAINT addon_offers_text_chk CHECK (
        length(btrim(created_by)) BETWEEN 1 AND 128
        AND (updated_by IS NULL OR length(btrim(updated_by)) BETWEEN 1 AND 128)
        AND (published_by IS NULL OR length(btrim(published_by)) BETWEEN 1 AND 128)
        AND (retired_by IS NULL OR length(btrim(retired_by)) BETWEEN 1 AND 128))
);

CREATE INDEX IF NOT EXISTS addon_offers_status_idx ON booking.addon_offers (status, sort_order);

COMMENT ON TABLE booking.addon_offers IS
    'bk-068 (AA-1151, PR-29 B1 / B3 / B4 / T7): an optional activity AA sells per place and day: one Booking service of an AA supplier with its sale rules. draft -> published (a second person, maker-checker like contracts) -> retired; a published offer is fixed (reopen to draft to change it). Inventory (free sale, allotment, stop-sale; on request by default) = booking.supply_restrictions of the service.';
COMMENT ON COLUMN booking.addon_offers.min_pax IS
    'conf:commercial; bk-068 (T7): the fewest travellers the supplier runs the activity for.';
COMMENT ON COLUMN booking.addon_offers.cutoff_hours IS
    'conf:commercial; bk-068 (T7): book at least this many hours before the earliest departure time of the day (the day start when start_times is empty).';
COMMENT ON COLUMN booking.addon_offers.operating_weekdays IS
    'bk-068 (T7): ISO weekdays the activity runs (1 = Monday .. 7 = Sunday).';
COMMENT ON COLUMN booking.addon_offers.start_times IS
    'bk-068 (T7): local departure times of a running day; empty = flexible (any time).';
COMMENT ON COLUMN booking.addon_offers.child_pct IS
    'conf:commercial; bk-068 (B4): child net as a % of the adult net for this activity; wins over the contract''s child % when the supplier gives no child rate.';
COMMENT ON COLUMN booking.addon_offers.cancellation_tiers IS
    'conf:commercial; bk-068: [{min_days, fee_pct}] override of the contract''s cancellation tiers for this activity (bk-060 shape); NULL = the contract''s.';
COMMENT ON COLUMN booking.addon_offers.writers IS
    'bk-068: every staff key that wrote the draft (its creator, each updated_by while a draft, a place added; kept by trigger addon_offers_writers, the client value is ignored; reopening a published offer resets it to the person who reopened; a draft retired unpublished keeps its writers). The publisher is never one of them unless owner_self_approved.';
COMMENT ON COLUMN booking.addon_offers.owner_self_approved IS
    'bk-068: the business owner published an offer she wrote (checked against the CIS marker by booking.owner_self_approval_guard). Cleared when the offer is reopened.';

CREATE OR REPLACE FUNCTION booking.addon_offers_writers() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.writers := ARRAY[NEW.created_by];
        RETURN NEW;
    END IF;
    IF OLD.status <> 'draft' AND NEW.status = 'draft' THEN
        IF OLD.published_by IS NOT NULL THEN
            -- Reopened after a publish: its rules were approved; the new draft starts with the person who reopened it.
            NEW.writers := ARRAY[coalesce(NEW.updated_by, OLD.created_by)];
        ELSE
            -- A draft retired before anyone published it: nobody approved its rules, so its makers stay makers (else
            -- a second person's reopen would let the only writer publish their own work) and the reopener joins them.
            NEW.writers := OLD.writers;
            IF NEW.updated_by IS NOT NULL AND NOT (NEW.updated_by = ANY (OLD.writers)) THEN
                NEW.writers := OLD.writers || NEW.updated_by;
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    NEW.writers := OLD.writers;
    IF OLD.status = 'draft' AND NEW.status = 'draft' AND NEW.updated_by IS NOT NULL
       AND NOT (NEW.updated_by = ANY (OLD.writers)) THEN
        NEW.writers := OLD.writers || NEW.updated_by;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.addon_offers_writers() IS
    'bk-068: writers = [created_by] on INSERT; while a draft, plus each new updated_by; reopening an offer that was published (published, or retired after a publish -> draft) resets it to [updated_by]; reopening a draft retired before any publish keeps its writers and adds updated_by.';

GRANT EXECUTE ON FUNCTION booking.addon_offers_writers() TO booking;

CREATE OR REPLACE FUNCTION booking.addon_offers_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'add-on offer % is never deleted (retire it)', OLD.id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'draft' OR NEW.published_by IS NOT NULL OR NEW.retired_by IS NOT NULL THEN
            RAISE EXCEPTION 'a new add-on offer starts as a draft' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.service_id IS DISTINCT FROM OLD.service_id OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'add-on offer % keeps its service and creator', OLD.id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF OLD.status <> 'draft' AND NEW.status = OLD.status
       AND (NEW.min_pax, NEW.cutoff_hours, NEW.operating_weekdays, NEW.start_times, NEW.child_pct,
            NEW.cancellation_tiers, NEW.published_by, NEW.published_at, NEW.retired_by, NEW.retired_at)
           IS DISTINCT FROM
           (OLD.min_pax, OLD.cutoff_hours, OLD.operating_weekdays, OLD.start_times, OLD.child_pct,
            OLD.cancellation_tiers, OLD.published_by, OLD.published_at, OLD.retired_by, OLD.retired_at) THEN
        RAISE EXCEPTION 'a % add-on offer is fixed (reopen it as a draft to change its rules)', OLD.status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF OLD.status = 'draft' AND NEW.status = 'retired' AND OLD.published_by IS NULL THEN
        RETURN NEW;  -- a draft that never sold may be retired directly
    END IF;
    IF NEW.status = 'published' AND OLD.status <> 'draft' AND OLD.status <> 'published' THEN
        RAISE EXCEPTION 'a retired add-on offer is reopened as a draft before it is published again'
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF NEW.status = 'published' AND OLD.status = 'draft' AND NEW.published_at IS DISTINCT FROM now() THEN
        NEW.published_at := now();
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.addon_offers_guard() IS
    'bk-068: an offer starts as a draft, keeps its service and creator, is never deleted; a published or retired offer keeps its rules (reopen to draft first); a retired offer goes back through draft. Publishing stamps published_at = now().';

GRANT EXECUTE ON FUNCTION booking.addon_offers_guard() TO booking;

-- Trigger order is by name: guard, owner_self_approval, set_updated_at, writers; the CHECKs read the writers result.
CREATE OR REPLACE TRIGGER addon_offers_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.addon_offers
    FOR EACH ROW EXECUTE FUNCTION booking.addon_offers_guard();

CREATE OR REPLACE TRIGGER addon_offers_owner_self_approval
    BEFORE INSERT OR UPDATE ON booking.addon_offers
    FOR EACH ROW EXECUTE FUNCTION booking.owner_self_approval_guard('published_by', 'owner_self_approved', 'mutable', 'published_at');

CREATE OR REPLACE TRIGGER addon_offers_set_updated_at
    BEFORE UPDATE ON booking.addon_offers
    FOR EACH ROW EXECUTE FUNCTION booking.set_updated_at();

CREATE OR REPLACE TRIGGER addon_offers_writers
    BEFORE INSERT OR UPDATE ON booking.addon_offers
    FOR EACH ROW EXECUTE FUNCTION booking.addon_offers_writers();

-- Never deleted (retired instead): the app role gets no DELETE (the bk-014 default privileges would give it).
REVOKE DELETE, TRUNCATE ON booking.addon_offers FROM booking;
GRANT SELECT, INSERT, UPDATE ON booking.addon_offers TO booking;

-- ── 2. Places of an offer ───────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS booking.addon_offer_places (
    offer_id        uuid NOT NULL REFERENCES booking.addon_offers (id),
    destination_id  uuid NOT NULL,
    role            text NOT NULL DEFAULT 'operates',
    created_by      text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (offer_id, destination_id),
    CONSTRAINT addon_offer_places_role_chk CHECK (role IN ('operates', 'pickup')),
    CONSTRAINT addon_offer_places_text_chk CHECK (length(btrim(created_by)) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS addon_offer_places_destination_idx ON booking.addon_offer_places (destination_id);

COMMENT ON TABLE booking.addon_offer_places IS
    'bk-068 (AA-1151): the CIS places (catalog.v_destination ids, soft key checked by the API) where an add-on offer is sold: operates (the activity happens there) or pickup (travellers staying there are collected). Written while the offer is a draft only.';

CREATE OR REPLACE FUNCTION booking.addon_offer_places_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    v_offer  uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.offer_id ELSE NEW.offer_id END;
    v_status text;
BEGIN
    SELECT o.status INTO v_status FROM booking.addon_offers o WHERE o.id = v_offer FOR UPDATE;
    IF v_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'the places of a % add-on offer are fixed (reopen it as a draft)', v_status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.offer_id, NEW.destination_id) IS DISTINCT FROM (OLD.offer_id, OLD.destination_id) THEN
        RAISE EXCEPTION 'a place row keeps its offer and place (delete it and add another)'
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF TG_OP = 'INSERT' THEN
        -- The person who adds a place is a maker of the draft (addon_offers_writers appends updated_by).
        UPDATE booking.addon_offers SET updated_by = NEW.created_by WHERE id = NEW.offer_id;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION booking.addon_offer_places_guard() IS
    'bk-068: places change while the offer is a draft only; an insert records its creator as a writer of the offer.';

GRANT EXECUTE ON FUNCTION booking.addon_offer_places_guard() TO booking;

CREATE OR REPLACE TRIGGER addon_offer_places_guard
    BEFORE INSERT OR UPDATE OR DELETE ON booking.addon_offer_places
    FOR EACH ROW EXECUTE FUNCTION booking.addon_offer_places_guard();

GRANT SELECT, INSERT, UPDATE, DELETE ON booking.addon_offer_places TO booking;

-- ── 3. Pricing policy: the read model horizon and the contract expiry warning, version 1 ────────────────────────

INSERT INTO booking.pricing_policy (id, param_key, version_no, value, unit, effective_from, reason, created_by)
VALUES
    ('00000000-0000-4000-8000-0000b6800000', 'addon_days_ahead', 1, '365'::jsonb, 'days', DATE '2026-01-01',
     'AA-1151: how many days ahead booking.v_place_addons lists the days an add-on can be sold.', 'seed:bk-068'),
    ('00000000-0000-4000-8000-0000b6800010', 'contract_expiry_alert_days', 1, '60'::jsonb, 'days', DATE '2026-01-01',
     'AA-1151 (advisory B3): the contract expiry job warns this many days before a published supplier contract ends.',
     'seed:bk-068')
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT e.id, p.id, p.created_by, 'submitted', p.created_by
FROM (VALUES ('00000000-0000-4000-8000-0000b6800001'::uuid, '00000000-0000-4000-8000-0000b6800000'::uuid),
             ('00000000-0000-4000-8000-0000b6800011'::uuid, '00000000-0000-4000-8000-0000b6800010'::uuid)) AS e (id, pid)
JOIN booking.pricing_policy p ON p.id = e.pid AND p.created_by = 'seed:bk-068'
ON CONFLICT DO NOTHING;

INSERT INTO booking.pricing_policy_events (id, policy_id, maker, event, actor)
SELECT e.id, p.id, p.created_by, 'approved', e.actor
FROM (VALUES ('00000000-0000-4000-8000-0000b6800002'::uuid, '00000000-0000-4000-8000-0000b6800000'::uuid,
              'tech lead S279 (thresholds rule: seeded defaults)'),
             ('00000000-0000-4000-8000-0000b6800012'::uuid, '00000000-0000-4000-8000-0000b6800010'::uuid,
              'tech lead S285 (contract expiring 60 days ahead)')) AS e (id, pid, actor)
JOIN booking.pricing_policy p ON p.id = e.pid AND p.created_by = 'seed:bk-068'
ON CONFLICT DO NOTHING;

-- ── 4. Read model: place add-ons on the days they can be sold ───────────────────────────────────────────────────

CREATE OR REPLACE VIEW booking.v_place_addons WITH (security_barrier = true) AS
WITH horizon AS (
    SELECT coalesce((
        SELECT (p.value #>> '{}')::integer
          FROM booking.pricing_policy p
          JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
         WHERE p.param_key = 'addon_days_ahead' AND p.effective_from <= (now() AT TIME ZONE 'UTC')::date
         ORDER BY p.effective_from DESC, a.created_at DESC, p.version_no DESC
         LIMIT 1), 0) AS days
),
days AS (
    SELECT ((now() AT TIME ZONE 'UTC')::date + g.n)::date AS service_date
      FROM horizon h, generate_series(0, h.days - 1) AS g (n)
)
SELECT 'sv:' || s.id::text AS component_id,
       s.id AS service_id,
       o.id AS offer_id,
       pl.destination_id,
       pl.role AS place_role,
       d.service_date,
       s.service_type,
       s.unit,
       s.duration_minutes,
       s.max_group_size,
       s.country_code::text AS country_code,
       o.min_pax,
       o.cutoff_hours,
       o.operating_weekdays,
       ARRAY(SELECT to_char(t, 'HH24:MI') FROM unnest(o.start_times) AS t ORDER BY t) AS start_times,
       o.sort_order,
       o.featured,
       coalesce(inv.inventory_kind, 'on_request') AS inventory_kind,
       inv.free_sale_max_pax,
       s.supply_version,
       o.published_at
  FROM booking.addon_offers o
  JOIN booking.services s ON s.id = o.service_id
  JOIN booking.suppliers sp ON sp.id = s.supplier_id
  JOIN booking.addon_offer_places pl ON pl.offer_id = o.id
  CROSS JOIN days d
  LEFT JOIN LATERAL (
        SELECT r.inventory_kind, r.max_pax AS free_sale_max_pax
          FROM booking.supply_restrictions r
          JOIN booking.supplier_contracts rk ON rk.id = r.supplier_contract_id AND rk.status = 'published'
         WHERE r.service_id = s.id AND r.status = 'contract' AND r.inventory_kind IN ('free_sale', 'allotment')
           AND d.service_date BETWEEN r.date_from AND r.date_to
         ORDER BY CASE r.inventory_kind WHEN 'allotment' THEN 1 ELSE 2 END, r.created_at
         LIMIT 1) inv ON true
 WHERE o.status = 'published'
   AND s.status = 'active'
   AND sp.status = 'active'
   AND extract(isodow FROM d.service_date)::smallint = ANY (o.operating_weekdays)
   AND EXISTS (
        SELECT 1
          FROM booking.supplier_rates x
          JOIN booking.supplier_contracts k ON k.id = x.supplier_contract_id
         WHERE x.service_id = s.id AND x.pax_type = 'adult'
           AND k.status = 'published' AND k.supplier_id = s.supplier_id
           AND k.valid_from <= d.service_date AND (k.valid_to IS NULL OR k.valid_to >= d.service_date)
           AND x.valid_from <= d.service_date AND (x.valid_to IS NULL OR x.valid_to >= d.service_date))
   AND NOT EXISTS (
        SELECT 1
          FROM booking.supply_restrictions st
         WHERE st.service_id = s.id AND st.inventory_kind = 'stop_sale'
           AND st.status IN ('pending', 'approved') AND st.ended_by IS NULL
           AND d.service_date BETWEEN st.date_from AND st.date_to);

COMMENT ON VIEW booking.v_place_addons IS
    'bk-068 (AA-1151, contract supply.place_addons.v1): one row per published add-on offer, place and day (today UTC + addon_days_ahead) on which it runs, has an in-force adult rate under a published contract of its active supplier and no stop-sale in effect. No net, price or supplier identity: quote the component_id through booking.b2b.v1. SELECT to tripplanner.';

-- A view is read-only for the app role (the bk-014 default privileges would give it DML).
REVOKE INSERT, UPDATE, DELETE ON booking.v_place_addons FROM booking;
GRANT SELECT ON booking.v_place_addons TO booking;
GRANT USAGE ON SCHEMA booking TO tripplanner;
GRANT SELECT ON booking.v_place_addons TO tripplanner;

-- ── 5. Post-check: both parameters have an approved version 1 ───────────────────────────────────────────────────

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(*) INTO n
    FROM booking.pricing_policy p
    JOIN booking.pricing_policy_events a ON a.policy_id = p.id AND a.event = 'approved'
    WHERE p.created_by = 'seed:bk-068' AND p.version_no = 1;
    IF n <> 2 THEN
        RAISE EXCEPTION 'bk-068: % of the 2 new pricing policy parameters have an approved version 1', n
            USING HINT = 'A key already had a version 1 made by someone else; the seed must not overwrite it.';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-068', now(), 'AA-1151: add-on offers (optional activities per place with sale rules, second-person publish), their places, the place add-on read model v_place_addons and the addon_days_ahead / contract_expiry_alert_days policy values')
ON CONFLICT (version) DO NOTHING;

COMMIT;
