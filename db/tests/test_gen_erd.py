"""Unit tests for db/gen_erd.py (AA-894 part 1): the generated ERD pages and erd.json.

Run: python3 -m unittest discover -s db/tests -v
"""
import copy
import difflib
import io
import json
import os
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import gen_erd as erd  # noqa: E402


def col(name, type_="uuid", not_null=True, comment=None):
    return {"name": name, "type": type_, "not_null": not_null, "comment": comment}


def pk_index(schema, table, cols, name=None):
    return {"index": name or f"{table}_pkey", "is_primary": True, "is_unique": True, "is_valid": True,
            "definition": f"CREATE UNIQUE INDEX {name or table + '_pkey'} ON {schema}.{table} USING btree ({cols})",
            "bytes": 8192, "scans": 3}


def fk(name, cols, ref_schema, ref_name, ref_cols, validated=True):
    return {"constraint": name, "type": "f", "validated": validated, "columns": cols, "ref_schema": ref_schema,
            "ref_name": ref_name, "ref_columns": ref_cols,
            "definition": f"FOREIGN KEY ({cols}) REFERENCES {ref_schema}.{ref_name}({ref_cols})"}


def rel(columns, indexes=(), constraints=(), kind="table", owner="bk_owner", **extra):
    r = {"kind": kind, "owner": owner, "rls": False, "rls_forced": False, "is_partition": False,
         "est_rows": 10, "size": {"total": 8192, "table": 8192, "index": 0}, "columns": list(columns),
         "indexes": list(indexes), "constraints": list(constraints), "policies": [], "grants": [],
         "column_grants": [], "triggers": [], "activity": {"seq_scan": 1, "n_dead_tup": 0}}
    r.update(extra)
    return r


def fixture():
    """A small format-2 dump: booking (3 tables + a view), shared (1 table), tripplanner (FK to shared),
    catalog (views only) and an empty schema."""
    return {
        "format": 2,
        "generated_at": "2026-10-21T16:24:32+00:00",
        "database": {"server_version": "15.17", "size_bytes": 1, "stats_reset": None},
        "connections": [{"application_name": "x", "role": "r", "state": "idle", "sessions": 1}],
        "schemas": [{"schema": s, "owner": o, "grants": []} for s, o in (
            ("acp_silver_s2", "cis_owner"), ("booking", "bk_owner"), ("catalog", "cis_owner"),
            ("shared", "cis_owner"), ("tripplanner", "tp_owner"))],
        "relations": {
            "acp_silver_s2": {},
            "booking": {
                "trip_cases": rel([col("id"), col("code", "character varying(32)"),
                                   col("total", "numeric(12,2)", False),
                                   col("created_at", "timestamp with time zone")],
                                  [pk_index("booking", "trip_cases", "id"),
                                   {"index": "trip_cases_code_key", "is_primary": False, "is_unique": True,
                                    "is_valid": True, "bytes": 1, "scans": 0,
                                    "definition": "CREATE UNIQUE INDEX trip_cases_code_key ON booking.trip_cases "
                                                  "USING btree (code)"}]),
                "legs": rel([col("id"), col("trip_case_id"), col("email", "text", False, "pii:contact; guest email"),
                             col("status", "booking.leg_status")],
                            [pk_index("booking", "legs", "id"),
                             {"index": "legs_email_live", "is_primary": False, "is_unique": True, "is_valid": True,
                              "bytes": 1, "scans": 0,
                              "definition": "CREATE UNIQUE INDEX legs_email_live ON booking.legs USING btree "
                                            "(lower(email)) WHERE (status <> 'void'::booking.leg_status)"}],
                            [fk("legs_trip_case_id_fkey", "trip_case_id", "booking", "trip_cases", "id")]),
                "notes": rel([col("trip_case_id", not_null=False), col("body", "text", False, "pii:free_text")],
                             [], [fk("notes_trip_case_id_fkey", "trip_case_id", "booking", "trip_cases", "id",
                                     validated=False)]),
                "v_cases": rel([col("id"), col("code", "text", False)], kind="view", est_rows=None, size=None),
            },
            "catalog": {
                "v_tour": rel([col("tour_id"), col("name", "text", False)], kind="view", owner="catalog_owner"),
            },
            "shared": {
                "destinations": rel([col("id"), col("name", "text")], [pk_index("shared", "destinations", "id")],
                                    owner="cis_owner"),
            },
            "tripplanner": {
                "tour_stop": rel([col("source_tour_id", "text"), col("day_index", "integer"),
                                  col("destination_id")],
                                 [pk_index("tripplanner", "tour_stop", "source_tour_id, day_index")],
                                 [fk("tour_stop_destination_id_fkey", "destination_id", "shared", "destinations",
                                     "id")], owner="tp_owner"),
            },
        },
        "migrations": [
            {"version": "bk-018", "applied_at": "2026-10-20 04:00:00+00:00", "description": "b"},
            {"version": "260", "applied_at": "2026-10-21 16:20:00+00:00", "description": "c"},
            {"version": "tp-017", "applied_at": "2026-10-19 10:00:00+00:00", "description": "t"},
        ],
        "migrations_latest_per_owner": {"cis": "260", "tripplanner": "tp-017", "booking": "bk-018"},
        "counts": {"schemas": 5, "relations": 7, "indexes": 5, "policies": 0, "functions": 0},
        "soft_keys": [],
    }


