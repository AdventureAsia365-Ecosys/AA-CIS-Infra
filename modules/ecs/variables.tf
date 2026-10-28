# Existing variables (already in variables.tf)
variable "project" {
  type = string
}

variable "environment" {
  type = string
}

# New variables for ECS Service + ALB integration
variable "aws_region" {
  type    = string
  default = "us-west-1"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets for ECS tasks"
}

variable "sg_app_id" {
  type        = string
  description = "Security group for ECS tasks"
}

# ADR 0004b (X1 S13c): one security group per caller. When set, the api / worker service uses its
# own group instead of the shared app group; null keeps sg_app_id (rollback = unset these).
variable "sg_api_id" {
  type        = string
  default     = null
  description = "Security group for the api service; null falls back to sg_app_id"
}

variable "sg_worker_id" {
  type        = string
  default     = null
  description = "Security group for the worker service; null falls back to sg_app_id"
}

variable "target_group_arn" {
  type        = string
  description = "ALB target group ARN"
}

variable "task_cpu" {
  type        = number
  default     = 512
  description = "Fargate task CPU units (256/512/1024/2048/4096)"
}

variable "task_memory" {
  type        = number
  default     = 1024
  description = "Fargate task memory in MB"
}

variable "service_desired_count" {
  type        = number
  default     = 1
  description = "Desired number of ECS tasks"
}

variable "secret_rds_arn" {
  type        = string
  description = "Secrets Manager ARN for DATABASE_URL"
}

variable "secret_openai_arn" {
  type        = string
  description = "Secrets Manager ARN for OPENAI_API_KEY"
}

# AA-23: removed
# variable "secret_langfuse_arn" {
#   type        = string
#   description = "Secrets Manager ARN for LANGFUSE_SECRET_KEY"
# }

variable "secret_admin_arn" {
  description = "ARN of Secrets Manager secret for ADMIN_SECRET"
  type        = string
}

variable "secret_jwt_arn" {
  description = "ARN of Secrets Manager secret for JWT_SECRET (AA-506 — no plaintext fallback allowed)"
  type        = string
}

# AA-23: removed
# variable "secret_langfuse_public_key_arn" {
#   description = "ARN of Langfuse public key secret"
#   type        = string
# }

# AA-23: removed
# variable "secret_langfuse_host_arn" {
#   description = "ARN of Langfuse host secret"
#   type        = string
# }

variable "secret_dataforseo_arn" {
  description = "ARN of Secrets Manager secret for DataForSEO credentials"
  type        = string
  default     = ""
}

variable "step_functions_arn" {
  description = "ARN of the pipeline Step Functions state machine"
  type        = string
  default     = ""
}

variable "sf_batch_threshold" {
  description = "Tour count above which ingest-s3 routes to Step Functions instead of direct background tasks"
  type        = number
  default     = 15
}

variable "execution_role_secrets_arn_pattern" {
  description = "ARN pattern granting the ECS execution role secretsmanager:GetSecretValue, needed to inject task-def secrets. Optional — leave null when the execution role already has this permission out-of-band."
  type        = string
  default     = null
}

variable "redis_host" {
  description = "Redis endpoint injected into container env as REDIS_HOST. Optional — omit to preserve existing behavior."
  type        = string
  default     = null
}

# AA-874 S5: the CIS api + worker on the TLS + AUTH replication group (AA-CIS-App shared/cache/redis_conn.py).
variable "redis_tls" {
  description = "AA-874: env REDIS_TLS=true on api and worker (rediss://, certificate + host name checked). Needs an AA-CIS-App image with shared/cache/redis_conn.py (#983)."
  type        = bool
  default     = false
  nullable    = false
}

variable "redis_auth_secret_arn" {
  description = "AA-874: Secrets Manager ARN of the Redis AUTH token, injected as the secret REDIS_AUTH_TOKEN on api and worker (execution role pattern aa-cis/<env>/*). Null = no AUTH."
  type        = string
  default     = null
  validation {
    # ElastiCache accepts AUTH only over TLS; the app would drop the token with an ERROR, so fail at plan.
    condition     = var.redis_auth_secret_arn == null || var.redis_tls
    error_message = "redis_auth_secret_arn needs redis_tls = true (ElastiCache AUTH works only over TLS)."
  }
}

variable "redis_cluster_id" {
  description = "AA-874: env REDIS_CLUSTER_ID on api and worker, the cache cluster GET /admin/infra/status describes (the replication group's member, <group>-001). Null = the app default (the old node id)."
  type        = string
  default     = null
}

variable "s1_writer_v2_enabled" {
  description = "AA-645: env S1_WRITER_V2 (on/off) on the worker, the S1 writer v2 switch for the A1 admin rewrite (AA-CIS-App services/content_generation/s1_writer_v2_live.py, default off). In Terraform so a template revision from any apply touching this module keeps the live value (lesson S250)."
  type        = bool
  default     = false
  nullable    = false
}

variable "bronze_bucket_name" {
  description = "S3 bronze bucket name for presigned upload URLs (admin_pipeline.py BRONZE_BUCKET env var)"
  type        = string
}

# ── AA-651 — worker ECS service sizing ────────────────────────
# The job runner is I/O-bound (it mostly waits on Bedrock/TypeSafe/DataForSEO), so it needs far
# less CPU than its wall-clock time suggests. 512/1024 matches the api task, which today also
# carries the in-process worker, so this is not a reduction in headroom.
variable "worker_task_cpu" {
  description = "AA-651 — Fargate CPU units for the worker task (I/O-bound job runner)"
  type        = number
  default     = 512
}

