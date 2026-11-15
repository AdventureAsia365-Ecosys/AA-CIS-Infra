-- Migration 427: AA-1051 + AA-1096 follow-up (S281 lane l14) -- the platform settings registry keys whose code is on
-- main are marked enforced.
--
-- Why. CIS 411 (erasure saga), 417 / 423 / 426 (claim-instrument evaluation, two-step evaluation, fresh pool, R1
-- firing sample), 419 (W5 writer proofs), 420 / 425 (AA Academy) seeded their keys with enforced = false (the page badge
-- "Not enforced yet") because the code that reads them shipped in a later PR (MIG-4), and the settings-lint guard
-- (tests/unit/test_s279_settings_lint.py) refuses an enforced key that no code names. Every one of those PRs is on main
-- now, and 34 of the 36 keys are read through the settings reader (shared/settings, settings.get / aget):
--   * cis.erasure.crm_window_days, saga_apply_enabled, saga_approval_valid_hours: services/tenant_erasure/policy.py
--     (the saga job, the admin erasure router);
--   * twelve cis.learn.* keys: services/learn/academy.py, services/learn/assessment.py, api/routers/learn.py;
--   * cis.quality.instrument_eval_*_min_pct and cis.spend.instrument_eval_*: services/ground_truth/instrument_eval.py;
--   * cis.quality.claim_two_step_*_min_pct: services/ground_truth/two_step.py; cis.quality.claim_fresh_pool_sample_max:
--     services/ground_truth/fresh_pool.py; cis.quality.claim_fire_sample_max: services/ground_truth/r1_fire.py;
--   * cis.quality.writer_proof_*_min_items and cis.spend.writer_proof_*_cap_usd: services/writer_proof/prereg.py
--     (workflow_cap, min_items, total_cap; used by the runner and the spend gate).
-- Two keys stay not enforced, because no code reads them yet:
--   * cis.content.trash_retention_days (CIS 407): no purge job reads it; the Settings > Plan card still shows a fixed 30.
--   * cis.learn.learner_retention_days (CIS 420): the learn_retention job that deletes ended learners has not shipped.
--     Its description said the learning API reads it; this file corrects the description.
--
-- What.
--   1. The block between "settings-edit:begin" and "settings-edit:end" (read by scripts/settings/gen_compiled_defaults.py
--      into shared/settings/compiled_defaults.json, the file the reader and the admin API serve; the seed-parity test
--      keeps the two equal): enforced = true for the 34 keys, and each description without its "from the release that
--      ships it; marked enforced by a later migration" clause; the learner retention description says it is not
--      enforced yet.
--   2. A post-check: every row of the block exists with its new fields (a misspelt key would otherwise leave the badge
--      in place without an error). It does not refuse other not-enforced keys: a key seeded later with enforced = false
--      (its code still to ship, e.g. the tenant TripPlanner custom domain keys) is legitimate.
--   3. Register 427.
--
-- Behaviour on apply. None for running code: the reader and the admin API serve the compiled defaults (regenerated
-- from this block in the same PR), and the enforced flag only drives the page badge and settings-lint. No value,
-- bound, approval rule or default changes.
--
-- Class: CONTRACT (root ADR 0017 decision 3; no migrate directive line): UPDATEs of existing config rows and one DO
-- block (the post-check). No readiness raise. MIG-4 deviation, the CIS 424 precedent (recorded in the implementation
-- notes): this file ships in ONE PR with the regenerated compiled_defaults.json and the tests that read the flag,
-- because the seed-parity test binds this block, the generator and compiled_defaults.json together (either half alone
-- is red), and the flag changes no behaviour, so a deploy before the apply changes only the page badge. On Dev, Infra
-- Migration Apply once every job table is idle (root ADR 0017a). DM-6.1: no personal data. DM-7.1: no new table.
--
-- Number. 426 is the newest CIS migration on main (15/11/2026), so this is 427 (main max + 1). The open tenant
-- TripPlanner custom domain batch (waiting on a cost approval) moves to 428-429 when it rebases. If the owner main
-- max + 1 differs at merge, renumber (git grep '427' here, in tests/integration/test_aa1051_migration_427.py,
-- compiled_defaults.json's _generated line and the implementation notes docs/implementation-notes/AA-1051.md).
--
-- Locks. UPDATEs of 35 rows of a small table read by no hot path (the reader reads shared.setting_value); the
-- definition guard trigger (CIS 407) allows the file's role, cis_owner. lock_timeout 5s. Re-runnable (the Integration
-- Tests replay every file): the UPDATE skips equal rows.
--
-- Rollback (a new forward migration): enforced = false for the keys (only if their code is reverted; the code needs
-- no change).

