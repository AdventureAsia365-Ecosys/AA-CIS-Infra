# AA-1093 follow-up (S279 lane l25-tp-erase-feed-cadence): the TripPlanner erasure feed schedule

Infra half of the lane; the app half is AA-TripPlanner-Web `docs/implementation-notes/AA-1093-l25-tp-erase-feed-cadence.md`
(jobs op `erasure_feed`).

## Decisions

- **A second `aws_scheduler_schedule` on the same function and invoke role**, `rate(5 minutes)`
  (`tripplanner_jobs_erasure_feed_schedule_expression`, declared in the module and the root, passed through like the
  other TripPlanner settings), input `{"op": "erasure_feed", "source": "aa-1093-erasure-feed"}`. The daily tick is
  untouched.
- **No flexible window, no delivery retry, event age 300 s**: a missed run is replaced by the next one; the app's
  idempotency key per request, round and phase makes a doubled run harmless.
- **Reserved concurrency stays 1** (connection budget pool `tp-jobs`). The scheduler invokes asynchronously: a run
  that meets a busy function waits in Lambda's async queue (`maximum_event_age_in_seconds = 3600` of the event invoke
  config), so the daily tick is never dropped by a feed run and the other way round.
- **The not-run alarm moves from `AWS/Lambda Invocations` to a log metric filter** on the tick's own line
  (`{ ($.evt = "jobs_run") && ($.op = "tick") }`, `AA/TripPlanner JobsTickRuns`, no default_value): with the feed
  invoking the function 288 times a day, Invocations would never alarm on a stopped tick.

## Changed (vs the lane brief)

- Added the alarm change: not in the brief, but without it the 5-minute schedule silently disarms the not-run alarm.

## Tradeoffs

- The cadence is a Terraform variable, not an admin-editable setting: it is the EventBridge wake-up interval, which
  the app never reads (like Booking's technical `SLOT_SECONDS = 300`). Cost about 0 USD/month (free tiers; one
  metric-hour a day for the filter), stated in the `tripplanner_jobs.tf` header.

## Should know

- Apply after the TripPlanner deploy that ships op `erasure_feed`. Before it, the old code answers
  `{"error": "unknown op ..."}` without raising (no alarm), so the order is not dangerous, only useless.
- After the apply, `aa-tripplanner-dev-jobs-not-run` reads the new metric, which has no data point yet (the filter
  only counts lines written after it exists). Missing data is breaching, so the alarm goes to ALARM (one e-mail) until
  a tick line lands. Live step: right after the apply, invoke `{"op":"tick"}` once (a second tick the same UTC day
  queues nothing, the idempotency key is per kind and day; before 19:30 UTC it runs that day's scheduled jobs early,
  which is the same work), then the alarm returns to OK on its next evaluation.
