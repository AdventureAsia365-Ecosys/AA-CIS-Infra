variable "project" {
  description = "Project prefix: aa-cis"
  type        = string
}

variable "environment" {
  description = "dev | staging | prod"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-1"
}

variable "account_id" {
  description = "AWS Account ID"
  type        = string
}

variable "acp_ingest_lambda_arn" {
  description = "ARN of ACP ingest Lambda (leave empty to route via bus only)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "alerts_topic_arn" {
  description = "ARN of an existing SNS topic to notify on DLQ-depth alarms. This module does not create its own SNS topic — pass the account's existing alerts topic (e.g. the AA-284 aws_sns_topic.alerts in accounts/aa365/observability.tf)."
  type        = string
}

variable "iam_propagation_gate" {
  description = "Synthetic dependency trigger only — never read for real logic. Pass an attribute of an upstream time_sleep resource (e.g. time_sleep.wait_for_iam_propagation.id) to force this module's IAM-sensitive resources (event bus, scheduler role, schedule group) to wait until the caller's IAM policy changes have propagated, avoiding AWS IAM eventual-consistency AccessDenied errors (AA-287/AA-402). Defaults to empty so callers that don't need the gate aren't forced to pass anything."
  type        = string
  default     = ""
}
