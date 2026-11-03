"""AA-1027 E4 live probe: a shared.stage_model_params row for tp_compose reaches TripPlanner's contract view (CIS 350),
inside one transaction that is always rolled back. Nothing is left behind and no TripPlanner Lambda ever sees the row.

Dispatch: DB Migrate, mode=run-script, script=db/scripts/aa1027_e4_stage_params_probe.py, after the Infra Migration
Apply of cis/350. Not READ_ONLY (it inserts the probe row), so the runner's idle check applies; the write is rolled
back before the script returns, whatever happens.

Steps, in one transaction:
  1. the primary model of tp_compose (shared.llm_role_config.model_id) and whether a params row already exists for it;
  2. when none exists, INSERT one probe row (temperature PROBE_TEMPERATURE, effort PROBE_EFFORT, updated_by
     'aa1027-e4-probe');
  3. read the view as tripplanner when the master may SET ROLE to it, else as the master: the stage_params object and
     supports_temperature of the tp_compose rows;
  4. roll back.
Then, outside the transaction: the probe row is gone.

Output (keys, flags and the probe's own values; no other row values):
  SCRIPT route stage=tp_compose model=<key|-> existing_row=<t|f>
  SCRIPT probe inserted=<t|f>
  SCRIPT view read_as=<role> position=<n> model=<key> supports_temperature=<t|f|-> stage_params=<json|null>
  SCRIPT view read_as=<role> error=<class>      (the view could not be read: the run fails, still rolled back)
  SCRIPT rolled_back row_left=<t|f>
  SCRIPT verdict view_carries_params=<true|false> clean=<true|false>
view_carries_params: the primary's view row shows the probe's temperature and effort (or the existing row's values).
clean: no probe row is left after the rollback. Exit 1 when either is false.
"""
import json

READ_ONLY = False

STAGE = "tp_compose"
PROBE_TEMPERATURE = 0.3
PROBE_EFFORT = "low"
PROBE_BY = "aa1027-e4-probe"

ROUTE_SQL = "SELECT model_id FROM shared.llm_role_config WHERE stage = $1 AND is_active"
EXISTING_SQL = "SELECT count(*) > 0 AS ok FROM shared.stage_model_params WHERE stage = $1 AND model_key = $2"
INSERT_SQL = """
INSERT INTO shared.stage_model_params (stage, model_key, temperature, effort, notes, created_at, updated_at, updated_by)
VALUES ($1, $2, $3, $4, 'AA-1027 E4 live probe, rolled back', now(), now(), $5)
"""
CAN_SET_ROLE_SQL = "SELECT pg_has_role(current_user, 'tripplanner', 'MEMBER') AS ok"
VIEW_SQL = """
SELECT position, model_key, supports_temperature, stage_params
  FROM catalog.v_llm_gateway_config_v1 WHERE stage = $1 AND is_active ORDER BY position
"""
LEFT_SQL = "SELECT count(*) > 0 AS ok FROM shared.stage_model_params WHERE updated_by = $1"


class _Rollback(Exception):
    pass


def _flag(v) -> str:
    return "-" if v is None else ("t" if v else "f")


async def main(conn):
    seen = {"carries": False}
    try:
        async with conn.transaction():
            model = await conn.fetchval(ROUTE_SQL, STAGE)
            existing = bool(model) and await conn.fetchval(EXISTING_SQL, STAGE, model)
            print(f"SCRIPT route stage={STAGE} model={model or '-'} existing_row={_flag(bool(existing))}")
            inserted = False
            if model and not existing:
                await conn.execute(INSERT_SQL, STAGE, model, PROBE_TEMPERATURE, PROBE_EFFORT, PROBE_BY)
                inserted = True
            print(f"SCRIPT probe inserted={_flag(inserted)}")
            role = "master"
            if await conn.fetchval(CAN_SET_ROLE_SQL):
                await conn.execute("SET LOCAL ROLE tripplanner")
                role = "tripplanner"
            try:
                rows = await conn.fetch(VIEW_SQL, STAGE)
            except Exception as e:  # noqa: BLE001 - e.g. the master may not read the tripplanner-only view
                print(f"SCRIPT view read_as={role} error={type(e).__name__}")
                raise _Rollback() from None
            for r in rows:
                raw = r["stage_params"]
                params = json.loads(raw) if isinstance(raw, str) else raw
                print(f"SCRIPT view read_as={role} position={r['position']} model={r['model_key']} "
                      f"supports_temperature={_flag(r['supports_temperature'])} "
                      f"stage_params={json.dumps(params, sort_keys=True) if params is not None else 'null'}")
                if r["model_key"] == model and isinstance(params, dict):
                    seen["carries"] = (not inserted) or (
                        params.get("temperature") == PROBE_TEMPERATURE and params.get("effort") == PROBE_EFFORT)
            raise _Rollback()
    except _Rollback:
        pass
    left = await conn.fetchval(LEFT_SQL, PROBE_BY)
    print(f"SCRIPT rolled_back row_left={_flag(bool(left))}")
    clean = not left
    print(f"SCRIPT verdict view_carries_params={'true' if seen['carries'] else 'false'} "
          f"clean={'true' if clean else 'false'}")
    return 0 if seen["carries"] and clean else 1
