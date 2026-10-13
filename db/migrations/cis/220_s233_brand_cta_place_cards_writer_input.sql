-- Migration 220: S233 — tenant default CTA (AA-771), place cards (AA-772), writer-input
-- snapshot per piece (AA-769), and the two place-card stage keys.
--
-- 1. shared.tenant_brand_rules.default_cta (AA-771). Every T9 request today has cta = NULL
--    (pick_subject never sets it), so a write without a portal override fails with
--    MissingCTAError, and the CTA is free text per request. The brand pack now carries the
--    tenant's own default CTA; a per-request override still wins.
--
-- 2. acp_shared.place_card + acp_shared.atom_place_card (AA-772). The A-series has no city,
--    region or display name for a place: an atom has the landmark as the itinerary names it
--    (tour_atoms.place) and the tour has one country (raw_tours.country). S232: 12/20 Pawangka
--    posts put the monastery in Luang Prabang, Ladakh or "a monastery in China". A card holds
--    the display name, locality, region, country, a naming note and a few checked background
--    facts the writer may cite; facts are drafted by one model and kept only when a second
--    model (another vendor) confirms them, then an admin can verify or reject the card.
--    One card per real place: place_key = normalised display_name | locality | country, so
--    "City Palace" in Jaipur and in Udaipur are two cards. atom_place_card maps an atom to its
--    card (resolved once per atom, from the atom's own place, evidence, day and tour country).
--    Platform data (no tenant column): cards describe places, never a tenant.
--
-- 3. acp_shared.content_piece.writer_input (AA-769). What the writer was given (seed, facts,
--    place cards, brand pack, angle, keyword, CTA) was never stored: shared.job.payload kept part
--    of it and facts were resolved in memory. The admin Content Quality page shows it per piece.
--
-- 4. acp_shared.facts.country (AA-768). Facts reach every T9 prompt with no place key, and the
--    per-fact relevance call was Jev (S232: no Jev on the T axis). A fact with a country is
--    offered only to pieces about that country; NULL = applies everywhere.
--
-- 5. Stage keys a3_place_card (writer) and a3_place_card_check (judge), routed like t9_write
--    and t10_judge today (copied from those rows, so no model choice changes). SAFE_DEFAULTS in
--    shared/llm_client/role_config.py mirrors them.
--
-- Applied on Dev via the AA-CIS-Infra "DB Migrate" workflow (identical copy in
-- db/migrations/cis/), BEFORE the app change that uses these columns is deployed.

BEGIN;

-- 1 ── tenant default CTA ────────────────────────────────────────────────────────────────────
ALTER TABLE shared.tenant_brand_rules ADD COLUMN IF NOT EXISTS default_cta TEXT;
COMMENT ON COLUMN shared.tenant_brand_rules.default_cta IS
    'AA-771 — the tenant''s default call to action for T9 pieces; a per-request cta override wins.';

-- 2 ── place cards ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS acp_shared.place_card (
    card_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    place_key     TEXT NOT NULL UNIQUE,
    display_name  TEXT NOT NULL,
    locality      TEXT,
    region        TEXT,
    country       TEXT NOT NULL,
    naming_note   TEXT,
    facts         JSONB NOT NULL DEFAULT '[]'::jsonb,
    status        TEXT NOT NULL DEFAULT 'auto_checked'
                  CHECK (status IN ('auto_checked', 'verified', 'rejected')),
    cost_usd      NUMERIC(10, 6) NOT NULL DEFAULT 0,
    verified_by   TEXT,
    verified_at   TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE acp_shared.place_card IS
    'AA-772 — one card per real place: display name, locality/region/country, naming note and '
    'checked background facts [{text, kind}] the T8/T9 writer may cite. Drafted by '
    'a3_place_card, each fact kept only if a3_place_card_check confirms it (status '
    'auto_checked); admin may set verified/rejected. A rejected card is never shown to a writer.';

CREATE TABLE IF NOT EXISTS acp_shared.atom_place_card (
    atom_id      TEXT PRIMARY KEY REFERENCES acp_contract.tour_atoms(atom_id) ON DELETE CASCADE,
    card_id      UUID NOT NULL REFERENCES acp_shared.place_card(card_id) ON DELETE CASCADE,
    resolved_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_atom_place_card_card ON acp_shared.atom_place_card(card_id);
COMMENT ON TABLE acp_shared.atom_place_card IS
    'AA-772 — which place card an atom is about (resolved once per atom).';

-- 3 ── writer input snapshot ─────────────────────────────────────────────────────────────────
ALTER TABLE acp_shared.content_piece ADD COLUMN IF NOT EXISTS writer_input JSONB;
COMMENT ON COLUMN acp_shared.content_piece.writer_input IS
    'AA-769 — what the T9 writer was given for this piece: seed, facts, place cards, brand pack, '
    'angle brief, keyword, cta, goal, channel, prompt sha256. Admin-only (never in a tenant '
    'projection).';

-- 4 ── facts scoped by country ──────────────────────────────────────────────────────────────
ALTER TABLE acp_shared.facts ADD COLUMN IF NOT EXISTS country TEXT;
COMMENT ON COLUMN acp_shared.facts.country IS
    'S233 — the country this fact is about (matches raw_tours.country); NULL = any country.';
UPDATE acp_shared.facts SET country = 'Laos' WHERE country IS NULL AND title ILIKE '%laos%';

-- 5 ── stage keys ────────────────────────────────────────────────────────────────────────────
INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
SELECT t.new_stage, c.role, c.provider, c.model_id, c.account_route, c.is_active,
       c.fallback_model_ids, NULL, 0, 'system-migration-s233'
FROM (VALUES ('a3_place_card', 't9_write'),
             ('a3_place_card_check', 't10_judge')) AS t(new_stage, twin)
JOIN shared.llm_role_config c ON c.stage = t.twin
ON CONFLICT (stage) DO NOTHING;

DO $$
BEGIN
    IF (SELECT count(*) FROM shared.llm_role_config
        WHERE stage IN ('a3_place_card', 'a3_place_card_check')) <> 2 THEN
        RAISE EXCEPTION 'S233: expected 2 place-card stage rows — a twin row (t9_write/t10_judge) is missing';
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('220', now(), 'S233: tenant_brand_rules.default_cta (AA-771), place_card + atom_place_card (AA-772), '
        'content_piece.writer_input (AA-769), facts.country, stage keys a3_place_card / a3_place_card_check')
ON CONFLICT (version) DO NOTHING;

COMMIT;
