-- Migration 428: AA-1090 (TripPlanner R8, root ADR 0019 b4 "higher tier = custom domain", tech lead S278 D10 / D13
-- NEW-D) — a tenant's own domain for its TripPlanner site: the table shared.tenant_tripplanner_domain and the six
-- custom-domain settings of the platform settings registry.
--
-- Why. Today an agency's planner lives on our path /{slug} (ADR 0019 d10). R8 lets the agency serve it on its own
-- host (trip.<agency domain>): staff add the domain on Tenant 360 › Subscription, the page shows the two DNS records
-- the agency creates (a CNAME of the host to the TripPlanner agency CloudFront distribution, a distribution of its own
-- apart from the public TripPlanner host, and the ACM validation CNAME),
-- and the CIS job tripplanner_custom_domain requests the ACM certificate (us-east-1, DNS validation), polls it, and
-- attaches
-- the host as an alternate domain name of the distribution (AA-CIS-Infra grants the CIS task role exactly that).
-- TripPlanner resolves a request's Host to the tenant through catalog.v_tenant_tripplanner_v1.custom_domains (CIS 429).
--
-- What:
--   1. shared.tenant_tripplanner_domain: one row per custom host of a tenant's TripPlanner site:
--        domain_id        uuid, the key (the job payload and the Tenant 360 row id);
--        tenant_id        the tenant (FK shared.tenants, ON DELETE CASCADE as the erasure backstop; the job then
--                         detaches an alias that has no row any more on its next run);
--        domain           the host, lower-case letters / digits / hyphens in dot-separated labels, at most 253
--                         characters, unique across every tenant (one host is one site);
--        status           pending (added, no certificate yet) | validating (the certificate waits for the agency's
--                         validation record) | attaching (validated; the job puts it on the distribution) | active
--                         (served) | removing (staff removed it; the job detaches the alias and deletes the
--                         certificate, then deletes the row) | failed (failure_code / failure_message say why; staff
--                         retry or remove it);
--        certificate_arn  the ACM certificate of this host (us-east-1, the region CloudFront reads), NULL before the
--                         request; validation_name / validation_value: the CNAME record ACM asks for;
--        cname_target     the distribution's domain name (*.cloudfront.net), the CNAME value of the host;
--        failure_code / failure_message, requested_at / validated_at / active_at, updated_at / updated_by (the actor:
--                         admin:<admin_users.id> or job:tripplanner_custom_domain:<job id>, never an e-mail).
--      No personal data (an agency's business host). No RLS, like the other R1 / R5 control-plane tables of shared
--      (shared.tenant_tripplanner_site, 379; shared.tenant_addon_request, 374): read and written only by the CIS API
--      and the CIS worker as cis_app, read by TripPlanner only through the catalog view, never by a tenant role (rls
--      catalogue rule a allowlist, tests/integration/rls_catalogue_rules.py; the 244 guard keeps the shared RLS table
--      set fixed). Grants: REVOKE ALL first (the Dev default ACL of cis_owner in shared, CIS 245), then cis_app SELECT,
--      INSERT, UPDATE, DELETE (the Tenant 360 editor, the job, the AA-839 tenant erasure). catalog_owner's column read
--      for the view is CIS 429.
--   2. Six rows in shared.setting_definition, area tripplanner (seed block below, read by
--      scripts/settings/gen_compiled_defaults.py into shared/settings/compiled_defaults.json in this PR), each with its
--      plain label and EN + VI guide (CIS 416):
--        cis.tripplanner.custom_domain_max_per_tenant          int domains 0..10, default 1, platform + tenant
--        cis.tripplanner.custom_domain_edge_max                int domains 0..100, default 10, maker-checker
--        cis.tripplanner.custom_domain_validation_timeout_hours int hours 1..72, default 72
--        cis.tripplanner.custom_domain_poll_seconds            duration_s 30..600, default 120
--        cis.tripplanner.custom_domain_edge_pending_hours      int hours 1..24, default 6 (a re-issued agency-edge
--                                                              certificate still pending: detach the host whose
--                                                              validation record is gone)
--        cis.tripplanner.custom_domain_renewal_grace_days      int days 7..59, default 30 (the daily edge check
--                                                              detaches a host that blocks ACM renewal this close
--                                                              to expiry; alert at once)
--      Seeded with enforced = false: the code that reads them ships in the next PR of this lane (MIG-4), and the
--      settings-lint guard refuses an enforced key that no code reads. A later migration marks them enforced.
--   3. A post-check, then register 428.
--
-- Behaviour on apply. None for running code: an empty table, nothing reads it or the keys until the AA-1090 CIS code
-- is deployed; then each key resolves to its default until an administrator approves a change.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): a new table with a tenant_id and RLS off on
-- purpose (rule a allowlist), REVOKE, config
-- rows INSERTed into an existing table and a DO post-check are outside the expand set. MIG-4: a migration-only PR in
-- the wave's CIS migration batch (with 429); applied on Dev by Infra Migration Apply when the job tables are idle
-- (ADR 0017a). DM-7.1: the retention row of shared.tenant_tripplanner_domain comes in a root PR that is on root master
-- before the Infra bot copy PR of 428.
--
-- Number. Main ends at 427 (15/11/2026, 427_aa1051_settings_enforced_keys), so this batch takes 428 and 429.
-- If the owner main max + 1 differs at merge, renumber (git grep '428_' and '428' here, in
-- tests/integration/test_aa1090_migrations_428_429.py, compiled_defaults.json, the seed-parity test and 429's guard).
--
-- Locks. One CREATE TABLE and its index, one INSERT of six rows into shared.setting_definition (the definition
-- guard trigger allows the file's role, cis_owner). lock_timeout 5s, statement_timeout 1min. Idempotent (IF NOT EXISTS,
-- ON CONFLICT (key) DO NOTHING), one transaction, self-registering. Replayed by the
-- integration conftest like any file (no catalog recipe).
--
-- Rollback (a new forward migration, after the AA-1090 code is reverted and every domain removed through the job, so
-- no certificate or alias is left behind): DELETE the six keys (no value row can exist before the code reads them);
-- a destructive file (DRY RUN) for DROP TABLE shared.tenant_tripplanner_domain.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('aa.actor', 'migration:428', true);

-- ── 1. The custom-domain table ───────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shared.tenant_tripplanner_domain (
    domain_id         uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id         uuid        NOT NULL,
    domain            text        NOT NULL,
    status            text        NOT NULL DEFAULT 'pending',
    certificate_arn   text,
    validation_name   text,
    validation_value  text,
    cname_target      text,
    failure_code      text,
    failure_message   text,
    requested_at      timestamptz NOT NULL DEFAULT now(),
    validated_at      timestamptz,
    active_at         timestamptz,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        text        NOT NULL,
    CONSTRAINT tenant_tripplanner_domain_pkey PRIMARY KEY (domain_id),
    CONSTRAINT tenant_tripplanner_domain_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES shared.tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT tenant_tripplanner_domain_domain_key UNIQUE (domain),
    CONSTRAINT tenant_tripplanner_domain_domain_chk CHECK (
        char_length(domain) BETWEEN 4 AND 253
        AND domain ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'),
    CONSTRAINT tenant_tripplanner_domain_status_chk CHECK (
        status IN ('pending', 'validating', 'attaching', 'active', 'removing', 'failed')),
    CONSTRAINT tenant_tripplanner_domain_cert_chk CHECK (
        certificate_arn IS NULL OR certificate_arn ~ '^arn:aws:acm:us-east-1:[0-9]{12}:certificate/[0-9a-f-]{36}$'),
    CONSTRAINT tenant_tripplanner_domain_validation_chk CHECK (
        (validation_name IS NULL OR char_length(validation_name) BETWEEN 1 AND 255)
        AND (validation_value IS NULL OR char_length(validation_value) BETWEEN 1 AND 255)),
    CONSTRAINT tenant_tripplanner_domain_target_chk CHECK (
        cname_target IS NULL OR cname_target ~ '^[a-z0-9]+\.cloudfront\.net$'),
    CONSTRAINT tenant_tripplanner_domain_failure_chk CHECK (
        (failure_code IS NULL OR failure_code ~ '^[a-z][a-z0-9_]{0,63}$')
        AND (failure_message IS NULL OR char_length(failure_message) <= 500)),
    CONSTRAINT tenant_tripplanner_domain_actor_chk CHECK (char_length(updated_by) BETWEEN 1 AND 64)
);

CREATE INDEX IF NOT EXISTS tenant_tripplanner_domain_tenant_idx ON shared.tenant_tripplanner_domain (tenant_id);

COMMENT ON TABLE shared.tenant_tripplanner_domain IS
    'AA-1090 TripPlanner R8 (CIS 428, root ADR 0019 b4): the custom hosts of a tenant''s TripPlanner site. Staff add a '
    'host on Tenant 360; the CIS job tripplanner_custom_domain requests its ACM certificate (us-east-1), waits for the '
    'agency''s validation record and attaches the host to the TripPlanner CloudFront distribution. TripPlanner serves '
    'an active host through catalog.v_tenant_tripplanner_v1.custom_domains (CIS 429). No personal data.';
COMMENT ON COLUMN shared.tenant_tripplanner_domain.status IS
    'AA-1090 (428): pending | validating | attaching | active | removing | failed. Only active is served; removing '
    'rows are deleted by the job once the alias is detached and the certificate deleted.';
COMMENT ON COLUMN shared.tenant_tripplanner_domain.updated_by IS
    'AA-1090 (428): admin:<admin_users.id>, job:tripplanner_custom_domain:<job id> or migration:<n>. Never an e-mail.';

-- ── Grants (REVOKE first: the Dev default ACL of cis_owner in shared, CIS 245) ─────────────────────────────────────
REVOKE ALL ON shared.tenant_tripplanner_domain FROM PUBLIC, cis_app, aa_app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON shared.tenant_tripplanner_domain TO cis_app;

-- ── 2. The custom-domain settings ────────────────────────────────────────────────────────────────────────────────
-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$[
{"key": "cis.tripplanner.custom_domain_max_per_tenant", "app": "cis", "area": "tripplanner", "label": "Trip planner: own domains per agency", "description": "The most custom hosts (for example trip.<agency domain>) one agency may have on its TripPlanner site at a time, counting every host that is not being removed. Tenant 360 refuses to add one more. A per-agency value overrides the platform value (the higher tier of ADR 0019 b4). Read by the Tenant 360 custom-domain editor from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "domains", "min_value": 0, "max_value": 10, "allowed_values": null, "default_value": 1, "scope_kind": "platform+tenant", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How many of its own web addresses (for example trip.agency-name.com) one agency can use for its trip planner at the same time, instead of the address on our site. An agency can be given its own number.", "raise": "An agency can run its planner on several addresses (for example one per brand or language), but each address uses one of the limited places on the shared certificate.", "lower": "Fewer addresses per agency keep places free for other agencies; an agency at the limit must remove an address before adding another.", "when": "Raise it for one agency when its contract includes more addresses; lower the platform value when the shared limit below is nearly used up.", "example": "With the default of 1, an agency that already serves trip.agency-name.com cannot add a second address until the first is removed."}, "vi": {"what": "Số địa chỉ web riêng (ví dụ trip.ten-dai-ly.com) một đại lý được dùng cùng lúc cho trang lập lịch trình của mình, thay cho địa chỉ trên trang của chúng ta. Có thể đặt con số riêng cho từng đại lý.", "raise": "Một đại lý chạy trang lập lịch trình trên nhiều địa chỉ (ví dụ mỗi thương hiệu hay mỗi ngôn ngữ một địa chỉ), nhưng mỗi địa chỉ chiếm một chỗ trong số chỗ có hạn trên chứng chỉ dùng chung.", "lower": "Mỗi đại lý ít địa chỉ hơn thì còn chỗ cho đại lý khác; đại lý đã chạm giới hạn phải gỡ một địa chỉ rồi mới thêm được địa chỉ khác.", "when": "Tăng cho một đại lý khi hợp đồng của họ có thêm địa chỉ; giảm giá trị chung khi giới hạn dùng chung bên dưới sắp hết.", "example": "Với mặc định 1, đại lý đang dùng trip.ten-dai-ly.com chưa thêm được địa chỉ thứ hai cho tới khi gỡ địa chỉ đầu."}}},
{"key": "cis.tripplanner.custom_domain_edge_max", "app": "cis", "area": "tripplanner", "label": "Trip planner: own domains on the agency edge", "description": "The most custom hosts of all agencies together on the TripPlanner agency CloudFront distribution (a distribution of its own, apart from the public TripPlanner host). Every attached host is one name on the one certificate that distribution serves, and ACM allows 10 names per certificate unless AWS raises the account quota (up to 100). Tenant 360 refuses a new host beyond this number. Read by the Tenant 360 custom-domain editor and the tripplanner_custom_domain job from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "domains", "min_value": 0, "max_value": 100, "allowed_values": null, "default_value": 10, "scope_kind": "platform", "impact": "high", "approval": "maker_checker", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How many agency web addresses, all agencies together, the trip planner can serve. All of them share one security certificate, and Amazon allows a limited number of names on one certificate (10 unless Amazon raises it for our account). Our own planner address is not on it.", "raise": "More agencies can use their own address, but only after Amazon has raised the names-per-certificate limit for our account; above that limit a new address fails when it is attached.", "lower": "No new agency address is accepted once the number in use reaches it; addresses already served keep working.", "when": "Raise it only after Amazon confirmed a higher names-per-certificate limit, at most to that limit; lower it to stop new addresses while the edge is reworked.", "example": "With the default of 10, the eleventh agency address is refused until one of the ten is removed."}, "vi": {"what": "Số địa chỉ web của đại lý, tính chung mọi đại lý, mà trang lập lịch trình phục vụ được. Tất cả dùng chung một chứng chỉ bảo mật, và Amazon chỉ cho một số tên có hạn trên một chứng chỉ (10, trừ khi Amazon nâng cho tài khoản của chúng ta). Địa chỉ planner của chính chúng ta không nằm trên chứng chỉ này.", "raise": "Nhiều đại lý dùng được địa chỉ riêng hơn, nhưng chỉ sau khi Amazon đã nâng giới hạn số tên trên một chứng chỉ cho tài khoản của chúng ta; vượt giới hạn đó thì địa chỉ mới bị lỗi lúc gắn.", "lower": "Không nhận thêm địa chỉ đại lý nào khi số đang dùng chạm mức này; các địa chỉ đang chạy vẫn hoạt động.", "when": "Chỉ tăng sau khi Amazon xác nhận giới hạn số tên cao hơn, tối đa bằng giới hạn đó; giảm để dừng nhận địa chỉ mới trong lúc sửa lại phần biên.", "example": "Với mặc định 10, địa chỉ đại lý thứ mười một bị từ chối cho tới khi gỡ một trong mười địa chỉ."}}},
{"key": "cis.tripplanner.custom_domain_validation_timeout_hours", "app": "cis", "area": "tripplanner", "label": "Trip planner: hours to wait for the agency's DNS record", "description": "How long the tripplanner_custom_domain job waits for an agency's ACM validation record after it requested the certificate. Past it the host is failed with validation_timeout and its certificate deleted; staff retry it once the agency created the record. ACM itself stops at 72 hours. Read by the tripplanner_custom_domain job from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 72, "allowed_values": null, "default_value": 72, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How long the system waits for an agency to add the DNS record that proves it owns the address it asked for. After that the address is marked failed and staff can try again.", "raise": "Agencies that need a few days to change their DNS do not have to start over, but a forgotten request stays open longer.", "lower": "Forgotten requests are closed sooner, but an agency that is slow to add the record has to be retried.", "when": "Lower it when many requests are left unfinished; keep it at the maximum while agencies set up their DNS through a third party.", "example": "With the default of 72, an address requested on Monday 09:00 fails on Thursday 09:00 if the record is still missing."}, "vi": {"what": "Thời gian hệ thống chờ đại lý thêm bản ghi DNS chứng minh họ sở hữu địa chỉ đã xin. Quá thời gian đó địa chỉ bị đánh dấu thất bại và nhân viên có thể thử lại.", "raise": "Đại lý cần vài ngày để sửa DNS không phải làm lại từ đầu, nhưng một yêu cầu bị quên sẽ treo lâu hơn.", "lower": "Yêu cầu bị quên được đóng sớm hơn, nhưng đại lý thêm bản ghi chậm sẽ phải được thử lại.", "when": "Giảm khi nhiều yêu cầu bị bỏ dở; giữ ở mức tối đa khi đại lý sửa DNS qua một bên thứ ba.", "example": "Với mặc định 72, địa chỉ xin lúc 09:00 thứ Hai sẽ thất bại lúc 09:00 thứ Năm nếu vẫn chưa có bản ghi."}}},
{"key": "cis.tripplanner.custom_domain_poll_seconds", "app": "cis", "area": "tripplanner", "label": "Trip planner: seconds between custom-domain checks", "description": "How long the tripplanner_custom_domain job waits before it looks again at a certificate that is still pending validation or a distribution change that is still deploying (the job reschedules itself; the job runner caps one wait at 600 seconds). Each look is one free ACM or CloudFront read. Read by the tripplanner_custom_domain job from the release that ships it; marked enforced by a later migration.", "value_type": "duration_s", "unit": "seconds", "min_value": 30, "max_value": 600, "allowed_values": null, "default_value": 120, "scope_kind": "platform", "impact": "low", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "guide": {"en": {"what": "How often the system checks whether an agency's DNS record has been seen and whether the address has been put live, while a new address is being set up.", "raise": "Fewer checks run, but an address goes live a little later after the agency added its record.", "lower": "An address goes live sooner after the record appears, with more (free) checks against Amazon.", "when": "Lower it during a guided setup with an agency on the phone; raise it if the job list shows many waiting checks.", "example": "With the default of 120, an address whose record appears at 10:00 is noticed by 10:02 at the latest."}, "vi": {"what": "Khoảng thời gian giữa hai lần hệ thống kiểm tra xem bản ghi DNS của đại lý đã có chưa và địa chỉ đã được đưa vào chạy chưa, trong lúc cài đặt một địa chỉ mới.", "raise": "Ít lần kiểm tra hơn, nhưng địa chỉ chạy muộn hơn một chút sau khi đại lý đã thêm bản ghi.", "lower": "Địa chỉ chạy sớm hơn sau khi bản ghi xuất hiện, đổi lại nhiều lần kiểm tra (miễn phí) với Amazon hơn.", "when": "Giảm trong lúc hướng dẫn đại lý cài đặt qua điện thoại; tăng nếu danh sách job có nhiều lượt kiểm tra đang chờ.", "example": "Với mặc định 120, địa chỉ có bản ghi xuất hiện lúc 10:00 sẽ được nhận ra chậm nhất lúc 10:02."}}},
{"key": "cis.tripplanner.custom_domain_edge_pending_hours", "app": "cis", "area": "tripplanner", "allowed_values": null, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "label": "Trip planner: hours an agency-edge certificate may wait", "description": "When an agency host is added or removed, the tripplanner_custom_domain job requests a new certificate for the agency CloudFront distribution naming every attached host; ACM issues it within minutes while each host's validation record is still in that agency's DNS. If it is still pending validation after this many hours, the job fails and detaches the hosts whose record ACM cannot find (failure code validation_record_gone, a staff alert) and requests the certificate again without them, so one agency's missing record never blocks the others. Read by the tripplanner_custom_domain job from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "hours", "min_value": 1, "max_value": 24, "default_value": 6, "guide": {"en": {"what": "How long the system waits for a new shared certificate of the agency addresses before it decides that an agency removed its DNS record, takes that agency's address off line and goes on without it.", "raise": "An agency whose DNS is briefly broken gets more time before its address is taken off line, but other agencies' new or removed addresses wait as long.", "lower": "Other agencies' changes go through sooner, but an agency with a short DNS problem loses its address sooner and staff must retry it.", "when": "Keep the default; lower it if a change for one agency is held up by another agency's DNS.", "example": "With the default of 6, an address added at 09:00 that waits for another agency's missing record goes live by about 15:00 without that agency's address."}, "vi": {"what": "Thời gian hệ thống chờ chứng chỉ dùng chung mới của các địa chỉ đại lý, trước khi kết luận một đại lý đã xoá bản ghi DNS, đưa địa chỉ của đại lý đó ra khỏi trạng thái chạy và làm tiếp mà không có nó.", "raise": "Đại lý bị lỗi DNS ngắn có thêm thời gian trước khi địa chỉ bị gỡ, nhưng việc thêm hoặc gỡ địa chỉ của đại lý khác cũng phải chờ lâu như vậy.", "lower": "Thay đổi của đại lý khác đi qua nhanh hơn, nhưng đại lý bị lỗi DNS ngắn mất địa chỉ sớm hơn và nhân viên phải thử lại.", "when": "Giữ mặc định; giảm nếu thay đổi của một đại lý bị kẹt vì DNS của đại lý khác.", "example": "Với mặc định 6, địa chỉ thêm lúc 09:00 mà phải chờ bản ghi bị thiếu của đại lý khác sẽ chạy khoảng 15:00, không còn địa chỉ của đại lý kia."}}},
{"key": "cis.tripplanner.custom_domain_renewal_grace_days", "app": "cis", "area": "tripplanner", "allowed_values": null, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": false, "label": "Trip planner: days before expiry to drop an agency domain that blocks renewal", "description": "ACM renews the agency-edge certificate by itself only while every agency keeps its validation record. The daily edge check of the tripplanner_custom_domain job reads the renewal status: when a host blocks renewal it raises a staff alert at once, and once the certificate expires within this many days it fails and detaches that host (failure code validation_record_gone) and replaces the certificate without it, so the other agencies never serve an expired certificate. ACM starts renewal 60 days before expiry. Read by the tripplanner_custom_domain job from the release that ships it; marked enforced by a later migration.", "value_type": "int", "unit": "days", "min_value": 7, "max_value": 59, "default_value": 30, "guide": {"en": {"what": "How close to the expiry of the shared certificate of the agency addresses the system waits for an agency to put back a missing DNS record, before it takes that agency's address off line so the certificate can be renewed for everyone else.", "raise": "The address of an agency with a missing record is taken off line sooner, with more time left to renew the certificate for the others.", "lower": "An agency gets longer to fix its record after the alert, with less time left before the certificate expires.", "when": "Keep the default; raise it if renewals have come close to the expiry date.", "example": "With the default of 30, an agency whose record went missing gets an alert at once and its address is taken off line 30 days before the certificate expires if the record is still missing."}, "vi": {"what": "Hệ thống chờ đại lý đặt lại bản ghi DNS bị thiếu tới khi chứng chỉ dùng chung của các địa chỉ đại lý còn bao nhiêu ngày thì hết hạn, trước khi gỡ địa chỉ của đại lý đó để gia hạn chứng chỉ cho mọi đại lý khác.", "raise": "Địa chỉ của đại lý thiếu bản ghi bị gỡ sớm hơn, còn nhiều thời gian hơn để gia hạn chứng chỉ cho các đại lý khác.", "lower": "Đại lý có thêm thời gian sửa bản ghi sau cảnh báo, đổi lại còn ít thời gian hơn trước khi chứng chỉ hết hạn.", "when": "Giữ mặc định; tăng nếu các lần gia hạn từng sát ngày hết hạn.", "example": "Với mặc định 30, đại lý bị thiếu bản ghi nhận cảnh báo ngay và địa chỉ bị gỡ 30 ngày trước khi chứng chỉ hết hạn nếu vẫn thiếu bản ghi."}}}
]$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

-- ── 3. Post-check ────────────────────────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    t constant text := 'shared.tenant_tripplanner_domain';
    bad text;
    refused integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE oid = t::regclass AND relrowsecurity) THEN
        RAISE EXCEPTION 'migration 428: % has row-level security on (the 244 guard keeps the shared RLS set fixed)', t;
    END IF;
    IF NOT pg_catalog.has_table_privilege('cis_app', t, 'SELECT, INSERT, UPDATE, DELETE')
       OR pg_catalog.has_table_privilege('aa_app_user', t, 'SELECT')
       OR pg_catalog.has_table_privilege('public', t, 'SELECT') THEN
        RAISE EXCEPTION 'migration 428: grants on % are not as designed', t;
    END IF;
    IF (SELECT count(*) FROM shared.setting_definition
         WHERE key IN ('cis.tripplanner.custom_domain_max_per_tenant', 'cis.tripplanner.custom_domain_edge_max',
                       'cis.tripplanner.custom_domain_validation_timeout_hours',
                       'cis.tripplanner.custom_domain_poll_seconds',
                       'cis.tripplanner.custom_domain_edge_pending_hours',
                       'cis.tripplanner.custom_domain_renewal_grace_days')) <> 6 THEN
        RAISE EXCEPTION 'migration 428: the six custom-domain settings are not all defined';
    END IF;
    -- The domain CHECK refuses what is not a lower-case host name (no row is ever stored: each probe fails).
    FOREACH bad IN ARRAY ARRAY['Trip.Example.test', 'trip..example.test', '-trip.example.test', 'trip.example.',
                               'trip_x.example.test', 'https://trip.example.test', 'localhost', '10.0.0.1'] LOOP
        BEGIN
            INSERT INTO shared.tenant_tripplanner_domain (tenant_id, domain, updated_by)
            VALUES ('00000000-0000-0000-0000-000000000000'::uuid, bad, 'migration:428');
        EXCEPTION
            WHEN check_violation THEN
                refused := refused + 1;
            WHEN foreign_key_violation THEN
                NULL;  -- a host the CHECK let through (counted as not refused below)
        END;
    END LOOP;
    IF refused <> 8 THEN
        RAISE EXCEPTION 'migration 428: the domain CHECK let % of 8 bad hosts through', 8 - refused;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('428', now(), 'AA-1090 TripPlanner R8: shared.tenant_tripplanner_domain (custom hosts of a tenant site) and '
                      'the six custom-domain settings')
ON CONFLICT (version) DO NOTHING;

COMMIT;
