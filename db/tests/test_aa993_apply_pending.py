"""AA-993 Phase E slice M3: the expand auto-apply (run_migration apply-pending mode + db/apply_pending.py).

No database, no AWS: the task half runs against the fakes of test_run_migration, the runner half on temp folders.
  python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import hashlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import apply_pending as ap  # noqa: E402
import check_migration_copies as cmc  # noqa: E402
import replay_migrations as rp  # noqa: E402
import run_migration as rm  # noqa: E402
from test_aa993_expand import tx  # noqa: E402
from test_run_migration import FakeConn, PgError  # noqa: E402


def expand(number, owner="booking", table=None):
    key = f"{rm.AUTO_KEY_PREFIX[owner]}{number:03d}"
    schema = {"booking": "booking", "crm": "crm", "tripplanner": "tripplanner", "cis": "shared"}[owner]
    body = f"CREATE TABLE {schema}.{table or f'aa993_t{number}'} (id bigint PRIMARY KEY);"
    return tx(body, version=key)


def contract(number, owner="booking"):
    key = f"{rm.AUTO_KEY_PREFIX[owner]}{number:03d}"
    return tx("ALTER TABLE booking.trip ADD CONSTRAINT c CHECK (true);", version=key, header="")


def entry(path, sql, verdict="ok"):
    return {"path": path, "sql": sql, "verdict": verdict}


def registered(owner, upto, start=1):
    return {f"{rm.AUTO_KEY_PREFIX[owner]}{n:03d}" for n in range(start, upto + 1)}


class RegistryMirrorTest(unittest.TestCase):
    def test_key_prefixes_match_the_replay_and_the_copy_guard(self):
        for owner in rm.AUTO_OWNERS:
            self.assertEqual(rm.AUTO_KEY_PREFIX[owner], rp.KEY_PREFIX[owner])
            self.assertEqual(rm.AUTO_KEY_PREFIX[owner], cmc.OWNERS[owner].key_prefix)
        self.assertNotIn("roles", rm.AUTO_OWNERS)           # master files never auto-applied

    def test_apply_pending_is_a_known_mode(self):
        self.assertEqual(rm.parse_mode("apply-pending").kind, "apply-pending")


class PlanPendingTest(unittest.TestCase):
    def steps(self, files, reg, owner="booking"):
        return [(s.action, s.path) for s in rm.plan_pending(files, reg)[owner]["steps"]]

    def test_contract_before_expand_stops_the_owner(self):
        # Design §2 M3: with expand 291 and contract 290 pending, nothing is applied.
        files = [entry("booking/290_c.sql", contract(290)), entry("booking/291_e.sql", expand(291))]
        self.assertEqual(self.steps(files, registered("booking", 289)), [("stop", "booking/290_c.sql")])

    def test_two_expand_files_apply_in_number_order(self):
        files = [entry("booking/291_e.sql", expand(291)), entry("booking/290_e.sql", expand(290))]
        self.assertEqual(self.steps(files, registered("booking", 289)),
                         [("apply", "booking/290_e.sql"), ("apply", "booking/291_e.sql")])

    def test_runner_refusal_stops_the_owner(self):
        files = [entry("booking/290_e.sql", expand(290), verdict="differs from the owner repo's main"),
                 entry("booking/291_e.sql", expand(291))]
        plan = rm.plan_pending(files, registered("booking", 289))["booking"]["steps"]
        self.assertEqual([(s.action, s.path) for s in plan], [("stop", "booking/290_e.sql")])
        self.assertIn("refused on the runner: differs", plan[0].reason)

    def test_out_of_order_file_is_never_applied_and_blocks(self):
        reg = registered("booking", 289) | {"bk-291"}
        files = [entry("booking/290_e.sql", expand(290)), entry("booking/292_e.sql", expand(292))]
        plan = rm.plan_pending(files, reg)["booking"]
        self.assertEqual(plan["head"], "bk-291")
        self.assertEqual([(s.action, s.path) for s in plan["steps"]], [("stop", "booking/290_e.sql")])
        self.assertIn("out-of-order", plan["steps"][0].reason)

    def test_registered_files_and_cis_legacy_gaps_are_skipped(self):
        reg = registered("cis", 300, start=264) | registered("cis", 231, start=25)
        files = [entry("cis/232_old.sql", contract(232, "cis")), entry("cis/263_old.sql", contract(263, "cis")),
                 entry("cis/300_x.sql", expand(300, "cis")), entry("cis/301_e.sql", expand(301, "cis"))]
        plan = rm.plan_pending(files, reg)["cis"]
        self.assertEqual(plan["legacy"], 2)
        self.assertEqual([(s.action, s.path) for s in plan["steps"]], [("apply", "cis/301_e.sql")])

    def test_expand_header_with_a_lint_error_stops(self):
        bad = tx("UPDATE booking.trip SET note = 'x';", version="bk-290")
        plan = rm.plan_pending([entry("booking/290_e.sql", bad)], registered("booking", 289))["booking"]["steps"]
        self.assertEqual(plan[0].action, "stop")
        self.assertIn("lint error", plan[0].reason)

    def test_a_gap_in_the_copies_stops_before_the_later_file(self):
        # Review of M3: 290 is on the owner's main but its copy PR has not merged; 291's copy is here. The task must
        # not apply 291 on its own (the runner's verdict is ok for 291, the replay copies in the owner's 290).
        plan = rm.plan_pending([entry("booking/291_e.sql", expand(291))], registered("booking", 289))["booking"]
        self.assertEqual([(s.action, s.path) for s in plan["steps"]], [("stop", "booking/291_e.sql")])
        self.assertIn("gap: bk-290 is neither registered nor copied", plan["steps"][0].reason)
        self.assertEqual(plan["steps"][0].kind, rm.STOP_GAP)              # M3 review: a gap is a stop a person sees

    def test_a_gap_after_applied_files_stops_there(self):
        files = [entry("booking/290_e.sql", expand(290)), entry("booking/292_e.sql", expand(292))]
        self.assertEqual(self.steps(files, registered("booking", 289)),
                         [("apply", "booking/290_e.sql"), ("stop", "booking/292_e.sql")])

    def test_an_owner_main_file_not_copied_yet_stops_its_number(self):
        files = [rm.not_copied_entry("booking/290_x.sql"), entry("booking/291_e.sql", expand(291))]
        plan = rm.plan_pending(files, registered("booking", 289))["booking"]["steps"]
        self.assertEqual([(s.action, s.path) for s in plan], [("stop", "booking/290_x.sql")])
        self.assertIn("not copied yet", plan[0].reason)

    def test_two_copies_with_one_number_stop_at_the_second(self):
        files = [entry("booking/290_a.sql", expand(290)), entry("booking/290_b.sql", expand(290))]
        plan = rm.plan_pending(files, registered("booking", 289))["booking"]["steps"]
        self.assertEqual([(s.action, s.path) for s in plan], [("apply", "booking/290_a.sql"),
                                                              ("stop", "booking/290_b.sql")])
        self.assertIn("duplicate number", plan[1].reason)

    def test_every_stop_has_an_enumerated_kind(self):
        # M3 review: the stop reason is classified explicitly (run_migration.STOP_KINDS), never by its text.
        reg = registered("booking", 289)
        cases = [
            ([entry("booking/290_c.sql", contract(290))], reg, rm.STOP_CONTRACT),
            ([entry("booking/290_e.sql", expand(290))], reg | {"bk-291"}, rm.STOP_OUT_OF_ORDER),
            ([rm.not_copied_entry("booking/290_x.sql")], reg, rm.STOP_NOT_COPIED),
            ([entry("booking/291_e.sql", expand(291))], reg, rm.STOP_GAP),
            ([entry("booking/290_a.sql", expand(290)), entry("booking/290_b.sql", expand(290))], reg,
             rm.STOP_DUPLICATE),
            ([entry("booking/290_e.sql", tx("UPDATE booking.trip SET note = 'x';", version="bk-290"))], reg,
             rm.STOP_LINT),
        ]
        for verdict_kind in (rm.STOP_REFUSED_BYTES, rm.STOP_REFUSED_CLASSIFY, rm.STOP_NO_EVIDENCE):
            cases.append(([dict(entry("booking/290_e.sql", expand(290), verdict="why"), verdict_kind=verdict_kind)],
                          reg, verdict_kind))
        cases.append(([entry("booking/290_e.sql", expand(290), verdict="why")], reg, rm.STOP_REFUSED))
        cases.append(([dict(entry("booking/290_e.sql", expand(290), verdict="why"), verdict_kind="bogus")], reg,
                      rm.STOP_REFUSED))
        for files, keys, kind in cases:
            stops = [s for s in rm.plan_pending(files, keys)["booking"]["steps"] if s.action == "stop"]
            self.assertEqual([s.kind for s in stops], [kind], files[-1]["path"])
        self.assertEqual(set(rm.STOP_KINDS), set(ap.STOP_NOTES))           # every kind has a person's note

    def test_owners_are_independent(self):
        files = [entry("booking/290_c.sql", contract(290)), entry("crm/024_e.sql", expand(24, "crm"))]
        plan = rm.plan_pending(files, registered("booking", 289) | registered("crm", 23))
        self.assertEqual(plan["booking"]["steps"][0].action, "stop")
        self.assertEqual([(s.action, s.path) for s in plan["crm"]["steps"]], [("apply", "crm/024_e.sql")])
        self.assertEqual(plan["tripplanner"], {"head": None, "steps": [], "legacy": 0})


def bundle(files, **override):
    data = {"kind": rm.BUNDLE_KIND, "format": 1,
            "files": [{"path": f["path"], "sql": f["sql"], "verdict": f.get("verdict", "ok"),
                       "sha256": hashlib.sha256(f["sql"].encode()).hexdigest()} for f in files]}
    data.update(override)
    return json.dumps(data).encode()


class LockConn:
    """The run's own session: the apply lock and the registry read."""

    def __init__(self, keys, lock_free=True):
        self.keys, self.lock_free, self.closed, self.lock_tries = list(keys), lock_free, False, 0

    async def fetchval(self, query, *args):
        assert query == rm.APPLY_LOCK_SQL, query
        self.lock_tries += 1
        return self.lock_free

    async def fetch(self, query, *args):
        assert query == rm.REGISTERED_SQL, query
        return [(k,) for k in self.keys]

    async def close(self):
        self.closed = True


