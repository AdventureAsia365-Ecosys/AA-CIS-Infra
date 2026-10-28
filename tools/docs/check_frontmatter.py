#!/usr/bin/env python3
"""Validate doc front-matter against docs/templates/frontmatter.schema.json (AA-888).

Default mode (CI, every docs PR):
  * every docs/**/*.md file, and a CONTEXT.md at the repo root (the app and Infra repos), that
    starts with a '---' block must validate against the schema;
  * catalog IDs must be unique (templates excluded, they share placeholder IDs);
  * exit 1 on any error.

--freshness-report PATH (weekly schedule, warn-only):
  * writes a Markdown report of pages past last_reviewed + review_every_days (default 90),
    and of active runbooks whose last_tested is missing or older than 180 days;
  * prints ::warning annotations; always exits 0 unless the front-matter itself is broken.

Usage:
  python tools/docs/check_frontmatter.py
  python tools/docs/check_frontmatter.py --freshness-report freshness/freshness.md
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator, FormatChecker

from docslib import (
    REPO_ROOT,
    SOURCE_LANG,
    TRANSLATION_LANGS,
    Finding,
    emit,
    is_template,
    list_markdown,
    source_of_translation,
    split_front_matter,
    translation_lang,
)

SCHEMA_PATH = "docs/templates/frontmatter.schema.json"
# Pages that may carry catalog front-matter. CONTEXT.md sits at the root of each app and Infra repo
# (catalog ARCH-06-<repo>); the root repo has none, so this list changes nothing there.
SCOPE = ["docs", "CONTEXT.md"]
DEFAULT_REVIEW_DAYS = 90
RUNBOOK_TEST_DAYS = 180


def _stringify_dates(value):
    """YAML turns 2026-10-19 into a date; the schema expects the ISO string."""
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()[:10]
    if isinstance(value, dict):
        return {k: _stringify_dates(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_stringify_dates(v) for v in value]
    return value


def load_pages(root: Path) -> tuple[list[tuple[str, dict]], list[Finding]]:
    """Return ([(relpath, front_matter)], parse_errors) for pages in SCOPE with front-matter."""
    pages: list[tuple[str, dict]] = []
    errors: list[Finding] = []
    for relpath in list_markdown(SCOPE, root):
        text = (root / relpath).read_text(encoding="utf-8")
        try:
            raw, _ = split_front_matter(text)
        except ValueError as exc:
            errors.append(Finding(relpath, 1, "Front-matter", str(exc)))
            continue
        if raw is None:
            continue
        try:
            data = yaml.safe_load(raw)
        except yaml.YAMLError as exc:
            errors.append(Finding(relpath, 1, "Front-matter", f"YAML does not parse: {exc}"))
            continue
        if not isinstance(data, dict):
            errors.append(Finding(relpath, 1, "Front-matter", "front-matter must be a YAML mapping"))
            continue
        pages.append((relpath, _stringify_dates(data)))
    return pages, errors


def validate(root: Path, pages: list[tuple[str, dict]]) -> list[Finding]:
    schema = json.loads((root / SCHEMA_PATH).read_text(encoding="utf-8"))
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors: list[Finding] = []
    seen: dict[str, str] = {}
    by_path = dict(pages)
    for relpath, data in pages:
        for err in sorted(validator.iter_errors(data), key=lambda e: list(e.path)):
            where = ".".join(str(p) for p in err.path) or "(root)"
            errors.append(Finding(relpath, 1, "Front-matter", f"{where}: {err.message}"))
        lang = translation_lang(relpath)
        if lang is not None:
            # A translation shares the id of its English page, so it is not part of the unique-id check.
            errors += _check_translation(relpath, lang, data, by_path)
            continue
        if "translation_of" in data or data.get("lang", SOURCE_LANG) != SOURCE_LANG:
            errors.append(Finding(relpath, 1, "Front-matter",
                                  f"only a translation file (<name>.<lang>.md, lang one of {', '.join(TRANSLATION_LANGS)}) "
                                  f"may set translation_of or a lang other than {SOURCE_LANG}"))
        page_id = data.get("id")
        if isinstance(page_id, str) and not is_template(relpath):
            if page_id in seen:
                errors.append(
                    Finding(relpath, 1, "Front-matter", f"duplicate id {page_id} (also in {seen[page_id]})")
                )
            else:
                seen[page_id] = relpath
    return errors


def _check_translation(relpath: str, lang: str, data: dict, by_path: dict[str, dict]) -> list[Finding]:
    """A <name>.<lang>.md page: lang matches the file name, translation_of names the English page next to it, and that
    page exists with the same id (docs/STYLE.md "Language")."""
    errors: list[Finding] = []
    source = source_of_translation(relpath)
    if data.get("lang") != lang:
        errors.append(Finding(relpath, 1, "Front-matter", f"a translation file named *.{lang}.md needs lang: {lang}"))
    if data.get("translation_of") != source:
        errors.append(Finding(relpath, 1, "Front-matter", f"translation_of must be {source} (the English page)"))
    english = by_path.get(source)
    if english is None:
        errors.append(Finding(relpath, 1, "Front-matter",
                              f"translation of {source}, but that page is missing or has no front-matter"))
    elif english.get("id") != data.get("id"):
        errors.append(Finding(relpath, 1, "Front-matter",
                              f"id {data.get('id')} differs from the English page ({english.get('id')} in {source})"))
    return errors


def _parse_date(value) -> dt.date | None:
    try:
        return dt.date.fromisoformat(str(value)) if value else None
    except ValueError:
        return None


def freshness(pages: list[tuple[str, dict]], today: dt.date) -> tuple[list[dict], list[dict]]:
    stale: list[dict] = []
    untested: list[dict] = []
    for relpath, data in pages:
        if is_template(relpath) or data.get("status") in ("superseded", "archived"):
            continue
        if data.get("generated") is True:
            continue  # the generator keeps it fresh; its own workflow is the check
        reviewed = _parse_date(data.get("last_reviewed"))
        window = data.get("review_every_days") or DEFAULT_REVIEW_DAYS
        if reviewed:
            due = reviewed + dt.timedelta(days=int(window))
            if today > due:
                stale.append(
                    {"path": relpath, "id": data.get("id"), "last_reviewed": reviewed.isoformat(),
                     "due": due.isoformat(), "overdue_days": (today - due).days}
                )
        is_runbook = "last_tested" in data
        if is_runbook and data.get("status") == "active":
            tested = _parse_date(data.get("last_tested"))
            if tested is None or (today - tested).days > RUNBOOK_TEST_DAYS:
                untested.append(
                    {"path": relpath, "id": data.get("id"),
                     "last_tested": tested.isoformat() if tested else "never",
                     "tested_where": data.get("tested_where") or "-"}
                )
    stale.sort(key=lambda r: -r["overdue_days"])
    return stale, untested


def write_report(path: Path, stale: list[dict], untested: list[dict], total: int, today: dt.date) -> None:
    lines = [
        "# Docs freshness report",
        "",
        f"Generated {today.isoformat()} by `.github/workflows/docs-lint.yml` (AA-888). "
        f"Pages checked: {total}. Rules: `last_reviewed` + `review_every_days` (default {DEFAULT_REVIEW_DAYS}); "
        f"active runbooks need `last_tested` within {RUNBOOK_TEST_DAYS} days. "
        "On Dev a stale `last_tested` is a warning, not an order to re-run (DM-9.3).",
        "",
        f"## Past review date ({len(stale)})",
        "",
    ]
    if stale:
        lines += ["| ID | Page | Last reviewed | Due | Days overdue |", "|---|---|---|---|---|"]
        lines += [
            f"| {r['id']} | `{r['path']}` | {r['last_reviewed']} | {r['due']} | {r['overdue_days']} |"
            for r in stale
        ]
    else:
        lines.append("None.")
    lines += ["", f"## Active runbooks without a recent test ({len(untested)})", ""]
    if untested:
        lines += ["| ID | Runbook | Last tested | Where |", "|---|---|---|---|"]
        lines += [f"| {r['id']} | `{r['path']}` | {r['last_tested']} | {r['tested_where']} |" for r in untested]
    else:
        lines.append("None.")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="repo root (default: this checkout)")
    parser.add_argument("--freshness-report", type=Path, help="write the weekly freshness report here")
    parser.add_argument("--today", type=dt.date.fromisoformat, default=dt.date.today(), help="override today (tests)")
    args = parser.parse_args(argv)
    root = args.root.resolve()

    pages, parse_errors = load_pages(root)
    errors = parse_errors + validate(root, pages)
    emit(errors, "error")

    if args.freshness_report:
        stale, untested = freshness(pages, args.today)
        write_report(args.freshness_report, stale, untested, len(pages), args.today)
        emit([Finding(r["path"], 1, "Review overdue", f"{r['id']}: last_reviewed {r['last_reviewed']}, "
                      f"due {r['due']} ({r['overdue_days']} days overdue)") for r in stale], "warning")
        emit([Finding(r["path"], 1, "Runbook untested", f"{r['id']}: last_tested {r['last_tested']}")
              for r in untested], "warning")
        print(f"freshness: {len(pages)} pages, {len(stale)} past review, {len(untested)} runbooks untested")

    print(f"front-matter: {len(pages)} pages checked, {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
