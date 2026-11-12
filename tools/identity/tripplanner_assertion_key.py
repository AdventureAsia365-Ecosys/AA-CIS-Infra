#!/usr/bin/env python3
"""TripPlanner tenant assertion key tool (AA-1092, S278 system audit M19). Run by an AWS admin with MFA from a
workstation. Not run by CI, not deployed. Standard library + boto3 only. DRY RUN by default: nothing is written
without --apply.

Fills and rotates the secret shell modules/environment/tripplanner.tf creates, so no key passes through a terminal, a
file or a Terraform state read:

  tripplanner/<env>/tenant-assertion-key   {current, previous, previous_until, edge_derived_until}

  current             the key the TripPlanner BFF signs the tenant assertion with (web task env
                      TP_TENANT_ASSERTION_KEY, mapped from this field). 48 random bytes, URL-safe (64 characters).
  previous            the key current replaced, accepted by the Lambdas until previous_until (rotation only).
  previous_until      epoch seconds; the grace a rotation gives the web task to pick up the new key (its next
                      deployment). At most 7 days: the Lambdas ignore a longer one (AA-TripPlanner-Web
                      backend/config.py TENANT_ASSERTION_MAX_GRACE_S), so this tool refuses it.
  edge_derived_until  epoch seconds; first fill only: the Lambdas keep accepting the pre-AA-1092 key derived from the
                      edge key until then, so the web task that still signs with it keeps working until its deploy.

Modes:
  (default)   first fill. Refuses when the secret already holds a key (use --rotate). Writes current and
              edge_derived_until = now + --grace-hours (default 24).
  --rotate    new current; previous = the old current; previous_until = now + --grace-hours. Drops any expired
              edge_derived_until. After --apply, WAIT at least LAMBDA_SECRET_CACHE_S (10 minutes, the Lambdas'
              secret cache, AA-TripPlanner-Web config.API_KEY_CACHE_SECONDS), then force a new deployment of
              aa-tripplanner-<env>-web: the Lambdas accept both keys until previous_until. A web task that signs with
              the new key before a warm Lambda re-read the secret would be refused (401) until that Lambda's cache
              expires; the Lambdas also re-read once on a signature miss (throttled), but the wait is the rule.
  --end-cutover  ends the first-fill cut-over early: keeps current (and an unexpired previous) and drops
              edge_derived_until, so the Lambdas refuse the pre-AA-1092 edge-derived key once their secret cache
              expires (at most LAMBDA_SECRET_CACHE_S). No new key, no deploy. Run it only after the web task signs
              with current (its deploy after the first fill). Refuses when there is no cut-over window to end.

The first fill has the same wait: the web deploy that maps the new current runs at least LAMBDA_SECRET_CACHE_S after
the write. The output carries deploy_not_before (epoch seconds) for both modes.

Values are never printed: the output is one JSON line with the secret name, the action, the fields written and the
version id. Account guard: refuses to run unless the credentials are for --expect-account.
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
import time
from typing import Any, Callable

DEFAULT_PROFILE = "aa365-admin"
DEFAULT_REGION = "us-west-1"
DEFAULT_ACCOUNT = "005097885195"
DEFAULT_ENV = "dev"

SECRET = "tripplanner/{env}/tenant-assertion-key"
PLACEHOLDER = "REPLACE_ME"
MIN_KEY_LENGTH = 32  # AA-TripPlanner-Web config.TENANT_ASSERTION_KEY_MIN_LENGTH
MAX_GRACE_HOURS = 7 * 24  # AA-TripPlanner-Web config.TENANT_ASSERTION_MAX_GRACE_S
DEFAULT_GRACE_HOURS = 24
# AA-TripPlanner-Web config.API_KEY_CACHE_SECONDS: how long a warm Lambda keeps the secret it read. A web deploy that
# starts signing with a new current must wait this long after the write.
LAMBDA_SECRET_CACHE_S = 600
FIELDS = ("current", "previous", "previous_until", "edge_derived_until")


class ToolError(Exception):
    """A refusal or an AWS failure, printed as one line (no traceback)."""


def out(line: dict[str, Any]) -> None:
    print(json.dumps(line, ensure_ascii=False), flush=True)


def new_key() -> str:
    return secrets.token_urlsafe(48)


def _secret_exists(sm: Any, name: str) -> bool:
    try:
        sm.describe_secret(SecretId=name)
        return True
    except sm.exceptions.ResourceNotFoundException:
        return False


def current_value(sm: Any, name: str) -> dict[str, Any]:
    """The stored JSON object; {} for a shell without a value or the placeholder. Anything else that is not the
    expected object is refused: the tool never overwrites a value it does not understand."""
    try:
        raw = sm.get_secret_value(SecretId=name)["SecretString"]
    except sm.exceptions.ResourceNotFoundException:
        return {}
    text = (raw or "").strip()
    if text in ("", PLACEHOLDER):
        return {}
    try:
        data = json.loads(text)
    except ValueError as exc:
        raise ToolError(f"{name} holds a value that is not JSON: fix it by hand, the tool will not overwrite it") from exc
    if not isinstance(data, dict) or not set(data) <= set(FIELDS):
        raise ToolError(f"{name} holds JSON with unexpected fields: fix it by hand, the tool will not overwrite it")
    if data.get("current") in (None, "", PLACEHOLDER):
        return {}
    return data


def wanted_value(current: dict[str, Any], *, rotate: bool, grace_hours: int, now: int,
                 make_key: Callable[[], str] = new_key) -> dict[str, Any]:
    if grace_hours < 1 or grace_hours > MAX_GRACE_HOURS:
        raise ToolError(f"--grace-hours must be between 1 and {MAX_GRACE_HOURS} (the Lambdas ignore a longer grace)")
    until = now + grace_hours * 3600
    key = make_key()
    if len(key) < MIN_KEY_LENGTH:
        raise ToolError("generated key is too short")
    if not rotate:
        if current:
            raise ToolError("the secret already holds a key: use --rotate")
        return {"current": key, "edge_derived_until": until}
    if not current:
        raise ToolError("the secret holds no key yet: run the first fill (without --rotate)")
    old = current.get("current")
    if not isinstance(old, str) or len(old.strip()) < MIN_KEY_LENGTH:
        raise ToolError("the stored current key is not usable: fix it by hand")
    value: dict[str, Any] = {"current": key, "previous": old, "previous_until": until}
    edge_until = current.get("edge_derived_until")
    if isinstance(edge_until, int) and not isinstance(edge_until, bool) and edge_until > now:
        value["edge_derived_until"] = edge_until  # a rotation inside the cut-over window keeps it
    return value


def _epoch(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def ended_cutover_value(current: dict[str, Any], *, now: int) -> dict[str, Any]:
    """The stored value without edge_derived_until: current kept, previous kept only while its grace runs."""
    if not current:
        raise ToolError("the secret holds no key yet: run the first fill (without --rotate)")
    if (_epoch(current.get("edge_derived_until")) or 0) <= now:
        raise ToolError("there is no cut-over window to end (edge_derived_until is absent or already past)")
    value: dict[str, Any] = {"current": current["current"]}
    prev_until = _epoch(current.get("previous_until"))
    if current.get("previous") and prev_until and prev_until > now:
        value["previous"], value["previous_until"] = current["previous"], prev_until
    return value


def write_secret(sm: Any, env: str, *, rotate: bool, grace_hours: int, apply: bool,
                 now: int | None = None, make_key: Callable[[], str] = new_key,
                 end_cutover: bool = False) -> dict[str, Any]:
    name = SECRET.format(env=env)
    if not _secret_exists(sm, name):
        raise ToolError(f"{name} does not exist: apply AA-CIS-Infra modules/environment/tripplanner.tf first (the shell)")
    if end_cutover and rotate:
        raise ToolError("--end-cutover and --rotate are separate steps: run one at a time")
    t = int(time.time() if now is None else now)
    stored = current_value(sm, name)
    if end_cutover:
        wanted = ended_cutover_value(stored, now=t)
    else:
        wanted = wanted_value(stored, rotate=rotate, grace_hours=grace_hours, now=t, make_key=make_key)
    result: dict[str, Any] = {
        "secret": name,
        "mode": "end_cutover" if end_cutover else "rotate" if rotate else "first_fill",
        "fields": sorted(wanted),
        "grace_until": wanted.get("previous_until", wanted.get("edge_derived_until")),
    }
    if not apply:
        result["action"] = "would_write"
        return result
    resp = sm.put_secret_value(SecretId=name, SecretString=json.dumps(wanted))
    result["action"] = "written"
    result["version_id"] = resp.get("VersionId")
    if end_cutover:
        result["refused_from"] = t + LAMBDA_SECRET_CACHE_S
        result["next"] = (f"the edge-derived key is refused once the Lambdas' secret cache expires (at most "
                          f"{LAMBDA_SECRET_CACHE_S // 60} minutes, refused_from); no deploy needed")
        return result
    result["deploy_not_before"] = t + LAMBDA_SECRET_CACHE_S
    wait = f"wait {LAMBDA_SECRET_CACHE_S // 60} minutes (until deploy_not_before, the Lambdas' secret cache), then "
    result["next"] = wait + (
        "deploy AA-TripPlanner-Web (Deploy Web Dev) so the web task maps the key"
        if not rotate else f"force a new deployment of aa-tripplanner-{env}-web before grace_until"
    )
    return result


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="AA-1092 TripPlanner tenant assertion key. DRY RUN unless --apply.")
    p.add_argument("--profile", default=DEFAULT_PROFILE, help="AWS profile ('' = default chain/env)")
    p.add_argument("--region", default=DEFAULT_REGION)
    p.add_argument("--expect-account", default=DEFAULT_ACCOUNT, help="refuse to run in any other account")
    p.add_argument("--env", default=DEFAULT_ENV)
    p.add_argument("--rotate", action="store_true", help="replace current; the old one stays valid for --grace-hours")
    p.add_argument("--grace-hours", type=int, default=DEFAULT_GRACE_HOURS)
    p.add_argument("--end-cutover", action="store_true",
                   help="drop edge_derived_until now (after the web task signs with current); no new key")
    p.add_argument("--apply", action="store_true")
    return p


def main(argv: list[str] | None = None, clients: tuple[Any, Any] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if clients is None:
            import boto3  # noqa: PLC0415 — only when talking to AWS

            session = boto3.Session(profile_name=args.profile or None, region_name=args.region)
            sts, sm = session.client("sts"), session.client("secretsmanager")
        else:
            sts, sm = clients
        account = sts.get_caller_identity()["Account"]
        if args.expect_account and account != args.expect_account:
            raise ToolError(f"refused: credentials are for account {account}, expected {args.expect_account}")
        out(write_secret(sm, args.env, rotate=args.rotate, grace_hours=args.grace_hours, apply=args.apply,
                         end_cutover=args.end_cutover))
        return 0
    except ToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — one line, no traceback
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
