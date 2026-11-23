-- Migration 471: AA-1174 (S288, privacy obligations on Platform > Compliance readiness; tech lead S287 close, Q14
-- changed: the Vietnam personal data law and GDPR now, plus every other law that applies after an applicability check)
-- — schema compliance becomes generic over "frameworks" (standards AND laws), law obligations get their legal metadata,
-- the applicability matrix gets its table, and the new cis.compliance.* settings of the privacy evidence are seeded.
--
-- Why. CIS 466 hard-coded the six in-scope frameworks in two CHECK constraints (compliance.requirement and
-- compliance.score_snapshot), so a law framework id (for example the Vietnam personal data law) is refused today. Laws
-- are shown as a met / not met checklist, never as a percentage (root advisory
-- docs/audits/2026-11-21-S287-compliance-tracking/README.md C.3 / C.6), and each obligation carries a counsel flag.
--
-- What:
--   1. compliance.framework: one row per framework (kind standard | law, title, jurisdiction, citation, official source
--      link, in_force_on = the date the text entered into force, applies_from = the date its duties apply when that is
--      later (GDPR: in force 2016-05-24, applies from 2018-05-25; NULL = from the in-force date), scored, sort_order,
--      active). Seeded with the six frameworks of 466 exactly; the EU AI Act row is kind 'law' AND scored = true, so
--      its existing score card stays (tech lead may drop the card later).
--      Law rows (the Vietnam personal data law, GDPR, ...) are NOT seeded here: they come with the private register
--      through scripts/compliance/load_register.py (format 2), because they depend on the applicability research.
--   2. compliance.requirement: the framework CHECK is replaced by a foreign key to compliance.framework (ON DELETE
--      RESTRICT); new columns counsel_review (a lawyer must confirm the item), applies_as (controller | processor |
--      both), source_url (the official text, https) and doc_url (our own document page, https://github.com/ only).
--   3. compliance.score_snapshot: the framework CHECK is replaced by a foreign key; the code writes snapshots only for
--      frameworks with scored = true.
--   4. compliance.applicability: the applicability matrix (market x segment x framework: the test, the threshold, the
--      verdict applies | not_yet | not_applicable, the primary source, the assessment date, a counsel flag). Platform
--      configuration, no personal data, no tenant column (no row-level security, like the other compliance tables).
--   5. Grants: cis_app DML on the two new tables (explicit, besides the default privileges of 466); nothing for
--      aa_app_user or PUBLIC.
--   6. Ten rows in shared.setting_definition, area compliance (settings-seed block below; the keys are named in
--      api/services/compliance_settings.py), each with its plain label and EN + VI guide (CIS 416 rule):
--        cis.compliance.validity_hours.cis_db             int hours 1-2160, default 72: how long a result the CIS API
--                                                         collects from its own database counts
--        cis.compliance.validity_hours.crm_ops            int hours 1-2160, default 72: the same for the CRM results
--        cis.compliance.legal_docs_overdue_max            int pages 0-100, default 0: legal pages past their own
--                                                         review cycle (last_reviewed + review_every_days)
--        cis.compliance.erasure_drill_max_age_days        int days 1-730, default 180: the last live erasure drill
--        cis.compliance.retention_run_max_age_days        int days 1-90, default 3: the oldest of the newest retention
--                                                         runs (one per retention job kind)
--        cis.compliance.retention_live_max_age_days       int days 1-90, default 7: the oldest of the newest LIVE
--                                                         retention runs (one per kind; a DRY RUN or held run deletes
--                                                         nothing, so only a live run proves old data goes)
--        cis.compliance.consent_capture_max_age_days      int days 1-730, default 90: the newest consent decision the
--                                                         CRM recorded
--        cis.compliance.campaign_consent_violations_max   int sends 0-1000, default 0: marketing sends to a contact
--                                                         without a yes at send time
--        cis.compliance.campaign_consent_window_days      int days 1-365, default 30: how far back the CRM counts sends
--        cis.compliance.applicability_review_max_age_days int days 1-730, default 180: when a matrix verdict shows
--                                                         "Review due" (display only, single approval)
--      Score-changing keys are maker_checker (as in 466); enforced (the code PR reads them).
--   7. A post-check, then register 471.
--
-- Behaviour on apply. None for running code: the code on main never writes a framework id outside the six seeded rows
-- and reads none of the new columns or keys. New columns are nullable or have a constant default.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): drops CHECK constraints, adds foreign keys,
-- creates tables, seeds rows and config rows, DO post-check. On Dev: Infra Migration Apply once every job table is idle
-- (root ADR 0017a). MIG-4: this migration-only PR, then the code PR (readiness raised to 471 there). Retention rows
-- (DM-7.1) for compliance.framework and compliance.applicability: root data standards Part B section 7, merged before
-- the Infra copy. Design ERD: root docs/architecture/erd/design/compliance.md if it is enforced (new tables and FKs).
--
-- Number. 471 is reserved for this lane by the S288 lane contract (470: another lane, 469 is the highest on main on
-- 23/11/2026). If the owner main max + 1 differs at merge, renumber everywhere (git grep '471_' and '471' in this repo:
-- this file, tests/integration/test_aa1174_migration_471.py, tests/unit/test_aa1174_obligations_seed.py,
-- api/core/readiness.py in the code PR, docs/implementation-notes/AA-1174.md; the root data standards rows).
--
-- Locks. ALTER TABLE on two small tables (253 requirement rows, a few hundred snapshot rows): DROP CONSTRAINT, ADD
-- COLUMN with constant defaults (catalog only), ADD CONSTRAINT FOREIGN KEY (validated; a short SHARE ROW EXCLUSIVE lock
-- on compliance.framework and the altered table). lock_timeout 5s. Re-runnable (IF NOT EXISTS, DROP CONSTRAINT IF
-- EXISTS, ON CONFLICT DO NOTHING); one transaction, self-registering.
--
-- X1. One BEGIN … COMMIT block, no role switch (Migration Apply runs cis/ files as cis_owner, the owner of schema
-- compliance since 466).
--
-- Rollback (a new forward migration, after the code PR is reverted): drop the two tables and the four columns, restore
-- the two CHECKs (only once no law row is referenced), DELETE the ten keys (their value rows first): a destructive file,
-- DRY RUN.

