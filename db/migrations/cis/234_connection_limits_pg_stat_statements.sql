-- Migration 234: AA-824 (data standards N3, C2.2) — per-role connection limits on the shared RDS and the
-- pg_stat_statements extension.
--
-- Why. The shared Dev RDS (CIS + TripPlanner + Booking) had no per-role connection limit: one app's burst
-- (TripPlanner Lambdas, a Booking deploy, a tenant-pool spike) could take every connection and stop the
-- other two. S237 moved the instance to db.t4g.small (max_connections 181) and preloaded
-- pg_stat_statements through the new parameter group (Infra #121, rebooted 15/10); the extension itself
-- is created by a migration, like every other database object.
--
-- What.
--   * CREATE EXTENSION pg_stat_statements (needs rds_superuser on RDS: the runner aa_cis_admin is a member).
--   * CONNECTION LIMIT per app runtime role (budget, data standards C2.2):
--       tripplanner 30  — browse 15 + assembly 5 reserved Lambda instances x pool max 1 = 20, plus headroom
--       booking     15  — pool max 5 per task; a rolling deploy runs two tasks (10) plus one-off scripts
--       aa_app_user 15  — CIS tenant pool max 5 per api task; a rolling deploy runs two tasks
--     The CIS runtime role aa_cis_admin (main pool, worker, DB Migrate) stays unlimited until the role split
--     (X1): limiting the migration runner here could lock DB Migrate out.
--   This is the single MIG-6 exception of the data standards (open item 1, "N3 interim"): role attributes
--   belong to an Infra role bootstrap (X1), which does not exist yet. Remove this exception when it does.
--
-- Cross-owner role changes are not guarded by IF EXISTS(role) (schema-ownership rule 5): the three roles
-- exist on Dev (TripPlanner/Booking bootstrap, 007b) and in CI (conftest). Idempotent.
--
-- Rollback: ALTER ROLE <role> CONNECTION LIMIT -1 for the three roles; DROP EXTENSION pg_stat_statements;
--           DELETE FROM shared.schema_versions WHERE version = '234'.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

ALTER ROLE tripplanner CONNECTION LIMIT 30;
ALTER ROLE booking CONNECTION LIMIT 15;
ALTER ROLE aa_app_user CONNECTION LIMIT 15;

-- Guards: the limits and the extension are really in place.
DO $$
DECLARE
    bad text;
BEGIN
    SELECT string_agg(rolname || '=' || rolconnlimit, ', ') INTO bad
      FROM pg_roles
     WHERE (rolname, rolconnlimit) NOT IN (('tripplanner', 30), ('booking', 15), ('aa_app_user', 15))
       AND rolname IN ('tripplanner', 'booking', 'aa_app_user');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 234: connection limits not applied: %', bad;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RAISE EXCEPTION 'migration 234: pg_stat_statements extension missing';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('234', now(),
    'AA-824: CONNECTION LIMIT tripplanner 30 / booking 15 / aa_app_user 15 (data standards C2.2, N3 interim '
    'MIG-6 exception until the X1 role bootstrap) + CREATE EXTENSION pg_stat_statements')
ON CONFLICT (version) DO NOTHING;

COMMIT;
