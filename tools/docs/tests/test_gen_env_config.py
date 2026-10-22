"""Tests for tools/docs/gen_env_config.py (AA-894 scope 5). Run from the repo root:

    python3 -m unittest discover -s tools/docs/tests -v

Offline: fake task definitions, Lambda configurations, Vercel API and CLI output with planted values,
fake boto3 clients; no AWS, no Vercel. The main guarantee under test: a value never reaches the
names-only model or the page.
"""
from __future__ import annotations

import datetime as dt
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import gen_docs as gd  # noqa: E402
import gen_env_config as ec  # noqa: E402

ACCT = "111122223333"  # fake
REGION = "us-west-1"
SECRET = "SUPERSECRETVALUE"
SM = f"arn:aws:secretsmanager:{REGION}:{ACCT}:secret:"


def _task_def(family: str, container: str = "api") -> dict:
    return {
        "family": family,
        "taskDefinitionArn": f"arn:aws:ecs:{REGION}:{ACCT}:task-definition/{family}:7",
        "containerDefinitions": [
            {
                "name": container,
                "image": f"{ACCT}.dkr.ecr.{REGION}.amazonaws.com/{family}:dev-abc",
                "environment": [
                    {"name": "APP_ENV", "value": f"dev-{SECRET}"},
                    {"name": "LEGACY_API_KEY", "value": SECRET},
                    {"name": "DB_SECRET_ARN", "value": f"{SM}db-{SECRET}"},
                ],
                "secrets": [
                    {"name": "DATABASE_URL", "valueFrom": f"{SM}aa-cis/dev/rds-cis-app-VwwqaP"},
                    {"name": "DFS_LOGIN", "valueFrom": f"{SM}aa-cis/dev/dataforseo-tGjzh7:login::"},
                    {"name": "FROM_SSM", "valueFrom": f"arn:aws:ssm:{REGION}:{ACCT}:parameter/aa/dev/flag"},
                ],
            }
        ],
    }


def _lambda_cfg(name: str) -> dict:
    return {
        "FunctionName": name,
        "FunctionArn": f"arn:aws:lambda:{REGION}:{ACCT}:function:{name}",
        "Environment": {"Variables": {"PLACES_SOURCE": SECRET, "TRIPPLANNER_DATABASE_URL_ARN": f"{SM}x-{SECRET}", "OLD_TOKEN": SECRET}},
    }


VERCEL_API_ENVS = [
    {"key": "NEXT_PUBLIC_API_URL", "type": "plain", "value": f"https://{SECRET}.example", "target": ["production", "preview"]},
    {"key": "SENTRY_AUTH_TOKEN", "type": "encrypted", "value": SECRET, "target": ["production"]},
    {"key": "COGNITO_CLIENT_SECRET", "type": "sensitive", "value": SECRET, "target": ["preview"], "gitBranch": "feat-x"},
]

VERCEL_CLI_TEXT = f"""Vercel CLI 60.0.1 (Node.js 22.22.3)
Retrieving project…
> Environment Variables found for team/aa-booking-admin [663ms]

 name                                   value               type        environments                       created
 COGNITO_BOOKING_STAFF_CLIENT_SECRET    Hidden              Secret      Production                         3d ago
 BOOKING_API_URL                        https://{SECRET}…   Config      Production, Preview, Development   6d ago
 ADMIN2_PASSWORD                        {SECRET}  x  y      Config      Preview (my-branch)                170d ago
"""


# ---------------------------------------------------------------------- fake boto3


class _Pager:
    def __init__(self, pages):
        self.pages = pages

    def paginate(self, **_):
        return iter(self.pages)