def pages(dump):
    with tempfile.TemporaryDirectory() as tmp:
        erd.write_pages(erd.build_model(dump), tmp)
        return {name: (Path(tmp) / name).read_text(encoding="utf-8") for name in sorted(os.listdir(tmp))}


def mermaid_block(text):
    return re.search(r"```mermaid\n(.*?)```", text, re.S).group(1)


class IndexColumnsTest(unittest.TestCase):
    def test_forms(self):
        for definition, expected in (
            ("CREATE UNIQUE INDEX a_pkey ON s.a USING btree (id)", (["id"], False)),
            ("CREATE UNIQUE INDEX a_pkey ON ONLY s.a USING btree (tenant_id, id)", (["tenant_id", "id"], False)),
            ('CREATE UNIQUE INDEX a_pkey ON s.a USING btree ("order", id DESC)', (["order", "id"], False)),
            ("CREATE INDEX a_x ON s.a USING btree (code text_pattern_ops) INCLUDE (name)", (["code"], False)),
            ("CREATE UNIQUE INDEX a_x ON s.a USING btree (code) WHERE (deleted_at IS NULL)", (["code"], True)),
            ("CREATE UNIQUE INDEX a_x ON s.a USING btree (lower(email))", (None, False)),
            ("CREATE INDEX a_x ON s.a USING gin ((payload -> 'k'::text))", (None, False)),
            ("not an index", (None, False)),
        ):
            with self.subTest(definition=definition):
                self.assertEqual(erd.index_columns(definition), expected)


