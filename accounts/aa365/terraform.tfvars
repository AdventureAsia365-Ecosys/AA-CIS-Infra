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
secret_openai_arn = "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/openai-key-Wcxuae"
secret_admin_arn  = "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/admin-secret-gudNmP"
secret_jwt_arn    = "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/jwt-secret-KOjq6l"

# Lambda plaintext runtime config — placeholders, enter real values by hand
# (do NOT copy account-1 values across).
database_url        = "postgresql://REPLACE_ME:REPLACE_ME@REPLACE_ME:5432/aa_cis_dev?sslmode=require"
dataforseo_login    = "REPLACE_ME"
dataforseo_password = "REPLACE_ME"

# "aa-cis/dev/api-keys" (APIFY_API_TOKEN placeholder, created by hand, never Terraform-managed):
# AA-878 (S243) found no reader on main of any repo (api/main.py no longer reads it); it is an
# orphan, deleted by hand with a 30-day recovery window after a DRY RUN (AA-878 step M2).

# AA-Booking (S235): immutable GitHub repo id — pins the aa-booking-dev-app-deploy OIDC trust to this repo.
booking_github_repo_id = "1418188499"

# AA-Partner (S248, AA-933): immutable GitHub repo id — pins the aa-crm-dev-app-deploy OIDC trust to this repo.
crm_github_repo_id = "1430388300"

# AA-939 (S249): the CRM web signs in with the partner pool (partner-web client, MFA required). The e2e users exist on
# the partner pool and are members of the synthetic agencies; after the apply: crm_dev_identity.py web-secret --pool
# partner --apply, then deploy the web.
crm_partner_signin_enabled = true

# AA-938 (S249): the F3 scrub guardrail (detect only) and its grants (crm_scrub.tf). The apply-role statements
# CrmBedrockGuardrail* were applied locally with MFA first (bootstrap). ~$0.75/month.
crm_scrub_guardrail_enabled = true

# AA-811 (S238): AA-Booking sends the staff "new inquiry" e-mail (SES, ses.tf) to this inbox on Dev.
booking_staff_notify_email = "nghieppham@adventure.asia"

# AA-871 (S247): map booking/dev/sentry-dsn into the Booking task (SENTRY_DSN + SENTRY_REQUIRED=true).
# Only after the secret holds the DSN of Sentry project aa-booking-api (ECS cannot start a task on a
# secret with no value); the next AA-Booking deploy carries the new task-definition revision.
booking_sentry_enabled = true

# AA-828 (S238): CIS spend budget alert e-mails (job ops_alert_email, SES) go to this inbox on Dev.
cis_ops_alert_email = "nghieppham@adventure.asia"

# AA-908 (S250): the shared Cognito web ACL with the rate rules on the WORKFORCE, EXTERNAL and PARTNER pools
# (about $9/month: $5 ACL + 4 rules; Nghiep's go in the S250 pre-approval).
identity_waf_enabled = true
# AA-908 S4/S5 (S250, option b): traveller native sign-up on, for the TripPlanner BFF's passwordless SignUp
# (email code only, root ADR 0006 decisions 1 and 4; no password is ever sent). The pre sign-up trigger allows it
# on the traveller clients only (tripplanner, booking-customer), and only with the BFF's signed proof in
# ValidationData (identity.tf identity_traveller_signup_proof): a direct public-API SignUp with a password and the
# managed-login /signup page are refused.
identity_external_native_signup_enabled = true

# AA-945 (S252): Google OAuth client stored in crm/dev/mail-oauth; map it into the CRM task as MAIL_OAUTH.
crm_mail_oauth_enabled = true

# AA-979 P2b: portal.lumiguides.it.com points at the crm_agency CloudFront distribution since the S253 cutover; the
# switch crm_agency_live and the Vercel rollback target were removed at the clean-up (runbook 4.5, S256).
