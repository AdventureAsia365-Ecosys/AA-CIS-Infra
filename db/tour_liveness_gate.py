"""AA-986 L7b (ADR 0015 decision 6): the verdict of the nightly DB Tour Liveness Gate.

The workflow `.github/workflows/db-tour-liveness-gate.yml` runs `db/scripts/s248_tour_deletion_probe.py` through the
DB Migrate run-script mechanism (one-off ECS task of the migrator task definition, `db/run_migration.py`, master
login, READ_ONLY) and saves the task's log. This script reads that log and decides:

  green  the task exited 0, the runner logged a READ_ONLY run, the probe printed exactly one
         `SCRIPT verdict violations=0 errors=0 ...` line and its JSON (`SCRIPT json[i/n] <part>|` lines, joined in
         order) agrees with it
  red    anything else: a `zero` layer or check with hits (violations > 0), a layer or check that failed to run
         (errors > 0, which includes the probe's visibility floor and a missing object of a landed slice), no
         catalog role could read the catalog, the task failed or never printed a verdict, the run was not read-only,
         a JSON part is missing or cut short, the verdict line and the JSON disagree, or a check of a landed slice
         reports `pending`

It writes a Markdown report to the step summary (`--summary`), one `::error::` / `::warning::` annotation per finding,
and the verdict as JSON (`--out`). Exit 0 = green, 1 = red, 2 = bad arguments. No AWS, no database: stdlib only.

  python3 db/tour_liveness_gate.py --log task.log --exit-code 0 --summary "$GITHUB_STEP_SUMMARY" --out gate.json
"""
import argparse
import json
import re
import sys

READ_ONLY_MARK = "READ_ONLY: default_transaction_read_only=on"
# db/run_migration.py exit codes a run-script can end with (DB Migrate prints the same meanings).
TASK_EXIT = {
    "2": "the script's sha256 did not match what was uploaded",
    "7": "refused: a job table is busy (a READ_ONLY script should never wait; is READ_ONLY still True?)",
    "8": "role refused: run-script needs the RDS master login (see the MIGRATE ERROR: role line)",
    "10": "the runner refused the mode input or the script's shape (see the MIGRATE ERROR line)",
    "13": "the probe raised or returned non-zero (see the MIGRATE ERROR line)",
}


JSON_PART_RE = re.compile(r"^SCRIPT json\[(\d+)/(\d+)\] (.*)$")


def read_json(lines):
    """The probe's result from its `SCRIPT json[i/n] <part>|` lines: (dict, None) or (None, why it is unusable)."""
    parts = [JSON_PART_RE.match(x.rstrip("\r\n")) for x in lines if x.startswith("SCRIPT json")]
    if not parts:
        return None, "no `SCRIPT json[i/n]` line: the probe did not finish"
    if not all(parts):
        return None, "a `SCRIPT json` line is not of the form `SCRIPT json[i/n] <part>|`"
    total = {int(m[2]) for m in parts}
    idx = [int(m[1]) for m in parts]
    if len(total) != 1 or sorted(idx) != list(range(1, total.pop() + 1)):
        return None, f"the `SCRIPT json` parts are incomplete or repeated (got {sorted(idx)} of {parts[0][2]})"
    if not all(m[3].endswith("|") for m in parts):
        return None, "a `SCRIPT json` part was cut short (no closing `|`)"
    text = "".join(m[3][:-1] for m in sorted(parts, key=lambda m: int(m[1])))
    try:
        res = json.loads(text)
    except ValueError:
        return None, "the joined `SCRIPT json` parts are not valid JSON"
    if not isinstance(res, dict):
        return None, "the `SCRIPT json` value is not an object"
    return res, None