BEGIN;
SET LOCAL lock_timeout = '5s';

-- settings-edit:begin (scripts/settings/gen_compiled_defaults.py reads the JSON array of the dollar-quoted block)
CREATE TEMP TABLE IF NOT EXISTS m427_edit (key text PRIMARY KEY, doc jsonb NOT NULL) ON COMMIT DROP;
INSERT INTO m427_edit (key, doc)
SELECT e.doc ->> 'key', e.doc
  FROM jsonb_array_elements($edit$[
{"key": "cis.erasure.crm_window_days", "enforced": true, "description": "Days after a tenant's offboarding before the erasure saga erases its partner CRM data (stage 2), without the owner's click (decision D2). CIS, Booking and TripPlanner use the offboarded tenant retention instead (stage 1). Read by the tenant erasure saga."},
{"key": "cis.erasure.saga_apply_enabled", "enforced": true, "description": "On: a Cognito administrator may approve a tenant erasure round and the apps then erase the tenant's data (CIS also needs its own data_erasure switch). Off (default): DRY RUNs only. Read by the tenant erasure saga."},
{"key": "cis.erasure.saga_approval_valid_hours", "enforced": true, "description": "Hours a combined erasure fingerprint may still be approved after it was computed, and hours an approval stays valid for the apps to apply (decision D7). Past it the tech lead starts a new DRY RUN round. Read by the tenant erasure saga."},
{"key": "cis.learn.final_quiz_items_per_module", "enforced": true, "description": "Research section 4.3: how many questions the final mixed quiz of a path draws from each required module (fewer when a module has fewer items that are not suspended). Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.learn.final_quiz_pass_mark_pct", "enforced": true, "description": "Decision D7 / research section 4.3: the lowest score, in percent, that passes the final mixed quiz of a learning path (drawn from every required module). Passing it, with every required module complete, issues the path certificate. Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.learn.learner_retention_days", "description": "Decision D11 (data standards DM-7.1 learn rows): learning records are kept while the account is active, and deleted this many days after the staff account was deactivated or removed, by the learn_retention job (its first run is a DRY RUN). A change of this window is a DM-7.5 amendment. Not enforced yet: no code reads it until the learn_retention job ships; a later migration marks it enforced then."},
{"key": "cis.learn.quiz_items_per_attempt", "enforced": true, "description": "Research section 4.2: the most questions the server draws for one module quiz attempt, from the module's items that are not suspended. A module with fewer items uses all of them. Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.learn.quiz_pass_mark_pct", "enforced": true, "description": "Decision D7 of the AA Academy research: the lowest score, in percent of the drawn items, that passes a module quiz. A module is complete when its required lessons are done and its quiz is passed at or above this mark. Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.learn.quiz_retake_delay_hours", "enforced": true, "description": "Decision D7: how many hours a learner waits after a failed quiz (module or final) before the next attempt opens. The wait makes a retake a second recall, not a guess at the answers just shown. Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.learn.recert_months", "enforced": true, "description": "Decision D7: how many months a certificate of a path listed in cis.learn.recert_paths stays valid before it expires and the holder certifies again. Certificates of other paths do not expire (they still need renewal when a required module gets a major version). Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.learn.recert_paths", "enforced": true, "description": "Decision D7: the learning path ids whose certificates expire after cis.learn.recert_months. Every other path certificate stays valid until a required module gets a major version or a new required module is added. Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.learn.review_max_cards_per_day", "enforced": true, "description": "Research section 4.3: the most spaced-review cards the due list returns to one learner per day; the rest wait for the next day. Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.learn.review_target_retention", "enforced": true, "description": "Research section 5.4 (spaced review with FSRS, ts-fsrs in the browser): the share of review cards a learner should still recall when a card comes due. The browser schedules with it; the API returns it with the due cards. Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.learn.verify_requests_per_minute", "enforced": true, "description": "ADR 0022 decision 6 (accepted, S280): how many public certificate verify requests one client address may make per minute on /learn/public/v1/certificates/{code}; more answer 429. Slows down guessing codes (128-bit, stored as SHA-256). Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.learn.verify_visitor_requests_per_minute", "enforced": true, "description": "ADR 0022 decision 11: the academy web calls the public verify route /learn/public/v1/certificates/{code} from its server, so all its visitors reach CIS from one address and cis.learn.verify_requests_per_minute caps the whole web. This is how many verify requests one visitor of the academy web may make per minute: CIS sends it on every verify answer (response header X-Learn-Visitor-Limit, contract learn.http.v1) and the academy web refuses a visitor over it before it calls CIS. CIS sends at most the per-address limit minus one, so one visitor can never use up the web's whole budget. Read by the AA Academy learning API."},
{"key": "cis.learn.video_url_ttl_seconds", "enforced": true, "description": "Decision D8: how long the presigned S3 link to a lesson video (and its captions) works after the learning API issues it. The browser starts the video within that time; a seek keeps working on the open stream, a page reload asks for a new link. Read by the AA Academy learning API (/learn/v1)."},
{"key": "cis.quality.claim_fire_sample_max", "enforced": true, "description": "The most unlabelled claims one R1 firing run may check (a deterministic, salted sample spread over the writers in proportion, drawn from claims on pieces no earlier claim-instrument evaluation touched). The fresh-pool sheet then draws its claims from the ones R1 fired on. It sets the paid calls of the firing run; the run's spending cap is cis.spend.instrument_eval_cap_usd. Read by the firing run."},
{"key": "cis.quality.claim_fresh_pool_sample_max", "enforced": true, "description": "The most claims one fresh-pool sample may draw for the labelling sheet of a claim-instrument evaluation (R1-fired claims on pieces no earlier evaluation touched; the agent panel labels every drawn claim, then about half are false positives and half violations). Read by the fresh-pool builder."},
{"key": "cis.quality.claim_two_step_judge_fp_drop_min_pct", "enforced": true, "description": "Per-step go / no-go bar of the two-step claim-instrument evaluation: of the false positives (claims judged ok that the R1 instrument fired on) step 1 sent on, step 2 must clear at least this percentage. When step 1 cleared every false positive the bar holds. Fixed in the pre-registration before any data; read by the two-step evaluation."},
{"key": "cis.quality.claim_two_step_judge_tp_keep_min_pct", "enforced": true, "description": "Per-step go / no-go bar of the two-step claim-instrument evaluation: of the stored violations step 1 sent on, step 2 (is each new specific supported by the source) must flag at least this percentage. Fixed in the pre-registration before any data; read by the two-step evaluation."},
{"key": "cis.quality.claim_two_step_route_tp_min_pct", "enforced": true, "description": "Per-step go / no-go bar of the two-step claim-instrument evaluation: step 1 (restatement of the source or new claim) must send at least this percentage of the subset's stored violations on to step 2. A violation that step 1 calls a restatement is lost for good. Fixed in the pre-registration before any data; read by the two-step evaluation."},
{"key": "cis.quality.instrument_eval_fp_drop_min_pct", "enforced": true, "description": "Go / no-go bar of a claim-instrument evaluation: the new prompt version must clear at least this percentage of the subset's false positives (claims the panel judged ok that R1 fired on). Read by the evaluation."},
{"key": "cis.quality.instrument_eval_tp_keep_min_pct", "enforced": true, "description": "Go / no-go bar of a claim-instrument evaluation: the new prompt version must still flag at least this percentage of the subset's stored violations (out of sample; the approved relabels are in-sample for a prompt drawn from them, so they are reported apart and never count toward this bar). Read by the evaluation."},
{"key": "cis.quality.writer_proof_null_run_min_items", "enforced": true, "description": "The fewest golden samples (GATE side) a registered null run pre-registration may fix. The power check still decides whether the sample is big enough for the pre-registered effect; this is the floor below which no file can be registered. Read by the W5 proof runner (services/writer_proof)."},
{"key": "cis.quality.writer_proof_s1_min_items", "enforced": true, "description": "The fewest golden samples (GATE side) a registered S1 tour rewrite proof pre-registration may fix. The power check still decides whether the sample is big enough for the pre-registered effect; this is the floor below which no file can be registered. Read by the W5 proof runner (services/writer_proof)."},
{"key": "cis.quality.writer_proof_t2_min_items", "enforced": true, "description": "The fewest golden samples (GATE side) a registered T2 tenant tour writer proof pre-registration may fix. The power check still decides whether the sample is big enough for the pre-registered effect; this is the floor below which no file can be registered. Read by the W5 proof runner (services/writer_proof)."},
{"key": "cis.quality.writer_proof_t9_min_items", "enforced": true, "description": "The fewest golden samples (GATE side) a registered T9 blog writer proof pre-registration may fix. The power check still decides whether the sample is big enough for the pre-registered effect; this is the floor below which no file can be registered. Read by the W5 proof runner (services/writer_proof)."},
{"key": "cis.spend.instrument_eval_cap_usd", "enforced": true, "description": "Hard cap in USD of one claim-instrument evaluation run (a new prompt version measured on claims the R1 instrument fired on). Every call is gated on the spend so far plus its worst case; the run stops before it would pass the cap. Never above the R1 harness hard cap of 2 USD. Read by the evaluation."},
{"key": "cis.spend.instrument_eval_max_claims", "enforced": true, "description": "The most claims one claim-instrument evaluation run may take (half false positives, half true positives of the claims the R1 instrument fired on). Read by the evaluation."},
{"key": "cis.spend.instrument_eval_trial_claims", "enforced": true, "description": "The most claims the paid trial of a claim-instrument evaluation may take before the full subset run (check the cost per call in the ledger first). Read by the evaluation."},
{"key": "cis.spend.writer_proof_null_run_cap_usd", "enforced": true, "description": "Root ADR 0020 D12: the most USD the eval null run (the T9 blog writer, no change) may spend on AI calls, ledger spend plus the caps of its queued or running jobs (shared.llm_call_log, stage adhoc_aa1051). A pre-registration's own cap_usd must be at or below it; each run also needs the tech lead's own yes. Read by the W5 proof runner (services/writer_proof)."},
{"key": "cis.spend.writer_proof_s1_cap_usd", "enforced": true, "description": "Root ADR 0020 D12: the most USD the S1 tour rewrite proof may spend on AI calls, ledger spend plus the caps of its queued or running jobs (shared.llm_call_log, stage adhoc_aa1051). A pre-registration's own cap_usd must be at or below it; each run also needs the tech lead's own yes. Read by the W5 proof runner (services/writer_proof)."},
{"key": "cis.spend.writer_proof_t2_cap_usd", "enforced": true, "description": "Root ADR 0020 D12: the most USD the T2 tenant tour writer proof may spend on AI calls, ledger spend plus the caps of its queued or running jobs (shared.llm_call_log, stage adhoc_aa1051). A pre-registration's own cap_usd must be at or below it; each run also needs the tech lead's own yes. Read by the W5 proof runner (services/writer_proof)."},
{"key": "cis.spend.writer_proof_t9_cap_usd", "enforced": true, "description": "Root ADR 0020 D12: the most USD the T9 blog writer proof may spend on AI calls, ledger spend plus the caps of its queued or running jobs (shared.llm_call_log, stage adhoc_aa1051). A pre-registration's own cap_usd must be at or below it; each run also needs the tech lead's own yes. Read by the W5 proof runner (services/writer_proof)."},
{"key": "cis.spend.writer_proof_total_cap_usd", "enforced": true, "description": "Root ADR 0020 D12: the most USD all W5 writer proofs together may spend on AI calls (every adhoc_aa1051 ledger row plus the caps of every queued or running W5 job). Each run also needs the tech lead's own yes. Read by the W5 proof runner (services/writer_proof)."}
]$edit$::jsonb) AS e (doc)
ON CONFLICT (key) DO UPDATE SET doc = EXCLUDED.doc;
-- settings-edit:end

