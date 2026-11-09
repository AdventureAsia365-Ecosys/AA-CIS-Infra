# =============================================================================
# AA-1060 (S274, tech lead approved the design and its $0 cost on 09/11/2026) — a permanent WordPress TEST site as a
# SIDECAR container of the Booking admin task (staff_web.tf, app key booking). The CIS WordPress publish path and its
# retire -> restore check need a WordPress site that stays up; free hosted test sites expire in days.
#
# Why the Booking admin task (and not the TripPlanner web task):
#   - Terraform owns its task definition (staff_web.tf), and its deploy (AA-Booking deploy-admin-dev.yml) copies the
#     family's latest revision and swaps only the image of the container it names, so an extra container survives
#     every app deploy (its one-container guard is relaxed in the same wave).
#   - It sits behind the shared ALB's HTTPS listener with the wildcard certificate *.<zone> (staff_web_edge.tf): the
#     test host needs one host rule, one target group and one DNS record. The TripPlanner web is reached only through
#     its own CloudFront distribution and the origin-secret host rules on :80 (a new host there means a new
#     distribution or alias, a us-east-1 certificate and web ACL changes).
#   - Headroom: 512 MB, max ~14 % used over 3 days (CloudWatch MemoryUtilization, 09/11/2026).
#
# The container (local.test_wp_container_definitions, appended to the Booking admin task by staff_web.tf):
#   - image public.ecr.aws/docker/library/wordpress (php-apache, ARM64 in the multi-arch index), pinned by digest
#   - essential = false: a WordPress fault never stops the Booking admin task by itself (no restart policy, see below)
#   - memory: soft 128 MB (reservation), hard 256 MB (an OOM kills WordPress, never the admin), no cpu share
#   - command: test_wp/start.sh (read it first): apache starts at once on a static fallback root that serves the
#     health file, the site set-up (SQLite plugin + wp-cli at pinned versions with checksums, install if missing,
#     random passwords for both users, ONE application password from the secret) runs in the background, and only a
#     finished site is switched in. Data is ephemeral: a new task re-creates the site; the application password stays
#     the same because it comes from the secret.
#   - secret: the WHOLE existing test secret aa-cis/<env>/e2e-wordpress-test (JSON {site_url, app_user,
#     app_password}, the one the agent E2E channel checks already read; no new secret, $0) as TEST_WP_CREDENTIALS.
#     A whole-secret reference (no JSON key) so a missing key never stops the task from starting; the script logs it
#     and leaves the REST sign-in off.
#   - logs: the Booking admin log group (30 days), stream prefix test-wp; no new log group.
#
# Two switches (accounts/aa365 test_wp_edge.tf):
#   - test_wp_enabled: the container in the task definition, the target group, the ALB rules, the DNS record and
#     the security group port. The running task gets the container at the next Booking admin deploy (the service
#     ignores task_definition).
#   - test_wp_service_attached: the service's second load_balancer block (ECS registers the container in the target
#     group). Turned on only AFTER the Booking admin runs a revision with the container: ECS refuses a load balancer
#     naming a container that the service's current task definition lacks. Two applies, like the S271 :443 opening.
#
# Health check: /license.txt, a static file served from both the fallback root and WordPress. A deeper path
# (/wp-json/) would let a WordPress fault fail the target group, and ECS replaces a task whose target is unhealthy in
# ANY of its target groups: the Booking admin would restart with it. The site itself is checked live
# (https://test-wp.<zone>/wp-json/ 200, the live steps of the PR).
#
# Security: no browser sign-in (the ALB answers 403 on /wp-login.php, /wp-admin and /xmlrpc.php, and the mu-plugin
# refuses login_init), DISALLOW_FILE_MODS (no plugin or theme install, no update), both users get random passwords
# nobody knows at every start, the publishing user is an editor (posts only), noindex (blog_public 0 + X-Robots-Tag).
# The secret is unset before apache starts, so PHP never sees it.
#
# Cost: $0 Fargate (the task size does not change), no new secret, no new log group, no alarm; one target group and
# two listener rules on the existing ALB (no extra LCU at test volume), one Route 53 record (no per-record charge).
# =============================================================================

variable "test_wp_enabled" {
  description = "AA-1060: true adds the WordPress test site sidecar to the Booking admin task definition, with its target group (the root adds the ALB rules, DNS record and security group port)."
  type        = bool
  default     = false
}

variable "test_wp_service_attached" {
  description = "AA-1060: true registers the sidecar in its target group (second load_balancer block of the Booking admin service). Only after the Booking admin runs a revision that has the container (header)."
  type        = bool
  default     = false

  validation {
    condition     = !var.test_wp_service_attached || var.test_wp_enabled
    error_message = "test_wp_service_attached needs test_wp_enabled."
  }
}

