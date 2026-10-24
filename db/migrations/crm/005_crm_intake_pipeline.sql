-- Migration crm-005: AA-936 (partner CRM, design v3 card CRM-08) — Slice 1: the public intake form, the Inquiry trip
-- and the board: forms and submissions, consent evidence, the F2 profile, trips with their stage rule, the party
-- links, tasks and notes, the LLM gateway's call log and its platform rollup.
--
-- Owner: AA-Partner (api/migrations/005_crm_intake_pipeline.sql). AA-CIS-Infra db/migrations/crm/ holds the byte copy
-- DB Migrate applies (Migration Copy Guard). Key crm-005.
--
-- Why. Design v3 §2.7 F1: a prospect submits the inquiry form (C-01) -> crm_intake_process dedupes by blind index
-- (R6, which absorbs C47: a repeat submission attaches to the open Inquiry) -> an F1 traveller + an F2 profile +
-- companions + a trip at Inquiry + a "Reply within 2 h" task -> the card shows on the board (A-02), waiting on the
-- agency. D12: the CRM has its own LLM gateway and call log (no text); CIS reads usage over HTTP (crm.ops.v1).
--
-- What (lane §2.3–2.5 and §2.9 column lists, trimmed to what Slice 1 writes; later cards add columns):
--   1. crm.enforce_stage_transition(): the stage twin of crm.enforce_status_transition() (crm-002) for a column
--      named stage; the allowed moves live in crm.status_transition like every other status.
--   2. crm.tenant_settings: one row per agency; ai_enabled (default false, D12) and ai_budget_usd (default 2).
--   3. crm.form_definition (no PII): the agency's Stage 1 form version (schema jsonb, AA-prebuilt).
--   4. crm.intake_form: a public form (random public_key in the hosted / embed URL), the origins allowed to frame it,
--      the honeypot field name, the default owner and the lead source code. SELECT-only lookup policy
--      intake_form_public_lookup TO crm_app keyed on app.intake_key (set only by app.tenancy.intake_tx() from the URL
--      key; an unknown or disabled key matches nothing). Same pattern as the crm-004 caller lookups.
--   5. crm.form_submission: the encrypted answers (payload_enc, vault DEK), the idempotency key (UNIQUE per agency),
--      the processing state and outcome; payload redacted after 90 days (redact_after, design §3.6).
--   6. crm.consent (append-only, DM-6.5): the consent the form collected (contact, optional marketing).
--   7. crm.traveler_profile (F2): random traveller_token, bands only; no FK to crm.traveler (the only F1 -> F2 link is
--      the encrypted crm.traveler.profile_token_enc, design §4.3).
--   8. crm.trip: the folder; stage TEXT + CHECK with every stage of design §3.3 group D (inquiry … cancelled) so later
--      cards add moves, not a new CHECK; waiting_on agency|client|aa|supplier|none (Fix B1); the Stage 1 answers.
--      Slice 1 opens only the Inquiry moves (inquiry <-> qualifying, either -> lost with a reason, lost -> inquiry);
--      CRM-15 (AA-943) adds the gates and the rest.
--   9. crm.trip_stage_history (append-only): every stage move, its actor and reason code.
--  10. crm.trip_traveler (F1 side) and crm.trip_party (F2 side): the party twins, written in one transaction.
--  11. crm.task (status open|done|skipped) and crm.note (body_enc, F1-encrypted).
--  12. crm.llm_call (append-only, no text, no traveller token) and crm.llm_usage_daily (platform rollup per day x
--      stage x model, no tenant column, read by /crm/ops/v1/llm/usage).
--   No reader role gets anything here (CRM-09 adds the F2 views and their grants). Every tenant table follows the base
--   template (api/db/templates/tenant_table.sql); the append-only ones its append-only variant; llm_usage_daily is a
--   platform table. tests/integration/test_crm002_tenancy.py checks all of it.
--
-- Order: after crm-004 (AA-935); Guard 0 refuses to run before it is registered.
--
-- Runs as crm_owner (DB Migrate switch), one BEGIN … COMMIT block, no role DDL. Idempotent (IF NOT EXISTS, DROP
-- POLICY IF EXISTS, ON CONFLICT DO NOTHING). Rollback: a forward crm- file (MIG-14); before AA-936 deploys nothing
-- reads these tables.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- ── Guard 0: runs as the owner, after crm-004 ────────────────────────────────────────────────────
DO $$
BEGIN
    IF current_user <> 'crm_owner' THEN
        RAISE EXCEPTION 'crm-005: must run as crm_owner (DB Migrate live-owner switch), runs as %', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'crm-004') THEN
        RAISE EXCEPTION 'crm-005: crm-004 is not registered (the agency directory, AA-935, lands first)';
    END IF;
    IF to_regclass('crm.traveler') IS NULL OR to_regclass('crm.audit_event') IS NULL THEN
        RAISE EXCEPTION 'crm-005: crm.traveler / crm.audit_event are missing (crm-003)';
    END IF;
END $$;

