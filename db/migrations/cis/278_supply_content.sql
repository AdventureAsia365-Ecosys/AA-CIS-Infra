-- Migration 278: AA-835 (root ADR 0004a) — the CIS side of supply content: the consumer state of the Booking supply
-- feed, the AA-written content per Booking hotel / service with its human review, and the read-back contract view
-- catalog.v_supply_content that Booking reads.
--
-- Why. ADR 0004a (hybrid supply content): Booking owns the hotel and service facts and emits them on the `supply`
-- stream of booking.outbox (bk-023, contracts supply.hotel.v1 / supply.service.v1, facts read from
-- booking.v_supply_hotels / v_supply_services, granted to cis_app). CIS pulls them, drafts the customer-facing text
-- with an LLM, a human reviews and publishes it, and Booking shows only published text (hotel / service pages and
-- proposals, AA-835 S4) through a CIS view, never a copy. Nothing on the CIS side exists yet (schema reference
-- 24/10/2026: no shared.supply_*, no catalog.v_supply_content). This file is storage only; the consumer, the draft
-- job and the review API arrive with the AA-835 S6 code PR.
--
-- What.
--   Part A (cis_owner, the owner of shared since 245) — platform tables: no tenant column, no personal data, no RLS
--   (rls_catalogue_rules rule a does not apply: no tenant key), cis_app only (+ catalog_owner SELECT for part B).
--     1. shared.supply_entity: one row per Booking entity, keyed (source_system 'booking', source_id = the Booking
--        hotel / service id as text). entity_type hotel | service, service_type (services only), title (hotel name
--        / service working_title) and country_code for the admin list, facts jsonb (the contract `facts` object as
--        received), applied_supply_version (the newest supply_version applied; older or equal events are skipped,
--        ADR 0004a decision 4), active, content_status:
--          draft        no content yet (a draft is being written)
--          in_review    a draft waits for review, nothing published yet
--          published    published_version_id is the approved version Booking shows
--          stale        published once, then the facts changed: Booking shows no text until a new version is
--                       approved (the read-back hides it)
--          unpublished  staff unpublished it, or Booking deactivated / removed the entity (rows are kept)
--        published_version_id = the last approved version of THIS entity (composite FK below), kept after an
--        unpublish so the diff of the next draft has a base. CHECKs: published needs a version; an inactive entity
--        is unpublished.
--     2. shared.supply_content_version: every version of the content of one entity, numbered per entity
--        (content_version). origin llm | human; description, highlights (<= 5), good_to_know (<= 3), photos jsonb
--        [{media_id, caption, alt}] (Booking entity_media ids, never a URL); supply_version = the facts version it
--        was written against; status draft -> approved | rejected | superseded, approved -> superseded. At most one
--        approved version per entity (partial unique index). A BEFORE UPDATE OR DELETE trigger keeps a version's
--        content immutable (an edit is a new human version), allows only those status moves, and refuses a DELETE
--        unless the version is rejected or superseded and older than 180 days (DM-7 row S250 R2, proposed).
--        llm_job_id = the shared.job that wrote an llm draft (its shared.llm_call_log rows carry the same job_id).
--     3. shared.supply_event_inbox: the idempotency record of the feed (contracts README rule 3), one row per
--        Booking outbox event: UNIQUE (source, contract, idempotency_key = booking.outbox.event_id), source_id,
--        event_type, supply_version (the event's), facts_supply_version (the facts row read with it), feed_seq,
--        outcome applied | skipped_older | missing. Ids, versions and the outcome only.
--     4. shared.supply_feed_cursor: one row per consumer: last_feed_seq (the cursor on booking.v_supply_outbox),
--        last_pull_at, last_success_at, last_error, last_error_at (the observability rule: lag and last error).
--     5. shared.supply_media: the Booking photos CIS knows (booking_media_id PK), their usage_rights and sha256 as
--        Booking reports them, and the CIS copies of the rights-cleared ones (WebP 1600 / 600 under the bronze
--        photos/supply/ prefix, their CDN URLs, the sha256 that was copied). Copy columns all set or all NULL.
--     6. Stage key supply_content_writer (writer, Claude Sonnet on acc3, no fallback, no shadow) in
--        shared.llm_role_config, and the spend budget bedrock / job:supply_content_draft ($0.10 a run, $1.00 a day,
--        hard stop) in shared.spend_budget. Both ON CONFLICT DO NOTHING: an admin change is never overwritten.
--     7. Grants. REVOKE ALL from PUBLIC, cis_app, aa_app_user, catalog_owner first (it also takes away the DML the
--        Dev default ACL of cis_owner gives cis_app on every new table and sequence in shared, CIS 245; SCHEDULE
--        S250 §5 point 3), then exactly: cis_app SELECT, INSERT, UPDATE on supply_entity, supply_content_version,
--        supply_feed_cursor and supply_media; SELECT, INSERT on supply_event_inbox (append-only); nothing on the
--        identity sequence (an identity column's nextval does not check it). catalog_owner SELECT on supply_entity,
--        supply_content_version and supply_media (part B). aa_app_user nothing (AA-859 invariant: no tenant-pool
--        privilege on a relation without RLS). No DELETE for anyone: no retention runs before DM-7.5 approval.
--   Part B (catalog_owner, the X1 S22 catalog recipe, as 253 / 256 / 257 / 258 / 273 / 274):
--     8. catalog.v_supply_content (security_barrier), one row per supply_entity: source_system, source_id,
--        entity_type, content_status, content_version (the published version's number while published, else the
--        newest version's, NULL when none), description, highlights, good_to_know, photo_urls (text[] of the CDN
--        URLs of the published photos whose media has usage_rights, is active and is copied, in the version's
--        order), edit_url ('/admin/supply-content/' || id, the CIS admin path; Booking prefixes its CIS_ADMIN_URL),
--        published_at. The text and photo columns are non-NULL only while content_status = 'published', the entity
--        is active and the version is approved: a draft, in_review, stale or unpublished row shows NULL text (ADR
--        0004a: proposals use published text only). SELECT to booking only (schema-ownership rule: catalog.*:booking
--        contract grant, CIS 225 / 228, owners.yaml cis consumer_grants; rls_catalogue_rules `catalog.*:booking`).
--        Not to tripplanner or aa_app_user: nobody else reads it. Booking's reader (AA-Booking app/supply/content.py)
--        feature-detects the view and the columns source_system, source_id, entity_type, content_status,
--        content_version, description, highlights, photo_urls and edit_url: keep them (append-only changes).
--   9. Register 278.
--
-- Guards (RAISE rolls the whole file back; nothing changes):
--   1. before, part A: roles cis_app, aa_app_user, catalog_owner exist; the runner may create in shared; each table
--      of this file that exists already has exactly this file's columns (re-run).
--   2. after, part A: the named constraints validated, the guard trigger, privileges exactly as in point 7 for
--      PUBLIC, cis_app, aa_app_user and catalog_owner (no column-level grant), the guard function not SECURITY
--      DEFINER with a pinned search_path and no EXECUTE for PUBLIC.
--   3. before, part B: schema catalog owned by cis_owner (245); roles catalog_owner and booking exist; catalog_owner
--      has USAGE on shared and SELECT on the three tables; the view, if present, is catalog_owner's (re-run).
--   4. after, part B (as catalog_owner, then as cis_owner): the view catalog_owner's and security_barrier, its
--      columns exactly as in point 8, grants exactly SELECT to booking (no PUBLIC, no column grants), no row with
--      text that is not published; catalog_owner has no CREATE on catalog any more; aa_app_user holds nothing on the
--      five tables or the view.
--
-- Preflight (read-only, as cis_app through the S3-mediated ECS exec; expected: all NULL / 0, and bk-023 applied so
-- the feed exists):
--   SELECT to_regclass('shared.supply_entity') AS entity, to_regclass('shared.supply_content_version') AS version,
--          (SELECT count(*) FROM shared.llm_role_config WHERE stage = 'supply_content_writer') AS stage_rows,
--          (SELECT count(*) FROM booking.v_supply_outbox) AS booking_supply_events;
--
-- Locks. New tables, one new view, two INSERTs into small config tables: catalog-only locks. lock_timeout 5s. Apply
-- through AA-CIS-Infra DB Migrate (byte copy in db/migrations/cis/) with the job tables idle (DM-11.4), after 275,
-- 276 and 277 (keys in order). Re-running is a no-op apart from the guards (IF NOT EXISTS, CREATE OR REPLACE,
-- grants from nothing, ON CONFLICT DO NOTHING).
--
-- Order with the code. Nothing reads these objects until the AA-835 S6 code PR (services/supply_content, the
-- supply_content_draft job, /admin/supply-content) deploys, and that code needs them: merge this file's PR, copy to
-- Infra, DB Migrate check -> apply, merge the schema-reference bot PR, then merge and deploy the code PR. Booking's
-- read-back (S4) turns on by itself once the view exists with its grant.
--
-- Recipe / X1. One BEGIN … COMMIT, run by DB Migrate as cis_owner (login db_migrator). Part A runs as cis_owner. Part
-- B uses the X1 S22 catalog recipe (CONTEXT.md): GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE
-- catalog_owner; the view and its grant; SET LOCAL ROLE cis_owner; REVOKE CREATE. Never RESET ROLE, no SECURITY
-- DEFINER, no role DDL. The conftest replay applies only part A (it skips 245 and the catalog recipe cannot run
-- there); tests/integration/test_aa835_migration_278.py applies the whole file the DB Migrate way on the RDS-like
-- state and rolls back.
--
-- Rollback (a NEW forward migration, after reverting the S6 code; Booking's reader turns itself off when the view
-- goes): under the catalog recipe DROP VIEW catalog.v_supply_content; then DROP TABLE shared.supply_media,
-- shared.supply_feed_cursor, shared.supply_event_inbox; ALTER TABLE shared.supply_entity DROP CONSTRAINT
-- supply_entity_published_version_fkey; DROP TABLE shared.supply_content_version, shared.supply_entity; DROP
-- FUNCTION shared.supply_content_version_guard(); DELETE FROM shared.llm_role_config WHERE stage =
-- 'supply_content_writer'; DELETE FROM shared.spend_budget WHERE provider = 'bedrock' AND scope =
-- 'job:supply_content_draft'.
--
-- The SQL that is applied to Dev is the copy in AA-CIS-Infra db/migrations/cis/ (DB Migrate workflow); keep the two
-- byte-identical. After apply: regenerate docs/architecture/db-schema-reference.md (DB Schema Dump workflow).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── Part A: the CIS supply content tables (cis_owner) ──────────────────────────────────────────────────────────────
DO $$
DECLARE
    t       text;
    cols    text;
    expect  jsonb := jsonb_build_object(
        'shared.supply_entity',
            'id uuid, source_system text, source_id text, entity_type text, service_type text, title text, '
            'country_code text, facts jsonb, applied_supply_version bigint, active boolean, content_status text, '
            'published_version_id uuid, created_at timestamp with time zone, updated_at timestamp with time zone',
        'shared.supply_content_version',
            'id uuid, entity_id uuid, content_version integer, supply_version bigint, origin text, description text, '
            'highlights text[], good_to_know text[], photos jsonb, status text, based_on_version_id uuid, '
            'llm_job_id uuid, created_by text, created_at timestamp with time zone, reviewed_by text, '
            'reviewed_at timestamp with time zone, review_note text',
        'shared.supply_event_inbox',
            'id bigint, source text, contract text, idempotency_key uuid, source_id text, event_type text, '
            'supply_version bigint, facts_supply_version bigint, feed_seq bigint, outcome text, '
            'received_at timestamp with time zone',
        'shared.supply_feed_cursor',
            'consumer text, last_feed_seq bigint, last_pull_at timestamp with time zone, '
            'last_success_at timestamp with time zone, last_error text, last_error_at timestamp with time zone',
        'shared.supply_media',
            'booking_media_id uuid, entity_id uuid, usage_rights boolean, active boolean, sha256 text, '
            'content_type text, width integer, height integer, cis_key_1600 text, cis_key_600 text, url_1600 text, '
            'url_600 text, copied_sha256 text, copied_at timestamp with time zone, '
            'updated_at timestamp with time zone');
BEGIN
    IF to_regrole('cis_app') IS NULL OR to_regrole('aa_app_user') IS NULL OR to_regrole('catalog_owner') IS NULL THEN
        RAISE EXCEPTION 'migration 278: roles cis_app, aa_app_user and catalog_owner must exist';
    END IF;
    IF NOT has_schema_privilege(current_user, 'shared', 'CREATE') THEN
        RAISE EXCEPTION 'migration 278: % may not create in shared; run it through DB Migrate (cis_owner)',
            current_user;
    END IF;
    FOR t IN SELECT jsonb_object_keys(expect) LOOP
        IF to_regclass(t) IS NOT NULL THEN
            SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
              INTO cols
              FROM pg_attribute a WHERE a.attrelid = to_regclass(t) AND a.attnum > 0 AND NOT a.attisdropped;
            IF cols IS DISTINCT FROM expect ->> t THEN
                RAISE EXCEPTION 'migration 278: % exists with other columns: %', t, cols;
            END IF;
        END IF;
    END LOOP;
END $$;

-- ── 1. The Booking entities CIS writes content for ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.supply_entity (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_system          text NOT NULL DEFAULT 'booking',
    source_id              text NOT NULL,
    entity_type            text NOT NULL,
    service_type           text,
    title                  text NOT NULL,
    country_code           text,
    facts                  jsonb NOT NULL,
    applied_supply_version bigint NOT NULL,
    active                 boolean NOT NULL DEFAULT true,
    content_status         text NOT NULL DEFAULT 'draft',
    published_version_id   uuid,
    created_at             timestamp with time zone NOT NULL DEFAULT now(),
    updated_at             timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT supply_entity_source_key UNIQUE (source_system, source_id),
    CONSTRAINT supply_entity_source_system_check CHECK (source_system = 'booking'),
    CONSTRAINT supply_entity_source_id_check CHECK (source_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    CONSTRAINT supply_entity_entity_type_check CHECK (entity_type IN ('hotel', 'service')),
    CONSTRAINT supply_entity_service_type_check CHECK (entity_type = 'service' OR service_type IS NULL),
    CONSTRAINT supply_entity_facts_check CHECK (jsonb_typeof(facts) = 'object'),
    CONSTRAINT supply_entity_version_check CHECK (applied_supply_version >= 1),
    CONSTRAINT supply_entity_content_status_check
        CHECK (content_status IN ('draft', 'in_review', 'published', 'stale', 'unpublished')),
    CONSTRAINT supply_entity_published_check CHECK (content_status <> 'published' OR published_version_id IS NOT NULL),
    CONSTRAINT supply_entity_inactive_check CHECK (active OR content_status = 'unpublished')
);

CREATE INDEX IF NOT EXISTS supply_entity_status_idx ON shared.supply_entity (content_status, updated_at DESC);

COMMENT ON TABLE shared.supply_entity IS
    'AA-835 (CIS 278, root ADR 0004a): one row per Booking hotel / service CIS writes customer content for, keyed '
    '(source_system booking, source_id = the Booking id). facts = the supply.hotel.v1 / supply.service.v1 facts as '
    'received; applied_supply_version = the newest version applied (older events are skipped). Written by the CIS '
    'supply feed consumer (services/supply_content) and the review API; Booking reads the result only through '
    'catalog.v_supply_content.';
COMMENT ON COLUMN shared.supply_entity.content_status IS
    'draft (no content yet) | in_review (a draft waits, nothing published) | published (published_version_id is '
    'live) | stale (facts changed after publishing: no text is served until a new version is approved) | '
    'unpublished (staff unpublished, or Booking deactivated / removed the entity; rows kept).';

-- ── 2. The content versions ────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.supply_content_version (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id           uuid NOT NULL,
    content_version     integer NOT NULL,
    supply_version      bigint NOT NULL,
    origin              text NOT NULL,
    description         text NOT NULL,
    highlights          text[] NOT NULL DEFAULT '{}'::text[],
    good_to_know        text[] NOT NULL DEFAULT '{}'::text[],
    photos              jsonb NOT NULL DEFAULT '[]'::jsonb,
    status              text NOT NULL DEFAULT 'draft',
    based_on_version_id uuid,
    llm_job_id          uuid,
    created_by          text NOT NULL,
    created_at          timestamp with time zone NOT NULL DEFAULT now(),
    reviewed_by         text,
    reviewed_at         timestamp with time zone,
    review_note         text,
    CONSTRAINT supply_content_version_entity_fkey FOREIGN KEY (entity_id) REFERENCES shared.supply_entity (id),
    CONSTRAINT supply_content_version_number_key UNIQUE (entity_id, content_version),
    CONSTRAINT supply_content_version_entity_id_key UNIQUE (entity_id, id),
    CONSTRAINT supply_content_version_numbers_check CHECK (content_version >= 1 AND supply_version >= 1),
    CONSTRAINT supply_content_version_origin_check CHECK (origin IN ('llm', 'human')),
    CONSTRAINT supply_content_version_status_check CHECK (status IN ('draft', 'approved', 'rejected', 'superseded')),
    CONSTRAINT supply_content_version_text_check
        CHECK (length(btrim(description)) > 0 AND cardinality(highlights) <= 5 AND cardinality(good_to_know) <= 3),
    CONSTRAINT supply_content_version_photos_check CHECK (jsonb_typeof(photos) = 'array'),
    CONSTRAINT supply_content_version_review_check
        CHECK (status NOT IN ('approved', 'rejected') OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS supply_content_version_one_approved
    ON shared.supply_content_version (entity_id) WHERE status = 'approved';

COMMENT ON TABLE shared.supply_content_version IS
    'AA-835 (CIS 278): the versions of the customer content of one shared.supply_entity. origin llm (the '
    'supply_content_draft job, llm_job_id) or human (an edit in /admin/supply-content). Content is immutable (an edit '
    'is a new version); status draft -> approved | rejected | superseded, approved -> superseded; one approved per '
    'entity. photos = [{media_id, caption, alt}] with Booking entity_media ids, never a URL.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'shared.supply_entity'::regclass
                                                AND conname = 'supply_entity_published_version_fkey') THEN
        ALTER TABLE shared.supply_entity
            ADD CONSTRAINT supply_entity_published_version_fkey FOREIGN KEY (id, published_version_id)
            REFERENCES shared.supply_content_version (entity_id, id);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION shared.supply_content_version_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status IN ('rejected', 'superseded') AND OLD.created_at < now() - interval '180 days' THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'shared.supply_content_version: only a rejected or superseded version older than 180 days '
                        'may be deleted (AA-835)' USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.entity_id IS DISTINCT FROM OLD.entity_id
       OR NEW.content_version IS DISTINCT FROM OLD.content_version
       OR NEW.supply_version IS DISTINCT FROM OLD.supply_version OR NEW.origin IS DISTINCT FROM OLD.origin
       OR NEW.description IS DISTINCT FROM OLD.description OR NEW.highlights IS DISTINCT FROM OLD.highlights
       OR NEW.good_to_know IS DISTINCT FROM OLD.good_to_know OR NEW.photos IS DISTINCT FROM OLD.photos
       OR NEW.based_on_version_id IS DISTINCT FROM OLD.based_on_version_id
       OR NEW.llm_job_id IS DISTINCT FROM OLD.llm_job_id OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'shared.supply_content_version: the content of a version never changes; an edit is a new '
                        'human version (AA-835)' USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT ((OLD.status = 'draft' AND NEW.status IN ('approved', 'rejected', 'superseded'))
                OR (OLD.status = 'approved' AND NEW.status = 'superseded')) THEN
        RAISE EXCEPTION 'shared.supply_content_version: status % -> % is not allowed (AA-835)', OLD.status, NEW.status
              USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.status = OLD.status AND OLD.status <> 'draft'
       AND (NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
            OR NEW.review_note IS DISTINCT FROM OLD.review_note) THEN
        RAISE EXCEPTION 'shared.supply_content_version: the review of a % version never changes (AA-835)', OLD.status
              USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END
$fn$;

REVOKE ALL ON FUNCTION shared.supply_content_version_guard() FROM PUBLIC;

DROP TRIGGER IF EXISTS supply_content_version_guard ON shared.supply_content_version;
CREATE TRIGGER supply_content_version_guard
    BEFORE UPDATE OR DELETE ON shared.supply_content_version
    FOR EACH ROW EXECUTE FUNCTION shared.supply_content_version_guard();

-- ── 3. The feed inbox (idempotency record) ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.supply_event_inbox (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source               text NOT NULL DEFAULT 'booking',
    contract             text NOT NULL,
    idempotency_key      uuid NOT NULL,
    source_id            text NOT NULL,
    event_type           text NOT NULL,
    supply_version       bigint NOT NULL,
    facts_supply_version bigint,
    feed_seq             bigint NOT NULL,
    outcome              text NOT NULL,
    received_at          timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT supply_event_inbox_key UNIQUE (source, contract, idempotency_key),
    CONSTRAINT supply_event_inbox_source_check CHECK (source = 'booking'),
    CONSTRAINT supply_event_inbox_contract_check CHECK (contract IN ('supply.hotel.v1', 'supply.service.v1')),
    CONSTRAINT supply_event_inbox_event_type_check CHECK (event_type IN ('supply.upsert', 'supply.deactivate')),
    CONSTRAINT supply_event_inbox_outcome_check CHECK (outcome IN ('applied', 'skipped_older', 'missing')),
    CONSTRAINT supply_event_inbox_outcome_version_check
        CHECK ((outcome = 'missing') = (facts_supply_version IS NULL))
);

CREATE INDEX IF NOT EXISTS supply_event_inbox_source_idx ON shared.supply_event_inbox (source_id, received_at DESC);
CREATE INDEX IF NOT EXISTS supply_event_inbox_received_idx ON shared.supply_event_inbox (received_at);

COMMENT ON TABLE shared.supply_event_inbox IS
    'AA-835 (CIS 278): one row per Booking supply outbox event CIS consumed (contracts README rule 3: the '
    'idempotency key is booking.outbox.event_id). outcome applied (facts_supply_version was newer than what CIS held) '
    '| skipped_older (an older or equal version) | missing (the entity is no longer in the Booking facts view). Ids, '
    'versions and the outcome only. Append-only for cis_app.';

-- ── 4. The feed cursor ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.supply_feed_cursor (
    consumer        text PRIMARY KEY,
    last_feed_seq   bigint NOT NULL DEFAULT 0,
    last_pull_at    timestamp with time zone,
    last_success_at timestamp with time zone,
    last_error      text,
    last_error_at   timestamp with time zone,
    CONSTRAINT supply_feed_cursor_consumer_check CHECK (consumer ~ '^[a-z][a-z0-9_]{1,62}$'),
    CONSTRAINT supply_feed_cursor_seq_check CHECK (last_feed_seq >= 0)
);

COMMENT ON TABLE shared.supply_feed_cursor IS
    'AA-835 (CIS 278): the position of each CIS consumer in booking.v_supply_outbox (WHERE feed_seq > last_feed_seq '
    'ORDER BY feed_seq), with the time of the last pull, the last success and the last error (shown on the admin '
    'status board).';

-- ── 5. The Booking photos and their CIS copies ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.supply_media (
    booking_media_id uuid PRIMARY KEY,
    entity_id        uuid NOT NULL,
    usage_rights     boolean NOT NULL DEFAULT false,
    active           boolean NOT NULL DEFAULT true,
    sha256           text NOT NULL,
    content_type     text NOT NULL,
    width            integer,
    height           integer,
    cis_key_1600     text,
    cis_key_600      text,
    url_1600         text,
    url_600          text,
    copied_sha256    text,
    copied_at        timestamp with time zone,
    updated_at       timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT supply_media_entity_fkey FOREIGN KEY (entity_id) REFERENCES shared.supply_entity (id),
    CONSTRAINT supply_media_sha256_check CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT supply_media_content_type_check CHECK (content_type IN ('image/jpeg', 'image/png', 'image/webp')),
    CONSTRAINT supply_media_copy_check
        CHECK ((cis_key_1600 IS NULL AND cis_key_600 IS NULL AND copied_sha256 IS NULL AND copied_at IS NULL
                AND url_1600 IS NULL AND url_600 IS NULL)
               OR (cis_key_1600 LIKE 'photos/supply/%' AND cis_key_600 LIKE 'photos/supply/%'
                   AND copied_sha256 ~ '^[0-9a-f]{64}$' AND copied_at IS NOT NULL)),
    CONSTRAINT supply_media_url_check
        CHECK ((url_1600 IS NULL OR url_1600 LIKE 'https://%') AND (url_600 IS NULL OR url_600 LIKE 'https://%'))
);

CREATE INDEX IF NOT EXISTS supply_media_entity_idx ON shared.supply_media (entity_id);

COMMENT ON TABLE shared.supply_media IS
    'AA-835 (CIS 278): the Booking supplier photos (booking.entity_media ids) of each supply entity as Booking '
    'reports them (usage_rights, sha256), and the CIS copies of the rights-cleared ones: WebP 1600 / 600 under the '
    'bronze photos/supply/ prefix and their CDN URLs, copied_sha256 = the source bytes copied. Only a photo with '
    'usage_rights that is active and copied is ever served (catalog.v_supply_content photo_urls).';

-- ── 6. Stage key and spend budget ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
VALUES
    ('supply_content_writer', 'writer', 'claude', 'sonnet', 'acc3', true, ARRAY[]::text[], NULL, 0, 'migration-278')
ON CONFLICT (stage) DO NOTHING;

INSERT INTO shared.spend_budget (provider, scope, per_run_usd, per_day_usd, hard_stop, updated_by)
VALUES ('bedrock', 'job:supply_content_draft', 0.10, 1.00, true, 'migration-278')
ON CONFLICT (provider, scope) DO NOTHING;

-- ── 7. Grants ──────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON shared.supply_entity, shared.supply_content_version, shared.supply_event_inbox,
              shared.supply_feed_cursor, shared.supply_media FROM PUBLIC;
REVOKE ALL ON shared.supply_entity, shared.supply_content_version, shared.supply_event_inbox,
              shared.supply_feed_cursor, shared.supply_media FROM cis_app, aa_app_user, catalog_owner;
REVOKE ALL ON SEQUENCE shared.supply_event_inbox_id_seq FROM PUBLIC;
REVOKE ALL ON SEQUENCE shared.supply_event_inbox_id_seq FROM cis_app, aa_app_user, catalog_owner;
GRANT SELECT, INSERT, UPDATE ON shared.supply_entity, shared.supply_content_version, shared.supply_feed_cursor,
                                shared.supply_media TO cis_app;
GRANT SELECT, INSERT ON shared.supply_event_inbox TO cis_app;
GRANT SELECT ON shared.supply_entity, shared.supply_content_version, shared.supply_media TO catalog_owner;

-- ── Guard 2 (part A) ───────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    privs text;
    missing text;
BEGIN
    SELECT string_agg(c, ', ') INTO missing FROM unnest(ARRAY[
        'shared.supply_entity:supply_entity_source_key', 'shared.supply_entity:supply_entity_published_check',
        'shared.supply_entity:supply_entity_inactive_check', 'shared.supply_entity:supply_entity_published_version_fkey',
        'shared.supply_content_version:supply_content_version_entity_fkey',
        'shared.supply_content_version:supply_content_version_entity_id_key',
        'shared.supply_content_version:supply_content_version_review_check',
        'shared.supply_event_inbox:supply_event_inbox_key',
        'shared.supply_media:supply_media_copy_check', 'shared.supply_media:supply_media_entity_fkey']) c
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint k
                        WHERE k.conrelid = split_part(c, ':', 1)::regclass AND k.conname = split_part(c, ':', 2)
                          AND k.convalidated);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 278: constraints missing or not validated: %', missing;
    END IF;
    IF to_regclass('shared.supply_content_version_one_approved') IS NULL THEN
        RAISE EXCEPTION 'migration 278: the one-approved-version index is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'shared.supply_content_version'::regclass
                                             AND tgname = 'supply_content_version_guard' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'migration 278: the version guard trigger is missing';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'shared.supply_content_version_guard()'::regprocedure
                                       AND (prosecdef OR proconfig IS NULL
                                            OR NOT proconfig @> ARRAY['search_path=pg_catalog, pg_temp']
                                            OR has_function_privilege('public', oid, 'EXECUTE'))) THEN
        RAISE EXCEPTION 'migration 278: the guard function must be SECURITY INVOKER, pin search_path and give PUBLIC '
                        'no EXECUTE';
    END IF;

    SELECT string_agg(r || ':' || o || ':' || p, ', ' ORDER BY r, o, p) INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r,
               c.relname::text AS o, a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid IN ('shared.supply_entity'::regclass, 'shared.supply_content_version'::regclass,
                         'shared.supply_event_inbox'::regclass, 'shared.supply_feed_cursor'::regclass,
                         'shared.supply_media'::regclass, 'shared.supply_event_inbox_id_seq'::regclass)
           AND (a.grantee = 0 OR a.grantee IN ('cis_app'::regrole, 'aa_app_user'::regrole,
                                               'catalog_owner'::regrole))) x;
    IF privs IS DISTINCT FROM
         'catalog_owner:supply_content_version:SELECT, catalog_owner:supply_entity:SELECT, '
         'catalog_owner:supply_media:SELECT, '
         'cis_app:supply_content_version:INSERT, cis_app:supply_content_version:SELECT, '
         'cis_app:supply_content_version:UPDATE, '
         'cis_app:supply_entity:INSERT, cis_app:supply_entity:SELECT, cis_app:supply_entity:UPDATE, '
         'cis_app:supply_event_inbox:INSERT, cis_app:supply_event_inbox:SELECT, '
         'cis_app:supply_feed_cursor:INSERT, cis_app:supply_feed_cursor:SELECT, cis_app:supply_feed_cursor:UPDATE, '
         'cis_app:supply_media:INSERT, cis_app:supply_media:SELECT, cis_app:supply_media:UPDATE' THEN
        RAISE EXCEPTION 'migration 278: unexpected privileges on the supply tables: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute a
                WHERE a.attacl IS NOT NULL
                  AND a.attrelid IN ('shared.supply_entity'::regclass, 'shared.supply_content_version'::regclass,
                                     'shared.supply_event_inbox'::regclass, 'shared.supply_feed_cursor'::regclass,
                                     'shared.supply_media'::regclass)) THEN
        RAISE EXCEPTION 'migration 278: column-level grants on the supply tables';
    END IF;
