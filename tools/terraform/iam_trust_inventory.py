#!/usr/bin/env python3
"""IAM trust inventory (S271 lessons guard G13): every role trust policy, every kind of principal, flagged.

Why: an S271 audit concluded "no role trusts an outside account" after reading only Principal.AWS. It missed the
role AWSReservedSSO_AdministratorAccess_*, which trusts a SAML provider (Federated) of the IAM Identity Center that
assigns permission sets to this account. That role is created by Identity Center, not by this repo's Terraform, and
its Access Analyzer finding is ARCHIVED (accounts/aa365/security_access_analyzer_archive.tf), so it shows in no
Terraform file and in no ACTIVE finding. This tool reads all three principal kinds (AWS, Federated, Service, plus
CanonicalUser, NotPrincipal and "*") and says which trust is managed by Terraform and which is not.

Read-only, stdlib only. Three modes:

  static   Scans the Terraform roots (accounts/*, modules/*) for aws_iam_role trust policies (jsonencode or a
           data.aws_iam_policy_document). No AWS, no Terraform. Expressions stay unresolved, so an account given by
           variable counts as "this account" only for the usual same-root forms. CI runs it through
           tools/terraform/tests/test_iam_trust_inventory.py: a new flagged trust fails until it is reviewed and
           acknowledged in tools/terraform/iam_trust_allowlist.json.
             python3 tools/terraform/iam_trust_inventory.py static
  plan     Reads `terraform show -json` of a plan (planned_values) or of the state (values): resolved policies of
           every Terraform-managed role of one root.
             python3 tools/terraform/iam_trust_inventory.py plan --json-file plan.json --self-account <id>
  live     Lists the account's roles (read-only `aws iam list-roles`, `aws iam get-role` for the tags; optional
           `aws accessanalyzer list-analyzers` + `list-findings-v2`, ACTIVE and ARCHIVED). A role that Terraform does
           not manage (not in --managed-from, no ManagedBy=terraform tag, an aws-reserved path) and has a flagged
           trust is reported as an UNMANAGED external trust. Single-line AWS CLI calls underneath.
             python3 tools/terraform/iam_trust_inventory.py live --profile aa365-admin --region us-west-1 --access-analyzer

Accounts: the account the tool runs against is "this account" (live: sts get-caller-identity; plan: --self-account).
Other ecosystem accounts are trusted only when named at run time, env IAM_TRUST_ACCOUNTS="acc3=<id>,mgmt=<id>"
(never in this public repo). Any other account is flagged as external.

Output: a Markdown table (account ids and ARNs masked with tools/docs/aws_mask.py; labels from AWS_ACCOUNT_ALIASES)
to stdout and, with --summary FILE, appended to that file; --json writes the rows as JSON instead. Exit 0 = no
unacknowledged flag, 1 = at least one flagged trust (read the table), 2 = usage or AWS error.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import urllib.parse
from dataclasses import asdict, dataclass, field
from typing import Callable, Iterable, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_ALLOWLIST = os.path.join(HERE, "iam_trust_allowlist.json")
DEFAULT_STATIC_ROOTS = ("accounts", "modules")

sys.path.insert(0, os.path.join(HERE, "..", "docs"))
import aws_mask  # noqa: E402

ACCOUNTS_ENV = "IAM_TRUST_ACCOUNTS"
OK, LISTED, FLAG, ACK = "ok", "listed", "flag", "acknowledged"
GITHUB_ISSUER = "token.actions.githubusercontent.com"
GITHUB_SUB_KEY = GITHUB_ISSUER + ":sub"
ACCOUNT_IN = re.compile(r"(?<![0-9])(\d{12})(?![0-9])")
# Same-root expressions for a principal in the account the root is applied to (static mode only).
SELF_EXPR = re.compile(
    r"\b(aws_iam_role|aws_iam_user|aws_iam_group|data\.aws_iam_role|data\.aws_caller_identity\.[A-Za-z0-9_]+\.account_id"
    r"|var\.account_id|local\.account_id|var\.management_account_id)\b"
)
# The GitHub Actions OIDC provider, as the roots reference it.
GITHUB_EXPR = re.compile(r"\b(aws_iam_openid_connect_provider\.github_actions\.arn|var\.github_oidc_provider_arn)\b")
SERVICE_LINKED_PATH = "/aws-service-role/"
RESERVED_SSO_PATH = "/aws-reserved/sso.amazonaws.com/"


@dataclass
class Context:
    self_accounts: set = field(default_factory=set)
    trusted: dict = field(default_factory=dict)  # account id -> alias
    services: set = field(default_factory=set)
    oidc_hosts: set = field(default_factory=set)
    acknowledged: list = field(default_factory=list)
    static: bool = False


@dataclass
class Trust:
    mode: str  # static / plan / live
    key: str  # what an acknowledgement matches: <dir>:<address>, plan:<address>, live:<role name>
    role: str
    kind: str
    principal: str
    actions: str
    verdict: str
    note: str
    managed: str = ""  # live: terraform / terraform (tag) / unmanaged / identity-center / service-linked
    analyzer: str = ""  # live with --access-analyzer: finding status(es) of the role


# --- allowlist and accounts ------------------------------------------------------------------------------------------

def load_allowlist(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    for entry in data.get("acknowledged", []):
        if not entry.get("match") or not entry.get("kind") or not str(entry.get("reason", "")).strip():
            raise ValueError(f"{path}: every acknowledged entry needs match, kind and a reason: {entry}")
    if ACCOUNT_IN.search(json.dumps(data)):
        raise ValueError(f"{path}: no account id in the allowlist (public repo); name accounts in {ACCOUNTS_ENV}")
    return data


def parse_accounts(value: str) -> dict:
    """'acc3=<id>,mgmt=<id>' (comma, space or newline separated) -> {id: alias}."""
    out = {}
    for item in re.split(r"[\s,]+", value or ""):
        if not item:
            continue
        alias, _, acct = item.partition("=")
        if not re.fullmatch(r"\d{12}", acct.strip()) or not alias.strip():
            raise ValueError(f"{ACCOUNTS_ENV}: bad entry (want alias=<12 digits>)")
        out[acct.strip()] = alias.strip()
    return out


def make_context(allowlist: dict, self_accounts: Iterable[str] = (), static: bool = False,
                 accounts_env: Optional[str] = None) -> Context:
    env = os.environ.get(ACCOUNTS_ENV, "") if accounts_env is None else accounts_env
    return Context(self_accounts={a for a in self_accounts if a}, trusted=parse_accounts(env),
                   services=set(allowlist.get("services", [])), oidc_hosts=set(allowlist.get("oidc_providers", [])),
                   acknowledged=list(allowlist.get("acknowledged", [])), static=static)


# --- classification --------------------------------------------------------------------------------------------------

def _account_of(principal: str) -> Optional[str]:
    if re.fullmatch(r"\d{12}", principal):
        return principal
    m = re.match(r"arn:aws[a-z-]*:(?:iam|sts)::(\d{12}):", principal)
    if m:
        return m.group(1)
    m = ACCOUNT_IN.search(principal)
    return m.group(1) if m else None


def classify(kind: str, principal: str, ctx: Context, conditions: str = "") -> tuple[str, str]:
    """(verdict, note) for one principal of an Allow statement. `conditions` is the statement's condition text."""
    p = principal.strip()
    if kind == "NotPrincipal":
        return FLAG, "NotPrincipal trust: everyone except the listed principals"
    if kind == "*" or p == "*":
        return FLAG, "any principal (public trust)"
    if kind == "CanonicalUser":
        return FLAG, "CanonicalUser principal (S3 canonical id of another account)"
    if kind == "unresolved":
        return FLAG, f"trust policy not readable statically ({p[:80]}); review it by hand"
    if kind == "AWS":
        acct = _account_of(p)
        if acct is None:
            if ctx.static and SELF_EXPR.search(p):
                return OK, "this account (same-root expression)"
            return FLAG, "cross-account? the principal is an expression not provably in this account"
        return _classify_account(acct, ctx)
    if kind == "Federated":
        is_github = GITHUB_ISSUER in p or (ctx.static and GITHUB_EXPR.search(p))
        if is_github:
            if GITHUB_SUB_KEY not in conditions:
                return FLAG, "GitHub OIDC trust without a token.actions.githubusercontent.com:sub condition"
            verdict, note = LISTED, "GitHub Actions OIDC (sub pinned)"
        elif ":saml-provider/" in p or "saml" in p.lower():
            if "AWSSSO_" in p:
                return FLAG, ("SAML federation: IAM Identity Center (AWSSSO_ provider); the organization that runs that "
                              "Identity Center can sign in here")
            return FLAG, "SAML federation: an external identity provider can sign in here"
        else:
            host = p.split(":oidc-provider/", 1)[1] if ":oidc-provider/" in p else p
            if host.split("/")[0] in ctx.oidc_hosts:
                verdict, note = LISTED, f"OIDC provider {host.split('/')[0]} (allowlisted)"
            else:
                return FLAG, f"web identity / OIDC provider not in the allowlist ({host[:80]})"
        acct = _account_of(p)
        if acct is not None and ctx.self_accounts and acct not in ctx.self_accounts:
            return FLAG, f"{note}, but the provider is in another account"
        return verdict, note
    if kind == "Service":
        if ctx.static and not re.fullmatch(r"[a-z0-9.-]+\.amazonaws\.com(\.cn)?", p):
            return FLAG, f"service principal is an expression ({p[:80]})"
        if p in ctx.services:
            return OK, "AWS service (allowlisted)"
        return FLAG, "AWS service not in the allowlist"
    return FLAG, f"unknown principal kind {kind}"


