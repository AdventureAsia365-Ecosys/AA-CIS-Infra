# =============================================================================
# AA-246 Track B — account 005097885195 (aa365), us-west-1
# db_password is NOT set here — supply via TF_VAR_db_password before plan/apply.
# Values marked REPLACE_ME are placeholders: enough for `terraform plan` to
# succeed (plain string interpolation, no data-source validation), but MUST
# be replaced with real values before `terraform apply`.
# =============================================================================

aws_region  = "us-west-1"
environment = "dev"
project     = "aa-cis"
account_id  = "005097885195"

# Own CIDR range (10.2.0.0/16) — non-overlapping with account 1's 10.1.0.0/16
vpc_cidr             = "10.2.0.0/16"
availability_zones   = ["us-west-1a", "us-west-1c"]
public_subnet_cidrs  = ["10.2.1.0/24", "10.2.2.0/24"]
private_subnet_cidrs = ["10.2.10.0/24", "10.2.11.0/24"]
db_subnet_cidrs      = ["10.2.20.0/24", "10.2.21.0/24"]

db_username = "aa_cis_admin"
# db_password — export TF_VAR_db_password before running plan/apply

# ALB HTTPS + API Gateway custom domain (issued in account 005097885195)
acm_certificate_arn = "arn:aws:acm:us-west-1:005097885195:certificate/257ca800-d552-4db7-8ad0-b6ddb72fbed0"
domain_name         = "api-cis-aa365.lumiguides.it.com"

task_cpu              = 512
task_memory           = 1024
service_desired_count = 1

# Secrets NOT covered by modules/secrets data sources — create manually in
# account 005097885195 first, then replace with the real ARNs.
# (secret_rds_arn / secret_dataforseo_arn are wired via module.secrets outputs
# instead — those two secrets MUST exist under names "aa-cis/dev/rds" and
# "aa-cis/dev/dataforseo" before `terraform plan` will succeed at all.)
secret_openai_arn    = "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/openai-key-Wcxuae"
secret_admin_arn     = "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/admin-secret-gudNmP"
secret_jwt_arn       = "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/jwt-secret-KOjq6l"

# Lambda plaintext runtime config — placeholders, enter real values by hand
# (do NOT copy account-1 values across).
database_url        = "postgresql://REPLACE_ME:REPLACE_ME@REPLACE_ME:5432/aa_cis_dev?sslmode=require"
redis_url           = ""
dataforseo_login    = "REPLACE_ME"
dataforseo_password = "REPLACE_ME"

# Not Terraform-managed at all (read at runtime via boto3, see
# api/main.py — secret name "aa-cis/dev/api-keys"). Created manually
# (placeholder) — update with a real APIFY_API_TOKEN key before relying on S2.
