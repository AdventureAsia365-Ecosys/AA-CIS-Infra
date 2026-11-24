#!/usr/bin/env python3
"""AA-1173 (S290, compliance readiness phase 2) — seal one collector run into the Object Lock evidence bucket.

The SAME file lives in the root repo (AA-Ecosys tools/compliance/seal.py) and in AA-CIS-Infra
(tools/compliance/seal.py); both test suites check it byte for byte against their own copy's hash in their tests
(test_seal.py SEAL_SHA256 is updated in both PRs together). The bucket (AA-CIS-Infra accounts/aa365/
compliance_evidence.tf) refuses every delete, every retention change and every PutObject without `If-None-Match: *`,
so each object here is written once and an existing key answers 412 (PreconditionFailed).

One run writes, under evidence/<source>/ (UTC date and time of the run, <run> = run id and attempt):

  raw/<yyyy>/<mm>/<dd>/<HHMMSS>Z-<run>/<file>      each --raw file as it is (private: Prowler findings, AWS answers)
  bundles/<yyyy>/<mm>/<dd>/<HHMMSS>Z-<run>.json    the evidence bundle (format 1) the CIS page ingests
  manifest/<yyyy>/<mm>/<dd>/<HHMMSS>Z-<run>.json   {"format": 1, "source", "created_at", "run_ref",
                                                   "collector_version", "previous": {"key", "sha256"} | null,
                                                   "objects": [{"key", "sha256", "bytes"}]}

The manifest is written LAST and names the newest earlier manifest of the same source with its SHA-256 (a hash chain:
an older manifest rewritten or removed breaks the next link; the CIS reader checks it, api/services/compliance_store.py
in AA-CIS-App). Objects go up with the AWS CLI (`aws s3api put-object --if-none-match '*'`, SHA-256 checksum).

Public repos: the log gets counts and the chain state only. Never a bucket name, a key with an account id, an ARN or
the AWS error text (an AccessDenied message names the role ARN): a failure prints the error code alone.

    python3 tools/compliance/seal.py --bucket "$BUCKET" --source aws_nightly --bundle out/bundle.json \\
        [--raw out/prowler.ocsf.json ...] --run "$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" \\
        --run-ref "compliance-aws #$GITHUB_RUN_NUMBER" --version "$GITHUB_SHA"

Stdlib only. Exit 0 = sealed, 1 = a write or read failed (the code is printed), 2 = bad arguments or input.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

FORMAT = 1
PREFIX = "evidence"
_SOURCE = re.compile(r"^[a-z][a-z0-9_]{1,40}$")
_RUN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,40}$")
_SHA = re.compile(r"^[0-9a-f]{7,40}$")
_FILE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$")
_CODE = re.compile(r"An error occurred \(([A-Za-z0-9]+)\)")

Runner = Callable[[list], str]


class SealFailed(Exception):
    """A write or read failed; the message is safe to print (an error code, never the AWS text)."""


def aws_cli(args: list) -> str:
    proc = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True, timeout=300,
                          stdin=subprocess.DEVNULL)
    if proc.returncode != 0:
        m = _CODE.search(proc.stderr or "")
        raise SealFailed(f"aws {args[0]} {args[1]} failed ({m.group(1) if m else 'no error code'})")
    return proc.stdout


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def stamp(now: datetime) -> tuple[str, str]:
    now = now.astimezone(timezone.utc)
    return now.strftime("%Y/%m/%d"), now.strftime("%H%M%S")


def put_once(run: Runner, bucket: str, key: str, path: Path, content_type: str) -> None:
    run(["s3api", "put-object", "--bucket", bucket, "--key", key, "--body", str(path), "--if-none-match", "*",
         "--content-type", content_type, "--checksum-algorithm", "SHA256"])


def previous_manifest(run: Runner, bucket: str, source: str, workdir: Path) -> Optional[dict]:
    """The newest manifest of ``source`` already in the bucket, as {"key", "sha256"}, or None (the first run)."""
    prefix = f"{PREFIX}/{source}/manifest/"
    keys: list[str] = []
    token: Optional[str] = None
    while True:
        args = ["s3api", "list-objects-v2", "--bucket", bucket, "--prefix", prefix, "--max-items", "1000"]
        if token:
            args += ["--starting-token", token]
        page = json.loads(run(args) or "{}") or {}
        keys += [o["Key"] for o in page.get("Contents") or [] if isinstance(o.get("Key"), str)]
        token = page.get("NextToken")
        if not token:
            break
    if not keys:
        return None
    key = max(keys)
    dest = workdir / "previous-manifest.json"
    run(["s3api", "get-object", "--bucket", bucket, "--key", key, str(dest)])
    return {"key": key, "sha256": sha256_file(dest)}


def seal(bucket: str, source: str, bundle: Path, raws: list, run_id: str, run_ref: str, version: Optional[str],
         now: datetime, run: Runner = aws_cli) -> dict:
    """Write the raw files, the bundle and the manifest; returns the counts (safe to print)."""
    if not _SOURCE.fullmatch(source):
        raise ValueError(f"bad source {source!r}")
    if not _RUN.fullmatch(run_id):
        raise ValueError(f"bad run id {run_id!r}")
    data = json.loads(bundle.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("format") != FORMAT or data.get("source") != source:
        raise ValueError(f"the bundle is not a format {FORMAT} bundle of {source}")
    day, hms = stamp(now)
    base = f"{PREFIX}/{source}"
    objects = []
    seen = set()
    for raw in raws:
        raw = Path(raw)
        if not _FILE.fullmatch(raw.name) or raw.name in seen:
            raise ValueError(f"bad or repeated raw file name {raw.name!r}")
        seen.add(raw.name)
        key = f"{base}/raw/{day}/{hms}Z-{run_id}/{raw.name}"
        put_once(run, bucket, key, raw, "application/json" if raw.suffix == ".json" else "application/octet-stream")
        objects.append({"key": key, "sha256": sha256_file(raw), "bytes": raw.stat().st_size})
    bkey = f"{base}/bundles/{day}/{hms}Z-{run_id}.json"
    put_once(run, bucket, bkey, bundle, "application/json")
    objects.append({"key": bkey, "sha256": sha256_file(bundle), "bytes": bundle.stat().st_size})
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        prev = previous_manifest(run, bucket, source, work)
        manifest = {"format": FORMAT, "source": source,
                    "created_at": now.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
                    "run_ref": run_ref[:120], "collector_version": version if version and _SHA.fullmatch(version)
                    else None, "previous": prev, "objects": objects}
        mpath = work / "manifest.json"
        mpath.write_text(json.dumps(manifest, sort_keys=True, indent=1) + "\n", encoding="utf-8")
        put_once(run, bucket, f"{base}/manifest/{day}/{hms}Z-{run_id}.json", mpath, "application/json")
    return {"source": source, "objects": len(objects), "raw": len(raws), "chain": "linked" if prev else "first"}


def main(argv: Optional[list] = None, run: Runner = aws_cli) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--source", required=True)
    ap.add_argument("--bundle", required=True, type=Path)
    ap.add_argument("--raw", action="append", default=[], type=Path)
    ap.add_argument("--run", required=True, dest="run_id")
    ap.add_argument("--run-ref", default="")
    ap.add_argument("--version", default=None)
    a = ap.parse_args(argv)
    try:
        out = seal(a.bucket, a.source, a.bundle, a.raw, a.run_id, a.run_ref, a.version, datetime.now(timezone.utc),
                   run=run)
    except (ValueError, OSError) as exc:
        print(f"seal: refused: {type(exc).__name__}: {str(exc)[:200]}", file=sys.stderr)
        return 2
    except SealFailed as exc:
        print(f"seal: {exc}", file=sys.stderr)
        return 1
    print(f"sealed {out['objects']} object(s) of {out['source']} ({out['raw']} raw); hash chain {out['chain']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
