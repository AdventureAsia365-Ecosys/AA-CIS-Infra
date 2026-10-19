"""AA-805 (TripPlanner AI Phase 0), read-only: the DB half of the closing evidence.

Dispatch: DB Migrate, mode=run-script, script=db/scripts/aa805_ai_guards_read.py. Runs as the RDS master (the
master reads tripplanner.* through its tp_owner membership, rl-001). READ_ONLY = True: the session is
default-read-only and the idle check only reports, so it can run while a wave is open.

What it prints (aggregates, ids of catalog components/destinations and statuses only; no narration text, no
customer data, no DSN):

1. Spend cap (TripPlanner config TP_DAILY_SPEND_CAP_USD, default 5.0 USD per UTC day over the online stages
   tp_compose + tp_search_embed; not set on the Lambdas):
     SCRIPT spend day=<d> stage=<s> cost_usd=<x> calls=<n> unpriced_calls=<n>   (llm_spend_daily, last 3 UTC days)
     SCRIPT spend_log day=<d> stage=<s> calls=<n> cost_usd=<x>      (shared.llm_call_log, same days: cross-check)
     SCRIPT spend_today online_usd=<x> cap_usd=5.0 under_cap=<t|f>
2. Narration cache (tripplanner.narration_cache, TTL 168 h):
     SCRIPT cache source=<s> mode=<m> rows=<n> hits=<n> rows_hit=<n> fresh_rows=<n> max_created=<ts> max_last_hit=<ts>
     SCRIPT cache_total rows=<n> hits=<n> rows_hit=<n>
3. Search returns no inactive tours (the 30-query labelled set, run live on the public BFF in S245; the returned
   destination ids are RETURNED_DESTINATIONS below, from root docs/audits/2026-10-20-S245-tp-ai-phase0/
   aa805_search_results.json). The legacy search path (PLACES_SOURCE unset) ranks tripplanner.itinerary_components
   with an embedding and keeps a component only when its source tour is an AA-tenant published_tours row with
   master_status 'active' and deleted_at NULL (TripPlanner backend/browse/search.py ACTIVE_TOUR_SQL). So every
   returned destination must have at least one such component:
     SCRIPT search returned=<n> found=<n> without_active_component=<n>            (expect without_active_component=0)
     SCRIPT search_violation destination=<id> embedded_components=<n>             (one line per violation, if any)
   Negative control: destinations whose embedded components ALL belong to tours that are not active (inactive,
   trashed, soft-deleted, another tenant or no published_tours row). The filter is only proven if such
   destinations exist and none of them was returned:
     SCRIPT control inactive_only_destinations=<n> of_them_returned=<n>           (expect >0 and 0)
     SCRIPT control components embedded=<n> embedded_not_active=<n>
4. Cache-test candidates: components the planner shows (embedded, active tour) whose own tour day has no AA master
   text, so a /narrate over them calls the model and is cacheable (source llm/mixed). Up to 5 component ids each:
     SCRIPT candidates no_structured_text=<n> own_day_missing=<n>
     SCRIPT candidate kind=<k> component=<id>

The master is a member of cis_owner, whose published_tours policy is USING true (CIS 245): it sees every tenant.
The TripPlanner Lambda (role tripplanner) only sees the tenant in app.tenant_id. So the queries name the AA tenant
explicitly AND set app.tenant_id, to read exactly what the Lambda reads.
"""

import hashlib

READ_ONLY = True

AA_TENANT_ID = "00000000-0000-0000-0000-000000000001"  # TripPlanner config.MASTER_CONTENT_TENANT_ID
DAILY_CAP_USD = 5.0  # TripPlanner config.TP_DAILY_SPEND_CAP_USD default (env var not set on the Lambdas)
ONLINE_STAGES = ["tp_compose", "tp_search_embed"]  # TripPlanner llm_gateway.ONLINE_STAGES
CACHE_TTL_HOURS = 168  # TripPlanner config.NARRATION_CACHE_TTL_HOURS default
CANDIDATES_PER_KIND = 5

SPEND_SQL = """
    SELECT day, stage, cost_usd, calls, unpriced_calls
      FROM tripplanner.llm_spend_daily
     WHERE day >= (now() AT TIME ZONE 'UTC')::date - 2
     ORDER BY day, stage
"""

SPEND_LOG_SQL = """
    SELECT (created_at AT TIME ZONE 'UTC')::date AS day, stage, count(*) AS calls,
           COALESCE(sum(cost_usd), 0) AS cost_usd
      FROM shared.llm_call_log
     WHERE stage = ANY($1::text[])
       AND created_at >= ((now() AT TIME ZONE 'UTC')::date - 2)::timestamp AT TIME ZONE 'UTC'
     GROUP BY 1, 2
     ORDER BY 1, 2
"""

SPEND_TODAY_SQL = """
    SELECT COALESCE(sum(cost_usd), 0) AS spent
      FROM tripplanner.llm_spend_daily
     WHERE day = (now() AT TIME ZONE 'UTC')::date AND stage = ANY($1::text[])
"""

CACHE_SQL = """
    SELECT source, mode, count(*) AS rows, COALESCE(sum(hits), 0) AS hits,
           count(*) FILTER (WHERE hits > 0) AS rows_hit,
           count(*) FILTER (WHERE created_at > now() - make_interval(hours => $1::int)) AS fresh_rows,
           max(created_at) AS max_created, max(last_hit_at) AS max_last_hit
      FROM tripplanner.narration_cache
     GROUP BY source, mode
     ORDER BY source, mode
"""

# A component counts as live exactly when search.py ACTIVE_TOUR_SQL keeps it, read as the AA tenant.
ACTIVE_COMPONENT = """
    c.embedding IS NOT NULL
    AND EXISTS (SELECT 1 FROM gold_aa_internal.published_tours pt
                 WHERE pt.tour_id::text = c.source_tour_id
                   AND pt.tenant_id = $1::uuid
                   AND pt.master_status = 'active'
                   AND pt.deleted_at IS NULL)
"""

SEARCH_SQL = f"""
    SELECT r.id AS destination_id,
           (d.id IS NOT NULL) AS found,
           (SELECT count(*) FROM tripplanner.itinerary_components c
             WHERE c.destination_id = r.id AND c.embedding IS NOT NULL) AS embedded_components,
           EXISTS (SELECT 1 FROM tripplanner.itinerary_components c
                    WHERE c.destination_id = r.id AND {ACTIVE_COMPONENT}) AS has_active_component
      FROM unnest($2::uuid[]) AS r(id)
      LEFT JOIN shared.destinations d ON d.id = r.id
"""

CONTROL_SQL = f"""
    WITH per_dest AS (
        SELECT c.destination_id,
               bool_or({ACTIVE_COMPONENT}) AS any_active
          FROM tripplanner.itinerary_components c
         WHERE c.embedding IS NOT NULL
         GROUP BY c.destination_id)
    SELECT count(*) FILTER (WHERE NOT any_active) AS inactive_only,
           count(*) FILTER (WHERE NOT any_active AND destination_id = ANY($2::uuid[])) AS inactive_only_returned
      FROM per_dest
"""

COMPONENTS_SQL = f"""
    SELECT count(*) FILTER (WHERE c.embedding IS NOT NULL) AS embedded,
           count(*) FILTER (WHERE c.embedding IS NOT NULL AND NOT ({ACTIVE_COMPONENT})) AS embedded_not_active
      FROM tripplanner.itinerary_components c
"""

# TripPlanner master_content.parse_days: a day header is "Day N" + ':' / '-' / en dash / em dash at a line start.
_HEADER = "(^|\\n)[[:space:]]*day[[:space:]]*"
_SEP = "[[:space:]]*[:\\u2013\\u2014-]"

