-- Migration crm-006: AA-937 (partner CRM, design v3 card CRM-09) — F1 / F2 complete: the rest of the identity vault
-- (relationships with their inverse, health codes, documents), the full F2 profile and its history, the age band at
-- departure, the list-view audit ids, and the F2 views with the first NOLOGIN reader grants.
--
-- Owner: AA-Partner (api/migrations/006_crm_f1_f2_complete.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-006.
--
-- Why. Design v3 §3.3 groups B and C, §4.3 (the F1 / F2 split and its honest threat model, Fix A1), §4.4 (list views,
-- Fix B15), §4.1 (documents under the tenant docs DEK, Fix A7), lane §2.3–2.4 (column lists), R7 (relationships with
-- an automatic inverse), R32 (age band at departure, recomputed only when the DOB or the departure date changes).
-- The card's R test: crm_ai_reader, crm_insights and crm_support_reader selecting crm.trip_traveler -> 42501.
--
-- What:
--   1. crm.audit_event.object_ids: the ids a list view showed (design §4.4: "one audit_event action=list_view with
--      the object ids and the field name"). Ids only, at most 200 per event.
--   2. crm.traveler_profile (F2): the remaining bands and codes of lane §2.4 (fitness, trek experience, altitude,
--      lodging tier, interests, must-do / must-avoid codes, occasion, dietary / mobility flags mirrored from the F1
--      health codes, planning bands). Every value is a code from a fixed list; free text never goes here (it is an
--      F1-encrypted note).
--   3. crm.trip_party.age_band_at_departure: the fixed band list (R32). Written by app.travellers.age_bands when the
--      traveller's DOB or the trip's start date changes, never by an unrelated edit.
--   4. crm.profile_history (F2): one row per AA trip a profile reached (Booking events, CRM-29b writes it), no
--      identity.
--   5. crm.traveler_relation (F1, ids only): spouse / partner / parent / child / sibling / friend / referrer /
--      referred. A trigger writes the inverse row (R7 "automatic inverse"), mirrors trash and hard delete to it, and
--      keeps from / to / kind fixed. One live relation per ordered pair, one live referrer per traveller.
--   6. crm.traveler_health (F1): the health codes, encrypted under the vault DEK (health_flags_enc), only with a
--      consent row purpose health_data = true of the same traveller (trigger). Mirrored as F2 flags by the app.
--   7. crm.document (F1): agency documents. The object is encrypted by the app with the tenant docs DEK (AAD =
--      tenant, table document, column content, document id) before it is stored in the documents bucket (SSE-KMS as
--      a second layer, AA-CIS-Infra crm_storage.tf); the file name is encrypted too; a passport scan is write-only
--      and never visible to travellers.
--   7b. Same-agency keys: UNIQUE (tenant_id, id) on crm.traveler, crm.trip and crm.traveler_profile, and every
--      new reference to them is a composite (tenant_id, id) foreign key. Referential checks bypass FORCE RLS, so a
--      single-column key would let one agency's row point at another agency's traveller or trip; the composite key
--      makes the database refuse it. The document key must be exactly tenants/<its tenant>/documents/<its id>.
--   8. F2 views for the NOLOGIN readers, owned by crm_owner (FORCE RLS binds the owner too, so they show the agency
--      of app.tenant_id only): v_ai_traveler_profile, v_ai_trip_party, v_ai_trip_context (crm_ai_reader) and
--      v_insight_fact (crm_insights: no token, no trip id). crm_support_reader stays without grants: its non-F1
--      table grants come with the owner-granted support layer (CRM-13b, AA-971; crm-005's guard refuses reader
--      grants on its tables when it is re-run). No reader gets anything on an F1 table, crm.trip_traveler included
--      (Fix A1), and crm_ai_reader / crm_insights get no base table at all, only their views.
--   Threat model (design §4.3, stated honestly): the split protects against the three readers. It does not protect
--   against crm_app and the RDS master: the lead of a trip joins F2 to identity through trip_id.
--
-- Order: after crm-005 (AA-936); Guard 0 refuses to run before it is registered.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP …
-- IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before AA-937
-- deploys nothing reads these objects.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-005 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-006: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-005') THEN
        RAISE EXCEPTION 'crm-006: crm-005 is not registered (Slice 1, AA-936, lands first)';
    END IF;
END $$;

-- ── 1. crm.audit_event.object_ids (list views, design §4.4) ──────────────────────────────────────
ALTER TABLE crm.audit_event ADD COLUMN IF NOT EXISTS object_ids TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE crm.audit_event DROP CONSTRAINT IF EXISTS audit_event_object_ids_chk;
ALTER TABLE crm.audit_event ADD CONSTRAINT audit_event_object_ids_chk CHECK (
    cardinality(object_ids) <= 200
    AND array_to_string(object_ids, ',', '!') ~ '^([A-Za-z0-9:_-]{1,80}(,|$))*$'
);
COMMENT ON COLUMN crm.audit_event.object_ids IS 'AA-937 (crm-006): the ids a list view showed (action list_view, design §4.4), at most 200; ids only, never values';

-- ── 2. crm.traveler_profile (F2): the rest of lane §2.4 ──────────────────────────────────────────
ALTER TABLE crm.traveler_profile
    ADD COLUMN IF NOT EXISTS residence_country  TEXT,
    ADD COLUMN IF NOT EXISTS fitness_band       TEXT,
    ADD COLUMN IF NOT EXISTS trek_experience    TEXT,
    ADD COLUMN IF NOT EXISTS altitude_ok        BOOLEAN,
    ADD COLUMN IF NOT EXISTS accommodation_tier TEXT,
    ADD COLUMN IF NOT EXISTS interests          TEXT[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS must_do_codes      TEXT[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS must_avoid_codes   TEXT[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS occasion           TEXT,
    ADD COLUMN IF NOT EXISTS dietary_flags      TEXT[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS mobility_flags     TEXT[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS budget_flex        TEXT,
    ADD COLUMN IF NOT EXISTS decision_maker     TEXT,
    ADD COLUMN IF NOT EXISTS booking_timeline   TEXT,
    ADD COLUMN IF NOT EXISTS competing_quotes   BOOLEAN;

ALTER TABLE crm.traveler_profile DROP CONSTRAINT IF EXISTS traveler_profile_bands_chk;
ALTER TABLE crm.traveler_profile ADD CONSTRAINT traveler_profile_bands_chk CHECK (
    (residence_country IS NULL OR residence_country ~ '^[A-Z]{2}$')
    AND (fitness_band IS NULL OR fitness_band IN ('up_to_2h', '2_4h', '4_6h', 'over_6h'))
    AND (trek_experience IS NULL OR trek_experience IN ('none', 'some', 'experienced'))
    AND (accommodation_tier IS NULL OR accommodation_tier IN ('budget', 'comfort', 'premium', 'luxury'))
    AND (occasion IS NULL OR occasion IN (
        'none', 'honeymoon', 'anniversary', 'birthday', 'family_reunion', 'graduation', 'retirement', 'other'
    ))
    AND (budget_flex IS NULL OR budget_flex IN ('fixed', 'some', 'flexible'))
    AND (decision_maker IS NULL OR decision_maker IN ('self', 'partner', 'family', 'group', 'company'))
    AND (booking_timeline IS NULL OR booking_timeline IN (
        'ready_now', 'within_month', 'within_3_months', 'later', 'just_looking'
    ))
);
ALTER TABLE crm.traveler_profile DROP CONSTRAINT IF EXISTS traveler_profile_codes_chk;
ALTER TABLE crm.traveler_profile ADD CONSTRAINT traveler_profile_codes_chk CHECK (
    cardinality(interests) <= 20 AND array_to_string(interests, ',', '!') ~ '^([a-z][a-z0-9_]{1,39}(,|$))*$'
    AND cardinality(must_do_codes) <= 20
    AND array_to_string(must_do_codes, ',', '!') ~ '^([a-z][a-z0-9_]{1,39}(,|$))*$'
    AND cardinality(must_avoid_codes) <= 20
    AND array_to_string(must_avoid_codes, ',', '!') ~ '^([a-z][a-z0-9_]{1,39}(,|$))*$'
    AND dietary_flags <@ ARRAY['vegetarian', 'vegan', 'halal', 'kosher', 'gluten_free', 'lactose_free', 'nut_allergy',
                               'shellfish_allergy', 'other_allergy']::text[]
    AND array_position(dietary_flags, NULL) IS NULL
    AND mobility_flags <@ ARRAY['limited_walking', 'wheelchair', 'no_stairs', 'no_long_drives', 'other']::text[]
    AND array_position(mobility_flags, NULL) IS NULL
);
COMMENT ON TABLE crm.traveler_profile IS 'AA-936 (crm-005), completed by AA-937 (crm-006): F2 pseudonymous profile (design v3 §4.3, lane §2.4): a random traveller_token, bands and codes only, no identity column and no FK to crm.traveler (the only link is the encrypted crm.traveler.profile_token_enc). dietary_flags / mobility_flags mirror the F1 health codes (crm.traveler_health). crm_ai_reader sees it through crm.v_ai_traveler_profile only.';
COMMENT ON COLUMN crm.traveler_profile.residence_country IS 'ISO 3166-1 alpha-2 country of residence (a band, not an address)';
COMMENT ON COLUMN crm.traveler_profile.dietary_flags IS 'codes mirrored from crm.traveler_health (F1, consent health_data); never free text';
COMMENT ON COLUMN crm.traveler_profile.mobility_flags IS 'codes mirrored from crm.traveler_health (F1, consent health_data); never free text';

-- ── 3. crm.trip_party.age_band_at_departure: the fixed band list (R32) ───────────────────────────
ALTER TABLE crm.trip_party DROP CONSTRAINT IF EXISTS trip_party_age_band_list_chk;
ALTER TABLE crm.trip_party ADD CONSTRAINT trip_party_age_band_list_chk CHECK (
    age_band_at_departure IS NULL OR age_band_at_departure IN (
        'under_2', '2_11', '12_17', '18_24', '25_34', '35_44', '45_54', '55_64', '65_74', '75_plus'
    )
);
CREATE INDEX IF NOT EXISTS trip_party_token_idx ON crm.trip_party (traveler_token);
COMMENT ON COLUMN crm.trip_party.age_band_at_departure IS 'AA-937 (crm-006, R32): the traveller''s age band on the trip''s start date, from the F1 DOB; recomputed only when that DOB or the start date changes (app.travellers.age_bands), one audit event per recompute';

-- ── 3b. Same-agency keys for the composite foreign keys below (7b) ───────────────────────────────
-- Referential checks bypass FORCE RLS: a key on (tenant_id, id) makes a cross-agency reference impossible.
DO $$
DECLARE
    spec text[];
BEGIN
    FOREACH spec SLICE 1 IN ARRAY ARRAY[
        ARRAY['traveler', 'traveler_tenant_id_uq', 'traveler_id'],
        ARRAY['trip', 'trip_tenant_id_uq', 'trip_id'],
        ARRAY['traveler_profile', 'traveler_profile_tenant_token_uq', 'traveler_token']
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                        WHERE conrelid = format('crm.%I', spec[1])::regclass AND conname = spec[2]) THEN
            EXECUTE format('ALTER TABLE crm.%I ADD CONSTRAINT %I UNIQUE (tenant_id, %I)', spec[1], spec[2], spec[3]);
        END IF;
    END LOOP;
END $$;

-- ── 4. crm.profile_history (F2) ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.profile_history (
    history_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    traveler_token   UUID NOT NULL,
    aa_departure_id  TEXT,
    aa_product_key   TEXT,
    stage_reached    TEXT NOT NULL,
    year_month       DATE NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT profile_history_ids_chk CHECK (
        (aa_departure_id IS NULL OR aa_departure_id ~ '^[A-Za-z0-9:_-]{1,80}$')
        AND (aa_product_key IS NULL OR aa_product_key ~ '^[A-Za-z0-9:_./-]{1,120}$')
    ),
    CONSTRAINT profile_history_stage_chk CHECK (stage_reached IN (
        'inquiry', 'qualifying', 'proposal', 'booked', 'pre_departure', 'travelling', 'completed', 'lost', 'cancelled'
    )),
    CONSTRAINT profile_history_profile_fk FOREIGN KEY (tenant_id, traveler_token)
        REFERENCES crm.traveler_profile (tenant_id, traveler_token),
    CONSTRAINT profile_history_month_chk CHECK (year_month = date_trunc('month', year_month)::date),
    CONSTRAINT profile_history_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS profile_history_token_idx ON crm.profile_history (traveler_token, year_month DESC);
COMMENT ON TABLE crm.profile_history IS 'AA-937 (crm-006): F2 "AA trip history" of a profile (lane §2.4, M:F2, M:17): the AA departure and product a traveller_token reached, by month. No identity; written from Booking events (CRM-29b, R36 "ready to travel again"). Base template, FORCE RLS.';

-- ── 5. crm.traveler_relation (F1, ids only; R7) ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.traveler_relation (
    relation_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    from_traveler_id UUID NOT NULL,
    to_traveler_id   UUID NOT NULL,
    kind             TEXT NOT NULL,
    inverse_id       UUID REFERENCES crm.traveler_relation (relation_id) ON DELETE SET NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT traveler_relation_from_fk FOREIGN KEY (tenant_id, from_traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id),
    CONSTRAINT traveler_relation_to_fk FOREIGN KEY (tenant_id, to_traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id),
    CONSTRAINT traveler_relation_kind_chk CHECK (kind IN (
        'spouse', 'partner', 'parent', 'child', 'sibling', 'friend', 'referrer', 'referred'
    )),
    CONSTRAINT traveler_relation_self_chk CHECK (from_traveler_id <> to_traveler_id),
    CONSTRAINT traveler_relation_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS traveler_relation_pair_uq ON crm.traveler_relation (from_traveler_id, to_traveler_id)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS traveler_relation_one_referrer_uq ON crm.traveler_relation (from_traveler_id)
    WHERE kind = 'referrer' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS traveler_relation_to_idx ON crm.traveler_relation (to_traveler_id);
COMMENT ON TABLE crm.traveler_relation IS 'AA-937 (crm-006): relationships between an agency''s travellers (R7), ids and a kind only. A row (from A, to B, kind K) reads "B is A''s K"; the trigger crm.traveler_relation_pair() writes the inverse (from B, to A, kind crm.relation_inverse(K)) in the same statement, mirrors trash and hard delete to it, and keeps from / to / kind fixed. F1 group B: no NOLOGIN reader is granted it.';
COMMENT ON COLUMN crm.traveler_relation.kind IS 'spouse | partner | parent | child | sibling | friend | referrer (B referred A) | referred (A referred B)';

CREATE OR REPLACE FUNCTION crm.relation_inverse(kind text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    SET search_path = pg_catalog
AS $$
    SELECT CASE kind
        WHEN 'parent' THEN 'child'
        WHEN 'child' THEN 'parent'
        WHEN 'referrer' THEN 'referred'
        WHEN 'referred' THEN 'referrer'
        ELSE kind
    END
$$;
REVOKE ALL ON FUNCTION crm.relation_inverse(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm.relation_inverse(text) TO crm_app;

CREATE OR REPLACE FUNCTION crm.traveler_relation_pair() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.from_traveler_id IS DISTINCT FROM OLD.from_traveler_id
       OR NEW.to_traveler_id IS DISTINCT FROM OLD.to_traveler_id
       OR NEW.kind IS DISTINCT FROM OLD.kind
       OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
        RAISE EXCEPTION 'crm: a relationship keeps its travellers and kind; remove it and add a new one'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.traveler_relation_pair() FROM PUBLIC;

CREATE OR REPLACE FUNCTION crm.traveler_relation_mirror() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
DECLARE
    inverse uuid;
BEGIN
    -- Only the statement the app runs mirrors; the mirrored write itself does not mirror back.
    IF pg_catalog.pg_trigger_depth() > 1 THEN
        RETURN NULL;
    END IF;
    IF TG_OP = 'INSERT' THEN
        INSERT INTO crm.traveler_relation (from_traveler_id, to_traveler_id, kind, inverse_id)
        VALUES (NEW.to_traveler_id, NEW.from_traveler_id, crm.relation_inverse(NEW.kind), NEW.relation_id)
        RETURNING relation_id INTO inverse;
        UPDATE crm.traveler_relation SET inverse_id = inverse WHERE relation_id = NEW.relation_id;
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.deleted_at IS DISTINCT FROM OLD.deleted_at AND NEW.inverse_id IS NOT NULL THEN
            UPDATE crm.traveler_relation
               SET deleted_at = NEW.deleted_at, deleted_by = NEW.deleted_by, purge_after = NEW.purge_after
             WHERE relation_id = NEW.inverse_id;
        END IF;
    ELSIF TG_OP = 'DELETE' THEN
        IF OLD.inverse_id IS NOT NULL THEN
            DELETE FROM crm.traveler_relation WHERE relation_id = OLD.inverse_id;
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION crm.traveler_relation_mirror() FROM PUBLIC;

CREATE OR REPLACE TRIGGER traveler_relation_fixed
    BEFORE UPDATE ON crm.traveler_relation
    FOR EACH ROW EXECUTE FUNCTION crm.traveler_relation_pair();
CREATE OR REPLACE TRIGGER traveler_relation_mirror
    AFTER INSERT OR UPDATE OF deleted_at OR DELETE ON crm.traveler_relation
    FOR EACH ROW EXECUTE FUNCTION crm.traveler_relation_mirror();

-- ── 6. crm.traveler_health (F1) ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.traveler_health (
    health_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    traveler_id      UUID NOT NULL,
    health_flags_enc BYTEA NOT NULL,
    consent_id       UUID NOT NULL REFERENCES crm.consent (consent_id),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT traveler_health_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id),
    CONSTRAINT traveler_health_enc_chk CHECK (octet_length(health_flags_enc) >= 30),
    CONSTRAINT traveler_health_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS traveler_health_traveler_uq ON crm.traveler_health (traveler_id)
    WHERE deleted_at IS NULL;
COMMENT ON TABLE crm.traveler_health IS 'AA-937 (crm-006): a traveller''s health codes (dietary, mobility, medical), F1 group B (lane §2.3). health_flags_enc is AES-256-GCM under the vault DEK, codes only (never free text). A row exists only with a consent row purpose health_data = true of the same traveller (trigger crm.traveler_health_consent()); dietary and mobility codes are mirrored to crm.traveler_profile. No NOLOGIN reader is granted it.';
COMMENT ON COLUMN crm.traveler_health.health_flags_enc IS 'pii:health; encrypted (vault DEK) JSON of codes';

CREATE OR REPLACE FUNCTION crm.traveler_health_consent() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM crm.consent c
         WHERE c.consent_id = NEW.consent_id AND c.traveler_id = NEW.traveler_id
           AND c.purpose = 'health_data' AND c.value
    ) THEN
        RAISE EXCEPTION 'crm: health codes need a health_data consent of the same traveller'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.traveler_health_consent() FROM PUBLIC;
CREATE OR REPLACE TRIGGER traveler_health_consent
    BEFORE INSERT OR UPDATE OF consent_id, traveler_id ON crm.traveler_health
    FOR EACH ROW EXECUTE FUNCTION crm.traveler_health_consent();

-- ── 7. crm.document (F1) ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.document (
    document_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                         REFERENCES crm.tenant (tenant_id),
    trip_id              UUID,
    traveler_id          UUID,
    kind                 TEXT NOT NULL,
    s3_key               TEXT NOT NULL,
    sha256               BYTEA NOT NULL,
    size_bytes           BIGINT NOT NULL,
    content_type         TEXT NOT NULL,
    filename_enc         BYTEA NOT NULL,
    visible_to_travelers BOOLEAN NOT NULL DEFAULT false,
    write_only           BOOLEAN NOT NULL DEFAULT false,
    uploaded_by_kind     TEXT NOT NULL DEFAULT 'member',
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ,
    deleted_by           TEXT,
    purge_after          TIMESTAMPTZ,
    CONSTRAINT document_s3_key_uq UNIQUE (s3_key),
    -- A NULL subject column skips its key (MATCH SIMPLE); document_subject_chk requires one of the two.
    CONSTRAINT document_trip_fk FOREIGN KEY (tenant_id, trip_id) REFERENCES crm.trip (tenant_id, trip_id),
    CONSTRAINT document_traveler_fk FOREIGN KEY (tenant_id, traveler_id)
        REFERENCES crm.traveler (tenant_id, traveler_id),
    CONSTRAINT document_subject_chk CHECK (trip_id IS NOT NULL OR traveler_id IS NOT NULL),
    CONSTRAINT document_kind_chk CHECK (kind IN (
        'passport_scan', 'waiver_pdf', 'terms_pdf', 'ticket', 'voucher', 'invoice_pdf', 'supplier_confirmation', 'other'
    )),
    -- The object key names the row's own agency and document only: no file name, no traveller, never another
    -- agency's prefix (the task role's grant covers tenants/*/documents/*, so this is the structural binding).
    CONSTRAINT document_s3_key_chk CHECK (
        s3_key = 'tenants/' || tenant_id::text || '/documents/' || document_id::text
    ),
    CONSTRAINT document_sha256_chk CHECK (octet_length(sha256) = 32),
    CONSTRAINT document_size_chk CHECK (size_bytes BETWEEN 1 AND 10485760),
    CONSTRAINT document_content_type_chk CHECK (content_type IN (
        'application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'
    )),
    CONSTRAINT document_filename_chk CHECK (octet_length(filename_enc) >= 30),
    -- A passport scan is write-only (design §3.3 group B) and a write-only document is never shown to travellers.
    CONSTRAINT document_write_only_chk CHECK (
        (kind <> 'passport_scan' OR write_only) AND NOT (write_only AND visible_to_travelers)
    ),
    CONSTRAINT document_uploader_chk CHECK (uploaded_by_kind IN ('member', 'traveler', 'aa_booking')),
    CONSTRAINT document_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS document_traveler_idx ON crm.document (traveler_id) WHERE traveler_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS document_trip_idx ON crm.document (trip_id) WHERE trip_id IS NOT NULL;
COMMENT ON TABLE crm.document IS 'AA-937 (crm-006): agency documents of a trip or traveller (F1 group B, design §4.1 Fix A7). The object in the documents bucket is AES-256-GCM under the tenant docs DEK (AAD = tenant, document, content, document id), then SSE-KMS as a second layer; sha256 is the digest of that stored object. Passport scans are write-only; visible_to_travelers drives the client portal (CRM-24a). No NOLOGIN reader is granted it.';
COMMENT ON COLUMN crm.document.filename_enc IS 'pii:free_text; the uploaded file name, encrypted (vault DEK)';
COMMENT ON COLUMN crm.document.s3_key IS 'exactly tenants/<this row''s tenant id>/documents/<this row''s document id>: no name, no traveller, no other agency';

-- ── RLS + triggers on the new tenant tables ──────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['profile_history', 'traveler_relation', 'traveler_health', 'document'] LOOP
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
END $$;

-- ── 8. F2 views and the NOLOGIN reader grants ────────────────────────────────────────────────────
-- Owned by crm_owner and run with its rights (not security_invoker): the readers get the views, never the base
-- tables. FORCE RLS binds crm_owner and every tenant policy names it, so a view shows the rows of app.tenant_id only
-- (set by tenant_tx() before SET LOCAL ROLE); with no tenant set it shows nothing.
CREATE OR REPLACE VIEW crm.v_ai_traveler_profile WITH (security_barrier = true) AS
SELECT p.traveler_token, p.residence_country, p.budget_band, p.pace, p.group_pref, p.fitness_band, p.trek_experience,
       p.altitude_ok, p.accommodation_tier, p.interests, p.must_do_codes, p.must_avoid_codes, p.occasion,
       p.dietary_flags, p.mobility_flags, p.budget_flex, p.decision_maker, p.booking_timeline, p.competing_quotes,
       p.repeat_count, p.stage2_completeness
  FROM crm.traveler_profile p
 WHERE p.deleted_at IS NULL;
COMMENT ON VIEW crm.v_ai_traveler_profile IS 'AA-937 (crm-006): F2 profiles for crm_ai_reader (design §4.3, lane §5.3): bands and codes, no identity, no consent, no marketing flag.';

CREATE OR REPLACE VIEW crm.v_ai_trip_party WITH (security_barrier = true) AS
SELECT tp.trip_id, tp.traveler_token, tp.role, tp.age_band_at_departure
  FROM crm.trip_party tp
 WHERE tp.deleted_at IS NULL;
COMMENT ON VIEW crm.v_ai_trip_party IS 'AA-937 (crm-006): the F2 party of a trip for crm_ai_reader: the only party link AI views see (crm.trip_traveler is never granted, Fix A1).';

CREATE OR REPLACE VIEW crm.v_ai_trip_context WITH (security_barrier = true) AS
SELECT t.trip_id, t.stage, t.waiting_on, t.month, t.start_date, t.end_date, t.nights, t.date_flex_days,
       t.destinations, t.party_adults, t.party_child_ages, t.party_type, t.budget_band, t.trip_style
  FROM crm.trip t
 WHERE t.deleted_at IS NULL;
COMMENT ON VIEW crm.v_ai_trip_context IS 'AA-937 (crm-006): trip bands for crm_ai_reader (lane §5.3 v_ai_trip_context; CRM-33 adds days and options): no title, no owner, no lead source, no free text.';

CREATE OR REPLACE VIEW crm.v_insight_fact WITH (security_barrier = true) AS
SELECT t.tenant_id,
       coalesce(date_trunc('month', t.start_date)::date, t.month) AS month,
       d.destination,
       t.budget_band,
       (SELECT tp.age_band_at_departure FROM crm.trip_party tp
         WHERE tp.trip_id = t.trip_id AND tp.role = 'lead' AND tp.deleted_at IS NULL LIMIT 1) AS age_band,
       t.party_adults + cardinality(t.party_child_ages) AS party_size,
       t.stage AS stage_reached,
       t.lost_reason_code
  FROM crm.trip t
  CROSS JOIN LATERAL unnest(CASE WHEN cardinality(t.destinations) = 0 THEN ARRAY[NULL::text] ELSE t.destinations END)
       AS d(destination)
 WHERE t.deleted_at IS NULL;
COMMENT ON VIEW crm.v_insight_fact IS 'AA-937 (crm-006): the insight fact for crm_insights (lane §2.10, M:17): one row per trip and destination with bands and codes only; no token, no trip id. CRM-34 aggregates it (n >= 10 and >= 3 agencies) into crm.insight_aggregate.';

-- The views are read-only for everyone; crm_app keeps SELECT (default privileges gave it DML, revoked here).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON crm.v_ai_traveler_profile, crm.v_ai_trip_party, crm.v_ai_trip_context,
    crm.v_insight_fact FROM crm_app;
GRANT SELECT ON crm.v_ai_traveler_profile, crm.v_ai_trip_party, crm.v_ai_trip_context TO crm_ai_reader;
GRANT SELECT ON crm.v_insight_fact TO crm_insights;

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
    p text;
    v text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.profile_history', 'crm.traveler_relation', 'crm.traveler_health', 'crm.document'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-006: % must have ENABLE + FORCE row level security', t;
        END IF;
    END LOOP;
    -- 7b: every new reference to a traveller, trip or profile is a same-agency (tenant_id, id) key.
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con
                WHERE con.contype = 'f'
                  AND con.conrelid IN ('crm.profile_history'::regclass, 'crm.traveler_relation'::regclass,
                                       'crm.traveler_health'::regclass, 'crm.document'::regclass)
                  AND con.confrelid IN ('crm.traveler'::regclass, 'crm.trip'::regclass,
                                        'crm.traveler_profile'::regclass)
                  AND cardinality(con.conkey) <> 2) THEN
        RAISE EXCEPTION 'crm-006: a new reference to a traveller, trip or profile is not a (tenant_id, id) key';
    END IF;
    -- Fix A1 / design §4.3: no NOLOGIN reader reaches an F1 table, crm.trip_traveler included.
    FOREACH t IN ARRAY ARRAY['crm.traveler', 'crm.traveler_health', 'crm.traveler_relation', 'crm.document',
                             'crm.trip_traveler', 'crm.note', 'crm.consent', 'crm.form_submission', 'crm.tenant_key',
                             'crm.integration_credential', 'crm.member'] LOOP
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'] LOOP
                IF pg_catalog.has_table_privilege(r, t, p) THEN
                    RAISE EXCEPTION 'crm-006: % may % on F1 table % (design §4.3)', r, p, t;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    -- crm_ai_reader and crm_insights read views only: no privilege on any base table of schema crm.
    FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights'] LOOP
        FOR t IN SELECT c.oid::regclass::text FROM pg_catalog.pg_class c
                  WHERE c.relnamespace = 'crm'::regnamespace AND c.relkind IN ('r', 'p') LOOP
            IF pg_catalog.has_table_privilege(r, t, 'SELECT') OR pg_catalog.has_table_privilege(r, t, 'INSERT')
               OR pg_catalog.has_table_privilege(r, t, 'UPDATE') OR pg_catalog.has_table_privilege(r, t, 'DELETE') THEN
                RAISE EXCEPTION 'crm-006: % has a privilege on base table % (views only)', r, t;
            END IF;
        END LOOP;
    END LOOP;
    -- The reader views carry no ciphertext, index, identity id or title column.
    FOREACH v IN ARRAY ARRAY['crm.v_ai_traveler_profile', 'crm.v_ai_trip_party', 'crm.v_ai_trip_context',
                             'crm.v_insight_fact'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                    WHERE a.attrelid = v::regclass AND a.attnum > 0 AND NOT a.attisdropped
                      AND (a.attname ~ '(_enc|_bidx)$' OR a.attname IN ('traveler_id', 'title', 'owner_member_id',
                                                                         'lead_source', 'marketing_ok'))) THEN
            RAISE EXCEPTION 'crm-006: % exposes an identity, ciphertext or index column', v;
        END IF;
        FOREACH p IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE'] LOOP
            IF pg_catalog.has_table_privilege('crm_app', v, p) THEN
                RAISE EXCEPTION 'crm-006: crm_app may % on view %', p, v;
            END IF;
        END LOOP;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                WHERE a.attrelid = 'crm.v_insight_fact'::regclass AND a.attname IN ('traveler_token', 'trip_id')) THEN
        RAISE EXCEPTION 'crm-006: crm.v_insight_fact carries a token or a trip id';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-006: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    FOREACH t IN ARRAY ARRAY['crm.traveler_relation_pair()', 'crm.traveler_relation_mirror()',
                             'crm.traveler_health_consent()', 'crm.relation_inverse(text)'] LOOP
        IF pg_catalog.has_function_privilege('public', t, 'EXECUTE') THEN
            RAISE EXCEPTION 'crm-006: % is executable by PUBLIC (SEC-4)', t;
        END IF;
    END LOOP;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-006', now(), 'AA-937: F1/F2 complete: relations (+inverse), health codes, documents, full F2 profile + history, age band list, list_view ids, F2 views + reader grants')
ON CONFLICT (version) DO NOTHING;

COMMIT;