class MermaidTextTest(unittest.TestCase):
    ATTR_RE = re.compile(r'^        [A-Za-z][A-Za-z0-9_\-()\[\]]* [A-Za-z_][A-Za-z0-9_\-]*'
                         r'( (PK|FK|UK)(, (PK|FK|UK))*)?( "[^"]*")?$')

    def test_types_are_mermaid_words(self):
        for pg, expected in (("character varying(64)", "varchar(64)"), ("timestamp with time zone", "timestamptz"),
                             ("numeric(10,2)", "numeric(10_2)"), ("text[]", "text[]"),
                             ("shared.job_status", "job_status"), ("vector(1536)", "vector(1536)"),
                             ('"char"', "char"), ("character(2)", "char(2)"), ("double precision", "float8"),
                             ("time without time zone", "time"), ("bit varying(8)", "varbit(8)")):
            with self.subTest(pg=pg):
                self.assertEqual(erd.mermaid_type(pg), expected)

    def test_names(self):
        self.assertEqual(erd.mermaid_name("trip_case_id"), "trip_case_id")
        self.assertEqual(erd.mermaid_name("Odd Name"), "Odd_Name")
        self.assertEqual(erd.mermaid_name("2fa"), "c_2fa")
        self.assertEqual(erd.entity("booking", "booking", "legs"), "legs")
        self.assertEqual(erd.entity("tripplanner", "shared", "destinations"), '"shared.destinations"')

    def test_mermaid_keywords_are_quoted_and_key_words_suffixed(self):
        # Mermaid 11.4.1's ER lexer reads these as keywords; unquoted they fail to parse (AA-894 review note 1).
        for word in ("one", "many", "to", "u", "erDiagram", "One", "MANY", "class", "style", "direction"):
            with self.subTest(word=word):
                self.assertEqual(erd.entity("crm", "crm", word), f'"{word}"')
        self.assertEqual(erd.entity("crm", "crm", "option"), "option")      # not a keyword: stays bare
        self.assertEqual(erd.entity("crm", "crm", "one_time"), "one_time")
        for name, expected in (("pk", "pk_"), ("FK", "FK_"), ("uk", "uk_"), ("pk-x", "pk_-x"),
                               ("pk_id", "pk_id"), ("pkg", "pkg"), ("fkey", "fkey"), ("uk_code", "uk_code")):
            with self.subTest(name=name):
                self.assertEqual(erd.mermaid_name(name), expected)
        self.assertEqual(erd.mermaid_type("pk"), "pk_")

    def test_keyword_table_and_key_column_render(self):
        dump = copy.deepcopy(fixture())
        dump["relations"]["booking"]["many"] = rel(
            [col("pk"), col("trip_case_id"), col("uk", "text")],
            [pk_index("booking", "many", "pk")],
            [fk("many_trip_case_id_fkey", "trip_case_id", "booking", "trip_cases", "id")])
        model = erd.build_model(dump)
        table = next(t for s in model["schemas"] for t in s["tables"] if t["name"] == "many")
        self.assertEqual(table["primary_key"], ["pk"])                        # erd.json keeps the real names
        self.assertEqual([c["name"] for c in table["columns"]], ["pk", "trip_case_id", "uk"])
        block = mermaid_block(erd.render_schema(model, next(s for s in model["schemas"]
                                                           if s["schema"] == "booking")))
        self.assertIn('    "many" {\n        uuid pk_ PK\n', block)
        self.assertIn('    trip_cases ||--o{ "many" : "many_trip_case_id_fkey"', block)
        self.assertNotRegex(block, r"(?m)^    many\b")

    def test_every_diagram_line_is_well_formed(self):
        entity_re = re.compile(r'^    ("[^"]+"|[A-Za-z_][A-Za-z0-9_\-]*)( \{)?$')
        line_res = (self.ATTR_RE, entity_re, re.compile(r"^    \}$"),
                    re.compile(r'^    ("[^"]+"|[A-Za-z_][A-Za-z0-9_\-]*) (\|\||\|o)(--|\.\.)(o\{|o\|) '
                               r'("[^"]+"|[A-Za-z_][A-Za-z0-9_\-]*) : "[^"]+"$'))
        for name, text in pages(fixture()).items():
            if name == "README.md":
                self.assertNotIn("```mermaid", text)
                continue
            block = mermaid_block(text).splitlines()
            self.assertEqual(block[0], "erDiagram", name)
            for line in block[1:]:
                with self.subTest(page=name, line=line):
                    self.assertTrue(any(r.match(line) for r in line_res), line)


