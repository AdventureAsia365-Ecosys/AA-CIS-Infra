# ============================================================
# ECS Module — AA-CIS
# Cluster + IAM + ECR + Task Definition + Service + Auto Scaling
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"

  # AA-993 G1: the test-only job kind noop_sleep (AA-CIS-App services/jobs/noop_sleep_job.py, deploy-gate exempt) for
  # the worker-drain live proof. Registered only when JOB_TEST_KINDS=1; Dev only, on api AND worker (the verify's
  # worker-kinds row compares both sides, and the api's deploy gate must see the kind as exempt).
  job_test_kinds_env = [
    { name = "JOB_TEST_KINDS", value = var.environment == "dev" ? "1" : "0" },
  ]

  # AA-828: operator alert e-mail (spend budget crossings, job ops_alert_email) for the api and the
  # worker. Empty values are fine: the app logs and sends nothing (shared/ops_alerts.py).
  # AA-913: ALERTS_TOPIC_ARN + ALERT_BOOTSTRAP_EMAIL let the admin page (Platform > Alert recipients)
  # manage the e-mail subscriptions of the alerts topic and show the Terraform bootstrap locked; the
  # worker reads them too (ops_alert_email reconciles the recipient list). Empty ARN = page read-only.
  ops_alert_mail_env = [
    { name = "ALERT_EMAIL_TO", value = var.ops_alert_email },
    { name = "SES_FROM_ADDRESS", value = var.ses_from_address },
    { name = "SES_CONFIGURATION_SET", value = var.ses_configuration_set },
    { name = "ALERTS_TOPIC_ARN", value = var.alerts_topic_arn },
    { name = "ALERT_BOOTSTRAP_EMAIL", value = var.alert_bootstrap_email },
  ]

  # AA-902: the Bedrock / Cost Explorer satellite account ID (shared/llm_client/bedrock_satellite.py
  # builds every satellite ARN from it; the public repo carries no account ID). acc3 only (AA-998).
  bedrock_satellite_env = [
    { name = "BEDROCK_ACCT_PRIMARY", value = var.bedrock_acct_primary },
  ]

  # AA-847 lines: the place_shape job's kill switch (AA-CIS-App services/jobs/place_shape_job.py; the job runs on the
  # worker, the api reads it for the /admin/places/shapes/backfill 409). Same value on api and worker.
  place_shapes_env = [
    { name = "PLACE_SHAPES_ENABLED", value = var.place_shapes_enabled ? "on" : "off" },
  ]

  # AA-988: the segment_gc stage of the platform recompute job (AA-CIS-App services/acp_contract/segment_gc.py): report
  # (default, counts only), apply (deletes zero-reference orphan segments, <= 10,000 per pass) or off. The job runs
  # on the worker; the api carries the same value so a recompute it runs inline behaves the same.
  segment_gc_env = [
    { name = "SEGMENT_GC_MODE", value = var.segment_gc_mode },
  ]

  # AA-905 / AA-989 (S236 paid-run gate, flipped S252 after the AA-905 place backfill): automatic place_extract
  # triggers (end of A3 atomize, place-card relink) also for a source with no place build yet (AA-CIS-App
  # services/places/enqueue.py auto_allowed; "on" is one of 1/true/on/yes). Off = only already-built sources are
  # kept in step (set-active / restore never checked it, audit S252 §5.4). The triggers run on the worker and in
  # api requests, so api and worker carry the same value.
  place_pipeline_auto_env = [
    { name = "PLACE_PIPELINE_AUTO", value = var.place_pipeline_auto ? "on" : "off" },
  ]

  # AA-839: the data_erasure job's apply switch and the tenant retention window (AA-CIS-App
  # services/jobs/erasure_job.py). The api checks the flag before it enqueues an apply (403) and the job
  # re-checks both on the worker, so api and worker carry the same values. Apply is on only for the
  # string "true"; "false" behaves like unset. Retention 30 = the code default.
  erasure_env = [
    { name = "ERASURE_APPLY_ENABLED", value = var.erasure_apply_enabled ? "true" : "false" },
    { name = "ERASURE_TENANT_RETENTION_DAYS", value = tostring(var.erasure_tenant_retention_days) },
  ]

  # AA-779 (CIS ADR 0011): the T9 blog FAQ question filter's mode (AA-CIS-App services/acp_content_writing/faq_filter.py).
  # The T9 write runs as a job on the worker, so only the worker task definition carries it.
  t9_faq_filter_env = [
    { name = "T9_FAQ_LLM_FILTER", value = var.t9_faq_llm_filter },
  ]

  # AA-835 (S6 review): the supply_media_purge job (AA-CIS-App services/jobs/supply_media_purge_job.py, worker only)
  # invalidates /supply/<type>/<media_id>-* on the photos CDN after it deletes a withdrawn Booking photo's CIS copies.
  # Empty ARN (CDN gated off) = no env, no grant: the job then skips the invalidation ("not_configured").
  photos_cdn_distribution_id = var.photos_cdn_distribution_arn == "" ? "" : element(split("/", var.photos_cdn_distribution_arn), 1)
  supply_photo_purge_env = local.photos_cdn_distribution_id == "" ? [] : [
    { name = "PHOTO_CDN_DISTRIBUTION_ID", value = local.photos_cdn_distribution_id },
  ]

  # AA-874 S5: Redis connection for api and worker (AA-CIS-App shared/cache/redis_conn.py). REDIS_TLS and the
  # REDIS_AUTH_TOKEN secret appear only when set, so a module call without them renders the old plain env.
  # REDIS_CLUSTER_ID names the node GET /admin/infra/status describes (admin_pipeline.py).
  redis_env = concat(
    var.redis_host != null ? [{ name = "REDIS_HOST", value = var.redis_host }] : [],
    var.redis_tls ? [{ name = "REDIS_TLS", value = "true" }] : [],
    var.redis_cluster_id != null ? [{ name = "REDIS_CLUSTER_ID", value = var.redis_cluster_id }] : [],
  )
  redis_secrets = var.redis_auth_secret_arn != null ? [
    { name = "REDIS_AUTH_TOKEN", valueFrom = var.redis_auth_secret_arn },
  ] : []

  # AA-645 (S248): the S1 writer v2 switch. Set by hand on the worker revision until S250; a Terraform apply
  # touching this module then registered a template revision without it, and CIS deploy-dev copies the latest
  # revision, so the next deploy would have put the S1 waves back on writer v1 (lesson S250). Worker only.
  s1_writer_env = [
    { name = "S1_WRITER_V2", value = var.s1_writer_v2_enabled ? "on" : "off" },
  ]
}