def _classify_account(acct: str, ctx: Context) -> tuple[str, str]:
    if acct in ctx.self_accounts:
        return OK, "this account"
    if acct in ctx.trusted:
        return LISTED, f"ecosystem account {ctx.trusted[acct]} (named in {ACCOUNTS_ENV})"
    if not ctx.self_accounts and not ctx.trusted:
        return FLAG, "account outside this root (literal id; name ecosystem accounts in " + ACCOUNTS_ENV + ")"
    return FLAG, "external account"


def acknowledge(trust: Trust, ctx: Context) -> Trust:
    if trust.verdict != FLAG:
        return trust
    for entry in ctx.acknowledged:
        if entry["kind"] == trust.kind and fnmatch.fnmatchcase(trust.key, entry["match"]):
            trust.verdict = ACK
            trust.note = f"{trust.note}; acknowledged: {entry['reason']}"
            break
    return trust


# --- resolved policies (plan / state / live) -------------------------------------------------------------------------

def _as_list(v) -> list:
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def parse_policy(doc) -> dict:
    if isinstance(doc, dict):
        return doc
    text = str(doc or "")
    if text.startswith("%7B") or text.startswith("%7b"):
        text = urllib.parse.unquote(text)
    return json.loads(text) if text.strip() else {}


def trusts_from_policy(mode: str, key: str, role: str, doc, ctx: Context) -> list[Trust]:
    out = []
    policy = parse_policy(doc)
    for stmt in _as_list(policy.get("Statement")):
        if stmt.get("Effect", "Allow") != "Allow":
            continue
        actions = ",".join(_as_list(stmt.get("Action")) + [f"NOT {a}" for a in _as_list(stmt.get("NotAction"))])
        cond = json.dumps(stmt.get("Condition", {}), sort_keys=True)
        pairs = []
        if "NotPrincipal" in stmt:
            pairs.append(("NotPrincipal", json.dumps(stmt["NotPrincipal"], sort_keys=True)))
        principal = stmt.get("Principal")
        if principal == "*":
            pairs.append(("*", "*"))
        elif isinstance(principal, dict):
            for kind, values in principal.items():
                for v in _as_list(values):
                    pairs.append((kind, str(v)))
        for kind, value in pairs:
            verdict, note = classify(kind, value, ctx, cond)
            out.append(acknowledge(Trust(mode, key, role, kind, value, actions, verdict, note), ctx))
    return out


