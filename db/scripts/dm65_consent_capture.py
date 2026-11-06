"""DM-6.5 consent capture check (AA-886; AA-1046 after Booking bk-045): consent value, time and source in
tripplanner.customers and in its hand-off to Booking (booking.inbox_events, inquiry.submitted). Read-only; prints
ids, booleans, timestamps and counts only (no name, email or phone).
Query text: AA-Ecosys docs/legal/consent-capture-query.md.

bk-045 (AA-1037, root ADR 0019) dropped the Booking customer master (booking.customers): Booking keeps no traveller
consent of its own any more. The hand-off rows stay under DM-6.6 (personal data redacted after 90 days), so the chain
check reads the unredacted ones only. Consent of an agency's travellers lives in crm.consent (RLS per tenant): the
CRM part of the page, not this master script.
"""

READ_ONLY = True

TEST_EMAIL_PATTERN = "aa886-consent-test%@example.com"

Q1 = """
SELECT 'tripplanner' AS app, 'tripplanner_form' AS source, contact_consent,
       (contact_consent_at IS NOT NULL) AS has_time, count(*) AS n
FROM tripplanner.customers GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4
"""

Q2 = """
SELECT 'tripplanner' AS app,
       count(*) FILTER (WHERE contact_consent AND contact_consent_at IS NULL) AS consent_without_time,
       count(*) FILTER (WHERE NOT contact_consent AND contact_consent_at IS NOT NULL) AS time_without_consent
FROM tripplanner.customers
"""

Q3 = """
SELECT count(DISTINCT t.id) AS tp_customers,
       count(DISTINCT t.id) FILTER (WHERE i.id IS NOT NULL) AS tp_customers_handed_off,
       count(i.id) AS handoffs,
       count(i.id) FILTER (WHERE (i.payload -> 'customer' ->> 'consent')::boolean
                                 IS DISTINCT FROM t.contact_consent) AS value_mismatch,
       count(i.id) FILTER (WHERE (i.payload -> 'customer' ->> 'consent_at')::timestamptz
                                 IS DISTINCT FROM t.contact_consent_at) AS time_mismatch,
       count(i.id) FILTER (WHERE i.source <> 'tripplanner') AS wrong_source
FROM tripplanner.customers t
LEFT JOIN booking.inbox_events i ON i.contract = 'inquiry.submitted' AND i.redacted_at IS NULL
     AND i.payload -> 'customer' ->> 'customer_id' = t.id::text
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
WHERE i.contract = 'inquiry.submitted' AND i.redacted_at IS NULL
  AND lower(i.payload -> 'customer' ->> 'email') LIKE $1
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
