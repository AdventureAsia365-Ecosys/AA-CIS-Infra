#!/usr/bin/env python3
"""Managed login branding coverage check (AA-935 follow-up, S249).

A Cognito user pool whose domain runs managed login version 2 renders NO sign-in page for an app client that has
no managed login branding style: `/login` and `/oauth2/authorize` answer HTTP 403 "Login pages unavailable". The
style is per client (one per client, Cognito's rule), not per domain. On 24/10/2026 every EXTERNAL client was in
that state, so nobody could sign in through managed login. This check reads the Terraform source of one root and
fails when that can happen again:

  B1  every interactive app client (allowed_oauth_flows holds "code" or "implicit") of a pool that has a domain
      with managed_login_version other than 1 is covered by an aws_cognito_managed_login_branding resource:
        - a client with for_each needs a branding resource with `for_each = aws_cognito_user_pool_client.<name>`
          (the whole map, so a key added later is covered automatically);
        - a single client needs `client_id = aws_cognito_user_pool_client.<name>.id`;
        - a client with count is refused (use for_each, so the check can prove every instance is covered);
  B2  the branding resource names the same pool as the client (`user_pool_id = aws_cognito_user_pool.<pool>.id`);
  B3  a domain or client whose pool is not a plain `aws_cognito_user_pool.<name>.id` reference cannot be checked
      and is reported (fail closed).

Machine clients (client_credentials only) never see a login page and are skipped. A domain without
managed_login_version (or with the literal 1) is the classic hosted UI, which needs no style. Any other value,
including a variable, counts as version 2 (fail closed).

Usage: python3 tools/terraform/managed_login_branding.py --source accounts/aa365
Exit 0 = every interactive v2 client has a style, 1 = violations (listed), 2 = bad input. Stdlib only, offline.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

INTERACTIVE_FLOWS = frozenset({"code", "implicit"})
_POOL_REF = re.compile(r"aws_cognito_user_pool\.([\w-]+)\.id")


class InputError(Exception):
    """The Terraform source cannot be read or parsed."""


# ----------------------------------------------------------------------------------------------
# Minimal HCL scanning (same approach as alb_rule_order.py: comments blanked, braces matched)
# ----------------------------------------------------------------------------------------------
def _strip_comments(text: str) -> str:
    """Blank out comments, keep strings (and offsets/lines) intact."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1])
            i = j + 1
        elif c == "#" or text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j == -1 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _block_end(text: str, open_idx: int) -> int:
    depth, i, n = 0, open_idx, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise InputError("unbalanced braces")


def _resources(text: str, rtype: str) -> list[tuple[str, str]]:
    """(name, top-level body) of every `resource "<rtype>" "<name>"` block; nested blocks are blanked."""
    found = []
    for m in re.finditer(rf'resource\s+"{rtype}"\s+"([\w-]+)"\s*\{{', text):
        start = m.end() - 1
        body = text[start + 1 : _block_end(text, start)]
        found.append((m.group(1), _top_level(body)))
    return found


def _top_level(body: str) -> str:
    """The body with every nested { ... } blanked, so a nested attribute never reads as a top-level one."""
    out, depth = [], 0
    i, n = 0, len(body)
    while i < n:
        c = body[i]
        if c == '"':
            j = i + 1
            while j < n and body[j] != '"':
                j += 2 if body[j] == "\\" else 1
            out.append(body[i : j + 1] if depth == 0 else re.sub(r"[^\n]", " ", body[i : j + 1]))
            i = j + 1
            continue
        if c == "{":
            depth += 1
        out.append(c if depth == 0 or c == "\n" else " ")
        if c == "}":
            depth -= 1
        i += 1
    return "".join(out)


def _attr(body: str, name: str) -> Optional[str]:
    m = re.search(rf"(?m)^\s*{name}\s*=\s*(.+?)\s*$", body)
    return m.group(1) if m else None


def _pool(expr: Optional[str]) -> Optional[str]:
    m = _POOL_REF.fullmatch(expr or "")
    return m.group(1) if m else None


# ----------------------------------------------------------------------------------------------
# Model
# ----------------------------------------------------------------------------------------------
@dataclass
class Client:
    name: str
    where: str
    pool: Optional[str]
    pool_expr: Optional[str]
    interactive: bool
    multi: str  # "" single, "for_each", "count"