def kv(line, prefix):
    """`SCRIPT <kind> a=1 b=x` -> {"a": "1", "b": "x"} (values never contain spaces in the probe's output)."""
    out = {}
    for part in line[len(prefix):].split():
        k, sep, v = part.partition("=")
        if sep:
            out[k] = v
    return out


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def evaluate(lines, exit_code):
    """The gate's decision from the task log lines and the container exit code (str or None)."""
    lines = [x.rstrip("\n") for x in lines]
    failures, warnings = [], []
    code = None if exit_code is None else str(exit_code).strip()

    if code != "0":
        why = TASK_EXIT.get(code, "the task did not finish normally (stopped, out of memory, or no exit code)")
        failures.append(f"task exit code {code or 'unknown'}: {why}")
    if not any(x.startswith("MIGRATE ran as:") and READ_ONLY_MARK in x for x in lines):
        failures.append("the runner did not log a READ_ONLY run (`MIGRATE ran as: ... READ_ONLY ...`): "
                        "the probe must stay READ_ONLY = True")

    verdicts = [x for x in lines if x.startswith("SCRIPT verdict ")]
    verdict = None
    if len(verdicts) != 1:
        failures.append(f"expected one `SCRIPT verdict` line, found {len(verdicts)}: the probe did not finish")
    else:
        verdict = kv(verdicts[0], "SCRIPT verdict ")
    res, why = read_json(lines)
    if why:
        failures.append(why)

    out = {"green": False, "failures": failures, "warnings": warnings, "verdict": verdict,
           "violations": [], "errors": [], "pending": [], "checks": {}, "keep_warn": [], "catalog_role": None,
           "visibility": None}
    if verdict is not None:
        nv, ne = _int(verdict.get("violations")), _int(verdict.get("errors"))
        if nv is None or ne is None:
            failures.append("the verdict line has no numeric violations= / errors=")
        else:
            if nv:
                failures.append(f"{nv} violation(s): {verdict.get('list', '-')}")
            if ne:
                failures.append(f"{ne} error(s): a layer or check that failed to run, a missing object of a landed "
                                "slice, or the visibility floor (rows hidden from the login)")
            if res is not None and (nv != len(res.get("violations", [])) or ne != len(res.get("errors", []))):
                failures.append("the verdict line and the JSON disagree on violations / errors")
    if res is not None:
        out["violations"] = list(res.get("violations", []))
        out["errors"] = list(res.get("errors", []))
        out["pending"] = list(res.get("pending", []))
        out["checks"] = dict(res.get("checks", {}))
        out["catalog_role"] = (res.get("catalog") or {}).get("role")
        out["as_of"], out["db_role"], out["totals"] = res.get("as_of"), res.get("db_role"), res.get("totals")
        landed = set(res.get("landed") or [])
        stuck = [n for n in out["pending"] if (out["checks"].get(n) or {}).get("slice") in landed]
        if stuck:
            failures.append(f"check(s) of a landed slice report pending (their object is gone): {', '.join(stuck)}")
        out["visibility"] = res.get("visibility")
        for key in ("landed", "visibility"):
            if key not in res:
                failures.append(f"the probe's JSON has no `{key}`: an older probe without the landed-slice rule or the "
                                "visibility floor ran")
        if out["catalog_role"] is None:
            failures.append("no catalog role (booking, tripplanner) could read catalog.v_tour: the catalog layers "
                            "and the cross-app references were not checked")
        for bucket, b in (res.get("buckets") or {}).items():
            for layer, r in (b.get("layers") or {}).items():
                if r.get("expect") == "keep_warn" and r.get("n"):
                    out["keep_warn"].append({"where": f"{bucket}.{layer}", "n": r["n"], "sample": r.get("sample", [])})
        for name, r in out["checks"].items():
            if r.get("expect") == "keep_warn" and r.get("n"):
                out["keep_warn"].append({"where": f"check.{name}", "n": r["n"], "sample": r.get("sample", [])})
        for w in out["keep_warn"]:
            warnings.append(f"kept and flagged: {w['where']} n={w['n']}")
    out["green"] = not failures
    return out


def _cell(v):
    return str(v).replace("|", "/").replace("\n", " ")[:300]


