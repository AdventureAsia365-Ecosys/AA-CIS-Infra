"""Runs ONE migration inside a one-off ECS task on the CIS api image (RDS is VPC-private).

Started by .github/workflows/db-migrate.yml, which uploads this file and the migration to S3 and
passes presigned URLs. Uses only the image's own Python + asyncpg and the task's DATABASE_URL
(Secrets Manager, task definition) — nothing from the app code.

Every migration self-registers in shared.schema_versions (repo convention), so:
  check — print whether the version is applied, change nothing
  apply — run the file unless the version is already registered, then require the row exists
"""
import asyncio
import hashlib
import os
import sys
import urllib.request

import asyncpg


def log(msg: str) -> None:
    print(f"MIGRATE {msg}", flush=True)


async def main() -> int:
    sql = urllib.request.urlopen(os.environ["MIGRATION_URL"], timeout=30).read()
    digest = hashlib.sha256(sql).hexdigest()
    if digest != os.environ["MIGRATION_SHA256"]:
        log(f"sha256 mismatch: got {digest}")
        return 2
    version, mode = os.environ["MIGRATION_VERSION"], os.environ["MIGRATION_MODE"]
    log(f"file={os.environ['MIGRATION_FILE']} version={version} sha256={digest[:12]} mode={mode}")

    conn = await asyncpg.connect(os.environ["DATABASE_URL"], timeout=30)
    try:
        latest = await conn.fetchval("SELECT max(version) FROM shared.schema_versions WHERE version ~ '^[0-9]+$'")
        applied = await conn.fetchval("SELECT applied_at FROM shared.schema_versions WHERE version = $1", version)
        log(f"before: latest_registered={latest} this_version_applied_at={applied}")
        if mode != "apply":
            return 0
        if applied:
            log("skip: already applied")
            return 0
        await conn.execute(sql.decode("utf-8"))      # simple protocol: the file's own BEGIN/COMMIT
        applied = await conn.fetchval("SELECT applied_at FROM shared.schema_versions WHERE version = $1", version)
        if not applied:
            log("ERROR: file ran but did not register its version in shared.schema_versions")
            return 3
        log(f"after: applied_at={applied}")
        return 0
    finally:
        await conn.close()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