class RunApplyPendingTest(unittest.TestCase):
    def run_pending(self, raw, keys, file_conns=None, lock_free=True, sha=None):
        self.lock = LockConn(keys, lock_free)
        self.file_conns = list(file_conns or [])
        self.used, self.sleeps, self.settings = [], [], []
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": sha or hashlib.sha256(raw).hexdigest(),
               "MIGRATION_MODE": "apply-pending", "MIGRATION_FILE": "", "MIGRATION_VERSION": "",
               "MIGRATION_IDLE_OVERRIDE": "someone's reason", "DATABASE_URL": "postgresql://x"}
        first = [True]

        async def connect(dsn, settings, **kw):
            self.settings.append(dict(settings))
            if first[0]:
                first[0] = False
                return self.lock
            conn = self.file_conns.pop(0) if self.file_conns else FakeConn()
            self.used.append(conn)
            return conn

        async def sleep(s):
            self.sleeps.append(s)

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asyncio.run(rm.run_task(env, fetch=lambda url: raw, connect=connect, sleep=sleep,
                                           get_secret=lambda sid: (_ for _ in ()).throw(LookupError(sid))))
        self.log = out.getvalue()
        return code

    def result(self):
        return ap.parse_result(self.log)

    def test_two_expand_files_are_applied_in_order_under_one_lock(self):
        files = [entry("booking/291_b.sql", expand(291)), entry("booking/290_a.sql", expand(290))]
        code = self.run_pending(bundle(files), registered("booking", 289))
        self.assertEqual(code, 0, self.log)
        self.assertEqual(self.lock.lock_tries, 1)
        self.assertTrue(self.lock.closed)
        self.assertTrue(all(c.executed[0].endswith("BEGIN;") for c in self.used))
        self.assertIn("CREATE TABLE booking.aa993_t290", self.used[0].executed[1])
        self.assertIn("CREATE TABLE booking.aa993_t291", self.used[1].executed[1])
        self.assertEqual(self.settings[1]["statement_timeout"], "30s")           # expand files: 30 s
        self.assertIn("apply lock: held by this run's own session (apply-pending)", self.log)
        self.assertNotIn("OVERRIDDEN", self.log)                                  # no idle override, ever
        rows = self.result()["owners"]["booking"]["files"]
        self.assertEqual([(r["file"], r["status"]) for r in rows],
                         [("booking/290_a.sql", "applied"), ("booking/291_b.sql", "applied")])

    def test_contract_first_applies_nothing(self):
        files = [entry("booking/290_c.sql", contract(290)), entry("booking/291_e.sql", expand(291))]
        code = self.run_pending(bundle(files), registered("booking", 289))
        self.assertEqual(code, 0)
        self.assertEqual(self.used, [])
        self.assertIn("auto: booking: STOP at booking/290_c.sql (bk-290): contract", self.log)
        row = self.result()["owners"]["booking"]["files"][0]
        self.assertEqual((row["status"], row["kind"]), ("manual", rm.STOP_CONTRACT))

    def test_lock_held_by_another_run_is_exit_17_and_nothing_runs(self):
        files = [entry("booking/290_e.sql", expand(290))]
        rm_wait = rm.APPLY_LOCK_WAIT_S
        try:
            rm.APPLY_LOCK_WAIT_S = 30
            code = self.run_pending(bundle(files), registered("booking", 289), lock_free=False)
        finally:
            rm.APPLY_LOCK_WAIT_S = rm_wait
        self.assertEqual(code, 17)
        self.assertEqual(self.used, [])
        self.assertEqual(self.result()["exit"], 17)

    def test_lock_timeout_is_retried_with_backoff(self):
        locked = FakeConn(fail=PgError("55P03", "canceling statement due to lock timeout"))
        code = self.run_pending(bundle([entry("booking/290_e.sql", expand(290))]), registered("booking", 289),
                                file_conns=[locked, FakeConn()])
        self.assertEqual(code, 0, self.log)
        self.assertEqual(self.sleeps, [30])
        self.assertEqual(self.result()["owners"]["booking"]["files"][0]["status"], "applied")

    def test_lock_timeout_three_times_fails_with_exit_6(self):
        def locked():
            return FakeConn(fail=PgError("55P03", "canceling statement due to lock timeout"))
        code = self.run_pending(bundle([entry("booking/290_e.sql", expand(290))]), registered("booking", 289),
                                file_conns=[locked(), locked(), locked()])
        self.assertEqual(code, 6)
        self.assertEqual(self.sleeps, list(rm.AUTO_LOCK_RETRY_S))

    def test_a_failed_file_stops_its_owner_but_not_the_others(self):
        broken = FakeConn(fail=PgError("42P01", "relation does not exist"))
        files = [entry("booking/290_e.sql", expand(290)), entry("booking/291_e.sql", expand(291)),
                 entry("crm/024_e.sql", expand(24, "crm"))]
        code = self.run_pending(bundle(files), registered("booking", 289) | registered("crm", 23),
                                file_conns=[broken])
        self.assertEqual(code, 6)
        res = self.result()["owners"]
        self.assertEqual([(r["file"], r["status"]) for r in res["booking"]["files"]], [("booking/290_e.sql", "failed")])
        self.assertEqual([(r["file"], r["status"]) for r in res["crm"]["files"]], [("crm/024_e.sql", "applied")])
        self.assertEqual(self.sleeps, [])                       # not a lock timeout: no retry

    def test_hot_table_file_during_an_open_wave_is_deferred(self):
        cic = ("-- Migration bk-290: AA-993 index.\n-- migrate: no-transaction\n-- migrate: expand\n"
               "CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_job_x ON booking.job (kind);\n"
               "INSERT INTO shared.schema_versions (version, applied_at, description)\n"
               "VALUES ('bk-290', now(), 'AA-993: x') ON CONFLICT (version) DO NOTHING;\n")
        wave = FakeConn(states=[({"booking": [], "shared": []}, 1)])
        wave.reltuples = {"booking.job": 10}
        code = self.run_pending(bundle([entry("booking/290_ix.sql", cic)]), registered("booking", 289),
                                file_conns=[wave])
        self.assertEqual(code, 0, self.log)
        self.assertEqual(self.result()["owners"]["booking"]["files"][0]["status"], "deferred")

    def test_a_gap_applies_nothing_of_that_owner(self):
        files = [entry("booking/291_e.sql", expand(291)), entry("crm/024_e.sql", expand(24, "crm"))]
        keys = registered("booking", 289) | registered("crm", 23)
        code = self.run_pending(bundle(files, not_copied=["booking/290_x.sql"]), keys)
        self.assertEqual(code, 0, self.log)
        self.assertEqual(len(self.used), 1)                                   # only crm 024 ran
        self.assertIn("auto: booking: STOP at booking/290_x.sql (bk-290): not copied yet", self.log)
        res = self.result()["owners"]
        self.assertEqual([(r["file"], r["status"]) for r in res["booking"]["files"]],
                         [("booking/290_x.sql", "manual")])
        # Without the runner's gap list the task still refuses to jump the gap on its own.
        code = self.run_pending(bundle(files[:1]), registered("booking", 289))
        self.assertEqual((code, self.used), (0, []))
        self.assertIn("auto: booking: STOP at booking/291_e.sql (bk-291): gap: bk-290", self.log)

    def test_bundle_not_copied_list_is_checked(self):
        raw = bundle([entry("booking/290_e.sql", expand(290))], not_copied=["booking/290_other.sql"])
        self.assertEqual(self.run_pending(raw, []), 10)                       # its number has a copy
        self.assertEqual(self.run_pending(bundle([], not_copied=["roles/009_x.sql"]), []), 10)
        self.assertEqual(self.run_pending(bundle([], not_copied="booking/290_x.sql"), []), 10)

    def test_bundle_tampering_is_refused(self):
        raw = bundle([entry("booking/290_e.sql", expand(290))])
        self.assertEqual(self.run_pending(raw, [], sha="0" * 64), 2)
        bad = json.loads(raw)
        bad["files"][0]["sql"] += "\n-- extra"
        self.assertEqual(self.run_pending(json.dumps(bad).encode(), []), 10)
        self.assertIn("sha256 mismatch", self.log)
        self.assertEqual(self.run_pending(bundle([entry("roles/009_x.sql", expand(9))]), []), 10)
        self.assertEqual(self.run_pending(bundle([], kind="other"), []), 10)
        bad = json.loads(raw)
        bad["files"][0]["verdict_kind"] = "trust-me"
        self.assertEqual(self.run_pending(json.dumps(bad).encode(), []), 10)


class RunnerSideTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.repo, self.owner = base / "infra", base / "owner"
        (self.repo / "db" / "migrations" / "booking").mkdir(parents=True)
        self.owner.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, name, sql, owner_sql=None):
        (self.repo / "db" / "migrations" / "booking" / name).write_text(sql)
        if owner_sql is not False:
            (self.owner / name).write_text(sql if owner_sql is None else owner_sql)

    def classify(self, *expand_files, contract_files=()):
        return {"files": [{"file": f, "class": "expand", "header": "expand"} for f in expand_files]
                + [{"file": f, "class": "contract", "header": "expand", "findings": ["relation x changed"]}
                   for f in contract_files]}

    def run_plan(self, keys, classify=None, extra=()):
        (self.repo / "keys.txt").write_text("\n".join(sorted(keys)))
        args = ["plan", "--repo-root", str(self.repo), "--source", f"booking={self.owner}",
                "--registered", str(self.repo / "keys.txt"), "--bundle", str(self.repo / "bundle.json"),
                "--github-output", str(self.repo / "out.txt"), "--plan-out", str(self.repo / "plan.json"), *extra]
        if classify is not None:
            (self.repo / "classify.json").write_text(json.dumps(classify))
            args += ["--classify", str(self.repo / "classify.json")]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ap.main(args), 0)
        out = dict(ln.split("=", 1) for ln in (self.repo / "out.txt").read_text().splitlines())
        (self.repo / "out.txt").unlink()
        return out, json.loads((self.repo / "bundle.json").read_text())

    def test_byte_mismatch_against_the_owner_main_refuses(self):
        self.put("290_e.sql", expand(290), owner_sql=expand(290) + "\n-- edited on main\n")
        out, b = self.run_plan(registered("booking", 289), self.classify("booking/290_e.sql"))
        self.assertEqual(out["apply"], "false")
        self.assertTrue(b["files"][0]["verdict"].startswith("differs from the owner repo's main"))
        self.assertEqual(b["files"][0]["verdict_kind"], rm.STOP_REFUSED_BYTES)
        self.assertEqual(out["manual"], "refused-bytes:booking/290_e.sql")        # M3 review: a person must see it
        self.put("291_e.sql", expand(291), owner_sql=False)
        _, b = self.run_plan(registered("booking", 289), self.classify("booking/291_e.sql"))
        self.assertIn("not on the owner repo's main", b["files"][1]["verdict"])

    def test_classify_evidence_is_required(self):
        self.put("290_e.sql", expand(290))
        out, b = self.run_plan(registered("booking", 289))
        self.assertEqual((out["needs_classify"], out["apply"]), ("true", "false"))
        self.assertEqual(b["files"][0]["verdict"], ap.NO_EVIDENCE)
        self.assertEqual(out["manual"], "no-evidence:booking/290_e.sql")
        out, _ = self.run_plan(registered("booking", 289), extra=["--classify-skipped"])
        self.assertEqual(out["manual"], "")              # scheduled list-only run: the classify was skipped on purpose
        out, b = self.run_plan(registered("booking", 289), self.classify("booking/290_e.sql"))
        self.assertEqual((out["apply"], b["files"][0]["verdict"]), ("true", "ok"))
        out, b = self.run_plan(registered("booking", 289), self.classify(contract_files=["booking/290_e.sql"]))
        self.assertEqual(out["apply"], "false")
        self.assertIn("classified contract on the replay: relation x changed", b["files"][0]["verdict"])
        self.assertEqual(out["manual"], "refused-classify:booking/290_e.sql")

    def test_bundle_round_trips_into_the_task_reader(self):
        self.put("290_e.sql", expand(290))
        self.put("291_c.sql", contract(291))
        _, b = self.run_plan(registered("booking", 289), self.classify("booking/290_e.sql"))
        files = rm.read_bundle(json.dumps(b).encode())
        self.assertEqual([f["path"] for f in files], ["booking/290_e.sql", "booking/291_c.sql"])
        plan = json.loads((self.repo / "plan.json").read_text())["owners"]["booking"]["steps"]
        self.assertEqual([(s["action"], s["file"]) for s in plan],
                         [("apply", "booking/290_e.sql"), ("stop", "booking/291_c.sql")])

    def test_owner_main_file_not_copied_yet_is_a_gap_in_the_bundle(self):
        # Review of M3: 290 is on the owner's main only (copy PR not merged), 291 is copied and classified expand.
        self.put("289_e.sql", expand(289))
        (self.owner / "290_x.sql").write_text(expand(290))
        self.put("291_e.sql", expand(291))
        out, b = self.run_plan(registered("booking", 289), self.classify("booking/291_e.sql"))
        self.assertEqual(b["not_copied"], ["booking/290_x.sql"])
        self.assertEqual((out["apply"], out["needs_classify"], out["manual"]),
                         ("false", "false", "not-copied:booking/290_x.sql"))
        plan = json.loads((self.repo / "plan.json").read_text())["owners"]["booking"]["steps"]
        self.assertEqual([(s["action"], s["file"]) for s in plan], [("stop", "booking/290_x.sql")])
        self.assertIn("booking/290_x.sql", [f["path"] for f in rm.read_bundle(json.dumps(b).encode())])
        # Below the owner's lowest copy is pre-copy-flow history: never a gap.
        (self.owner / "005_history.sql").write_text("-- old\n")
        self.assertEqual(ap.not_copied(self.repo, {"booking": self.owner}), ["booking/290_x.sql"])

    def test_nothing_pending_needs_no_classify(self):
        self.put("290_e.sql", expand(290))
        out, _ = self.run_plan(registered("booking", 290))
        self.assertEqual(out, {"needs_classify": "false", "apply": "false", "pending": "0", "manual": ""})

    def test_report_reads_the_auto_result_line(self):
        res = {"bundle": "abc", "exit": 0, "owners": {
            "booking": {"head_before": "bk-289", "legacy": 0, "files": [
                {"file": "booking/290_e.sql", "version": "bk-290", "status": "applied"},
                {"file": "booking/291_c.sql", "version": "bk-291", "status": "manual", "kind": "contract",
                 "reason": "contract (no header)"}]},
            "crm": {"head_before": "crm-023", "legacy": 0, "files": [
                {"file": "crm/024_e.sql", "version": "crm-024", "status": "manual", "kind": "refused-classify",
                 "reason": "refused on the runner: classified contract on the replay: x"}]},
            "tripplanner": {"head_before": "tp-020", "legacy": 0, "files": [
                {"file": "tripplanner/021_e.sql", "version": "tp-021", "status": "manual",
                 "reason": "refused on the runner: something new"}]},
            "cis": {"head_before": "301", "legacy": 0, "files": []}}}
        log = self.repo / "task.log"
        log.write_text("MIGRATE something\nMIGRATE auto-result " + json.dumps(res) + "\n")
        summary, outp = self.repo / "s.md", self.repo / "o.txt"
        self.assertEqual(ap.main(["report", "--log", str(log), "--summary", str(summary), "--github-output",
                                  str(outp)]), 0)
        # M3 review: every stop reaches the manual list, runner refusals included (a row without a kind = refused).
        self.assertEqual(outp.read_text(), "applied=true\nmanual=contract:booking/291_c.sql,"
                         "refused-classify:crm/024_e.sql,refused:tripplanner/021_e.sql\nresult=found\n")
        text = summary.read_text()
        self.assertIn("| booking | bk-289 | `booking/291_c.sql` | manual | manual DB Migrate apply needed: contract (no header) |",
                      text)
        self.assertIn("| cis | 301 | | nothing pending | |", text)
        self.assertIn("| tripplanner | tp-020 | `tripplanner/021_e.sql` | manual | refused on the runner: refused", text)

    def test_missing_result_is_unknown_and_fails(self):
        # M3 review: the task exited 0 but printed no auto-result line: never green, and the probe + dump still run.
        log, outp, summary = self.repo / "task.log", self.repo / "o.txt", self.repo / "s.md"
        log.write_text("MIGRATE crashed\n")
        self.assertEqual(ap.main(["report", "--log", str(log), "--github-output", str(outp), "--summary",
                                  str(summary)]), 3)
        self.assertEqual(outp.read_text(), "applied=unknown\nmanual=\nresult=missing\n")
        self.assertIn("Result unknown", summary.read_text())
        outp.unlink()
        self.assertEqual(ap.main(["report", "--log", str(self.repo / "absent.log"), "--github-output", str(outp)]), 3)

    def test_notes_name_the_pr_marker_and_body_per_kind(self):
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            ap.main(["notes", "--manual", "contract:booking/291_c.sql,not-copied:crm/024_e.sql,"
                     "refused-bytes:cis/302_x.sql", "--run-id", "42"])
        notes = [json.loads(ln) for ln in buf.getvalue().splitlines()]
        self.assertEqual([(n["branch"], n["on_main"]) for n in notes],
                         [("bot/migration-copy/booking-291", True), ("bot/migration-copy/crm-024", False),
                          ("bot/migration-copy/cis-302", True)])
        self.assertEqual(notes[0]["marker"], "<!-- aa993-manual-apply:contract:booking/291_c.sql -->")
        self.assertTrue(notes[0]["body"].startswith(notes[0]["marker"] + "\n**Manual DB Migrate apply needed**"))
        self.assertIn("`migration=booking/291_c.sql`", notes[0]["body"])
        self.assertIn("run 42", notes[2]["body"])
        self.assertIn("not byte-identical", notes[2]["body"])
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            ap.main(["notes", "--manual", "", "--run-id", "1"])
        self.assertEqual(buf.getvalue(), "")
        with self.assertRaises(SystemExit):
            ap.parse_manual("booking/291_c.sql")                 # no kind: the old format is refused
        with self.assertRaises(SystemExit):
            ap.parse_manual("bogus:booking/291_c.sql")

    def test_pick_pr_takes_the_merged_copy_pr_not_the_newest(self):
        # M3 review: a later PR on the same bot branch (closed unmerged, or reopened) must not get the note.
        br = {"ref": "bot/migration-copy/booking-291"}
        pulls = [{"number": 90, "state": "closed", "merged_at": None, "head": br},
                 {"number": 70, "state": "closed", "merged_at": "2026-10-20T10:00:00Z", "head": br},
                 {"number": 60, "state": "closed", "merged_at": "2026-10-21T10:00:00Z",
                  "head": {"ref": "fix/hand-copy"}},
                 {"number": 95, "state": "open", "merged_at": None, "head": br}]
        self.assertEqual(ap.pick_copy_pr(pulls, "booking/291_c.sql", merged=True), 70)    # bot branch first
        self.assertEqual(ap.pick_copy_pr(pulls[2:3], "booking/291_c.sql", merged=True), 60)  # a hand copy PR
        self.assertIsNone(ap.pick_copy_pr(pulls[:1], "booking/291_c.sql", merged=True))
        self.assertEqual(ap.pick_copy_pr(pulls, "booking/291_c.sql", merged=False), 95)
        self.assertIsNone(ap.pick_copy_pr(pulls[:3], "booking/291_c.sql", merged=False))
        (self.repo / "pulls.json").write_text(json.dumps(pulls))
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            ap.main(["pick-pr", "--pulls", str(self.repo / "pulls.json"), "--path", "booking/291_c.sql", "--merged"])
        self.assertEqual(buf.getvalue(), "70\n")

    def test_explain_covers_every_runner_exit_code(self):
        for code in (2, 3, 4, 6, 7, 8, 9, 10, 14, 15, 16, 17):
            self.assertIn(code, ap.EXPLAIN)


