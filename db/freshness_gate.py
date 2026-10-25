"""AA-991: the verdict of the nightly DB Freshness Probe (does every layer built on a tour's atoms follow its source?).

The workflow `.github/workflows/db-freshness-probe.yml` runs `db/scripts/aa991_freshness_probe.py` through the DB
Migrate run-script mechanism (one-off ECS task of the migrator task definition, `db/run_migration.py`, master login,
READ_ONLY; the probe reads as `cis_app`) and saves the task's log. This script reads that log and decides.

Two modes. **Report** (`ENFORCE = False`, the default until AA-988 / AA-989 / AA-990 close): red only when the probe
itself failed — the task did not exit 0, the runner logged no READ_ONLY run, no single `SCRIPT verdict` line, a
`SCRIPT json[i/n]` part missing or cut short, the verdict line and the JSON disagree, a metric failed to run or the
visibility floor tripped (`errors > 0`), the probe did not read as `cis_app`, or a metric of BASELINE is missing from
the JSON (a renamed metric must not drop out silently). Counts are compared with the S251 baseline: a count above
its baseline is a warning, and the stale metrics that would be red once enforced are listed.
**Enforce** (`ENFORCE = True`, or `--enforce` / the workflow input `enforce=true` for one run): additionally red on
every `stale` metric whose `aged` count (links of tours changed more than 24 h before the probe) is above zero.

It writes a Markdown report to the step summary (`--summary`), one `::error::` / `::warning::` annotation per finding,
and the verdict as JSON (`--out`). Exit 0 = green, 1 = red, 2 = bad arguments. No AWS, no database: stdlib only.

  python3 db/freshness_gate.py --log task.log --exit-code 0 --summary "$GITHUB_STEP_SUMMARY" --out gate.json
"""
import argparse
import json
import sys

from tour_liveness_gate import READ_ONLY_MARK, TASK_EXIT, _cell, _int, kv, read_json

# The switch (AA-991 Done-when: "after the other S1 propagation issues close, the probe shows 0 stale links").
# A one-line PR sets it to True once AA-988, AA-989 and AA-990 are Done and a report-only night shows stale_aged=0.
ENFORCE = False
READ_ROLE = "cis_app"

# S251 baseline (25/10/2026, Dev, read as cis_app over ECS exec; root .tmp-session/s251/audit-s1prop/coverage*.txt
# and the Linear text of AA-988 / AA-989 / AA-990 / AA-991). None = the metric is sharper than any S251 query: its
# baseline is the first nightly run (recorded in db/README.md). Approximate entries are marked in db/README.md.
BASELINE_AS_OF = "S251 2026-10-25"
BASELINE = {
    "atoms_older_than_master": 0,
    "active_tours_without_atoms": 0,
    "active_atoms_without_segment": 9004,          # 25,877 active atoms - 16,873 in a segment
    "tours_with_place_atoms_but_no_segment": None,
    "orphan_segments": 8578,                       # 18,978 segments - 10,400 holding an active atom (narrowed by
                                                   # AA-988 to zero-reference orphans: an upper bound now)
    "orphan_segments_kept_referenced": None,       # AA-988 info: orphans a reference keeps (history)
    "ranking_missing": None,
    "ranking_off_active_pairs": None,              # S251 segment-level twin: 0 rows on dead segments
    "active_tours_without_ranking": 9,             # 892 active - 883 tours with current rows
    "routes_missing": None,
    "routes_differ": None,
    "active_tours_without_route": 192,             # 892 active - 700 tours with a current route
    "current_routes_older_than_atoms": 3,
    "routes_with_dead_segment": 0,
    "geo_tour_place_rows_on_inactive_atoms": 2038,  # of 2,480 rows, 123 tours
    "geo_tour_place_stale_rows": None,
    "place_card_links_missing": None,
    "active_place_atoms_without_card_link": None,   # S251: only 105 active atoms linked to a card
    "tenant_versions_older_than_master": 2,         # of 55 versions
    "angle_gate_requests_on_inactive_atoms": 14,    # of 25 requests
    "seo_context_expired": 76,                      # of 918 rows
    "seo_context_expired_active_tours": None,
}


