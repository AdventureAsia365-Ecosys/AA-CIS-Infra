# AA-1183 part 2 — the CI bot key moves to the environment ci-bot (S297, lane l2-rotation)

Root notes: `docs/implementation-notes/AA-1183-l2-rotation.md` in AA-Ecosys (the script
`tools/security/ci_bot_key_consolidate.sh` and the order of the move).

## Decisions

- **Every job that reads `AA_CI_BOT_PRIVATE_KEY` runs in `environment: ci-bot`** (main only, no reviewers): the
  publish job of DB Schema Dump, a new publish job of Docs Gen, the Migration Sync job. The repo-level copy (readable
  by any workflow on any pushed branch) is deleted by the script's `cleanup` after this PR merges.
- **Root reads use the job's own `github.token`**: the root repo is public, so Docs Gen render, Image Scan and the
  Migration Copy Guard retention-rows job no longer mint a ci-bot read token. The retention-rows job runs on
  pull_request, which a main-only environment would refuse.
- **Docs Gen is split** into `render` (plan role over OIDC, no environment: its subject stays `ref:refs/heads/main`)
  and `publish` (ci-bot, no AWS, downloads the render artifact). An environment on the render job would change the
  OIDC subject the plan role trusts.
- **Guard test** `tools/security/tests/test_aa1183_ci_bot_environment.py`: the key only in ci-bot jobs, no AWS role in
  a ci-bot job, every ci-bot job main-only.

## Changed

- `.github/workflows/db-schema-dump.yml`, `docs-gen.yml`, `image-scan.yml`, `migration-copy-guard.yml`,
  `migration-sync.yml`; `tools/terraform/tests/test_aa1023_env_dev_workflows.py` (the dump job, not the publish job,
  is the apply-role job); README CI secrets, db/README.

## Tradeoffs

- Docs Gen gains a second job (about 20 s of runner time a night) instead of keeping the key next to AWS
  credentials.

## Should know

- Merge only after the `ci-bot` environment holds the key (root script `setup`); before that the publish jobs fail
  with the "App is not configured" error. Live check: dispatch Docs Gen (`publish=true`) and DB Schema Dump once.