def _walk_modules(module: dict):
    yield from module.get("resources", []) or []
    for child in module.get("child_modules", []) or []:
        yield from _walk_modules(child)


def plan_trusts(data: dict, ctx: Context) -> list[Trust]:
    """aws_iam_role trust policies of `terraform show -json` output (plan: planned_values; state: values)."""
    values = data.get("planned_values") or data.get("values") or {}
    out = []
    for res in _walk_modules(values.get("root_module", {}) or {}):
        if res.get("type") != "aws_iam_role" or res.get("mode", "managed") != "managed":
            continue
        addr = res.get("address", "?")
        vals = res.get("values") or {}
        doc = vals.get("assume_role_policy")
        if not doc:
            out.append(Trust("plan", f"plan:{addr}", addr, "unknown", "-", "", OK, "known only after apply"))
            continue
        out.extend(trusts_from_policy("plan", f"plan:{addr}", addr, doc, ctx))
    return out


def managed_role_names(data: dict) -> set:
    values = data.get("planned_values") or data.get("values") or {}
    names = set()
    for res in _walk_modules(values.get("root_module", {}) or {}):
        if res.get("type") == "aws_iam_role" and (res.get("values") or {}).get("name"):
            names.add(res["values"]["name"])
    return names


# --- live ------------------------------------------------------------------------------------------------------------