BEGIN;
SET LOCAL lock_timeout = '5s';

-- 1. compliance.framework ───────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS compliance.framework (
    framework     text    NOT NULL,
    kind          text    NOT NULL,
    title         text    NOT NULL,
    jurisdiction  text,
    citation      text,
    source_url    text,
    in_force_on   date,
    applies_from  date,
    scored        boolean NOT NULL DEFAULT false,
    sort_order    integer NOT NULL,
    active        boolean NOT NULL DEFAULT true,
    CONSTRAINT framework_pkey PRIMARY KEY (framework),
    CONSTRAINT framework_id_check CHECK (framework ~ '^[a-z0-9-]+:[0-9a-z.-]+$' AND char_length(framework) <= 40),
    CONSTRAINT framework_kind_check CHECK (kind IN ('standard', 'law')),
    CONSTRAINT framework_title_check CHECK (char_length(title) BETWEEN 3 AND 120),
    CONSTRAINT framework_jurisdiction_check CHECK (jurisdiction IS NULL OR jurisdiction ~ '^[A-Z]{2}(-[A-Z0-9]{1,3})?$'),
    CONSTRAINT framework_citation_check CHECK (citation IS NULL OR char_length(citation) <= 200),
    CONSTRAINT framework_source_url_check CHECK (source_url IS NULL
                                                 OR (source_url LIKE 'https://%' AND char_length(source_url) <= 500)),
    CONSTRAINT framework_applies_from_check CHECK (applies_from IS NULL OR in_force_on IS NULL
                                                   OR applies_from >= in_force_on),
    CONSTRAINT framework_sort_check CHECK (sort_order > 0)
);
COMMENT ON TABLE compliance.framework IS
    'AA-1174 (CIS 471): every framework of the readiness register. kind standard = scored as Evidenced %; kind law = '
    'a met / not met checklist of obligations (scored only when scored = true). Law rows come from the register loader.';
COMMENT ON COLUMN compliance.framework.in_force_on IS
    'AA-1174 (471): the date the text entered into force (one convention for every framework).';
COMMENT ON COLUMN compliance.framework.applies_from IS
    'AA-1174 (471): the date its duties apply when later than in_force_on (GDPR 2018-05-25); NULL = from in_force_on.';