def evaluate(lines, exit_code, enforce=False):
    """The gate's decision from the task log lines, the container exit code (str or None) and the mode."""
    lines = [x.rstrip("\n") for x in lines]
    failures, warnings, notes = [], [], []
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

    out = {"green": False, "mode": "enforce" if enforce else "report", "failures": failures, "warnings": warnings,
           "notes": notes, "verdict": verdict, "metrics": {}, "errors": [], "would_fail": [], "above_baseline": [],
           "read_as": None, "totals": None, "jobs_in_flight": []}
    if verdict is not None:
        ne, na = _int(verdict.get("errors")), _int(verdict.get("stale_aged"))
        if ne is None or na is None:
            failures.append("the verdict line has no numeric errors= / stale_aged=")
        else:
            if ne:
                failures.append(f"{ne} error(s): a metric that failed to run, the role switch, or the visibility "
                                "floor (rows hidden from the login)")
            if res is not None and (ne != len(res.get("errors", []))
                                    or na != (res.get("verdict") or {}).get("stale_aged")):
                failures.append("the verdict line and the JSON disagree on errors / stale_aged")
    if res is not None:
        metrics = dict(res.get("metrics") or {})
        out.update(metrics=metrics, errors=list(res.get("errors", [])), read_as=res.get("read_as"),
                   totals=res.get("totals"), jobs_in_flight=list(res.get("jobs_in_flight") or []),
                   as_of=res.get("as_of"), cutoff=res.get("cutoff"))
        if out["read_as"] != READ_ROLE:
            failures.append(f"the probe read as `{out['read_as']}`, not `{READ_ROLE}`: the counts are not comparable "
                            "with the baseline (and FORCE RLS tables may hide rows)")
        missing = [m for m in BASELINE if m not in metrics]
        if missing:
            failures.append(f"metric(s) of the baseline missing from the probe: {', '.join(missing)}")
        for name, m in metrics.items():
            n, aged, base = m.get("n"), m.get("aged"), BASELINE.get(name)
            if m.get("gate") == "stale" and aged:
                out["would_fail"].append(name)
            if n is not None and base is not None and n > base:
                out["above_baseline"].append(name)
                warnings.append(f"{name} = {n}, above the {BASELINE_AS_OF} baseline {base}")
        if enforce:
            for name in out["would_fail"]:
                failures.append(f"stale: {name} has {metrics[name]['aged']} link(s) of tours changed more than "
                                f"{res.get('stale_after_hours', 24)} h ago (sample: "
                                f"{', '.join(metrics[name].get('sample_aged') or []) or '-'})")
        elif out["would_fail"]:
            notes.append("report-only: red once enforced: " + ", ".join(out["would_fail"]))
    out["green"] = not failures
    return out


def markdown(g, reason):
    status = "GREEN" if g["green"] else "**RED**"
    v = g["verdict"] or {}
    lines = [f"### Downstream freshness probe ({reason}, mode {g['mode']})",
             f"- {status}: stale metrics with links {v.get('stale', '?')}, aged stale links {v.get('stale_aged', '?')}"
             f", errors {v.get('errors', '?')}"]
    if g.get("as_of"):
        t = g.get("totals") or {}
        lines.append(f"- probe as of {g['as_of']}, read as `{g.get('read_as')}`, aged = tour changed before "
                     f"{g.get('cutoff')}; {t.get('active_tours', '?')} active tours, {t.get('active_atoms', '?')} "
                     f"active atoms, {t.get('tours_changed_within_window', '?')} tours changed inside the window")
    if g["jobs_in_flight"]:
        lines.append("- propagation jobs in flight: " + ", ".join(
            f"{_cell(j.get('kind'))} {_cell(j.get('status'))} {j.get('n')}" for j in g["jobs_in_flight"]))
    for f in g["failures"]:
        lines.append(f"- failure: {_cell(f)}")
    for n in g["notes"]:
        lines.append(f"- {_cell(n)}")
    if g["metrics"]:
        lines += ["", f"| metric | gate | n | aged (> 24 h) | baseline ({BASELINE_AS_OF}) | delta | sample |",
                  "|---|---|---|---|---|---|---|"]
        for name, m in g["metrics"].items():
            n, base = m.get("n"), BASELINE.get(name)
            delta = "-" if n is None or base is None else f"{n - base:+d}"
            shown = m.get("sample_aged") or m.get("sample") or []
            lines.append(f"| `{name}` | {m.get('gate', '?')} | {'-' if n is None else n} | "
                         f"{'-' if m.get('aged') is None else m['aged']} | {'first run' if base is None else base} | "
                         f"{delta} | {_cell(', '.join(shown) or m.get('error') or '-')} |")
    if g["errors"]:
        lines += ["", "| failed to run | error | SQLSTATE | detail |", "|---|---|---|---|"]
        for e in g["errors"]:
            lines.append(f"| `{_cell(e.get('metric'))}` | {_cell(e.get('error'))} | {_cell(e.get('sqlstate') or '-')} "
                         f"| {_cell(e.get('detail', ''))} |")
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--log", required=True, help="the task log (one CloudWatch message per line)")
    ap.add_argument("--exit-code", default=None, help="exit code of the task's migrate container")
    ap.add_argument("--summary", help="append the Markdown report to this file (GITHUB_STEP_SUMMARY)")
    ap.add_argument("--out", help="write the verdict as JSON to this file")
    ap.add_argument("--reason", default="manual")
    ap.add_argument("--enforce", action="store_true", help="red on aged stale links for this run (ENFORCE=True)")
    a = ap.parse_args(argv)
    try:
        with open(a.log, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError as e:
        print(f"::error::freshness probe: cannot read the task log ({type(e).__name__})")
        lines = []
    g = evaluate(lines, a.exit_code, enforce=a.enforce or ENFORCE)
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as f:
            f.write(markdown(g, a.reason))
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump({k: g.get(k) for k in ("green", "mode", "failures", "warnings", "notes", "verdict", "metrics",
                                             "errors", "would_fail", "above_baseline", "read_as", "totals",
                                             "jobs_in_flight")}
                      | {"reason": a.reason, "baseline": BASELINE, "baseline_as_of": BASELINE_AS_OF}, f, indent=1,
                      default=str)
    for f_ in g["failures"]:
        print(f"::error::freshness probe: {_cell(f_)}")
    for w in g["warnings"]:
        print(f"::warning::freshness probe: {_cell(w)}")
    for n in g["notes"]:
        print(f"freshness probe: {n}")
    print(f"freshness probe ({g['mode']}): {'GREEN' if g['green'] else 'RED'}")
    return 0 if g["green"] else 1


if __name__ == "__main__":
    sys.exit(main())