AwsRunner = Callable[[list], dict]


def cli_runner(profile: Optional[str], region: Optional[str]) -> AwsRunner:
    def run(args: list) -> dict:
        cmd = ["aws", *args, "--output", "json"]
        if profile:
            cmd += ["--profile", profile]
        if region:
            cmd += ["--region", region]
        proc = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=300)
        if proc.returncode != 0:
            raise RuntimeError(f"aws {' '.join(args[:2])} failed: {aws_mask.mask_text(proc.stderr.strip())[:300]}")
        return json.loads(proc.stdout or "{}")
    return run


def _analyzer_status(run: AwsRunner) -> dict:
    """{role ARN: 'ACTIVE' / 'ARCHIVED' / ...} from the ACCOUNT analyzer's IAM role findings (all statuses)."""
    analyzers = [a for a in run(["accessanalyzer", "list-analyzers", "--type", "ACCOUNT"]).get("analyzers", [])
                 if a.get("status") == "ACTIVE"]
    if not analyzers:
        return {}
    flt = json.dumps({"resourceType": {"eq": ["AWS::IAM::Role"]}})
    found = run(["accessanalyzer", "list-findings-v2", "--analyzer-arn", analyzers[0]["arn"], "--filter", flt])
    status: dict = {}
    for f in found.get("findings", []):
        status.setdefault(f.get("resource", ""), set()).add(f.get("status", "?"))
    return {arn: "/".join(sorted(s)) for arn, s in status.items()}


def live_trusts(run: AwsRunner, ctx: Context, managed_names: set = frozenset(), read_tags: bool = True,
                access_analyzer: bool = False) -> list[Trust]:
    if not ctx.self_accounts:
        ctx.self_accounts = {run(["sts", "get-caller-identity"])["Account"]}
    status = _analyzer_status(run) if access_analyzer else {}
    out = []
    for role in run(["iam", "list-roles"]).get("Roles", []):
        name, path = role["RoleName"], role.get("Path", "/")
        if path.startswith(RESERVED_SSO_PATH):
            managed = "identity-center (not Terraform)"
        elif path.startswith(SERVICE_LINKED_PATH):
            managed = "service-linked (AWS)"
        elif name in managed_names:
            managed = "terraform"
        elif read_tags:
            tags = run(["iam", "get-role", "--role-name", name]).get("Role", {}).get("Tags", [])
            managed = "terraform (tag)" if any(t.get("Key") == "ManagedBy" and t.get("Value") == "terraform"
                                               for t in tags) else "unmanaged"
        else:
            managed = "unmanaged"
        for t in trusts_from_policy("live", f"live:{name}", name, role.get("AssumeRolePolicyDocument"), ctx):
            t.managed = managed
            t.analyzer = status.get(role.get("Arn", ""), "")
            if managed.startswith("service-linked") and t.kind == "Service" and t.verdict == FLAG:
                t.verdict, t.note = OK, "service-linked role (created and owned by AWS)"
            if t.verdict == FLAG and not managed.startswith("terraform"):
                t.note = f"UNMANAGED external trust: {t.note}"
            if t.verdict in (FLAG, ACK) and "ARCHIVED" in t.analyzer:
                t.note += " (Access Analyzer finding ARCHIVED: absent from ACTIVE findings)"
            out.append(t)
    return out


