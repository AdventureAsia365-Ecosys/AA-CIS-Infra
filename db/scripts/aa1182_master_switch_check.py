"""AA-1182 (S297): read-only evidence for the switch to the RDS-managed master password.

Dispatch after the Terraform apply that sets manage_master_user_password: DB Migrate, mode=run-script,
script=db/scripts/aa1182_master_switch_check.py. The runner has already logged which master login it used (expected:
`MIGRATE master login: aa_cis_admin (in-task RDS-managed secret of aa-cis-dev-db)`). This script then prints:

  SCRIPT session_user=aa_cis_admin
  SCRIPT managed_secret status=<active|creating|rotating|impaired>   (DescribeDBInstances MasterUserSecret metadata;
                                                                    the 180-day schedule is checked with the CLI)
  SCRIPT legacy_master=refused (InvalidPasswordError)   the old DSN secret no longer logs in (Done-when: old fails)
     or legacy_master=absent (<error class/code>)       the old secret is already deleted / unreadable
     or legacy_master=STILL-LOGS-IN                     the switch did not change the password: exit 13, investigate

It never prints a value: secret contents, DSNs and error texts stay inside; only classes, codes and metadata leave.
READ_ONLY = True: the master session is read-only and the idle check only reports.
"""

READ_ONLY = True

INSTANCE = "aa-cis-dev-db"
LEGACY_ID = "aa-cis/dev/rds"
REGION = "us-west-1"


def _err(exc):
    code = (getattr(exc, "response", None) or {}).get("Error", {}).get("Code")
    return f"{type(exc).__name__}{f' {code}' if code else ''}"


def _managed_status(rds):
    """SecretStatus of the instance's RDS-managed master secret ('not-managed' without one), metadata only."""
    inst = rds.describe_db_instances(DBInstanceIdentifier=INSTANCE)["DBInstances"][0]
    master = inst.get("MasterUserSecret") or {}
    if not master.get("SecretArn"):
        return "not-managed"
    return master.get("SecretStatus") or "unknown"


async def _legacy_login(sm, connect):
    """'refused (...)', 'absent (...)' or 'STILL-LOGS-IN' for the old DSN secret."""
    try:
        dsn = (sm.get_secret_value(SecretId=LEGACY_ID).get("SecretString") or "").strip()
    except Exception as e:  # noqa: BLE001 — ResourceNotFound / InvalidRequest (scheduled for deletion) / denied
        return f"absent ({_err(e)})"
    if not dsn:
        return "absent (empty)"
    try:
        conn = await connect(dsn, ssl="require", timeout=30)
    except Exception as e:  # noqa: BLE001 — class only: the text may echo the DSN
        return f"refused ({type(e).__name__})"
    await conn.close()
    return "STILL-LOGS-IN"


def _clients():
    import boto3
    return boto3.client("rds", region_name=REGION), boto3.client("secretsmanager", region_name=REGION)


async def _connect(dsn, **kw):
    import asyncpg
    return await asyncpg.connect(dsn, **kw)


async def check(conn, rds, sm, connect):
    print(f"SCRIPT session_user={await conn.fetchval('SELECT session_user::text')}", flush=True)
    status = _managed_status(rds)
    print(f"SCRIPT managed_secret status={status}", flush=True)
    legacy = await _legacy_login(sm, connect)
    print(f"SCRIPT legacy_master={legacy}", flush=True)
    return 1 if legacy == "STILL-LOGS-IN" or status == "not-managed" else 0


async def main(conn):
    rds, sm = _clients()
    return await check(conn, rds, sm, _connect)