variable "worker_task_memory" {
  description = "AA-651 — Fargate memory (MiB) for the worker task"
  type        = number
  default     = 1024
}

variable "worker_desired_count" {
  description = "AA-651 — baseline worker task count (autoscaling min)"
  type        = number
  default     = 1
}

variable "worker_max_count" {
  description = "AA-651 — autoscaling max worker task count"
  type        = number
  default     = 3
}

variable "permissions_boundary_arn" {
  description = "AA-806 step 4: ARN of the permissions boundary set on every IAM role this module creates (accounts/aa365 passes aa-workload-boundary). Null leaves the roles unbounded."
  type        = string
  default     = null
}

variable "tags" {
  description = "AA-828: tags merged into every taggable resource of this module (the root passes App = \"cis\", DM-10.1). Provider default_tags still add Project/Environment/ManagedBy/Account."
  type        = map(string)
  default     = {}
}

variable "cluster_tags" {
  description = "AA-828: tags merged over var.tags on the ECS cluster only (the root passes App = \"shared\": the AA-Booking service runs in this cluster too)."
  type        = map(string)
  default     = {}
}

# ── AA-828 — operator alert e-mail (SES, accounts/aa365/ses.tf) ──
variable "ops_alert_email" {
  description = "AA-828 — operator mailbox for CIS alert e-mails (ALERT_EMAIL_TO; spend budget crossings). Empty = the app sends no e-mail."
  type        = string
  default     = ""
}

variable "ses_from_address" {
  description = "AA-828 — SES_FROM_ADDRESS; must equal the ses:FromAddress the task role may send as (accounts/aa365 var.ses_from_address)."
  type        = string
  default     = ""
}

variable "ses_configuration_set" {
  description = "AA-828 — SES_CONFIGURATION_SET; the transactional stream the task role may send through (ses.tf)."
  type        = string
  default     = ""
}

# ── AA-913 — alert recipients managed from the CIS admin page (accounts/aa365/alert_recipients.tf) ──
variable "alerts_topic_arn" {
  description = "AA-913 — ALERTS_TOPIC_ARN: the alerts topic whose e-mail subscriptions the admin page manages; empty = page read-only/not configured."
  type        = string
  default     = ""
}

variable "alert_bootstrap_email" {
  description = "AA-913 — ALERT_BOOTSTRAP_EMAIL: the Terraform-managed subscription of the alerts topic, shown locked in the admin page."
  type        = string
  default     = ""
}

variable "bedrock_acct_primary" {
  description = "AA-902: acc3 (the only Bedrock satellite, AA-998) account ID, env BEDROCK_ACCT_PRIMARY on api and worker"
  type        = string
  default     = ""
}

variable "place_shapes_enabled" {
  description = "AA-847: env PLACE_SHAPES_ENABLED (on/off) on api and worker, the place_shape job's kill switch (default off)."
  type        = bool
  default     = false
}

variable "place_pipeline_auto" {
  description = "AA-905/AA-989: env PLACE_PIPELINE_AUTO (on/off) on api and worker. On = automatic place_extract also for sources with no place build (paid, cents per tour); off (default) = only already-built sources are re-synced."
  type        = bool
  default     = false
}

variable "segment_gc_mode" {
  description = "AA-988: env SEGMENT_GC_MODE on api and worker for the recompute job's segment_gc stage: report (default), apply or off."
  type        = string
  default     = "report"
  validation {
    condition     = contains(["report", "apply", "off"], var.segment_gc_mode)
    error_message = "segment_gc_mode must be report, apply or off."
  }
}

variable "erasure_apply_enabled" {
  description = "AA-839: env ERASURE_APPLY_ENABLED (true/false) on api and worker. The data_erasure apply runs only when true; default false (DRY RUN only)."
  type        = bool
  default     = false
}

variable "erasure_tenant_retention_days" {
  description = "AA-839: env ERASURE_TENANT_RETENTION_DAYS on api and worker, days a tenant stays offboarded before an erasure apply may run. Default 30 = the code default."
  type        = number
  default     = 30
  nullable    = false # null from the caller = this default
  validation {
    condition     = var.erasure_tenant_retention_days >= 0 && floor(var.erasure_tenant_retention_days) == var.erasure_tenant_retention_days
    error_message = "erasure_tenant_retention_days must be a whole number >= 0."
  }
}

variable "t9_faq_llm_filter" {
  description = "AA-779: env T9_FAQ_LLM_FILTER on the worker — off (no model call), shadow (record the LLM verdicts, deliver the deterministic list) or on (deliver the LLM-kept list; needs CIS ADR 0011 accepted)."
  type        = string
  default     = "off"
  validation {
    condition     = contains(["off", "shadow", "on"], var.t9_faq_llm_filter)
    error_message = "t9_faq_llm_filter must be off, shadow or on."
  }
}

variable "photos_cdn_distribution_arn" {
  description = "AA-835: ARN of the photos CloudFront distribution (accounts/aa365/photos_cdn.tf). Gives the CIS task role cloudfront:CreateInvalidation on it and the worker env PHOTO_CDN_DISTRIBUTION_ID (the supply_media_purge job). Empty = CDN gated off: no grant, no env."
  type        = string
  default     = ""
}