# ── ECS Exec session log (S241 D-07) ──────────────────────────
# Every ECS Exec session on this cluster (CIS api, CIS worker, Booking api) is recorded here: the
# SSM agent in the task uploads the session transcript when the session ends. No KMS key: no other
# log group in this stack uses a CMK, and CloudWatch Logs encrypts at rest with its own key anyway.
# The transcript holds whatever the session printed (kept 365 days, AA-872, readable by anyone with
# logs:GetLogEvents on the account): never run env/printenv in an exec session, and scripts print
# counts and ids only, never DSNs or secret values.
resource "aws_cloudwatch_log_group" "exec_sessions" {
  name              = "/ecs/${local.name_prefix}/exec-sessions"
  retention_in_days = 365 # AA-872 (S241 D-09): security/audit logs 365 days

  tags = var.tags
}

# ── ECS Cluster ───────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"
  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  # S241 D-07: DEFAULT writes exec transcripts into each task definition's awslogs group (mixed with
  # app logs, 14-day retention; Booking's task role cannot write there). OVERRIDE sends every
  # session on the cluster to the dedicated group above. Each task role needs the logs grant to
  # write there (CIS: aws_iam_role_policy.ecs_task_exec_logging below, enforced by depends_on;
  # Booking: accounts/aa365/booking.tf, applied before the cluster, see
  # docs/implementation-notes/S241-exec-logging.md). Rollback: set logging = "DEFAULT" and drop
  # log_configuration; deleting this block may leave OVERRIDE live with no Terraform owner.
  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"
      log_configuration {
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.exec_sessions.name
        cloud_watch_encryption_enabled = false
      }
    }
  }
  # Without this, UpdateCluster can run before the CIS task role may write to the group.
  depends_on = [aws_iam_role_policy.ecs_task_exec_logging]

  # AA-828: the cluster also runs aws_ecs_service.booking (accounts/aa365/booking.tf), so the root
  # passes cluster_tags = { App = "shared" }. A cluster has no cost line of its own; task cost is
  # attributed through the service tags propagated to each task (propagate_tags below).
  tags = merge(var.tags, var.cluster_tags, { Name = "${local.name_prefix}-cluster" })
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ── IAM Roles ─────────────────────────────────────────────────
resource "aws_iam_role" "ecs_execution" {
  name                 = "${local.name_prefix}-ecs-execution-role"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# AmazonECSTaskExecutionRolePolicy does not include secretsmanager:GetSecretValue,
# which the execution role needs to inject the task definition's `secrets` block.
# Optional — only created when execution_role_secrets_arn_pattern is set.
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  count = var.execution_role_secrets_arn_pattern != null ? 1 : 0

  name = "${local.name_prefix}-ecs-execution-secrets"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.execution_role_secrets_arn_pattern]
    }]
  })
}