class ModelTest(unittest.TestCase):
    def setUp(self):
        self.model = erd.build_model(fixture(), source="https://example/run/1")
        self.schemas = {s["schema"]: s for s in self.model["schemas"]}
        self.tables = {f"{s['schema']}.{t['name']}": t for s in self.model["schemas"] for t in s["tables"]}

    def test_keys_and_tags(self):
        cases = self.tables["booking.trip_cases"]
        self.assertEqual(cases["primary_key"], ["id"])
        self.assertEqual(cases["unique_keys"], [["code"]])
        self.assertEqual({c["name"]: (c["pk"], c["fk"], c["uk"]) for c in cases["columns"]},
                         {"id": (True, False, False), "code": (False, False, True), "total": (False, False, False),
                          "created_at": (False, False, False)})
        legs = self.tables["booking.legs"]
        self.assertEqual(legs["unique_keys"], [])                 # expression + partial unique index: no key
        email = next(c for c in legs["columns"] if c["name"] == "email")
        self.assertEqual((email["tag"], email["type"]), ("pii:contact", "text"))
        self.assertEqual(self.tables["tripplanner.tour_stop"]["primary_key"], ["source_tour_id", "day_index"])
        self.assertEqual(self.tables["booking.notes"]["primary_key"], [])

    def test_owners_and_edges(self):
        self.assertEqual({s: (v["owner_app"], v["owner_role"]) for s, v in self.schemas.items()},
                         {"acp_silver_s2": ("cis", "cis_owner"), "booking": ("booking", "bk_owner"),
                          "catalog": ("cis", "cis_owner"), "shared": ("cis", "cis_owner"),
                          "tripplanner": ("tripplanner", "tp_owner")})
        self.assertEqual([(e["from"], e["name"], e["to"], e["validated"], e["cross_schema"], e["cross_owner"])
                          for e in self.model["edges"]],
                         [("booking.legs", "legs_trip_case_id_fkey", "booking.trip_cases", True, False, False),
                          ("booking.notes", "notes_trip_case_id_fkey", "booking.trip_cases", False, False, False),
                          ("tripplanner.tour_stop", "tour_stop_destination_id_fkey", "shared.destinations", True,
                           True, True)])
        self.assertEqual(self.model["owner_migration_dates"],
                         {"booking": "2026-10-20", "cis": "2026-10-21", "tripplanner": "2026-10-19",
                          "platform": "2026-10-21"})

    def test_no_row_data_comments_or_grants(self):
        forbidden = {"comment", "est_rows", "size", "activity", "grants", "column_grants", "policies", "connections",
                     "database", "soft_keys", "roles"}

        def walk(node):
            if isinstance(node, dict):
                for k, v in node.items():
                    self.assertNotIn(k, forbidden)
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)
        walk(self.model)
        self.assertNotIn("guest email", erd.json_text(self.model))        # comment free text never leaks

    def test_json_is_sorted_and_stable(self):
        text = erd.json_text(self.model)
        self.assertEqual(text, erd.json_text(erd.build_model(fixture(), source="https://example/run/1")))
        self.assertTrue(text.endswith("}\n"))
        self.assertEqual(json.loads(text)["format"], 1)
        self.assertEqual([s["schema"] for s in self.model["schemas"]], sorted(self.schemas))

    def test_fingerprint_ignores_volatile_and_follows_structure(self):
        base = self.model["fingerprint"]
        noisy = fixture()
        noisy["generated_at"] = "2026-10-22T03:43:00+00:00"
        noisy["relations"]["booking"]["legs"]["est_rows"] = 99999
        noisy["relations"]["booking"]["legs"]["activity"] = {"seq_scan": 500}
        noisy["relations"]["booking"]["legs"]["columns"][2]["comment"] = "pii:contact; reworded free text"
        self.assertEqual(erd.build_model(noisy)["fingerprint"], base)
        changed = fixture()
        changed["relations"]["booking"]["notes"]["constraints"][0]["validated"] = True
        self.assertNotEqual(erd.build_model(changed)["fingerprint"], base)