# --- static (Terraform source) ---------------------------------------------------------------------------------------

def _block_end(text: str, start: int, open_ch: str = "{", close_ch: str = "}") -> int:
    """Index just past the bracket matching text[start] (an opening bracket); strings, comments, heredocs skipped."""
    depth, i, n = 0, start, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c == "#" or text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                return n
        elif text.startswith("/*", i):
            i = text.find("*/", i) + 1 or n
        elif text.startswith("<<", i):
            m = re.match(r"<<-?([A-Za-z_]+)\n", text[i:])
            if m:
                end = re.compile(r"^\s*" + m.group(1) + r"\s*$", re.M).search(text, i + m.end())
                i = end.end() if end else n
                continue
        elif c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def _blocks(text: str, header: str):
    """(name, body) of every top-level `<header> "<name>" {` block, header like 'resource "aws_iam_role"'."""
    for m in re.finditer(r"^\s*" + re.escape(header) + r'\s+"([^"]+)"\s*\{', text, re.M):
        brace = m.end() - 1
        yield m.group(1), text[brace:_block_end(text, brace)]


def _sub_blocks(body: str, name: str):
    for m in re.finditer(r"(?<![\w\"])" + re.escape(name) + r"\s*\{", body):
        brace = m.end() - 1
        yield body[brace:_block_end(body, brace)]


def _strip_comments(text: str) -> str:
    return re.sub(r"(?m)^\s*(#|//).*$", "", text)


def _list_items(expr: str) -> list[str]:
    expr = expr.strip()
    if expr.startswith("["):
        inner = expr[1:_block_end(expr, 0, "[", "]") - 1]
        items, depth, cur, in_str = [], 0, "", False
        for i, c in enumerate(inner):
            if c == '"' and (i == 0 or inner[i - 1] != "\\"):
                in_str = not in_str
            if not in_str and c in "([{":
                depth += 1
            elif not in_str and c in ")]}":
                depth -= 1
            if c == "," and depth == 0 and not in_str:
                items.append(cur)
                cur = ""
            else:
                cur += c
        items.append(cur)
        return [x.strip().strip('"') for x in items if x.strip()]
    return [expr.strip().strip('"')]


def _value_after(body: str, key: str) -> Optional[str]:
    """The expression after `key =` (a "string", a [list] or a bare expression up to the end of the line)."""
    m = re.search(r"(?<![\w\"])\"?" + re.escape(key) + r"\"?\s*=\s*", body)
    if not m:
        return None
    rest = body[m.end():]
    if rest.startswith("["):
        return rest[:_block_end(rest, 0, "[", "]")]
    if rest.startswith('"'):
        end = 1
        while end < len(rest) and rest[end] != '"':
            end += 2 if rest[end] == "\\" else 1
        return rest[:end + 1]
    return re.split(r"[\n,}]", rest, 1)[0].strip()


def _jsonencode_pairs(segment: str) -> list[tuple[str, str]]:
    """(kind, principal) pairs of the Principal / NotPrincipal maps of a jsonencode() trust policy."""
    pairs = []
    for m in re.finditer(r"(?<![\w\"])(Not)?Principal\s*=\s*", segment):
        rest = segment[m.end():]
        if m.group(1):
            pairs.append(("NotPrincipal", rest.split("\n", 1)[0].strip()))
            continue
        if rest.startswith('"*"'):
            pairs.append(("*", "*"))
            continue
        if not rest.startswith("{"):
            pairs.append(("unresolved", rest.split("\n", 1)[0].strip()))
            continue
        body = rest[:_block_end(rest, 0)]
        for k in ("AWS", "Service", "Federated", "CanonicalUser"):
            v = _value_after(body, k)
            if v is not None:
                pairs.extend((k, item) for item in _list_items(v))
    return pairs