resource "aws_iam_role" "ecs_task" {
  name                 = "${local.name_prefix}-ecs-task-role"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}
# AWS managed policy required for ECS Exec (execute-command) — grants ssmmessages:
# CreateControlChannel/CreateDataChannel/OpenControlChannel/OpenDataChannel on the task role.
# Account 1 already has this attached out-of-band (not in prior Terraform state) — same
# class of drift as ecs_execution_secrets above. AttachRolePolicy is idempotent, so applying
# this where it already exists in AWS is safe (no EntityAlreadyExists on this resource type).
resource "aws_iam_role_policy_attachment" "ecs_task_ssm" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# S241 D-07: what the SSM agent in a task needs to upload an ECS Exec session log. CreateLogStream,
# DescribeLogStreams and PutLogEvents are scoped to the exec log group; DescribeLogGroups is a list
# call that takes no log group ARN (as in the AWS ECS Exec guide) and only returns names. The broad
# logs:* grant in ecs_task_policy already covers part of this; this policy keeps the exec path
# working if that grant is ever narrowed.
resource "aws_iam_role_policy" "ecs_task_exec_logging" {
  name = "${local.name_prefix}-ecs-task-exec-logging"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ExecSessionLogDescribeGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid      = "ExecSessionLogWrite"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.exec_sessions.arn}:*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task_policy" {
  name = "${local.name_prefix}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:ListBucket",
          "secretsmanager:GetSecretValue",
          "sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage",
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
          "bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "*"
      },
      # AA-380 — cloudwatch:PutMetricData has no ARN-scoped Resource (always "*"
      # per AWS IAM); the cloudwatch:namespace condition key is the only way to
      # restrict which namespace this role can write to. Scoped to "acp" — the
      # sole custom-metric namespace in use (AA-141 api/routers/acp_health.py,
      # AA-362 services/acp_produce/metrics.py) — not a wildcard grant.
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "acp"
          }
        }
      },
      # AA-459 — the first runtime-WRITE Secrets Manager use in this codebase (every prior
      # use, incl. the GetSecretValue statement above, is read-only against secrets an
      # admin/Terraform already pre-created). AA-CIS-App's api/routers/v1_integrations.py
      # (AA-457) writes one Secrets Manager secret per tenant at
      # acp/cms/{tenant_id} (create-or-update: create_secret, falling back to
      # put_secret_value on ResourceExistsException) — confirmed live 25/08/2026 via
      # CloudWatch that the task role lacked this, 502ing POST /v1/integrations/wordpress
      # for every real tenant. Deliberately a SEPARATE statement from the GetSecretValue
      # one above (that one is Resource="*", bundled with unrelated s3/sqs/logs/bedrock
      # actions) rather than widening that grant — this is scoped ONLY to the acp/cms/
      # namespace the Python code actually writes to, least-privilege, not
      # secretsmanager:* and not an unscoped Resource. secretsmanager:TagResource is
      # deliberately NOT included — confirmed by reading the real call site
      # (v1_integrations.py's create_secret(Name=secret_key, SecretString=payload) passes
      # no Tags argument), so AWS never invokes TagResource for this code path; add it
      # later only if a real future caller starts tagging secrets on create.
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:005097885195:secret:acp/cms/*"
      },
      # AA-462 — same gap as AA-459 (comment above), same fix, different prefix. T11's new
      # Facebook integration (api/routers/v1_integrations.py::save_facebook()) writes to
      # acp/social/{tenant_id} — deliberately NOT acp/cms/{tenant_id} (a Page Access Token
      # isn't a CMS credential, and a tenant connecting both needs two independent secrets,
      # see that file's own header comment) — so the acp/cms/* grant above doesn't cover it.
      # Confirmed live before this PR: POST /v1/integrations/facebook 502'd "Could not save
      # credentials — try again" for a real tenant, identical shape to the AA-459 bug this
      # mirrors. Kept as its own statement (not widened into acp/cms/* or acp/*) for the same
      # least-privilege reasoning AA-459 already established — scoped only to the namespace
      # the Python code actually writes to.
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:005097885195:secret:acp/social/*"
      },
      # S237 — a tenant key rotation (POST /admin/tenants/{id}/generate-key, /restore) keeps the E2E test
      # tenants' key copies in sync (AA-CIS-App services/acp_shared/e2e_tenant_key_sync.py). Describe +
      # PutSecretValue only, never CreateSecret: the app overwrites a copy that already exists, so a real
      # tenant (no such secret) is never written and its key exists only on the admin's screen.
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:PutSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:005097885195:secret:aa-cis/dev/e2e-tenant/*"
      },
      # X1 S19 (AA-860, plan XD5): the GetSecretValue grant above is on "*", so without this a compromised
      # CIS runtime could read the RDS master DSN and every other app's DSN, and the DB role split (cis_app,
      # S18) would be cosmetic. An explicit Deny wins over any Allow. Secrets Manager ARNs end in "-" plus 6
      # random characters, so `rds-??????` matches only the master secret aa-cis/<env>/rds, never rds-app-user
      # or rds-cis-app (more characters after "rds-"); likewise db-migrator-??????. The CIS code reads only
      # aa-cis/<env>/{rds-app-user, e2e-tenant/*, gdrive-photo-reader, geoapify, jwt-secret, sentry-dsn-api,
      # typesafe, dataforseo} and acp/{cms,social}/* (grep 19/10/2026; booking-jwt-signing-key goes away with
      # the CIS to Booking bridge, AA-911): none is denied. DATABASE_URL itself is injected by the EXECUTION
      # role, which this does not touch. The only
      # code naming the master secret is services/acp_produce/sweeper_lambda.py, a Lambda handler that is
      # neither deployed nor imported by the api / worker. Master-level scripts go through DB Migrate
      # mode=run-script (db/scripts/README.md), no longer through ECS exec.
      {
        Sid    = "DenyMasterAndOtherAppSecrets"
        Effect = "Deny"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:005097885195:secret:${var.project}/${var.environment}/rds-??????",
          "arn:aws:secretsmanager:${var.aws_region}:005097885195:secret:${var.project}/${var.environment}/db-migrator-??????",
          "arn:aws:secretsmanager:${var.aws_region}:005097885195:secret:booking/*",
          "arn:aws:secretsmanager:${var.aws_region}:005097885195:secret:tripplanner/*",
          "arn:aws:secretsmanager:${var.aws_region}:005097885195:secret:crm/*", # AA-932 partner CRM
        ]
      },
      # AA-894 scope 2 — the admin data-model view (AA-CIS-App GET /admin/data-model) reads the ERD model that
      # the DB Schema Dump workflow writes (db-schema-dump.yml ERD_S3_PREFIX): exactly these two objects. The
      # s3:GetObject on "*" above already covers them; this statement names the only read the view needs, so it
      # keeps working when that "*" is narrowed later.
      {
        Sid    = "ReadErdModel"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "arn:aws:s3:::${var.bronze_bucket_name}/data-model/erd/latest.json",
          "arn:aws:s3:::${var.bronze_bucket_name}/data-model/erd/previous.json",
        ]
      },
      # AA-894 scope 2 — the full catalog dumps (db-schema-dump/latest.json, db-schema-dump/<run id>/schema.json:
      # roles, grants, policies, functions) are for the dump workflow only; no CIS code reads or writes that prefix
      # (grep 22/10/2026). The dump task itself runs with the migrator task role (accounts/aa365/db_migrator.tf),
      # not this one. An explicit Deny wins over the "*" grants above.
      {
        Sid      = "DenySchemaDumpPrefix"
        Effect   = "Deny"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${var.bronze_bucket_name}/db-schema-dump/*"
      },
      # AA-894 scope 2 — CIS only reads the ERD model; the dump workflow's CI role is its only writer.
      {
        Sid      = "DenyErdModelWrite"
        Effect   = "Deny"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.bronze_bucket_name}/data-model/*"
      },
      # AA-898 — the admin docs reader (AA-CIS-App GET /admin/docs/manifest, /admin/docs/page) reads the bundle the
      # root repo Docs sync workflow uploads (manifest.json + pages/<repo>/<path>.md under docs-reader/). The "*"
      # GetObject above already covers it; this names the read so it survives a narrowing of that grant.
      {
        Sid      = "ReadDocsReader"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.bronze_bucket_name}/docs-reader/*"
      },
      # AA-898 — only CI (accounts/aa365/docs_reader.tf aa-cis-<env>-docs-sync) writes what the admin shows; the
      # "*" PutObject above must not reach this prefix.
      {
        Sid      = "DenyDocsReaderWrites"
        Effect   = "Deny"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.bronze_bucket_name}/docs-reader/*"
      },
      # AA-835 (S6 review) — DM-7 row "supply_media": when Booking withdraws a supply photo's usage rights or removes
      # it, the supply_media_purge job deletes the CIS WebP copies (photos/supply/<type>/<media_id>-{1600,600}.webp).
      # The only S3 delete this role holds, on that prefix only; every other CIS photo (photos/<country slug>/) stays
      # put/get only.
      {
        Sid      = "DeleteSupplyPhotoCopies"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.bronze_bucket_name}/photos/supply/*"
      }
      ],
      # AA-835 (S6 review) — the same job invalidates the deleted copies on the photos CDN (TTL up to a year, min one
      # day). Only on this one distribution; absent when the CDN is gated off.
      var.photos_cdn_distribution_arn == "" ? [] : [
        {
          Sid      = "InvalidateSupplyPhotoCopies"
          Effect   = "Allow"
          Action   = ["cloudfront:CreateInvalidation"]
          Resource = var.photos_cdn_distribution_arn
        }
    ])
  })
}

# AA-257 — GET /admin/infra/status (live ECS/RDS/NAT/ElastiCache health, aa-cis-dev-api's
# admin_pipeline.py) and the pre-existing GET /admin/metrics/spot-workers (built earlier,
# never actually granted this) both need read-only describe/list access this role has never
# had. Confirmed live before this PR: /admin/metrics/spot-workers has been returning
# AccessDeniedException on ecs:ListTasks in prod this whole time (degrades to zeros — no
# outage, but silently non-functional since it shipped).
#
# All Resource="*" — none of ecs:Describe*/List*, rds:DescribeDBInstances,
# ec2:DescribeInstances, elasticache:DescribeCacheClusters, or ecr:DescribeImages support
# resource-level ARN scoping in IAM (same constraint documented on the cloudwatch:PutMetricData
# statement above); every action here is describe/list/read-only, no write/delete verb in
# this statement, scoped to exactly the AWS API surface both endpoints' code actually calls.
#
# Deliberately opened as its own PR, NOT auto-merged — per the repo-wide "no self-added IAM
# via Terraform auto-merge" convention (same one AA-256's Cost Explorer ask hit), IAM changes
# get a manual look regardless of CI outcome.
resource "aws_iam_role_policy" "ecs_task_infra_status_readonly" {
  name = "${local.name_prefix}-ecs-task-infra-status-readonly"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "ecs:DescribeTaskDefinition",
          "ecr:DescribeImages",
          "rds:DescribeDBInstances",
          "ec2:DescribeInstances",
          "elasticache:DescribeCacheClusters"
        ]
        Resource = "*"
      },
      # AA-623 — GET /admin/cost-explorer (aa-cis-dev-api's admin_llm_ops.py) reconciles the
      # External Spend page's token-derived cost estimate (AA-622) against real AWS billing.
      # Cost Explorer is IAM-global (no per-account/per-resource ARN scoping — same constraint
      # already documented on cloudwatch:PutMetricData above), and does not support
      # resource-level restriction on ce:GetCostAndUsage either, so Resource="*" here is the
      # only form AWS accepts, not a broadened grant. Read-only (Get*, no write/delete verb),
      # same class of statement as the ecs/rds/ec2/elasticache describes already in this
      # policy. Deliberately landed in its own PR per this file's own "no self-added IAM via
      # Terraform auto-merge" convention noted below — Nghiệp reviews/merges/applies by hand.
      {
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage"]
        Resource = "*"
      },
      # AA-858 — GET /admin/overview/ops (AA-CIS-App api/services/ops_overview/) shows request / error / p95 /
      # throttle numbers per app (API Gateway aa-cis-dev-api + aa-booking-dev-api, Lambdas
      # aa-tripplanner-dev-browse/-assembly) and an "alarm firing" pill per app. Read-only, cached in Redis
      # (5 min), so a page view is not an API call. cloudwatch:GetMetricData has no resource-level permission
      # in IAM (Resource="*" is the only form AWS accepts; it returns metric values only). Cost: $0.01 per
      # 1,000 metrics requested, ~16 per cache miss, worst case ≈ $0.60/month.
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = "*"
      },
      # DescribeAlarms (names, states, thresholds; free within the API free tier) supports the alarm ARN, so it is
      # scoped to this account's alarms in this region rather than "*". Not narrowed to per-prefix ARNs
      # (aa-cis-dev-*, aa-booking-dev-*, …): DescribeAlarms is a list call made with AlarmNamePrefix, and whether
      # IAM matches a prefix-pattern ARN for it is unverified; alarm:* also covers the aa-identity-dev-* /
      # aa-email-dev-* alarms if the overview adds them. No lambda:GetFunctionConfiguration (it returns env vars).
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = "arn:aws:cloudwatch:${var.aws_region}:005097885195:alarm:*"
      }
    ]
  })
}

