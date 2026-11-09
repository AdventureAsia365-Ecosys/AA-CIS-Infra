-- Migration 393: AA-1055 PR 2 (buy side of the search-demand redesign, root audit
-- docs/audits/2026-11-08-S273-session/dfs-cost-audit/design.vi.md sections 2, 5 and 7) — the stored keyword map of a
-- place, the SERP tier of the demand store and the freshness tier of the research log.
--
-- Why. Segment research (services/acp_contract/segment_research_batch.py) asks an LLM for up to 4 search keywords
-- per place, has Jev judge them, buys their volume and one SERP, and keeps nothing of the map: every refresh pays the
-- LLM and Jev again and no reader can tell which keyword belongs to which place (atom_ranking matches by name). The
-- design keeps ONE buyer and ONE store: the map is kept (place_keyword), each place gets ONE SERP in the SERP market
-- (US / English) instead of one per market, and the related searches of that SERP, thrown away until now, are kept
-- next to its People Also Ask. Volume and SERP freshness are tracked apart (volume per market, SERP once per place),
-- so a place whose volume is fresh can still get the SERP it lacks (the 154 places bought on 08/11 have no related
-- searches).
--
-- What.
--   1. acp_contract.place_keyword: one row per (subject_kind, subject, keyword). subject_kind 'place' = subject is an
--      atom_segment.canonical_place; 'country_activity' = subject is '<country>|<activity>' (a tour-level phrase such
--      as "bhutan cultural tour" with no place, for S1; country and activity are then both set). source says where
--      the keyword came from (llm_propose, place_name, country_activity, seo_context_copy); prompt_version is the
--      proposing prompt's version (a new version re-proposes the place). jev_zone / jev_mode / jev_probability keep
--      Jev's verdict on "is this keyword about this very place" (a3_keyword_belongs; 'not_asked' for the plain place
--      name, which is the place by definition). A rejected keyword stays in the map so it is never proposed nor bought
--      again. No tenant column: platform data, like search_demand.
--   2. acp_contract.search_demand gains related_searches (jsonb, the SERP's related searches), paa_retrieved_on (when
--      the SERP behind people_also_ask / related_searches / serp_domains was bought) and serp_location (the market
--      whose location the SERP was bought in). Backfill: rows that hold a bought SERP (non-empty people_also_ask or a
--      serp_domains value) get paa_retrieved_on = retrieved_on and serp_location = market (until now every SERP was
--      bought in the row's own market). related_searches stays NULL: it was never stored, so those SERPs are bought
--      again once (the SERP is skipped only when both PAA and related searches are fresh).
--   3. acp_contract.segment_research_log gains tier ('volume' | 'serp', default 'volume'): every existing row is a
--      volume row (the default is the backfill). The primary key becomes (canonical_place, market, tier); a 'serp' row
--      sits under the SERP market. The old key (canonical_place, market) goes: the old code's
--      ON CONFLICT (canonical_place, market) fails from here on, so no segment_research job may start between this
--      apply and the deploy of the code PR (the job is admin-triggered only, AA-646).
--   4. Register 393.
--
-- Class: contract (ADR 0017 decision 3): it UPDATEs an existing table (backfill), adds a CHECK and replaces the primary
-- key of an existing table. MIG-4 order: this migration-only PR, the apply (Dev: Infra Migration Apply when every job
-- table is idle, root ADR 0017a), then the code PR that raises readiness to 393.
--
-- PII (DM-6.1). None: place names, search keywords and Google's public questions; no person, no tenant.
--
-- Retention (DM-7.1). place_keyword: kept while its subject exists (a map is re-proposed only on a new place, a rename
-- or a new prompt version); rows of a canonical place no atom_segment holds any more are deletable. No deletion job
-- yet. Row in root data standards Part B section 7, in the root PR of this change (merged before the Infra copy).
-- search_demand and segment_research_log keep their rows as today (grandfathered CIS tables).
--
-- Size. search_demand ~5.1k rows, segment_research_log ~1.3k rows (Dev, 08/11/2026): the backfill and the key swap
-- take milliseconds. ADD COLUMN with a constant default is metadata-only.

BEGIN;

-- 1. The keyword map ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS acp_contract.place_keyword (
    subject_kind    text        NOT NULL,
    subject         text        NOT NULL,
    keyword         text        NOT NULL,
    rank            smallint    NOT NULL DEFAULT 0,
    country         text,
    activity        text,
    source          text        NOT NULL,
    prompt_version  text        NOT NULL,
    jev_zone        text,
    jev_mode        text,
    jev_probability real,
    proposed_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT place_keyword_pkey PRIMARY KEY (subject_kind, subject, keyword),
    CONSTRAINT place_keyword_subject_kind_check CHECK (subject_kind IN ('place', 'country_activity')),
    CONSTRAINT place_keyword_source_check
        CHECK (source IN ('llm_propose', 'place_name', 'country_activity', 'seo_context_copy')),
    CONSTRAINT place_keyword_jev_zone_check
        CHECK (jev_zone IS NULL OR jev_zone IN ('accept', 'grey', 'reject', 'error', 'skipped', 'not_asked')),
    CONSTRAINT place_keyword_country_activity_check
        CHECK (subject_kind <> 'country_activity' OR (country IS NOT NULL AND activity IS NOT NULL)),
    CONSTRAINT place_keyword_keyword_check CHECK (length(keyword) BETWEEN 1 AND 80)
);

CREATE INDEX IF NOT EXISTS idx_place_keyword_keyword ON acp_contract.place_keyword (keyword);

COMMENT ON TABLE acp_contract.place_keyword IS
    'AA-1055 (CIS 393): the stored keyword map of a place (or of a country + activity phrase), proposed once by '
    'segment research and judged by Jev; read instead of re-proposing on every refresh. Platform data, no tenant.';
COMMENT ON COLUMN acp_contract.place_keyword.subject IS
    'canonical_place of atom_segment (subject_kind place), or ''<country>|<activity>'' (subject_kind country_activity).';
COMMENT ON COLUMN acp_contract.place_keyword.prompt_version IS
    'Version of the proposing prompt (a3_propose@<sha12>); a place whose map has another version is proposed again.';
COMMENT ON COLUMN acp_contract.place_keyword.jev_zone IS
    'Jev a3_keyword_belongs zone at proposal time; not_asked for the plain place name. A keyword is dropped from '
    'purchase only when jev_zone = reject AND jev_mode = enforce (ADR 0007).';

REVOKE ALL ON acp_contract.place_keyword FROM PUBLIC;
REVOKE ALL ON acp_contract.place_keyword FROM aa_app_user, catalog_owner;
GRANT SELECT, INSERT, UPDATE, DELETE ON acp_contract.place_keyword TO cis_app;

-- 2. The SERP tier of the demand store ───────────────────────────────────────────────────────────────────────────
ALTER TABLE acp_contract.search_demand ADD COLUMN IF NOT EXISTS related_searches jsonb;
ALTER TABLE acp_contract.search_demand ADD COLUMN IF NOT EXISTS paa_retrieved_on timestamptz;
ALTER TABLE acp_contract.search_demand ADD COLUMN IF NOT EXISTS serp_location text;

COMMENT ON COLUMN acp_contract.search_demand.related_searches IS
    'AA-1055 (CIS 393): the related searches of the SERP bought for this keyword (NULL = never stored).';
COMMENT ON COLUMN acp_contract.search_demand.paa_retrieved_on IS
    'AA-1055 (CIS 393): when the SERP behind people_also_ask / related_searches / serp_domains was bought '
    '(retrieved_on is the volume''s date). Fresh for 365 days.';
COMMENT ON COLUMN acp_contract.search_demand.serp_location IS
    'AA-1055 (CIS 393): the market whose location the SERP was bought in (one SERP per place, US / English).';

UPDATE acp_contract.search_demand
   SET paa_retrieved_on = retrieved_on, serp_location = market
 WHERE paa_retrieved_on IS NULL
   AND (people_also_ask <> '[]'::jsonb OR serp_domains IS NOT NULL);

-- 3. The freshness tier of the research log ──────────────────────────────────────────────────────────────────────
ALTER TABLE acp_contract.segment_research_log ADD COLUMN IF NOT EXISTS tier text NOT NULL DEFAULT 'volume';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'segment_research_log_tier_check'
                      AND conrelid = 'acp_contract.segment_research_log'::regclass) THEN
        ALTER TABLE acp_contract.segment_research_log
            ADD CONSTRAINT segment_research_log_tier_check CHECK (tier IN ('volume', 'serp'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_attribute a
                     ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                    WHERE i.indrelid = 'acp_contract.segment_research_log'::regclass
                      AND i.indisprimary AND a.attname = 'tier') THEN
        ALTER TABLE acp_contract.segment_research_log DROP CONSTRAINT IF EXISTS segment_research_log_pkey;
        ALTER TABLE acp_contract.segment_research_log
            ADD CONSTRAINT segment_research_log_pkey PRIMARY KEY (canonical_place, market, tier);
    END IF;
END $$;

COMMENT ON COLUMN acp_contract.segment_research_log.tier IS
    'AA-1055 (CIS 393): volume = the place''s keyword volumes were bought in this market; serp = the place''s one SERP '
    'was bought (market = the SERP market). Each tier is fresh for 365 days.';

-- 4. Register ────────────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('393', now(), 'AA-1055: acp_contract.place_keyword (stored keyword map + Jev verdict), search_demand '
        'related_searches / paa_retrieved_on / serp_location (one SERP per place), segment_research_log tier')
ON CONFLICT (version) DO NOTHING;

COMMIT;