WF = ROOT / ".github" / "workflows"


class WorkflowShapeTest(unittest.TestCase):
    """The safety properties of the two M3 workflows that a later edit must not lose (ADR 0017 d2, d5, d6, d8)."""

    @classmethod
    def setUpClass(cls):
        import yaml   # the Copy Guard job installs PyYAML for the registry test
        cls.apply_text = (WF / "migration-apply.yml").read_text()
        cls.sync_text = (WF / "migration-sync.yml").read_text()
        cls.probe_text = (WF / "db-isolation-probe.yml").read_text()
        cls.apply = yaml.safe_load(cls.apply_text)
        cls.sync = yaml.safe_load(cls.sync_text)
        cls.probe = yaml.safe_load(cls.probe_text)

    def test_apply_has_its_own_group_and_never_db_migrate(self):
        self.assertEqual(self.apply["concurrency"], {"group": "db-auto-apply", "cancel-in-progress": False})

    def test_apply_job_uses_the_narrow_environment_and_the_switch(self):
        job = self.apply["jobs"]["apply"]
        self.assertEqual(job["environment"], "dev-db-auto")
        self.assertIn("needs.plan.outputs.allowed == 'true'", job["if"])
        self.assertIn('[ "$DB_AUTO_APPLY" = "true" ]', self.apply_text)
        self.assertIn("DB_AUTO_APPLY: ${{ vars.DB_AUTO_APPLY }}", self.apply_text)
        self.assertIn('[ "$PRIVATE" = "false" ]', self.apply_text)              # d8: public repo only
        self.assertIn("required_status_checks", self.apply_text)                # d8: ruleset in force
        self.assertNotIn("environment: prod", self.apply_text)

    def test_apply_uploads_only_under_the_narrow_prefix_and_never_overrides(self):
        self.assertIn('PREFIX="db-auto-apply/', self.apply_text)
        self.assertNotIn("db-migrate/", self.apply_text)
        self.assertNotIn("MIGRATION_IDLE_OVERRIDE", self.apply_text)
        self.assertNotIn("MIGRATION_SNAPSHOT", self.apply_text)
        self.assertIn('{name: "MIGRATION_MODE", value: "apply-pending"}', self.apply_text)

    def test_probe_inherits_secrets_so_its_environment_secret_resolves(self):
        # S258: live runs 40916210939 / 40922869610 showed the callee's environment secret empty without inheritance
        # (the M3 review assumed otherwise); the callee still names no secrets and its environment picks the role.
        self.assertEqual(self.apply["jobs"]["probe"].get("secrets"), "inherit")
        self.assertNotIn("secrets", self.probe[True]["workflow_call"])
        self.assertEqual(self.probe["jobs"]["probe"]["environment"], "${{ inputs.environment || 'prod' }}")

    def test_missing_result_fails_and_still_probes_and_dumps(self):
        self.assertIn('echo "applied=unknown" >> "$GITHUB_OUTPUT"', self.apply_text)
        self.assertIn('if [ "$REPORT" != "0" ]; then', self.apply_text)
        for job in ("probe", "dump"):
            self.assertIn("needs.apply.outputs.applied == 'unknown'", self.apply["jobs"][job]["if"])

    def test_summary_notes_the_merged_copy_pr(self):
        text = yaml_dump = str(self.apply["jobs"]["summary"])
        self.assertIn("pick-pr --pulls pulls.json --path \"$f\" --merged", text)
        self.assertIn("--diff-filter=A", text)
        self.assertNotIn("per_page=1&", yaml_dump)
        self.assertEqual(self.apply["jobs"]["summary"]["steps"][0]["with"], {"fetch-depth": 0})

    def test_probe_is_blocking_with_the_same_role(self):
        probe = self.apply["jobs"]["probe"]
        self.assertEqual(probe["uses"], "./.github/workflows/db-isolation-probe.yml")
        self.assertEqual(probe["with"]["environment"], "dev-db-auto")
        self.assertTrue(probe["with"]["s3_root"].startswith("db-auto-apply/"))
        self.assertNotIn("continue-on-error", str(probe))
        self.assertIn("workflow_call", self.probe[True])                        # PyYAML reads `on:` as True
        self.assertIn("environment: ${{ inputs.environment || 'prod' }}", self.probe_text)
        self.assertIn('PREFIX="$S3_ROOT/', self.probe_text)

    def test_dump_is_dispatched_with_after_apply(self):
        self.assertIn("gh workflow run db-schema-dump.yml", self.apply_text)
        self.assertIn("-f after_apply=true", self.apply_text)

    def test_apply_triggers(self):
        on = self.apply[True]
        self.assertEqual(sorted(on["push"]["paths"]), sorted(f"db/migrations/{o}/**" for o in rm.AUTO_OWNERS))
        self.assertIn("schedule", on)
        self.assertIn("workflow_dispatch", on)

    def test_sync_pulls_and_mints_a_narrow_token_only(self):
        self.assertEqual(self.sync[True]["schedule"], [{"cron": "4-59/10 * * * *"}])
        self.assertNotIn("repository_dispatch", self.sync[True])
        steps = {s.get("name", ""): s for s in self.sync["jobs"]["sync"]["steps"]}
        mint = next(s for n, s in steps.items() if n.startswith("Mint"))
        self.assertEqual(mint["with"]["repositories"], "AA-CIS-Infra")
        perms = {k: v for k, v in mint["with"].items() if k.startswith("permission-")}
        self.assertEqual(perms, {"permission-contents": "write", "permission-pull-requests": "write"})
        self.assertTrue(self.sync["jobs"]["sync"]["if"].startswith("github.ref == 'refs/heads/main' && ("))
        self.assertIn("--match-head-commit", self.sync_text)
        self.assertIn("db/migration_sync.py merge-check", self.sync_text)
        # Per owner in ascending number order, and the pass sees what it merged (merge-check's gap rule).
        self.assertIn('"\\(.head.ref) \\(.number)"\' \\\n            | LC_ALL=C sort', self.sync_text)
        self.assertIn("--repo-root .", self.sync_text)
        self.assertIn('cp head.sql "$F"', self.sync_text)
        # M3 review: the close path closes only the ci-bot App's own PRs (exact login), not any Bot.
        self.assertNotIn(".user.type", self.sync_text)
        self.assertIn('[ "$(jq -r .user.login pr.json)" = "$BOT_LOGIN" ]', self.sync_text)
        self.assertIn("BOT_LOGIN=$(python3 db/migration_sync.py bot-login)", self.sync_text)
        self.assertIn("steps.gate.outputs.merge == 'true'", self.sync_text)
        self.assertEqual(self.sync["permissions"], {"contents": "read"})

    def test_sync_wakes_on_events_not_only_the_cron(self):
        # S258: GitHub's */10 cron is best effort. An owner's wake-up comment and the end of a copy PR's slow checks
        # start the sync too; the cron stays as the backstop.
        on, job = self.sync[True], self.sync["jobs"]["sync"]
        self.assertEqual(on["issue_comment"], {"types": ["created"]})
        self.assertEqual(on["workflow_run"]["types"], ["completed"])
        self.assertEqual(on["workflow_run"]["branches"], ["bot/migration-copy/**"])
        # Each name is the `name:` of a workflow that reports a required check of the ruleset (a rename would
        # silently drop the trigger).
        import yaml
        names = {yaml.safe_load((WF / f).read_text())["name"] for f in ("terraform-plan.yml", "migration-copy-guard.yml")}
        self.assertEqual(set(on["workflow_run"]["workflows"]), names)
        # Only ci-bot's comment on the labelled wake-up issue counts; never a PR comment, never anyone else.
        cond = " ".join(job["if"].split())
        self.assertIn("github.event.comment.user.login == 'aa-ecosys-ci-bot[bot]'", cond)
        self.assertIn("contains(github.event.issue.labels.*.name, 'migration-sync-wake')", cond)
        self.assertIn("!github.event.issue.pull_request", cond)
        self.assertIn("github.event.workflow_run.head_repository.full_name == github.repository", cond)
        self.assertIn("startsWith(github.event.workflow_run.head_branch, 'bot/migration-copy/')", cond)
        # The comment is a doorbell: its body is never read.
        self.assertNotIn("comment.body", self.sync_text)
        # Job-level concurrency: a skipped run (someone else's comment) never replaces a pending real run.
        self.assertNotIn("concurrency", self.sync)
        self.assertEqual(job["concurrency"], {"group": "migration-sync", "cancel-in-progress": False})
        # The doorbell issue is ensured before any step that can fail (clone, plan, mint, merge).
        names = [s.get("name", "") for s in job["steps"]]
        wake = names.index("Wake-up issue (find or create)")
        self.assertLess(wake, next(i for i, n in enumerate(names) if n.startswith("Clone the owner repos")))


if __name__ == "__main__":
    unittest.main()