-- ── 1. Stage transition trigger function ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm.enforce_stage_transition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.stage IS DISTINCT FROM OLD.stage AND NOT EXISTS (
        SELECT 1 FROM crm.status_transition t
         WHERE t.table_name = TG_TABLE_NAME AND t.from_status = OLD.stage AND t.to_status = NEW.stage
    ) THEN
        RAISE EXCEPTION 'crm: % stage % -> % is not an allowed transition', TG_TABLE_NAME, OLD.stage, NEW.stage
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION crm.enforce_stage_transition() FROM PUBLIC;

INSERT INTO crm.status_transition (table_name, from_status, to_status) VALUES
    ('intake_form', 'active', 'disabled'),
    ('intake_form', 'disabled', 'active'),
    ('form_submission', 'received', 'processed'),
    ('form_submission', 'received', 'failed'),
    ('form_submission', 'failed', 'received'),
    ('task', 'open', 'done'),
    ('task', 'open', 'skipped'),
    ('task', 'done', 'open'),
    ('task', 'skipped', 'open'),
    ('trip', 'inquiry', 'qualifying'),
    ('trip', 'qualifying', 'inquiry'),
    ('trip', 'inquiry', 'lost'),
    ('trip', 'qualifying', 'lost'),
    ('trip', 'lost', 'inquiry')
ON CONFLICT DO NOTHING;

