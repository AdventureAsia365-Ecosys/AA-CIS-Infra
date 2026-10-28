#!/usr/bin/env python3
"""Environment config register for the AA-Ecosys root repo (AA-894 scope 5, catalog APP-03).

Renders docs/generated/env-config.md: the NAMES of the environment variables every runtime of the
ecosystem gets, with where each one comes from. Never a value.

  ECS      every service of the cluster (aa-cis-dev-api, aa-cis-dev-worker, aa-booking-dev-api, ...):
           the task definition the PRIMARY deployment runs. `environment[].name` (plain) and
           `secrets[]` as name + Secrets Manager secret NAME (or SSM parameter name); the secret is
           never resolved.
  Lambda   every function of the account: the KEYS of `Environment.Variables`.
  Vercel   every project: env var key, kind (sensitive = write-only, readable = a project member can
           read it) and targets. Read live from the Vercel REST API when a token is given, otherwise
           from the checked-in snapshot tools/docs/env_config_vercel.json (names only).

Values never leave the extraction functions: `extract_*` keep names and secret names only, so the
names-only model (JSON) and the page cannot carry a value. For AWS the CLI --query projections already
drop them (Lambda: only `keys(Environment.Variables)`), so they never reach this process at all. tests/test_gen_env_config.py plants
values in every input and asserts they reach neither.

The page lands in the root repo next to the Terraform pages (gen_docs.py) through the same bot PR
(.github/workflows/docs-gen.yml). It carries no task-definition revision, image tag or date of
capture outside the header, so it changes only when a name, a source or a target changes.

Subcommands:
  collect-aws      --cluster NAME --out FILE [--profile P]
                   AWS CLI v2, read-only (ecs:Describe*/List*, lambda:ListFunctions,
                   secretsmanager:ListSecrets); every call projects names with --query
  vercel-snapshot  (--cli | --api) [--project P ...] --out FILE
                   --cli runs `vercel env ls --project P` (local, logged-in CLI) and keeps only the
                   name, type and environments columns; --api reads VERCEL_TOKEN (and VERCEL_TEAM_ID)
                   from the environment.
  render           --aws FILE --vercel FILE --out-dir DIR [--source TEXT] [--sha SHA] [--date D]
                   [--require-ecs S ...] [--require-lambda F ...] [--require-vercel P ...]
                   exits 1 without writing the page when a required runtime is missing (fail closed:
                   a page that silently lost a service is worse than no new page).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_docs as gd  # noqa: E402

PAGE = "env-config.md"
FORMAT = 1
VERCEL_SNAPSHOT = Path(__file__).resolve().parent / "env_config_vercel.json"

SPEC = gd.PageSpec(
    PAGE,
    "APP-03",
    "Environment config register",
    "Generated list of the environment variable NAMES of every ECS service, Lambda function and Vercel project, with the source of each (plain, secret by name, Vercel kind); never a value.",
    ("APP-01", "docs/security/secrets-register.md", "AA-894"),
)

BLURB = (
    "> **Generated - do not edit. Names only, never a value.** Source: {source}. AA-CIS-Infra",
    "> `tools/docs/gen_env_config.py` renders it nightly from the live ECS task definitions, Lambda configurations and",
    "> Vercel projects; a secret is listed by its store name and never read. To change a row, change the app's",
    "> Terraform, task definition or Vercel project.",
)

# Coverage the page must have (AA-894 Done-when 5). Missing one = collection problem, no page.
REQUIRED_ECS = ("aa-cis-dev-api", "aa-cis-dev-worker", "aa-booking-dev-api")
REQUIRED_LAMBDA = ("aa-tripplanner-dev-browse", "aa-tripplanner-dev-assembly")
# AA-979 P2b clean-up: aa-cis-portal is gone (the Content studio runs on ECS, aa-crm-dev-portal).
REQUIRED_VERCEL = ("aa-cis-frontend", "aa-booking-admin", "aa-tripplanner")

# Sections of the page, by runtime-name prefix (ECS service, Lambda function, Vercel project).
APPS = (
    ("aa-cis-", "CIS"),
    ("aa-booking-", "Booking"),
    ("aa-tripplanner", "TripPlanner"),
    ("aa-identity-", "Identity (Cognito triggers)"),
    ("aa-crm-", "CRM"),
)
OTHER_APP = "Other"

# Same rule as tools/secrets/register_check.py (AA-878): a plain name that looks like it carries a
# secret value. Kept in step by hand: that module needs PyYAML, this one is stdlib only.
_SECRETISH = re.compile(r"(SECRET|KEY|TOKEN|PASSWORD|PASSWD|CREDENTIAL)")
_SECRETISH_OK_SUFFIX = ("_ARN", "_NAME", "_HEADER", "_ID")

ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_SM_SUFFIX_RE = re.compile(r"^(.+)-[A-Za-z0-9]{6}$")
VERCEL_SENSITIVE = {"sensitive", "secret"}
VERCEL_READABLE = {"encrypted", "plain", "system"}
# `vercel env ls` labels (CLI 60): Secret = sensitive, Config = encrypted/plain.
CLI_KIND = {"secret": "sensitive", "sensitive": "sensitive", "config": "readable", "encrypted": "readable", "plain": "readable", "system": "readable"}


class InputError(Exception):
    """An input cannot be read or has an unexpected shape (exit 2, fail closed)."""


def app_of(name: str) -> str:
    for prefix, app in APPS:
        if name.startswith(prefix):
            return app
    return OTHER_APP


def looks_like_secret(name: str, *, vercel: bool = False) -> bool:
    if vercel and name.startswith("NEXT_PUBLIC_"):
        return False
    return bool(_SECRETISH.search(name.upper())) and not name.upper().endswith(_SECRETISH_OK_SUFFIX)


# --------------------------------------------------------------------------- extraction (values dropped here)


def secret_ref(value_from: str, names_by_arn: Optional[dict[str, str]] = None) -> dict:
    """Store and NAME of an ECS `secrets[].valueFrom`. No account, region or ARN is kept."""
    v = str(value_from or "")
    if v.startswith("arn:") and ":secretsmanager:" in v and ":secret:" in v:
        head, rest = v.split(":secret:", 1)
        parts = rest.split(":")
        name_part = parts[0]
        key = parts[1] if len(parts) > 1 and parts[1] else None
        names = names_by_arn or {}
        name = names.get(f"{head}:secret:{name_part}")  # full ARN (name + "-" + 6 random characters)
        if not name and names:
            # Partial ARN (no random suffix): the one listed full ARN that is this + "-" + 6 characters.
            prefix = f"{head}:secret:{name_part}-"
            hits = {n for k, n in names.items() if k.startswith(prefix) and len(k) == len(prefix) + 6}
            if len(hits) == 1:
                name = hits.pop()
            else:
                # Not listed (deleted, or another account's secret): the name part as written, flagged.
                return {"store": "secretsmanager", "secret": name_part, "key": key, "unlisted": True}
        if not name:
            # ListSecrets denied: strip what looks like the random suffix. A partial ARN whose name ends in
            # "-" + 6 characters (e.g. "-reader") is cut too; the collector warns when it runs this way.
            m = _SM_SUFFIX_RE.match(name_part)
            name = m.group(1) if m else name_part
        return {"store": "secretsmanager", "secret": name, "key": key}
    if v.startswith("arn:") and ":ssm:" in v and ":parameter" in v:
        name = v.split(":parameter", 1)[1]
        return {"store": "ssm", "secret": name if name.startswith("/") else "/" + name, "key": None}
    if v.startswith("arn:"):
        return {"store": "unknown", "secret": "", "key": None}
    # A bare name is an SSM parameter of the same account and region (ECS rule).
    return {"store": "ssm", "secret": v, "key": None}


def extract_task_def(td: dict, names_by_arn: Optional[dict[str, str]] = None) -> list[dict]:
    """Containers of a task definition with variable names and secret NAMES only."""
    out = []
    for c in td.get("containerDefinitions") or []:
        rows = []
        for e in c.get("environment") or []:
            n = str(e.get("name") or "")
            if n:
                rows.append({"name": n, "source": "plain"})
        for s in c.get("secrets") or []:
            n = str(s.get("name") or "")
            if n:
                rows.append({"name": n, "source": "secret", **secret_ref(s.get("valueFrom", ""), names_by_arn)})
        rows.sort(key=lambda r: (r["name"], r["source"]))
        out.append({"name": str(c.get("name") or ""), "vars": rows, "env_files": len(c.get("environmentFiles") or [])})
    return out


def vercel_kind(raw_type: Any) -> str:
    t = str(raw_type or "").strip().lower()
    if t in VERCEL_SENSITIVE:
        return "sensitive"
    if t in VERCEL_READABLE:
        return "readable"
    return CLI_KIND.get(t, "unknown")


def _targets(raw: Any) -> list[str]:
    if isinstance(raw, str):
        raw = [raw]
    out = sorted({str(t).strip().lower() for t in (raw or []) if str(t).strip()})
    return out


def extract_vercel_api(envs: Iterable[dict]) -> list[dict]:
    """Vercel REST `envs[]` -> key, kind, targets (+ git branch name). `value` is never read."""
    rows = []
    for e in envs or []:
        key = str(e.get("key") or "")
        if not key:
            continue
        row = {"key": key, "kind": vercel_kind(e.get("type")), "target": _targets(e.get("target"))}
        if e.get("gitBranch"):
            row["branch"] = str(e["gitBranch"])
        rows.append(row)
    return sorted(rows, key=lambda r: (r["key"], r["target"], r.get("branch", "")))


def parse_vercel_cli(text: str) -> list[dict]:
    """`vercel env ls` table -> key, kind, targets. The value column is dropped on read.

    Columns are split on 2+ spaces: name, value (masked/truncated), type, environments, created.
    Only the first and the last three columns are used, so a value with inner spaces cannot shift
    them. A line whose type column is not a known label raises (the line is never echoed).
    """
    rows = []
    for line in text.splitlines():
        parts = re.split(r"\s{2,}", line.strip())
        if len(parts) < 4 or not ENV_NAME_RE.match(parts[0]) or parts[0].lower() == "name":
            continue
        type_label, envs = parts[-3], parts[-2]
        if type_label.lower() not in CLI_KIND:
            raise InputError(f"vercel env ls: unexpected type column on the row of {parts[0]}")
        targets = []
        branch = None
        for t in envs.split(","):
            t = t.strip()
            m = re.match(r"^(\w+)\s*\((.+)\)$", t)  # "Preview (my-branch)"
            if m:
                t, branch = m.group(1), m.group(2)
            if t:
                targets.append(t)
        row = {"key": parts[0], "kind": CLI_KIND[type_label.lower()], "target": _targets(targets)}
        if branch:
            row["branch"] = branch
        rows.append(row)
    return sorted(rows, key=lambda r: (r["key"], r["target"], r.get("branch", "")))


# --------------------------------------------------------------------------- collection (read-only)


# The AWS CLI v2 (preinstalled on GitHub runners) does the reads; each call projects names with a
# JMESPath --query, so a plain value or a Lambda env value never leaves the CLI process: not on disk, not
# in this process. No third-party Python package is installed in the Docs Gen job (it holds the plan
# role's credentials and a root repo App write token (aa-ecosys-ci-bot); a pip dependency would run
# code with both in reach).
Q_LIST_SECRETS = "SecretList[].[ARN,Name]"
Q_LIST_SERVICES = "serviceArns"
Q_DESCRIBE_SERVICES = (
    "services[].{serviceName:serviceName,taskDefinition:taskDefinition,"
    "deployments:deployments[].{status:status,taskDefinition:taskDefinition}}"
)
Q_TASK_DEF = (
    "taskDefinition.{family:family,containerDefinitions:containerDefinitions[].{name:name,"
    "environment:environment[].{name:name},secrets:secrets[].{name:name,valueFrom:valueFrom},"
    "environmentFiles:environmentFiles[].{type:type}}}"
)
Q_LIST_FUNCTIONS = "Functions[].{function:FunctionName,keys:keys(Environment.Variables || `{}`)}"

_AWS_ERROR_CODE = re.compile(r"\(([A-Za-z]+)\)")


class AwsCli:
    """Read-only `aws <service> <op> --query Q --output json` runner (pagination is the CLI's own)."""

    def __init__(self, region: str, profile: Optional[str] = None, runner=subprocess.run):
        self.region, self.profile, self.runner = region, profile, runner

    def call(self, service: str, op: str, *args: str, query: str) -> Any:
        cmd = ["aws", service, op, *args, "--region", self.region, "--output", "json", "--query", query]
        if self.profile:
            cmd += ["--profile", self.profile]
        res = self.runner(cmd, capture_output=True, text=True, timeout=300, check=False)
        if res.returncode != 0:
            m = _AWS_ERROR_CODE.search(res.stderr or "")  # the error code only, never the CLI's full text
            raise InputError(f"aws {service} {op} failed (exit {res.returncode}{', ' + m.group(1) if m else ''})")
        out = (res.stdout or "").strip()
        return json.loads(out) if out else None


def secret_names_by_arn(aws: AwsCli) -> tuple[dict[str, str], Optional[str]]:
    """Full ARN -> name from ListSecrets (metadata only). On failure the suffix heuristic is used."""
    try:
        rows = aws.call("secretsmanager", "list-secrets", "--include-planned-deletion", query=Q_LIST_SECRETS) or []
    except InputError as exc:  # AccessDenied etc.: names fall back to the ARN suffix rule
        return {}, f"secretsmanager:ListSecrets failed ({exc}); secret names from the ARN suffix rule"
    return {str(arn): str(name) for arn, name in rows if arn and name}, None


def collect_ecs(aws: AwsCli, cluster: str, names_by_arn: dict[str, str]) -> list[dict]:
    arns = aws.call("ecs", "list-services", "--cluster", cluster, query=Q_LIST_SERVICES) or []
    services: list[dict] = []
    for i in range(0, len(arns), 10):
        services.extend(aws.call("ecs", "describe-services", "--cluster", cluster, "--services", *arns[i : i + 10],
                                 query=Q_DESCRIBE_SERVICES) or [])
    out = []
    for svc in sorted(services, key=lambda s: s.get("serviceName", "")):
        primary = next((d for d in svc.get("deployments") or [] if d.get("status") == "PRIMARY"), None)
        td_arn = (primary or {}).get("taskDefinition") or svc.get("taskDefinition")
        if not td_arn:
            continue
        td = aws.call("ecs", "describe-task-definition", "--task-definition", td_arn, query=Q_TASK_DEF) or {}
        out.append(
            {
                "service": svc["serviceName"],
                "family": td.get("family", ""),
                "containers": extract_task_def(td, names_by_arn),
            }
        )
    return out


def collect_lambda(aws: AwsCli) -> list[dict]:
    out = []
    for fn in aws.call("lambda", "list-functions", query=Q_LIST_FUNCTIONS) or []:
        out.append({"function": str(fn["function"]), "vars": [{"name": str(k), "source": "plain"} for k in sorted(fn.get("keys") or [])]})
    return sorted(out, key=lambda f: f["function"])


def collect_aws(cluster: str, region: str, profile: Optional[str] = None, runner=subprocess.run) -> dict:
    aws = AwsCli(region, profile, runner)
    names_by_arn, warning = secret_names_by_arn(aws)
    return {
        "format": FORMAT,
        "cluster": cluster,
        "ecs": collect_ecs(aws, cluster, names_by_arn),
        "lambda": collect_lambda(aws),
        "warnings": [warning] if warning else [],
    }


def _vercel_get(path: str, token: str, team_id: Optional[str], **params) -> dict:
    if team_id:
        params["teamId"] = team_id
    url = "https://api.vercel.com" + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 (fixed https host)
        return json.loads(resp.read().decode("utf-8"))


def collect_vercel_api(token: str, team_id: Optional[str], only: Iterable[str] = ()) -> dict[str, list[dict]]:
    only = set(only)
    projects: list[dict] = []
    params: dict[str, Any] = {"limit": 100}
    while True:
        data = _vercel_get("/v10/projects", token, team_id, **params)
        projects.extend(data.get("projects") or [])
        nxt = (data.get("pagination") or {}).get("next")
        if not nxt:
            break
        params["until"] = nxt
    out = {}
    for p in sorted(projects, key=lambda p: p.get("name", "")):
        if only and p.get("name") not in only:
            continue
        data = _vercel_get(f"/v10/projects/{urllib.parse.quote(p['id'])}/env", token, team_id)
        out[p["name"]] = extract_vercel_api(data.get("envs") or [])
    return out


def collect_vercel_cli(projects: Iterable[str], cwd: Optional[str] = None) -> dict[str, list[dict]]:
    out = {}
    for p in projects:
        res = subprocess.run(
            ["vercel", "env", "ls", "--project", p, "--no-color", "--non-interactive"],
            capture_output=True, text=True, timeout=120, cwd=cwd, check=False,
        )
        if res.returncode != 0:
            raise InputError(f"vercel env ls --project {p} failed (exit {res.returncode})")
        out[p] = parse_vercel_cli(res.stdout + "\n" + res.stderr)
        del res
    return out


# --------------------------------------------------------------------------- render


def _secret_cell(v: dict) -> Any:
    if v.get("source") != "secret":
        return ""
    if not v.get("secret"):
        return "(not a Secrets Manager or SSM reference)"
    label = v["secret"] if v.get("store") == "secretsmanager" else f"SSM {v['secret']}"
    s = gd.code(label)
    if v.get("key"):
        s = gd.Raw(f"{s} (JSON key {gd.code(v['key'])})")
    return s


def _secret_note(v: dict) -> str:
    if v.get("unlisted"):
        return "secret not found by ListSecrets (deleted, or another account): name as written in the task definition"
    return ""


def _plain_note(name: str, *, vercel: bool = False, kind: str = "") -> str:
    if vercel:
        if kind == "readable" and looks_like_secret(name, vercel=True):
            return "secret-shaped name in a readable variable: make it sensitive or register why not"
        return ""
    if name.upper().endswith("_ARN"):
        return "an ARN (read at run time)"
    if looks_like_secret(name):
        return "secret-shaped name in plain config: check"
    return ""


def _ecs_section(svc: dict) -> list[str]:
    lines = [f"### ECS service `{svc['service']}`", ""]
    multi = len(svc["containers"]) > 1
    for c in svc["containers"]:
        if multi:
            lines += [f"Container `{c['name']}`:", ""]
        rows = [[gd.code(v["name"]), v["source"], _secret_cell(v), _plain_note(v["name"]) if v["source"] == "plain" else _secret_note(v)] for v in c["vars"]]
        if rows:
            lines.append(gd.table(["Variable", "Source", "Secret (store name)", "Note"], rows))
        else:
            lines.append("No environment variables.")
        if c.get("env_files"):
            lines += ["", f"Plus {c['env_files']} environment file(s) from S3 (names inside not listed)."]
        lines.append("")
    plain = sum(v["source"] == "plain" for c in svc["containers"] for v in c["vars"])
    secret = sum(v["source"] == "secret" for c in svc["containers"] for v in c["vars"])
    lines.insert(2, f"Task definition family `{svc['family']}` (the revision the primary deployment runs): {plain} plain, {secret} from a secret.\n")
    return lines


def _lambda_section(fn: dict) -> list[str]:
    lines = [f"### Lambda `{fn['function']}`", ""]
    rows = [[gd.code(v["name"]), "plain", _plain_note(v["name"])] for v in fn["vars"]]
    lines.append(gd.table(["Variable", "Source", "Note"], rows) if rows else "No environment variables.")
    lines.append("")
    return lines


def _vercel_section(project: str, envs: list[dict]) -> list[str]:
    lines = [f"### Vercel project `{project}`", ""]
    rows = []
    for e in envs:
        targets = ", ".join(e["target"]) + (f" (branch `{gd.cell(e['branch'])}`)" if e.get("branch") else "")
        rows.append([gd.code(e["key"]), e["kind"], gd.Raw(gd.cell(targets)), _plain_note(e["key"], vercel=True, kind=e["kind"])])
    lines.append(gd.table(["Variable", "Kind", "Targets", "Note"], rows) if rows else "No environment variables.")
    lines.append("")
    return lines


def render_body(aws: dict, vercel: dict) -> str:
    ecs = aws.get("ecs") or []
    lambdas = aws.get("lambda") or []
    projects: dict[str, list[dict]] = vercel.get("projects") or {}
    if vercel.get("source") == "api":
        vsrc = "read live from the Vercel REST API"
    else:
        vsrc = (
            f"from the checked-in snapshot AA-CIS-Infra `tools/docs/env_config_vercel.json` (captured "
            f"{vercel.get('captured') or 'unknown'} with `vercel env ls`; the Docs Gen workflow has no Vercel token)"
        )
    n_ecs = sum(len(c["vars"]) for s in ecs for c in s["containers"])
    n_secret = sum(v["source"] == "secret" for s in ecs for c in s["containers"] for v in c["vars"])
    n_lambda = sum(len(f["vars"]) for f in lambdas)
    n_vercel = sum(len(v) for v in projects.values())
    out = [
        "What every runtime of the Dev ecosystem is configured with, by **name**: the ECS services of cluster "
        f"`{aws.get('cluster', '')}`, every Lambda function of acc2 and every Vercel project. Values are never read "
        "for this page; a secret is named by its Secrets Manager secret (or SSM parameter), which the "
        "[secrets register](../security/secrets-register.md) describes (owner, readers, rotation).",
        "",
        "- **Source** (ECS, Lambda): `plain` = a value in the task definition or function configuration; `secret` = "
        "injected at start from the named secret (ECS `secrets[]`).",
        "- **Kind** (Vercel): `sensitive` = write-only, nobody can read it back; `readable` = encrypted at rest but a "
        "project member can read it.",
        "- **Note** flags a name that looks like a secret in a plain or readable variable (same rule as the AA-878 "
        "register drift check).",
        f"- Vercel rows are {vsrc}.",
        "",
        f"**Totals:** {len(ecs)} ECS services ({n_ecs} variables, {n_secret} from a secret), {len(lambdas)} Lambda "
        f"functions ({n_lambda} variables), {len(projects)} Vercel projects ({n_vercel} variables).",
        "",
    ]
    for w in aws.get("warnings") or []:
        out += [f"> Collection warning: {gd.cell(w)}", ""]
    apps = [a for _, a in APPS] + [OTHER_APP]
    for app in apps:
        a_ecs = [s for s in ecs if app_of(s["service"]) == app]
        a_lam = [f for f in lambdas if app_of(f["function"]) == app]
        a_ver = sorted(p for p in projects if app_of(p) == app)
        if not (a_ecs or a_lam or a_ver):
            continue
        out += [f"## {app}", ""]
        for s in a_ecs:
            out += _ecs_section(s)
        for f in a_lam:
            out += _lambda_section(f)
        for p in a_ver:
            out += _vercel_section(p, projects[p])
    return "\n".join(out).rstrip("\n") + "\n"


def missing_runtimes(aws: dict, vercel: dict, ecs: Iterable[str], lam: Iterable[str], ver: Iterable[str]) -> list[str]:
    have_ecs = {s["service"] for s in aws.get("ecs") or []}
    have_lam = {f["function"] for f in aws.get("lambda") or []}
    have_ver = set((vercel.get("projects") or {}).keys())
    return (
        [f"ECS service {n}" for n in ecs if n not in have_ecs]
        + [f"Lambda {n}" for n in lam if n not in have_lam]
        + [f"Vercel project {n}" for n in ver if n not in have_ver]
    )


def render_page(aws: dict, vercel: dict, *, date: str, sha: str, source: str) -> str:
    body = render_body(aws, vercel)
    blurb = tuple(line.format(source=gd.cell(source)) for line in BLURB)
    return gd.page(SPEC, body, date=date, sha=sha, source=source, blurb=blurb)


# --------------------------------------------------------------------------- CLI


def _read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise InputError(f"cannot read {path}: {exc.__class__.__name__}") from None
    if not isinstance(data, dict):
        raise InputError(f"{path}: expected a JSON object")
    return data


def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: Optional[list[str]] = None) -> int:
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("collect-aws", help="names-only model of ECS + Lambda (AWS CLI, read-only)")
    a.add_argument("--cluster", default="aa-cis-dev-cluster")
    # Fixed default, not AWS_REGION: a stray shell region must not render an empty page of another region.
    a.add_argument("--region", default="us-west-1")
    a.add_argument("--profile", help="AWS CLI profile (local runs); CI uses the job's OIDC credentials")
    a.add_argument("--out", required=True, type=Path)

    v = sub.add_parser("vercel-snapshot", help="names-only Vercel env list")
    g = v.add_mutually_exclusive_group(required=True)
    g.add_argument("--cli", action="store_true", help="run the local `vercel env ls` per project")
    g.add_argument("--api", action="store_true", help="Vercel REST API with VERCEL_TOKEN (+ VERCEL_TEAM_ID)")
    v.add_argument("--project", action="append", default=[], help="project name (repeat); --cli needs at least one")
    v.add_argument("--cwd", help="--cli: a directory linked to the Vercel team")
    v.add_argument("--date", default=today)
    v.add_argument("--out", required=True, type=Path)

    r = sub.add_parser("render", help="render env-config.md")
    r.add_argument("--aws", required=True, type=Path)
    r.add_argument("--vercel", type=Path, default=VERCEL_SNAPSHOT)
    r.add_argument("--out-dir", required=True, type=Path)
    r.add_argument("--source", default="local run")
    r.add_argument("--sha", default="local")
    r.add_argument("--date", default=today)
    r.add_argument("--require-ecs", nargs="*", default=list(REQUIRED_ECS))
    r.add_argument("--require-lambda", nargs="*", default=list(REQUIRED_LAMBDA))
    r.add_argument("--require-vercel", nargs="*", default=list(REQUIRED_VERCEL))

    args = ap.parse_args(argv)
    try:
        if args.cmd == "collect-aws":
            model = collect_aws(args.cluster, args.region, args.profile)
            _write_json(args.out, model)
            print(f"collected {len(model['ecs'])} ECS services and {len(model['lambda'])} Lambda functions (names only) into {args.out}")
            for w in model["warnings"]:
                print(f"::warning::{w}")
            return 0

        if args.cmd == "vercel-snapshot":
            if args.api:
                token = os.environ.get("VERCEL_TOKEN") or ""
                if not token:
                    raise InputError("--api needs VERCEL_TOKEN in the environment")
                projects = collect_vercel_api(token, os.environ.get("VERCEL_TEAM_ID") or None, args.project)
                source = "api"
            else:
                if not args.project:
                    raise InputError("--cli needs at least one --project")
                projects = collect_vercel_cli(args.project, args.cwd)
                source = "snapshot"
            _write_json(args.out, {"format": FORMAT, "source": source, "captured": args.date, "projects": projects})
            print(f"wrote {sum(len(v) for v in projects.values())} Vercel variable names of {len(projects)} projects into {args.out}")
            return 0

        aws = _read_json(args.aws)
        vercel = _read_json(args.vercel)
        missing = missing_runtimes(aws, vercel, args.require_ecs, args.require_lambda, args.require_vercel)
        if missing:
            for m in missing:
                print(f"::error title=env-config::required runtime missing from the collected data: {m}")
            return 1
        args.out_dir.mkdir(parents=True, exist_ok=True)
        (args.out_dir / PAGE).write_text(render_page(aws, vercel, date=args.date, sha=args.sha, source=args.source), encoding="utf-8")
        print(f"rendered {PAGE} into {args.out_dir}")
        return 0
    except (InputError, gd.aws_mask.AliasError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