def _doc_pairs(doc: str) -> tuple[list[tuple[str, str]], str, str]:
    """(pairs, conditions text, actions) of a data.aws_iam_policy_document body (Allow statements only)."""
    pairs, conds, actions = [], [], []
    for stmt in _sub_blocks(doc, "statement"):
        if re.search(r'effect\s*=\s*"Deny"', stmt):
            continue
        if re.search(r'dynamic\s+"(not_)?principals"', stmt):
            pairs.append(("unresolved", "dynamic principals block"))
        for blk in _sub_blocks(stmt, "not_principals"):
            pairs.append(("NotPrincipal", " ".join(_list_items(_value_after(blk, "identifiers") or ""))))
        for blk in _sub_blocks(stmt, "principals"):
            kind = (_value_after(blk, "type") or "").strip('"')
            for item in _list_items(_value_after(blk, "identifiers") or '""'):
                pairs.append((kind, item))
        conds.extend(_sub_blocks(stmt, "condition"))
        actions.extend(_list_items(_value_after(stmt, "actions") or "[]"))
    return pairs, " ".join(conds), ",".join(actions)


def static_trusts(ctx: Context, repo_root: str = REPO_ROOT, roots: Iterable[str] = DEFAULT_STATIC_ROOTS) -> list[Trust]:
    """Trusts of every aws_iam_role under the given folders (each folder of .tf files is one module)."""
    ctx.static = True
    out = []
    for top in roots:
        for base, dirs, files in os.walk(os.path.join(repo_root, top)):
            dirs[:] = sorted(d for d in dirs if not d.startswith("."))
            tf = sorted(f for f in files if f.endswith(".tf"))
            if not tf:
                continue
            rel = os.path.relpath(base, repo_root).replace(os.sep, "/")
            texts = {}
            for f in tf:
                with open(os.path.join(base, f), encoding="utf-8") as fh:
                    texts[f] = fh.read()
            docs = {name: body for text in texts.values()
                    for name, body in _blocks(_strip_comments(text), 'data "aws_iam_policy_document"')}
            for f, text in texts.items():
                for name, body in _blocks(_strip_comments(text), 'resource "aws_iam_role"'):
                    out.extend(_static_role(ctx, rel, f, name, body, docs))
    return out


def _static_role(ctx: Context, rel: str, f: str, name: str, body: str, docs: dict) -> list[Trust]:
    addr = f"aws_iam_role.{name}"
    key, role = f"{rel}:{addr}", f"{rel}/{f}:{addr}"
    m = re.search(r"\bassume_role_policy\s*=\s*", body)
    if not m:
        return [acknowledge(Trust("static", key, role, "unresolved", "no assume_role_policy", "", FLAG,
                                  "no assume_role_policy argument found"), ctx)]
    rest = body[m.end():]
    if rest.startswith("jsonencode("):
        segment = rest[:_block_end(rest, len("jsonencode"), "(", ")")]
        pairs, cond = _jsonencode_pairs(segment), segment
        actions = ",".join(sorted({a for m in re.finditer(r"(?<![\w\"])Action\s*=", segment)
                                   for a in _list_items(_value_after(segment[m.start():], "Action") or "")}))
    else:
        dm = re.match(r"data\.aws_iam_policy_document\.([A-Za-z0-9_-]+)(?:\[[^\]]*\])?\.json\b", rest)
        if not dm or dm.group(1) not in docs:
            expr = rest.split("\n", 1)[0].strip()
            return [acknowledge(Trust("static", key, role, "unresolved", expr, "", FLAG,
                                      f"trust policy not readable statically ({expr[:80]}); review it by hand"), ctx)]
        pairs, cond, actions = _doc_pairs(docs[dm.group(1)])
    if not pairs:
        pairs = [("unresolved", "no principal found")]
    out = []
    for kind, principal in pairs:
        verdict, note = classify(kind, principal, ctx, cond)
        out.append(acknowledge(Trust("static", key, role, kind, principal, actions, verdict, note), ctx))
    return out


# --- report ----------------------------------------------------------------------------------------------------------

def _cell(text: str) -> str:
    return aws_mask.mask_text(str(text)).replace("|", "\\|").replace("\n", " ").strip()