CANDIDATES_SQL = f"""
    WITH live AS (
        SELECT c.id, c.name, c.source_day_index, pt.aa_itineraries AS txt
          FROM tripplanner.itinerary_components c
          JOIN gold_aa_internal.published_tours pt
            ON pt.tour_id::text = c.source_tour_id AND pt.tenant_id = $1::uuid
           AND pt.master_status = 'active' AND pt.deleted_at IS NULL
         WHERE c.embedding IS NOT NULL),
    kinds AS (
        SELECT id,
               CASE WHEN txt IS NULL OR txt !~* '{_HEADER}[0-9]{{1,2}}{_SEP}' THEN 'no_structured_text'
                    WHEN txt !~* ('{_HEADER}0?' || source_day_index::text || '{_SEP}')
                     AND strpos(lower(txt), lower(name)) = 0 THEN 'own_day_missing'
               END AS kind
          FROM live)
    SELECT kind, count(*) AS n,
           (array_agg(id::text ORDER BY id))[1:{CANDIDATES_PER_KIND}] AS sample
      FROM kinds
     WHERE kind IS NOT NULL
     GROUP BY kind
"""

# 725 distinct destination ids returned by the 30 queries (S245 run 2026-10-19 23:32-23:34 UTC).
RETURNED_DESTINATIONS = """
00b4da70-ab72-4219-9f92-01fc33591025 011bccd5-a995-40d9-9de1-040d2b1184f6 014b0962-f93c-4d43-ae0e-86a1550ad699
02b862b3-bef9-4999-8acb-27eb73a59aa1 02fb252d-2675-4fbe-8155-1263a3dccd39 03536e1d-312b-4e85-961d-c1be1707bd86
0367b381-73b0-4939-89d9-7cabe10b3655 038803d7-f5d0-4d4d-af33-813c660c552d 03d9f045-e429-40af-a216-f11e0d595174
04018024-aa05-4df5-a247-f5d624687156 0444c960-09d4-4330-924f-862ec1e30011 04996def-4be9-4b13-92c1-5565950292cf
052f353a-0e04-45c1-9b39-f2a2f856a3d1 0560a95c-758c-4244-a507-cf01f2339fd1 05eb2095-0dcb-49ae-895c-ad3ae0d983c1
081384fb-adb2-48ac-bb0a-be7da4a5cf58 08c37be6-93c5-4e50-80c5-a13e00a0b191 08e840fc-1777-4c69-b578-5b6b34057bcb
090c2606-6145-42ca-b588-f73e84f64bcd 09226931-a12c-490d-a005-c0d85afc4ef8 09f453e4-eed4-4742-b49a-3f79ea650afe
0a866ac1-72e5-4045-9082-b3f448dd6989 0a8760e1-6ea8-4065-970c-6acc97dad19f 0ad7a832-213f-45ed-b612-a75cfec05f2e
0ae7dddd-0a28-4242-b150-ca577d7aade9 0c6684cf-1372-442f-8e58-b1d4f5f53cc1 0c668d22-fee6-4198-90e7-1f457108a3f5
0ce0ad8a-18cd-4f60-9ff1-5829990eee96 0d2205d3-525f-46d2-9f0f-ec7a6463212d 0d73faab-db55-4934-9d83-994d4ae3178d
0d874f06-e425-402d-b4ae-bba1dcca7150 0e152e68-0437-459c-9bd7-f6ea6cb8515b 0e4b16a6-805a-4c2c-ae1f-72d51e9576b5
0e53d7cf-9638-49aa-9e89-c0c93f20fdd2 0f85068e-d849-406c-8544-73d362147f7a 0fc0ee17-1d46-4072-9d41-3288775236b3
0fc2f5b2-28bb-42f1-af40-f65147e34ebf 0fcecec1-6021-4db3-bbcb-c2281ffd04fe 10201aa6-6cc0-4a52-95a7-75bc9da3692d
1119f662-f26b-4ed4-8543-2a8ffa95825a 118dea50-0b71-48d9-bb5a-e474e3c9eab2 11d9029b-06f1-487a-a3e8-8458e035d6a3
11d99185-8a62-41c0-b2a7-9235f8e75b01 1207cb04-9996-48d5-85fe-29a2d9f125f9 13982a99-3d4e-4faf-ae45-93895a2a2d84
15a1f88c-e7e3-43fb-a55a-cf596b17263b 15b81c18-7ea6-45a7-83f8-bc7c9962f2f4 1659e286-9b3d-4668-9fb3-10f35c78d792
16d72e60-ca2d-4ab0-bc33-34e1caee257b 16e04dbf-9a06-454f-800d-c46447651fd0 16f4dfa4-0f80-48f5-af7c-93e64752cb29
172d4f06-c1b5-4db1-a402-49f264b94ee3 1765c8de-4736-4489-91ac-bead8094bfa6 1777d024-c6ea-4f05-a667-b5d342b6723a
1808eace-2afe-4d23-b8ee-6c6b8fc97771 1828293c-cb17-4a61-b433-74b5d9e5b339 18580e2e-e46b-4752-ada0-acd93191af98
188f20f3-83c4-418c-9194-760f4679d654 18d8d522-c0bc-459e-94b4-5eab2c038cd1 19cb9bf6-bf31-44ce-bb98-0d7311f99968
1adc86d7-cecb-4291-bbd1-027320f889a4 1b25f236-9efe-4780-8588-97759d0d7c29 1b761ec6-5101-4056-90ab-2a3a21a596d7
1c45fc18-0a43-4cb1-8ba6-212c4f0eb0ed 1c68217c-e3ff-48be-9db9-e619458ce4f9 1ca06f8f-7611-4255-b923-22d1f93a4390
1cc4769a-7cde-4980-bd4a-b75d5fe4ef55 1d035abc-c6c3-455e-bc1e-db3164d2ca78 1d172bb6-2685-4cb0-bd1a-3e47bdd891bf
1d82812d-a4c9-4364-a26f-3df23519e57f 1d877553-5a4a-4ce5-af73-07f12306ef2a 1db86416-06a1-4412-9dcb-c0397b3a480f
1e52e9eb-499b-46c9-ba71-67d7a7bbc1ca 1e678954-7262-431c-91b1-460c5d8e43f9 1e8f42a4-c09c-4e26-b99d-b92d78a44faf
1eba53fe-e49a-450c-a2c7-0201e61cf299 1ed93123-8d79-4612-9c82-fac04f1bc36f 1ff69bad-c0a6-4911-84dd-7a9269a40594
201b4785-39bf-4406-be60-5cadf950a7e4 203b0941-eb77-4b21-bb46-2267ae17fefd 20c2f7dd-c1b3-4d6e-a15b-8f1ff9ad40de
20daeb36-6b74-48d3-9ffe-3c69e6f13d7c 20f1d687-7db4-4672-b559-f0da34f53970 213f3f68-6df9-43c9-bb1e-f8ddf722b178
217ec3be-4ef7-4887-9d40-5e8710b2f5d2 21a1463f-84b8-4461-a3cd-8d0f654af090 21bb2825-e7e4-4f26-a912-170b09bd151f
226eff10-c174-40a7-a8e1-b88bc9fecd5e 23b893c9-3378-4aa3-9b04-cd434b5abfae 24356559-ca80-47c6-866a-2660b7d503e2
243f3638-774f-4f0b-83df-b2496940dfa6 2451616b-63db-4036-afe4-89bb5b542201 248201a1-4446-4bf3-80ef-131d421374a1
250e2a46-566b-4441-a30b-3ea6a2b7817e 2511d3a2-cbfb-478b-a113-4b02959301f7 252bc909-42ad-45bf-86db-dde1c11067d3
2584155f-9aab-43ce-a387-cee33db61e82 2592518c-ba75-4b99-8a81-750126cdb27f 25ac6525-aac5-4972-8910-4e79f652429a
25bad288-e144-4c99-90ef-ede1033615fa 26022a2c-bdb9-4407-8f67-5c58e03e7cd1 27e2b556-da8a-4c49-a0a7-c6e39bd93ca3
28110392-c2db-44b2-96b6-8e9050913947 282b4f82-462f-41ac-8a5e-3e6467c2d449 296716fc-2a39-4f11-8b1d-9242fc8e1f93
29932685-ecd5-49e3-a00f-b38e4a15f87b 29e51668-47a6-44ef-a984-fe7bbb43198e 2a5b8df3-5212-41ae-8f63-76986418c075
2a728293-deb1-48aa-abe0-d42e9885c552 2b106c5d-4477-417a-bfd9-b84c8603de08 2b6c258c-249d-4272-96b3-eee6ea328c13
2bda62f6-87b3-447a-ad03-46c4250fe567 2be3ec87-2b22-45d9-b81d-6049ceb3134a 2be5ee0a-a845-42be-86c6-2f793f2a3b14
2cde526f-17fc-4173-868f-504449a82cc3 2d625a45-78c7-433a-8ec4-2597b77f08f1 2d87d09f-b4b3-4e39-ad0e-c6af2fee140f
2dc10867-2c27-4768-aeec-e4f3a1accfe4 2dd1d81a-11d8-436e-a80d-c3cc22230c08 2e0c0232-8ddb-4922-a442-28a678631606
2e8114cf-3e3f-423d-be10-3f5285a03b5e 2eb66c88-cc78-433e-bfe7-310607334fb0 2ee1f437-5c91-4087-a88e-5e70aae2e828
2f2f3556-637d-4f6f-9288-0d31b35e210b 2f546cd3-6d0b-45af-aa2d-22087ba3aad3 309d27e9-6bc0-44d8-9f0b-0e98e88c0be5
309ed607-315d-4944-af0d-020e39d60ff4 30c9fdd8-6da9-47e0-90c2-bf4fc1db64c3 30da9446-fe60-4cc0-bc42-2880625ae3e6
31438eb3-b35f-45a2-8961-209027707558 319f7ece-5a2b-4699-ac80-b35237404417 31e7e229-2a94-4206-a8ba-e37ec00535ca
32c4b146-06df-4aa4-add5-54d008055845 334ca416-865a-401e-a925-bbe4e003c08b 335aa466-aa4c-4d76-bb8f-42d4d2047068
33678e96-4dce-4787-a458-b5390aa4cfec 346b93ca-2e4f-45c6-810e-dd1e6dfaf76e 3471afd5-0594-4f0c-b7e2-3554f552c682
34794d58-0f9c-4954-850f-a956d5d9192b 3491970e-b28c-4db0-b8db-f6e5401db2b3 35605b9f-0a28-42a4-9220-2bd47da72dc5
35a3b4a3-a9af-4597-adef-94fcc75d0979 363f4717-5f32-4224-ba1e-c729e05ad8e2 36430a4b-ed11-4fd2-bea4-6e687b1ee2e2
3652c0ca-1242-4d82-bada-fc1467fa730d 36ac7069-d674-40ca-93aa-cc85c9c2f92a 36ba69be-5c1a-48f8-9f70-18d26f782ba2
36bb1451-0008-4e17-840f-6b0ad9078a6f 37224b40-0d93-43dc-838a-ef1826abaa12 37a3133c-e4f8-4477-b527-5ad66e814a93
37f7fd2f-aa98-4a32-ac8a-6bf381b0154e 38b01372-cc72-4d75-90d0-9d29746ca420 38b0e88c-a654-4aef-9253-2831b1e5e27a
398cc44d-9364-497c-ad10-cc9c42f25184 3a051f4a-2e3f-4894-84c1-6270d3abff3e 3a94f3b5-6a54-4571-8299-a38ed3eaadde
3aaabc09-369e-4a1a-88fb-e36df2fb185f 3ab6b23c-b0e9-4654-b9e8-dccd3ed45d67 3afb92c7-c6f5-4849-8cff-66e16a2b3164
3bdd70e3-b9a6-458e-a345-419512767ad0 3eb5f768-beb1-42fa-bfe8-e4b29e99e36a 3edcfbee-6380-4c61-bebd-d71f22a10a8a
3f07f785-d829-4936-ade3-62301b69187e 3f24fe1f-a831-4e4f-9e1b-2d0bf5eec127 3ff5000d-b803-4069-b96a-283ce26bc168
40012de7-df80-4fa5-82af-df329dac433e 4008c151-ffdc-4b6b-b318-6d3bd3635082 40443931-be26-4298-95d9-461507b22bce
4188baa8-9b1e-4525-9e8d-a34a979da0b9 424250f5-cd55-4b58-aa25-21fa9faaadca 42910316-6e5f-4300-9b3e-11f8c4cb5d45
42cd8d5a-c6ea-4682-a510-c030fe73c31a 4355d344-802d-4d96-9159-bd8cb7eeb4b5 435be0c2-0559-4e16-a4df-55da9af39d9d
43756d16-4653-489f-a4ba-6ab5e75212f0 438bc34b-ff78-472c-8369-3f4afd9f74ed 43cc5a23-7e13-4a2a-af84-76d4be7fb3e4
43dd131b-8904-45d7-8f42-3fda898e89ee 43df60eb-086b-464d-8e26-26e23634ac17 43f64bcf-b891-4b95-848b-c8cfb771bb14
44180c06-03ad-47f1-a01c-8d5e81712bf9 4466462c-2f76-4c69-a687-8505b6b9698c 4565213c-6400-4b46-b32c-997c2f4771ca
457ec9cb-5629-42aa-be72-3f07952230d1 4649fcd4-9d20-4439-9743-4da995c210c0 46ed1201-bd3f-45c9-8e1f-689bfbc7bdc1
46fed5ac-2ce0-4244-acc2-f42ea06115a9 4704371e-5c52-4dde-a497-55d8534ff7f7 470a933f-fc27-4c92-9c01-7e12fdef3356
474f3a16-e1b4-4d38-ad60-ade3ecc10ed2 47792829-c03d-42f3-a0b4-bdeed9ddfc6f 4795189f-59da-4644-8ff3-b205442ed97e
47d65837-5f30-4757-9575-6385d1a86e22 47e85a1b-a968-4dff-aba6-1c4f6ab85b58 483c973d-6da2-477c-babc-cd8369d20201
48d7d2a8-a5ec-4fcf-9058-ab5fe59bd08a 48fe44ca-0a16-4296-b5aa-0e6945faff48 492d7409-6719-47ef-884e-3a6e6ec803e3
4931a722-ccf2-4cff-90b4-77734672ca8a 49627ef7-b221-4118-bc9f-d8a31e79001b 4aa344ba-097b-4bd9-b145-44bd53e2d7fc
4b343851-75af-41f9-8500-b37a9a6cb28f 4c122e0d-641a-4b1e-8265-febd5648aba1 4c18545f-d51b-4356-95dc-34cf484f46e8
4c2e2075-f05d-4690-a749-ad83ce873d42 4c5bc429-e037-4968-abb6-19f0cb690088 4c6b95b4-6085-40ae-b7cf-80b2ae90d6f0
4cb64812-49b1-4ed1-a671-ec93f2e84de6 4cef831b-1225-41ed-82a4-812b94e818cf 4d149a31-c0d5-409f-8643-747bbb51225f
4d158557-a958-4e42-bcd0-80e8623378da 4d40ad49-e77a-4f76-aa0d-19a195ea4278 4e713a4c-8c12-44d6-8a40-23e35068c292
4e8b3482-d144-42a1-8633-64bf780d968a 4e8d3050-42dc-4cc9-8fca-d863d1d43080 4fbf08e3-3b4d-4d36-91e8-9d652a23cb18
5050d61e-f18f-4b4f-bb66-89378e2f0f26 505db49f-e315-43d8-9f84-a3c472a2ec2c 50bb6c00-ee2d-48fb-8541-b9ce67ee5f6c
512b328e-6972-48fc-9a33-5dbd1c609d03 518f62c3-dc1e-46c8-bfe3-e717af730420 527b91ea-ce13-4ff1-8562-9bdc6116dde6
52bfb740-19fb-4c66-bfd3-ac075c6ba148 53e4443f-3862-4e61-aa27-9e9f2d8bf671 54798246-c066-4326-86e1-46bb8aab0740
54c90083-e95b-49a4-aaab-33522ed25bc9 557bc41e-73ae-4470-87e7-91ce00f25613 559a9eb9-d5fc-4f24-b49b-7dab9c59de2a
55c18fc4-d6e2-463b-920a-a2f50c609173 576c4960-c56c-4b0e-8d79-03e84c49b5cb 57b7c75f-140d-49ad-b216-f396ba8dabcb
57d917e2-1772-496f-8675-6450495d7d8b 587c3504-75d2-4203-96c4-eba3ffc7c7bb 589fb851-ab44-46e0-9cfa-042ba0a73e73
58db9cb9-415a-48f3-994e-a0797ddbf5d9 5990d6d1-d0e6-4dbe-bd67-684f466df9f2 59ad9c4a-53ef-4691-b61d-a118fa4aaf96
59c70a65-e69a-470c-b986-711f2fe00897 59f0d5af-836e-4ebb-89e0-7ffbdb6b9706 5a0be664-1795-418a-8308-762bd147a0f7
5a3b58b3-c66c-4939-b5a3-7197c0d6631c 5a9ae372-7ab5-4374-a6cb-e00c567ce9a2 5acace31-57a7-45bd-a549-6ba102f74bc4
5afe4fcf-9ec0-4439-bf5a-7e08b8d6673d 5bdaf8c7-a61b-4a66-94ca-8054f4475500 5c09b5a5-1ab8-41ed-a8cf-3f6182225d3e
5c1f1060-ee67-4900-8d72-a69bf43ff653 5c41eb3e-508f-4beb-9a79-2e702ecc4fd5 5cceac16-6d3d-4d34-b9ab-710e860f6461
5d4eabc0-c0fb-44a9-8c34-0b1a3c5f64a6 5d735e79-8f02-47bb-af46-613c9acb0cfc 5e47179e-1c6a-4c29-9e78-f2ee32496db2
5f3b86d0-1647-4ef8-8473-ca8c1f897ea0 5fcc3948-8b7c-4c9d-a58c-40fc562076eb 60081905-6b72-48d4-8f7b-5cbdf1634f4d
605067c0-6c7a-4b3a-ad13-02d4e2644d44 6082a6c3-9a6c-41d4-ad8d-60295204dedb 609be705-546b-415f-b809-5047725d94ee
6157993c-d199-4e94-85af-b7d2d716f169 61e0d302-1fd2-457c-a074-aa337929ecc5 626051ac-4e90-4e6d-8bcb-a5896b9c0f06
62772375-65d3-4a9f-9ac1-33849e712a69 6277748c-ed19-49b2-98e3-56a1b50cc91e 62def251-075e-41c2-afc6-51b8713ec2d2
62ebf83d-9ccf-432a-b0d0-c80956f490cb 631e754d-8f5a-43f2-8049-153f30b939db 6339eb1c-1d96-4c2e-9d1a-6d5bc841563d
63ff6322-bf36-4f61-a2aa-98369e923b4f 64b37272-bb86-46fe-99a0-deb3ed14807e 64d60df0-bec8-4b02-9531-1e9781440148
659b5fed-559e-4a00-ad61-3d8a2541bbf6 65cbb5ed-4ca6-46c2-bacd-18c3527b5169 65d115d3-8062-44bd-b0e7-56b876155924
66401a5a-c060-4e64-b748-cddd1ea42ad8 6693ac97-b414-4c29-a898-42ee0aa66ddc 669601aa-bc39-4341-a1ea-065a14a2418d
66d9f932-4f26-4507-9fc7-98356df8ee4b 67185505-e59e-4322-9910-b46d6cc8ac3a 67945272-461c-47c0-b782-895ca409081b
67a2c657-70d0-47c6-9d28-fb9800e01543 680b31cb-ea7d-4db9-b8a0-38490d9d7382 682f9416-3204-4b83-8dc0-9b4647ec0026
687b1e5c-25b6-45ed-9b68-57f3761aadba 689b8c95-2fb0-4f3d-b4ec-690e61a09679 68a3803b-84b8-4bf6-a592-d8db6224dc21
68f5e636-b9ca-4d99-8d52-582326cd40ce 6988cca3-6eaf-402e-9e93-658d6164d4bd 6a2ba1ab-3363-432c-8cd5-dc4eb3269d02
6af33c2e-e141-48e3-b8bc-53d7b9b584ee 6b9af4f0-5655-42c9-9696-8c89c2e3d490 6bbd1507-bde7-41a1-9f06-6b96ad9c9158
6be86d5a-470f-4a72-b097-1eb6a87e43f5 6bf9c2b3-bf59-40a4-8718-151536c2fe87 6c195f9c-68b8-4fe6-b4f5-b0b89a7d8275
6c30fc1f-2c15-4371-8ad8-cc9c99d670c9 6c8885bd-d72f-4e4f-8658-cc56d9def40e 6ceb432b-e96c-4986-ba3b-760fe7d0ace8
6d0bbbb3-1f1d-4dc7-ac91-1260f20268b6 6d2c4960-1bcf-4102-9da2-31b876ff1a1c 6e509d54-4162-4911-8618-b04e016b001f
6e640bca-1c04-47d6-91c4-999bd545454b 6e8fb609-2d3f-49e3-aba3-49f10893f821 6ed7918f-f824-4b92-a9a9-a97876a67386
6f4164d0-5bcc-4c07-b3bc-7e491e6808ff 6f6594b9-9425-44b7-8a27-ce59a3d70ed8 6f6a9edd-a12a-4730-84e6-68e4f94e67cc
6fb5140a-036b-4464-827a-2042c5db654d 70314126-d7bf-490b-9f6b-bfe0bece9590 70930247-6aab-4234-bfae-18b2cc5a6783
70b4d3b8-bdce-4405-81e4-c816bc69a9b7 72121d1d-8761-49b0-b0fd-a33eaefad127 72bae2ad-a44e-4da5-ac33-f325aced48fb
72cd4ab4-23cd-4f49-8a72-76457076c088 735acb0e-9baf-4bb3-88e7-eaf1aa203365 7495a77e-2db9-41b1-a41c-4324c47a8dcd
75a8e124-10eb-4f51-9940-1438e8421b8b 75c15d48-a2c8-4ee7-842c-6c4160912885 75dc2135-c475-4258-a029-5e3318163869
760698dc-1406-46c3-afb5-31ca3d52dc93 7638da6d-d090-4690-8283-6bb022eaa38d 76611932-be2e-40c5-b4c1-c69703417078
7735d2e1-cc7d-433c-bb39-bdf73640838c 77594733-180b-4f1c-a280-51333f278d6a 77b66d27-b187-4c3f-bfb4-9735664f95f0
786c5cf3-94ba-485a-b737-06fb3e1cd7b8 787ccd01-e8bf-485b-b271-a9fd5fffd0b6 78c2ef89-87ef-4069-9456-ad7544da2e98
78c57f0f-62cf-49bb-b798-6888f1171a94 79821b20-711e-476f-b38c-c5b5c74dc1f0 7997a67e-3905-4cd5-b741-2febec50fe73
799a111a-00c8-42c4-ad81-a1d2b424379c 79db47c7-dfca-431a-aaf1-c7a526ee18b4 7a397d64-26d8-4ce8-aa4d-dc1d279ff5de
7a8c3c62-e546-425f-bc2f-9054b03c9041 7a9b742f-45df-446e-be09-74c98ca8ca6a 7bab0482-7b0f-4fb7-a0e5-beba91e057df
7bc55fbd-76f1-4ba9-ae91-f006efa78fe4 7bf97db0-0333-4c7a-907b-d4f408aa78e5 7bf9d55e-9179-4ca8-b4c3-7769f9fb63a1
7c1be208-e5a2-4699-9fc0-0d00d3b42592 7c1d6d42-b58c-4c8d-9a06-3baa61e61652 7c236efa-205a-430b-9cba-a1de31feb0cb
7c2c3631-d9b8-47ba-ba8e-5c3519fa316b 7c53bade-5182-479b-88b2-db2c3c598bd2 7cbcccc8-a41a-47b2-84bb-2ff1903bb737
7cf16677-4d22-416e-bdbf-34245a790558 7d65882c-e993-4a3f-8669-9cb76b230dc2 7d993507-5de5-4af9-bfa2-84df6ea593b2
7ddb2c68-46d8-44ad-bf49-c34ff743c79a 7de5ceea-8bf7-40e4-8b8e-9cbe8baa6782 7e02a956-5d73-4b77-b6de-64d898c5a3d9
7e5a7cbe-812c-4475-81cf-8da7caa5fe45 7ec193de-3120-47da-b985-6ccd8deefa31 7f28f107-bf99-46c6-87a7-b72590f81e2b
7f2e0894-5ca8-4969-8e30-7e1729b828db 7f4867b3-656e-4925-8c2c-bd4325ab9979 7f522358-39ec-457c-b2b2-329862e9f943
7fb592a9-1a61-4af4-aed1-1159809642ed 7fc16bde-1a19-4ed5-9737-efb5d5bfea10 7fe8f795-8386-4f82-b6af-541ca53bb823
8031a0c5-5b0c-4da0-a6b5-87738b0d923a 8033cf59-99d6-471f-b944-8b4cf2b84dd4 8037bee1-8f2e-4f6d-a8cf-38bcf72d442c
80711b51-111b-4255-8e3d-50f608358a5e 808c5d4c-2b8a-4ba2-9c5a-813751da6c00 80d10cdf-41f9-4e63-a77f-81689619fe9e
81126be4-4adb-42cc-9053-35b20a1eea60 81f3a0b5-eac0-49ad-a496-793cb04ad819 82344100-ce98-4420-8502-d1ca59faac63
830aa3ea-4cfd-4ae5-859e-4dffc61e4afc 8313f53a-1597-463e-b761-316df4f8969f 833e0824-66f8-43f2-9f15-ee362c818230
8392d3e5-eaef-4367-b3e4-7a232630f760 865a0f6f-20ca-4837-babe-2435cff4aa26 884bd069-877a-408a-a2ea-fe0057df38ca
88555269-1c3e-405c-9918-46a8188b2a7d 88634fc3-3369-452a-962d-74bab0e6324f 88842fb5-9f8f-4b2d-b327-1343650a371d
892f124f-3659-4482-b33e-66fe2ba133ee 8989dfc7-4bf3-4e99-af08-0bc20ae2ec52 8a210a4d-0ae3-43eb-be0b-11669e46ef65
8a45a4d3-eb4d-419d-94f6-5e637842a7cd 8b2f8444-203d-4d92-b49c-22f1971ea4bd 8b408ab5-3dbc-4999-8d91-26a00bb636d0
8b66f33b-7509-45a7-80b6-91ce83777974 8b73966f-8537-44e3-8d38-1924019b2aa1 8bc3cc4c-8d70-409d-8930-08f6f642f787
8c92a176-a85b-4bbf-b46a-81324b12c763 8c9785d0-e6c6-494b-8cf0-cb63df2b64c4 8d0dbed8-9056-459e-8342-9e55c01333e3
8d351ff4-adca-4fb0-9c1f-74e574b8c77b 8db4f15e-ce5b-4545-bcd1-563168f23fda 8dda3088-6c23-41ae-8d70-5ef04c420d59
8de7ec9a-5673-4c3d-9e55-dadcfdda4f74 8e1123db-47dc-473a-b9dc-c4850f7209d7 8eac95e1-4cf3-44a2-97bd-c3dd0bb39721
8f0044ea-b604-4953-87d8-3471bfbda8cd 8f52e372-7a1d-47eb-bbc4-bc81f9ea0d57 901ea932-0c10-4b76-9131-bbeb89068d1e
909065dd-b35e-4d1a-a78f-742cbc52e28d 909661e4-c8ec-4636-8301-17aee13ee5fb 90b13794-b559-46dc-830f-c18f1effb2ed
90deccb3-f3b9-4afb-a957-0f31cf87a0af 91c14d05-c707-4e39-87b8-cc40ca55a1bb 91d464d6-9f53-4aff-802e-86725d458f1e
922452c3-3835-4c41-855c-cca3dce3d00a 92bebf2b-7dbb-490e-932a-2d1b71935900 92e01b96-b79b-43bf-904a-ce69a80a87a5
92f16c25-86a3-4fae-bba6-bde24270dcad 939b0473-cbb7-4ab7-b106-1a4879061055 93d9f509-b76d-4293-982b-1b049a70e5ff
93f4abdd-fbf0-41b6-8b00-b8fdfd0ca215 9442c2dc-6f30-43b7-a029-2e18fde96087 9457790c-f319-48f3-80cb-6c84c0252492
949b04c7-d0e0-42d6-9546-4ae52f6626cb 94d83212-81e3-45b7-a61e-83de878b7214 95bd0e78-7799-4be1-8aee-61befc6276da
965d87c8-a499-4c99-8478-57fad6507d58 9671f8ba-650b-40f2-b18e-d02a91b81f96 96dc302a-8e88-4c39-b4a8-322062a88bb2
9726e166-974f-43a5-b819-225993ec1069 97408445-0f61-49d9-8deb-f1465b045a8d 979ef69b-43c7-4ff4-b173-55f9f4de164d
97bbc5b1-5528-4af7-bd34-d0b4df8b2382 982b2cdf-b419-4187-be77-05b051b10170 984761ae-a89b-4649-a322-34711caf7fd4
98a9eebc-1d3d-46cd-ade0-1fa687953c4c 98f0f8be-f255-48d4-902e-a3ef681d79f6 991326c1-ba45-4fe4-ac62-cdf34fe9c9ec
992706a3-1ba1-4cd3-b377-997face1f740 992e7c77-0755-4ea0-9cb9-ea511cfa2cfc 99cf5698-0429-41fb-a9eb-4e923ddb70ed
99fe8e5f-f186-4e59-ad39-e860cb4115fc 9a70bf78-8f8e-421d-85b0-56f4e0be3d67 9a97fbb6-4aab-4b8f-baf9-061dc7b8bf76
9aac7b5c-90c5-4d83-9199-d574a1ffa39e 9adb5a8a-8d34-447b-8615-ef36bfeb44ed 9af9f150-5e46-4746-8899-44af77403239
9b0f441f-cfb3-4756-be73-fa7c50880e14 9b505ebf-44ba-4dcc-ab5d-972ca979f726 9b5aab4c-7a2f-47cf-9e1b-321c8ca3dfeb
9bd08e7a-7a29-4656-a48f-0c8c022979fb 9c0fe029-f3a2-4f40-a062-fa5030173bf9 9c5c80cc-a5d0-4fe8-8456-f303d5e4b182
9cbce230-2e31-4f96-8471-8707df3d55da 9d5e454b-f6e4-44c8-88ad-26afebe9a4a6 9d8974de-8e7d-42f1-a63f-00c5c5413c10
9da51ff5-b609-4a62-9fd1-cb88a4b285a8 9dd11e4b-7017-4000-9785-a7132aed74c0 9e5dd946-6f2d-4624-8304-7fac6a1c9c5e
9f20ea31-1c72-46d5-9125-a8a38b22a482 9f2562f7-fe4f-4f44-98ad-cb2125ffadfd a01d1a95-69ab-4c1e-bdc1-440ee704ced1
a0445087-9b2e-4c2e-b5ba-ed329b95b9ff a18e2deb-6bf6-4811-8685-ffed5fd4f707 a18fd876-851c-4adb-b762-8724c1dc21d0
a213cca5-b186-45ea-bfa1-97b27c67ed3d a238b4c9-f442-44f9-a80c-3725a3bf4b1e a2586c69-af7d-4366-8f04-4adcd624e2c2
a29f34f9-131c-4b48-8631-b093d9b2066f a2a954ca-4dd2-4981-adc7-760a1d5b0fd2 a2f93822-440d-4dfa-bc30-2176aa233a9b
a2fbf087-9ca8-463f-ba1e-a05e42bc04dc a329a552-4bc5-49a0-8bad-5b8017bdffab a3badb34-07c5-48a6-a0e4-92e107cb533f
a57d645a-1d81-4314-94c3-7e6159b86329 a6464a57-989e-4b41-a2da-234c9bd24d84 a6574ba8-7a4a-45e7-9c6a-da4fb7c068d4
a73bbb43-4b35-4fa6-9fb3-b43a4f9ff88a a7d3f607-5351-4e65-ac3b-ab645287537c a7e9765c-1ba6-483b-b13c-37dd23e172f0
a8026069-abea-42fa-b21b-8f372787b9b2 a8e346d6-86c9-4e5a-97e3-10df3234cadd a92663ad-04b1-41b2-bc87-a772c2bec183
a9c7d285-725c-46af-af08-73d92c4e5646 a9cb1a49-0cf3-44d2-bdc8-86047ec8c188 ab7eec7e-deac-4d8a-a259-793e3d7fbb92
ac14a550-a346-4c2e-a376-e25a195b8dda ac435bfb-97dc-4fa9-baf0-1f92d34eb659 ad00c9b5-b892-4321-bf09-bdb163380069
ad4396ae-58e8-435c-ba8e-e7fc254adf35 adee816f-dee0-4a05-be13-3bc9c38a3a3a ae13e2ff-b6e6-4f73-a539-0d6f1097ab79
ae58b8da-b931-456a-9c72-b64a0c63315b ae8a02e9-262e-4063-b1dd-7dd7f8bbb5c1 aec3564c-2b83-4de4-abb5-3dc8ae56344e
affa289e-ae4e-4e6b-ac94-55afdde7c90b b0101d53-3a38-4acd-8087-2aad32ec5e79 b0b8d6e4-93d8-4c4b-a022-4ff570c71528
b149e7f5-8a0a-4d9b-b2f7-933451f6b4a8 b173dcc9-01ab-45fe-903c-85f974ad0f6b b2202205-d57f-4a93-90ab-b8a3f5dde072
b252add7-3cec-41f1-aee8-4c52acc6b01e b29e415f-fe51-4e92-ae60-c8196002a924 b2e112ab-158f-44c1-9320-e99972db83dc
b38a0ff7-a8fa-45ed-a4ad-fdbbe72eb7b7 b4180406-cf17-42bd-98ad-6b083be94938 b4ac117c-f2ad-49d4-88ad-f1dc1819a155
b4b6cc34-84e8-4901-a35b-4d4e6e047d38 b4bac36c-f99f-4804-9aa1-960c58f5b04d b606dc39-1dcb-483d-a636-443fa3ca8d72
b690cd5f-7c86-47b6-a9da-985e2211cfc7 b6a8dc47-9b10-4439-aa74-bb4712180cff b6febf2c-1443-4e98-8fa6-39f18945f684
b7a7e765-04cc-40de-ae6b-62bae3033faf b7a9947a-6cb2-43c3-b04e-c324fc770bf9 b8096db2-8726-4b3a-9a58-5fb6a468fd71
b8574710-9f6d-49cb-93d8-063f24e6d01d b93feca4-43f4-4849-af99-3f3dc8a837db b9c1f71a-a8e0-4b07-83d1-85f6bb63ebce
b9ddb34a-7d2e-477c-8f3c-33408692e14d ba03e65f-18e0-4700-a41d-bacc6cc36e65 ba69d8b3-8572-4e73-ab25-421f3d3f1838
baac6fa9-413f-438f-a68a-37c118483dbb bab88cb7-c709-4165-826c-d415848b77c0 bbbaa12e-12b0-4f7a-aac9-ca13faa44648
bbe2ecc1-23ec-4056-9ce6-09a660d8b1b2 bcf94d0b-f139-4b49-9950-45c66fe34a85 bd515a9a-d508-4745-b541-2292a3bc1c2e
bd5162af-2898-4f81-8e8d-1d0eabf11edf bd7e8922-dc1a-4a8f-bda0-7a0e25156190 be023298-39e9-4ed7-8690-962d505716af
be0b7450-9d78-404e-b371-990fc89f0ba4 bef69c72-0c45-4dba-bd13-73c192ffe5ba bf017484-bcdf-4e18-8228-7f5023586484
bf0e9fd3-5108-4529-9873-574791fd01bf bf84d05e-34d6-446c-a937-600be6e823f1 bfbd9853-05fb-45ad-a40f-1a9156c87559
c0692809-aca0-42a3-90b6-5eeacdd97abe c097a2d8-ecd6-4cc3-b5b1-9d938d38c9e4 c1a46992-c0d2-49b9-8d71-cdae564f29be
c1d35c61-347d-4297-a93f-7e492d7fbcf5 c22e9037-b7d1-41c2-b0e6-a60e6d5fb14d c2344921-4bec-4855-9678-8e233adea7a7
c2c593aa-2839-4d56-a16d-8bf97abb358a c2e6bb63-dd96-42a0-b528-a43e910d6161 c337d185-35fc-497b-ae0f-b9a14e8f0fd1
c3d1270d-20a0-4173-93f4-3fc0a4e3ec88 c3d68547-57d8-446f-acb2-f827f536d9e2 c3de4fec-c81f-45a1-bd13-21b25484d840
c3e6feb7-dc72-4a9e-8e99-81c8ab6a84ed c4199cf6-c6ec-45a2-b4a0-5f69d6a45d98 c485b0f5-d4e3-4428-9ccd-38a331b4e867
c4f651ef-67fd-4d59-96ff-0339ab9187c5 c51ecb8a-7f28-47aa-a762-1f93fc1892e5 c5236d4f-1c34-42ef-94cd-d0bc623d422a
c598de00-cd7a-4190-a770-d95048877caf c5a1a60c-1c7c-45a4-afa8-e2575f483614 c5b3f0fc-fcdb-4a10-bec0-da84321efc7d
c5c87ad2-5baa-46c1-b736-425aa162b7d9 c5dd9e98-8fcb-44d2-8b4f-8d3bdcf82b91 c663ac42-e6b5-4318-a837-575e5ea6d4d7
c6febdfb-031d-4cc3-8c71-98e6973923f3 c7219fa7-67d2-4bdb-a920-11ff76007477 c7703feb-4fa9-46e8-a3ff-780f13023cdb
c775a96f-5896-4aa7-b909-88ec8c4d5363 c7cc120f-9c1d-44f6-a198-00a636de21a6 c832f71b-5489-4e4a-9995-b834f26aff63
c91b154a-1f14-41f4-b1c3-796df467c555 c95654f1-ba29-4cdc-8f20-0ce527e6eb19 c971bab3-e065-4812-b32c-6331500c353d
ca9ba3dd-eb66-46e3-accb-67ad6b785b9e cac85742-bcd8-4689-a727-ecc81ba4bcf6 cbb894c2-5c57-4914-b3b1-073e555035f4
cbbfbb08-ac24-498f-bda0-261e864be7d6 cc80df07-0c19-4887-9bbe-2d56f1db8ad1 cc9adff7-097c-4a49-8063-ed19195b0078
ccada783-45f0-442a-9bab-53bbd2e0e9e4 cd18e886-f30d-4d4e-b2e3-9b11c64978b1 cd20b2d9-f02a-4be1-8e6d-8aba9b16df95
cd413e31-47eb-4fb6-b965-94df1cab3384 cd5cfa4e-cc5b-4aa6-886a-6dc2271ebe1b cd761f7f-c708-4e78-bebd-fcf4a8bbcf25
cd9367a2-2e3d-4180-ba7a-1bf3b0773a17 cdbbab83-1ff7-4f23-a8d6-e5185bfe7224 ce4d872d-974a-4a59-b8ee-27fe76c82b2c
ceee04be-0cb1-4174-ae02-de26eb5d9255 ceee506f-23c8-42ef-9242-cb9db53c6608 cfa1f391-9800-4acb-8898-4dd0b1a68df7
d07c9151-7259-4275-af0e-c90652fb07a4 d0d08614-b140-40e4-85e8-c8a916467a39 d0f91b14-f6c6-481b-9c33-17c85bc36ee1
d15af46e-c755-4b33-a903-89d349834f59 d1ceac54-8454-4961-868d-c582a06a5675 d23adcd9-8896-4e69-8dbd-bb1fe60a27d3
d29a6b5c-f5f5-47d1-8360-edb010d53861 d2c32100-820f-495d-bb25-949bfa0859ff d2d2cecb-92bd-4e5c-b874-4128a7b3c433
d356f33e-bc2e-4f3f-a6de-e734ecd7aca9 d387992a-49e7-4888-8e8c-3d5e406a0462 d3a6d631-fd15-4017-b738-af6f22704516
d3ff4cb0-445c-48bc-9852-3aaa5c7fde3c d453ea70-851f-4af4-899a-62505c0509ba d4950c64-fd04-4ae5-aae5-760a1a83fa43
d5257910-ea35-48f2-b103-b18323c50f03 d591b157-16b4-4560-aca1-a25fcb293d74 d6425301-4e33-4769-a6ab-17b9472a145f
d6839d1b-f263-4c7e-b26b-d8efef62ab39 d6a036a8-1d72-4459-bf45-76a3dcaae47b d6e48482-6bef-47a4-b12e-3a33110fffa9
d762ac40-336b-4acf-9927-087694f39971 d7891152-e3a6-41d0-9f36-6365bb161808 d7b7e735-f23a-492f-be56-e35e88ed0140
d7c01003-e92c-414a-ad94-eafb1be2fe0e d7e002a8-973e-445f-810f-5e0ce1bfb59f d85cfc65-aa3b-4525-b310-9d64f3f314e8
d882c2f4-bd15-4b06-b21d-b123ded22d3f d8ab3b16-1524-4cb2-b849-2b4148b07d51 d8bc5ea1-abdd-410d-84f3-6c879774ab49
d909c013-f5a2-4400-989f-3132e80b26d6 d977d726-2e32-4f33-9695-9a0e8fa008da d9c45bc5-a06a-4b6e-a94b-b7e432c5891c
d9e0de9e-118d-4508-b308-5d7ffd920450 da18c21c-ea3a-4801-a2be-f5aa25d5df0a da22597f-d62d-4720-b025-fbde8d45ad16
da959016-d899-42de-9aa6-bddde859e338 daa2eb39-45a9-4e58-b959-fd3c2885b78c dad168f7-4d86-4099-9f79-e172915e2436
db8d72d3-90fc-4178-ac9d-ff3e38e6749b db8f1085-1a29-4d64-a083-c26d3ce0b980 db988431-90f6-4844-a501-667b5f66d6f1
dbee264d-2cc1-4637-8129-7b97bafe9eb1 dbf5e47d-0bd6-480b-84de-22c89f2fbe23 dc8be442-2023-4d14-8935-84f049eb0285
dceb8d61-c291-4eed-80f8-a582407634f9 dd02797b-d17a-4d27-9eb7-3deb72691b69 dd2c3c09-0327-4839-acbb-123c8a5c3a66
dd6919ce-079b-476e-bd81-06e62bce8cf6 ddca0984-1e19-40bf-b9bc-cf34aa676a61 de6b39c0-5092-4fcd-8833-641e90c6f24c
de8fe51b-ed1d-4ded-9e81-be6a06936d86 dfd9a986-87ba-4a42-a978-e060eded94fd e04b804c-a954-4c1d-a028-00887c2e50d3
e06dcff5-39c0-4d92-a891-ccdac37e3efa e258c959-587e-4c68-b4b1-610ac8e762bc e2f40664-92b7-4c0a-8fd9-bd9bcaba7151
e3619942-5d26-4fa5-adac-f636e839a880 e40c1726-df85-4411-befb-31b0e4aa12b1 e41d8b29-51c3-421a-8e82-d35a97f9a26d
e5025282-cb83-4d7f-8a24-d9511c8137b6 e58d9c5b-eb42-4aa5-8f1c-0b8814fd191b e5e66e9b-80f4-4cf0-b8f9-132f0076bcf2
e5f2b589-7cad-4b68-82a5-b77f99ab6b4e e5f6a0ce-9957-4511-98d8-78326a1b5a02 e67e057e-3284-4384-b837-e058231413d0
e69a3b53-bb83-4b4a-8850-8eca1ef157fb e73e3743-ea5b-4408-805c-b3e243c285e0 e782d965-5467-4623-8a1b-1d6b09f5f64b
e7a37f02-672b-4a36-a753-da73b8d358a1 e7cfbf4a-0c17-4b33-8642-e1b1593d1330 e7d726d6-3f69-48b7-b1a5-0d374359e9f1
e82db2e0-5723-4408-b230-2bf2107fbaf9 e84e02f6-44a4-4c62-8b1a-c800f2826370 e872a347-ee8b-4b09-9926-e8491dba47c3
e89ca08f-3f7b-48a3-ada6-49e7bdfb5ec0 e968765a-a430-4ad8-bdba-1160dde5883c e9865816-7364-4ea6-a0e2-8e4def755b90
e993ea05-70a2-48e6-8dc8-cef4561404bb e9e0ab18-29dd-4c07-badb-c6a68d5c5d18 ea7a1264-d17c-40ab-a05f-0545b23dec1d
eabd2945-b520-4385-a44a-f324292b7030 eaf8d250-4ebb-4bb5-8b30-38874a56084b eb14be94-84e8-484e-a7bf-9faa412647e1
eb3be30b-5820-48bc-95b1-1117f100f697 eb503f37-6a3f-43d8-b783-84bb94b39c9f eba219ce-0491-411d-a7ae-cba14f9ec6ff
ec7a0622-a9bd-4b26-933e-90d6afa4d309 ec8c5eb0-e86f-4445-9986-b003ea295bc9 ecab4dd0-9098-4798-8dfe-b51aa42ac667
ecd82767-4da7-4d3b-8a67-b0165d02263a ecfa8721-0b52-4e79-8643-59914991ae58 ecfbef85-5b1d-4e64-99b2-9ef2ba13d674
eda2078b-52d0-421e-94e5-9d3bceec17ee edc2f910-6295-4781-9863-9a7732b0b699 ee15ce5e-2247-412c-bef5-8cb59cd24284
ee1a1066-e60a-4d36-beb8-1ac850e8503f ee88b8fb-bff2-4bce-800f-a6c74cd360b5 ee9b81d7-b8dd-43f0-868a-eb738ba3014b
eed16f24-473b-4684-a7b9-9e946504e919 eee61f7e-0b83-46c8-ae4e-17f942d16e86 ef0c7b7b-9743-4c64-896a-6a0776380a6d
f05fc17b-80a5-47d3-afe7-780e6ca06baa f0d7738c-20e9-4359-9ff8-59b2ea1ca85e f12663bb-a9f6-48b3-9b7b-9ae41596ba97
f133a4fd-007c-413a-9262-ec13f41f4890 f20186c8-989c-4853-9616-e5e9137a0b4a f24f4364-773d-49bf-9542-939f4cfea628
f27246a5-4072-4a4d-b319-eb5503d166d6 f27fbfb2-6406-4c88-aa74-0e388ab5dd4c f29303cd-efd1-447c-ae9a-a09a588994c4
f2f42dba-2c24-4b12-b8d0-fac2a3f079c9 f31b4fa5-f380-47d1-8b5d-2b4e3c6fc3f7 f33a1c1f-6c37-4730-8444-45c49f994297
f349594e-1ad3-492b-a68b-2ec1ec2db329 f3de3a74-cb16-4b8e-9fe7-5d44babe460c f4836a1e-8ec6-493a-b848-b05e78f4d98f
f53aa5ba-a116-4c15-8b5c-6c925bd7e1f2 f56f75ec-adcf-4460-a84b-89fa226a6ce7 f5efbbf0-f2a3-4719-aa66-f1a8f34c4a2d
f6848888-ae6a-4c4f-af64-e12648bb35b8 f6ad6718-ff3c-447c-9336-98458480b8c1 f70fa9df-841c-413c-9c16-ec1110224b2c
f7be0c77-18d8-419e-9f97-d047fc22a796 fa62eb74-44df-4c7a-b93c-5f64d92236c7 fa87778d-380f-4f44-88c9-3914399ba4e5
fb16e906-663e-42e1-aab1-48e4b400b857 fb23a81f-621d-4085-a6d4-d9ef22185612 fb40679d-b692-4008-9f2d-84f0a76c7403
fb7d08ff-88ef-43c0-9520-1ce31538261e fbdfe59b-6587-4d1f-a5db-7294dc3fc383 fc0175c8-f734-435d-857a-05db7fc35310
fc49c041-1b7c-41f2-af1b-3bdb07e7c38d fcc77c84-cb15-4c13-8c18-794b150e4c4f fd10f894-f511-48a8-b79c-2984ecee7100
fe09726c-414f-4a8e-87cf-27583b8d6127 fe237698-fdfd-47fa-9470-1fe976a9ed00 fe95e7f4-17ea-4c35-9eb5-9bf28133bf92
fea247fb-471c-44c8-a515-c519f0cf7b3c feb8f29d-2223-431e-9fbc-49a7114f7b5a fed9c208-5ef9-414b-a4cf-720d1053590a
ff1b6105-419e-4daf-8c5e-0e87d1584f39 ff5c13a5-9eb2-4325-89a8-5c5c240afa8b ffd0acf9-faef-41ea-b3d6-775fab06b49d
ffec089f-f5f8-483d-86cb-7d2e5eaa658d ffee19a0-35c6-4391-b84f-62e03b2e8339
"""


