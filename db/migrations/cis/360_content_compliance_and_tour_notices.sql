-- migrate: expand
-- Migration 360: AA-1039 R6 slice 2 (root ADR 0019 d20, d21) — the compliance flags of tenant content (the AA-subject
-- gate holds and the tour retirement flags of live posts), the tenant e-mail notices of a retired or restored tour,
-- and the notice-period policy before a retired tour's WordPress page goes to draft.
--
-- Why. d21: a tenant piece must link at least one AA subject and its sales links may point only to AA tour pages or
-- the tenant's TripPlanner site; a piece that fails is held in admin Tenant content QA › Compliance with a reason the
-- tenant reads. content_piece.status 'held' cannot carry it: since AA-770 a 'held' piece is an admin-only quality
-- label that still publishes. d20: a retired tour fans out to the tenant's live posts (WordPress page to draft after
-- the notice period, Facebook post flagged, nothing deleted) and to e-mail (at once when live pages or posts remain,
-- else a daily digest; a restored tour gets a "back on sale" mail). The flags are admin data (memory: the tenant sees
-- content only); the notices are the delivery record of the mail.
--
-- What. Three new tables in acp_shared:
--   1. acp_shared.content_compliance_flag  one row per finding on a tenant piece:
--        kind      subject_gate (d21: no AA subject, or a sales link off the AA catalogue) | tour_retired (d20: a
--                  live post about a tour AA retired);
--        stage     write (the gate when T9 finished the piece) | publish (the gate right before a publish) |
--                  retirement (the fan-out of a lifecycle event);
--        piece_id, publish_id (the live post, tour_retired), tour_id, channel, external_url;
--        codes     the finding codes (no_aa_subject, off_catalog_link, tour_retired), admin only;
--        detail    object: the links found, the hosts refused, the content hash the gate read;
--        tenant_message  the content-style sentence the tenant reads (English, no internal code);
--        event_key the gold_aa_internal.tour_lifecycle_event.idempotency_key of a tour_retired flag;
--        action    none | draft_after_notice (WordPress: the page goes to draft at draft_due_at, shared.job
--                  retired_page_draft) | notice_only (Facebook: nothing is deleted);
--        draft_due_at, drafted_at;
--        state open | resolved, resolution passed (the gate passes now) | released (staff override for this content
--        hash) | restored (the tour is served again) | unpublished (the post is no longer live) | drafted (the page
--        went to draft) | superseded (a newer piece of the request), resolved_at, resolved_by.
--      At most one open subject_gate flag per piece and one tour_retired flag per (event, post).
--   2. acp_shared.tenant_tour_notice  one row per (tenant, lifecycle event) the tenant is told about by e-mail:
--        event retired | restored, delivery immediate | digest, tour_name, summary (object: what the system did, the
--        pages and posts, the draft date, a replacement tour), mailed_at, mail_job_id, message_id, skipped_reason.
--   3. acp_shared.tour_retirement_policy  the notice period in days (1-90) before a retired tour's WordPress page
--        goes to draft: one optional platform row (tenant_id NULL) and optional per-tenant rows. No row = 7 days
--        (ADR 0019 b7, the code default).
--   RLS ENABLE + FORCE with the X1 parity policies <t>_cis_app_all / <t>_cis_owner_all and tenant_isolation TO
--   aa_app_user on each (rule a of the RLS catalogue); the tenant pool holds no privilege (admin data: the tenant reads
--   the reason through the CIS API, never the row). Grants: cis_app SELECT, INSERT, UPDATE, DELETE (DELETE: the
--   AA-839 erasure). Nothing for aa_app_user.
--
-- Behaviour. None on apply: no row. Before this file is applied the gate skips its flag reads and writes (it catches
-- the missing table), the admin Compliance route answers 503, and the fan-out jobs fail with a retryable error so
-- no retire / restore event is lost: the job retries, and the sweep re-enqueues a dead fan-out job of an event that
-- has no notice or flag yet once the tables exist.
--
-- Class: expand (root ADR 0017 d3): three new tables with their indexes, RLS flags, policies, grants and comments; no
-- change to any existing object, no DO block, no REVOKE, no seed row. Retention rows (DM-7.1): root data standards
-- Part B section 7, in the root PR of this change.
--
-- Number. 359 is the highest on main (03/11: 358 and 359 came with AA-1040), so this file is 360. If main moves again
-- before the merge, renumber to main max + 1 everywhere the number appears: the file name, this header, the
-- registration below, the code comments and runtime strings (services/tour_lifecycle/fanout.py MIGRATION, the admin
-- Compliance 503 text), the tests and the X1 lists in tests/integration/conftest.py, CONTEXT.md, the implementation
-- notes, the root DM-7.1 retention rows and the Infra notes (git grep the number in all three repos).
--
-- Rollback (a new forward migration, after the code that writes them is reverted): DROP TABLE
-- acp_shared.content_compliance_flag, acp_shared.tenant_tour_notice, acp_shared.tour_retirement_policy; (a
-- destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. DB Migrate runs cis/ files as cis_owner, the owner of schema
-- acp_shared, which then owns the tables.

BEGIN;

SET LOCAL lock_timeout = '5s';

-- 1. compliance flags ───────────────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE acp_shared.content_compliance_flag (
    flag_id         uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    kind            text NOT NULL,
    stage           text NOT NULL,
    piece_id        uuid NOT NULL,
    publish_id      uuid,
    tour_id         uuid,
    channel         text,
    external_url    text,
    codes           text[] NOT NULL DEFAULT '{}'::text[],
    detail          jsonb NOT NULL DEFAULT '{}'::jsonb,
    tenant_message  text NOT NULL,
    event_key       text,
    action          text NOT NULL DEFAULT 'none',
    draft_due_at    timestamp with time zone,
    drafted_at      timestamp with time zone,
    state           text NOT NULL DEFAULT 'open',
    resolution      text,
    resolved_at     timestamp with time zone,
    resolved_by     text,
    created_at      timestamp with time zone NOT NULL DEFAULT now(),
    updated_at      timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT content_compliance_flag_pkey PRIMARY KEY (flag_id),
    CONSTRAINT content_compliance_flag_kind_check CHECK (kind IN ('subject_gate', 'tour_retired')),
    CONSTRAINT content_compliance_flag_stage_check CHECK (stage IN ('write', 'publish', 'retirement')),
    CONSTRAINT content_compliance_flag_codes_check
        CHECK (codes <@ ARRAY['no_aa_subject', 'off_catalog_link', 'tour_retired']::text[]),
    CONSTRAINT content_compliance_flag_detail_check CHECK (jsonb_typeof(detail) = 'object'),
    CONSTRAINT content_compliance_flag_message_check CHECK (length(btrim(tenant_message)) BETWEEN 1 AND 1000),
    CONSTRAINT content_compliance_flag_action_check CHECK (action IN ('none', 'draft_after_notice', 'notice_only')),
    CONSTRAINT content_compliance_flag_draft_check CHECK ((action = 'draft_after_notice') = (draft_due_at IS NOT NULL)),
    CONSTRAINT content_compliance_flag_retired_check CHECK (
        kind <> 'tour_retired' OR (publish_id IS NOT NULL AND tour_id IS NOT NULL AND event_key IS NOT NULL)),
    CONSTRAINT content_compliance_flag_state_check CHECK (state IN ('open', 'resolved')),
    CONSTRAINT content_compliance_flag_resolution_check CHECK (
        resolution IS NULL
        OR resolution IN ('passed', 'released', 'restored', 'unpublished', 'drafted', 'superseded')),
    CONSTRAINT content_compliance_flag_resolved_check CHECK (
        (state = 'resolved') = (resolution IS NOT NULL) AND (state = 'resolved') = (resolved_at IS NOT NULL)),
    CONSTRAINT content_compliance_flag_resolved_by_check CHECK (resolved_by IS NULL OR length(resolved_by) <= 128),
    CONSTRAINT content_compliance_flag_url_check CHECK (external_url IS NULL OR length(external_url) <= 2000)
);
CREATE UNIQUE INDEX content_compliance_flag_open_gate_key
    ON acp_shared.content_compliance_flag (piece_id) WHERE kind = 'subject_gate' AND state = 'open';
CREATE UNIQUE INDEX content_compliance_flag_retired_post_key
    ON acp_shared.content_compliance_flag (event_key, publish_id) WHERE kind = 'tour_retired';
CREATE INDEX content_compliance_flag_queue_idx
    ON acp_shared.content_compliance_flag (state, kind, created_at DESC);
CREATE INDEX content_compliance_flag_tenant_idx ON acp_shared.content_compliance_flag (tenant_id, created_at DESC);
CREATE INDEX content_compliance_flag_piece_idx ON acp_shared.content_compliance_flag (piece_id);
CREATE INDEX content_compliance_flag_tour_idx
    ON acp_shared.content_compliance_flag (tour_id) WHERE tour_id IS NOT NULL;

COMMENT ON TABLE acp_shared.content_compliance_flag IS
    'AA-1039 R6 (CIS 360, root ADR 0019 d20 / d21): compliance findings on a tenant content piece: subject_gate (no '
    'AA subject, or a sales link off the AA catalogue; an open one blocks the publish) and tour_retired (a live post '
    'about a tour AA retired; WordPress goes to draft after the notice period, Facebook is flagged only). Admin-only '
    '(Tenant content QA › Compliance); the tenant reads tenant_message through the API, never the row. Goes with '
    'the tenant (AA-839 erasure, tenant_id).';
COMMENT ON COLUMN acp_shared.content_compliance_flag.tenant_message IS
    'AA-1039 (360): the content-style sentence shown to the tenant (English, no internal code, never "flag" / "QA").';
COMMENT ON COLUMN acp_shared.content_compliance_flag.detail IS
    'AA-1039 (360): {"links": [...], "refused_hosts": [...], "content_sha256": "...", ...}; admin only.';
COMMENT ON COLUMN acp_shared.content_compliance_flag.event_key IS
    'AA-1039 (360): gold_aa_internal.tour_lifecycle_event.idempotency_key of the retirement (tour_retired only).';
COMMENT ON COLUMN acp_shared.content_compliance_flag.draft_due_at IS
    'AA-1039 (360): when the WordPress page goes to draft (action draft_after_notice; shared.job retired_page_draft '
    'runs at this time). Set from acp_shared.tour_retirement_policy (default 7 days).';

ALTER TABLE acp_shared.content_compliance_flag ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.content_compliance_flag FORCE ROW LEVEL SECURITY;

CREATE POLICY content_compliance_flag_cis_app_all ON acp_shared.content_compliance_flag AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY content_compliance_flag_cis_owner_all ON acp_shared.content_compliance_flag AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY tenant_isolation ON acp_shared.content_compliance_flag AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
COMMENT ON POLICY tenant_isolation ON acp_shared.content_compliance_flag IS
    'AA-1039 (CIS 360): own tenant rows only; the tenant pool holds no privilege (flags are admin data), the policy '
    'is the floor if one is ever granted.';

GRANT SELECT, INSERT, UPDATE, DELETE ON acp_shared.content_compliance_flag TO cis_app;

-- 2. tenant e-mail notices of a retired / restored tour ──────────────────────────────────────────────────────────────

CREATE TABLE acp_shared.tenant_tour_notice (
    notice_id       uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    tour_id         uuid NOT NULL,
    source_id       text,
    event_key       text NOT NULL,
    event           text NOT NULL,
    tour_name       text,
    delivery        text NOT NULL,
    summary         jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamp with time zone NOT NULL DEFAULT now(),
    mailed_at       timestamp with time zone,
    mail_job_id     uuid,
    message_id      text,
    skipped_reason  text,
    CONSTRAINT tenant_tour_notice_pkey PRIMARY KEY (notice_id),
    CONSTRAINT tenant_tour_notice_event_key UNIQUE (tenant_id, event_key),
    CONSTRAINT tenant_tour_notice_event_check CHECK (event IN ('retired', 'restored')),
    CONSTRAINT tenant_tour_notice_delivery_check CHECK (delivery IN ('immediate', 'digest')),
    CONSTRAINT tenant_tour_notice_summary_check CHECK (jsonb_typeof(summary) = 'object'),
    CONSTRAINT tenant_tour_notice_name_check CHECK (tour_name IS NULL OR length(tour_name) <= 500),
    CONSTRAINT tenant_tour_notice_message_id_check CHECK (message_id IS NULL OR length(message_id) <= 300),
    CONSTRAINT tenant_tour_notice_skipped_check CHECK (skipped_reason IS NULL OR length(skipped_reason) <= 300)
);
CREATE INDEX tenant_tour_notice_unmailed_idx
    ON acp_shared.tenant_tour_notice (delivery, created_at) WHERE mailed_at IS NULL;
CREATE INDEX tenant_tour_notice_tenant_idx ON acp_shared.tenant_tour_notice (tenant_id, created_at DESC);

COMMENT ON TABLE acp_shared.tenant_tour_notice IS
    'AA-1039 R6 (CIS 360, root ADR 0019 d20): one e-mail notice per (tenant, tour lifecycle event): retired (at once '
    'when live pages or posts remain, else the daily digest) or restored ("back on sale"). A paused tour gets none. '
    'Written by the tour_retirement_fanout job, mailed by tour_notice_email (SES). Ids, the tour name and counts '
    'only; no address (recipients are resolved at send time). Goes with the tenant (AA-839 erasure).';

ALTER TABLE acp_shared.tenant_tour_notice ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.tenant_tour_notice FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_tour_notice_cis_app_all ON acp_shared.tenant_tour_notice AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY tenant_tour_notice_cis_owner_all ON acp_shared.tenant_tour_notice AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY tenant_isolation ON acp_shared.tenant_tour_notice AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

GRANT SELECT, INSERT, UPDATE, DELETE ON acp_shared.tenant_tour_notice TO cis_app;

-- 3. notice-period policy ───────────────────────────────────────────────────────────────────────────────────────────

CREATE TABLE acp_shared.tour_retirement_policy (
    tenant_id       uuid,
    notice_days     smallint NOT NULL,
    updated_at      timestamp with time zone NOT NULL DEFAULT now(),
    updated_by      text NOT NULL,
    CONSTRAINT tour_retirement_policy_days_check CHECK (notice_days BETWEEN 1 AND 90),
    CONSTRAINT tour_retirement_policy_updated_by_check CHECK (length(btrim(updated_by)) BETWEEN 1 AND 128)
);
CREATE UNIQUE INDEX tour_retirement_policy_scope_key
    ON acp_shared.tour_retirement_policy (COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid));