# ── CloudWatch Log Group ──────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 30 # AA-872 (S241 D-09): app logs 30 days

  tags = var.tags
}

# ── ECR Repository ────────────────────────────────────────────
# AA-869: IMMUTABLE. Deploy Dev pushes only dev-<sha> (AA-CIS-App, since AA-869), so a tag always
# names one image and a rollback to an older task-def revision gets exactly the image it ran.
resource "aws_ecr_repository" "api" {
  name                 = "${local.name_prefix}-api"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = merge(var.tags, { Name = "${local.name_prefix}-api" })
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  # AA-869: keep 30 deploy images (~1.5 days at the S241 deploy rate, so recent task-def revisions
  # still have their image for a rollback; ~13 GB, about +0.7 USD/month over 10 images), expire
  # untagged layers after 7 days. The frozen :latest image also carries its dev-<sha> tag, so it
  # ages out with rule 2; the task definitions' :latest placeholder then names a missing tag, which
  # is harmless (services ignore task_definition; every deploy rewrites the image).
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 30 dev-<sha> deploy images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["dev-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ── Task Definition ───────────────────────────────────────────
resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name         = "api"
    image        = "${aws_ecr_repository.api.repository_url}:latest"
    essential    = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    environment = concat([
      { name = "PORT", value = "8000" },
      { name = "ENVIRONMENT", value = var.environment },
      { name = "PROJECT", value = var.project },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "STEP_FUNCTIONS_ARN", value = var.step_functions_arn },
      { name = "SF_BATCH_THRESHOLD", value = tostring(var.sf_batch_threshold) },
      { name = "BRONZE_BUCKET", value = var.bronze_bucket_name },
      # AA-651 — the durable job runner now has its own ECS service (aws_ecs_service.worker
      # below). Turn OFF the API's in-process worker so jobs are claimed only by the worker
      # task, never double-claimed. (A single DB-wide advisory lock in queue.claim keeps the
      # per-kind caps exact even if both ran, but running jobs in the API process is exactly
      # the event-loop contention AA-651 removes — see api/main.py JOB_WORKER_IN_API.)
      { name = "JOB_WORKER_IN_API", value = "false" },
      ],
      local.ops_alert_mail_env,
      local.bedrock_satellite_env,
      local.place_shapes_env,
      local.segment_gc_env,
      local.place_pipeline_auto_env,
      local.erasure_env,
      local.redis_env,
      local.job_test_kinds_env,
    )
    secrets = concat([
      { name = "DATABASE_URL", valueFrom = var.secret_rds_arn },
      { name = "OPENAI_API_KEY", valueFrom = var.secret_openai_arn },
      # { name = "LANGFUSE_SECRET_KEY", valueFrom = var.secret_langfuse_arn },            # AA-23: removed
      { name = "ADMIN_SECRET", valueFrom = var.secret_admin_arn },
      { name = "JWT_SECRET", valueFrom = var.secret_jwt_arn },
      # { name = "LANGFUSE_PUBLIC_KEY", valueFrom = var.secret_langfuse_public_key_arn }, # AA-23: removed
      # { name = "LANGFUSE_HOST",       valueFrom = var.secret_langfuse_host_arn },        # AA-23: removed
      # ANTHROPIC_API_KEY: removed AA-518 — provisioned but 0 callers in app code (direct-Anthropic
      # calls never shipped; the app only ever calls Claude via the Bedrock satellite pattern,
      # AA-296/397). Secret aa-cis/dev/anthropic-key itself deleted from Secrets Manager same PR.
      { name = "DATAFORSEO_LOGIN", valueFrom = "${var.secret_dataforseo_arn}:login::" },
      { name = "DATAFORSEO_PASSWORD", valueFrom = "${var.secret_dataforseo_arn}:password::" },
      ],
      local.redis_secrets,
    )
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api"
      }
    }
    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
    # AA-310 (AA-295 Direction 3) — SIGTERM→SIGKILL window. Fargate default is 30s, but the app's
    # shutdown needs: uvicorn finishing in-flight HTTP requests (LLM-backed endpoints run 15-30s)
    # + the lifespan drain of background jobs (asyncio.wait timeout=25, api/main.py) + pool/redis
    # close + CancelledError→mark_interrupted() on jobs still pending. 90s covers that with margin
    # and stays under both the Fargate cap (120s) and the FARGATE_SPOT 2-minute interruption notice
    # (the service runs weight-3 Spot). It does NOT let a run_tour job finish (p50 ~13 min, max ~38
    # min measured 24/09) — it only lets it be marked `interrupted` cleanly instead of SIGKILLed.
    # Clean shutdowns exit in ~0.1s, so this does not slow normal deploys.
    stopTimeout = 90
  }])

  tags = merge(var.tags, { Name = "${local.name_prefix}-api-task" })
}

