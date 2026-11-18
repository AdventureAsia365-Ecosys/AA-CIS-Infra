"""Static tests: the docs-sync role reads back exactly one object, the reader manifest (AA-1132).

The root repo "Docs sync" workflow keeps the manifest it is about to replace as docs-reader/manifest.previous.json
(the one-step undo of a bad publish). That needs s3:GetObject on docs-reader/manifest.json, and nothing more:

  - the role policy has one GetObject statement, on that single object of the bronze bucket (no wildcard, no other
    prefix, no other read action such as GetObjectVersion or GetObjectTagging);
  - the write statement stays Put / Delete on docs-reader/* and the list statement stays limited to the prefix;
  - no KMS grant: the bronze bucket is SSE-S3 (AES256), checked in modules/s3.

Offline: reads the .tf files; no Terraform, no AWS. Run from the repo root:
python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1132_docs_sync_manifest_read.py
"""
from __future__ import annotations

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DOCS_READER = os.path.join(REPO_ROOT, "accounts", "aa365", "docs_reader.tf")
S3_MAIN = os.path.join(REPO_ROOT, "modules", "s3", "main.tf")


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _block(text: str, opener: str) -> str:
    start = text.index(opener)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise AssertionError(f"unbalanced block after {opener!r}")


def _statements(policy: str) -> list[str]:
    """The `{ ... Sid = ... }` statement blocks of a jsonencode policy."""
    out = []
    for m in re.finditer(r"Sid\s*=", policy):
        start = policy.rindex("{", 0, m.start())
        out.append(_brace(policy, start))
    return out


def _brace(text: str, start: int) -> str:
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise AssertionError("unbalanced statement")


def _policy() -> str:
    return _block(_read(DOCS_READER), 'resource "aws_iam_role_policy" "docs_sync"')


def _by_sid() -> dict[str, str]:
    return {re.search(r'Sid\s*=\s*"([^"]+)"', s).group(1): s for s in _statements(_policy())}


def test_one_get_statement_on_the_manifest_only():
    stmts = _by_sid()
    gets = {sid: s for sid, s in stmts.items() if "s3:Get" in s}
    assert list(gets) == ["ReadCurrentDocsManifest"]
    s = gets["ReadCurrentDocsManifest"]
    assert re.search(r'Action\s*=\s*\["s3:GetObject"\]', s)
    assert re.search(r'Resource\s*=\s*"arn:aws:s3:::\$\{module\.s3\.bronze_bucket_name\}/\$\{local\.docs_reader_prefix\}'
                     r'manifest\.json"', s)
    assert "*" not in s.split("Resource", 1)[1]


def test_write_and_list_unchanged():
    stmts = _by_sid()
    assert sorted(stmts) == ["ListDocsReaderPrefix", "ReadCurrentDocsManifest", "WriteDocsReaderObjects"]
    assert re.search(r'Action\s*=\s*\["s3:PutObject",\s*"s3:DeleteObject"\]', stmts["WriteDocsReaderObjects"])
    assert re.search(r'Action\s*=\s*\["s3:ListBucket"\]', stmts["ListDocsReaderPrefix"])
    assert "s3:prefix" in stmts["ListDocsReaderPrefix"]
    assert "kms:" not in _policy()


def test_bronze_bucket_is_sse_s3():
    sse = _block(_read(S3_MAIN), 'resource "aws_s3_bucket_server_side_encryption_configuration" "bronze"')
    assert 'sse_algorithm = "AES256"' in sse


def test_prefix_is_the_reader_prefix():
    assert re.search(r'docs_reader_prefix\s*=\s*"docs-reader/"', _read(DOCS_READER))