@dataclass
class Branding:
    name: str
    where: str
    pool: Optional[str]
    for_each: Optional[str]
    client_id: Optional[str]


def _flows(body: str) -> Optional[set[str]]:
    expr = _attr(body, "allowed_oauth_flows")
    if expr is None:
        return set()
    if not re.fullmatch(r"\[[^\]]*\]", expr):
        return None  # not a literal list: unknown
    return set(re.findall(r'"([\w-]+)"', expr))


def scan(root: Path) -> tuple[list[str], int]:
    """Violations and the number of interactive v2 clients checked."""
    files = sorted(root.glob("*.tf"))
    if not files:
        raise InputError(f"no *.tf files in {root}")
    texts = {f.name: _strip_comments(f.read_text(encoding="utf-8")) for f in files}

    errors: list[str] = []
    v2_pools: set[str] = set()
    clients: list[Client] = []
    brandings: list[Branding] = []

    for fname, text in texts.items():
        for name, body in _resources(text, "aws_cognito_user_pool_domain"):
            version = _attr(body, "managed_login_version")
            if version is None or version == "1":
                continue
            pool_expr = _attr(body, "user_pool_id")
            pool = _pool(pool_expr)
            if pool is None:
                errors.append(f"B3 {fname}:aws_cognito_user_pool_domain.{name}: user_pool_id {pool_expr!r} is not "
                              "aws_cognito_user_pool.<name>.id, cannot check its clients")
                continue
            v2_pools.add(pool)

        for name, body in _resources(text, "aws_cognito_user_pool_client"):
            flows = _flows(body)
            pool_expr = _attr(body, "user_pool_id")
            multi = "for_each" if _attr(body, "for_each") else ("count" if _attr(body, "count") else "")
            if flows is None:
                errors.append(f"B3 {fname}:aws_cognito_user_pool_client.{name}: allowed_oauth_flows is not a literal "
                              "list, cannot tell whether it shows a login page")
                flows = set(INTERACTIVE_FLOWS)
            clients.append(Client(name, fname, _pool(pool_expr), pool_expr, bool(flows & INTERACTIVE_FLOWS), multi))

        for name, body in _resources(text, "aws_cognito_managed_login_branding"):
            brandings.append(Branding(name, fname, _pool(_attr(body, "user_pool_id")),
                                      _attr(body, "for_each"), _attr(body, "client_id")))

    checked = 0
    for c in clients:
        if not c.interactive:
            continue
        label = f"{c.where}:aws_cognito_user_pool_client.{c.name}"
        if c.pool is None:
            errors.append(f"B3 {label}: user_pool_id {c.pool_expr!r} is not aws_cognito_user_pool.<name>.id")
            continue
        if c.pool not in v2_pools:
            continue
        checked += 1
        if c.multi == "count":
            errors.append(f"B1 {label}: uses count; use for_each so a branding for_each over it covers every instance")
            continue
        ref = f"aws_cognito_user_pool_client.{c.name}"
        if c.multi == "for_each":
            covering = [b for b in brandings if b.for_each == ref]
            want = f"for_each = {ref}"
        else:
            covering = [b for b in brandings if b.client_id == f"{ref}.id"]
            want = f"client_id = {ref}.id"
        if not covering:
            errors.append(f"B1 {label}: interactive client of managed login v2 pool aws_cognito_user_pool.{c.pool} "
                          f"has no aws_cognito_managed_login_branding ({want}); its /login answers 403")
            continue
        for b in covering:
            if b.pool != c.pool:
                errors.append(f"B2 {b.where}:aws_cognito_managed_login_branding.{b.name}: user_pool_id is not "
                              f"aws_cognito_user_pool.{c.pool}.id (the pool of {ref})")
    return errors, checked


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--source", required=True, type=Path, help="Terraform root, e.g. accounts/aa365")
    args = ap.parse_args(argv)
    try:
        errors, checked = scan(args.source)
    except (InputError, OSError, UnicodeDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    if errors:
        print(f"FAIL: {len(errors)} managed login branding violation(s) in {args.source}:")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"OK: {checked} interactive client resource(s) of managed login v2 pools in {args.source}, each with a style")
    return 0


if __name__ == "__main__":
    sys.exit(main())