class PagesTest(unittest.TestCase):
    def setUp(self):
        self.pages = pages(fixture())

    def test_one_page_per_non_empty_schema_plus_index(self):
        self.assertEqual(sorted(self.pages),
                         ["README.md", "booking.md", "catalog.md", "shared.md", "tripplanner.md"])
        self.assertIn("Empty schemas (no page): `acp_silver_s2`.", self.pages["README.md"])

    def test_booking_diagram(self):
        block = mermaid_block(self.pages["booking.md"])
        self.assertIn("    trip_cases {\n        uuid id PK\n        varchar(32) code UK\n"
                      "        numeric(12_2) total\n        timestamptz created_at\n    }", block)
        self.assertIn('        text email "pii:contact"', block)
        self.assertIn('    trip_cases ||--o{ legs : "legs_trip_case_id_fkey"', block)
        self.assertIn('    trip_cases |o..o{ notes : "notes_trip_case_id_fkey"', block)   # nullable + NOT VALID
        self.assertNotIn("v_cases", block)                                   # views are listed, not drawn
        self.assertIn("| `v_cases` | view | 2 |", self.pages["booking.md"])

    def test_cross_schema_edge_drawn_on_the_child_page_listed_on_the_parent(self):
        tp = mermaid_block(self.pages["tripplanner.md"])
        self.assertIn('    "shared.destinations"\n', tp)
        self.assertIn('    "shared.destinations" ||--o{ tour_stop : "tour_stop_destination_id_fkey"', tp)
        shared = self.pages["shared.md"]
        self.assertNotIn("tour_stop", mermaid_block(shared))
        incoming = shared.split("## Foreign keys in from other schemas")[1]
        self.assertIn("`tour_stop_destination_id_fkey` | `tripplanner.tour_stop` (destination_id)", incoming)
        readme = self.pages["README.md"]
        self.assertIn("| `tripplanner` | `shared` | TripPlanner -> CIS | 1 |", readme)

    def test_views_only_schema_draws_its_views(self):
        page = self.pages["catalog.md"]
        self.assertIn("This schema has no tables: the diagram shows its views", page)
        self.assertIn("    v_tour {\n        uuid tour_id\n        text name\n    }", mermaid_block(page))

    def test_big_schema_shows_key_columns_only(self):
        with mock.patch.object(erd, "MAX_FULL_TABLES", 2):
            block = mermaid_block(pages(fixture())["booking.md"])
        self.assertIn("    trip_cases {\n        uuid id PK\n        varchar(32) code UK\n    }", block)
        self.assertIn("    legs {\n        uuid id PK\n        uuid trip_case_id FK\n    }", block)
        self.assertNotIn("email", block)

    def test_front_matter(self):
        id_re = re.compile(r"^(CAT|ARCH|APP|OPS|PROD|SEC|FIN|GUIDE|TPL|PLAT)-[0-9]{2}(-[a-z0-9]+)*$")
        ids = set()
        for name, text in self.pages.items():
            with self.subTest(page=name):
                head = text.split("---\n")[1]
                fields = dict(line.split(": ", 1) for line in head.splitlines())
                self.assertLessEqual({"id", "title", "type", "status", "owner", "last_reviewed", "generated",
                                      "generator"}, set(fields))
                self.assertRegex(fields["id"], id_re)
                self.assertNotIn(fields["id"], ids)
                ids.add(fields["id"])
                self.assertEqual((fields["type"], fields["status"], fields["generated"]),
                                 ("reference", "active", "true"))
                self.assertEqual(fields["generator"], erd.GENERATOR)
                self.assertRegex(fields["last_reviewed"], r"^\d{4}-\d{2}-\d{2}$")
                self.assertEqual(f"# {json.loads(fields['title'])}", text.split("---\n", 2)[2].splitlines()[1])
        self.assertIn("APP-04-erd-booking", ids)
        self.assertIn("last_reviewed: 2026-10-20", self.pages["booking.md"])   # newest Booking migration

    def test_markdown_basics(self):
        """The markdownlint rules a generator can break (.markdownlint-cli2.jsonc runs the defaults in root CI)."""
        for name, text in self.pages.items():
            with self.subTest(page=name):
                self.assertTrue(text.endswith("\n") and not text.endswith("\n\n"))          # MD047, MD012
                self.assertNotIn("\n\n\n", text)                                              # MD012
                self.assertFalse([ln for ln in text.splitlines() if ln != ln.rstrip()])       # MD009
                self.assertNotIn("\t", text)                                                  # MD010
                body = text.split("---\n", 2)[2]
                self.assertEqual(len(re.findall(r"^# ", body, re.M)), 1)                     # MD025
                for fence in re.findall(r"^```.*$", body, re.M)[::2]:
                    self.assertNotEqual(fence, "```")                                         # MD040
                lines = body.splitlines()
                for i, ln in enumerate(lines):
                    if ln.startswith("|") and (i == 0 or not lines[i - 1].startswith("|")):
                        self.assertEqual(lines[i - 1], "")                                    # MD058
                        width = ln.count(" | ")
                        j = i
                        while j < len(lines) and lines[j].startswith("|"):
                            if not lines[j].startswith("|---"):
                                self.assertEqual(lines[j].replace("\\|", "").count(" | "), width, lines[j])
                            j += 1
                        self.assertEqual(lines[j] if j < len(lines) else "", "")
                    if ln.startswith("#"):
                        self.assertEqual(lines[i + 1], "", ln)                                # MD022

    def test_deterministic_and_volatile_free(self):
        self.assertEqual(pages(fixture()), self.pages)
        noisy = fixture()
        noisy["generated_at"] = "2026-10-23T03:43:00+00:00"
        noisy["connections"] = []
        for rels in noisy["relations"].values():
            for r in rels.values():
                r["est_rows"], r["size"], r["activity"] = 123456, {"total": 1 << 30}, {"seq_scan": 9}
                for i in r["indexes"]:
                    i["scans"], i["bytes"] = 999, 1 << 20
        self.assertEqual(pages(noisy), self.pages)

    def test_fk_change_shows_up_as_a_diff(self):
        """Done-when line 1: a new FK in booking changes booking.md (a relationship line) and the index count,
        nothing else."""
        changed = fixture()
        changed["relations"]["booking"]["notes"]["constraints"].append(
            fk("notes_leg_id_fkey", "trip_case_id", "booking", "legs", "id"))
        after = pages(changed)
        self.assertEqual(sorted(n for n in after if after[n] != self.pages[n]), ["README.md", "booking.md"])
        diff = difflib.unified_diff(self.pages["booking.md"].splitlines(), after["booking.md"].splitlines(),
                                    lineterm="", n=0)
        added = [ln for ln in diff if ln.startswith("+") and not ln.startswith("+++")]
        self.assertIn('+    legs |o--o{ notes : "notes_leg_id_fkey"', added)
        self.assertIn("+| `notes_leg_id_fkey` | `booking.notes` (trip_case_id) | `booking.legs` (id) | yes |", added)
        dropped = fixture()
        dropped["relations"]["tripplanner"]["tour_stop"]["constraints"] = []
        after = pages(dropped)
        self.assertEqual(sorted(n for n in after if after[n] != self.pages[n]),
                         ["README.md", "shared.md", "tripplanner.md"])
        self.assertNotIn("tour_stop_destination_id_fkey", after["tripplanner.md"])


