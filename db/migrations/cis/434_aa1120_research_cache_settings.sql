-- Migration 434: AA-1120 (S282) — the freshness windows of the DataForSEO research cache and the recovery window of
-- queued tasks in the platform settings registry (CIS 407; tech lead S279: a threshold, limit, cap, TTL or retention
-- window is a setting on Platform › Settings, never a code literal or an env var alone).
--
-- Why. Every DataForSEO purchase of segment research (live endpoints and the Standard queue of AA-1055) now goes
-- through one research cache (services/seo_intelligence/research_cache.py): a (keyword, market) volume or SERP that
-- is still fresh in acp_contract.search_demand is never bought again, and a queued task that was paid for but not
-- collected (a worker restart or a job retry during the wait) is collected free from DataForSEO instead of being
-- posted again. The two freshness windows were code constants (FRESH_FOR and SERP_FRESH_FOR, 365 days, AA-1055); the
-- recovery window is new. They become settings here so an administrator changes them on Platform › Settings
-- (audited) and the cache, the stale plan and the preview estimate read the value in force.
--
-- What:
--   1. Three rows in shared.setting_definition (seed block below, read by scripts/settings/gen_compiled_defaults.py
--      into shared/settings/compiled_defaults.json in this PR), area "seo", scope platform, impact medium, single
--      approval, no evidence, no env override, enforced (services/seo_intelligence/research_settings.py names every
--      key in this PR, the settings-lint reader check; the code PR reads them through shared.settings):
--        cis.seo.research_volume_fresh_days   int days 30-730, default 365 (was segment_research.FRESH_FOR)
--        cis.seo.research_serp_fresh_days     int days 30-730, default 365 (was segment_research_batch.SERP_FRESH_FOR)
--        cis.seo.dfs_queue_recover_days       int days 0-30, default 7 (0 = never collect an older paid task)
--      Each seed row carries its plain label and its EN + VI operator guide (CIS 416 rule).
--   2. Register 434.
--
-- Behaviour on apply. None for running code: no value row is seeded and nothing on main reads these keys; after the code
-- PR the research cache reads the defaults (the 365-day windows of today, a 7-day recovery window) until an
-- administrator changes a value.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): config rows INSERTed into an existing table.
-- MIG-4: a migration-only PR, applied on Dev by Infra Migration Apply when the job tables are idle (ADR 0017a), then the
-- code PR (no readiness raise: a reader falls back to the compiled defaults). DM-6.1: no personal data. DM-7.1: no new
-- table.
--
-- Number. 433 is the newest CIS migration on main (16/11/2026). If the owner main max + 1 differs at merge, renumber
-- (git grep '434_' and '434' here, in tests/integration/test_aa1120_migration_434.py, compiled_defaults.json and the
-- implementation notes docs/implementation-notes/AA-1120.md).
--
-- Locks. One INSERT of three rows (the definition guard trigger allows the file's role, cis_owner). lock_timeout 5s.
-- Idempotent (ON CONFLICT (key) DO NOTHING), one transaction, self-registering.
--
-- Rollback (a new forward migration, after the code PR is reverted): DELETE the keys' value rows first, then the keys.

BEGIN;
SET LOCAL lock_timeout = '5s';

-- settings-seed:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted seed)
INSERT INTO shared.setting_definition
    (key, app, area, label, description, value_type, unit, min_value, max_value, allowed_values, default_value,
     scope_kind, impact, approval, evidence_required, env_override, cache_s, enforced, guide)
