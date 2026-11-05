-- Migration 376: AA-1042 follow-up (tech lead S269, 05/11) — every Claude model the Anthropic API key can use is in
-- the AI gateway catalog with an Anthropic API deployment, and the family fallback chains fit those deployments into
-- the gateway's six attempts per request.
--
-- Why. The tech lead plugged the sponsored Anthropic API key in on 05/11 (connection anthropic-direct, ON, cap 150 USD
-- a month) and asked "Fable 5.1, Fable 5, Opus 5, Opus 4.8, 4.7, 4.6, 4.5, Sonnet 4.6, Haiku 4.5: why are they not in
-- the catalog as fallbacks?". The key can use 13 models (count_tokens, 05/11, $0); only Haiku 5.5, Sonnet 5, Sonnet
-- 5.5 and Opus 5.5 had an anthropic-direct deployment (306 seeded it for the Converse rows of that day). Sonnet 4.6
-- and Haiku 4.5 (366) answer on acc3 only, so when acc3 is blocked as an account (the Error 002 risk) every route
-- loses its 4.x rungs at once; Opus 4.6 / 4.5 are disabled acc3 candidates (367); Fable 5.1 / 5, Opus 5 / 4.8 / 4.7 have
-- no catalog row at all.
--
-- What.
--   1. Five catalog rows, reached only by the Anthropic API (no Bedrock profile): enabled, family anthropic, vendor
--      anthropic, provider anthropic, api_style anthropic_messages (the gateway's Anthropic adapter; with no
--      registry it refuses them by name instead of trying a Bedrock path with no profile), wire_model = the API model
--      id, callable_via {llm_client}, supports_temperature false (the adapter never sends one), max_output_tokens
--      128000, capabilities {} (the adapter's family table gives each its default effort). Prices: Anthropic
--      first-party list prices, USD per 1M tokens, from the claude-api skill model table (cached 2026-10-06), read
--      S269: cache read 0.1x input (Fable 5.1 0.025x), cache write 1.25x input (5-minute TTL; the gateway prices 1-hour
--      writes at 2x itself):
--        key        label            API model id       in      out     cache read  cache write
--        fable-5-1  Claude Fable 5.1 claude-fable-5-1   10.00   50.00   0.25        12.50
--        fable-5    Claude Fable 5   claude-fable-5     10.00   50.00   1.00        12.50
--        opus-5     Claude Opus 5    claude-opus-5       5.00   25.00   0.50         6.25
--        opus-4-8   Claude Opus 4.8  claude-opus-4-8     5.00   25.00   0.50         6.25
--        opus-4-7   Claude Opus 4.7  claude-opus-4-7     5.00   25.00   0.50         6.25
--   2. The acc3 candidates Opus 4.6 / Opus 4.5 (367) switched on in the catalog (enabled, blocked_reason NULL) while
--      they are still the untouched 367 rows; their acc3 deployments stay disabled (no evidence acc3 serves them), so
--      the Anthropic API is their only path. An admin's change of either row is kept (NOTICE).
--   3. Nine anthropic-direct deployments (origin seed, enabled, access_state unknown: the probe and the availability
--      sweep fill it), priority 100: behind every AWS deployment of the same model (tech lead S267, "AWS preferred,
--      not only"; acc3 rows are priority 10), the 306 convention. ON CONFLICT DO NOTHING (an admin's row is kept):
--        model       wire_id                     notes
--        fable-5-1   claude-fable-5-1
--        fable-5     claude-fable-5
--        opus-5      claude-opus-5
--        opus-4-8    claude-opus-4-8
--        opus-4-7    claude-opus-4-7
--        opus-4-6    claude-opus-4-6
--        opus-4-5    claude-opus-4-5-20251101    request_defaults {"effort": "high"} (the adapter's family table
--                                                does not know Opus 4.5; high is its default effort)
--        sonnet-4-6  claude-sonnet-4-6           cache read 0.30 / write 3.75 overrides (the 366 row has no cache
--        haiku-4-5   claude-haiku-4-5-20251001   price); cache read 0.10 / write 1.25: Anthropic list, 0.1x / 1.25x
--      In and out prices come from the catalog row (the 4.x rows hold the same 3 / 15, 1 / 5, 5 / 25 the Anthropic list
--      has).
--   4. The routes. The gateway makes at most six provider attempts per request (shared/llm_client/errors.py
--      MAX_CHAIN_ATTEMPTS, root ADR 0009 decision 5), and the chain rule counts every deployment of every model of a
--      route in the stage's scopes (api/services/llm_route_chains.py attempt_cap; the admin route control refuses a
--      save that breaks it). Step 3 gives Sonnet 4.6 and Haiku 4.5 a second deployment, so the 366 chains that name
--      both 4.x rows (or a 4.x row behind two other two-deployment models) would reach 7 attempts and their last rung
--      would never run. Each such chain keeps its order and drops its LOWEST Claude rung; the other-maker last rung
--      stays (the OpenAI API at the end of a writer, ADR 0009 S267; acc2 at the end of a validate stage: the other
--      failure domain). A stage changes only when its live row still has the primary and the 366 fallbacks, is
--      active and is a content stage (an admin's later change is kept, NOTICE):
--
--      stage                      primary      366 fallbacks                                   new fallbacks
--      s1_generate, supply_content_writer, t2_generate, t8_angle_gen, t9_write
--                                 sonnet-5-5   sonnet-4-6, haiku-4-5, gpt-6-luna-openai        sonnet-4-6, gpt-6-luna-openai
--      tp_compose                 sonnet-5-5   sonnet-4-6, haiku-4-5, gpt-6-luna-openai        sonnet-4-6, haiku-4-5
--      a0_column_map, s1_flag_fix, s1_itinerary_nudge, t2_flag_fix, t2_itinerary_nudge, t9_repair, segment_research,
--      segment_research_batch
--                                 haiku-5-5    haiku-4-5, sonnet-4-6, gpt-6-luna-openai        haiku-4-5, gpt-6-luna-openai
--      a3_place_card_check        haiku-5-5    haiku-4-5, sonnet-4-6, llama4-scout             haiku-4-5, llama4-scout
--      a3_place_days              haiku-5-5    haiku-4-5, sonnet-4-6, nova-lite                haiku-4-5, nova-lite
--      a3_place_locate, t9_faq_answer_fit
--                                 sonnet-5-5   sonnet-4-6, haiku-4-5, nova-lite                sonnet-4-6, nova-lite
--      a3_atomize, s1_source_facts
--                                 gpt-6-luna   gpt-6-luna-openai, haiku-5-5, haiku-4-5, nova-lite
--                                                                                   gpt-6-luna-openai, haiku-5-5, nova-lite
--
--      tp_compose is TripPlanner's stage: its own gateway calls Bedrock only and skips every vendor deployment (366),
--      so the OpenAI API rung never runs there; it keeps both AWS 4.x rungs instead (6 attempts). Every other stage
--      keeps its 366 route (the judges and the GPT stages name no Claude 4.x model; a3_place_dedupe_check and
--      t9_faq_filter make 5 attempts). The Claude attempts per request do not drop: Sonnet 4.6 / Haiku 4.5 are now
--      tried on acc3 AND on the Anthropic API, so a route survives acc3 being blocked as an account.
--      Not on any chain (catalog + deployment only, selectable in the admin route control): Sonnet 5 (acc3 refuses it
--      like every 5.x model and its only working path is the same API key as Sonnet 5.5, so its two attempts would
--      push out Sonnet 4.6, the only Sonnet that answers on AWS today, or the other-maker last rung); Opus 5 / 4.8 /
--      4.7 / 4.6 / 4.5 (no stage has an Opus primary; their degrade order, quality first, is Opus 5.5 > Opus 5 > Opus
--      4.8 > Opus 4.7 > Opus 4.6 > Opus 4.5, recorded in the catalog notes for the stage that adopts Opus); Fable 5.1 /
--      5 (Anthropic's most capable tier, 10 / 50 USD per 1M tokens, for long-horizon reasoning: above every tier a
--      stage uses, API only, and no family tier to degrade into). Raising the six-attempt cap to let a chain carry
--      them is an ADR 0009 decision, not this file's.
--   5. One route config version (CIS 370): action external, created_by migration-376-aa1042, the snapshot of the
--      routes and provider order after this file and its diff against the version in force, so the ledger rows written
--      after the apply carry the version that routes them and a one-click revert to the version before stays possible
--      (the admin refuses it while its chains break the attempt cap; "Prefer AWS" undoes the S269 Anthropic-first
--      preset instead).
--   6. Register 376.
--
-- Guards (RAISE rolls the whole file back):
--   before: 366, 367 and 370 registered; acc3 a bedrock aws_only connection, anthropic-direct an anthropic
--           vendor_direct one; family anthropic exists; sonnet-4-6, haiku-4-5, opus-4-6, opus-4-5 are Anthropic
--           Converse catalog rows; a pre-existing row of a new key (a re-apply) is an Anthropic Messages API row;
--           every model the new chains name is an enabled catalog row callable by llm_client.
--   after:  the five rows exist as described and enabled; opus-4-6 / opus-4-5 enabled unless an admin changed them;
--           the nine deployments exist with their API model id (^claude-[a-z0-9-]+$), each seeded one behind every
--           aws_only deployment of its model; only the listed stages changed, to their decided fallbacks, and every
--           row keeps primary, role, shadow, scopes, pii_class and is_active; the chain rules of
--           api/services/llm_route_chains.py on every row this file changed (RAISE) and every other active row
--           (NOTICE), except attempt_cap: RAISE on ANY active row this file pushes over the six attempts (an admin's
--           route that the new deployments would cut short must be changed first); every changed row still has an
--           enabled model with an enabled deployment on an enabled connection in its scopes.
--
-- Behaviour on Dev (anthropic-direct ON since 05/11, preset prefer_anthropic_api = route version 4: Haiku 5.5, Sonnet
-- 5, Sonnet 5.5 and Opus 5.5 on the API first). The primaries keep answering on the Anthropic API. When the API key is
-- refused or capped, a writer falls to Sonnet 4.6 / Haiku 4.5 on acc3 as today; when acc3 is also refused, to the same
-- 4.x model on the API (new) and then the OpenAI API. The new 4.x API rows sit behind acc3 (priority 100): applying
-- the preset again moves them API-first like the four 5.x rows. The daily probe calls each new enabled deployment
-- (60 tokens in, 32 out: about 0.011 USD a day for the nine, Fable 5.1 / 5 about 0.002 each; the whole post-376
-- plan about 0.02 USD a day). Its cap (MAX_PROBES) was 30, under the post-376 count of 33 enabled deployments on
-- enabled connections (the last rows, openai-direct, would go unprobed): the companion code PR raised it to 50
-- and merges BEFORE this file. No stage routes Opus or Fable, so beyond the probe they cost nothing until a stage
-- adopts one.
--
-- Class: contract (root ADR 0017 d3: INSERT of config rows, UPDATE of catalog and route rows), no migrate directive
-- line. Migration-only PR (MIG-4: no code needs this file; the code already reads every column it writes). On Dev
-- Infra Migration Apply applies it once every job table is idle (root ADR 0017a). After the apply: the probe of each
-- new deployment (admin connection test), POST /admin/writing-memory/releases/reverify-scan (writer routes changed
-- outside the admin PATCH), the route control preview, the bot/db-schema-reference PR. DM-7.1: no new table.
--
-- Number. Main max is 375 (05/11: CIS #1315, AA-1035), so 376 (the migration preflight refuses any other).
-- Renumber to main max + 1 if needed: git grep '376_' and 'migration 376' / 'CIS 376' / 'migration-376' /
-- "'376'" (file, tests, snapshot, actor, version).
--
-- Rollback (a NEW forward migration): the 366 fallbacks back on the rows updated_by 'migration-376-aa1042' (or the
-- admin route control, which refuses them while the 4.x API rows exist: delete those first); DELETE the nine
-- anthropic-direct deployments with updated_by 'migration-376-aa1042' and their shared.llm_provider_health rows; the
-- five catalog rows switched off (enabled = false) or deleted once no route, alias or ledger join needs them; opus-4-6
-- / opus-4-5 back to enabled = false with their 367 blocked_reason.
--
-- X1. One BEGIN … COMMIT block, no role switch (DB Migrate runs cis/ files as cis_owner, the owner of every table
-- here). Grants: none (existing tables).

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
    actor      constant text := 'migration-376-aa1042';
    max_attempts constant int := 6;               -- shared/llm_client/errors.py MAX_CHAIN_ATTEMPTS
    text_roles constant text[] := ARRAY['writer', 'judge', 'validate'];
    pairs      constant text[] := ARRAY['a3_place_card_check', 'a3_place_card', 'a3_place_dedupe_check', 'a3_place_dedupe'];
    new_keys   constant text[] := ARRAY['fable-5-1', 'fable-5', 'opus-5', 'opus-4-8', 'opus-4-7'];
    old_keys   constant text[] := ARRAY['opus-4-6', 'opus-4-5', 'sonnet-4-6', 'haiku-4-5'];
    candidates constant text[] := ARRAY['opus-4-6', 'opus-4-5'];
    -- model key -> [wire id, request_defaults, cache read override, cache write override]
    deps       constant jsonb := $deps${
        "fable-5-1":  ["claude-fable-5-1",          {}, null, null],
        "fable-5":    ["claude-fable-5",            {}, null, null],
        "opus-5":     ["claude-opus-5",             {}, null, null],
        "opus-4-8":   ["claude-opus-4-8",           {}, null, null],
        "opus-4-7":   ["claude-opus-4-7",           {}, null, null],
        "opus-4-6":   ["claude-opus-4-6",           {}, null, null],
        "opus-4-5":   ["claude-opus-4-5-20251101",  {"effort": "high"}, null, null],
        "sonnet-4-6": ["claude-sonnet-4-6",         {}, 0.30, 3.75],
        "haiku-4-5":  ["claude-haiku-4-5-20251001", {}, 0.10, 1.25]
    }$deps$::jsonb;
    plan       jsonb := $plan$[
        ["s1_generate",            "sonnet-5-5", ["sonnet-4-6", "haiku-4-5", "gpt-6-luna-openai"], ["sonnet-4-6", "gpt-6-luna-openai"]],
        ["supply_content_writer",  "sonnet-5-5", ["sonnet-4-6", "haiku-4-5", "gpt-6-luna-openai"], ["sonnet-4-6", "gpt-6-luna-openai"]],
        ["t2_generate",            "sonnet-5-5", ["sonnet-4-6", "haiku-4-5", "gpt-6-luna-openai"], ["sonnet-4-6", "gpt-6-luna-openai"]],
        ["t8_angle_gen",           "sonnet-5-5", ["sonnet-4-6", "haiku-4-5", "gpt-6-luna-openai"], ["sonnet-4-6", "gpt-6-luna-openai"]],
        ["t9_write",               "sonnet-5-5", ["sonnet-4-6", "haiku-4-5", "gpt-6-luna-openai"], ["sonnet-4-6", "gpt-6-luna-openai"]],
        ["tp_compose",             "sonnet-5-5", ["sonnet-4-6", "haiku-4-5", "gpt-6-luna-openai"], ["sonnet-4-6", "haiku-4-5"]],
        ["a0_column_map",          "haiku-5-5",  ["haiku-4-5", "sonnet-4-6", "gpt-6-luna-openai"], ["haiku-4-5", "gpt-6-luna-openai"]],
        ["s1_flag_fix",            "haiku-5-5",  ["haiku-4-5", "sonnet-4-6", "gpt-6-luna-openai"], ["haiku-4-5", "gpt-6-luna-openai"]],
        ["s1_itinerary_nudge",     "haiku-5-5",  ["haiku-4-5", "sonnet-4-6", "gpt-6-luna-openai"], ["haiku-4-5", "gpt-6-luna-openai"]],
        ["t2_flag_fix",            "haiku-5-5",  ["haiku-4-5", "sonnet-4-6", "gpt-6-luna-openai"], ["haiku-4-5", "gpt-6-luna-openai"]],
        ["t2_itinerary_nudge",     "haiku-5-5",  ["haiku-4-5", "sonnet-4-6", "gpt-6-luna-openai"], ["haiku-4-5", "gpt-6-luna-openai"]],
        ["t9_repair",              "haiku-5-5",  ["haiku-4-5", "sonnet-4-6", "gpt-6-luna-openai"], ["haiku-4-5", "gpt-6-luna-openai"]],
        ["segment_research",       "haiku-5-5",  ["haiku-4-5", "sonnet-4-6", "gpt-6-luna-openai"], ["haiku-4-5", "gpt-6-luna-openai"]],
        ["segment_research_batch", "haiku-5-5",  ["haiku-4-5", "sonnet-4-6", "gpt-6-luna-openai"], ["haiku-4-5", "gpt-6-luna-openai"]],
        ["a3_place_card_check",    "haiku-5-5",  ["haiku-4-5", "sonnet-4-6", "llama4-scout"],      ["haiku-4-5", "llama4-scout"]],
        ["a3_place_days",          "haiku-5-5",  ["haiku-4-5", "sonnet-4-6", "nova-lite"],         ["haiku-4-5", "nova-lite"]],
        ["a3_place_locate",        "sonnet-5-5", ["sonnet-4-6", "haiku-4-5", "nova-lite"],         ["sonnet-4-6", "nova-lite"]],
        ["t9_faq_answer_fit",      "sonnet-5-5", ["sonnet-4-6", "haiku-4-5", "nova-lite"],         ["sonnet-4-6", "nova-lite"]],
        ["a3_atomize",             "gpt-6-luna", ["gpt-6-luna-openai", "haiku-5-5", "haiku-4-5", "nova-lite"],
                                                 ["gpt-6-luna-openai", "haiku-5-5", "nova-lite"]],
        ["s1_source_facts",        "gpt-6-luna", ["gpt-6-luna-openai", "haiku-5-5", "haiku-4-5", "nova-lite"],
                                                 ["gpt-6-luna-openai", "haiku-5-5", "nova-lite"]]
    ]$plan$::jsonb;
    stages     text[];
    before     jsonb;                 -- every row: what must not change
    old_fall   jsonb;                 -- every row: its fallbacks before this file
    cap_before jsonb;                 -- every active row: its possible attempts before this file
    outside    text[];
    acc2_only  text[];
    twin_pairs text[];
    changed    text[] := ARRAY[]::text[];
    skipped    text[] := ARRAY[]::text[];
    kept       text[] := ARRAY[]::text[];
    p          jsonb;
    r          record;
    old_f      text[];
    new_f      text[];
    bad        text;
    prev_version bigint;
    prev_snap  jsonb;
    live_snap  jsonb;
    changes    jsonb;
BEGIN
    -- ── 0. Guard: predecessors ───────────────────────────────────────────────────────────────────────────────────
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['366', '367', '370']) AS v (n)
                WHERE NOT EXISTS (SELECT 1 FROM shared.schema_versions s WHERE s.version = v.n)) THEN
        RAISE EXCEPTION 'migration 376: apply 366, 367 and 370 first (family chains, candidate rows, route versions)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'acc3' AND kind = 'bedrock' AND data_scope = 'aws_only') THEN
        RAISE EXCEPTION 'migration 376: connection acc3 is not a bedrock aws_only row';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_provider_connection
                    WHERE connection_key = 'anthropic-direct' AND kind = 'anthropic' AND data_scope = 'vendor_direct') THEN
        RAISE EXCEPTION 'migration 376: connection anthropic-direct is not an anthropic vendor_direct row (304)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shared.llm_model_family WHERE family_key = 'anthropic') THEN
        RAISE EXCEPTION 'migration 376: family anthropic is missing (migration 320)';
    END IF;
    SELECT string_agg(k2, ', ') INTO bad FROM unnest(old_keys) AS k2
     WHERE NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog m
                        WHERE m.model_key = k2 AND m.vendor = 'anthropic' AND m.api_style = 'converse'
                          AND coalesce(m.family, m.vendor) = 'anthropic'
                          AND m.price_in_per_mtok IS NOT NULL AND m.price_out_per_mtok IS NOT NULL);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 376: not an Anthropic Converse catalog row with prices (366 / 367): %', bad;
    END IF;
    SELECT string_agg(m.model_key, ', ') INTO bad FROM shared.llm_model_catalog m
     WHERE m.model_key = ANY (new_keys)
       AND (m.vendor <> 'anthropic' OR m.provider <> 'anthropic' OR m.api_style <> 'anthropic_messages');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 376: % exists and is not an Anthropic Messages API row', bad;
    END IF;
    SELECT string_agg(DISTINCT x, ', ') INTO bad
      FROM jsonb_array_elements(plan) AS e (v)
     CROSS JOIN LATERAL jsonb_array_elements_text(e.v -> 3) AS f (x)
     WHERE NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog m
                        WHERE m.model_key = x AND m.enabled AND 'llm_client' = ANY (m.callable_via));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 376: models of the new chains that are not enabled catalog rows callable by '
                        'llm_client: %', bad;
    END IF;

    SELECT array_agg(e.v ->> 0) INTO stages FROM jsonb_array_elements(plan) AS e (v);
    SELECT coalesce(jsonb_object_agg(stage, to_jsonb(rc) - 'updated_at' - 'updated_by' - 'fallback_model_ids'), '{}'),
           coalesce(jsonb_object_agg(stage, to_jsonb(coalesce(rc.fallback_model_ids, ARRAY[]::text[]))), '{}')
      INTO before, old_fall
      FROM shared.llm_role_config rc;

    -- The possible attempts of every active route BEFORE the new deployments (the attempt_cap count: every
    -- deployment row of every model of the chain, enabled or not, on a connection in the stage's scopes).
    SELECT coalesce(jsonb_object_agg(rc.stage, (
               SELECT count(*) FROM (SELECT DISTINCT unnest(ARRAY[rc.model_id] || coalesce(rc.fallback_model_ids,
                                                                                          ARRAY[]::text[])) AS key) u
                 JOIN shared.llm_model_deployment d ON d.model_key = u.key
                 JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
                WHERE c.data_scope = ANY (coalesce(rc.allowed_scopes, ARRAY['aws_only'])))), '{}')
      INTO cap_before
      FROM shared.llm_role_config rc WHERE rc.is_active;

    -- ── 1. The five Anthropic API catalog rows ──────────────────────────────────────────────────────────────────
    INSERT INTO shared.llm_model_catalog
        (model_key, label, vendor, family, provider, api_style, bedrock_profile_ids, wire_model, callable_via,
         supports_temperature, max_output_tokens, price_in_per_mtok, price_out_per_mtok, price_cache_read_per_mtok,
         price_cache_write_per_mtok, price_source, enabled, blocked_reason, notes, capabilities, updated_by)
    SELECT v.key, v.label, 'anthropic', 'anthropic', 'anthropic', 'anthropic_messages', '{}'::jsonb, v.wire,
           ARRAY['llm_client'], false, 128000, v.p_in, v.p_out, v.p_read, v.p_write,
           'Anthropic first-party list price (claude-api skill model table, cached 2026-10-06), read S269 05/11/2026: '
           'cache read ' || v.read_x || ' input, cache write 1.25x input (5-minute TTL)',
           true, NULL, v.notes, '{}'::jsonb, actor
      FROM (VALUES
            ('fable-5-1', 'Claude Fable 5.1', 'claude-fable-5-1', 10.0000, 50.0000, 0.2500, 12.5000, '0.025x',
             'AA-1042 (S269, CIS 376): reached only by the Anthropic API (anthropic-direct). Anthropic''s most capable '
             'tier, for long-horizon reasoning; thinking always on. Not on any stage chain: above every tier a stage '
             'uses. Requires the account''s 30-day retention (no zero data retention).'),
            ('fable-5', 'Claude Fable 5', 'claude-fable-5', 10.0000, 50.0000, 1.0000, 12.5000, '0.1x',
             'AA-1042 (S269, CIS 376): reached only by the Anthropic API. The previous Fable release (Fable 5.1 is its '
             'successor at the same price). Not on any stage chain.'),
            ('opus-5', 'Claude Opus 5', 'claude-opus-5', 5.0000, 25.0000, 0.5000, 6.2500, '0.1x',
             'AA-1042 (S269, CIS 376): reached only by the Anthropic API. Opus degrade order (quality first): Opus 5.5 > '
             'Opus 5 > Opus 4.8 > Opus 4.7 > Opus 4.6 > Opus 4.5. No stage has an Opus primary today.'),
            ('opus-4-8', 'Claude Opus 4.8', 'claude-opus-4-8', 5.0000, 25.0000, 0.5000, 6.2500, '0.1x',
             'AA-1042 (S269, CIS 376): reached only by the Anthropic API. Opus degrade order: Opus 5.5 > Opus 5 > Opus '
             '4.8 > Opus 4.7 > Opus 4.6 > Opus 4.5.'),
            ('opus-4-7', 'Claude Opus 4.7', 'claude-opus-4-7', 5.0000, 25.0000, 0.5000, 6.2500, '0.1x',
             'AA-1042 (S269, CIS 376): reached only by the Anthropic API. Opus degrade order: Opus 5.5 > Opus 5 > Opus '
             '4.8 > Opus 4.7 > Opus 4.6 > Opus 4.5.')
           ) AS v (key, label, wire, p_in, p_out, p_read, p_write, read_x, notes)
    ON CONFLICT (model_key) DO NOTHING;

    -- ── 2. Opus 4.6 / 4.5: the 367 candidates switched on (Anthropic API path; acc3 rows stay off) ───────────────
    WITH w AS (
        UPDATE shared.llm_model_catalog
           SET enabled        = true,
               blocked_reason = NULL,
               notes          = coalesce(notes || ' ', '') || 'AA-1042 (S269, CIS 376): enabled for the Anthropic API '
                                || 'deployment (the acc3 deployment stays disabled). Opus degrade order: Opus 5.5 > '
                                || 'Opus 5 > Opus 4.8 > Opus 4.7 > Opus 4.6 > Opus 4.5.',
               updated_at     = now(),
               updated_by     = actor
         WHERE model_key = ANY (candidates) AND NOT enabled AND updated_by = 'migration-367-aa1026'
        RETURNING model_key
    )
    SELECT coalesce(array_agg(model_key), ARRAY[]::text[]) INTO kept FROM w;
    SELECT coalesce(array_agg(k3), ARRAY[]::text[]) INTO kept
      FROM unnest(candidates) AS k3
     WHERE NOT (k3 = ANY (kept))
       AND NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog m WHERE m.model_key = k3 AND m.updated_by = actor);
    IF cardinality(kept) > 0 THEN
        RAISE NOTICE 'migration 376: catalog rows an admin changed since 367, left as they are: %',
                     array_to_string(kept, ', ');
    END IF;

    -- ── 3. The nine Anthropic API deployments, behind AWS ───────────────────────────────────────────────────────
    INSERT INTO shared.llm_model_deployment
        (model_key, connection_key, wire_id, priority, enabled, price_cache_read_override, price_cache_write_override,
         batch_capable, request_defaults, origin, notes, updated_by)
    SELECT d.key, 'anthropic-direct', d.v ->> 0, 100, true, (d.v ->> 2)::numeric, (d.v ->> 3)::numeric, false,
           d.v -> 1, 'seed',
           'AA-1042 (S269, CIS 376): the Anthropic API (sponsored key). Priority 100: behind every AWS deployment of '
           'the model (AWS preferred, not only); the prefer_anthropic_api preset moves it first.',
           actor
      FROM jsonb_each(deps) AS d (key, v)
    ON CONFLICT (model_key, connection_key) DO NOTHING;

    -- Reach of every model, after step 3 (every deployment row, enabled or not: the policy, as the admin counts it).
    SELECT coalesce(array_agg(x), ARRAY[]::text[]) INTO outside
      FROM (SELECT d.model_key AS x
              FROM shared.llm_model_deployment d
              JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
             GROUP BY d.model_key
            HAVING bool_and(c.data_scope <> 'aws_only')) o;
    SELECT coalesce(array_agg(x), ARRAY[]::text[]) INTO acc2_only
      FROM (SELECT d.model_key AS x
              FROM shared.llm_model_deployment d
              JOIN shared.llm_model_catalog m ON m.model_key = d.model_key AND m.api_style <> 'embed'
             GROUP BY d.model_key
            HAVING bool_and(d.connection_key = 'acc2')) a;
    -- The vendor twins (shared/llm_client/data_scope.py vendor_twins), as migration 366 computes them.
    WITH base AS (
        SELECT m.model_key, coalesce(m.family, m.vendor) AS fam, m.model_key = ANY (outside) AS out_only,
               regexp_replace(
                   CASE WHEN left(w.id, length(lower(m.vendor)) + 1) = lower(m.vendor) || '.'
                        THEN substr(w.id, length(m.vendor) + 2) ELSE w.id END,
                   '(-v[0-9]+(:[0-9]+)?|:[0-9]+)$', '') AS base
          FROM shared.llm_model_catalog m
         CROSS JOIN LATERAL (
               SELECT regexp_replace(lower(btrim(x)), '^(global|us|eu|apac|jp|au|ca)\.', '') AS id
                 FROM (SELECT pr.value AS x FROM jsonb_each_text(
                           CASE WHEN jsonb_typeof(m.bedrock_profile_ids) = 'object' THEN m.bedrock_profile_ids
                                ELSE '{}'::jsonb END) AS pr
                        WHERE NOT (m.model_key = ANY (outside))
                       UNION ALL
                       SELECT m.wire_model) ids
                WHERE x IS NOT NULL AND btrim(x) <> '') w
         WHERE m.api_style <> 'embed'
    )
    SELECT coalesce(array_agg(DISTINCT v.model_key || '>' || a.model_key), ARRAY[]::text[]) INTO twin_pairs
      FROM base v JOIN base a ON a.fam = v.fam AND a.base = v.base AND a.model_key <> v.model_key
     WHERE v.out_only AND NOT a.out_only AND v.base <> '';

    -- ── 4. The routes ──────────────────────────────────────────────────────────────────────────────────────────
    FOR p IN SELECT v FROM jsonb_array_elements(plan) AS e (v) LOOP
        old_f := ARRAY(SELECT jsonb_array_elements_text(p -> 2));
        new_f := ARRAY(SELECT jsonb_array_elements_text(p -> 3));
        SELECT rc.stage, rc.model_id, rc.is_active, rc.pii_class, coalesce(rc.fallback_model_ids, ARRAY[]::text[]) AS f
          INTO r
          FROM shared.llm_role_config rc WHERE rc.stage = p ->> 0;
        IF NOT FOUND OR r.model_id <> p ->> 1 OR NOT r.is_active OR r.pii_class <> 'content'
           OR r.f = new_f OR r.f <> old_f THEN
            skipped := skipped || (p ->> 0);                 -- no row, re-routed / switched off, or already in place
            CONTINUE;
        END IF;
        UPDATE shared.llm_role_config
           SET fallback_model_ids = new_f,
               updated_at         = now(),
               updated_by         = actor
         WHERE stage = p ->> 0;
        changed := changed || (p ->> 0);
    END LOOP;

    -- ── 5. Guards: catalog, deployments, routes ─────────────────────────────────────────────────────────────────
    SELECT string_agg(k4, ', ') INTO bad FROM unnest(new_keys) AS k4
     WHERE NOT EXISTS (SELECT 1 FROM shared.llm_model_catalog m
                        WHERE m.model_key = k4 AND m.enabled AND m.vendor = 'anthropic' AND m.family = 'anthropic'
                          AND m.provider = 'anthropic' AND m.api_style = 'anthropic_messages'
                          AND 'llm_client' = ANY (m.callable_via)
                          AND m.price_in_per_mtok IS NOT NULL AND m.price_out_per_mtok IS NOT NULL);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 376: catalog rows not an enabled, priced Anthropic Messages API row: %', bad;
    END IF;

    SELECT string_agg(d.key || ' (' || coalesce(x.wire_id, 'none') || ')', ', ' ORDER BY d.key) INTO bad
      FROM jsonb_each(deps) AS d (key, v)
      LEFT JOIN shared.llm_model_deployment x ON x.model_key = d.key AND x.connection_key = 'anthropic-direct'
     WHERE x.wire_id IS NULL OR x.wire_id !~ '^claude-[a-z0-9-]+$'
        OR (x.updated_by = actor AND x.wire_id <> d.v ->> 0);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 376: anthropic-direct deployments missing or not a Claude API model id: %', bad;
    END IF;
    SELECT string_agg(DISTINCT x.model_key, ', ') INTO bad
      FROM shared.llm_model_deployment x
      JOIN shared.llm_model_deployment a ON a.model_key = x.model_key
      JOIN shared.llm_provider_connection c ON c.connection_key = a.connection_key AND c.data_scope = 'aws_only'
     WHERE x.connection_key = 'anthropic-direct' AND x.updated_by = actor AND x.priority <= a.priority;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 376: seeded Anthropic API deployments that would sort ahead of AWS: %', bad;
    END IF;

    SELECT string_agg(rc.stage, ', ' ORDER BY rc.stage) INTO bad
      FROM shared.llm_role_config rc
     WHERE NOT (before ? rc.stage)
        OR to_jsonb(rc) - 'updated_at' - 'updated_by' - 'fallback_model_ids' IS DISTINCT FROM before -> rc.stage
        OR (rc.updated_by = actor AND NOT (rc.stage = ANY (stages)))
        OR (rc.stage = ANY (changed) AND rc.fallback_model_ids IS DISTINCT FROM ARRAY(
                SELECT jsonb_array_elements_text(e.v -> 3) FROM jsonb_array_elements(plan) AS e (v)
                 WHERE e.v ->> 0 = rc.stage))
        OR (NOT (rc.stage = ANY (changed))
            AND to_jsonb(coalesce(rc.fallback_model_ids, ARRAY[]::text[])) IS DISTINCT FROM old_fall -> rc.stage);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 376: route rows changed beyond their decided fallbacks: %', bad;
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(before)) <> (SELECT count(*) FROM shared.llm_role_config) THEN
        RAISE EXCEPTION 'migration 376: a route row appeared or disappeared';
    END IF;

    -- The chain rules (api/services/llm_route_chains.py violations) on every active row: RAISE for a row this file
    -- changed and for ANY row the new deployments push over the attempt cap; NOTICE for the rest (an admin's route is
    -- reported, never rewritten here).
    FOR r IN
        WITH routes AS (
            SELECT rc.stage, rc.role, rc.shadow_model_id,
                   coalesce(rc.allowed_scopes, ARRAY['aws_only']) AS scopes,
                   coalesce(rc.fallback_model_ids, ARRAY[]::text[]) AS f,
                   ARRAY[rc.model_id] || coalesce(rc.fallback_model_ids, ARRAY[]::text[]) AS chain
              FROM shared.llm_role_config rc WHERE rc.is_active
        ), keyed AS (
            SELECT rt.*, kk.key, kk.ord, kk.key = ANY (outside) AS out_only,
                   kk.ord > 1 AND (kk.key || '>' || rt.chain[kk.ord - 1]) = ANY (twin_pairs) AS twin_slot,
                   (SELECT coalesce(m.family, m.vendor) FROM shared.llm_model_catalog m WHERE m.model_key = kk.key) AS fam
              FROM routes rt CROSS JOIN LATERAL unnest(rt.chain) WITH ORDINALITY AS kk (key, ord)
        ), attempts AS (
            SELECT rt.stage, (SELECT count(*) FROM (SELECT DISTINCT unnest(rt.chain) AS key) u
                                JOIN shared.llm_model_deployment d ON d.model_key = u.key
                                JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key
                               WHERE c.data_scope = ANY (rt.scopes)) AS n
              FROM routes rt
        )
        SELECT rt.stage, rules.rule, ac.n FROM routes rt
          JOIN attempts ac ON ac.stage = rt.stage
         CROSS JOIN LATERAL (
            SELECT 'no_fallback' AS rule WHERE cardinality(rt.f) = 0
            UNION ALL
            SELECT 'aws_only_text_stage' WHERE rt.role = ANY (text_roles) AND NOT ('vendor_direct' = ANY (rt.scopes))
            UNION ALL
            SELECT 'vendor_not_last' WHERE EXISTS (
                   SELECT 1 FROM keyed a JOIN keyed b ON a.stage = b.stage AND b.ord > a.ord
                    WHERE a.stage = rt.stage AND a.out_only AND NOT a.twin_slot AND NOT b.out_only)
            UNION ALL
            SELECT 'judge_writer_family' WHERE rt.role = 'judge' AND (
                   EXISTS (SELECT 1 FROM keyed WHERE keyed.stage = rt.stage AND keyed.fam = 'anthropic')
                   OR EXISTS (SELECT 1 FROM shared.llm_model_catalog m WHERE m.model_key = rt.shadow_model_id
                                AND coalesce(m.family, m.vendor) = 'anthropic'))
            UNION ALL
            SELECT 'writer_family' WHERE rt.role = 'writer' AND EXISTS (
                   SELECT 1 FROM keyed WHERE keyed.stage = rt.stage AND keyed.fam IS DISTINCT FROM 'anthropic'
                      AND keyed.fam IS NOT NULL
                      AND NOT (keyed.ord = cardinality(rt.chain) AND keyed.out_only
                               AND 'vendor_direct' = ANY (rt.scopes)))
            UNION ALL
            SELECT 'writer_acc2' WHERE rt.role = 'writer' AND EXISTS (
                   SELECT 1 FROM keyed WHERE keyed.stage = rt.stage AND keyed.key = ANY (acc2_only))
            UNION ALL
            SELECT 'attempt_cap' WHERE ac.n > max_attempts
            UNION ALL
            SELECT 'check_pair_family' WHERE EXISTS (
                   SELECT 1 FROM generate_series(1, cardinality(pairs) / 2) AS g (n)
                     JOIN routes prod ON prod.stage = pairs[2 * g.n]
                    WHERE pairs[2 * g.n - 1] = rt.stage
                      AND EXISTS (SELECT 1 FROM keyed a JOIN keyed b ON a.fam = b.fam
                                   WHERE a.stage = rt.stage AND b.stage = prod.stage))
        ) rules
        ORDER BY 1, 2
    LOOP
        IF r.stage = ANY (changed) THEN
            RAISE EXCEPTION 'migration 376: the new route of % breaks the chain rule %', r.stage, r.rule;
        END IF;
        IF r.rule = 'attempt_cap' AND coalesce((cap_before ->> r.stage)::int, 0) <= max_attempts THEN
            RAISE EXCEPTION 'migration 376: the new Anthropic API deployments would give route % (fallbacks not '
                            'changed here: an admin changed it since 366) % possible attempts, more than %: change its '
                            'chain in the admin route control first', r.stage, r.n, max_attempts;
        END IF;
        RAISE NOTICE 'migration 376: route % (fallbacks not changed here) breaks the chain rule %', r.stage, r.rule;
    END LOOP;

    -- Every changed row still has a model that can be called: enabled in the catalog, with an enabled deployment on
    -- an enabled connection in its scopes (circuits and refusals are runtime: the route control preview shows them).
    SELECT string_agg(rc.stage, ', ' ORDER BY rc.stage) INTO bad
      FROM shared.llm_role_config rc
     WHERE rc.stage = ANY (changed)
       AND NOT EXISTS (
           SELECT 1 FROM unnest(ARRAY[rc.model_id] || rc.fallback_model_ids) AS u (key)
             JOIN shared.llm_model_catalog m ON m.model_key = u.key AND m.enabled
             JOIN shared.llm_model_deployment d ON d.model_key = u.key AND d.enabled
             JOIN shared.llm_provider_connection c ON c.connection_key = d.connection_key AND c.enabled
            WHERE c.data_scope = ANY (coalesce(rc.allowed_scopes, ARRAY['aws_only'])));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration 376: changed routes with no enabled model on an enabled connection: %', bad;
    END IF;

    -- ── 6. The route config version (CIS 370): what this file changed, as one 'external' version ────────────────
    SELECT current_version INTO prev_version FROM shared.llm_route_settings WHERE singleton FOR UPDATE;
    IF prev_version IS NULL THEN
        RAISE EXCEPTION 'migration 376: shared.llm_route_settings has no row (migration 370)';
    END IF;
    SELECT snapshot INTO prev_snap FROM shared.llm_route_config_version WHERE version = prev_version;
    live_snap := jsonb_build_object(
        'order_mode', (SELECT order_mode FROM shared.llm_route_settings WHERE singleton),
        'routes', coalesce((SELECT jsonb_object_agg(stage, jsonb_build_object(
                                       'model_id', model_id,
                                       'fallback_model_ids', to_jsonb(coalesce(fallback_model_ids, '{}'::text[]))))
                              FROM shared.llm_role_config), '{}'::jsonb),
        'priorities', coalesce((SELECT jsonb_object_agg(model_key, pr)
                                  FROM (SELECT model_key, jsonb_object_agg(connection_key, priority) AS pr
                                          FROM shared.llm_model_deployment GROUP BY model_key) d), '{}'::jsonb));
    -- the diff of shared/llm_client/route_versions.diff: order mode, then each stage whose chain differs, then each
    -- model whose provider order (priority, then connection key) differs; a missing side is null
    WITH chains AS (
        SELECT s.stage,
               CASE WHEN prev_snap -> 'routes' ? s.stage
                    THEN jsonb_build_array(prev_snap -> 'routes' -> s.stage -> 'model_id')
                         || coalesce(prev_snap -> 'routes' -> s.stage -> 'fallback_model_ids', '[]'::jsonb) END AS b,
               CASE WHEN live_snap -> 'routes' ? s.stage
                    THEN jsonb_build_array(live_snap -> 'routes' -> s.stage -> 'model_id')
                         || coalesce(live_snap -> 'routes' -> s.stage -> 'fallback_model_ids', '[]'::jsonb) END AS a
          FROM (SELECT jsonb_object_keys(coalesce(prev_snap -> 'routes', '{}')) AS stage
                UNION SELECT jsonb_object_keys(live_snap -> 'routes')) s
    ), orders AS (
        SELECT mk.model,
               (SELECT jsonb_agg(e.key ORDER BY (e.value)::int, e.key)
                  FROM jsonb_each_text(prev_snap -> 'priorities' -> mk.model) e) AS b,
               (SELECT jsonb_agg(e.key ORDER BY (e.value)::int, e.key)
                  FROM jsonb_each_text(live_snap -> 'priorities' -> mk.model) e) AS a
          FROM (SELECT jsonb_object_keys(coalesce(prev_snap -> 'priorities', '{}')) AS model
                UNION SELECT jsonb_object_keys(live_snap -> 'priorities')) mk
    )
    SELECT coalesce(jsonb_agg(x.c ORDER BY x.grp, x.k COLLATE "C"), '[]'::jsonb) INTO changes
      FROM (SELECT 0 AS grp, '' AS k,
                   jsonb_build_object('kind', 'order_mode', 'before', prev_snap -> 'order_mode',
                                      'after', live_snap -> 'order_mode') AS c
             WHERE (prev_snap -> 'order_mode') IS DISTINCT FROM (live_snap -> 'order_mode')
            UNION ALL
            SELECT 1, ch.stage, jsonb_build_object('kind', 'route', 'stage', ch.stage, 'before', ch.b, 'after', ch.a)
              FROM chains ch WHERE ch.b IS DISTINCT FROM ch.a
            UNION ALL
            SELECT 2, o.model, jsonb_build_object('kind', 'provider_order', 'model', o.model, 'before', o.b,
                                                  'after', o.a)
              FROM orders o WHERE o.b IS DISTINCT FROM o.a) x;
    IF jsonb_array_length(changes) > 0 THEN
        INSERT INTO shared.llm_route_config_version (version, created_by, action, note, snapshot, diff)
        VALUES (prev_version + 1, actor, 'external',
                'CIS 376 (S269): Anthropic API deployments for every Claude model of the key, chains fitted to the '
                'six attempts per request.', live_snap, changes);
        UPDATE shared.llm_route_settings
           SET current_version = prev_version + 1, updated_at = now(), updated_by = actor
         WHERE singleton;
    END IF;

    RAISE NOTICE 'migration 376: chains set on: %', coalesce(nullif(array_to_string(changed, ', '), ''), '(none)');
    IF cardinality(skipped) > 0 THEN
        RAISE NOTICE 'migration 376: listed stages left as they are (no row, re-routed or switched off since 366, or '
                     'already in place): %', array_to_string(skipped, ', ');
    END IF;
    RAISE NOTICE 'migration 376: route config version %', (SELECT current_version FROM shared.llm_route_settings
                                                           WHERE singleton);
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('376', now(), 'AA-1042 (S269): every Claude model of the Anthropic API key in the gateway catalog (Fable 5.1 / '
                      '5, Opus 5 / 4.8 / 4.7 rows; Opus 4.6 / 4.5 enabled) with an anthropic-direct deployment behind '
                      'AWS (9 rows, Sonnet 4.6 and Haiku 4.5 included), 20 family chains fitted to the six attempts '
                      'per request, one external route config version')
ON CONFLICT (version) DO NOTHING;

COMMIT;