class FakeEcs:
    def __init__(self, tds: dict[str, dict]):
        self.tds = tds

    def get_paginator(self, name):
        assert name == "list_services"
        return _Pager([{"serviceArns": [f"arn:aws:ecs:{REGION}:{ACCT}:service/c/{n}" for n in self.tds]}])

    def describe_services(self, cluster, services):
        out = []
        for arn in services:
            n = arn.rsplit("/", 1)[-1]
            td = f"arn:aws:ecs:{REGION}:{ACCT}:task-definition/{n}:7"
            out.append({"serviceName": n, "taskDefinition": td.replace(":7", ":6"),
                        "deployments": [{"status": "PRIMARY", "taskDefinition": td}, {"status": "ACTIVE", "taskDefinition": td.replace(":7", ":6")}]})
        return {"services": out}

    def describe_task_definition(self, taskDefinition):
        assert taskDefinition.endswith(":7"), "must read the PRIMARY deployment's revision"
        n = taskDefinition.rsplit("/", 1)[-1].split(":")[0]
        return {"taskDefinition": self.tds[n]}


class FakeLambda:
    def __init__(self, names):
        self.names = names

    def get_paginator(self, name):
        assert name == "list_functions"
        return _Pager([{"Functions": [_lambda_cfg(n) for n in self.names]}])


class FakeSm:
    def __init__(self, fail=False):
        self.fail = fail

    def get_paginator(self, name):
        assert name == "list_secrets"
        if self.fail:
            raise PermissionError("AccessDenied")
        return _Pager([{"SecretList": [{"ARN": f"{SM}aa-cis/dev/rds-cis-app-VwwqaP", "Name": "aa-cis/dev/rds-cis-app"}]}])


def _aws_model() -> dict:
    ecs = FakeEcs({n: _task_def(n, "worker" if "worker" in n else "api") for n in ec.REQUIRED_ECS})
    names, warn = ec.secret_names_by_arn(FakeSm())
    assert warn is None
    return {
        "format": 1,
        "cluster": "aa-cis-dev-cluster",
        "ecs": ec.collect_ecs(ecs, "aa-cis-dev-cluster", names),
        "lambda": ec.collect_lambda(FakeLambda(list(ec.REQUIRED_LAMBDA) + ["aa-identity-dev-pre-token"])),
        "warnings": [],
    }


def _vercel_model() -> dict:
    projects = {p: ec.extract_vercel_api(VERCEL_API_ENVS) for p in ec.REQUIRED_VERCEL if p != "aa-booking-admin"}
    projects["aa-booking-admin"] = ec.parse_vercel_cli(VERCEL_CLI_TEXT)
    projects["aa-cis-portal"] = []
    return {"format": 1, "source": "snapshot", "captured": "2026-10-22", "projects": projects}


class NoValueLeaks(unittest.TestCase):
    """Planted values (SUPERSECRETVALUE, the fake account) reach neither the model nor the page."""

    def test_model_and_page_carry_no_value(self):
        aws, vercel = _aws_model(), _vercel_model()
        page = ec.render_page(aws, vercel, date="2026-10-22", sha="abc", source="test")
        for blob in (json.dumps(aws), json.dumps(vercel), page):
            self.assertNotIn(SECRET, blob)
            self.assertNotIn(ACCT, blob)
            self.assertNotIn("arn:aws", blob)
            self.assertNotIn("VwwqaP", blob)  # the random ARN suffix is dropped
        for name in ("APP_ENV", "LEGACY_API_KEY", "DATABASE_URL", "PLACES_SOURCE", "SENTRY_AUTH_TOKEN", "BOOKING_API_URL"):
            self.assertIn(f"`{name}`", page)

    def test_extract_task_def_keeps_names_only(self):
        containers = ec.extract_task_def(_task_def("aa-cis-dev-api"))
        self.assertEqual(len(containers), 1)
        for v in containers[0]["vars"]:
            self.assertNotIn("value", v)
            self.assertNotIn("valueFrom", v)
        self.assertNotIn(SECRET, json.dumps(containers))

    def test_cli_value_column_dropped_even_with_spaces(self):
        rows = ec.parse_vercel_cli(VERCEL_CLI_TEXT)
        self.assertEqual([r["key"] for r in rows], ["ADMIN2_PASSWORD", "BOOKING_API_URL", "COGNITO_BOOKING_STAFF_CLIENT_SECRET"])
        self.assertNotIn(SECRET, json.dumps(rows))
        by = {r["key"]: r for r in rows}
        self.assertEqual(by["COGNITO_BOOKING_STAFF_CLIENT_SECRET"]["kind"], "sensitive")
        self.assertEqual(by["BOOKING_API_URL"]["target"], ["development", "preview", "production"])
        self.assertEqual(by["ADMIN2_PASSWORD"], {"key": "ADMIN2_PASSWORD", "kind": "readable", "target": ["preview"], "branch": "my-branch"})

    def test_cli_unknown_type_fails_without_echoing_the_line(self):
        text = f" WEIRD_VAR    {SECRET}    Mystery    Production    1d ago\n"
        with self.assertRaises(ec.InputError) as cm:
            ec.parse_vercel_cli(text)
        self.assertNotIn(SECRET, str(cm.exception))