class CliTest(unittest.TestCase):
    def test_writes_pages_and_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            dump_path = Path(tmp) / "schema.json"
            dump_path.write_text(json.dumps(fixture()), encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                rc = erd.main([str(dump_path), "--out-dir", f"{tmp}/erd", "--json", f"{tmp}/erd.json",
                               "--source", "https://example/run/2"])
            self.assertEqual(rc, 0)
            self.assertIn("5 page(s)", out.getvalue())
            model = json.loads((Path(tmp) / "erd.json").read_text(encoding="utf-8"))
            self.assertEqual((model["source"], model["generated_at"]),
                             ("https://example/run/2", "2026-10-21T16:24:32+00:00"))
            self.assertEqual(sorted(os.listdir(f"{tmp}/erd")),
                             ["README.md", "booking.md", "catalog.md", "shared.md", "tripplanner.md"])
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(erd.main([str(dump_path), "--fingerprint"]), 0)
            self.assertEqual(out.getvalue().strip(), model["fingerprint"])

    def test_refuses_other_formats(self):
        with tempfile.TemporaryDirectory() as tmp:
            dump_path = Path(tmp) / "schema.json"
            dump = copy.deepcopy(fixture())
            dump["format"] = 1
            dump_path.write_text(json.dumps(dump), encoding="utf-8")
            with redirect_stderr(io.StringIO()):
                self.assertEqual(erd.main([str(dump_path), "--json", f"{tmp}/x.json"]), 2)


if __name__ == "__main__":
    unittest.main()