END $$;

-- ── Part B: catalog.v_supply_content (X1 S22 catalog recipe) ───────────────────────────────────────────────────────
DO $$
BEGIN
    IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog') IS DISTINCT FROM 'cis_owner' THEN
        RAISE EXCEPTION 'migration 278: schema catalog is not owned by cis_owner (apply 245 first)';
    END IF;
    IF to_regrole('catalog_owner') IS NULL OR to_regrole('booking') IS NULL THEN
        RAISE EXCEPTION 'migration 278: roles catalog_owner and booking must exist (contracts rule 5)';
    END IF;
    IF NOT has_schema_privilege('catalog_owner', 'shared', 'USAGE')
       OR NOT has_table_privilege('catalog_owner', 'shared.supply_entity', 'SELECT')
       OR NOT has_table_privilege('catalog_owner', 'shared.supply_content_version', 'SELECT')
       OR NOT has_table_privilege('catalog_owner', 'shared.supply_media', 'SELECT') THEN
        RAISE EXCEPTION 'migration 278: catalog_owner cannot read schema shared or the supply tables';
    END IF;
    IF to_regclass('catalog.v_supply_content') IS NOT NULL
       AND (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = to_regclass('catalog.v_supply_content'))
           <> 'catalog_owner' THEN
        RAISE EXCEPTION 'migration 278: catalog.v_supply_content exists and is not catalog_owner''s';
    END IF;