SELECT s.key, s.app, s.area, s.label, s.description, s.value_type, s.unit, s.min_value, s.max_value, s.allowed_values,
       s.default_value, s.scope_kind, s.impact, s.approval, s.evidence_required, s.env_override, s.cache_s, s.enforced,
       s.guide
  FROM jsonb_to_recordset($seed$
[
{"key": "cis.seo.research_volume_fresh_days", "app": "cis", "area": "seo", "label": "Keyword research: days a search volume stays fresh", "description": "Research cache (AA-1120): a keyword's search volume in a market, bought from DataForSEO, is reused without a new purchase for this many days (acp_contract.search_demand.retrieved_on), and a place's volume research (segment_research_log tier volume) counts as fresh for as long. Read by services/seo_intelligence/research_cache.py before every volume purchase, by the stale plan and by the preview estimate of segment research.", "value_type": "int", "unit": "days", "min_value": 30, "max_value": 730, "allowed_values": null, "default_value": 365, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long a monthly search volume bought from DataForSEO for a keyword in one market is reused before research buys it again. Google's volume is a 12-month average, so it changes slowly.", "raise": "Fewer volumes are bought again, so research costs less; demand numbers can be older.", "lower": "Volumes are refreshed more often, so research costs more; demand numbers are newer.", "when": "Lower it when the business owner wants newer demand numbers before a season or a market launch; raise it to keep keyword data spend low.", "example": "With the default of 365 days, a volume bought on 9 November is reused until 9 November next year."}, "vi": {"what": "Lượng tìm kiếm hằng tháng của một từ khoá ở một thị trường, mua từ DataForSEO, được dùng lại bao lâu trước khi research mua lại. Lượng của Google là trung bình 12 tháng nên đổi chậm.", "raise": "Ít lượng tìm kiếm bị mua lại hơn nên research rẻ hơn; số nhu cầu có thể cũ hơn.", "lower": "Lượng tìm kiếm được làm mới thường hơn nên research tốn hơn; số nhu cầu mới hơn.", "when": "Giảm khi chủ doanh nghiệp muốn số nhu cầu mới hơn trước một mùa hoặc trước khi mở một thị trường; tăng để giữ chi phí dữ liệu từ khoá thấp.", "example": "Với mặc định 365 ngày, lượng tìm kiếm mua ngày 9/11 được dùng lại tới ngày 9/11 năm sau."}}},
{"key": "cis.seo.research_serp_fresh_days", "app": "cis", "area": "seo", "label": "Keyword research: days a search results page stays fresh", "description": "Research cache (AA-1120): a keyword's search results page (People Also Ask questions, related searches, organic domains), bought from DataForSEO, is reused without a new purchase for this many days (acp_contract.search_demand.paa_retrieved_on), and a place's SERP research (segment_research_log tier serp) counts as fresh for as long. Read by services/seo_intelligence/research_cache.py before every SERP purchase, by the stale plan and by the preview estimate of segment research.", "value_type": "int", "unit": "days", "min_value": 30, "max_value": 730, "allowed_values": null, "default_value": 365, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How long the search results page bought for a keyword (the questions people also ask, related searches and the sites that rank) is reused before research buys it again.", "raise": "Fewer pages are bought again, so research costs less; the questions can be older.", "lower": "Pages are refreshed more often, so research costs more; blogs get newer questions.", "when": "Lower it when reviewers find the questions in blogs out of date; raise it to keep keyword data spend low.", "example": "With the default of 365 days, a results page bought on 9 November is reused until 9 November next year."}, "vi": {"what": "Trang kết quả tìm kiếm mua cho một từ khoá (các câu hỏi người dùng cũng hỏi, tìm kiếm liên quan và các trang đang xếp hạng) được dùng lại bao lâu trước khi research mua lại.", "raise": "Ít trang bị mua lại hơn nên research rẻ hơn; câu hỏi có thể cũ hơn.", "lower": "Trang được làm mới thường hơn nên research tốn hơn; blog có câu hỏi mới hơn.", "when": "Giảm khi người duyệt thấy câu hỏi trong blog đã lỗi thời; tăng để giữ chi phí dữ liệu từ khoá thấp.", "example": "Với mặc định 365 ngày, trang kết quả mua ngày 9/11 được dùng lại tới ngày 9/11 năm sau."}}},
{"key": "cis.seo.dfs_queue_recover_days", "app": "cis", "area": "seo", "label": "Keyword research: days to collect a paid queued task again", "description": "Research cache (AA-1120): a DataForSEO Standard queue task that was paid for at post but never collected (a worker restart or a job retry during the wait) is collected free by the next run that needs the same keywords, when it was posted within this many days, instead of being posted and paid again. 0 = never collect an older task. DataForSEO keeps a task's result for 30 days. Read by services/seo_intelligence/dfs_queue.py before every queued post.", "value_type": "int", "unit": "days", "min_value": 0, "max_value": 30, "allowed_values": null, "default_value": 7, "scope_kind": "platform", "impact": "medium", "approval": "single", "evidence_required": false, "env_override": null, "cache_s": 60, "enforced": true, "guide": {"en": {"what": "How far back research looks for keyword data it already paid for in the DataForSEO queue but never received (a restart during the wait). Such data is fetched free instead of being bought again.", "raise": "Older paid tasks are still fetched instead of bought again; DataForSEO keeps a task for 30 days at most.", "lower": "Only recent paid tasks are fetched; an older one is bought again. 0 turns the recovery off.", "when": "Raise it when research runs are days apart and a restart cut a run short; lower it only to test a fresh purchase.", "example": "With the default of 7 days, a run on Friday fetches free the results a run on Monday paid for but lost in a restart."}, "vi": {"what": "Research nhìn lại bao xa để tìm dữ liệu từ khoá đã trả tiền trong hàng đợi DataForSEO nhưng chưa nhận về (khởi động lại trong lúc chờ). Dữ liệu đó được lấy miễn phí thay vì mua lại.", "raise": "Task đã trả tiền cũ hơn vẫn được lấy về thay vì mua lại; DataForSEO giữ một task tối đa 30 ngày.", "lower": "Chỉ task đã trả tiền gần đây được lấy về; task cũ hơn bị mua lại. 0 là tắt việc lấy lại.", "when": "Tăng khi các lần research cách nhau nhiều ngày và một lần khởi động lại đã cắt ngang một lần chạy; chỉ giảm để thử một lần mua mới.", "example": "Với mặc định 7 ngày, lần chạy thứ Sáu lấy miễn phí kết quả mà lần chạy thứ Hai đã trả tiền nhưng bị mất khi khởi động lại."}}}
]
$seed$::jsonb) AS s (key text, app text, area text, label text, description text, value_type text, unit text,
                      min_value numeric, max_value numeric, allowed_values jsonb, default_value jsonb, scope_kind text,
                      impact text, approval text, evidence_required boolean, env_override text, cache_s integer,
                      enforced boolean, guide jsonb)
ON CONFLICT (key) DO NOTHING;
-- settings-seed:end

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('434', now(), 'AA-1120: research cache freshness and queued-task recovery windows (cis.seo.research_*)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
