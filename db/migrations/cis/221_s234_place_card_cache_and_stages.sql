-- Migration 221: S234 — place-card negative cache + aliases (AA-772), and the stage keys
-- t9_repair (AA-768/AA-769) and t10_claims (AA-768 F9 v2).
--
-- 1. acp_shared.place_card_miss (AA-772). S233: 169 Sonnet drafts made 74 cards ($1.30); a miss
--    (no identifiable place, identity rejected by the checker, error) was never stored, so every
--    T8/T9 job paid for the same place again — one unnamed atom was drafted 35 times. A miss is
--    now stored per (place_norm, country_norm) with a retry_after (no_name 30 days,
--    identity_rejected 14 days, error 1 day). rule_version / prompt_sha: a miss written under
--    an older filter rule or prompt no longer blocks a new draft.
--
-- 2. acp_shared.atom_place_card.card_id becomes NULLABLE + miss_reason (AA-772). An atom row with
--    card_id NULL records why the atom has no card (unnamed / logistics_place / no_name /
--    identity_rejected / error) for the admin view. Every reader JOINs place_card on card_id,
--    so a NULL row returns nothing to a writer.
--
-- 3. acp_shared.place_card_alias (AA-772). The same lake had 5 cards (the key held the LLM's
--    free-text locality, and nothing was looked up before drafting). An alias (the itinerary
--    spelling, the display name, a parenthetical name, the draft's own aliases, or an admin
--    merge) maps a folded name + country to a card, so the next atom naming that place is linked
--    with no LLM call.
--
-- 4. Stage keys (shared.llm_role_config):
--    - t9_repair (writer): Claude Haiku, fallback Sonnet — the one cheap stage for T9 sentence
--      repair, SEO fit and the admin sentence suggest (S234 plan C2/C12). Callers move to it in
--      their own PRs; the pipeline repair moves only after its A/B.
--    - t10_claims (validate): GPT-6 Luna, fallback GPT-5.6 Luna, shadow 0 — F9 v2 claim
--      extraction (AA-768), not wired into the gates until its offline replay passes.
--    a3_place_card stays on its migration-220 route until the place-card A/B.
--    ON CONFLICT DO NOTHING: an admin's later Settings change is never overwritten. SAFE_DEFAULTS
--    in shared/llm_client/role_config.py mirrors both rows.
--
-- Idempotent (IF NOT EXISTS / ON CONFLICT DO NOTHING) — safe to re-run, and the integration
-- conftest replays every migration on an empty DB.
--
-- Applied on Dev via the AA-CIS-Infra "DB Migrate" workflow (identical copy in
-- db/migrations/cis/), BEFORE the app change that uses these tables is deployed.

BEGIN;

-- 1 ── negative cache ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS acp_shared.place_card_miss (
    place_norm     TEXT NOT NULL,
    country_norm   TEXT NOT NULL,
    reason         TEXT NOT NULL CHECK (reason IN ('no_name', 'identity_rejected', 'error')),
    attempts       INTEGER NOT NULL DEFAULT 1,
    rule_version   INTEGER NOT NULL,
    prompt_sha     TEXT NOT NULL,
    model          TEXT,
    last_tried_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    retry_after    TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (place_norm, country_norm)
);
COMMENT ON TABLE acp_shared.place_card_miss IS
    'AA-772 (S234) — a place the paid card draft could not resolve (no_name, identity_rejected, '
    'error), keyed by folded itinerary place + folded tour country. Not drafted again before '
    'retry_after unless rule_version/prompt_sha changed or an admin forces a build.';

-- 2 ── atom-level miss reason ───────────────────────────────────────────────────────────────
ALTER TABLE acp_shared.atom_place_card ALTER COLUMN card_id DROP NOT NULL;
ALTER TABLE acp_shared.atom_place_card ADD COLUMN IF NOT EXISTS miss_reason TEXT;
COMMENT ON COLUMN acp_shared.atom_place_card.miss_reason IS
    'AA-772 (S234) — why this atom has no card (card_id NULL): unnamed, logistics_place, no_name, '
    'identity_rejected, error. NULL when linked.';

-- 3 ── aliases ──────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS acp_shared.place_card_alias (
    alias_norm    TEXT NOT NULL,
    country_norm  TEXT NOT NULL,
    card_id       UUID NOT NULL REFERENCES acp_shared.place_card(card_id) ON DELETE CASCADE,
    source        TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (alias_norm, country_norm)
);
CREATE INDEX IF NOT EXISTS idx_place_card_alias_card ON acp_shared.place_card_alias(card_id);
COMMENT ON TABLE acp_shared.place_card_alias IS
    'AA-772 (S234) — folded place name + folded country → card. source: itinerary | display | '
    'draft_alias | merge. Looked up before any a3_place_card draft.';

-- 4 ── stage keys ───────────────────────────────────────────────────────────────────────────
INSERT INTO shared.llm_role_config
    (stage, role, provider, model_id, account_route, is_active, fallback_model_ids,
     shadow_model_id, shadow_sample_pct, updated_by)
VALUES
    ('t9_repair', 'writer', 'claude', 'haiku', 'acc3', true, ARRAY['sonnet']::text[],
     NULL, 0, 'system-migration-s234'),
    ('t10_claims', 'validate', 'openai', 'gpt-6-luna', 'acc3', true, ARRAY['gpt-5.6-luna']::text[],
     NULL, 0, 'system-migration-s234')
ON CONFLICT (stage) DO NOTHING;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('221', now(), 'S234: place_card_miss + place_card_alias + atom_place_card.miss_reason (AA-772), '
        'stage keys t9_repair (haiku) and t10_claims (gpt-6-luna)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