END $$;

GRANT CREATE ON SCHEMA catalog TO catalog_owner;
SET LOCAL ROLE catalog_owner;

CREATE OR REPLACE VIEW catalog.v_supply_content WITH (security_barrier = true) AS
SELECT e.source_system,
       e.source_id,
       e.entity_type,
       e.content_status,
       COALESCE(p.content_version, n.content_version) AS content_version,
       p.description,
       p.highlights,
       p.good_to_know,
       CASE WHEN p.id IS NOT NULL THEN COALESCE(ph.urls, ARRAY[]::text[]) END AS photo_urls,
       '/admin/supply-content/' || e.id::text AS edit_url,
       p.reviewed_at AS published_at
  FROM shared.supply_entity e
  LEFT JOIN shared.supply_content_version p
         ON e.content_status = 'published'
        AND e.active
        AND p.entity_id = e.id
        AND p.id = e.published_version_id
        AND p.status = 'approved'
  LEFT JOIN LATERAL (
        SELECT max(v.content_version) AS content_version
          FROM shared.supply_content_version v
         WHERE v.entity_id = e.id
       ) n ON true
  LEFT JOIN LATERAL (
        SELECT array_agg(m.url_1600 ORDER BY x.ord) AS urls
          FROM jsonb_array_elements(p.photos) WITH ORDINALITY AS x(photo, ord)
          JOIN shared.supply_media m ON m.booking_media_id::text = x.photo ->> 'media_id'
         WHERE m.entity_id = e.id
           AND m.usage_rights
           AND m.active
           AND m.url_1600 IS NOT NULL
       ) ph ON true;