UPDATE shared.setting_definition AS d
   SET enforced    = CASE WHEN e.doc ? 'enforced' THEN (e.doc ->> 'enforced')::boolean ELSE d.enforced END,
       description = COALESCE(e.doc ->> 'description', d.description)
  FROM m427_edit AS e
 WHERE d.key = e.key
   AND (d.enforced IS DISTINCT FROM CASE WHEN e.doc ? 'enforced' THEN (e.doc ->> 'enforced')::boolean
                                         ELSE d.enforced END
        OR d.description IS DISTINCT FROM COALESCE(e.doc ->> 'description', d.description));

-- Post-check: every row of the block exists with its new fields.
DO $check$
DECLARE
    missing text;
BEGIN
    SELECT string_agg(e.key, ', ' ORDER BY e.key) INTO missing
      FROM m427_edit AS e
     WHERE NOT EXISTS (
           SELECT 1 FROM shared.setting_definition AS d
            WHERE d.key = e.key
              AND (NOT e.doc ? 'enforced' OR d.enforced = (e.doc ->> 'enforced')::boolean)
              AND (NOT e.doc ? 'description' OR d.description = e.doc ->> 'description'));
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'CIS 427: no definition or not edited: %', missing;
    END IF;
END
$check$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('427', now(), 'AA-1051 + AA-1096: mark the settings registry keys read by code on main enforced')
ON CONFLICT (version) DO NOTHING;

COMMIT;
