-- migrate: expand
-- Migration 440: AA-1122 item 1 (S282, tech lead decision 16/11/2026) — the monthly search volume history of the
-- research store: one row per (keyword, market, month), written once and never overwritten.
--
-- Why. Every Google Ads volume answer DataForSEO sends (search_volume live and Standard queue, keywords_for_keywords)
-- carries `monthly_searches`: the last 12 months of the keyword in that market. Research kept only the 12-month
-- average (acp_contract.search_demand.search_volume) and replaced it on every refresh, so the season of a place (when
-- people search it) was paid for and dropped. Content timing (publish two to three months before the peak of a market)
-- and "demand is rising / falling" need the months.
--
-- What.
--   1. acp_contract.search_volume_monthly:
--        keyword / market     the research store key (acp_contract.search_demand: tidied lowercase keyword, market code)
--        month                the first day of the month the volume is about (date; DataForSEO year + month)
--        search_volume        the monthly searches Google Ads reports for that month (NULL = reported without a number)
--        source               the endpoint label that answered (search_volume_bulk, search_volume_bulk_queue,
--                             keywords_for_keywords), for the audit of the row
--        first_seen_at        when the row was first stored
--      Primary key (keyword, market, month). The writer inserts with ON CONFLICT DO NOTHING: a month is stored once,
--      a later purchase of the same keyword only adds the months it had not seen (Google Ads revises the last month a
--      little; the first answer is kept so the history never moves under a reader).
--      Index (market, month) for the per-market season reads.
--   2. GRANT cis_app SELECT, INSERT (the research writers and the admin reads; no UPDATE, no DELETE: the history is
--      append-only for the runtime role).
--   3. Register 440.
--
-- PII (DM-6.1). None: search phrases, market codes, months and numbers. No tenant column (platform research store).
--
-- Retention (DM-7.1). Kept: history of derived reference data; no deletion job yet (a window, proposed 48 months, the
-- depth Google Ads reports, becomes a setting with a TTL kind before prod). Row in root data standards Part B section
-- 7, in the root PR of this change (merged before the Infra copy).
--
-- Behaviour. None on apply: the table is empty and nothing reads it. The code PR writes it on every volume answer and
-- reads it on the admin Research tab (the seasonality reader).
--
-- Class: expand (root ADR 0017 d3): a new table with its constraints and an index, a grant to the owner's runtime role
-- and comments; no existing object changes, no seed row, no DO block. Ships in the migration-only PR with 441 and 442.
--
-- Number. 434 is the newest CIS migration on main (16/11/2026); 435-439 belong to the pricing lane of this wave and the
-- lane was given 440 onwards. If the owner main max + 1 differs at merge, renumber (git grep '440_' and '440' here, in
-- tests/integration/test_aa1122_migrations_440_442.py and docs/implementation-notes/AA-1122.md).
--
-- Rollback (a new forward migration, after the code PR is reverted): DROP TABLE acp_contract.search_volume_monthly (a
-- destructive file, DRY RUN).
--
-- X1. One BEGIN … COMMIT block, no role switch. Migration Apply runs cis/ files as cis_owner, the owner of schema
-- acp_contract.

BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS acp_contract.search_volume_monthly (
    keyword        text         NOT NULL,
    market         text         NOT NULL,
    month          date         NOT NULL,
    search_volume  integer,
    source         text         NOT NULL,
    first_seen_at  timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT search_volume_monthly_pkey PRIMARY KEY (keyword, market, month),
    CONSTRAINT search_volume_monthly_keyword_check CHECK (length(keyword) BETWEEN 1 AND 200),
    CONSTRAINT search_volume_monthly_market_check CHECK (length(market) BETWEEN 1 AND 16),
    CONSTRAINT search_volume_monthly_month_check CHECK (month = date_trunc('month', month)::date),
    CONSTRAINT search_volume_monthly_volume_check CHECK (search_volume IS NULL OR search_volume >= 0),
    CONSTRAINT search_volume_monthly_source_check CHECK (length(source) BETWEEN 1 AND 64)
);

CREATE INDEX IF NOT EXISTS search_volume_monthly_market_month_idx
    ON acp_contract.search_volume_monthly (market, month);

COMMENT ON TABLE acp_contract.search_volume_monthly IS
    'AA-1122 (CIS 440): the monthly search volume Google Ads reports for a research keyword in a market (DataForSEO '
    'monthly_searches), one row per (keyword, market, month), written once and never overwritten. The season behind '
    'acp_contract.search_demand.search_volume (a 12-month average). Read by the seasonality reader (peak month, '
    'year-over-year per place and market).';
COMMENT ON COLUMN acp_contract.search_volume_monthly.month IS
    'AA-1122 (440): the first day of the month the volume is about.';
COMMENT ON COLUMN acp_contract.search_volume_monthly.source IS
    'AA-1122 (440): the DataForSEO endpoint label that answered (search_volume_bulk, search_volume_bulk_queue, '
    'keywords_for_keywords).';

GRANT SELECT, INSERT ON acp_contract.search_volume_monthly TO cis_app;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('440', now(), 'AA-1122: acp_contract.search_volume_monthly (monthly search volume history, never overwritten)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
