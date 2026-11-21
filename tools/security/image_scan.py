#!/usr/bin/env python3
"""Nightly scan of the container images that actually run (AA-1164, root SEC-03; tech lead decision D11, S286).

The CI of each app scans an image it builds for the check and never pushes; the deploy builds again, and nothing reads
the base layers of what has been running for weeks. This tool works from the cluster instead: it lists the image digest
every RUNNING task of every service uses, writes one SBOM per digest (Trivy, CycloneDX; pulled once by digest, then
cached) and scans it with today's vulnerability DB every night (Trivy), classifies every finding
with the root triage rule (tools/security/vuln_triage.py: CISA KEV, FIRST EPSS, CVSS; the SEC-03 classes P0-P3) and
the ONE exception register (docs/security/vuln-exceptions.toml), and fails when a fixable finding the gate names is
not accepted there. Stdlib only; AWS through the `aws` CLI (read-only calls), scanners through their pinned binaries.

  collect  --out running.json            ECS list-services / list-tasks / describe-tasks of the configured cluster:
                                         one entry per running digest (services, containers, platform, owner repo).
                                         The pull reference (it names the registry host, i.e. the account) stays in
                                         this file, which never leaves the runner.
  registries --running running.json      the private ECR registry hosts to log in to (one per line).
  cache-key --running running.json      the key of the SBOM cache entry for the running digests.
  scan     --running running.json --out DIR --sbom-cache DIR
                                         per digest: the SBOM (<key>.sbom.json; from the cache, else pulled by digest
                                         and added to it) and the Trivy JSON of its scan (<key>.trivy.json), both
                                         masked (no account id) before they are written; a failed pull or scan is
                                         recorded in <key>.error.txt and fails the gate.
  triage   --running running.json --dir DIR --root-dir ROOT [--offline]
                                         runs ROOT/tools/security/vuln_triage.py on each Trivy file with the image's
                                         owner repo (so a register row of that repo accepts it): <key>.triage.json.
  report   --running running.json --dir DIR --summary-md FILE --summary-json FILE
                                         counts by level, fixable counts, triage classes and the gate per image;
                                         the Markdown goes to the run summary, the JSON (masked) to the private
                                         docs-reader prefix. Exit 1 when the gate fails.
  upload-uri --account ID                the s3:// URI of that private copy (bucket from the account id at run time:
                                         the id is never written in this public repo).

Every value that decides what is scanned or what fails is in tools/security/image_scan.toml.
Public repo: everything this tool prints or writes outside running.json goes through tools/docs/aws_mask.py and is
checked with its find_leaks (an account id or an ARN left in the output is an error, exit 2). Digests are printed.

Exit: 0 done (gate passed) | 1 the gate failed | 2 bad input, a leak in the output, or an AWS / tool call failed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable, Iterable

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
DEFAULT_CONFIG = HERE / "image_scan.toml"
sys.path.insert(0, str(REPO_ROOT / "tools" / "docs"))

import aws_mask  # noqa: E402

ECR_HOST = re.compile(r"^\d{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(?:\.cn)?$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
ARCH_PLATFORM = {"arm64": "linux/arm64", "aarch64": "linux/arm64", "x86_64": "linux/amd64", "amd64": "linux/amd64"}
SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")
CLASSES = ("P0", "P1", "P2", "P3")
REQUIRED = {
    "cluster": ("name", "region", "env", "default_platform"),
    "scan": ("scanners", "pkg_types", "severities", "timeout", "sbom_format"),
    "gate": ("classes", "severities", "require_fix", "fail_on_scan_error"),
    "triage": ("tool", "config", "register"),
    "report": ("bucket_template", "upload_key", "top_findings"),
}

Runner = Callable[[list[str]], str]


class ToolError(Exception):
    """A configuration, input or external-call problem (exit 2)."""


# --------------------------------------------------------------------------------------------------------------------
# Config


def load_config(path: Path) -> dict:
    try:
        with open(path, "rb") as fh:
            cfg = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ToolError(f"{path}: {exc}") from exc
    for section, keys in REQUIRED.items():
        if section not in cfg:
            raise ToolError(f"{path}: missing [{section}]")
        for key in keys:
            if key not in cfg[section]:
                raise ToolError(f"{path}: missing [{section}] {key}")
    owners = cfg.get("owners") or []
    if not owners or any(not {"registry", "repository", "repo"} <= set(o) for o in owners):
        raise ToolError(f"{path}: [[owners]] needs registry, repository and repo on every row")
    for name in ("severities",):
        for section in ("scan", "gate"):
            bad = [s for s in cfg[section][name] if s not in SEVERITIES]
            if bad:
                raise ToolError(f"{path}: [{section}] {name} has unknown severities {bad}")
    bad = [c for c in cfg["gate"]["classes"] if c not in CLASSES]
    if bad:
        raise ToolError(f"{path}: [gate] classes has unknown classes {bad}")
    return cfg


# --------------------------------------------------------------------------------------------------------------------
# Image references


@dataclass
class ImageRef:
    host: str          # registry host ("docker.io" when the reference names none)
    repository: str    # path inside the registry
    tag: str
    digest: str

    @property
    def registry(self) -> str:
        """`ecr` for a private ECR registry (its host names the account), else the public host."""
        return "ecr" if ECR_HOST.match(self.host) else self.host


def parse_image(image: str) -> ImageRef:
    """`host/path:tag`, `host/path@sha256:...`, `path:tag` (Docker Hub) -> parts."""
    rest, digest = (image.split("@", 1) + [""])[:2]
    first, _, remainder = rest.partition("/")
    if remainder and ("." in first or ":" in first or first == "localhost"):
        host, path = first, remainder
    else:
        host, path = "docker.io", rest
    tag = ""
    if ":" in path.rsplit("/", 1)[-1]:
        path, tag = path.rsplit(":", 1)
    if not path:
        raise ToolError(f"not an image reference: {aws_mask.mask_text(image)}")
    return ImageRef(host, path, tag, digest)


def owner_of(ref: ImageRef, cfg: dict) -> str:
    for row in cfg["owners"]:
        if fnmatch.fnmatchcase(ref.registry, row["registry"]) and fnmatch.fnmatchcase(ref.repository, row["repository"]):
            return row["repo"]
    raise ToolError(f"no [[owners]] row matches {ref.registry}/{ref.repository}")


# --------------------------------------------------------------------------------------------------------------------
# collect: what runs


@dataclass
class Use:
    service: str
    container: str
    tasks: int = 0


@dataclass
class Image:
    key: str
    ref: str               # pull reference by digest (names the registry host: never printed, never uploaded)
    registry: str          # "ecr" or the public host
    repository: str
    tag: str
    digest: str
    platform: str
    owner: str
    uses: list[Use] = field(default_factory=list)


def aws_cli(args: list[str]) -> str:
    proc = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True, timeout=120,
                          stdin=subprocess.DEVNULL)
    if proc.returncode != 0:
        first = (proc.stderr.strip().splitlines() or ["no output"])[0]
        raise ToolError(f"aws {args[0]} {args[1]} failed: {aws_mask.mask_text(first)}")
    return proc.stdout


def _json(text: str, what: str) -> object:
    try:
        return json.loads(text or "null")
    except json.JSONDecodeError as exc:
        raise ToolError(f"{what}: not JSON ({exc})") from exc


def _chunks(items: list[str], size: int) -> Iterable[list[str]]:
    for i in range(0, len(items), size):
        yield items[i:i + size]


def collect(cfg: dict, run: Runner = aws_cli) -> tuple[list[Image], list[str]]:
    """(one Image per running digest, the services with no running task)."""
    cluster, region = cfg["cluster"]["name"], cfg["cluster"]["region"]
    base = ["--cluster", cluster, "--region", region]
    arns = _json(run(["ecs", "list-services", *base, "--query", "serviceArns"]), "list-services") or []
    services = sorted(a.rsplit("/", 1)[-1] for a in arns)
    images: dict[str, Image] = {}
    idle: list[str] = []
    for service in services:
        tasks = _json(run(["ecs", "list-tasks", *base, "--service-name", service, "--desired-status", "RUNNING",
                           "--query", "taskArns"]), "list-tasks") or []
        if not tasks:
            idle.append(service)
            continue
        for chunk in _chunks(list(tasks), 100):
            described = _json(run(["ecs", "describe-tasks", *base, "--tasks", *chunk, "--query", "tasks"]),
                              "describe-tasks") or []
            for task in described:
                if task.get("lastStatus") != "RUNNING":   # still starting: no digest yet, next night's run sees it
                    continue
                arch = next((a.get("value") for a in task.get("attributes") or []
                             if a.get("name") == "ecs.cpu-architecture"), None)
                platform = ARCH_PLATFORM.get(str(arch or "").lower(), cfg["cluster"]["default_platform"])
                for c in task.get("containers") or []:
                    _add(images, cfg, service, c, platform)
    return sorted(images.values(), key=lambda i: (i.owner, i.repository, i.digest)), idle


def _add(images: dict[str, Image], cfg: dict, service: str, container: dict, platform: str) -> None:
    image = container.get("image") or ""
    ref = parse_image(image)
    digest = container.get("imageDigest") or ref.digest
    if not DIGEST.match(digest or ""):
        raise ToolError(f"{service}/{container.get('name')}: no image digest reported for "
                        f"{ref.registry}/{ref.repository}")
    key_id = f"{digest}|{platform}"
    img = images.get(key_id)
    if img is None:
        name = re.sub(r"[^A-Za-z0-9._-]+", "-", ref.repository.rsplit("/", 1)[-1])
        img = Image(key=f"{name}-{digest[7:19]}-{platform.rsplit('/', 1)[-1]}",
                    ref=f"{ref.host}/{ref.repository}@{digest}", registry=ref.registry, repository=ref.repository,
                    tag=ref.tag, digest=digest, platform=platform, owner=owner_of(ref, cfg))
        images[key_id] = img
    use = next((u for u in img.uses if u.service == service and u.container == container.get("name")), None)
    if use is None:
        use = Use(service, container.get("name") or "?")
        img.uses.append(use)
    use.tasks += 1


def write_running(path: Path, cfg: dict, images: list[Image], idle: list[str]) -> None:
    doc = {"cluster": cfg["cluster"]["name"], "collected_at": _now(), "images": [asdict(i) for i in images],
           "idle_services": idle}
    path.write_text(json.dumps(doc, indent=1) + "\n", encoding="utf-8")


def read_running(path: Path) -> tuple[list[Image], list[str]]:
    doc = _json(path.read_text(encoding="utf-8"), str(path))
    if not isinstance(doc, dict) or "images" not in doc:
        raise ToolError(f"{path}: not a running-images file")
    images = []
    for raw in doc["images"]:
        uses = [Use(**u) for u in raw.pop("uses", [])]
        images.append(Image(**raw, uses=uses))
    return images, list(doc.get("idle_services") or [])


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


# --------------------------------------------------------------------------------------------------------------------
# scan: one SBOM per digest (pulled once, then cached), a fresh vulnerability scan of that SBOM every night


def sbom_args(cfg: dict, img: Image, out: Path) -> list[str]:
    """Trivy reads the image BY DIGEST from the registry (no docker daemon) and writes its CycloneDX SBOM."""
    s = cfg["scan"]
    return ["trivy", "image", "--quiet", "--format", s["sbom_format"], "--output", str(out),
            "--pkg-types", s["pkg_types"], "--timeout", s["timeout"], "--platform", img.platform,
            "--image-src", "remote", img.ref]


def trivy_args(cfg: dict, sbom: Path, out: Path) -> list[str]:
    """Today's vulnerability DB against the digest's SBOM: an unchanged digest is never pulled again."""
    s = cfg["scan"]
    return ["trivy", "sbom", "--quiet", "--format", "json", "--output", str(out), "--scanners", s["scanners"],
            "--pkg-types", s["pkg_types"], "--severity", ",".join(s["severities"]), "--timeout", s["timeout"],
            str(sbom)]


def cache_name(img: Image) -> str:
    return f"{img.digest[7:]}-{img.platform.rsplit('/', 1)[-1]}.cdx.json"


def cache_key(images: list[Image]) -> str:
    """Key of the SBOM cache entry for this set of running digests (no account id in it)."""
    lines = "\n".join(sorted(f"{i.digest}|{i.platform}" for i in images))
    return hashlib.sha256(lines.encode()).hexdigest()[:32]


def _exec(args: list[str]) -> tuple[int, str]:
    proc = subprocess.run(args, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return proc.returncode, proc.stderr


def mask_file(path: Path) -> None:
    """Rewrite a scanner output without account ids / ARNs (the registry host names the account)."""
    text = aws_mask.mask_text(path.read_text(encoding="utf-8"))
    leaks = aws_mask.find_leaks(text)
    if leaks:
        raise ToolError(f"{path.name}: account id or ARN left after masking ({len(leaks)})")
    if path.suffix == ".json":
        _json(text, f"{path.name} after masking")   # a masked bare number would break the JSON: refuse it
    path.write_text(text, encoding="utf-8")


def _first_error(err: str, rc: int) -> str:
    return aws_mask.mask_text((err.strip().splitlines() or [f"exit {rc}"])[-1])[:300]


def scan(cfg: dict, images: list[Image], out_dir: Path, cache_dir: Path,
         execute: Callable[[list[str]], tuple[int, str]] = _exec) -> list[str]:
    """SBOM (cached per digest, else pulled once) + vulnerability scan of every image.

    Returns the keys whose scan failed (their reason is in <key>.error.txt). The cache keeps only the SBOMs of the
    digests running now, masked."""
    out_dir.mkdir(parents=True, exist_ok=True)
    cache_dir.mkdir(parents=True, exist_ok=True)
    failed = []
    for img in images:
        sbom, vulns, cached = (out_dir / f"{img.key}.sbom.json", out_dir / f"{img.key}.trivy.json",
                               cache_dir / cache_name(img))
        problem, source = "", "cached SBOM"
        if cached.exists():
            shutil.copyfile(cached, sbom)
        else:
            source = "pulled"
            rc, err = execute(sbom_args(cfg, img, sbom))
            if rc != 0 or not sbom.exists():
                problem = f"sbom: {_first_error(err, rc)}"
                sbom.unlink(missing_ok=True)
            else:
                mask_file(sbom)
                shutil.copyfile(sbom, cached)
        if not problem:
            rc, err = execute(trivy_args(cfg, sbom, vulns))
            if rc != 0 or not vulns.exists():
                problem = f"trivy: {_first_error(err, rc)}"
                vulns.unlink(missing_ok=True)
            else:
                mask_file(vulns)
        if problem:
            failed.append(img.key)
            (out_dir / f"{img.key}.error.txt").write_text(problem + "\n", encoding="utf-8")
        print(f"scanned {img.repository}@{img.digest[:19]} ({img.platform}, {source}): "
              f"{'FAILED ' + problem if problem else 'ok'}", file=sys.stderr)
    keep = {cache_name(i) for i in images}
    for old in cache_dir.glob("*.cdx.json"):
        if old.name not in keep:
            old.unlink()
    return failed


# --------------------------------------------------------------------------------------------------------------------
# triage: the root SEC-03 rule and register


def triage_args(cfg: dict, root: Path, img: Image, trivy: Path, out: Path, cache: Path, offline: bool) -> list[str]:
    t = cfg["triage"]
    args = [sys.executable, "-I", str(root / t["tool"]), "--config", str(root / t["config"]),
            "--register", str(root / t["register"]), "--cache-dir", str(cache), "--env", cfg["cluster"]["env"],
            "--input", f"{img.owner}={trivy}", "--format", "json", "--out", str(out)]
    return args + (["--offline"] if offline else [])


def triage(cfg: dict, images: list[Image], scan_dir: Path, root: Path, offline: bool,
           execute: Callable[[list[str]], tuple[int, str]] = _exec) -> None:
    t = cfg["triage"]
    for rel in (t["tool"], t["config"], t["register"]):
        if not (root / rel).is_file():
            raise ToolError(f"root checkout has no {rel} (the triage rule and register of AA-1163)")
    cache = scan_dir / ".triage-cache"
    for img in images:
        trivy = scan_dir / f"{img.key}.trivy.json"
        if not trivy.exists():
            continue
        out = scan_dir / f"{img.key}.triage.json"
        rc, err = execute(triage_args(cfg, root, img, trivy, out, cache, offline))
        if rc != 0 or not out.exists():
            first = (err.strip().splitlines() or [f"exit {rc}"])[-1]
            raise ToolError(f"triage of {img.repository}@{img.digest[:19]} failed: {aws_mask.mask_text(first)}")
        mask_file(out)


# --------------------------------------------------------------------------------------------------------------------
# report: counts and the gate


@dataclass
class ImageResult:
    image: Image
    scanned: bool
    error: str = ""
    by_severity: dict = field(default_factory=dict)
    fixable: dict = field(default_factory=dict)
    by_class: dict = field(default_factory=dict)
    accepted: int = 0
    kev: int = 0
    failures: list[dict] = field(default_factory=list)
    top: list[dict] = field(default_factory=list)
    triage_state: str = ""


def _finding_row(f: dict) -> dict:
    return {
        "id": (f.get("ids") or ["?"])[0], "package": f.get("package", "?"),
        "severity": str(f.get("severity", "unknown")).upper(), "class": f.get("cls", ""),
        "fixed_in": f.get("fixed_in") or "", "kev": bool(f.get("kev")),
        "epss": f.get("epss"), "reasons": f.get("reasons") or [], "status": f.get("status", ""),
    }


def gate_fails(f: dict, cfg: dict) -> bool:
    g = cfg["gate"]
    if str(f.get("status", "")).startswith("accepted"):
        return False
    if g["require_fix"] and not f.get("fixed_in"):
        return False
    return f.get("cls") in g["classes"] or str(f.get("severity", "")).upper() in g["severities"]


def evaluate(cfg: dict, img: Image, scan_dir: Path) -> ImageResult:
    err_file = scan_dir / f"{img.key}.error.txt"
    trivy_file = scan_dir / f"{img.key}.trivy.json"
    triage_file = scan_dir / f"{img.key}.triage.json"
    if err_file.exists() or not trivy_file.exists():
        reason = err_file.read_text(encoding="utf-8").strip() if err_file.exists() else "no scan output"
        return ImageResult(img, scanned=False, error=reason)
    if not triage_file.exists():
        return ImageResult(img, scanned=False, error="no triage output")
    doc = _json(triage_file.read_text(encoding="utf-8"), triage_file.name)
    findings = (doc or {}).get("findings") or []
    res = ImageResult(img, scanned=True, by_severity={s: 0 for s in SEVERITIES}, fixable={s: 0 for s in SEVERITIES},
                      by_class={c: 0 for c in CLASSES})
    meta = (doc or {}).get("meta") or {}
    res.triage_state = f"KEV {meta.get('kev', '?')}; EPSS {meta.get('epss', '?')}"
    for f in findings:
        sev = str(f.get("severity", "unknown")).upper()
        sev = sev if sev in SEVERITIES else "UNKNOWN"
        res.by_severity[sev] += 1
        if f.get("fixed_in"):
            res.fixable[sev] += 1
        if f.get("cls") in res.by_class:
            res.by_class[f["cls"]] += 1
        if str(f.get("status", "")).startswith("accepted"):
            res.accepted += 1
        if f.get("kev"):
            res.kev += 1
        if gate_fails(f, cfg):
            res.failures.append(_finding_row(f))
    order = {c: i for i, c in enumerate(CLASSES)}
    ranked = sorted(findings, key=lambda f: (order.get(f.get("cls"), 9), -(f.get("cvss") or 0.0)))
    res.top = [_finding_row(f) for f in ranked[: int(cfg["report"]["top_findings"])]]
    res.failures.sort(key=lambda r: (order.get(r["class"], 9), r["id"]))
    return res


def gate_failed(cfg: dict, results: list[ImageResult]) -> bool:
    if cfg["gate"]["fail_on_scan_error"] and any(not r.scanned for r in results):
        return True
    return any(r.failures for r in results)


def _uses(img: Image) -> str:
    return ", ".join(f"{u.service}/{u.container} x{u.tasks}" for u in img.uses)


def render_markdown(cfg: dict, results: list[ImageResult], idle: list[str], meta: dict) -> str:
    g = cfg["gate"]
    out = [f"### Image scan: {cfg['cluster']['name']} ({meta['scanned_at']})", "",
           f"Gate: fixed version available, not in the exception register, and class in {', '.join(g['classes'])} "
           f"or severity in {', '.join(g['severities'])}. Result: **{'FAILED' if meta['gate_failed'] else 'passed'}**.",
           "", "| Owner | Image | Digest | Platform | Running as | C | H | M | L | U | Fixable C/H | P0 | P1 | "
           "Accepted | Gate |", "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        i = r.image
        if not r.scanned:
            out.append(f"| {i.owner} | `{i.repository}` | `{i.digest}` | {i.platform} | {_uses(i)} | "
                       f"| | | | | | | | | not scanned: {r.error.splitlines()[0][:120]} |")
            continue
        s, fx, c = r.by_severity, r.fixable, r.by_class
        out.append(f"| {i.owner} | `{i.repository}` | `{i.digest}` | {i.platform} | {_uses(i)} | {s['CRITICAL']} | "
                   f"{s['HIGH']} | {s['MEDIUM']} | {s['LOW']} | {s['UNKNOWN']} | {fx['CRITICAL']}/{fx['HIGH']} | "
                   f"{c['P0']} | {c['P1']} | {r.accepted} | {'FAIL ' + str(len(r.failures)) if r.failures else 'ok'} |")
    if idle:
        out += ["", f"Services with no running task (nothing to scan): {', '.join(idle)}."]
    failing = [r for r in results if r.failures]
    if failing:
        out += ["", "#### Gate failures (bump the base image or the package, or add a register row with its "
                ".trivyignore entry)", "", "| Image | Id | Package | Severity | Class | Fixed in | Why |",
                "|---|---|---|---|---|---|---|"]
        for r in failing:
            for f in r.failures:
                out.append(f"| `{r.image.repository}` | {f['id']} | {f['package']} | {f['severity']} | {f['class']} | "
                           f"{f['fixed_in']} | {'; '.join(f['reasons'])} |")
    states = sorted({r.triage_state for r in results if r.triage_state})
    if states:
        out += ["", "Feeds: " + " | ".join(states)]
    out += ["", "SBOM and Trivy JSON per digest: run artifact `image-scan-<run id>` (masked, 14 days)."]
    return aws_mask.mask_text("\n".join(out) + "\n")


def render_json(cfg: dict, results: list[ImageResult], idle: list[str], meta: dict) -> str:
    def image_doc(r: ImageResult) -> dict:
        i = r.image
        return {"owner": i.owner, "registry": i.registry, "repository": i.repository, "tag": i.tag,
                "digest": i.digest, "platform": i.platform, "uses": [asdict(u) for u in i.uses],
                "scanned": r.scanned, "error": r.error, "by_severity": r.by_severity, "fixable": r.fixable,
                "by_class": r.by_class, "accepted": r.accepted, "kev": r.kev, "gate_failures": r.failures,
                "top": r.top}
    doc = {"format": 1, **meta, "cluster": cfg["cluster"]["name"],
           "gate": {k: cfg["gate"][k] for k in ("classes", "severities", "require_fix")},
           "images": [image_doc(r) for r in results], "idle_services": idle}
    return aws_mask.mask_text(json.dumps(doc, indent=1)) + "\n"


def report(cfg: dict, images: list[Image], idle: list[str], scan_dir: Path) -> tuple[list[ImageResult], dict]:
    results = [evaluate(cfg, img, scan_dir) for img in images]
    meta = {"scanned_at": _now(), "gate_failed": gate_failed(cfg, results),
            "images_total": len(results), "images_scanned": sum(r.scanned for r in results)}
    return results, meta


# --------------------------------------------------------------------------------------------------------------------
# CLI


def _write_checked(path: Path, text: str) -> None:
    leaks = aws_mask.find_leaks(text)
    if leaks:
        raise ToolError(f"{path.name}: account id or ARN in the output ({len(leaks)}); nothing written")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main(argv: list[str] | None = None, *, run: Runner = aws_cli,
         execute: Callable[[list[str]], tuple[int, str]] = _exec) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--out", type=Path, required=True)
    r = sub.add_parser("registries")
    r.add_argument("--running", type=Path, required=True)
    s = sub.add_parser("scan")
    s.add_argument("--running", type=Path, required=True)
    s.add_argument("--out", type=Path, required=True)
    s.add_argument("--sbom-cache", type=Path, required=True)
    k = sub.add_parser("cache-key")
    k.add_argument("--running", type=Path, required=True)
    t = sub.add_parser("triage")
    t.add_argument("--running", type=Path, required=True)
    t.add_argument("--dir", type=Path, required=True)
    t.add_argument("--root-dir", type=Path, required=True)
    t.add_argument("--offline", action="store_true", help="skip the KEV and EPSS feeds")
    rp = sub.add_parser("report")
    rp.add_argument("--running", type=Path, required=True)
    rp.add_argument("--dir", type=Path, required=True)
    rp.add_argument("--summary-md", type=Path, required=True)
    rp.add_argument("--summary-json", type=Path, required=True)
    u = sub.add_parser("upload-uri")
    u.add_argument("--account", required=True)
    args = p.parse_args(argv)
    try:
        cfg = load_config(args.config)
        if args.cmd == "upload-uri":
            if not re.fullmatch(r"\d{12}", args.account):
                raise ToolError("--account wants a 12-digit account id")
            bucket = cfg["report"]["bucket_template"].format(account=args.account)
            print(f"s3://{bucket}/{cfg['report']['upload_key']}")
            return 0
        if args.cmd == "collect":
            images, idle = collect(cfg, run)
            write_running(args.out, cfg, images, idle)
            for i in images:
                print(f"{i.owner}: {i.repository}@{i.digest} {i.platform} <- {_uses(i)}", file=sys.stderr)
            print(f"{len(images)} running digests, {len(idle)} services without a running task", file=sys.stderr)
            return 0
        images, idle = read_running(args.running)
        if args.cmd == "registries":
            for host in sorted({i.ref.split("/", 1)[0] for i in images if i.registry == "ecr"}):
                print(host)
            return 0
        if args.cmd == "cache-key":
            print(cache_key(images))
            return 0
        if args.cmd == "scan":
            failed = scan(cfg, images, args.out, args.sbom_cache, execute)
            print(f"{len(images) - len(failed)}/{len(images)} images scanned", file=sys.stderr)
            return 0
        if args.cmd == "triage":
            triage(cfg, images, args.dir, args.root_dir, args.offline, execute)
            return 0
        results, meta = report(cfg, images, idle, args.dir)
        _write_checked(args.summary_md, render_markdown(cfg, results, idle, meta))
        _write_checked(args.summary_json, render_json(cfg, results, idle, meta))
        failures = sum(len(r.failures) for r in results)
        unscanned = sum(not r.scanned for r in results)
        print(f"gate {'FAILED' if meta['gate_failed'] else 'passed'}: {failures} finding(s) to fix, "
              f"{unscanned} image(s) not scanned", file=sys.stderr)
        return 1 if meta["gate_failed"] else 0
    except ToolError as exc:
        print(f"image_scan: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
