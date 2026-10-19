-- Migration bk-016: AA-680 (Booking Phase 2, root ADR 0006 / 0006a) — Cognito WORKFORCE identity on booking.staff_users.
--
-- Owner: AA-Booking (key bk-NNN). A byte-identical copy goes to AA-CIS-Infra db/migrations/booking/016_staff_cognito_identity.sql
-- and is applied to Dev by the DB Migrate workflow (check, then apply), as bk_owner (the live owner of schema booking
-- since bk-014). Never run it from a laptop.
--
-- Why: Booking staff now sign in with the Cognito WORKFORCE pool (client booking-staff / breakglass) next to the CIS
-- bridge token. A staff row is found by its Cognito identity (cognito_iss, cognito_sub). The primary key stays
-- cis_user_id (about 30 foreign keys point at it); the column is now "the Booking staff key" under its legacy name:
--   * bridge-era rows keep the CIS shared.admin_users.id they were created with; the one-time Infra script
--     db/scripts/aa680_link_staff_cognito.py copies admin_users.cognito_iss / cognito_sub onto them;
--   * a WORKFORCE user with no linked row gets a new row keyed 'cog:' || sub on the first sign-in.
-- staff_users_cognito_key_chk ties the two: a 'cog:' key always carries its own sub, so the key and the identity can
-- never disagree. NULL pairs are distinct in the unique index, so any number of rows may still be unlinked.
--
-- Depends on bk-003 (booking.staff_users). Adds two nullable columns (no default: no table rewrite on PG 15), two
-- CHECKs and one unique index on a table of a handful of rows. Role booking already has table-level
-- SELECT/INSERT/UPDATE/DELETE on booking.staff_users (bk-003): no grant change. Re-runnable (the Integration Tests
-- replay every file): ADD COLUMN / CREATE INDEX IF NOT EXISTS, each CHECK dropped if present and added again.

BEGIN;

SET LOCAL lock_timeout = '5s';

ALTER TABLE booking.staff_users
    ADD COLUMN IF NOT EXISTS cognito_iss TEXT,
    ADD COLUMN IF NOT EXISTS cognito_sub TEXT;

ALTER TABLE booking.staff_users DROP CONSTRAINT IF EXISTS staff_users_cognito_pair_chk;
ALTER TABLE booking.staff_users ADD CONSTRAINT staff_users_cognito_pair_chk CHECK (
    (cognito_iss IS NULL AND cognito_sub IS NULL)
    OR (cognito_iss IS NOT NULL AND cognito_sub IS NOT NULL
        AND cognito_iss LIKE 'https://%' AND length(cognito_sub) BETWEEN 1 AND 128)
);

ALTER TABLE booking.staff_users DROP CONSTRAINT IF EXISTS staff_users_cognito_key_chk;
ALTER TABLE booking.staff_users ADD CONSTRAINT staff_users_cognito_key_chk CHECK (
    left(cis_user_id, 4) <> 'cog:' OR (cognito_sub IS NOT NULL AND cognito_sub = substr(cis_user_id, 5))
);

CREATE UNIQUE INDEX IF NOT EXISTS staff_users_cognito_identity_key
    ON booking.staff_users (cognito_iss, cognito_sub);

COMMENT ON TABLE booking.staff_users IS
    'bk-003 (ADR 0004 O1) + bk-016 (ADR 0006a): Booking profile of a staff user. Bridge-era rows were provisioned from the CIS staff JWT; WORKFORCE rows are linked or created by Cognito identity. Role and active of a linked row follow its booking-* Cognito groups.';
COMMENT ON COLUMN booking.staff_users.cis_user_id IS
    'The Booking staff key (legacy name; every staff FK points here): CIS shared.admin_users.id for bridge-era rows, ''cog:'' || Cognito sub for rows created on a WORKFORCE sign-in (bk-016).';
COMMENT ON COLUMN booking.staff_users.cognito_iss IS
    'bk-016: issuer of the linked Cognito identity (the WORKFORCE pool issuer); NULL = not linked yet.';
COMMENT ON COLUMN booking.staff_users.cognito_sub IS
    'bk-016: sub of the linked Cognito identity; unique with cognito_iss; never rebound to another identity by the app.';

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('bk-016', now(), 'AA-680 (Phase 2): booking.staff_users cognito_iss / cognito_sub (+ pair and cog: key checks, unique identity index)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