class SecretRefs(unittest.TestCase):
    def test_full_arn_suffix_and_json_key(self):
        self.assertEqual(ec.secret_ref(f"{SM}aa-cis/dev/dataforseo-tGjzh7:login::"),
                         {"store": "secretsmanager", "secret": "aa-cis/dev/dataforseo", "key": "login"})

    def test_listsecrets_name_wins_over_suffix_rule(self):
        # A partial ARN whose name ends in -<6 chars> would be cut by the suffix rule; the map knows better.
        arn = f"{SM}openai-apikey"
        self.assertEqual(ec.secret_ref(arn, {arn: "openai-apikey"})["secret"], "openai-apikey")
        self.assertEqual(ec.secret_ref(arn)["secret"], "openai")  # documented limit of the fallback

    def test_ssm_and_bare_names(self):
        self.assertEqual(ec.secret_ref(f"arn:aws:ssm:{REGION}:{ACCT}:parameter/aa/dev/flag")["secret"], "/aa/dev/flag")
        self.assertEqual(ec.secret_ref("/aa/dev/flag"), {"store": "ssm", "secret": "/aa/dev/flag", "key": None})

    def test_listsecrets_denied_falls_back_with_warning(self):
        names, warn = ec.secret_names_by_arn(FakeSm(fail=True))
        self.assertEqual(names, {})
        self.assertIn("ListSecrets", warn)


class Render(unittest.TestCase):
    def setUp(self):
        self.aws, self.vercel = _aws_model(), _vercel_model()
        self.page = ec.render_page(self.aws, self.vercel, date="2026-10-22", sha="abc", source="test run")

    def test_front_matter_and_header(self):
        self.assertTrue(self.page.startswith("---\nid: APP-03\n"))
        self.assertIn("generated: true", self.page)
        self.assertIn("Names only, never a value", self.page)
        self.assertIn("docs-fingerprint:", self.page)
        self.assertIn("(../security/secrets-register.md)", self.page)

    def test_sections_per_app_and_runtime(self):
        for h in ("## CIS", "## Booking", "## TripPlanner", "## Identity (Cognito triggers)",
                  "### ECS service `aa-cis-dev-api`", "### ECS service `aa-cis-dev-worker`",
                  "### ECS service `aa-booking-dev-api`", "### Lambda `aa-tripplanner-dev-browse`",
                  "### Vercel project `aa-cis-portal`", "### Vercel project `aa-booking-admin`"):
            self.assertIn(h, self.page)
        self.assertLess(self.page.index("## CIS"), self.page.index("## Booking"))

    def test_secret_rows_and_notes(self):
        self.assertIn("| `DATABASE_URL` | secret | `aa-cis/dev/rds-cis-app` |", self.page)
        self.assertIn("`aa-cis/dev/dataforseo` (JSON key `login`)", self.page)
        self.assertIn("`SSM /aa/dev/flag`", self.page)
        self.assertIn("| `LEGACY_API_KEY` | plain |  | secret-shaped name in plain config: check |", self.page)
        self.assertIn("| `TRIPPLANNER_DATABASE_URL_ARN` | plain | an ARN (read at run time) |", self.page)
        self.assertIn("| `SENTRY_AUTH_TOKEN` | readable | production | secret-shaped name in a readable variable", self.page)
        self.assertIn("| `NEXT_PUBLIC_API_URL` | readable | preview, production |  |", self.page)
        self.assertIn("preview (branch `feat-x`)", self.page)

    def test_no_volatile_content_in_body(self):
        body = ec.render_body(self.aws, self.vercel)
        self.assertNotIn(":7", body)  # no task-definition revision
        self.assertNotIn("dev-abc", body)  # no image tag
        again = ec.render_page(self.aws, self.vercel, date="2026-11-30", sha="def", source="other")
        fp = gd.FINGERPRINT_RE.search
        self.assertEqual(fp(self.page).group(1), fp(again).group(1))

    def test_deterministic(self):
        self.assertEqual(self.page, ec.render_page(_aws_model(), _vercel_model(), date="2026-10-22", sha="abc", source="test run"))

    def test_api_source_line(self):
        v = dict(self.vercel, source="api")
        self.assertIn("read live from the Vercel REST API", ec.render_body(self.aws, v))
        self.assertIn("captured 2026-10-22", ec.render_body(self.aws, self.vercel))