COMMENT ON TABLE acp_shared.tour_retirement_policy IS
    'AA-1039 R6 (CIS 360, root ADR 0019 d20 b7): days of notice before the WordPress page of a retired tour goes to '
    'draft. tenant_id NULL = the platform row; a tenant row overrides it. No row = 7 days (code default).';

ALTER TABLE acp_shared.tour_retirement_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE acp_shared.tour_retirement_policy FORCE ROW LEVEL SECURITY;

CREATE POLICY tour_retirement_policy_cis_app_all ON acp_shared.tour_retirement_policy AS PERMISSIVE FOR ALL
    TO cis_app USING (true) WITH CHECK (true);
CREATE POLICY tour_retirement_policy_cis_owner_all ON acp_shared.tour_retirement_policy AS PERMISSIVE FOR ALL
    TO cis_owner USING (true) WITH CHECK (true);
CREATE POLICY tenant_isolation ON acp_shared.tour_retirement_policy AS PERMISSIVE FOR ALL TO aa_app_user
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

GRANT SELECT, INSERT, UPDATE, DELETE ON acp_shared.tour_retirement_policy TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('360', now(), 'AA-1039 R6: acp_shared.content_compliance_flag, tenant_tour_notice, tour_retirement_policy '
                      '(AA-subject gate holds, tour retirement fan-out flags and e-mail notices)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