# ── ECS Service ───────────────────────────────────────────────
resource "aws_ecs_service" "api" {
  name            = "${local.name_prefix}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.service_desired_count

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 3
    base              = 0
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # AA-176 (scope item 2): a failed rolling deploy (new task never reaches healthy — bad image,
  # crashed startup, failing health check) used to just sit there consuming the deployment's
  # maximumPercent headroom indefinitely with no automatic rollback -- required a human to
  # notice and manually re-deploy the previous task definition revision. This does not touch
  # image tagging strategy (still :latest per this repo's own current convention -- see
  # AA-CIS-App CLAUDE.md "Image tag: always :latest" -- deliberately NOT changed here, that's
  # a separate, explicitly-conflicting decision this PR does not make) -- ECS's circuit
  # breaker triggers on deployment health regardless of tag scheme, and auto-rolls the SERVICE
  # back to the last-known-good task definition revision when the new deployment's tasks fail
  # to stabilize, closing the "nobody noticed, deploy just hangs broken" half of this gap on
  # its own.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [coalesce(var.sg_api_id, var.sg_app_id)]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "api"
    container_port   = 8000
  }

  enable_execute_command = true

  # AA-828: copy the service tags (App = "cis") onto every task it starts, so Fargate cost lands
  # under the App cost allocation tag. SERVICE, not TASK_DEFINITION: the AA-CIS-App deploy workflow
  # registers each new revision from `describe-task-definition` output, which carries no tags, so
  # the revisions that actually run are untagged. In-place UpdateService; running tasks keep their
  # old (empty) tags until the next deployment replaces them.
  propagate_tags = "SERVICE"

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_execution]

  tags = merge(var.tags, { Name = "${local.name_prefix}-api-service" })
}