-- ── 2. crm.tenant_settings ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.tenant_settings (
    tenant_id     UUID PRIMARY KEY DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                  REFERENCES crm.tenant (tenant_id),
    ai_enabled    BOOLEAN NOT NULL DEFAULT false,
    ai_budget_usd NUMERIC(10, 2) NOT NULL DEFAULT 2,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ,
    deleted_by    TEXT,
    purge_after   TIMESTAMPTZ,
    CONSTRAINT tenant_settings_budget_chk CHECK (ai_budget_usd >= 0 AND ai_budget_usd <= 10000),
    CONSTRAINT tenant_settings_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
COMMENT ON TABLE crm.tenant_settings IS 'AA-936 (crm-005): agency settings with safe defaults (design v3 §3.3 group A, Fix E3). Slice 1 holds the AI switches the LLM gateway checks (D12): ai_enabled default false, ai_budget_usd default 2 per month. No PII.';

-- ── 3. crm.form_definition ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.form_definition (
    form_definition_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    stage              TEXT NOT NULL DEFAULT 's1',
    version            INTEGER NOT NULL,
    schema_key         TEXT NOT NULL,
    schema             JSONB NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT form_definition_version_uq UNIQUE (tenant_id, stage, version),
    CONSTRAINT form_definition_stage_chk CHECK (stage IN ('s1', 's2', 's3')),
    CONSTRAINT form_definition_version_chk CHECK (version BETWEEN 1 AND 100000),
    CONSTRAINT form_definition_schema_key_chk CHECK (schema_key ~ '^[a-z][a-z0-9_.]{0,39}$'),
    CONSTRAINT form_definition_schema_chk CHECK (jsonb_typeof(schema) = 'object' AND octet_length(schema::text) <= 65536),
    CONSTRAINT form_definition_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
COMMENT ON TABLE crm.form_definition IS 'AA-936 (crm-005): a versioned client form of the agency (stage s1 = the inquiry form C-01). schema is the AA-prebuilt field list (no PII); schema_key names the server validator (app/intake/stage1.py). Conditional branches (R31) arrive with CRM-15.';

-- ── 4. crm.intake_form ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.intake_form (
    intake_form_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                            REFERENCES crm.tenant (tenant_id),
    public_key              TEXT NOT NULL,
    label                   TEXT NOT NULL,
    form_definition_id      UUID NOT NULL REFERENCES crm.form_definition (form_definition_id),
    allowed_origins         TEXT[] NOT NULL DEFAULT '{}',
    honeypot_field          TEXT NOT NULL,
    default_owner_member_id UUID REFERENCES crm.member (member_id),
    lead_source             TEXT NOT NULL DEFAULT 'website_form',
    privacy_notice_url      TEXT,
    status                  TEXT NOT NULL DEFAULT 'active',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at              TIMESTAMPTZ,
    deleted_by              TEXT,
    purge_after             TIMESTAMPTZ,
    CONSTRAINT intake_form_public_key_chk CHECK (public_key ~ '^[A-Za-z0-9_-]{20,64}$'),
    CONSTRAINT intake_form_label_chk CHECK (length(btrim(label)) BETWEEN 1 AND 80 AND label = btrim(label)),
    CONSTRAINT intake_form_origins_chk CHECK (
        cardinality(allowed_origins) <= 10
        AND array_to_string(allowed_origins, ' ', '!') ~ '^(https://[a-z0-9.-]+(:[0-9]{1,5})?( |$))*$'
    ),
    CONSTRAINT intake_form_honeypot_chk CHECK (honeypot_field ~ '^[a-z][a-z_]{2,30}$'),
    CONSTRAINT intake_form_lead_source_chk CHECK (lead_source ~ '^[a-z][a-z0-9_]{0,39}$'),
    CONSTRAINT intake_form_privacy_url_chk CHECK (
        privacy_notice_url IS NULL OR (privacy_notice_url ~ '^https://[^\s]+$' AND length(privacy_notice_url) <= 500)
    ),
    CONSTRAINT intake_form_status_chk CHECK (status IN ('active', 'disabled')),
    CONSTRAINT intake_form_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
-- One key opens one form across every agency (the public URL carries the key only).
CREATE UNIQUE INDEX IF NOT EXISTS intake_form_public_key_uq ON crm.intake_form (public_key);
COMMENT ON TABLE crm.intake_form IS 'AA-936 (crm-005): a public inquiry form of the agency (hosted page /c/f/<public_key> on the client host, or framed by the allowed origins). public_key is random and not a secret (it is in the URL); honeypot_field is the name of the hidden field bots fill. No PII.';

DROP POLICY IF EXISTS intake_form_public_lookup ON crm.intake_form;
CREATE POLICY intake_form_public_lookup ON crm.intake_form
    FOR SELECT
    TO crm_app
    USING (
        status = 'active'
        AND deleted_at IS NULL
        AND public_key = NULLIF(current_setting('app.intake_key', true), '')
    );
COMMENT ON POLICY intake_form_public_lookup ON crm.intake_form IS 'AA-936 (crm-005): the one active form whose public key the public intake route was called with, only while app.intake_key is set (app.tenancy.intake_tx). SELECT only.';

-- ── 5. crm.form_submission ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.form_submission (
    submission_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id              UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                           REFERENCES crm.tenant (tenant_id),
    intake_form_id         UUID NOT NULL REFERENCES crm.intake_form (intake_form_id),
    stage                  TEXT NOT NULL DEFAULT 's1',
    schema_key             TEXT NOT NULL,
    payload_enc            BYTEA,
    idempotency_key        TEXT NOT NULL,
    hidden_answers_dropped INTEGER NOT NULL DEFAULT 0,
    status                 TEXT NOT NULL DEFAULT 'received',
    outcome                TEXT,
    failure_class          TEXT,
    trip_id                UUID,
    traveler_id            UUID REFERENCES crm.traveler (traveler_id),
    processed_at           TIMESTAMPTZ,
    redact_after           TIMESTAMPTZ NOT NULL DEFAULT now() + interval '90 days',
    payload_redacted_at    TIMESTAMPTZ,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by             TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at             TIMESTAMPTZ,
    deleted_by             TEXT,
    purge_after            TIMESTAMPTZ,
    CONSTRAINT form_submission_idempotency_uq UNIQUE (tenant_id, idempotency_key),
    CONSTRAINT form_submission_stage_chk CHECK (stage IN ('s1', 's2', 's3')),
    CONSTRAINT form_submission_schema_key_chk CHECK (schema_key ~ '^[a-z][a-z0-9_.]{0,39}$'),
    CONSTRAINT form_submission_payload_chk CHECK (
        (payload_enc IS NOT NULL AND octet_length(payload_enc) >= 30) OR payload_redacted_at IS NOT NULL
    ),
    CONSTRAINT form_submission_idempotency_chk CHECK (idempotency_key ~ '^[A-Za-z0-9:_-]{8,80}$'),
    CONSTRAINT form_submission_dropped_chk CHECK (hidden_answers_dropped BETWEEN 0 AND 1000),
    CONSTRAINT form_submission_status_chk CHECK (status IN ('received', 'processed', 'failed')),
    CONSTRAINT form_submission_outcome_chk CHECK (
        (status = 'processed') = (outcome IS NOT NULL) AND (outcome IS NULL OR outcome IN ('created', 'attached'))
    ),
    CONSTRAINT form_submission_failure_chk CHECK (failure_class IS NULL OR failure_class ~ '^[A-Za-z][A-Za-z0-9_]{0,63}$'),
    CONSTRAINT form_submission_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS form_submission_trip_idx ON crm.form_submission (trip_id) WHERE trip_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS form_submission_redact_idx ON crm.form_submission (redact_after)
    WHERE payload_redacted_at IS NULL;
COMMENT ON TABLE crm.form_submission IS 'AA-936 (crm-005): one submitted client form. payload_enc = the answers as JSON, AES-256-GCM under the tenant vault DEK (AAD = tenant, table, column, submission id); the server drops hidden-branch answers before storing (R31, CRM-15). Processed by the crm_intake_process job (outcome created = new trip, attached = repeat inquiry on the open trip, C47). Payload redacted after 90 days (design §3.6), the row kept.';
COMMENT ON COLUMN crm.form_submission.payload_enc IS 'pii:contact; encrypted (vault DEK): the answers, names, email and phone included';
COMMENT ON COLUMN crm.form_submission.idempotency_key IS 'the page''s random submission id (a retried POST is stored once)';

-- ── 6. crm.consent (append-only) ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.consent (
    consent_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                   REFERENCES crm.tenant (tenant_id),
    traveler_id    UUID NOT NULL REFERENCES crm.traveler (traveler_id),
    purpose        TEXT NOT NULL,
    value          BOOLEAN NOT NULL,
    at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    source         TEXT NOT NULL,
    submission_id  UUID REFERENCES crm.form_submission (submission_id),
    notice_version TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT consent_purpose_chk CHECK (
        purpose IN ('contact', 'marketing', 'health_data', 'ops_release', 'ai_processing', 'terms')
    ),
    CONSTRAINT consent_source_chk CHECK (source IN ('form', 'portal', 'agent_recorded', 'import')),
    CONSTRAINT consent_notice_chk CHECK (notice_version IS NULL OR notice_version ~ '^[a-z0-9_.-]{1,40}$')
);
CREATE INDEX IF NOT EXISTS consent_traveler_idx ON crm.consent (traveler_id, purpose, at DESC);
CREATE OR REPLACE TRIGGER consent_append_only
    BEFORE UPDATE OR DELETE ON crm.consent
    FOR EACH ROW EXECUTE FUNCTION crm.reject_append_only_change();
CREATE OR REPLACE TRIGGER consent_no_truncate
    BEFORE TRUNCATE ON crm.consent
    FOR EACH STATEMENT EXECUTE FUNCTION crm.reject_append_only_change();
REVOKE UPDATE, DELETE, TRUNCATE ON crm.consent FROM crm_app;
COMMENT ON TABLE crm.consent IS 'AA-936 (crm-005): consent evidence (DM-6.5), append-only: one row per purpose and answer, the latest row per purpose wins. Slice 1 writes contact (required by the form) and marketing (optional) with source form and the submission id. Erasure goes through crm.erase_subject() (CRM-35).';

-- ── 7. crm.traveler_profile (F2) ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.traveler_profile (
    traveler_token      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                        REFERENCES crm.tenant (tenant_id),
    budget_band         TEXT,
    pace                TEXT,
    group_pref          TEXT,
    repeat_count        INTEGER NOT NULL DEFAULT 0,
    stage2_completeness SMALLINT NOT NULL DEFAULT 0,
    marketing_ok        BOOLEAN NOT NULL DEFAULT false,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    purge_after         TIMESTAMPTZ,
    CONSTRAINT traveler_profile_budget_chk CHECK (
        budget_band IS NULL OR budget_band IN ('under_1000', '1000_2000', '2000_3500', '3500_5000', 'over_5000', 'not_sure')
    ),
    CONSTRAINT traveler_profile_pace_chk CHECK (pace IS NULL OR pace IN ('relaxed', 'balanced', 'adventure')),
    CONSTRAINT traveler_profile_group_chk CHECK (group_pref IS NULL OR group_pref IN ('private', 'small_group')),
    CONSTRAINT traveler_profile_repeat_chk CHECK (repeat_count BETWEEN 0 AND 10000),
    CONSTRAINT traveler_profile_s2_chk CHECK (stage2_completeness BETWEEN 0 AND 100),
    CONSTRAINT traveler_profile_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
COMMENT ON TABLE crm.traveler_profile IS 'AA-936 (crm-005): F2 pseudonymous profile (design v3 §4.3, lane §2.4): a random traveller_token and bands only, no identity column and no FK to crm.traveler (the only link is the encrypted crm.traveler.profile_token_enc). The F2 views and the NOLOGIN reader grants arrive with CRM-09 (AA-937).';

-- ── 8. crm.trip ──────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.trip (
    trip_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    title            TEXT NOT NULL,
    stage            TEXT NOT NULL DEFAULT 'inquiry',
    stage_entered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    waiting_on       TEXT NOT NULL DEFAULT 'agency',
    start_date       DATE,
    end_date         DATE,
    month            DATE,
    date_flex_days   SMALLINT NOT NULL DEFAULT 0,
    nights           SMALLINT,
    destinations     TEXT[] NOT NULL DEFAULT '{}',
    party_adults     SMALLINT NOT NULL DEFAULT 1,
    party_child_ages SMALLINT[] NOT NULL DEFAULT '{}',
    party_type       TEXT,
    budget_band      TEXT,
    trip_style       TEXT,
    owner_member_id  UUID REFERENCES crm.member (member_id),
    intake_form_id   UUID REFERENCES crm.intake_form (intake_form_id),
    lead_source      TEXT,
    lost_reason_code TEXT,
    last_inquiry_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT trip_title_chk CHECK (length(btrim(title)) BETWEEN 1 AND 120),
    CONSTRAINT trip_stage_chk CHECK (stage IN (
        'inquiry', 'qualifying', 'proposal', 'booked', 'pre_departure', 'travelling', 'completed', 'lost', 'cancelled'
    )),
    CONSTRAINT trip_waiting_on_chk CHECK (waiting_on IN ('agency', 'client', 'aa', 'supplier', 'none')),
    CONSTRAINT trip_dates_chk CHECK (
        (start_date IS NULL OR end_date IS NULL OR end_date >= start_date)
        AND (month IS NULL OR month = date_trunc('month', month)::date)
    ),
    CONSTRAINT trip_flex_chk CHECK (date_flex_days BETWEEN 0 AND 60),
    CONSTRAINT trip_nights_chk CHECK (nights IS NULL OR nights BETWEEN 1 AND 90),
    CONSTRAINT trip_destinations_chk CHECK (
        cardinality(destinations) <= 12
        AND array_to_string(destinations, ',', '!') ~ '^([a-z][a-z_]{1,39}(,|$))*$'
    ),
    CONSTRAINT trip_party_chk CHECK (
        party_adults BETWEEN 1 AND 50
        AND cardinality(party_child_ages) <= 20
        AND (cardinality(party_child_ages) = 0 OR (0 <= ALL (party_child_ages) AND 17 >= ALL (party_child_ages)))
    ),
    CONSTRAINT trip_party_type_chk CHECK (
        party_type IS NULL OR party_type IN ('solo', 'couple', 'family', 'friends', 'group')
    ),
    CONSTRAINT trip_budget_chk CHECK (
        budget_band IS NULL OR budget_band IN ('under_1000', '1000_2000', '2000_3500', '3500_5000', 'over_5000', 'not_sure')
    ),
    CONSTRAINT trip_style_chk CHECK (trip_style IS NULL OR trip_style IN ('relaxed', 'balanced', 'adventure')),
    CONSTRAINT trip_lead_source_chk CHECK (lead_source IS NULL OR lead_source ~ '^[a-z][a-z0-9_]{0,39}$'),
    -- R23: a lost trip always has one of the fixed reasons; any other stage has none.
    CONSTRAINT trip_lost_reason_chk CHECK (
        (stage = 'lost') = (lost_reason_code IS NOT NULL)
        AND (lost_reason_code IS NULL OR lost_reason_code IN (
            'price', 'price_aa_tour', 'aa_sold_out', 'aa_on_request_declined', 'dates_changed', 'went_elsewhere',
            'no_response', 'postponed', 'other'
        ))
    ),
    CONSTRAINT trip_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS trip_board_idx ON crm.trip (tenant_id, stage, last_inquiry_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS trip_owner_idx ON crm.trip (owner_member_id) WHERE owner_member_id IS NOT NULL;
ALTER TABLE crm.form_submission DROP CONSTRAINT IF EXISTS form_submission_trip_fk;
ALTER TABLE crm.form_submission ADD CONSTRAINT form_submission_trip_fk FOREIGN KEY (trip_id) REFERENCES crm.trip (trip_id);
COMMENT ON TABLE crm.trip IS 'AA-936 (crm-005): the trip, the folder everything hangs off (design v3 §0.2). stage covers every stage of design §3.3 group D; the allowed moves are rows in crm.status_transition (table trip) checked by crm.enforce_stage_transition(). Slice 1: inquiry <-> qualifying, -> lost (reason R23), lost -> inquiry; CRM-15 adds the rest and the gates. The Stage 1 answers are bands and codes, no identity (pii:travel by design: dates and destinations of a household).';
COMMENT ON COLUMN crm.trip.title IS 'pii:travel; generated from the destination codes and nights (never a name); the agent may rename it';
COMMENT ON COLUMN crm.trip.last_inquiry_at IS 'the latest submission that created or attached to this trip (board order, C47)';

-- ── 9. crm.trip_stage_history (append-only) ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.trip_stage_history (
    history_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                 REFERENCES crm.tenant (tenant_id),
    trip_id      UUID NOT NULL REFERENCES crm.trip (trip_id),
    from_stage   TEXT,
    to_stage     TEXT NOT NULL,
    reason_code  TEXT NOT NULL,
    override     BOOLEAN NOT NULL DEFAULT false,
    at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT trip_stage_history_stage_chk CHECK (
        to_stage ~ '^[a-z_]{3,20}$' AND (from_stage IS NULL OR from_stage ~ '^[a-z_]{3,20}$')
    ),
    CONSTRAINT trip_stage_history_reason_chk CHECK (reason_code ~ '^[a-z][a-z0-9_]{0,39}$')
);
CREATE INDEX IF NOT EXISTS trip_stage_history_trip_idx ON crm.trip_stage_history (trip_id, at);
CREATE OR REPLACE TRIGGER trip_stage_history_append_only
    BEFORE UPDATE OR DELETE ON crm.trip_stage_history
    FOR EACH ROW EXECUTE FUNCTION crm.reject_append_only_change();
CREATE OR REPLACE TRIGGER trip_stage_history_no_truncate
    BEFORE TRUNCATE ON crm.trip_stage_history
    FOR EACH STATEMENT EXECUTE FUNCTION crm.reject_append_only_change();
REVOKE UPDATE, DELETE, TRUNCATE ON crm.trip_stage_history FROM crm_app;
COMMENT ON TABLE crm.trip_stage_history IS 'AA-936 (crm-005): every stage move of a trip (design §3.3 group D), append-only. created_by = the actor (member:<id> or job:<kind>); reason_code a code (intake, agent_move, lost reason, undo).';

-- ── 10. crm.trip_traveler (F1) and crm.trip_party (F2) ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.trip_traveler (
    trip_traveler_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                     REFERENCES crm.tenant (tenant_id),
    trip_id          UUID NOT NULL REFERENCES crm.trip (trip_id),
    traveler_id      UUID NOT NULL REFERENCES crm.traveler (traveler_id),
    role             TEXT NOT NULL,
    portal_access    TEXT NOT NULL DEFAULT 'none',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ,
    deleted_by       TEXT,
    purge_after      TIMESTAMPTZ,
    CONSTRAINT trip_traveler_uq UNIQUE (trip_id, traveler_id),
    CONSTRAINT trip_traveler_role_chk CHECK (role IN ('lead', 'companion')),
    CONSTRAINT trip_traveler_portal_chk CHECK (portal_access IN ('lead', 'companion', 'none')),
    CONSTRAINT trip_traveler_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS trip_traveler_one_lead_uq ON crm.trip_traveler (trip_id)
    WHERE role = 'lead' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS trip_traveler_traveler_idx ON crm.trip_traveler (traveler_id);
COMMENT ON TABLE crm.trip_traveler IS 'AA-936 (crm-005): F1 side of the party link (trip x traveller, lead or companion). crm_app only: no NOLOGIN reader is ever granted it (design §4.3, Fix A1; the isolation probe expects 42501).';

CREATE TABLE IF NOT EXISTS crm.trip_party (
    trip_party_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                          REFERENCES crm.tenant (tenant_id),
    trip_id               UUID NOT NULL REFERENCES crm.trip (trip_id),
    traveler_token        UUID NOT NULL REFERENCES crm.traveler_profile (traveler_token),
    role                  TEXT NOT NULL,
    age_band_at_departure TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ,
    deleted_by            TEXT,
    purge_after           TIMESTAMPTZ,
    CONSTRAINT trip_party_uq UNIQUE (trip_id, traveler_token),
    CONSTRAINT trip_party_role_chk CHECK (role IN ('lead', 'companion')),
    CONSTRAINT trip_party_age_band_chk CHECK (
        age_band_at_departure IS NULL OR age_band_at_departure ~ '^[a-z0-9_]{1,20}$'
    ),
    CONSTRAINT trip_party_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
COMMENT ON TABLE crm.trip_party IS 'AA-936 (crm-005): F2 twin of crm.trip_traveler (trip x traveller_token), written in the same transaction; the only party link AI and insight views will see (CRM-09).';

-- ── 11. crm.task and crm.note ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm.task (
    task_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                       REFERENCES crm.tenant (tenant_id),
    trip_id            UUID REFERENCES crm.trip (trip_id),
    kind               TEXT NOT NULL,
    assignee_member_id UUID REFERENCES crm.member (member_id),
    status             TEXT NOT NULL DEFAULT 'open',
    due_anchor         TEXT,
    due_offset_days    SMALLINT,
    due_at             TIMESTAMPTZ,
    due_overridden     BOOLEAN NOT NULL DEFAULT false,
    done_at            TIMESTAMPTZ,
    done_by            TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,
    deleted_by         TEXT,
    purge_after        TIMESTAMPTZ,
    CONSTRAINT task_kind_chk CHECK (kind ~ '^[a-z][a-z0-9_]{0,39}$'),
    CONSTRAINT task_status_chk CHECK (status IN ('open', 'done', 'skipped')),
    CONSTRAINT task_anchor_chk CHECK (due_anchor IS NULL OR due_anchor IN (
        'departure', 'return', 'created', 'stage_entered', 'hold_expiry', 'deposit_paid', 'ops_handoff'
    )),
    CONSTRAINT task_offset_chk CHECK (due_offset_days IS NULL OR due_offset_days BETWEEN -365 AND 365),
    CONSTRAINT task_done_chk CHECK ((status = 'open') = (done_at IS NULL) AND (done_at IS NULL) = (done_by IS NULL)),
    CONSTRAINT task_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS task_trip_idx ON crm.task (trip_id) WHERE trip_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS task_open_idx ON crm.task (tenant_id, assignee_member_id, due_at)
    WHERE status = 'open' AND deleted_at IS NULL;
-- One open task of a kind per trip: a repeat inquiry re-opens the reply task instead of adding a second one.
CREATE UNIQUE INDEX IF NOT EXISTS task_open_kind_uq ON crm.task (trip_id, kind)
    WHERE status = 'open' AND deleted_at IS NULL AND trip_id IS NOT NULL;
COMMENT ON TABLE crm.task IS 'AA-936 (crm-005): agency tasks (lane §2.5; R20 buckets later). kind is a code the UI words (reply_inquiry = "Reply within 2 h"); no free text here. done_by = member:<id>.';

CREATE TABLE IF NOT EXISTS crm.note (
    note_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                REFERENCES crm.tenant (tenant_id),
    trip_id     UUID REFERENCES crm.trip (trip_id),
    traveler_id UUID REFERENCES crm.traveler (traveler_id),
    kind        TEXT NOT NULL,
    body_enc    BYTEA NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,
    deleted_by  TEXT,
    purge_after TIMESTAMPTZ,
    CONSTRAINT note_kind_chk CHECK (kind IN ('internal', 'call_log', 'stage2_free_text', 'inquiry_message')),
    CONSTRAINT note_subject_chk CHECK (trip_id IS NOT NULL OR traveler_id IS NOT NULL),
    CONSTRAINT note_body_chk CHECK (octet_length(body_enc) >= 30),
    CONSTRAINT note_trash_chk CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL) AND (deleted_at IS NULL) = (purge_after IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS note_trip_idx ON crm.note (trip_id, created_at) WHERE trip_id IS NOT NULL;
COMMENT ON TABLE crm.note IS 'AA-936 (crm-005): notes on a trip or traveller (lane §2.5). body_enc is F1 ciphertext (vault DEK); free text never leaves it unencrypted and passes F3 before any AI use (CRM-10). kind inquiry_message = the prospect''s message from the form.';
COMMENT ON COLUMN crm.note.body_enc IS 'pii:free_text; encrypted (vault DEK)';

-- ── 12. crm.llm_call (append-only) and crm.llm_usage_daily (platform rollup) ────────────────────
CREATE TABLE IF NOT EXISTS crm.llm_call (
    llm_call_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID NOT NULL DEFAULT NULLIF(current_setting('app.tenant_id', true), '')::uuid
                  REFERENCES crm.tenant (tenant_id),
    at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    stage         TEXT NOT NULL,
    role          TEXT NOT NULL,
    provider      TEXT NOT NULL,
    model         TEXT NOT NULL,
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd_est  NUMERIC(12, 6) NOT NULL DEFAULT 0,
    latency_ms    INTEGER NOT NULL DEFAULT 0,
    outcome       TEXT NOT NULL,
    refusal_code  TEXT,
    error_class   TEXT,
    scrub_receipt JSONB NOT NULL DEFAULT '{}',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    TEXT NOT NULL DEFAULT COALESCE(NULLIF(current_setting('app.actor', true), ''), current_user::text),
    CONSTRAINT llm_call_stage_chk CHECK (stage ~ '^crm_[a-z0-9_]{1,40}$'),
    CONSTRAINT llm_call_role_chk CHECK (role IN ('writer', 'judge', 'validate')),
    CONSTRAINT llm_call_provider_chk CHECK (provider ~ '^[a-z][a-z0-9_]{0,30}$'),
    CONSTRAINT llm_call_model_chk CHECK (model ~ '^[A-Za-z0-9._:/-]{1,120}$'),
    CONSTRAINT llm_call_tokens_chk CHECK (input_tokens >= 0 AND output_tokens >= 0 AND latency_ms >= 0),
    CONSTRAINT llm_call_cost_chk CHECK (cost_usd_est >= 0),
    CONSTRAINT llm_call_outcome_chk CHECK (outcome IN ('ok', 'refused', 'error')),
    CONSTRAINT llm_call_refusal_chk CHECK ((outcome = 'refused') = (refusal_code IS NOT NULL)
        AND (refusal_code IS NULL OR refusal_code ~ '^[a-z][a-z0-9_]{0,39}$')),
    CONSTRAINT llm_call_error_chk CHECK (error_class IS NULL OR error_class ~ '^[A-Za-z][A-Za-z0-9_]{0,63}$'),
    -- Counts and versions only (entity counts, scrubber version): never a value.
    CONSTRAINT llm_call_receipt_chk CHECK (jsonb_typeof(scrub_receipt) = 'object' AND octet_length(scrub_receipt::text) <= 2048)
);
CREATE INDEX IF NOT EXISTS llm_call_tenant_at_idx ON crm.llm_call (tenant_id, at DESC);
CREATE OR REPLACE TRIGGER llm_call_append_only
    BEFORE UPDATE OR DELETE ON crm.llm_call
    FOR EACH ROW EXECUTE FUNCTION crm.reject_append_only_change();
CREATE OR REPLACE TRIGGER llm_call_no_truncate
    BEFORE TRUNCATE ON crm.llm_call
    FOR EACH STATEMENT EXECUTE FUNCTION crm.reject_append_only_change();
REVOKE UPDATE, DELETE, TRUNCATE ON crm.llm_call FROM crm_app;
COMMENT ON TABLE crm.llm_call IS 'AA-936 (crm-005): one call (or refusal) of the CRM LLM gateway (D12 change, design §4.5: scrub receipt -> budget -> ai_enabled -> call -> this row). No prompt, no output, no traveller token. Retention 180 days + rollup (design §3.6; the purge job arrives with CRM-33a).';

CREATE TABLE IF NOT EXISTS crm.llm_usage_daily (
    day           DATE NOT NULL,
    stage         TEXT NOT NULL,
    model         TEXT NOT NULL,
    calls         INTEGER NOT NULL DEFAULT 0,
    failed_calls  INTEGER NOT NULL DEFAULT 0,
    input_tokens  BIGINT NOT NULL DEFAULT 0,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    cost_usd      NUMERIC(14, 6) NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (day, stage, model),
    CONSTRAINT llm_usage_daily_stage_chk CHECK (stage ~ '^crm_[a-z0-9_]{1,40}$'),
    CONSTRAINT llm_usage_daily_model_chk CHECK (model ~ '^[A-Za-z0-9._:/-]{1,120}$'),
    CONSTRAINT llm_usage_daily_counts_chk CHECK (
        calls >= 0 AND failed_calls >= 0 AND failed_calls <= calls AND input_tokens >= 0 AND output_tokens >= 0
        AND cost_usd >= 0
    )
);
REVOKE DELETE, TRUNCATE ON crm.llm_usage_daily FROM crm_app;
COMMENT ON TABLE crm.llm_usage_daily IS 'AA-936 (crm-005): platform rollup of crm.llm_call per UTC day x stage x model, summed over every agency (no tenant column, no PII), written by the gateway in the call''s transaction; read by GET /crm/ops/v1/llm/usage (crm.ops.v1) for the CIS cost page. crm_app may SELECT, INSERT, UPDATE.';

-- ── RLS + triggers on every tenant table ─────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['tenant_settings', 'form_definition', 'intake_form', 'form_submission', 'consent',
                             'traveler_profile', 'trip', 'trip_stage_history', 'trip_traveler', 'trip_party', 'task',
                             'note', 'llm_call'] LOOP
        EXECUTE format('ALTER TABLE crm.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE crm.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON crm.%I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON crm.%I '
            'TO crm_owner, crm_app, crm_ai_reader, crm_insights, crm_support_reader, crm_eraser '
            'USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid) '
            'WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)', t);
        IF t NOT IN ('consent', 'trip_stage_history', 'llm_call') THEN
            EXECUTE format(
                'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.set_updated_at()',
                t || '_set_updated_at', t);
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['intake_form', 'form_submission', 'task'] LOOP
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE OF status ON crm.%I '
            'FOR EACH ROW EXECUTE FUNCTION crm.enforce_status_transition()', t || '_status_transition', t);
    END LOOP;
END $$;

CREATE OR REPLACE TRIGGER trip_stage_transition
    BEFORE UPDATE OF stage ON crm.trip
    FOR EACH ROW EXECUTE FUNCTION crm.enforce_stage_transition();

-- ── Guard 1: the shape this file promises ────────────────────────────────────────────────────────
DO $$
DECLARE
    t text;
    r text;
BEGIN
    FOREACH t IN ARRAY ARRAY['crm.tenant_settings', 'crm.form_definition', 'crm.intake_form', 'crm.form_submission',
                             'crm.consent', 'crm.traveler_profile', 'crm.trip', 'crm.trip_stage_history',
                             'crm.trip_traveler', 'crm.trip_party', 'crm.task', 'crm.note', 'crm.llm_call'] LOOP
        IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_catalog.pg_class WHERE oid = t::regclass) THEN
            RAISE EXCEPTION 'crm-005: % must have ENABLE + FORCE row level security', t;
        END IF;
        FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_insights', 'crm_support_reader', 'crm_eraser'] LOOP
            IF pg_catalog.has_table_privilege(r, t, 'SELECT') THEN
                RAISE EXCEPTION 'crm-005: reader % may read % (grants come with CRM-09, never on F1 tables)', r, t;
            END IF;
        END LOOP;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['crm.consent', 'crm.trip_stage_history', 'crm.llm_call'] LOOP
        IF pg_catalog.has_table_privilege('crm_app', t, 'UPDATE') OR pg_catalog.has_table_privilege('crm_app', t, 'DELETE') THEN
            RAISE EXCEPTION 'crm-005: % is append-only but crm_app may change it', t;
        END IF;
    END LOOP;
    IF pg_catalog.has_table_privilege('crm_app', 'crm.llm_usage_daily', 'DELETE') THEN
        RAISE EXCEPTION 'crm-005: crm_app may delete from crm.llm_usage_daily';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
               WHERE c.relnamespace = 'crm'::regnamespace AND 0 = ANY (pol.polroles)) THEN
        RAISE EXCEPTION 'crm-005: a crm policy applies TO PUBLIC (catalogue rule b); name the CRM roles';
    END IF;
    IF (SELECT polcmd FROM pg_catalog.pg_policy WHERE polrelid = 'crm.intake_form'::regclass
         AND polname = 'intake_form_public_lookup') IS DISTINCT FROM 'r' THEN
        RAISE EXCEPTION 'crm-005: intake_form_public_lookup must be FOR SELECT';
    END IF;
    IF pg_catalog.has_function_privilege('public', 'crm.enforce_stage_transition()', 'EXECUTE') THEN
        RAISE EXCEPTION 'crm-005: crm.enforce_stage_transition() is executable by PUBLIC (SEC-4)';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('crm-005', now(), 'AA-936: intake forms + submissions, consent, F2 profile, trip + stage history, party links, task, note, llm_call + usage rollup')
ON CONFLICT (version) DO NOTHING;

COMMIT;