COMMENT ON VIEW catalog.v_supply_content IS
    'AA-835 (CIS 278, root ADR 0004a decision 5): the AA-written customer content of each Booking hotel / service CIS '
    'knows, for Booking (role booking only). Key (source_system, source_id = the Booking id). description, '
    'highlights, good_to_know and photo_urls are non-NULL only while content_status = published (approved version, '
    'active entity); draft, in_review, stale and unpublished rows carry NULL text. photo_urls = CDN URLs of the '
    'published photos whose Booking media has usage_rights. edit_url = the CIS admin path of the entity (prefix the '
    'CIS admin origin). Columns are append-only (Booking feature-detects them).';

REVOKE ALL ON catalog.v_supply_content FROM PUBLIC;
GRANT SELECT ON catalog.v_supply_content TO booking;

-- ── Closing checks as catalog_owner ────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    cols text;
BEGIN
    SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a WHERE a.attrelid = 'catalog.v_supply_content'::regclass AND a.attnum > 0
       AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM 'source_system text, source_id text, entity_type text, content_status text, '
                             'content_version integer, description text, highlights text[], good_to_know text[], '
                             'photo_urls text[], edit_url text, published_at timestamp with time zone' THEN
        RAISE EXCEPTION 'migration 278: catalog.v_supply_content has unexpected columns: %', cols;
    END IF;
    IF EXISTS (SELECT 1 FROM catalog.v_supply_content
                WHERE content_status <> 'published'
                  AND (description IS NOT NULL OR highlights IS NOT NULL OR photo_urls IS NOT NULL)) THEN
        RAISE EXCEPTION 'migration 278: catalog.v_supply_content serves text for a row that is not published';
    END IF;
    RAISE NOTICE 'migration 278: catalog.v_supply_content rows % (published %)',
        (SELECT count(*) FROM catalog.v_supply_content),
        (SELECT count(*) FROM catalog.v_supply_content WHERE description IS NOT NULL);
