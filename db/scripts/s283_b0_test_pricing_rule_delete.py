"""S283 B0 (WRITE): delete the scheduled B2B test pricing row (note 'ZZ S239…', valid_from 2027-01-01).

Why: on 1 Jan 2027 the pricing engine would take this approved test fixture over the B2B rule in force (lower margin and
floor, no RRP markup). Approved policy rows are append-only for role booking and bk-058 closes pending rows only, so the
only way to end it is the owner removing the fixture (bk-058: "role booking deletes no policy row; only the owner's test
fixtures do"). Its policy_approvals row (and any closure) goes with it through ON DELETE CASCADE.
Tech lead approval: S283 close decision page, question c-b0-test-rule ("now"). DRY RUN first:
s283_b0_test_pricing_rule_check.py.

Guards: exactly one matching row, pinned by id; no row of any other table references it except policy_approvals /
policy_row_closures; after the delete, inside the same transaction, no b2b row is dated after today and the b2b rule in
force today is unchanged. Anything else rolls back. Prints ids, dates and counts only.
"""
PIN = "REPLACE_WITH_DRY_RUN_PIN"
CASCADE_OK = {"booking.policy_approvals", "booking.policy_row_closures"}

IN_FORCE_SQL = """
SELECT r.id FROM booking.pricing_rules r
JOIN booking.policy_approvals a ON a.pricing_rule_id = r.id
WHERE r.channel = 'b2b' AND r.valid_from <= CURRENT_DATE
ORDER BY r.valid_from DESC LIMIT 1
"""


async def main(conn):
    async with conn.transaction():
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        ids = [r["id"] for r in await conn.fetch(
            "SELECT id FROM booking.pricing_rules WHERE channel = 'b2b' AND valid_from = DATE '2027-01-01' "
            "AND note LIKE 'ZZ S239%' ORDER BY id FOR UPDATE")]
        if [str(i) for i in ids] != [PIN]:
            if not ids:
                print("SCRIPT target absent: nothing to do", flush=True)
                return
            raise RuntimeError(f"target rows {len(ids)} do not match the pin: refusing")
        refs = await conn.fetch(
            "SELECT c.conrelid::regclass::text AS tbl, a.attname AS col FROM pg_constraint c "
            "JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1] "
            "WHERE c.contype = 'f' AND c.confrelid = 'booking.pricing_rules'::regclass")
        for r in refs:
            n = await conn.fetchval(f"SELECT count(*) FROM {r['tbl']} WHERE {r['col']} = ANY($1::uuid[])", ids)
            print(f"SCRIPT referencing {r['tbl']}.{r['col']} rows={n}", flush=True)
            if n and r["tbl"] not in CASCADE_OK:
                raise RuntimeError(f"{r['tbl']} references the row: refusing")
        before = await conn.fetchval(IN_FORCE_SQL)
        status = await conn.execute("DELETE FROM booking.pricing_rules WHERE id = ANY($1::uuid[])", ids)
        if status != "DELETE 1":
            raise RuntimeError(f"unexpected delete status {status}: rolling back")
        after = await conn.fetchval(IN_FORCE_SQL)
        later = await conn.fetchval(
            "SELECT count(*) FROM booking.pricing_rules WHERE channel = 'b2b' AND valid_from > CURRENT_DATE")
        if after != before or later != 0:
            raise RuntimeError(f"post-check failed (in force changed={after != before}, later={later}): rolling back")
        print(f"SCRIPT deleted {status}; b2b in force id={after}; b2b rows dated after today={later}", flush=True)
