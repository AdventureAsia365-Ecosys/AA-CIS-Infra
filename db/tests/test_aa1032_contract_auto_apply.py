"""AA-1032 (root ADR 0017a): on Dev, migration-apply also applies CONTRACT files when every job table is idle.

The task half (run_migration apply-pending, contract mode) runs against the fakes of test_run_migration, the runner
half (db/apply_pending.py) on temp folders, the copy-PR half (db/migration_sync.py merge-check) on JSON fixtures.
No database, no AWS, no network:
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
import migration_sync as ms  # noqa: E402
import run_migration as rm  # noqa: E402
from test_aa993_apply_pending import LockConn, contract, entry, expand, registered  # noqa: E402
from test_aa993_expand import tx  # noqa: E402
from test_aa993_migration_sync import RULESET, Repo, green, pr  # noqa: E402
from test_run_migration import FakeConn, PgError, job  # noqa: E402


def destructive(number, owner="booking"):
    key = f"{rm.AUTO_KEY_PREFIX[owner]}{number:03d}"
    return tx("DROP TABLE booking.aa1032_old;", version=key, header="-- migrate: destructive\n")


def bundle(files, contract_mode=True, environment="dev", **override):
    data = {"kind": rm.BUNDLE_KIND, "format": 1, "contract": contract_mode, "environment": environment,
            "files": [{"path": f["path"], "sql": f["sql"], "verdict": f.get("verdict", "ok"),
                       "verdict_kind": f.get("verdict_kind", "ok"),
                       "sha256": hashlib.sha256(f["sql"].encode()).hexdigest()} for f in files]}
    data.update(override)
    return json.dumps(data).encode()


def steps(files, keys, owner="booking", contract_mode=True):
    return [(s.action, s.path, s.kind or s.cls) for s in
            rm.plan_pending(files, keys, contract=contract_mode)[owner]["steps"]]


class ContractPlanTest(unittest.TestCase):
    def test_contract_file_is_an_apply_step_in_contract_mode(self):
        files = [entry("booking/290_c.sql", contract(290)), entry("booking/291_e.sql", expand(291))]
        self.assertEqual(steps(files, registered("booking", 289)),
                         [("apply", "booking/290_c.sql", "contract"), ("apply", "booking/291_e.sql", "expand")])

    def test_contract_mode_off_keeps_the_old_stop(self):
        files = [entry("booking/290_c.sql", contract(290)), entry("booking/291_e.sql", expand(291))]
        self.assertEqual(steps(files, registered("booking", 289), contract_mode=False),
                         [("stop", "booking/290_c.sql", rm.STOP_CONTRACT)])
        self.assertEqual(rm.plan_pending(files, registered("booking", 289))["booking"]["steps"][0].kind,
                         rm.STOP_CONTRACT)                       # the default is off

    def test_destructive_file_always_stops(self):
        files = [entry("booking/290_d.sql", destructive(290)), entry("booking/291_e.sql", expand(291))]
        for mode in (True, False):
            self.assertEqual(steps(files, registered("booking", 289), contract_mode=mode),
                             [("stop", "booking/290_d.sql", rm.STOP_DESTRUCTIVE)])
        self.assertIn(rm.STOP_DESTRUCTIVE, rm.STOP_KINDS)
        self.assertIn(rm.STOP_DESTRUCTIVE, ap.STOP_NOTES)

    def test_contract_file_needs_the_runner_verdict_and_a_clean_lint(self):
        reg = registered("booking", 289)
        refused = dict(entry("booking/290_c.sql", contract(290), verdict="did not apply on the replay"),
                       verdict_kind=rm.STOP_REFUSED_CLASSIFY)
        self.assertEqual(steps([refused], reg), [("stop", "booking/290_c.sql", rm.STOP_REFUSED_CLASSIFY)])
        bad = tx("DROP TABLE booking.aa1032_old;", version="bk-290", header="")     # DROP needs the header
        plan = rm.plan_pending([entry("booking/290_c.sql", bad)], reg, contract=True)["booking"]["steps"]
        self.assertEqual((plan[0].action, plan[0].kind), ("stop", rm.STOP_LINT))
        self.assertIn("contract file but 1 lint error", plan[0].reason)

    def test_order_gap_and_out_of_order_rules_still_hold_for_contract_files(self):
        reg = registered("booking", 289)
        self.assertEqual(steps([entry("booking/291_c.sql", contract(291))], reg),
                         [("stop", "booking/291_c.sql", rm.STOP_GAP)])
        self.assertEqual(steps([entry("booking/290_c.sql", contract(290))], reg | {"bk-291"}),
                         [("stop", "booking/290_c.sql", rm.STOP_OUT_OF_ORDER)])
        files = [rm.not_copied_entry("booking/290_x.sql"), entry("booking/291_c.sql", contract(291))]
        self.assertEqual(steps(files, reg), [("stop", "booking/290_x.sql", rm.STOP_NOT_COPIED)])


class ContractTaskTest(unittest.TestCase):
    def run_pending(self, raw, keys, file_conns=None):
        self.lock = LockConn(keys)
        self.file_conns = list(file_conns or [])
        self.used, self.sleeps, self.settings = [], [], []
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": hashlib.sha256(raw).hexdigest(),
               "MIGRATION_MODE": "apply-pending", "MIGRATION_FILE": "", "MIGRATION_VERSION": "",
               "MIGRATION_IDLE_OVERRIDE": "someone's reason", "MIGRATION_SNAPSHOT": "snap-x",
               "DATABASE_URL": "postgresql://x"}
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

    def rows(self, owner="booking"):
        return ap.parse_result(self.log)["owners"][owner]["files"]

    def test_idle_contract_file_is_applied_with_the_contract_settings(self):
        files = [entry("booking/290_c.sql", contract(290)), entry("booking/291_e.sql", expand(291))]
        code = self.run_pending(bundle(files), registered("booking", 289))
        self.assertEqual(code, 0, self.log)
        self.assertIn("contract files ON (dev", self.log)
        self.assertIn("ADD CONSTRAINT c CHECK", "\n".join(self.used[0].executed))
        self.assertEqual(self.settings[1]["statement_timeout"], rm.DEFAULT_SETTINGS["statement_timeout"])
        self.assertEqual(self.settings[2]["statement_timeout"], "30s")        # the expand file after it
        self.assertGreaterEqual(self.used[0].checks, 1)                        # the idle check ran
        self.assertNotIn("OVERRIDDEN", self.log)                               # the override never reaches a file
        self.assertEqual(self.sleeps, [])                                      # idle at once: no wait
        self.assertEqual([(r["file"], r["status"], r["class"]) for r in self.rows()],
                         [("booking/290_c.sql", "applied", "contract"), ("booking/291_e.sql", "applied", "expand")])
        self.assertTrue(ap.parse_result(self.log)["contract"])

    def test_busy_job_table_defers_the_contract_file_and_its_owner(self):
        busy = FakeConn(states=[({"booking": [job("booking_noop", "running")], "shared": []}, 0)])
        files = [entry("booking/290_c.sql", contract(290)), entry("booking/291_e.sql", expand(291)),
                 entry("crm/024_e.sql", expand(24, "crm"))]
        code = self.run_pending(bundle(files), registered("booking", 289) | registered("crm", 23), [busy])
        self.assertEqual(code, 0, self.log)                                    # a deferral is not a failure
        self.assertEqual(self.sleeps, [rm.IDLE_WAIT_S] * rm.IDLE_WAITS)        # DB Migrate's wait, then give up
        self.assertEqual(busy.ran, False)
        self.assertNotIn("OVERRIDDEN", self.log)
        row = self.rows()[0]
        self.assertEqual((row["status"], row["exit"], row["class"]), ("deferred", 7, "contract"))
        self.assertIn("a job table is busy or a rerun wave is open", self.log)
        self.assertEqual(len(self.rows()), 1)                                  # 291 waits behind it
        self.assertEqual(self.rows("crm")[0]["status"], "applied")            # other owners still run

    def test_open_wave_defers_the_contract_file(self):
        wave = FakeConn(states=[({"booking": [], "shared": []}, 1)])
        code = self.run_pending(bundle([entry("booking/290_c.sql", contract(290))]), registered("booking", 289),
                                [wave])
        self.assertEqual(code, 0, self.log)
        self.assertEqual(self.rows()[0]["status"], "deferred")

    def test_destructive_file_is_never_run(self):
        code = self.run_pending(bundle([entry("booking/290_d.sql", destructive(290))]), registered("booking", 289))
        self.assertEqual((code, self.used), (0, []))
        row = self.rows()[0]
        self.assertEqual((row["status"], row["kind"]), ("manual", rm.STOP_DESTRUCTIVE))

    def test_a_failed_contract_file_stops_its_owner(self):
        broken = FakeConn(fail=PgError("23514", "check constraint is violated by some row"))
        files = [entry("booking/290_c.sql", contract(290)), entry("booking/291_e.sql", expand(291))]
        code = self.run_pending(bundle(files), registered("booking", 289), [broken])
        self.assertEqual(code, 6)
        self.assertEqual([(r["file"], r["status"]) for r in self.rows()], [("booking/290_c.sql", "failed")])

    def test_contract_bundle_outside_dev_is_refused(self):
        files = [entry("booking/290_c.sql", contract(290))]
        for raw in (bundle(files, environment="prod"), bundle(files, environment=""),
                    bundle(files, contract_mode="yes"), bundle(files, environment=["dev"])):
            self.assertEqual(self.run_pending(raw, registered("booking", 289)), 10)
            self.assertEqual(self.used, [])
        self.assertIn("contract auto-apply exists only in dev", self.run_and_log(bundle(files, environment="prod")))

    def run_and_log(self, raw):
        self.run_pending(raw, registered("booking", 289))
        return self.log

    def test_bundle_without_contract_mode_keeps_contract_files_manual(self):
        files = [entry("booking/290_c.sql", contract(290))]
        for raw in (bundle(files, contract_mode=False, environment="prod"),
                    json.dumps({k: v for k, v in json.loads(bundle(files)).items()
                                if k not in ("contract", "environment")}).encode()):
            self.assertEqual(self.run_pending(raw, registered("booking", 289)), 0)
            self.assertEqual(self.used, [])
            self.assertEqual((self.rows()[0]["status"], self.rows()[0]["kind"]), ("manual", rm.STOP_CONTRACT))
            self.assertIn("contract files off", self.log)


class ContractRunnerSideTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.repo, self.owner = base / "infra", base / "owner"
        (self.repo / "db" / "migrations" / "booking").mkdir(parents=True)
        self.owner.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, name, sql):
        (self.repo / "db" / "migrations" / "booking" / name).write_text(sql)
        (self.owner / name).write_text(sql)

    def run_plan(self, keys, classify, extra=()):
        (self.repo / "keys.txt").write_text("\n".join(sorted(keys)))
        (self.repo / "classify.json").write_text(json.dumps(classify))
        (self.repo / "summary.md").write_text("")
        args = ["plan", "--repo-root", str(self.repo), "--source", f"booking={self.owner}",
                "--registered", str(self.repo / "keys.txt"), "--bundle", str(self.repo / "bundle.json"),
                "--classify", str(self.repo / "classify.json"), "--summary", str(self.repo / "summary.md"),
                "--github-output", str(self.repo / "out.txt"), *extra]
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            self.assertEqual(ap.main(args), 0)
        self.stdout = buf.getvalue()
        out = dict(ln.split("=", 1) for ln in (self.repo / "out.txt").read_text().splitlines())
        (self.repo / "out.txt").unlink()
        return out, json.loads((self.repo / "bundle.json").read_text())

    @staticmethod
    def replay(file, applied="ok", lint=(), header="none"):
        return {"file": file, "class": "contract", "header": header, "lint_errors": list(lint), "findings": [],
                "error": "", "applied": applied}

    def test_contract_evidence_is_a_clean_replay(self):
        verdicts = ap.classify_verdicts({"files": [
            self.replay("booking/290_c.sql"),
            self.replay("booking/291_c.sql", applied="failed: UndefinedTableError 42P01 relation does not exist"),
            self.replay("booking/292_c.sql", lint=["line 3: DROP TABLE needs the destructive header"]),
            self.replay("booking/293_x.sql", header="expand"),             # an expand file classified contract
            dict(self.replay("booking/294_c.sql"), applied="here")]})
        self.assertEqual(verdicts["booking/290_c.sql"], ("ok", "ok"))
        self.assertEqual(verdicts["booking/294_c.sql"], ("ok", "ok"))
        for f in ("booking/291_c.sql", "booking/292_c.sql", "booking/293_x.sql"):
            self.assertEqual(verdicts[f][0], rm.STOP_REFUSED_CLASSIFY, f)
        self.assertIn("did not apply cleanly on the replay", verdicts["booking/291_c.sql"][1])

    def test_plan_in_contract_mode_on_dev(self):
        self.put("290_c.sql", contract(290))
        out, b = self.run_plan(registered("booking", 289), {"files": [self.replay("booking/290_c.sql")]},
                               ["--environment", "dev", "--contract"])
        self.assertEqual((out["apply"], out["needs_classify"], out["manual"]), ("true", "true", ""))
        self.assertEqual((b["contract"], b["environment"]), (True, "dev"))
        self.assertIn("contract files applied when every job table is idle",
                      (self.repo / "summary.md").read_text())
        # The task accepts what the runner wrote.
        self.assertEqual(rm.read_bundle_contract(json.dumps(b).encode()), (True, "dev"))

    def test_plan_outside_dev_or_without_the_switch_keeps_contract_manual(self):
        self.put("290_c.sql", contract(290))
        for extra in (["--environment", "prod", "--contract"], ["--environment", "dev"], []):
            out, b = self.run_plan(registered("booking", 289), {"files": [self.replay("booking/290_c.sql")]}, extra)
            self.assertEqual((out["apply"], out["manual"]), ("false", "contract:booking/290_c.sql"), extra)
            self.assertFalse(b["contract"])
        self.assertIn("::warning::--contract ignored: environment 'prod'",
                      self.run_plan(registered("booking", 289), {"files": []},
                                    ["--environment", "prod", "--contract"]) and self.stdout)

    def test_plan_destructive_stays_manual_in_contract_mode(self):
        self.put("290_d.sql", destructive(290))
        out, _ = self.run_plan(registered("booking", 289), {"files": [self.replay("booking/290_d.sql")]},
                               ["--environment", "dev", "--contract"])
        self.assertEqual((out["apply"], out["manual"]), ("false", "destructive:booking/290_d.sql"))
        note = ap.note(rm.STOP_DESTRUCTIVE, "booking/290_d.sql", "1")
        self.assertIn("never applies it", note["body"])
        self.assertTrue(note["on_main"])

    def test_report_shows_the_class_of_each_applied_file(self):
        result = {"bundle": "abc", "exit": 0, "contract": True, "owners": {"booking": {"head_before": "bk-289",
                  "files": [{"file": "booking/290_c.sql", "status": "applied", "class": "contract"},
                            {"file": "booking/291_c.sql", "status": "deferred", "exit": 7, "class": "contract",
                             "reason": "a job table is busy or a rerun wave is open"}]}}}
        text = "\n".join(ap.report_lines(result))
        self.assertIn("contract files on (Dev)", text)
        self.assertIn("| `booking/290_c.sql` | applied | contract file |", text)
        self.assertIn("contract file: a job table is busy", text)


class LatestCheckRunTest(unittest.TestCase):
    """migration-sync merge-check judges the LATEST run of each check (S258 #510, S263 #589: a cancelled duplicate
    gitleaks run made ci-bot refuse a green copy PR, and contract copies were merged by hand)."""

    def setUp(self):
        self.r = Repo()
        self.sql = contract(34)
        self.r.main("034_b.sql", self.sql)
        self.files = [{"filename": "db/migrations/booking/034_b.sql", "status": "added"}]
        self.req = ms.required_contexts(RULESET)

    def tearDown(self):
        self.r.tmp.cleanup()

    def check(self, checks):
        return ms.merge_check(pr(), self.files, checks, self.sql.encode(), {"booking": self.r.owner}, self.req,
                              self.r.infra)

    @staticmethod
    def runs(*extra):
        base = [dict(c, id=100 + i, app={"id": 15368}) for i, c in enumerate(green())]
        return base + [dict(e, app=e.get("app", {"id": 15368})) for e in extra]

    def test_cancelled_duplicate_superseded_by_a_green_run_merges(self):
        gitleaks = next(c for c in green() if c["name"] == "gitleaks")
        cancelled = dict(gitleaks, id=50, conclusion="cancelled")             # the older run of the pair
        code, why = self.check(self.runs(cancelled))
        self.assertEqual(code, 0, why)

    def test_a_newer_failure_still_refuses(self):
        gitleaks = next(c for c in green() if c["name"] == "gitleaks")
        code, why = self.check(self.runs(dict(gitleaks, id=900, conclusion="failure")))
        self.assertEqual(code, 1)
        self.assertIn("gitleaks", why)

    def test_a_newer_run_still_in_progress_waits(self):
        gitleaks = next(c for c in green() if c["name"] == "gitleaks")
        code, _ = self.check(self.runs(dict(gitleaks, id=900, status="in_progress", conclusion=None)))
        self.assertEqual(code, 2)

    def test_same_name_from_another_app_is_judged_on_its_own(self):
        other = {"name": "gitleaks", "status": "completed", "conclusion": "failure", "id": 10, "app": {"id": 7}}
        self.assertEqual(self.check(self.runs(other))[0], 1)

    def test_contract_copy_pr_body_says_dev_applies_it(self):
        self.r.copy("033_a.sql")
        copies = self.r.plan()["copies"]
        self.assertEqual(copies[0]["class"], "contract")
        self.assertIn("applies it after this merge once every job table is idle", copies[0]["body"])
        self.assertNotIn("manual DB Migrate apply needed", copies[0]["body"])


WF = ROOT / ".github" / "workflows"


class ContractWorkflowShapeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import yaml
        cls.text = (WF / "migration-apply.yml").read_text()
        cls.wf = yaml.safe_load(cls.text)

    def test_contract_mode_is_dev_only_with_a_kill_switch(self):
        env = self.wf["jobs"]["plan"]["env"]
        self.assertEqual(env["TARGET_ENV"], "dev")
        self.assertEqual(env["DB_AUTO_APPLY_CONTRACT"], "${{ vars.DB_AUTO_APPLY_CONTRACT }}")
        self.assertIn('elif [ "$DB_AUTO_APPLY_CONTRACT" = "false" ]; then', self.text)
        # A list-only run (auto-apply not allowed) keeps contract files manual and noted.
        gate = next(st["run"] for st in self.wf["jobs"]["plan"]["steps"] if st.get("id") == "gate")
        self.assertLess(gate.index('if [ -n "$why" ]; then\n  echo "contract=false"'),
                        gate.index('elif [ "$TARGET_ENV" = "dev" ]; then'))
        self.assertIn('elif [ "$TARGET_ENV" = "dev" ]; then', self.text)
        self.assertEqual(self.text.count('[ "$CONTRACT" = "true" ] && ARGS+=(--contract)'), 2)
        self.assertEqual(self.text.count('--environment "$TARGET_ENV"'), 2)

    def test_the_task_still_gets_no_override_and_no_snapshot(self):
        self.assertNotIn("MIGRATION_IDLE_OVERRIDE", self.text)
        self.assertNotIn("MIGRATION_SNAPSHOT", self.text)
        self.assertEqual(self.wf["jobs"]["apply"]["environment"], "dev-db-auto")


if __name__ == "__main__":
    unittest.main()