-- EU AI Act: in force 2024-08-01, applies from 2026-08-02 (Art. 113; some chapters earlier, deployer duties then).
INSERT INTO compliance.framework (framework, kind, title, jurisdiction, citation, source_url, in_force_on,
                                  applies_from, scored, sort_order)
VALUES ('iso27001:2022', 'standard', 'ISO/IEC 27001:2022', NULL, NULL, NULL, NULL, NULL, true, 1),
       ('soc2:2017', 'standard', 'SOC 2 (TSC common criteria)', NULL, NULL, NULL, NULL, NULL, true, 2),
       ('iso42001:2023', 'standard', 'ISO/IEC 42001:2023', NULL, NULL, NULL, NULL, NULL, true, 3),
       ('owasp-top10:2021', 'standard', 'OWASP Top 10 (2021)', NULL, NULL, NULL, NULL, NULL, true, 4),
       ('owasp-llm:2025', 'standard', 'OWASP Top 10 for LLM (2025)', NULL, NULL, NULL, NULL, NULL, true, 5),
       ('eu-ai-act:2024', 'law', 'EU AI Act (deployer duties)', 'EU', 'Regulation (EU) 2024/1689',
        'https://eur-lex.europa.eu/eli/reg/2024/1689/oj', '2024-08-01', '2026-08-02', true, 6)
ON CONFLICT (framework) DO NOTHING;

-- 2. compliance.requirement: FK instead of the CHECK, legal metadata ─────────────────────────────────────────────────
ALTER TABLE compliance.requirement DROP CONSTRAINT IF EXISTS requirement_framework_check;
ALTER TABLE compliance.requirement ADD COLUMN IF NOT EXISTS counsel_review boolean NOT NULL DEFAULT false;
ALTER TABLE compliance.requirement ADD COLUMN IF NOT EXISTS applies_as text;
ALTER TABLE compliance.requirement ADD COLUMN IF NOT EXISTS source_url text;
ALTER TABLE compliance.requirement ADD COLUMN IF NOT EXISTS doc_url text;
ALTER TABLE compliance.requirement DROP CONSTRAINT IF EXISTS requirement_framework_fkey;
ALTER TABLE compliance.requirement ADD CONSTRAINT requirement_framework_fkey FOREIGN KEY (framework)
    REFERENCES compliance.framework (framework) ON DELETE RESTRICT;
ALTER TABLE compliance.requirement DROP CONSTRAINT IF EXISTS requirement_applies_as_check;
ALTER TABLE compliance.requirement ADD CONSTRAINT requirement_applies_as_check
    CHECK (applies_as IS NULL OR applies_as IN ('controller', 'processor', 'both'));
ALTER TABLE compliance.requirement DROP CONSTRAINT IF EXISTS requirement_source_url_check;
ALTER TABLE compliance.requirement ADD CONSTRAINT requirement_source_url_check
    CHECK (source_url IS NULL OR (source_url LIKE 'https://%' AND char_length(source_url) <= 500));
ALTER TABLE compliance.requirement DROP CONSTRAINT IF EXISTS requirement_doc_url_check;
ALTER TABLE compliance.requirement ADD CONSTRAINT requirement_doc_url_check
    CHECK (doc_url IS NULL OR (doc_url LIKE 'https://github.com/%' AND char_length(doc_url) <= 500));
COMMENT ON COLUMN compliance.requirement.counsel_review IS
    'AA-1174 (471): true = a lawyer must confirm how this obligation applies; readiness, not legal advice.';
COMMENT ON COLUMN compliance.requirement.doc_url IS
    'AA-1174 (471): our own document page for the obligation (a GitHub docs page), shown when no evidence row links.';

-- 3. compliance.score_snapshot: FK instead of the CHECK ─────────────────────────────────────────────────────────────
ALTER TABLE compliance.score_snapshot DROP CONSTRAINT IF EXISTS score_snapshot_framework_check;
ALTER TABLE compliance.score_snapshot DROP CONSTRAINT IF EXISTS score_snapshot_framework_fkey;
ALTER TABLE compliance.score_snapshot ADD CONSTRAINT score_snapshot_framework_fkey FOREIGN KEY (framework)
    REFERENCES compliance.framework (framework) ON DELETE RESTRICT;

