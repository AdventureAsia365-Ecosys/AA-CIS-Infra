"""DM-6.5 consent capture check (AA-886): consent value, time and source in tripplanner.customers and the
Booking master. Read-only; prints ids, booleans, timestamps and counts only (no name, email or phone).
Query text: AA-Ecosys docs/legal/consent-capture-query.md.
"""

READ_ONLY = True

TEST_EMAIL_PATTERN = "aa886-consent-test%@example.com"

Q1 = """
SELECT 'booking' AS app, source, contact_consent, (contact_consent_at IS NOT NULL) AS has_time, count(*) AS n
FROM booking.customers WHERE deleted_at IS NULL GROUP BY 1, 2, 3, 4
UNION ALL
SELECT 'tripplanner', 'tripplanner_form', contact_consent, (contact_consent_at IS NOT NULL), count(*)
FROM tripplanner.customers GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4
"""

Q2 = """
SELECT 'booking' AS app,
       count(*) FILTER (WHERE contact_consent AND contact_consent_at IS NULL) AS consent_without_time,
       count(*) FILTER (WHERE NOT contact_consent AND contact_consent_at IS NOT NULL) AS time_without_consent
FROM booking.customers WHERE deleted_at IS NULL
UNION ALL
SELECT 'tripplanner',
       count(*) FILTER (WHERE contact_consent AND contact_consent_at IS NULL),
       count(*) FILTER (WHERE NOT contact_consent AND contact_consent_at IS NOT NULL)
FROM tripplanner.customers
"""

Q3 = """
SELECT count(DISTINCT t.id) AS tp_customers,
       count(DISTINCT t.id) FILTER (WHERE b.id IS NOT NULL) AS tp_customers_in_booking,
       count(b.id) AS booking_leads,
       count(b.id) FILTER (WHERE b.contact_consent IS DISTINCT FROM t.contact_consent) AS value_mismatch,
       count(b.id) FILTER (WHERE b.contact_consent_at IS DISTINCT FROM t.contact_consent_at) AS time_mismatch,
       count(b.id) FILTER (WHERE b.source <> 'tripplanner_lead') AS wrong_source
FROM tripplanner.customers t
LEFT JOIN booking.customers b ON b.external_ref = t.id::text AND b.deleted_at IS NULL
"""

Q4 = """
SELECT 'tripplanner.customers' AS step, t.id::text AS id, NULL::text AS source,
       t.contact_consent AS consent, t.contact_consent_at AS consent_at, t.created_at AS at
FROM tripplanner.customers t WHERE lower(t.email) LIKE $1
UNION ALL
SELECT 'booking.inbox_events', i.id::text, i.source,
       (i.payload -> 'customer' ->> 'consent')::boolean,
       (i.payload -> 'customer' ->> 'consent_at')::timestamptz, i.received_at
FROM booking.inbox_events i
WHERE i.contract = 'inquiry.submitted' AND lower(i.payload -> 'customer' ->> 'email') LIKE $1
UNION ALL
SELECT 'booking.customers', b.id::text, b.source, b.contact_consent, b.contact_consent_at, b.created_at
FROM booking.customers b WHERE b.deleted_at IS NULL AND lower(b.email) LIKE $1
ORDER BY at
"""


def _line(tag, row):
    print(f"SCRIPT {tag} " + " ".join(f"{k}={row[k]}" for k in row.keys()), flush=True)


async def main(conn):
    for row in await conn.fetch(Q1):
        _line("coverage", row)
    for row in await conn.fetch(Q2):
        _line("integrity", row)
    _line("chain", await conn.fetchrow(Q3))
    rows = await conn.fetch(Q4, TEST_EMAIL_PATTERN)
    print(f"SCRIPT test_inquiry rows={len(rows)}", flush=True)
    for row in rows:
        _line("test_inquiry", row)
