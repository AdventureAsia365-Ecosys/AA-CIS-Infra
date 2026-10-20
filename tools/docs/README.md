# Docs lint tools (AA-888)

The checks behind [`.github/workflows/docs-lint.yml`](../../.github/workflows/docs-lint.yml). The rules are the
ecosystem docs standard (AA-Ecosys `docs/STYLE.md`).

## Vendored copy

These files are copies of AA-Ecosys `tools/docs/`, the source of truth, and must stay byte-identical with it and
with the copy in AA-Booking: `docslib.py`, `check_docs_text.py`, `check_adr_index.py`, `check_frontmatter.py`,
`test_docs_tools.py`, `lychee.toml`, `requirements.txt`. The schema
[`docs/templates/frontmatter.schema.json`](../../docs/templates/frontmatter.schema.json) is a copy of AA-Ecosys
`docs/templates/frontmatter.schema.json`. Only this README is repo-specific.

Change a rule in AA-Ecosys first, then copy the files here and to AA-Booking in the same session. There is no
automatic drift check yet; compare by hand with `cmp` from the workspace when you touch these files.

## What runs here

| Check | Command | Level |
|---|---|---|
| Unit tests of the tools | `python3 -m unittest discover -s tools/docs -p 'test_*.py'` | error |
| Front-matter of `CONTEXT.md` and `docs/**` against the schema, unique IDs | `python3 tools/docs/check_frontmatter.py` | error |
| ADR status lines and the index `docs/adr/README.md` | `python3 tools/docs/check_adr_index.py docs/adr` | error |
| No `aws ...` command continued with a backslash, in any tracked Markdown file | `python3 tools/docs/check_docs_text.py aws-multiline --all` | error |
| Literal resource IDs in Markdown | `python3 tools/docs/check_docs_text.py resource-ids --all --mode warn --block vpc,apigw` | error for VPC resource IDs (`sg-`, `subnet-`, `vpc-`, ...) and API Gateway hosts; warning for account IDs, ARNs and user-pool IDs |
| Internal links, offline | `lychee --config tools/docs/lychee.toml $(git ls-files '*.md')` | error |
| Freshness report (weekly, artifact `docs-freshness`) | `python3 tools/docs/check_frontmatter.py --freshness-report .freshness.md` | warning |

Why the resource-ID split: this repo is private and holds the account map, ARNs in IAM notes and the state bucket
name (STYLE.md, "Where a page may live"), so those only warn. VPC resource IDs and API Gateway hosts change when
resources are re-created and are read from Terraform outputs, so no page carries them. Workflow YAML, Terraform and
scripts are not Markdown and are not scanned; multi-line `aws` commands in workflow `run:` blocks run on Linux
runners and are fine.

Journals keep their history as written and are out of scope of the text checks: `docs/implementation-notes/`
(and the other journal folders listed in `docslib.py`). To skip one line on purpose, put `docs-lint: ignore` on it
(an HTML comment works) and say why next to it.

## Run locally

From the repo root:

```bash
python3 -m pip install -r tools/docs/requirements.txt
python3 -m unittest discover -s tools/docs -p 'test_*.py'
python3 tools/docs/check_frontmatter.py
python3 tools/docs/check_adr_index.py docs/adr
python3 tools/docs/check_docs_text.py aws-multiline --all
python3 tools/docs/check_docs_text.py resource-ids --all --mode warn --block vpc,apigw
lychee --config tools/docs/lychee.toml $(git ls-files '*.md')
```
