-- Migration bk-070: AA-1152 (S289 lane g-1152; S285 advisory PR-29 T6, slice L9 of root
-- docs/audits/2026-11-19-S285-session/advisory-r2-plan.md) — booking.v_place_addons gains the add-on's title, so the
-- TripPlanner day cards can name an add-on (contract supply.place_addons.v1 1.1).
--
-- Owner: AA-Booking (key bk-NNN). AA-CIS-Infra Migration Sync copies it byte for byte to
-- db/migrations/booking/070_place_addons_title.sql and Migration Apply applies it on Dev as bk_owner once every job
-- table is idle (root ADR 0017a). Never run it from a laptop.
--
-- Depends on bk-068 (the view, AA-1151).
--
-- Why: role tripplanner reads this view and nothing of CIS supply content (catalog.v_supply_content is granted to
-- booking only), so a day card had an sv: id and sale rules but no name to show. The title is AA's name of the
-- service (booking.services.title, English, entered by AA staff; never a supplier identity), the same name the agency
-- CRM sees in booking.b2b.v1 1.11 GET /add-ons.
--
-- What: CREATE OR REPLACE VIEW booking.v_place_addons with the bk-068 body unchanged and one column appended at the end
-- (title text). Columns are append-only (contract rule), so a reader of 1.0 keeps working; grants survive CREATE OR
-- REPLACE (restated below anyway, as bk-068 left them).
--
-- Class: contract (root ADR 0017 d3: it replaces an existing view a consumer reads). Migration-only PR first (MIG-4);
-- the TripPlanner day cards read the column after it is applied and fail soft before (UndefinedColumn = no add-on).
-- DM-6.1: no personal data. DM-7.1: no new table.
-- Re-runnable (the Integration Tests replay every file): CREATE OR REPLACE.
-- Number: owner main max + 1. If it moves, renumber: file name, this header, the guard, the registration and the tests
-- that name it (git grep '070_' and 'bk-070').

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'bk-068') THEN
        RAISE EXCEPTION 'bk-070: bk-068 (the add-on offers and v_place_addons) lands first';
    END IF;
    IF EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'bk-070' AND description NOT LIKE 'AA-1152%') THEN
        RAISE EXCEPTION 'bk-070: the key bk-070 is already held by another migration (not AA-1152): renumber one';
    END IF;
END
$$;

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
       o.published_at,
       s.title
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
    'bk-068 (AA-1151) + bk-070 (AA-1152, title), contract supply.place_addons.v1 1.1: one row per published add-on offer, place and day (today UTC + addon_days_ahead) on which it runs, has an in-force adult rate under a published contract of its active supplier and no stop-sale in effect; title = AA''s name of the service. No net, price or supplier identity: quote the component_id through booking.b2b.v1. SELECT to tripplanner.';
COMMENT ON COLUMN booking.v_place_addons.title IS
    'bk-070 (AA-1152): AA''s name of the add-on (booking.services.title, English, no supplier); the customer text and photos stay CIS''s.';

REVOKE INSERT, UPDATE, DELETE ON booking.v_place_addons FROM booking;
GRANT SELECT ON booking.v_place_addons TO booking;
GRANT SELECT ON booking.v_place_addons TO tripplanner;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'booking' AND table_name = 'v_place_addons' AND column_name = 'title') THEN
        RAISE EXCEPTION 'bk-070: booking.v_place_addons has no title column';
    END IF;
END
$$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-070', now(), 'AA-1152: booking.v_place_addons appends title (AA''s name of the add-on) for the TripPlanner day cards (supply.place_addons.v1 1.1)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