def render(trusts: list[Trust], title: str) -> str:
    flagged = [t for t in trusts if t.verdict == FLAG]
    acked = [t for t in trusts if t.verdict == ACK]
    roles = len({t.key for t in trusts})
    lines = [f"## IAM trust inventory ({title})", "",
             f"{roles} roles, {len(trusts)} trusted principals: {len(flagged)} flagged, {len(acked)} acknowledged.",
             "Kinds read: AWS, Federated (SAML / OIDC), Service, CanonicalUser, NotPrincipal and `*`.", ""]
    live = any(t.mode == "live" for t in trusts)
    head = "| Verdict | Role | Kind | Principal | Actions | Note |"
    sep = "|---|---|---|---|---|---|"
    if live:
        head, sep = head + " Managed by | Access Analyzer |", sep + "---|---|"
    lines += [head, sep]
    order = {FLAG: 0, ACK: 1, LISTED: 2, OK: 3}
    for t in sorted(trusts, key=lambda t: (order.get(t.verdict, 9), t.key, t.kind, t.principal)):
        row = [t.verdict.upper() if t.verdict == FLAG else t.verdict, t.role, t.kind, t.principal, t.actions, t.note]
        if live:
            row += [t.managed, t.analyzer or "-"]
        lines.append("| " + " | ".join(_cell(c) for c in row) + " |")
    return "\n".join(lines) + "\n"


def main(argv: Optional[list] = None, runner: Optional[AwsRunner] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("mode", choices=["static", "plan", "live"])
    ap.add_argument("--allowlist", default=DEFAULT_ALLOWLIST)
    ap.add_argument("--repo-root", default=REPO_ROOT, help="static: repository root")
    ap.add_argument("--root", action="append", help="static: folder to scan (repeatable; default accounts, modules)")
    ap.add_argument("--json-file", help="plan: `terraform show -json` output of a plan or of the state")
    ap.add_argument("--self-account", action="append", default=[], help="plan: the root's own account id")
    ap.add_argument("--managed-from", action="append", default=[],
                    help="live: `terraform show -json` file(s) whose aws_iam_role names count as Terraform-managed")
    ap.add_argument("--no-tags", action="store_true", help="live: skip get-role (no ManagedBy tag lookup)")
    ap.add_argument("--access-analyzer", action="store_true", help="live: add Access Analyzer finding status")
    ap.add_argument("--profile")
    ap.add_argument("--region")
    ap.add_argument("--summary", help="append the Markdown report to this file (e.g. $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--json", action="store_true", help="print the rows as JSON (masked) instead of Markdown")
    args = ap.parse_args(argv)
    try:
        allow = load_allowlist(args.allowlist)
        if args.mode == "static":
            ctx = make_context(allow, static=True)
            trusts = static_trusts(ctx, args.repo_root, args.root or DEFAULT_STATIC_ROOTS)
            title = "static, Terraform source"
        elif args.mode == "plan":
            if not args.json_file:
                ap.error("plan needs --json-file")
            with open(args.json_file, encoding="utf-8") as fh:
                data = json.load(fh)
            ctx = make_context(allow, args.self_account)
            trusts = plan_trusts(data, ctx)
            title = "Terraform plan / state"
        else:
            managed = set()
            for path in args.managed_from:
                with open(path, encoding="utf-8") as fh:
                    managed |= managed_role_names(json.load(fh))
            ctx = make_context(allow)
            run = runner or cli_runner(args.profile, args.region)
            trusts = live_trusts(run, ctx, managed, read_tags=not args.no_tags, access_analyzer=args.access_analyzer)
            title = "live account, read-only"
    except (OSError, ValueError, RuntimeError, KeyError, json.JSONDecodeError, subprocess.TimeoutExpired) as exc:
        print(f"iam_trust_inventory: {aws_mask.mask_text(str(exc))}", file=sys.stderr)
        return 2
    if args.json:
        print(aws_mask.mask_text(json.dumps([asdict(t) for t in trusts], indent=1)))
    else:
        report = render(trusts, title)
        print(report, end="")
        if args.summary:
            with open(args.summary, "a", encoding="utf-8") as fh:
                fh.write(report)
    return 1 if any(t.verdict == FLAG for t in trusts) else 0


if __name__ == "__main__":
    sys.exit(main())
