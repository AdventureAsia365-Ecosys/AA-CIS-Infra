"""AA-1164: offline tests of tools/security/image_scan.py (no AWS, no scanner, no network).

The AWS CLI and the scanners are injected; the account id below is invented (twelve ones) and must never reach an
output. Run: python3 -m pytest -p no:cacheprovider -q tools/security/tests
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "security"))

import image_scan as tool  # noqa: E402

CONFIG = ROOT / "tools" / "security" / "image_scan.toml"
WORKFLOW = ROOT / ".github" / "workflows" / "image-scan.yml"
ACCT = "111111111111"
HOST = f"{ACCT}.dkr.ecr.us-west-1.amazonaws.com"
D_API = "sha256:" + "a" * 64
D_WEB = "sha256:" + "b" * 64
D_PUB = "sha256:" + "c" * 64


@pytest.fixture()
def cfg():
    return tool.load_config(CONFIG)


@pytest.fixture(autouse=True)
def _no_aliases(monkeypatch):
    monkeypatch.delenv("AWS_ACCOUNT_ALIASES", raising=False)


def fake_aws(tasks_by_service: dict[str, list[dict]]):
    calls = []

    def run(args: list[str]) -> str:
        calls.append(args)
        if args[:2] == ["ecs", "list-services"]:
            return json.dumps([f"arn:aws:ecs:us-west-1:{ACCT}:service/c/{s}" for s in tasks_by_service])
        if args[:2] == ["ecs", "list-tasks"]:
            svc = args[args.index("--service-name") + 1]
            return json.dumps([f"t-{svc}-{n}" for n, _ in enumerate(tasks_by_service[svc])])
        if args[:2] == ["ecs", "describe-tasks"]:
            ids = args[args.index("--tasks") + 1: args.index("--query")]
            out = []
            for svc, tasks in tasks_by_service.items():
                out += [t for n, t in enumerate(tasks) if f"t-{svc}-{n}" in ids]
            return json.dumps(out)
        raise AssertionError(args)

    run.calls = calls
    return run


def task(arch: str, *containers: tuple[str, str, str], status: str = "RUNNING") -> dict:
    return {"lastStatus": status, "attributes": [{"name": "ecs.cpu-architecture", "value": arch}],
            "containers": [{"name": n, "image": i, "imageDigest": d} for n, i, d in containers]}


CLUSTER = {
    "svc-api": [task("x86_64", ("api", f"{HOST}/aa-cis-dev-api:dev-1", D_API))],
    "svc-worker": [task("x86_64", ("worker", f"{HOST}/aa-cis-dev-api:dev-1", D_API)),
                   task("x86_64", ("worker", f"{HOST}/aa-cis-dev-api:dev-1", D_API))],
    "svc-web": [task("arm64", ("web", f"{HOST}/aa-crm-dev-web:abc", D_WEB),
                     ("sidecar", f"public.ecr.aws/docker/library/demo@{D_PUB}", D_PUB))],
    "svc-idle": [],
    "svc-starting": [task("arm64", ("web", f"{HOST}/aa-booking-dev-admin:x", ""), status="PENDING")],
}


# ---------------------------------------------------------------------------------------------------------- config


def test_config_loads_and_holds_every_gate_value(cfg):
    assert cfg["gate"]["classes"] == ["P0", "P1"]
    assert cfg["gate"]["severities"] == ["CRITICAL", "HIGH"]
    assert cfg["gate"]["require_fix"] is True
    assert cfg["cluster"]["name"] == "aa-cis-dev-cluster"


def test_config_refuses_a_missing_key(tmp_path):
    bad = tmp_path / "c.toml"
    bad.write_text(CONFIG.read_text(encoding="utf-8").replace('require_fix = true\n', ""), encoding="utf-8")
    with pytest.raises(tool.ToolError, match="require_fix"):
        tool.load_config(bad)


def test_config_refuses_an_unknown_severity(tmp_path):
    bad = tmp_path / "c.toml"
    bad.write_text(CONFIG.read_text(encoding="utf-8").replace('severities = ["CRITICAL", "HIGH"]',
                                                              'severities = ["SEVERE"]'), encoding="utf-8")
    with pytest.raises(tool.ToolError, match="unknown severities"):
        tool.load_config(bad)


# ---------------------------------------------------------------------------------------------------- references


@pytest.mark.parametrize("image,host,repo,tag,digest", [
    (f"{HOST}/aa-cis-dev-api:dev-1", HOST, "aa-cis-dev-api", "dev-1", ""),
    (f"public.ecr.aws/docker/library/demo@{D_PUB}", "public.ecr.aws", "docker/library/demo", "", D_PUB),
    ("demo:1.2", "docker.io", "demo", "1.2", ""),
    ("localhost:5000/team/app:7", "localhost:5000", "team/app", "7", ""),
])
def test_parse_image(image, host, repo, tag, digest):
    ref = tool.parse_image(image)
    assert (ref.host, ref.repository, ref.tag, ref.digest) == (host, repo, tag, digest)


def test_owner_mapping_first_match_wins(cfg):
    assert tool.owner_of(tool.parse_image(f"{HOST}/aa-booking-dev-admin:x"), cfg) == "AA-Booking"
    assert tool.owner_of(tool.parse_image(f"{HOST}/aa-tripplanner-dev-web:x"), cfg) == "AA-TripPlanner-Web"
    # a public image that happens to carry an app prefix is still a third-party image
    assert tool.owner_of(tool.parse_image("public.ecr.aws/x/aa-cis-dev-api:1"), cfg) == "AA-CIS-Infra"


# ---------------------------------------------------------------------------------------------------- collect


def test_collect_one_entry_per_running_digest(cfg):
    run = fake_aws(CLUSTER)
    images, idle = tool.collect(cfg, run)
    assert idle == ["svc-idle"]
    by_repo = {i.repository: i for i in images}
    assert set(by_repo) == {"aa-cis-dev-api", "aa-crm-dev-web", "docker/library/demo"}
    api = by_repo["aa-cis-dev-api"]
    assert api.platform == "linux/amd64" and api.owner == "AA-CIS-App"
    assert api.ref == f"{HOST}/aa-cis-dev-api@{D_API}"
    assert {(u.service, u.container, u.tasks) for u in api.uses} == {("svc-api", "api", 1), ("svc-worker", "worker", 2)}
    assert by_repo["aa-crm-dev-web"].platform == "linux/arm64"
    assert by_repo["docker/library/demo"].owner == "AA-CIS-Infra"
    assert by_repo["docker/library/demo"].registry == "public.ecr.aws"
    # every ECS call names the configured cluster and region; nothing but list / describe
    assert all(c[1].startswith(("list-", "describe-")) for c in run.calls)
    assert all(c[c.index("--cluster") + 1] == "aa-cis-dev-cluster" for c in run.calls)


def test_collect_refuses_a_running_container_without_digest(cfg):
    run = fake_aws({"svc": [task("arm64", ("web", f"{HOST}/aa-crm-dev-web:abc", ""))]})
    with pytest.raises(tool.ToolError, match="no image digest"):
        tool.collect(cfg, run)


def test_running_file_round_trip_and_registries(cfg, tmp_path, capsys):
    images, idle = tool.collect(cfg, fake_aws(CLUSTER))
    path = tmp_path / "running.json"
    tool.write_running(path, cfg, images, idle)
    back, idle2 = tool.read_running(path)
    assert [i.key for i in back] == [i.key for i in images] and idle2 == idle
    assert tool.main(["registries", "--running", str(path)]) == 0
    assert capsys.readouterr().out.split() == [HOST]


# ---------------------------------------------------------------------------------------------------- scan


def _trivy_doc(*vulns: dict) -> dict:
    return {"SchemaVersion": 2, "ArtifactName": f"{HOST}/aa-cis-dev-api@{D_API}",
            "Results": [{"Target": f"{HOST}/aa-cis-dev-api@{D_API} (alpine 3.99.1)", "Vulnerabilities": list(vulns)}]}


def _fake_scanner(seen, fail_repo=None):
    def execute(args):
        seen.append(args)
        out = Path(args[args.index("--output") + 1])
        if fail_repo and args[1] == "image" and fail_repo in args[-1]:
            return 1, "FATAL unable to pull from " + HOST
        if args[1] == "image":
            out.write_text(json.dumps({"bomFormat": "CycloneDX", "metadata": {"component": {"name": args[-1]}}}))
        else:
            out.write_text(json.dumps(_trivy_doc()))
        return 0, ""
    return execute


def test_scan_masks_outputs_and_records_failures(cfg, tmp_path):
    images, _ = tool.collect(cfg, fake_aws(CLUSTER))
    seen = []
    failed = tool.scan(cfg, images, tmp_path / "out", tmp_path / "cache", _fake_scanner(seen, "aa-crm-dev-web"))
    web = next(i for i in images if i.repository == "aa-crm-dev-web")
    assert failed == [web.key]
    err = (tmp_path / "out" / f"{web.key}.error.txt").read_text()
    assert ACCT not in err and "{aws-account}" in err
    for f in list((tmp_path / "out").glob("*.json")) + list((tmp_path / "cache").glob("*.json")):
        assert ACCT not in f.read_text()
        json.loads(f.read_text())
    pulls = [a for a in seen if a[1] == "image"]
    assert all(a[a.index("--platform") + 1] in ("linux/amd64", "linux/arm64") for a in pulls)
    assert {a[-1].rsplit("@", 1)[-1] for a in pulls} == {i.digest for i in images}   # pulled by digest, never by tag
    scans = [a for a in seen if a[1] == "sbom"]
    assert len(scans) == 2 and all(a[a.index("--scanners") + 1] == cfg["scan"]["scanners"] for a in scans)
    # the failed digest is not cached; the two others are
    assert sorted(p.name for p in (tmp_path / "cache").glob("*")) == sorted(
        tool.cache_name(i) for i in images if i.repository != "aa-crm-dev-web")


def test_every_trivy_call_ignores_a_cwd_trivyignore(cfg, tmp_path, monkeypatch):
    """The gate accepts a finding only through the root register (repo-scoped): a .trivyignore in the working
    directory (the Infra checkout root in the nightly run) must not drop findings of every image before triage."""
    (tmp_path / ".trivyignore").write_text("CVE-2099-0001\n")
    monkeypatch.chdir(tmp_path)
    images, _ = tool.collect(cfg, fake_aws(CLUSTER))
    seen = []
    assert tool.scan(cfg, images, tmp_path / "out", tmp_path / "cache", _fake_scanner(seen)) == []
    assert {a[1] for a in seen} == {"image", "sbom"}
    for args in seen:
        assert args[args.index("--ignorefile") + 1] == os.devnull
    img = images[0]
    sbom = tool.sbom_args(cfg, img, tmp_path / "x.cdx.json")
    vulns = tool.trivy_args(cfg, tmp_path / "x.cdx.json", tmp_path / "x.json")
    assert sbom[-1] == img.ref and vulns[-1] == str(tmp_path / "x.cdx.json")   # the target stays the last argument
    assert sbom[sbom.index("--ignorefile") + 1] == vulns[vulns.index("--ignorefile") + 1] == os.devnull


def test_scan_reuses_the_cached_sbom_and_prunes_old_entries(cfg, tmp_path):
    images, _ = tool.collect(cfg, fake_aws(CLUSTER))
    cache = tmp_path / "cache"
    cache.mkdir()
    for img in images:
        (cache / tool.cache_name(img)).write_text(json.dumps({"bomFormat": "CycloneDX"}))
    (cache / ("d" * 64 + "-amd64.cdx.json")).write_text("{}")        # a digest no longer running
    seen = []
    assert tool.scan(cfg, images, tmp_path / "out", cache, _fake_scanner(seen)) == []
    assert [a for a in seen if a[1] == "image"] == []                  # nothing pulled
    assert len([a for a in seen if a[1] == "sbom"]) == len(images)     # every digest scanned again
    assert not (cache / ("d" * 64 + "-amd64.cdx.json")).exists()


def test_cache_key_depends_on_the_running_set_only(cfg):
    images, _ = tool.collect(cfg, fake_aws(CLUSTER))
    assert tool.cache_key(images) == tool.cache_key(list(reversed(images)))
    assert tool.cache_key(images) != tool.cache_key(images[:1])
    assert ACCT not in tool.cache_key(images)


# ---------------------------------------------------------------------------------------------------- triage + gate


def _finding(ident, sev, cls, fixed="", status="open", kev=False, cvss=None):
    return {"ids": [ident], "package": "libdemo", "severity": sev, "cls": cls, "fixed_in": fixed or None,
            "status": status, "kev": kev, "cvss": cvss, "reasons": ["demo"]}


@pytest.mark.parametrize("finding,fails", [
    (_finding("CVE-2099-0001", "high", "P1", fixed="1.2"), True),
    (_finding("CVE-2099-0002", "critical", "P0", fixed=""), False),                 # no fix yet: monthly triage
    (_finding("CVE-2099-0003", "high", "P1", fixed="1.2", status="accepted until 2099-01-01"), False),
    (_finding("CVE-2099-0004", "medium", "P0", fixed="1.2", kev=True), True),         # KEV lifts a medium to P0
    (_finding("CVE-2099-0005", "critical", "P2", fixed="1.2"), True),               # severity alone is enough
    (_finding("CVE-2099-0006", "medium", "P2", fixed="1.2"), False),
])
def test_gate_rule(cfg, finding, fails):
    assert tool.gate_fails(finding, cfg) is fails


def _prepare(cfg, tmp_path, findings_by_repo: dict[str, list[dict]]):
    images, idle = tool.collect(cfg, fake_aws(CLUSTER))
    for img in images:
        if img.repository in findings_by_repo:
            (tmp_path / f"{img.key}.trivy.json").write_text("{}")
            (tmp_path / f"{img.key}.triage.json").write_text(json.dumps(
                {"meta": {"kev": "catalog demo", "epss": "scores demo"}, "findings": findings_by_repo[img.repository]}))
        else:
            (tmp_path / f"{img.key}.error.txt").write_text("trivy: pull refused\n")
    return images, idle


def test_report_counts_and_gate(cfg, tmp_path):
    findings = [_finding("CVE-2099-0001", "high", "P1", fixed="1.2"),
                _finding("CVE-2099-0002", "critical", "P0"),
                _finding("CVE-2099-0003", "low", "P3", fixed="1.0", status="accepted until 2099-01-01")]
    images, idle = _prepare(cfg, tmp_path, {"aa-cis-dev-api": findings, "aa-crm-dev-web": [],
                                            "docker/library/demo": []})
    results, meta = tool.report(cfg, images, idle, tmp_path)
    api = next(r for r in results if r.image.repository == "aa-cis-dev-api")
    assert api.by_severity["HIGH"] == 1 and api.by_severity["CRITICAL"] == 1 and api.by_severity["LOW"] == 1
    assert api.fixable["HIGH"] == 1 and api.fixable["CRITICAL"] == 0
    assert api.by_class["P0"] == 1 and api.accepted == 1
    assert [f["id"] for f in api.failures] == ["CVE-2099-0001"]
    assert meta["gate_failed"] is True and meta["images_scanned"] == 3


def test_report_passes_when_only_unfixable_or_accepted(cfg, tmp_path):
    findings = [_finding("CVE-2099-0002", "critical", "P0"),
                _finding("CVE-2099-0003", "high", "P1", fixed="1.0", status="accepted until 2099-01-01")]
    images, idle = _prepare(cfg, tmp_path, {"aa-cis-dev-api": findings, "aa-crm-dev-web": [],
                                            "docker/library/demo": []})
    _, meta = tool.report(cfg, images, idle, tmp_path)
    assert meta["gate_failed"] is False


def test_an_image_not_scanned_fails_the_gate(cfg, tmp_path):
    images, idle = _prepare(cfg, tmp_path, {"aa-cis-dev-api": [], "docker/library/demo": []})
    results, meta = tool.report(cfg, images, idle, tmp_path)
    assert meta["gate_failed"] is True
    assert [r.image.repository for r in results if not r.scanned] == ["aa-crm-dev-web"]


def test_report_cli_writes_masked_outputs_and_exit_code(cfg, tmp_path):
    images, idle = _prepare(cfg, tmp_path, {"aa-cis-dev-api": [_finding("CVE-2099-0001", "high", "P1", fixed="1.2")],
                                            "aa-crm-dev-web": [], "docker/library/demo": []})
    running = tmp_path / "running.json"
    tool.write_running(running, cfg, images, idle)
    md, js = tmp_path / "out" / "summary.md", tmp_path / "out" / "summary.json"
    rc = tool.main(["report", "--running", str(running), "--dir", str(tmp_path), "--summary-md", str(md),
                    "--summary-json", str(js)])
    assert rc == 1
    text = md.read_text()
    assert ACCT not in text and ACCT not in js.read_text()
    assert D_API in text and "svc-worker/worker x2" in text and "svc-idle" in text
    assert "CVE-2099-0001" in text and "FAILED" in text
    doc = json.loads(js.read_text())
    assert doc["gate_failed"] is True and doc["gate"]["classes"] == ["P0", "P1"]
    assert {i["repository"] for i in doc["images"]} == {"aa-cis-dev-api", "aa-crm-dev-web", "docker/library/demo"}
    assert all("ref" not in i for i in doc["images"])


def test_triage_runs_the_root_tool_per_image_with_the_owner_repo(cfg, tmp_path):
    images, _ = tool.collect(cfg, fake_aws(CLUSTER))
    root = tmp_path / "root"
    for rel in (cfg["triage"]["tool"], cfg["triage"]["config"], cfg["triage"]["register"]):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text("")
    scan_dir = tmp_path / "scan"
    scan_dir.mkdir()
    for img in images:
        (scan_dir / f"{img.key}.trivy.json").write_text("{}")
    seen = []

    def execute(args):
        seen.append(args)
        Path(args[args.index("--out") + 1]).write_text(json.dumps({"findings": []}))
        return 0, ""

    tool.triage(cfg, images, scan_dir, root, offline=True, execute=execute)
    inputs = sorted(a[a.index("--input") + 1].split("=", 1)[0] for a in seen)
    assert inputs == ["AA-CIS-App", "AA-CIS-Infra", "AA-Partner"]
    assert all("--offline" in a and a[a.index("--env") + 1] == "dev" for a in seen)
    assert all(a[a.index("--register") + 1].endswith("docs/security/vuln-exceptions.toml") for a in seen)


def test_triage_refuses_a_root_checkout_without_the_register(cfg, tmp_path):
    with pytest.raises(tool.ToolError, match="vuln-exceptions.toml|vuln_triage"):
        tool.triage(cfg, [], tmp_path, tmp_path, offline=True)


# ---------------------------------------------------------------------------------------------------- workflow


def test_workflow_wiring():
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "tools/security/image_scan.py" in text
    # pinned, checksum-verified scanners from the shared release pins (WL5), never their own download actions
    assert "./.github/actions/release-bin" in text and "tool: trivy" in text
    assert "aquasecurity/" not in text and "anchore/" not in text
    # read-only plan role for the reads, checked before use; the upload role only in the upload job
    assert "aa-cis-infra-tf-plan" in text and "IMAGE_SCAN_UPLOAD_ROLE_ARN" in text
    assert "vars.IMAGE_SCAN" not in text                       # role ARNs are secrets in a public repo (WL1)
    assert "github.ref == 'refs/heads/main'" in text
    assert "::add-mask::" in text                              # the account id never shows in the public log
    assert "actions/cache/save@" in text and "actions/cache@" not in text   # WL4: save on main only
    assert "running.json" not in text.split("upload-artifact@", 1)[1].split("\n\n", 1)[0]


def test_upload_uri(capsys):
    assert tool.main(["upload-uri", "--account", ACCT]) == 0
    assert capsys.readouterr().out.strip() == f"s3://aa-cis-bronze-{ACCT}/docs-reader/security/image-scan/summary.json"
    assert tool.main(["upload-uri", "--account", "12"]) == 2