# ── Auto Scaling ──────────────────────────────────────────────
# AA-859 (S240, sizing option A): max 10 -> 7 api tasks. The tenant pool goes from 1 to 2 connections per
# task (AA-CIS-App api/core/aa544_tenant_pool.py TENANT_POOL_MAX_SIZE), and 2 x 7 = 14 stays under the
# aa_app_user CONNECTION LIMIT 15 (CIS migration 234). Data standard C2.2/C2.3c: change this value only
# together with the tenant pool size and the C2.2 budget table. Dev runs 1 task, so the cap costs nothing.
resource "aws_appautoscaling_target" "api" {
  max_capacity       = 7
  min_capacity       = var.service_desired_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu_scale_out" {
  name               = "${local.name_prefix}-cpu-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "memory_scale_out" {
  name               = "${local.name_prefix}-memory-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 80.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ============================================================
# AA-651 — Worker ECS service (durable job runner, own process)
# ============================================================
# Same image, execution role and TASK role as the api (so the Bedrock satellite trust and every
# secret grant still apply — the issue requires the invoker IAM unchanged). Differences from api:
#   - command override `python -m worker` (runs the job loop, not uvicorn)
#   - no portMappings, no healthCheck, no ALB target (not an HTTP service)
#   - stopTimeout 120s (the Fargate max): a worker drain releases running jobs back to the queue;
#     give it the full window (api uses 90s because it also fronts the ALB deregistration).
#   - its own `worker` log-stream prefix.
# Env/secrets mirror the api so a job handler has the identical runtime (DB, OpenAI, DataForSEO,
# Bedrock via the task role). JOB_WORKER_IN_API is irrelevant here (that flag only gates the API's
# in-process loop); the worker process always runs the loop.

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name_prefix}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_task_cpu
  memory                   = var.worker_task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = "${aws_ecr_repository.api.repository_url}:latest"
    essential = true
    command   = ["python", "-m", "worker"]
    environment = concat([
      { name = "ENVIRONMENT", value = var.environment },
      { name = "PROJECT", value = var.project },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "STEP_FUNCTIONS_ARN", value = var.step_functions_arn },
      { name = "SF_BATCH_THRESHOLD", value = tostring(var.sf_batch_threshold) },
      { name = "BRONZE_BUCKET", value = var.bronze_bucket_name },
      # AA-801 (S236): T2 judge with tenant score anchors; gate on brand_fit only, mission logged
      # as a diagnostic (anchors: spread <= 1 on 9/9; brand-swap control: brand_fit 7-8 -> 5.67).
      { name = "T2_JUDGE_ANCHORS", value = "on" },
      { name = "T2_JUDGE_GATE", value = "brand_fit" },
      # AA-793 (S237): T3 grounding accepts background facts about named places (past years,
      # centuries, elevations) instead of flagging them; never tour activities, services or times
      # the source lacks (writer source-fidelity policy). Best draft wins + targeted repair default on.
      { name = "T3_BACKGROUND_FACTS", value = "on" },
      # AA-993 G1: the drain window on SIGTERM (shared/jobs/worker.py). It must leave 15 s of the 120 s stopTimeout
      # below; a running job that does not finish in time is released (not counted while a newer revision is alive).
      { name = "JOB_WORKER_GRACE_SECONDS", value = "100" },
      ],
      local.ops_alert_mail_env,
      local.bedrock_satellite_env,
      local.place_shapes_env,
      local.segment_gc_env,
      local.place_pipeline_auto_env,
      local.erasure_env,
      local.t9_faq_filter_env,
      local.supply_photo_purge_env,
      local.s1_writer_env,
      local.redis_env,
      local.job_test_kinds_env,
    )
    secrets = concat([
      { name = "DATABASE_URL", valueFrom = var.secret_rds_arn },
      { name = "OPENAI_API_KEY", valueFrom = var.secret_openai_arn },
      { name = "ADMIN_SECRET", valueFrom = var.secret_admin_arn },
      { name = "JWT_SECRET", valueFrom = var.secret_jwt_arn },
      { name = "DATAFORSEO_LOGIN", valueFrom = "${var.secret_dataforseo_arn}:login::" },
      { name = "DATAFORSEO_PASSWORD", valueFrom = "${var.secret_dataforseo_arn}:password::" },
      ],
      local.redis_secrets,
    )
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "worker"
      }
    }
    # The worker drains by releasing running jobs back to the queue on SIGTERM (shared.jobs.worker
    # shutdown). 120s = Fargate max, comfortably over the loop's grace_seconds (20s) + release.
    stopTimeout = 120
  }])

  tags = merge(var.tags, { Name = "${local.name_prefix}-worker-task" })
}

