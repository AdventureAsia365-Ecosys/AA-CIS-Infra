-- Migration 479: AA-1173 (S290, compliance readiness phases 2-3; tech lead decisions of the S287 decision page, root
-- docs/audits/2026-11-21-S287-compliance-tracking/README.md sections 4 C.2 / C.3 / C.5 and 5 phases 2-3) — the
-- management layer of Platform › Compliance: exceptions with maker-checker and an expiry, the monthly posture review
-- record, the sealed-object reference on every evidence row, and the cis.compliance.* settings of the new evidence
-- sources (AWS nightly checks, the weekly Prowler scan), of the exceptions and of the review.
--
-- Why. Phase 1 (CIS 466 / 471) scores fresh, passing evidence only. Three gaps remain: (1) a control the business has
-- decided to live with for a while has nowhere to say so (the advisory: "accepted risk", approved by a second person,
-- with an expiry); (2) the monthly review the PDCA loop needs leaves no record an auditor can sample; (3) evidence now
-- lands in an Object Lock bucket (AA-CIS-Infra compliance_evidence.tf) and each row should name the sealed object it
-- came from and its SHA-256, so the row can be checked against the immutable copy.
--
-- What:
--   1. compliance.exception: one row per exception (subject = a control id, a check id or a vulnerability id; title,
--      reason, compensating control, risk level low | medium | high; proposed_by / proposed_at; expires_on; the
--      decision: decided_by, decided_at, decision_note, self_approved; revoked_by / revoked_at / revoke_note). Status
--      proposed -> approved | rejected, proposed | approved -> revoked; "expired" is derived (approved and expires_on
--      before today). A trigger refuses DELETE, TRUNCATE, any change of the proposal's own columns and any other status
--      move (the record an auditor samples); a CHECK refuses an approval by the proposer unless self_approved is set,
--      which the code only sets while cis.settings.two_person_approval is off (tech lead S287 Q13: one tech lead for
--      now; the page says "self-approved"). The longest expiry is the setting cis.compliance.exception_max_days (the
--      code checks it at proposal and at approval; the table only refuses an expiry on or before the proposal day).
--      Actors are staff ids ("admin:<id>"), never a customer: no personal data beyond the staff identity (DM-6.1).
--   2. compliance.review: one row per (kind, period): kind monthly_posture, period = the first day of the month
--      reviewed, summary = the numbers the page showed when the review was recorded (scores per framework, controls by
--      state, checks failing or stale, open and expired exceptions; counts and ids only, at most 16 KiB), notes and
--      actions (the reviewer's words), reviewed_by / reviewed_at. Append-only (trigger), like compliance.evidence.
--   3. compliance.evidence: two nullable columns, object_key (the key of the sealed bundle in the evidence bucket,
--      "evidence/<source>/..."; never a bucket name) and object_sha256 (its SHA-256, 64 hex), with CHECKs. Rows of
--      the docs reader file (phase 1) and of the API's own sources keep them NULL.
--   4. Grants: cis_app DML on the two new tables (explicit, besides the default privileges of 466); nothing for
--      aa_app_user or PUBLIC. The triggers keep both append-only / transition-only whatever the grant.
--   5. Five rows in shared.setting_definition, area compliance (settings-seed block below; the keys are named in
--      api/services/compliance_settings.py), each with its plain label and EN + VI guide (CIS 416 rule):
--        cis.compliance.validity_hours.aws_nightly     int hours 1-2160, default 48: how long a result of the nightly
--                                                      AWS read-only check counts
--        cis.compliance.validity_hours.prowler_weekly  int hours 1-2160, default 216 (9 days): the same for the weekly
--                                                      Prowler scan
--        cis.compliance.prowler_critical_high_max      int findings 0-100000, default 0: failing Prowler findings of
--                                                      severity critical or high the scan check tolerates
--        cis.compliance.exception_max_days             int days 1-365, default 90: the longest an exception may run
--        cis.compliance.review_max_age_days            int days 1-400, default 40: the newest monthly review must be at
--                                                      most this old for the review check to pass
--      Score-changing keys are maker_checker (as in 466 / 471); enforced (the code PR reads them).
--   6. A post-check, then register 479.
--
-- Behaviour on apply. None for running code: two new empty tables, two nullable columns nobody writes yet, config rows
-- nobody reads until the code PR (Platform › Compliance, tabs Exceptions and Reviews; the evidence store reader; the
-- job compliance_db_checks) is deployed.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): ALTER TABLE ADD COLUMN / ADD CONSTRAINT on an
-- existing table, trigger functions, config rows INSERTed into shared.setting_definition and a DO post-check are outside
-- the expand set. On Dev: Infra Migration Apply once every job table is idle (root ADR 0017a). MIG-4: this
-- migration-only PR, then the code PR (readiness raised to 479 there). Retention rows (DM-7.1) for compliance.exception
-- and compliance.review: root data standards Part B section 7, merged before the Infra copy.
--
-- Number. 477 is the highest on main on 24/11/2026 and 478 belongs to AA-1148 (S290 lane, merged first), so this is
-- 479 (MIG-4 chain: it merges after 478 is on main). If the owner main max + 1 differs at merge,
-- renumber everywhere (git grep '479_' and '479' in this repo: this file, tests/integration/test_aa1173_migration_479.py,
-- api/core/readiness.py in the code PR, docs/implementation-notes/AA-1173.md; the root data standards rows).
--
-- Locks. compliance.evidence (a few thousand rows): ADD COLUMN without default (catalog only), two ADD CONSTRAINT CHECK
-- (a short ACCESS EXCLUSIVE lock and a scan of a small table). New objects otherwise. lock_timeout 5s. Re-runnable (IF
-- NOT EXISTS, DROP ... IF EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING); one transaction, self-registering.
--
-- X1. One BEGIN … COMMIT block, no role switch (Migration Apply runs cis/ files as cis_owner, the owner of schema
-- compliance since 466).
--
-- Rollback (a new forward migration, after the code PR is reverted): drop the two tables and the two columns, DELETE
-- the five keys (their value rows first): a destructive file, DRY RUN (the exceptions and reviews are audit history).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- 1. compliance.exception ───────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS compliance.exception (
    exception_id  bigint      GENERATED ALWAYS AS IDENTITY,
    subject_kind  text        NOT NULL,
    subject_ref   text        NOT NULL,
    title         text        NOT NULL,
    reason        text        NOT NULL,
    compensating  text,
    risk_level    text        NOT NULL,
    status        text        NOT NULL DEFAULT 'proposed',
    proposed_by   text        NOT NULL,
    proposed_at   timestamptz NOT NULL DEFAULT now(),
    expires_on    date        NOT NULL,
    decided_by    text,
    decided_at    timestamptz,
    decision_note text,
    self_approved boolean     NOT NULL DEFAULT false,
    revoked_by    text,
    revoked_at    timestamptz,
    revoke_note   text,
    CONSTRAINT exception_pkey PRIMARY KEY (exception_id),
    CONSTRAINT exception_subject_kind_check CHECK (subject_kind IN ('control', 'check', 'vulnerability')),
    CONSTRAINT exception_subject_ref_check CHECK (subject_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$'),
    CONSTRAINT exception_title_check CHECK (char_length(title) BETWEEN 3 AND 160),
    CONSTRAINT exception_reason_check CHECK (char_length(reason) BETWEEN 20 AND 2000),
    CONSTRAINT exception_compensating_check CHECK (compensating IS NULL OR char_length(compensating) <= 2000),
    CONSTRAINT exception_risk_check CHECK (risk_level IN ('low', 'medium', 'high')),
    CONSTRAINT exception_status_check CHECK (status IN ('proposed', 'approved', 'rejected', 'revoked')),
    CONSTRAINT exception_actor_check CHECK (char_length(proposed_by) BETWEEN 1 AND 120
                                            AND (decided_by IS NULL OR char_length(decided_by) BETWEEN 1 AND 120)
                                            AND (revoked_by IS NULL OR char_length(revoked_by) BETWEEN 1 AND 120)),
    CONSTRAINT exception_expiry_check CHECK (expires_on > (proposed_at AT TIME ZONE 'UTC')::date),
    CONSTRAINT exception_note_check CHECK ((decision_note IS NULL OR char_length(decision_note) <= 1000)
                                           AND (revoke_note IS NULL OR char_length(revoke_note) BETWEEN 3 AND 1000)),
    -- a decided row names its decider; a proposed one has none
    CONSTRAINT exception_decision_check CHECK ((status = 'proposed') = (decided_by IS NULL AND decided_at IS NULL)
                                               OR (status = 'revoked' AND revoked_by IS NOT NULL)),
    -- maker-checker: the proposer approves only as a recorded self-approval (two-person approval off, Q13)
    CONSTRAINT exception_checker_check CHECK (decided_by IS NULL OR decided_by <> proposed_by OR self_approved),
    CONSTRAINT exception_self_check CHECK (NOT self_approved OR decided_by = proposed_by),
    CONSTRAINT exception_revoke_check CHECK ((status = 'revoked') = (revoked_by IS NOT NULL AND revoked_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS exception_subject_idx ON compliance.exception (subject_kind, subject_ref);
CREATE INDEX IF NOT EXISTS exception_status_idx ON compliance.exception (status, expires_on);
COMMENT ON TABLE compliance.exception IS
    'AA-1173 (CIS 479): accepted-risk exceptions of Platform > Compliance (a control, a check or a vulnerability), '
    'maker-checker with an expiry. Transition-only (trigger); expired is derived from expires_on.';
COMMENT ON COLUMN compliance.exception.self_approved IS
    'AA-1173 (479): the proposer approved it while cis.settings.two_person_approval was off (tech lead S287 Q13).';

CREATE OR REPLACE FUNCTION compliance.exception_guard() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP <> 'UPDATE' THEN
        RAISE EXCEPTION 'compliance.exception is an audit record (% refused)', TG_OP
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF (NEW.subject_kind, NEW.subject_ref, NEW.title, NEW.reason, NEW.compensating, NEW.risk_level, NEW.proposed_by,
        NEW.proposed_at, NEW.expires_on)
       IS DISTINCT FROM
       (OLD.subject_kind, OLD.subject_ref, OLD.title, OLD.reason, OLD.compensating, OLD.risk_level, OLD.proposed_by,
        OLD.proposed_at, OLD.expires_on) THEN
        RAISE EXCEPTION 'compliance.exception: the proposal cannot change once made (propose a new exception)'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NOT ((OLD.status = 'proposed' AND NEW.status IN ('approved', 'rejected', 'revoked'))
            OR (OLD.status = 'approved' AND NEW.status = 'revoked')) THEN
        RAISE EXCEPTION 'compliance.exception: % -> % is not a valid move', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'approved' AND (NEW.decided_by, NEW.decided_at, NEW.decision_note, NEW.self_approved)
            IS DISTINCT FROM (OLD.decided_by, OLD.decided_at, OLD.decision_note, OLD.self_approved) THEN
        RAISE EXCEPTION 'compliance.exception: the approval cannot change once made'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION compliance.exception_guard() FROM PUBLIC;
DROP TRIGGER IF EXISTS exception_guard_trg ON compliance.exception;
CREATE TRIGGER exception_guard_trg BEFORE UPDATE OR DELETE ON compliance.exception
    FOR EACH ROW EXECUTE FUNCTION compliance.exception_guard();
DROP TRIGGER IF EXISTS exception_no_truncate_trg ON compliance.exception;
CREATE TRIGGER exception_no_truncate_trg BEFORE TRUNCATE ON compliance.exception
    FOR EACH STATEMENT EXECUTE FUNCTION compliance.exception_guard();

-- 2. compliance.review ──────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS compliance.review (
    review_id   bigint      GENERATED ALWAYS AS IDENTITY,
    kind        text        NOT NULL,
    period      date        NOT NULL,
    summary     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    notes       text        NOT NULL,
    actions     text,
    reviewed_by text        NOT NULL,
    reviewed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT review_pkey PRIMARY KEY (review_id),
    CONSTRAINT review_once_key UNIQUE (kind, period),
    CONSTRAINT review_kind_check CHECK (kind IN ('monthly_posture')),
    CONSTRAINT review_period_check CHECK (extract(day FROM period) = 1),
    CONSTRAINT review_summary_check CHECK (jsonb_typeof(summary) = 'object' AND octet_length(summary::text) <= 16384),
    CONSTRAINT review_notes_check CHECK (char_length(notes) BETWEEN 20 AND 4000),
    CONSTRAINT review_actions_check CHECK (actions IS NULL OR char_length(actions) <= 4000),
    CONSTRAINT review_actor_check CHECK (char_length(reviewed_by) BETWEEN 1 AND 120)
);
COMMENT ON TABLE compliance.review IS
    'AA-1173 (CIS 479): the Security posture monthly review record (one per month): the numbers the page showed, the '
    'reviewer''s notes and actions. Append-only (trigger).';

CREATE OR REPLACE FUNCTION compliance.review_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'compliance.review is append-only (% refused)', TG_OP USING ERRCODE = 'insufficient_privilege';
END
$fn$;
REVOKE ALL ON FUNCTION compliance.review_append_only() FROM PUBLIC;
DROP TRIGGER IF EXISTS review_append_only_trg ON compliance.review;
CREATE TRIGGER review_append_only_trg BEFORE UPDATE OR DELETE ON compliance.review
    FOR EACH ROW EXECUTE FUNCTION compliance.review_append_only();
DROP TRIGGER IF EXISTS review_no_truncate_trg ON compliance.review;
CREATE TRIGGER review_no_truncate_trg BEFORE TRUNCATE ON compliance.review
    FOR EACH STATEMENT EXECUTE FUNCTION compliance.review_append_only();

-- 3. compliance.evidence: the sealed object ─────────────────────────────────────────────────────────────────────────
ALTER TABLE compliance.evidence ADD COLUMN IF NOT EXISTS object_key text;
ALTER TABLE compliance.evidence ADD COLUMN IF NOT EXISTS object_sha256 text;
ALTER TABLE compliance.evidence DROP CONSTRAINT IF EXISTS evidence_object_key_check;
ALTER TABLE compliance.evidence ADD CONSTRAINT evidence_object_key_check
    CHECK (object_key IS NULL OR (object_key ~ '^evidence/[a-z][a-z0-9_]{1,40}/[A-Za-z0-9._/-]{1,240}$'
                                  AND position('..' IN object_key) = 0));
ALTER TABLE compliance.evidence DROP CONSTRAINT IF EXISTS evidence_object_sha256_check;
ALTER TABLE compliance.evidence ADD CONSTRAINT evidence_object_sha256_check
    CHECK (object_sha256 IS NULL OR object_sha256 ~ '^[0-9a-f]{64}$');
COMMENT ON COLUMN compliance.evidence.object_key IS
    'AA-1173 (479): the key of the sealed bundle in the Object Lock evidence bucket this row came from (no bucket name).';
COMMENT ON COLUMN compliance.evidence.object_sha256 IS
    'AA-1173 (479): SHA-256 of that bundle, as listed in its source''s hash-chained manifest.';

-- 4. Grants ─────────────────────────────────────────────────────────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON compliance.exception, compliance.review TO cis_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA compliance TO cis_app;
REVOKE ALL ON compliance.exception, compliance.review FROM PUBLIC;

-- 5. Settings ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.compliance.validity_hours.aws_nightly", "app": "cis", "area": "compliance", "label": "Compliance: hours a nightly AWS check stays valid", "description": "Platform > Compliance (AA-1173): how many hours a result of the nightly AWS read-only check (AA-CIS-Infra workflow compliance-aws.yml: CloudTrail, S3 public access block, KMS rotation, IAM MFA, open security groups, RDS and ECR settings, the WAF rate rule, alarms on the alerts topic) counts after it was collected. Older evidence is stale: its check no longer passes and the Evidenced % of every framework it maps to drops.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 2160, "allowed_values": null, "default_value": 48, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long a result of the nightly AWS configuration check still counts as proof on the Compliance page.", "raise": "Proof stays valid longer; a nightly run that stopped is noticed later, because its old passes still count.", "lower": "Proof must be fresher; one missed nightly run turns the AWS checks stale and the score drops.", "when": "Keep it about two nights; set 1 hour only to show the stale path.", "example": "With the default 48, a check collected on Monday at 03:00 stops counting on Wednesday at 03:00."}, "vi": {"what": "Một kết quả của lượt kiểm cấu hình AWS hằng đêm còn được tính là bằng chứng trên trang Compliance trong bao lâu.", "raise": "Bằng chứng còn hiệu lực lâu hơn; lượt chạy hằng đêm bị ngừng được phát hiện muộn hơn vì các kết quả đạt cũ vẫn được tính.", "lower": "Bằng chứng phải mới hơn; lỡ một lượt chạy hằng đêm là các check AWS thành cũ và điểm giảm.", "when": "Giữ khoảng hai đêm; chỉ đặt 1 giờ khi muốn cho thấy đường cũ (stale).", "example": "Với mặc định 48, một check thu lúc 03:00 thứ Hai hết được tính lúc 03:00 thứ Tư."}}},
{"key": "cis.compliance.validity_hours.prowler_weekly", "app": "cis", "area": "compliance", "label": "Compliance: hours a weekly Prowler scan stays valid", "description": "Platform > Compliance (AA-1173): how many hours the result of the weekly Prowler scan of the AWS account (AA-CIS-Infra workflow compliance-aws.yml, free open source scanner, no Security Hub) counts after it was collected. Older, the scan checks are stale and the controls they feed drop.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 2160, "allowed_values": null, "default_value": 216, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long the result of the weekly Prowler scan still counts as proof on the Compliance page.", "raise": "An older scan still counts; a weekly scan that stopped is noticed later.", "lower": "The scan must be fresher; a single late weekly run turns its checks stale.", "when": "Keep it a little above one week plus a day or two of slack.", "example": "With the default 216 (nine days), a scan of Sunday 04:00 counts until Tuesday 04:00 of the next week but one."}, "vi": {"what": "Kết quả của lượt quét Prowler hằng tuần còn được tính là bằng chứng trên trang Compliance trong bao lâu.", "raise": "Lượt quét cũ hơn vẫn được tính; lượt quét hằng tuần bị ngừng được phát hiện muộn hơn.", "lower": "Lượt quét phải mới hơn; chỉ một lượt hằng tuần bị trễ là các check của nó thành cũ.", "when": "Giữ cao hơn một tuần cộng một hai ngày dự phòng.", "example": "Với mặc định 216 (chín ngày), lượt quét 04:00 Chủ nhật được tính tới 04:00 thứ Ba của tuần sau nữa."}}},
{"key": "cis.compliance.prowler_critical_high_max", "app": "cis", "area": "compliance", "label": "Compliance: critical or high Prowler findings tolerated", "description": "Platform > Compliance (AA-1173): the check prowler_critical_high passes while the newest weekly Prowler scan has at most this many failing findings of severity critical or high. More, the check fails and the cloud configuration controls it feeds drop. Findings the business accepted belong in an approved exception, not in a higher number here.", "value_type": "int", "unit": "findings", "min_value": 0, "max_value": 100000, "allowed_values": null, "default_value": 0, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How many failing critical or high findings the weekly Prowler scan may report while its check still passes.", "raise": "The check tolerates more serious findings; real cloud risks are less visible on the page.", "lower": "Every serious finding turns the check red.", "when": "Keep 0; accept a known finding through an exception with an expiry instead of raising this.", "example": "With the default 0, one high finding (an unencrypted bucket, say) fails the check."}, "vi": {"what": "Lượt quét Prowler hằng tuần được phép báo bao nhiêu phát hiện mức nghiêm trọng hoặc cao mà check vẫn đạt.", "raise": "Check chấp nhận nhiều phát hiện nghiêm trọng hơn; rủi ro cloud thật khó thấy hơn trên trang.", "lower": "Mỗi phát hiện nghiêm trọng đều làm check đỏ.", "when": "Giữ 0; chấp nhận một phát hiện đã biết bằng ngoại lệ có hạn thay vì tăng số này.", "example": "Với mặc định 0, một phát hiện mức cao (ví dụ một bucket không mã hoá) làm check không đạt."}}},
{"key": "cis.compliance.exception_max_days", "app": "cis", "area": "compliance", "label": "Compliance: longest an exception may run", "description": "Platform > Compliance (AA-1173): the expiry date of a compliance exception (an accepted risk on a control, a check or a vulnerability) may be at most this many days after the day it is proposed; an approval re-checks it. A shorter window forces the risk to be looked at again sooner.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 365, "allowed_values": null, "default_value": 90, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "The longest time an accepted risk may stay accepted before it must be proposed and approved again.", "raise": "Exceptions may run longer; a risk accepted once is looked at less often.", "lower": "Exceptions expire sooner and must be renewed with a fresh reason.", "when": "Keep about a quarter, so each exception comes up again at the next quarterly review.", "example": "With the default 90, an exception proposed on 1 December can run until 1 March at the latest."}, "vi": {"what": "Thời gian dài nhất một rủi ro được chấp nhận còn hiệu lực trước khi phải đề xuất và duyệt lại.", "raise": "Ngoại lệ chạy lâu hơn; rủi ro đã chấp nhận ít được xem lại hơn.", "lower": "Ngoại lệ hết hạn sớm hơn và phải gia hạn với lý do mới.", "when": "Giữ khoảng một quý, để mỗi ngoại lệ được xem lại ở lần rà soát quý kế tiếp.", "example": "Với mặc định 90, ngoại lệ đề xuất ngày 1 tháng 12 chạy được muộn nhất tới ngày 1 tháng 3."}}},
{"key": "cis.compliance.review_max_age_days", "app": "cis", "area": "compliance", "label": "Compliance: days a monthly posture review counts", "description": "Platform > Compliance (AA-1173): the check monthly_review_recent passes while the newest Security posture monthly review recorded on the page is at most this many days old. Older, the check fails and the management review controls it feeds drop.", "value_type": "int", "unit": "days", "min_value": 1, "max_value": 400, "allowed_values": null, "default_value": 40, "scope_kind": "platform", "impact": "medium", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How recent the last recorded monthly posture review must be for the review check to pass.", "raise": "An older review still counts; months without a review go unnoticed longer.", "lower": "Reviews must be recorded more promptly each month to keep the check green.", "when": "Keep a little above one month, so a review recorded early in each month keeps the check green.", "example": "With the default 40, a review recorded on 3 November counts until 13 December."}, "vi": {"what": "Lần rà soát tư thế bảo mật hằng tháng gần nhất phải mới tới đâu thì check rà soát mới đạt.", "raise": "Lần rà soát cũ hơn vẫn được tính; tháng không rà soát bị phát hiện muộn hơn.", "lower": "Phải ghi rà soát đúng hạn hơn mỗi tháng để giữ check xanh.", "when": "Giữ cao hơn một tháng một chút, để rà soát ghi đầu mỗi tháng giữ check xanh.", "example": "Với mặc định 40, lần rà soát ghi ngày 3 tháng 11 được tính tới ngày 13 tháng 12."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- 6. Post-check ─────────────────────────────────────────────────────────────────────────────────────────────────────
DO $check$
DECLARE
    bad text;
BEGIN
    SELECT string_agg(t, ', ') INTO bad
      FROM unnest(ARRAY['compliance.exception', 'compliance.review']) AS t
     WHERE has_table_privilege('aa_app_user', t, 'SELECT, INSERT, UPDATE, DELETE')
        OR NOT has_table_privilege('cis_app', t, 'SELECT, INSERT, UPDATE');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 479: grants are not cis_app DML only on %', bad;
    END IF;
    IF (SELECT count(*) FROM information_schema.columns
         WHERE table_schema = 'compliance' AND table_name = 'evidence'
           AND column_name IN ('object_key', 'object_sha256')) <> 2 THEN
        RAISE EXCEPTION 'migration 479: compliance.evidence lacks object_key / object_sha256';
    END IF;
    IF (SELECT count(*) FROM shared.setting_definition
         WHERE key IN ('cis.compliance.validity_hours.aws_nightly', 'cis.compliance.validity_hours.prowler_weekly',
                       'cis.compliance.prowler_critical_high_max', 'cis.compliance.exception_max_days',
                       'cis.compliance.review_max_age_days')
           AND guide IS NOT NULL) <> 5 THEN
        RAISE EXCEPTION 'migration 479: the five cis.compliance.* settings are not all seeded with a guide';
    END IF;
END
$check$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('479', now(), 'AA-1173: compliance exceptions (maker-checker, expiry), monthly posture reviews, sealed object on evidence, five cis.compliance.* settings')
ON CONFLICT (version) DO NOTHING;

COMMIT;