def markdown(g, reason, res=None):
    status = "GREEN" if g["green"] else "**RED**"
    v = g["verdict"] or {}
    lines = [f"### Tour liveness gate ({reason})",
             f"- {status}: violations {v.get('violations', '?')}, errors {v.get('errors', '?')}, "
             f"pending checks {len(g['pending'])} (waiting for their slice: {', '.join(g['pending']) or 'none'})"]
    if g.get("as_of"):
        t = g.get("totals") or {}
        lines.append(f"- probe as of {g['as_of']}, login `{g.get('db_role')}`, catalog read as "
                     f"`{g.get('catalog_role') or '-'}`; {t.get('groups', '?')} tour groups, "
                     f"{t.get('groups_dead', '?')} with no live version")
        vis = g.get("visibility") or {}
        if vis:
            lines.append("- visibility (the login must see the AA rows): "
                         + ", ".join(f"{k} {'-' if v is None else v}" for k, v in vis.items()))
    for f in g["failures"]:
        lines.append(f"- failure: {_cell(f)}")
    flat = {}
    for bucket, b in ((res or {}).get("buckets") or {}).items():
        for layer, r in (b.get("layers") or {}).items():
            flat[f"{bucket}.{layer}"] = r
    for name, r in g["checks"].items():
        flat[f"check.{name}"] = r
    if g["violations"]:
        lines += ["", "| violation (expect zero) | n | sample |", "|---|---|---|"]
        for where in g["violations"]:
            r = flat.get(where, {})
            lines.append(f"| `{where}` | {r.get('n', '?')} | {_cell(', '.join(r.get('sample', [])) or '-')} |")
    if g["errors"]:
        lines += ["", "| failed to run | error | SQLSTATE | detail |", "|---|---|---|---|"]
        for e in g["errors"]:
            lines.append(f"| `{_cell(e.get('layer'))}` | {_cell(e.get('error'))} | {_cell(e.get('sqlstate') or '-')} "
                         f"| {_cell(e.get('detail', ''))} |")
    if g["checks"]:
        lines += ["", "| check (ADR 0015 decision 6) | slice | expect | n | sample / requires |",
                  "|---|---|---|---|---|"]
        for name, r in g["checks"].items():
            n = "-" if r.get("n") is None else r["n"]
            extra = r.get("requires") or r.get("error") or ", ".join(r.get("sample", [])) or "-"
            lines.append(f"| `{name}` | {r.get('slice', '?')} | {r.get('expect', '?')} | {n} | {_cell(extra)} |")
    if g["keep_warn"]:
        lines += ["", "| kept and flagged (keep_warn) | n | sample |", "|---|---|---|"]
        for w in g["keep_warn"]:
            lines.append(f"| `{w['where']}` | {w['n']} | {_cell(', '.join(w['sample']) or '-')} |")
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--log", required=True, help="the task log (one CloudWatch message per line)")
    ap.add_argument("--exit-code", default=None, help="exit code of the task's migrate container")
    ap.add_argument("--summary", help="append the Markdown report to this file (GITHUB_STEP_SUMMARY)")
    ap.add_argument("--out", help="write the verdict as JSON to this file")
    ap.add_argument("--reason", default="manual")
    a = ap.parse_args(argv)
    try:
        with open(a.log, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError as e:
        print(f"::error::tour liveness gate: cannot read the task log ({type(e).__name__})")
        lines = []
    g = evaluate(lines, a.exit_code)
    res, _ = read_json(lines)
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as f:
            f.write(markdown(g, a.reason, res))
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump({k: g.get(k) for k in ("green", "failures", "warnings", "verdict", "violations", "errors",
                                             "pending", "checks", "catalog_role", "visibility")}
                      | {"reason": a.reason}, f, indent=1)
    for f_ in g["failures"]:
        print(f"::error::tour liveness gate: {_cell(f_)}")
    for w in g["warnings"]:
        print(f"::warning::tour liveness gate: {_cell(w)}")
    print(f"tour liveness gate: {'GREEN' if g['green'] else 'RED'}")
    return 0 if g["green"] else 1


if __name__ == "__main__":
    sys.exit(main())
