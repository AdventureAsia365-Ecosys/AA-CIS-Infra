# ============================================================
# SQS Module — AA-CIS
# 6 queues + 6 DLQs theo Plan v3.0
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"

  queues = [
    "ingestion",
    "seo",
    "content-gen",
    "validation",
    "export",
    "hitl"
  ]
}

# Dead Letter Queues
resource "aws_sqs_queue" "dlq" {
  for_each = toset(local.queues)

  name                      = "${local.name_prefix}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Name    = "${local.name_prefix}-${each.key}-dlq"
    Service = each.key
  }
}

# Main Queues
resource "aws_sqs_queue" "main" {
  for_each = toset(local.queues)

  name                       = "${local.name_prefix}-${each.key}"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400 # 1 day
  receive_wait_time_seconds  = 20    # Long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 3
  })

  tags = {
    Name    = "${local.name_prefix}-${each.key}"
    Service = each.key
  }
}