END $$;

SET LOCAL ROLE cis_owner;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;

-- ── Guards on the result (as cis_owner) ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    privs text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE oid = 'catalog.v_supply_content'::regclass
                                        AND (pg_get_userbyid(relowner) <> 'catalog_owner'
                                             OR NOT COALESCE(reloptions, '{}') @> ARRAY['security_barrier=true'])) THEN
        RAISE EXCEPTION 'migration 278: catalog.v_supply_content must be catalog_owner''s and security_barrier';
    END IF;
    SELECT string_agg(r || ':' || p, ', ' ORDER BY r, p) INTO privs FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS r, a.privilege_type AS p
          FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
         WHERE c.oid = 'catalog.v_supply_content'::regclass AND a.grantee <> c.relowner) x;
    IF privs IS DISTINCT FROM 'booking:SELECT' THEN
        RAISE EXCEPTION 'migration 278: unexpected grants on catalog.v_supply_content: %', privs;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attacl IS NOT NULL
                                            AND attrelid = 'catalog.v_supply_content'::regclass) THEN
        RAISE EXCEPTION 'migration 278: column grants on catalog.v_supply_content';
    END IF;
    IF has_schema_privilege('catalog_owner', 'catalog', 'CREATE') THEN
        RAISE EXCEPTION 'migration 278: catalog_owner still has CREATE on schema catalog';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
                WHERE c.oid IN ('shared.supply_entity'::regclass, 'shared.supply_content_version'::regclass,
                                'shared.supply_event_inbox'::regclass, 'shared.supply_feed_cursor'::regclass,
                                'shared.supply_media'::regclass, 'catalog.v_supply_content'::regclass)
                  AND a.grantee = 'aa_app_user'::regrole) THEN
        RAISE EXCEPTION 'migration 278: aa_app_user holds a privilege on a supply table or the view (AA-859)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('278', now(), 'AA-835: CIS supply content (shared.supply_* consumer + review tables, supply_content_writer '
                      'stage) and the Booking read-back view catalog.v_supply_content')
ON CONFLICT (version) DO NOTHING;

COMMIT;