resource "aws_ecs_service" "worker" {
  name            = "${local.name_prefix}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_desired_count

  # Same Spot-weighted strategy as the api: the job runner tolerates interruption (a reaped job is
  # re-queued, S201), so running mostly on Spot is both safe and ~70% cheaper.
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 3
    base              = 0
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [coalesce(var.sg_worker_id, var.sg_app_id)]
    assign_public_ip = false
  }

  # No load_balancer block — the worker is not an HTTP service.

  enable_execute_command = true

  # AA-828: same as the api service: service tags (App = "cis") reach every task.
  propagate_tags = "SERVICE"

  # The App deploy workflow registers a new task def (new image) and points the service at it on
  # every push, so Terraform must not fight it on task_definition; desired_count is autoscaled.
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_execution]

  tags = merge(var.tags, { Name = "${local.name_prefix}-worker-service" })
}

# Autoscale the worker on CPU/memory, same shape as the api. min = desired, max = worker_max_count
# (default 3). Jobs piling up push CPU over target → ECS adds a worker task (each one its own 4
# slots); the per-kind DB-wide caps still bound real concurrency (a3_atomize stays 1).
resource "aws_appautoscaling_target" "worker" {
  max_capacity       = var.worker_max_count
  min_capacity       = var.worker_desired_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "worker_cpu_scale_out" {
  name               = "${local.name_prefix}-worker-cpu-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension
  service_namespace  = aws_appautoscaling_target.worker.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "worker_memory_scale_out" {
  name               = "${local.name_prefix}-worker-memory-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension
  service_namespace  = aws_appautoscaling_target.worker.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 80.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
