"""S283 B0 DRY RUN (read-only): the scheduled B2B test pricing row that would replace the B2B rule in force.

The S283 UI audit found an approved B2B pricing row with valid_from 2027-01-01 whose note starts with 'ZZ S239' (a test
fixture made for a page-layout check). The pricing engine takes the newest approved row on or before the day, so on
1 Jan 2027 it would replace the B2B rule in force (lower margin and floor, no RRP markup). Approved rows cannot be
withdrawn from the UI (bk-058 closes pending rows only). This script counts what s283_b0_test_pricing_rule_delete.py
would remove and prints a pin (ids only), plus the B2B rule that stays in force. Prints ids, dates and counts only.
"""
READ_ONLY = True

TARGET_SQL = """
SELECT r.id, r.valid_from,
       EXISTS (SELECT 1 FROM booking.policy_approvals a WHERE a.pricing_rule_id = r.id) AS approved
FROM booking.pricing_rules r
WHERE r.channel = 'b2b' AND r.valid_from = DATE '2027-01-01' AND r.note LIKE 'ZZ S239%'
ORDER BY r.id
"""

IN_FORCE_SQL = """
SELECT r.id, r.valid_from
FROM booking.pricing_rules r
JOIN booking.policy_approvals a ON a.pricing_rule_id = r.id
WHERE r.channel = 'b2b' AND r.valid_from <= CURRENT_DATE
ORDER BY r.valid_from DESC
LIMIT 1
"""

REFS_SQL = """
SELECT c.conrelid::regclass::text AS tbl, c.conname, c.confdeltype
FROM pg_constraint c
WHERE c.contype = 'f' AND c.confrelid = 'booking.pricing_rules'::regclass
ORDER BY 1, 2
"""


async def main(conn):
    rows = await conn.fetch(TARGET_SQL)
    pin = ",".join(str(r["id"]) for r in rows)
    print(f"SCRIPT target rows={len(rows)} approved={[r['approved'] for r in rows]} pin={pin}", flush=True)
    for r in await conn.fetch(REFS_SQL):
        print(f"SCRIPT fk {r['tbl']} {r['conname']} on_delete={r['confdeltype']}", flush=True)
    if rows:
        ids = [r["id"] for r in rows]
        for r in await conn.fetch(REFS_SQL):
            col = await conn.fetchval(
                "SELECT a.attname FROM pg_constraint c JOIN pg_attribute a "
                "ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1] WHERE c.conname = $1", r["conname"])
            n = await conn.fetchval(f"SELECT count(*) FROM {r['tbl']} WHERE {col} = ANY($1::uuid[])", ids)
            print(f"SCRIPT referencing {r['tbl']}.{col} rows={n}", flush=True)
    keep = await conn.fetchrow(IN_FORCE_SQL)
    print(f"SCRIPT b2b in force today id={keep['id'] if keep else None} "
          f"valid_from={keep['valid_from'] if keep else None}", flush=True)
    later = await conn.fetchval(
        "SELECT count(*) FROM booking.pricing_rules WHERE channel = 'b2b' AND valid_from > CURRENT_DATE")
    print(f"SCRIPT b2b rows dated after today={later}", flush=True)