class Cli(unittest.TestCase):
    def test_render_and_changed(self):
        with tempfile.TemporaryDirectory() as td:
            t = Path(td)
            (t / "aws.json").write_text(json.dumps(_aws_model()))
            (t / "vercel.json").write_text(json.dumps(_vercel_model()))
            rc = ec.main(["render", "--aws", str(t / "aws.json"), "--vercel", str(t / "vercel.json"), "--out-dir", str(t / "gen"), "--date", "2026-10-22"])
            self.assertEqual(rc, 0)
            page = (t / "gen" / ec.PAGE).read_text()
            self.assertNotIn(SECRET, page)
            # gen_docs `changed` publishes the extra page when it is new on master.
            (t / "old").mkdir()
            self.assertEqual(gd.changed_pages(t / "gen", t / "old", 30, dt.date(2026, 10, 22), gd.PAGES + gd.EXTRA_PAGES), [ec.PAGE])
            (t / "old" / ec.PAGE).write_text(page)
            self.assertEqual(gd.changed_pages(t / "gen", t / "old", 30, dt.date(2026, 10, 22), gd.PAGES + gd.EXTRA_PAGES), [])

    def test_missing_required_runtime_fails_closed(self):
        aws = _aws_model()
        aws["ecs"] = [s for s in aws["ecs"] if s["service"] != "aa-cis-dev-worker"]
        with tempfile.TemporaryDirectory() as td:
            t = Path(td)
            (t / "aws.json").write_text(json.dumps(aws))
            (t / "vercel.json").write_text(json.dumps(_vercel_model()))
            rc = ec.main(["render", "--aws", str(t / "aws.json"), "--vercel", str(t / "vercel.json"), "--out-dir", str(t / "gen")])
            self.assertEqual(rc, 1)
            self.assertFalse((t / "gen" / ec.PAGE).exists())

    def test_checked_in_snapshot_is_names_only(self):
        data = json.loads(ec.VERCEL_SNAPSHOT.read_text(encoding="utf-8"))
        self.assertEqual(data["format"], 1)
        self.assertEqual(set(data["projects"]), set(ec.REQUIRED_VERCEL))
        for project, rows in data["projects"].items():
            for r in rows:
                self.assertLessEqual(set(r), {"key", "kind", "target", "branch"}, project)
                self.assertIn(r["kind"], {"sensitive", "readable"})
                self.assertRegex(r["key"], ec.ENV_NAME_RE)


if __name__ == "__main__":
    unittest.main()