locals {
  test_wp_on = var.test_wp_enabled ? 1 : 0

  # The host task: the Booking admin (staff_web.tf local.staff_web_apps key).
  test_wp_host_app  = "booking"
  test_wp_container = "test-wp"
  test_wp_port      = 80
  test_wp_host      = "test-wp.${var.dns_zone_name}"

  # Static file in both document roots (start.sh): the target group health never depends on WordPress itself.
  test_wp_health_path = "/license.txt"

  # wordpress:7.1.4-php8.4-apache, multi-arch index digest (linux/arm64/v8 included), read 09/11/2026 from
  # public.ecr.aws/docker/library/wordpress. A digest, never a tag: the official images are rebuilt under the same tag.
  test_wp_image = "public.ecr.aws/docker/library/wordpress@sha256:543d2b75f287c76f387cd17dcf2ca5e69745a1c30b754e32414a5e1ef5b8da87"

  # Fetched by start.sh at every start, checksums verified before use (sha256 of the release zip on wordpress.org;
  # sha512 published next to the wp-cli phar on GitHub).
  test_wp_sqlite_plugin_url    = "https://downloads.wordpress.org/plugin/sqlite-database-integration.3.1.3.zip"
  test_wp_sqlite_plugin_sha256 = "f6ce35e8419d0b9326221a907627d905e25c2a5ba2afc86492811f14c851efe0"
  test_wp_cli_url              = "https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar"
  test_wp_cli_sha512           = "be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832"

  # The publishing user when the secret has no app_user.
  test_wp_default_user = "aa-e2e-publisher"

  test_wp_tags = {
    App       = "cis" # who uses it: the CIS publish path checks (it runs in the Booking admin task at no cost)
    Component = "web"
    Issue     = "AA-1060"
  }

  test_wp_container_definitions = var.test_wp_enabled ? [
    {
      name      = local.test_wp_container
      image     = local.test_wp_image
      essential = false
      # Soft share for the scheduler, hard cap so an out-of-memory kills WordPress, never the Booking admin. No cpu
      # value: both containers keep the same (minimum) CPU weight.
      memoryReservation = 128
      memory            = 256
      portMappings      = [{ containerPort = local.test_wp_port, protocol = "tcp" }]
      entryPoint        = ["bash", "-c"]
      command           = [file("${path.module}/test_wp/start.sh")]
      environment = [
        { name = "TEST_WP_HOST", value = local.test_wp_host },
        { name = "TEST_WP_DEFAULT_USER", value = local.test_wp_default_user },
        { name = "TEST_WP_SQLITE_PLUGIN_URL", value = local.test_wp_sqlite_plugin_url },
        { name = "TEST_WP_SQLITE_PLUGIN_SHA256", value = local.test_wp_sqlite_plugin_sha256 },
        { name = "TEST_WP_CLI_URL", value = local.test_wp_cli_url },
        { name = "TEST_WP_CLI_SHA512", value = local.test_wp_cli_sha512 },
      ]
      # The whole secret, no JSON key (header): a missing key never blocks the task start.
      secrets = [
        { name = "TEST_WP_CREDENTIALS", valueFrom = data.aws_secretsmanager_secret.test_wp_credentials[0].arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.staff_web[local.test_wp_host_app].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = local.test_wp_container
        }
      }
      # No restartPolicy: the provider compares container definitions after a read, and an empty ignoredExitCodes list
      # in the read-back would show a diff (a new revision) on every plan. A stopped sidecar fails its target group,
      # ECS replaces the task and the new one re-creates the site.
      stopTimeout = 10
    }
  ] : []
}

# The existing test-only secret (secrets register: aa-cis/<env>/e2e-wordpress-test, managed by cli). Read by name:
# Terraform never creates it and never reads its value (DescribeSecret only).
data "aws_secretsmanager_secret" "test_wp_credentials" {
  count = local.test_wp_on

  name = "aa-cis/${var.environment}/e2e-wordpress-test"
}

# -----------------------------------------------------------------------------
# Target group. The HTTPS host rule in front of it is accounts/aa365 alb_rules.tf test_wp.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "test_wp" {
  count = local.test_wp_on

  name                 = "aa-booking-${var.environment}-test-wp-tg"
  port                 = local.test_wp_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = 10

  health_check {
    enabled             = true
    path                = local.test_wp_health_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = local.test_wp_tags
}

# -----------------------------------------------------------------------------
# Outputs (names only).
# -----------------------------------------------------------------------------
output "test_wp_host" {
  description = "AA-1060: public host of the WordPress test site (empty while test_wp_enabled is false)."
  value       = var.test_wp_enabled ? local.test_wp_host : ""
}

output "test_wp_port" {
  description = "AA-1060: container port of the sidecar (the staff web security group admits it from the ALB)."
  value       = local.test_wp_port
}

output "test_wp_target_group_arn" {
  description = "AA-1060: target group of the WordPress test site (empty while test_wp_enabled is false)."
  value       = one(aws_lb_target_group.test_wp[*].arn)
}