-- 4. compliance.applicability (the matrix) ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS compliance.applicability (
    market         text    NOT NULL,
    segment        text    NOT NULL,
    framework      text    NOT NULL REFERENCES compliance.framework (framework) ON DELETE RESTRICT,
    test           text    NOT NULL,
    threshold      text,
    verdict        text    NOT NULL,
    source_url     text    NOT NULL,
    source_title   text    NOT NULL,
    assessed_on    date    NOT NULL,
    counsel_review boolean NOT NULL DEFAULT true,
    note           text,
    CONSTRAINT applicability_pkey PRIMARY KEY (market, segment, framework),
    CONSTRAINT applicability_market_check CHECK (market ~ '^[A-Z]{2}(-[A-Z0-9]{1,3})?$'),
    CONSTRAINT applicability_segment_check CHECK (segment IN ('traveller', 'agency', 'agency_client', 'staff')),
    CONSTRAINT applicability_test_check CHECK (char_length(test) BETWEEN 3 AND 300),
    CONSTRAINT applicability_threshold_check CHECK (threshold IS NULL OR char_length(threshold) <= 200),
    CONSTRAINT applicability_verdict_check CHECK (verdict IN ('applies', 'not_yet', 'not_applicable')),
    CONSTRAINT applicability_source_url_check CHECK (source_url LIKE 'https://%' AND char_length(source_url) <= 500),
    CONSTRAINT applicability_source_title_check CHECK (char_length(source_title) BETWEEN 3 AND 160),
    CONSTRAINT applicability_note_check CHECK (note IS NULL OR char_length(note) <= 300)
);
CREATE INDEX IF NOT EXISTS applicability_framework_idx ON compliance.applicability (framework);
COMMENT ON TABLE compliance.applicability IS
    'AA-1174 (CIS 471): which law applies to which market and data segment, with the test, the threshold and a primary '
    'source per verdict. Readiness, not legal advice; loaded from the private register (full replace).';

-- 5. Grants ─────────────────────────────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON compliance.framework, compliance.applicability FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON compliance.framework, compliance.applicability TO cis_app;

