# AA-CIS-Infra — Claude Code Context
# Updated: 11/05/2026

## LIVE STATE
- Account: 867490540162 | Region: us-west-1 | Profile: pqnghiep-admin
- ECS cluster: aa-cis-dev-cluster | service: aa-cis-dev-api
- RDS: aa-cis-dev-db.cr2y6824szn3.us-west-1.rds.amazonaws.com (PostgreSQL 15)
- ECR: 867490540162.dkr.ecr.us-west-1.amazonaws.com/aa-cis-dev-api
- ALB: aa-cis-dev-alb-1114303360.us-west-1.elb.amazonaws.com

## ⚠️ CRITICAL — DO NOT CHANGE
api_task_def_arn is hardcoded to revision :21 in main.tf.
This is known tech debt. Do NOT update it — will break Step Functions.
Linear: AA-22 (deferred)

## TERRAFORM BACKEND
backend "s3" { bucket = "aa-cis-tfstate-867490540162", key = "dev/terraform.tfstate" }
Profile: pqnghiep-admin | Region: us-west-1
Always: terraform plan before apply.

## RESOURCE NAMING
Pattern: aa-cis-{env}-{resource}
Examples: aa-cis-dev-api, aa-cis-dev-db, aa-cis-dev-cluster, aa-cis-dev-redis

## ECR — ALWAYS :latest
NEVER use commit hash as image tag in task definitions.
Always use :latest so ECS pulls correct image after CI push.

## SECRETS (Secrets Manager)
aa-cis/dev/rds          → plain DSN string (postgresql://user:pwd@host/db)
aa-cis/dev/anthropic-key → Anthropic API key (legacy — migrate to Bedrock)
aa-cis/dev/dataforseo   → DataForSEO credentials
aa-cis/dev/admin-secret → Admin panel secret

## COST TARGETS
Phase 1: ~$73-100/month
ECS: stop desired=0 after session
RDS: stop instance after session
Lambda: on-demand (no cost when idle)

## SSM ONLY
Never use SSH. All container access via:
aws ecs execute-command --cluster aa-cis-dev-cluster --task {TASK_ARN} --container api --interactive --command "/bin/bash" --profile pqnghiep-admin --region us-west-1
