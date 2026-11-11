# AA-1041 slice 2 — the planning chat path in the TripPlanner web ACL rules

## Decisions

- `POST /api/trip/chat` (the TripPlanner planning chat: one model call per message, AA-TripPlanner-Web
  `frontend/lib/botCheck.ts` `CHAT_PATH`) joins `local.tp_web_protected_paths` in `accounts/aa365/tripplanner_web_edge.tf`.
  Rules 3 (`TripPlannerRateLimitModelPaths`, per viewer IP) and 4 (`TripPlannerChallengePlanner`) cover it like search,
  narration and "Send to advisor": the same URL_DECODE + NORMALIZE_PATH and the same unanchored match
  (`local.tp_protected_path_regex` in `modules/waf`). No new rule, no new resource, no cost change.

## Changed

- `tp_web_protected_paths`: + `/api/trip/chat`; comments and the `tripplanner_web_model_rate_limit` description say
  "the model calls" (three now) instead of "the two model calls".
- `tools/terraform/tests/test_aa1038_tripplanner_web.py`: the path list, the regex, two dot-segment spellings of the
  chat path and one neighbour (`/api/trip/cha`).

## Tradeoffs

- The model-path rate rule's budget (`var.tripplanner_web_model_rate_limit`, 100 per 5 minutes per IP) is shared by the
  four paths. A traveller chatting and searching at once stays far below it; the app's own limits (20 chat messages
  per hour per session, 40 per IP) are the finer ones.

## Should know

- Apply this before the TripPlanner web deploy of the chat: that repo's Deploy Web Dev now requires HTTP 202 +
  `x-amzn-waf-action: challenge` on `POST /api/trip/chat` without a token.
