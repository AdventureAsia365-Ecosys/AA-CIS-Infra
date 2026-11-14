-- Migration 425: AA-1105 (S281) — the per-visitor limit of the academy web's public certificate checks in the platform
-- settings registry (CIS 407; tech lead S279: a threshold, limit or cap is a setting on Platform › Settings, never a
-- code literal or an env var alone).
--
-- Why. The academy web (AA-Partner CRM web, academy host) calls the public verify route
-- GET /learn/public/v1/certificates/{code} from its server, so behind its NAT every visitor reaches CIS from one
-- address and CIS's per-address limit (cis.learn.verify_requests_per_minute, CIS 420) is a cap for the whole web: one
-- visitor reloading the verify page in a loop would use it up and every other visitor would be refused. The web
-- therefore limits each of its own visitors before it calls CIS, and it needs that limit from a real, editable source
-- that is lower than the per-address cap (S281 review of the academy web). This key is that limit; the learning API
-- sends it on every verify answer (response header X-Learn-Visitor-Limit, contract learn.http.v1 1.1), clamped to the
-- per-address limit minus one, so one visitor can never take the web's whole budget.
--
-- What:
--   1. One row in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py into
--      shared/settings/compiled_defaults.json in this PR):
--        cis.learn.verify_visitor_requests_per_minute   int 1..300 requests, default 6, platform, impact medium,
--                                                       single approval, no evidence, no env override, cache 60 s
--      The seed row carries its plain label and its EN + VI operator guide (CIS 416 rule). Seeded with enforced =
--      false like the twelve other cis.learn.* keys (CIS 420): the learning API code that reads it ships in the next PR
--      of this lane (MIG-4); the later migration that marks the learn keys enforced covers this one too.
--   2. Register 425.
--
-- Behaviour on apply. None for running code: no value row is seeded, and the deployed learning API does not read the
-- key yet; after the code PR it resolves to its default (6) until an administrator approves a change.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a config row INSERTed into an existing table.
-- MIG-4: a migration-only PR (it joins the wave's CIS migration batch), applied on Dev by Infra Migration Apply when the
-- job tables are idle (ADR 0017a), then the code PR. DM-7.1: no new table.
--
-- Number. 422 is the newest CIS migration on main (15/11/2026); other lanes of the S281 wave hold 423-428. If the
-- owner main max + 1 differs at merge, renumber (git grep '425_' and '425' here, in
-- tests/integration/test_aa1105_migration_425.py, tests/integration/test_aa1105_migration_420.py,
-- compiled_defaults.json's _generated line and docs/implementation-notes/AA-1105.md).
--
-- Locks. One INSERT of one row (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
-- Idempotent (ON CONFLICT (key) DO NOTHING), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE the key's value rows first, then the key.

BEGIN;
SET LOCAL lock_timeout = '5s';

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$[
{"key": "cis.learn.verify_visitor_requests_per_minute", "app": "cis", "area": "learn", "label": "Academy: certificate checks per minute for one visitor of the academy web", "description": "ADR 0022 decision 11: the academy web calls the public verify route /learn/public/v1/certificates/{code} from its server, so all its visitors reach CIS from one address and cis.learn.verify_requests_per_minute caps the whole web. This is how many verify requests one visitor of the academy web may make per minute: CIS sends it on every verify answer (response header X-Learn-Visitor-Limit, contract learn.http.v1) and the academy web refuses a visitor over it before it calls CIS. CIS sends at most the per-address limit minus one, so one visitor can never use up the web's whole budget. Read by the AA Academy learning API from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "requests", "min_value": 1, "max_value": 300, "allowed_values": null, "default_value": 6, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How many certificate checks one visitor of the academy web may make per minute on the public verify page. All visitors of the academy web share the per-address limit (certificate checks per minute), so this smaller number keeps one visitor from using all of it.", "raise": "A visitor who checks many certificates in a row is told to wait less often, but fewer such visitors fit in the shared per-address limit before everyone is told to wait. It never goes above the per-address limit minus one, whatever this says.", "lower": "One visitor reloading the page in a loop uses less of the shared limit, so other visitors keep their checks, but a visitor checking a batch of certificates by hand is told to wait sooner.", "when": "Raise it if a partner checking a batch of certificates on the academy web is told to wait; lower it if the logs show one visitor reloading the verify page in a loop while others are refused.", "example": "With the default of 6 and the per-address limit at its default of 30: the 7th check within one minute from the same visitor waits until the minute ends, and five such visitors together still leave room for others."}, "vi": {"what": "Số lần mỗi phút một người truy cập trang academy được kiểm chứng chỉ trên trang xác minh công khai. Mọi người truy cập trang academy dùng chung giới hạn theo địa chỉ (số lần kiểm chứng chỉ mỗi phút), nên con số nhỏ hơn này giữ cho một người không dùng hết giới hạn chung đó.", "raise": "Người kiểm nhiều chứng chỉ liên tiếp ít bị báo chờ hơn, nhưng giới hạn chung theo địa chỉ chứa được ít người như vậy hơn trước khi mọi người bị báo chờ. Giá trị gửi đi không bao giờ vượt quá giới hạn theo địa chỉ trừ một, dù ở đây đặt bao nhiêu.", "lower": "Một người tải lại trang liên tục chỉ dùng ít phần của giới hạn chung, nên người khác vẫn kiểm được, nhưng người kiểm cả loạt chứng chỉ bằng tay sẽ bị báo chờ sớm hơn.", "when": "Tăng nếu một đối tác kiểm cả loạt chứng chỉ trên trang academy bị báo chờ; giảm nếu nhật ký cho thấy một người tải lại trang xác minh liên tục trong khi người khác bị từ chối.", "example": "Với mặc định 6 và giới hạn theo địa chỉ ở mặc định 30: lần kiểm thứ 7 trong một phút của cùng một người phải chờ hết phút đó, và năm người như vậy cùng lúc vẫn chừa chỗ cho người khác."}}}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('425', now(), 'AA-1105: the academy web per-visitor certificate check limit (cis.learn.verify_visitor_requests_per_minute)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
