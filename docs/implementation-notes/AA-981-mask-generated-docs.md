# AA-981 / AA-889 — Mask AWS identifiers in the generated docs (AA-CIS-Infra part)

Linear: AA-981 (public-repo hygiene), AA-889 (docs hygiene). S248 decision d15: AA-Ecosys (root) and this repo stay
public until the code is done, so the pages the generators here publish must not print account ids or full ARNs.
Root part: AA-Ecosys `docs/implementation-notes/AA-981-mask-generated-docs.md`.

## Decisions

- **One masking module, `tools/docs/aws_mask.py` (stdlib only).** Used by `gen_docs.page()` (so by every page of
  the Docs Gen bot PR: alarms, network, inventory, IAM, env-config) and by `db/gen_schema_reference.render()`.
  The masking runs on the rendered text, not per field: a value that reaches a page by a path nobody thought of
  (a JSON output, a trust policy, a catalog comment) is still masked.
- **Account id -> `{acc2}`**, braces rather than `<acc2>`: an angle-bracket label in a Markdown table cell outside
  a code span is raw HTML and GitHub drops it (and markdownlint MD033 flags it). An id not in the table renders
  `{aws-account}`.
- **Alias table from the environment, never from the repo.** `AWS_ACCOUNT_ALIASES="acc1=<id>,acc2=<id>,acc3=<id>"`.
  Docs Gen builds it from the optional repo **secret** `AWS_ACCOUNT_ALIASES` plus acc2 read from
  `sts get-caller-identity` at run time, each id `::add-mask::`ed first. A secret, not a repo variable: variables
  are printed in the step `env:` header, and this repo's Actions logs are public. Malformed table -> exit 2 without
  echoing the entry.
- **ARN -> `arn:{partition}:<service>:<region>:<account label>:<resource>`.** Service, region, resource type and
  name stay readable (the docs are for engineers); partition and account do not. A Secrets Manager resource
  loses its random `-XXXXXX` suffix. `arn:aws:iam::aws:policy/...` keeps `aws` (AWS managed, not an account).
- **EC2 / VPC ids -> `<prefix>-{masked}`** (vpc, subnet, sg, rtb, igw, eni, i, nat, eipalloc, vpce, acl, pl). The
  lane rule "no VPC/SG ids in public docs" applies to the same pages; network.md keeps the Name column next to
  each ID column, so nothing a reader needs is lost.
- **UUIDs are skipped** (their last group can be 12 digits: the AA master tenant
  `00000000-0000-0000-0000-000000000001` in RLS policies of db-schema-reference.md).
- **Guard in two places.** (1) Tests: `tools/docs/tests/test_aws_mask.py` renders every Docs Gen page from a
  fixture full of realistic ids/ARNs and asserts no `\b\d{12}\b` (outside UUIDs), no `arn:aws:`, no EC2 id;
  `db/tests/test_schema_reference.py::NoAwsIdentifierLeakTest` does the same for the schema reference.
  (2) Run time: `page()` and `render()` call `aws_mask.assert_clean`, so a generator never writes a leaking page.
- **The Docs Gen fingerprint covers the masked body**, so `changed` compares what is published.

## Changed

- `db/gen_schema_reference.py`: the Verified line said acc2 plus the literal account id; it now says `acc2` only.
- `.github/workflows/migration-copy-guard.yml`: `tools/docs/aws_mask.py` added to the path filter (the db tests
  now import it).
- `.github/workflows/docs-gen.yml`: new step "Account alias table for masking".

## Tradeoffs

- **Masking every 12-digit number** (outside UUIDs) rather than only known ids: a stray id of an account not in
  the table is still masked. Cost: a genuine 12-digit literal (a CHECK constraint, a default) would render as
  `{aws-account}` in the schema reference. None exists today.
- **Secret suffix rule** (`-` + 6 alphanumerics at the end): a secret written WITHOUT its suffix whose name ends
  in a 6-letter word (`...-reader`) would lose that word on the page. Cosmetic; same rule as `gen_env_config`.
- **Not masked (out of this lane's scope, listed for a decision):** API Gateway ids / execute-api hosts, Cognito
  user-pool ids, CloudFront distribution ids and domains, ALB/NLB DNS names, the RDS endpoint host, the NAT
  Elastic IP, ACM validation CNAMEs. Most are discoverable through public DNS or a JWT issuer anyway.
  `aws_mask` is the place to add them.

## Should know

- **History is not rewritten.** Every value committed before this change stays in the git history of both repos
  (and in the open bot PR branch until it is force-pushed). AWS account ids are not secrets (AWS says so); the risk
  is reconnaissance only. No credential is involved.
- **Hand-written docs still hold ids** (root: about 167 files, most in `docs/audits/`, `docs/linear-export/`,
  `docs/sessions/`; this repo: about 56 files, e.g. `.claude/CLAUDE.md`, the state bucket name). Out of scope here.

## Review round (agent review, S248)

- **Test fixtures used real Dev ids** (VPC, subnet, NAT instance, ENI, IGW, route table, ALB ids, a Secrets
  Manager suffix, an API Gateway domain id). Replaced with AWS-documentation-style fakes and folded into the
  original commit, so the real values never enter this repo's history. The test module docstring now says every
  identifier in it is fake.
- **`db-schema-dump.yml` printed the full ECS task ARN** (with the account id) in the public Actions log. It now
  masks the account id right after the OIDC step (`::add-mask::` from `sts get-caller-identity`) and prints only
  the task id. `db-migrate.yml`, `db-isolation-probe.yml`, `terraform-plan.yml` and `terraform-apply.yml` are not
  changed here: their logs (and every run before this change) can still show ids and ARNs.
- **Artifacts:** `docs-gen-<run>` and `db-schema-dump-<run>` keep 14 days. Runs before this change hold unmasked
  pages; the dump artifact also keeps the raw `schema.json`, which this change does not mask. Any signed-in
  GitHub user can download artifacts of a public repo.
- **The env-config guard test now plants leaks** (a secret referenced by full ARN, an SSM parameter ARN from a
  second account, an ECR image URI in a collector warning) and checks both the `{acc2}`/`{acc3}` labels and the
  `{aws-account}` fallback; it fails when masking is switched off.