def returned_destinations():
    """RETURNED_DESTINATIONS as a sorted list of distinct ids, and its short sha256 (ties the output to the JSON)."""
    ids = sorted(set(RETURNED_DESTINATIONS.split()))
    return ids, hashlib.sha256(",".join(ids).encode()).hexdigest()[:16]


def _num(value):
    return f"{float(value):.6f}" if value is not None else "null"


async def main(conn):
    ids, digest = returned_destinations()
    print(f"SCRIPT input returned_destinations={len(ids)} sha256_16={digest}", flush=True)

    # 1. Spend cap.
    for r in await conn.fetch(SPEND_SQL):
        print(f"SCRIPT spend day={r['day']} stage={r['stage']} cost_usd={_num(r['cost_usd'])} calls={r['calls']} "
              f"unpriced_calls={r['unpriced_calls']}", flush=True)
    for r in await conn.fetch(SPEND_LOG_SQL, ONLINE_STAGES):
        print(f"SCRIPT spend_log day={r['day']} stage={r['stage']} calls={r['calls']} "
              f"cost_usd={_num(r['cost_usd'])}", flush=True)
    spent = float(await conn.fetchval(SPEND_TODAY_SQL, ONLINE_STAGES) or 0)
    print(f"SCRIPT spend_today online_usd={spent:.6f} cap_usd={DAILY_CAP_USD} under_cap={spent < DAILY_CAP_USD}",
          flush=True)

    # 2. Narration cache.
    totals = [0, 0, 0]
    for r in await conn.fetch(CACHE_SQL, CACHE_TTL_HOURS):
        totals = [totals[0] + r["rows"], totals[1] + r["hits"], totals[2] + r["rows_hit"]]
        print(f"SCRIPT cache source={r['source']} mode={r['mode']} rows={r['rows']} hits={r['hits']} "
              f"rows_hit={r['rows_hit']} fresh_rows={r['fresh_rows']} max_created={r['max_created']} "
              f"max_last_hit={r['max_last_hit']}", flush=True)
    print(f"SCRIPT cache_total rows={totals[0]} hits={totals[1]} rows_hit={totals[2]}", flush=True)

    # 3 + 4 read published_tours (FORCE RLS): pin the AA tenant like the Lambda (set_catalog_tenant), in one
    # transaction so the setting ends with it.
    async with conn.transaction():
        await conn.execute("SELECT set_config('app.tenant_id', $1, true)", AA_TENANT_ID)
        rows = await conn.fetch(SEARCH_SQL, AA_TENANT_ID, ids)
        control = await conn.fetchrow(CONTROL_SQL, AA_TENANT_ID, ids)
        comps = await conn.fetchrow(COMPONENTS_SQL, AA_TENANT_ID)
        candidates = await conn.fetch(CANDIDATES_SQL, AA_TENANT_ID)

    violations = [r for r in rows if not r["has_active_component"]]
    print(f"SCRIPT search returned={len(rows)} found={sum(1 for r in rows if r['found'])} "
          f"without_active_component={len(violations)}", flush=True)
    for r in violations:
        print(f"SCRIPT search_violation destination={r['destination_id']} "
              f"embedded_components={r['embedded_components']}", flush=True)
    print(f"SCRIPT control inactive_only_destinations={control['inactive_only']} "
          f"of_them_returned={control['inactive_only_returned']}", flush=True)
    print(f"SCRIPT control components embedded={comps['embedded']} "
          f"embedded_not_active={comps['embedded_not_active']}", flush=True)

    counts = {r["kind"]: r["n"] for r in candidates}
    print(f"SCRIPT candidates no_structured_text={counts.get('no_structured_text', 0)} "
          f"own_day_missing={counts.get('own_day_missing', 0)}", flush=True)
    for r in candidates:
        for cid in r["sample"] or []:
            print(f"SCRIPT candidate kind={r['kind']} component={cid}", flush=True)

    ok = not violations and control["inactive_only_returned"] == 0
    print(f"SCRIPT verdict search_no_inactive={'PASS' if ok else 'FAIL'} "
          f"control_has_inactive_only={control['inactive_only'] > 0}", flush=True)
