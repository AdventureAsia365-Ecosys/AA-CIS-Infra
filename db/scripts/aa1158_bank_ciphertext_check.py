"""AA-1158 part 2 (S290), Dev, READ ONLY: supplier bank account numbers are ciphertext at rest.

Copy to AA-CIS-Infra `db/scripts/aa1158_bank_ciphertext_check.py` (PR, review, merge), then dispatch DB Migrate
`mode=run-script script=db/scripts/aa1158_bank_ciphertext_check.py` (the ORCHESTRATOR; db/scripts/README.md). It
needs the master because role `booking` reads `booking.supplier_bank_account` only through the app's columns.

What it proves, with counts only (no value of any column is returned; the runner's personal-data guard plans every
statement, and `ciphertext` / `account_last4` appear only inside `count(*) FILTER (WHERE …)`):

1. Shape: the table has no column that could hold a clear account number, holder, IBAN, SWIFT/BIC, bank code or bank
   address (`plaintext_like_columns` = 0), and its columns are exactly the AA-Booking bk-067 envelope
   (`ciphertext` bytea, `wrapped_key` bytea, `kms_key_id`, `enc_alg`).
2. Every row is an envelope: `enc_alg = 'AES-256-GCM'`, a KMS key ARN in us-west-1, a wrapped data key of at least
   16 bytes, a ciphertext of at least 29 bytes (12-byte nonce + 16-byte tag + data).
3. No clear text inside the ciphertext: no run of 6 or more ASCII digits (an account number would show one; random
   AES-GCM output has one with a probability of about 1 in a million per row), no `{"` at the start of the encrypted
   part (the plaintext is sorted JSON), and the stored last 4 characters never appear in the ciphertext bytes.
4. The rows of the synthetic suppliers of S289 / S290 (codes in SUPPLIERS) are counted per status, so the check covers
   the accounts the live checks entered (S289 `•••• 0875` on SUP-000017, S290 on the S290 supplier).

Prints `SCRIPT <topic> key=value …` lines and a verdict `SCRIPT verdict ciphertext_at_rest=true|false`. Returns 1 when
any check fails, so the workflow run goes red.
"""

READ_ONLY = True

# The synthetic suppliers whose accounts the S289 / S290 live checks entered (codes only, invented records). Add the
# S290 supplier code after it exists (40_supply.cjs writes it to work/supply.json).
SUPPLIERS = ("SUP-000017", "SUP-000019")

ROLE = "bk_owner"

COLUMNS_SQL = (
    "SELECT column_name, data_type FROM information_schema.columns"
    " WHERE table_schema = 'booking' AND table_name = 'supplier_bank_account' ORDER BY ordinal_position"
)
PLAINTEXT_COLUMNS_SQL = (
    "SELECT count(*) FROM information_schema.columns"
    " WHERE table_schema = 'booking' AND table_name = 'supplier_bank_account'"
    " AND column_name ~* '(iban|swift|bic|account_number|account_no|holder|bank_code|bank_address|plain|clear)'"
)
ENVELOPE_SQL = (
    "SELECT count(*) AS total_rows,"
    " count(*) FILTER (WHERE enc_alg <> 'AES-256-GCM') AS bad_alg,"
    " count(*) FILTER (WHERE kms_key_id NOT LIKE 'arn:aws:kms:us-west-1:%') AS bad_key_id,"
    " count(DISTINCT kms_key_id) AS key_ids,"
    " count(*) FILTER (WHERE octet_length(wrapped_key) < 16) AS short_wrapped_key,"
    " count(*) FILTER (WHERE octet_length(ciphertext) < 29) AS short_ciphertext,"
    " count(*) FILTER (WHERE encode(ciphertext, 'hex') ~ '^(..)*(3[0-9]){6}') AS digit_runs,"
    " count(*) FILTER (WHERE substring(ciphertext FROM 13 FOR 2) = '\\x7b22'::bytea) AS json_after_nonce,"
    " count(*) FILTER (WHERE position(convert_to(account_last4, 'UTF8') IN ciphertext) > 0) AS last4_visible"
    " FROM booking.supplier_bank_account"
)
PER_SUPPLIER_SQL = (
    "SELECT s.code, b.status, count(*) AS n FROM booking.supplier_bank_account b"
    " JOIN booking.suppliers s ON s.id = b.supplier_id WHERE s.code = ANY($1::text[])"
    " GROUP BY s.code, b.status ORDER BY s.code, b.status"
)
EXPECTED = {"ciphertext": "bytea", "wrapped_key": "bytea", "kms_key_id": "text", "enc_alg": "text"}


def out(topic, **kv):
    print("SCRIPT " + topic + " " + " ".join(f"{k}={v}" for k, v in kv.items()), flush=True)


async def main(conn):
    async with conn.transaction():
        await conn.execute(f"SET LOCAL ROLE {ROLE}")
        cols = {r["column_name"]: r["data_type"] for r in await conn.fetch(COLUMNS_SQL)}
        plaintext_cols = await conn.fetchval(PLAINTEXT_COLUMNS_SQL)
        env = dict(await conn.fetchrow(ENVELOPE_SQL))
        per = await conn.fetch(PER_SUPPLIER_SQL, list(SUPPLIERS))
    out("columns", count=len(cols), names=",".join(sorted(cols)))
    shape_ok = all(cols.get(k) == v for k, v in EXPECTED.items())
    out("shape", envelope_columns_ok=str(shape_ok).lower(), plaintext_like_columns=plaintext_cols)
    out("envelope", **env)
    for r in per:
        out("supplier", code=r["code"], status=r["status"], rows=r["n"])
    failures = [
        name
        for name, bad in (
            ("shape", not shape_ok),
            ("plaintext_columns", plaintext_cols != 0),
            ("no_rows", env["total_rows"] == 0),
            ("bad_alg", env["bad_alg"] != 0),
            ("bad_key_id", env["bad_key_id"] != 0),
            ("short_wrapped_key", env["short_wrapped_key"] != 0),
            ("short_ciphertext", env["short_ciphertext"] != 0),
            ("digit_runs", env["digit_runs"] != 0),
            ("json_after_nonce", env["json_after_nonce"] != 0),
            ("last4_visible", env["last4_visible"] != 0),
        )
        if bad
    ]
    out("verdict", ciphertext_at_rest=str(not failures).lower(), failed=",".join(failures) or "none")
    return 0 if not failures else 1