-- 6. Settings ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.compliance.validity_hours.cis_db", "app": "cis", "area": "compliance", "label": "Compliance: hours a check of the CIS database stays valid", "description": "Platform > Compliance (AA-1174): how many hours a result the CIS API collects from its own database (source cis_db: the retention runs of the job runner) counts after it was collected. Older evidence is stale and the privacy obligations it backs read not met. The page collects these results when an administrator presses Refresh evidence.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 2160, "allowed_values": null, "default_value": 72, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long a result the page read from the CIS database still counts as proof.", "raise": "Proof stays valid longer; a retention job that stopped is noticed later.", "lower": "Proof must be fresher; someone has to press Refresh evidence more often.", "when": "Keep it at three days while the results are collected by hand; shorten it once a daily job collects them.", "example": "With the default 72, a result collected on Monday at 09:00 stops counting on Thursday at 09:00."}, "vi": {"what": "Một kết quả trang đọc từ database CIS còn được tính là bằng chứng trong bao lâu.", "raise": "Bằng chứng còn hiệu lực lâu hơn; job dọn dữ liệu ngừng chạy bị phát hiện muộn hơn.", "lower": "Bằng chứng phải mới hơn; phải bấm Refresh evidence thường hơn.", "when": "Giữ ba ngày khi kết quả còn được thu bằng tay; rút ngắn khi có job hằng ngày thu.", "example": "Với mặc định 72, kết quả thu lúc 09:00 thứ Hai hết được tính lúc 09:00 thứ Năm."}}},
{"key": "cis.compliance.validity_hours.crm_ops", "app": "cis", "area": "compliance", "label": "Compliance: hours a check of the partner CRM stays valid", "description": "Platform > Compliance (AA-1174): how many hours a result the page reads from the partner CRM (source crm_ops: consent capture and campaign sends to opted-in contacts only, counts across agencies) counts after it was collected. Older evidence is stale and the marketing obligations it backs read not met.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 2160, "allowed_values": null, "default_value": 72, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long a result the page read from the partner CRM still counts as proof.", "raise": "Proof stays valid longer; a campaign sent to someone without consent is noticed later.", "lower": "Proof must be fresher; someone has to press Refresh evidence more often.", "when": "Keep it at three days while the results are collected by hand; shorten it once a daily job collects them.", "example": "With the default 72, a result collected on Monday at 09:00 stops counting on Thursday at 09:00."}, "vi": {"what": "Một kết quả trang đọc từ CRM đối tác còn được tính là bằng chứng trong bao lâu.", "raise": "Bằng chứng còn hiệu lực lâu hơn; chiến dịch gửi cho người chưa đồng ý bị phát hiện muộn hơn.", "lower": "Bằng chứng phải mới hơn; phải bấm Refresh evidence thường hơn.", "when": "Giữ ba ngày khi kết quả còn được thu bằng tay; rút ngắn khi có job hằng ngày thu.", "example": "Với mặc định 72, kết quả thu lúc 09:00 thứ Hai hết được tính lúc 09:00 thứ Năm."}}},
{"key": "cis.compliance.legal_docs_overdue_max", "app": "cis", "area": "compliance", "label": "Compliance: legal pages allowed past their review cycle", "description": "Platform > Compliance (AA-1174): each legal document check (records of processing, data processing agreement and annexes, sub-processor list, Vietnam transfer dossier, data subject request runbook, consent capture) passes while at most this many of its pages are past their own review cycle (last_reviewed plus the page's review_every_days, the same rule as the weekly docs freshness report). A page that is missing, superseded or undated is an error, whatever this value.", "value_type": "int", "unit": "pages", "min_value": 0, "max_value": 100, "allowed_values": null, "default_value": 0, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How many pages of one legal document may be past their own review date while its check still passes.", "raise": "Out-of-date legal pages still count as proof; a stale sub-processor list or agreement is less visible.", "lower": "Every legal page past its review date turns its obligation to not met.", "when": "Keep 0; raise it only for a short catch-up period, with a reason.", "example": "With the default 0, one annex of the processing agreement reviewed 31 days ago on a 30-day cycle fails the agreement check."}, "vi": {"what": "Bao nhiêu trang của một tài liệu pháp lý được phép quá hạn rà soát mà check của nó vẫn đạt.", "raise": "Trang pháp lý cũ vẫn được tính là bằng chứng; danh sách bên xử lý phụ hoặc thỏa thuận lỗi thời khó thấy hơn.", "lower": "Mỗi trang pháp lý quá hạn rà soát làm nghĩa vụ của nó thành chưa đạt.", "when": "Giữ 0; chỉ tăng trong một đợt bù việc ngắn, có lý do.", "example": "Với mặc định 0, một phụ lục của thỏa thuận xử lý dữ liệu rà soát cách đây 31 ngày theo chu kỳ 30 ngày làm check thỏa thuận không đạt."}}},
{"key": "cis.compliance.erasure_drill_max_age_days", "app": "cis", "area": "compliance", "label": "Compliance: days a live erasure drill counts", "description": "Platform > Compliance (AA-1174): the check last_erasure_drill passes while the newest live erasure drill in the root retention and erasure run log (docs/legal/retention-log.md, Runs) is at most this many days old. Older, the data subject request obligations it backs read not met.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 730, "allowed_values": null, "default_value": 180, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How recent the last live erasure drill must be for the erasure drill check to pass.", "raise": "Older drills still count; the erasure procedure may have changed since it was last tried for real.", "lower": "Erasure drills must be repeated more often to keep the obligation met.", "when": "Keep it at about half a year while on Dev; shorten it once real travellers' data is held.", "example": "With the default 180, a drill run on 31 October counts until 29 April."}, "vi": {"what": "Lượt diễn tập xóa dữ liệu thật gần nhất phải mới tới đâu thì check diễn tập xóa mới đạt.", "raise": "Diễn tập cũ hơn vẫn được tính; quy trình xóa có thể đã đổi từ lần thử thật gần nhất.", "lower": "Phải diễn tập xóa thường hơn để giữ nghĩa vụ đạt.", "when": "Giữ khoảng nửa năm khi còn ở Dev; rút ngắn khi đã giữ dữ liệu của khách thật.", "example": "Với mặc định 180, lượt diễn tập ngày 31 tháng 10 được tính tới ngày 29 tháng 4."}}},
{"key": "cis.compliance.retention_run_max_age_days", "app": "cis", "area": "compliance", "label": "Compliance: days the newest retention run of each kind counts", "description": "Platform > Compliance (AA-1174): the check retention_runs_recent passes while every retention job kind of the CIS job runner (llm call log, tenant API usage, jobs, decision log, cost snapshots) finished a run at most this many days ago; the oldest of those newest runs decides. Older, the storage limitation obligations it backs read not met: a retention schedule that stopped is not evidence.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 90, "allowed_values": null, "default_value": 3, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How recent the newest run of every retention job must be for the retention check to pass.", "raise": "A retention schedule that stopped is noticed later.", "lower": "A single missed daily run turns the retention obligation to not met.", "when": "Keep it a little above a day times the runs you accept to miss; the jobs run daily.", "example": "With the default 3, a kind whose last run finished on Monday fails the check from Friday."}, "vi": {"what": "Lượt chạy mới nhất của mỗi job dọn dữ liệu phải mới tới đâu thì check dọn dữ liệu mới đạt.", "raise": "Lịch dọn dữ liệu ngừng chạy bị phát hiện muộn hơn.", "lower": "Chỉ lỡ một lượt chạy hằng ngày là nghĩa vụ giới hạn lưu trữ thành chưa đạt.", "when": "Giữ cao hơn một ngày nhân số lượt chạy chấp nhận bị lỡ một chút; các job chạy hằng ngày.", "example": "Với mặc định 3, một loại job có lượt chạy cuối xong vào thứ Hai sẽ trượt check từ thứ Sáu."}}},
{"key": "cis.compliance.retention_live_max_age_days", "app": "cis", "area": "compliance", "label": "Compliance: days the newest live retention run of each kind counts", "description": "Platform > Compliance (AA-1174): the check retention_live_enabled passes while every retention job kind of the CIS job runner finished a LIVE run (one that may delete rows) at most this many days ago; the oldest of those newest live runs decides, and a kind with no live run at all fails it. Scheduled runs fall back to DRY RUN after a retention window changes and stay there until a live run of the new window is approved, and a held run deletes nothing either, so recent runs alone do not prove old data goes. Older, the storage limitation obligations it backs read not met.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 90, "allowed_values": null, "default_value": 7, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How recent the newest live run (one that really deletes old rows) of every retention job must be for the live retention check to pass.", "raise": "Retention jobs that fell back to DRY RUN, or keep being held, still count as deleting old data for longer.", "lower": "A short wait for the approval of a live run after a window change turns the storage limitation obligation to not met.", "when": "Keep it a few days above the time an approval of a live run usually takes; the jobs run daily.", "example": "With the default 7, a kind whose last live run finished 8 days ago, followed only by DRY RUN runs, fails the check."}, "vi": {"what": "Lượt chạy thật (xóa thật dữ liệu cũ) mới nhất của mỗi job dọn dữ liệu phải mới tới đâu thì check dọn dữ liệu thật mới đạt.", "raise": "Job dọn dữ liệu đã quay về chạy thử, hoặc liên tục bị giữ lại, vẫn được tính là đang xóa dữ liệu cũ lâu hơn.", "lower": "Chỉ chờ duyệt một lượt chạy thật sau khi đổi thời hạn lưu một chút là nghĩa vụ giới hạn lưu trữ thành chưa đạt.", "when": "Giữ cao hơn thời gian thường cần để duyệt một lượt chạy thật vài ngày; các job chạy hằng ngày.", "example": "Với mặc định 7, một loại job có lượt chạy thật cuối cách đây 8 ngày, sau đó chỉ chạy thử, làm check không đạt."}}},
{"key": "cis.compliance.consent_capture_max_age_days", "app": "cis", "area": "compliance", "label": "Compliance: days since the CRM last recorded a consent decision", "description": "Platform > Compliance (AA-1174): the check consent_capture_present passes while the newest consent decision the partner CRM recorded (any agency, any purpose; counts and dates only) is at most this many days old. Older, consent capture is not shown to be working and the consent obligations read not met.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 730, "allowed_values": null, "default_value": 90, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How recent the newest consent decision recorded in the partner CRM must be for the consent capture check to pass.", "raise": "A consent form that stopped recording is noticed later.", "lower": "Consent must be recorded more often (by real use or a test) to keep the obligation met.", "when": "Keep a quarter while agencies are few; shorten it once agencies collect consent every week.", "example": "With the default 90, a last decision recorded on 1 September counts until 30 November."}, "vi": {"what": "Quyết định đồng ý mới nhất CRM đối tác ghi nhận phải mới tới đâu thì check ghi nhận đồng ý mới đạt.", "raise": "Form đồng ý ngừng ghi nhận bị phát hiện muộn hơn.", "lower": "Phải có quyết định đồng ý được ghi thường hơn (dùng thật hoặc thử) để giữ nghĩa vụ đạt.", "when": "Giữ một quý khi còn ít đại lý; rút ngắn khi đại lý thu đồng ý hằng tuần.", "example": "Với mặc định 90, quyết định cuối ghi ngày 1 tháng 9 được tính tới ngày 30 tháng 11."}}},
{"key": "cis.compliance.campaign_consent_violations_max", "app": "cis", "area": "compliance", "label": "Compliance: marketing sends allowed without consent", "description": "Platform > Compliance (AA-1174): the check campaign_consent_enforced passes while the partner CRM counts at most this many marketing messages sent in the window (cis.compliance.campaign_consent_window_days) to a contact whose latest marketing consent at send time was not a yes, or who was on the suppression list. Counts only, across agencies.", "value_type": "int", "unit": "sends", "min_value": 0, "max_value": 1000, "allowed_values": null, "default_value": 0, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How many marketing messages sent without a yes may be tolerated while the campaign consent check still passes.", "raise": "Sends without consent are tolerated; the marketing obligations read met although the rule was broken.", "lower": "Any send without consent turns the marketing obligations to not met.", "when": "Keep 0: the consent gate should make a violation impossible, so one is a bug to fix.", "example": "With the default 0, one message sent to a contact who had said no fails the check."}, "vi": {"what": "Bao nhiêu tin marketing gửi khi chưa có đồng ý được chấp nhận mà check đồng ý chiến dịch vẫn đạt.", "raise": "Tin gửi khi chưa đồng ý được bỏ qua; nghĩa vụ marketing vẫn đạt dù luật đã bị vi phạm.", "lower": "Bất kỳ tin nào gửi khi chưa đồng ý làm nghĩa vụ marketing thành chưa đạt.", "when": "Giữ 0: cổng đồng ý phải chặn hết, nên có một vi phạm là lỗi cần sửa.", "example": "Với mặc định 0, một tin gửi cho người đã từ chối làm check không đạt."}}},
{"key": "cis.compliance.campaign_consent_window_days", "app": "cis", "area": "compliance", "label": "Compliance: days of campaign sends the consent check reads", "description": "Platform > Compliance (AA-1174): how many days back the partner CRM counts marketing sends and consent decisions for the campaign consent and consent capture checks (passed to the CRM's read-only privacy evidence route, which caps it).", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 365, "allowed_values": null, "default_value": 30, "scope_kind": "platform", "impact": "low", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How far back the campaign consent check looks at marketing messages sent by the partner CRM.", "raise": "Older sends are checked too; the count covers more campaigns.", "lower": "Only recent sends are checked; an old violation drops out of the count sooner.", "when": "Keep a month; widen it after a fix to show the history is clean.", "example": "With the default 30, a check on 30 November reads sends from 31 October on."}, "vi": {"what": "Check đồng ý chiến dịch xem lại các tin marketing CRM đối tác đã gửi trong bao nhiêu ngày.", "raise": "Kiểm cả tin gửi cũ hơn; số đếm bao nhiều chiến dịch hơn.", "lower": "Chỉ kiểm tin gửi gần đây; vi phạm cũ ra khỏi số đếm sớm hơn.", "when": "Giữ một tháng; nới rộng sau khi sửa lỗi để cho thấy lịch sử sạch.", "example": "Với mặc định 30, lượt kiểm ngày 30 tháng 11 đọc các tin gửi từ ngày 31 tháng 10."}}},
{"key": "cis.compliance.applicability_review_max_age_days", "app": "cis", "area": "compliance", "label": "Compliance: days before an applicability verdict needs a review", "description": "Platform > Compliance (AA-1174): a row of the applicability matrix (which law applies to which market and data segment) assessed longer ago than this many days shows a Review due badge on the Obligations tab. Display only: it never changes an obligation state.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 730, "allowed_values": null, "default_value": 180, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How old a verdict of the applicability matrix may be before it is marked for review.", "raise": "Verdicts are flagged for review less often; a changed law or threshold may be missed longer.", "lower": "Verdicts are flagged for review more often.", "when": "Keep about half a year; laws and thresholds change yearly at most.", "example": "With the default 180, a verdict assessed on 23 November shows Review due from 22 May."}, "vi": {"what": "Một kết luận trong ma trận áp dụng được bao nhiêu ngày thì bị đánh dấu cần rà soát lại.", "raise": "Kết luận ít bị đánh dấu rà soát hơn; luật hoặc ngưỡng thay đổi có thể bị bỏ sót lâu hơn.", "lower": "Kết luận bị đánh dấu rà soát thường hơn.", "when": "Giữ khoảng nửa năm; luật và ngưỡng thường đổi nhiều nhất mỗi năm một lần.", "example": "Với mặc định 180, kết luận đánh giá ngày 23 tháng 11 hiện Cần rà soát từ ngày 22 tháng 5."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- 7. Post-check ─────────────────────────────────────────────────────────────────────────────────────────────────────
DO $check$
DECLARE
    bad text;
    n   integer;
BEGIN
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'compliance' AND c.relkind IN ('r', 'p')
       AND (has_table_privilege('aa_app_user', c.oid, 'SELECT, INSERT, UPDATE, DELETE')
            OR NOT has_table_privilege('cis_app', c.oid, 'SELECT')
            OR NOT has_table_privilege('cis_app', c.oid, 'INSERT')
            OR NOT has_table_privilege('cis_app', c.oid, 'UPDATE')
            OR NOT has_table_privilege('cis_app', c.oid, 'DELETE'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 471: grants are not cis_app DML only on compliance.%', bad;
    END IF;
    SELECT count(*) INTO n FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'compliance' AND c.relkind = 'r'
       AND c.relname IN ('requirement', 'control', 'requirement_mapping', 'evidence', 'score_snapshot', 'framework',
                         'applicability');
    IF n <> 7 THEN
        RAISE EXCEPTION 'migration 471: % of the seven compliance tables exist', n;
    END IF;
    IF (SELECT count(*) FROM compliance.framework
         WHERE framework IN ('iso27001:2022', 'soc2:2017', 'iso42001:2023', 'owasp-top10:2021', 'owasp-llm:2025',
                             'eu-ai-act:2024') AND scored) <> 6 THEN
        RAISE EXCEPTION 'migration 471: the six scored frameworks of 466 are not all seeded';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                WHERE conname IN ('requirement_framework_check', 'score_snapshot_framework_check')
                  AND connamespace = 'compliance'::regnamespace) THEN
        RAISE EXCEPTION 'migration 471: a hard-coded framework CHECK is still present';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_constraint
         WHERE conname IN ('requirement_framework_fkey', 'score_snapshot_framework_fkey') AND contype = 'f'
           AND connamespace = 'compliance'::regnamespace) <> 2 THEN
        RAISE EXCEPTION 'migration 471: the framework foreign keys are missing';
    END IF;
    IF (SELECT count(*) FROM shared.setting_definition
         WHERE key IN ('cis.compliance.validity_hours.cis_db', 'cis.compliance.validity_hours.crm_ops',
                       'cis.compliance.legal_docs_overdue_max', 'cis.compliance.erasure_drill_max_age_days',
                       'cis.compliance.retention_run_max_age_days', 'cis.compliance.retention_live_max_age_days',
                       'cis.compliance.consent_capture_max_age_days', 'cis.compliance.campaign_consent_violations_max',
                       'cis.compliance.campaign_consent_window_days',
                       'cis.compliance.applicability_review_max_age_days')
           AND guide IS NOT NULL) <> 10 THEN
        RAISE EXCEPTION 'migration 471: the ten new cis.compliance.* settings are not all seeded with a guide';
    END IF;
END
$check$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('471', now(), 'AA-1174: compliance.framework and compliance.applicability, law metadata on requirements, framework FKs instead of CHECKs, ten privacy evidence settings')
ON CONFLICT (version) DO NOTHING;

COMMIT;
