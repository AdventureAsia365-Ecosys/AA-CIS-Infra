"""AA-1060: offline guards for the WordPress test site sidecar of the Booking admin task.

1. The sidecar lives only in the Booking admin task, is non-essential, has a soft and a hard memory limit inside the
   unchanged 256 / 512 task, no CPU weight of its own, no restart policy (perpetual diff), and logs to the Booking
   admin log group.
2. Every artifact it runs is pinned: the image by digest, the SQLite plugin and wp-cli by version and checksum.
3. The secret is the whole existing test secret (no JSON key, so a missing key never blocks the task start), and
   Terraform only describes it (no secret version).
4. The target group checks a static file, never a WordPress path: an unhealthy target in ANY target group makes ECS
   replace the task, and the Booking admin would restart with it.
5. The ALB blocks sign-in, the dashboard and XML-RPC above the forward rule; both are host rules on the HTTPS listener
   behind the existing wildcard certificate; DNS, security group port and service attachment follow the switches.
6. The start script: valid bash, apache on a fallback root first, set-up in the background, the secret removed before
   apache, no password on a command line of curl or in the log, WordPress switched in only after the set-up.

Offline: reads the .tf files and the script; no Terraform, no AWS, no PHP. Run from the repo root:
    python3 -m pytest -p no:cacheprovider -q tools/terraform/tests/test_aa1060_test_wp.py
"""
from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AA365 = ROOT / "accounts" / "aa365"
ENV = ROOT / "modules" / "environment"
TEST_WP = (ENV / "test_wp.tf").read_text(encoding="utf-8")
STAFF = (ENV / "staff_web.tf").read_text(encoding="utf-8")
SCRIPT_PATH = ENV / "test_wp" / "start.sh"
SCRIPT = SCRIPT_PATH.read_text(encoding="utf-8")
EDGE = (AA365 / "test_wp_edge.tf").read_text(encoding="utf-8")
RULES = (AA365 / "alb_rules.tf").read_text(encoding="utf-8")
SGS = (AA365 / "app_security_groups.tf").read_text(encoding="utf-8")
ENVIRONMENT = (AA365 / "environment.tf").read_text(encoding="utf-8")


def _block_after(text: str, start: int) -> str:
    """Text of the brace-balanced block whose opening brace is the first one at or after ``start``."""
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i : j + 1]
    raise AssertionError("unbalanced braces")


def _resource(text: str, kind: str, name: str) -> str:
    m = re.search(rf'^resource "{kind}" "{name}" \{{', text, re.M)
    assert m, f"{kind}.{name} not found"
    return _block_after(text, m.start())


def _code(block: str) -> str:
    return "\n".join(line for line in block.splitlines() if not line.strip().startswith("#"))


def _local(name: str) -> str:
    m = re.search(rf'^\s*{name}\s*=\s*"([^"]*)"', TEST_WP, re.M)
    assert m, f"local {name} not found"
    return m.group(1)


def _sidecar() -> str:
    start = TEST_WP.index("test_wp_container_definitions = var.test_wp_enabled ? [")
    return _code(TEST_WP[start : TEST_WP.index("] : []", start)])


# 1. Placement and size ---------------------------------------------------------------------------------------------


def test_sidecar_only_in_the_booking_admin_task_and_the_task_size_is_unchanged():
    assert 'test_wp_host_app  = "booking"' in TEST_WP
    td = _resource(STAFF, "aws_ecs_task_definition", "staff_web")
    assert "each.key == local.test_wp_host_app ? local.test_wp_container_definitions : []" in td
    assert 'cpu                      = "256"' in td and 'memory                   = "512"' in td


def test_sidecar_is_non_essential_with_soft_and_hard_memory_and_no_cpu_weight():
    side = _sidecar()
    assert "essential = false" in side
    reservation = int(re.search(r"memoryReservation\s*=\s*(\d+)", side).group(1))
    hard = int(re.search(r"^\s*memory\s*=\s*(\d+)", side, re.M).group(1))
    assert 0 < reservation < hard <= 256, "the Booking admin keeps at least half of the 512 MB task"
    assert not re.search(r"^\s*cpu\s*=", side, re.M), "a cpu value would outweigh the admin container (no cpu set)"
    assert "restartPolicy" not in side, "perpetual task definition diff (header of test_wp.tf)"
    assert '"awslogs-group"         = aws_cloudwatch_log_group.staff_web[local.test_wp_host_app].name' in side
    assert 'entryPoint        = ["bash", "-c"]' in side
    assert 'command           = [file("${path.module}/test_wp/start.sh")]' in side


def test_script_fits_comfortably_in_the_task_definition():
    # A task definition is at most 64 KiB; the script is the command string of the sidecar.
    assert len(SCRIPT.encode("utf-8")) < 24 * 1024


# 2. Pins -----------------------------------------------------------------------------------------------------------


def test_image_plugin_and_wp_cli_are_pinned():
    assert re.fullmatch(r"public\.ecr\.aws/docker/library/wordpress@sha256:[0-9a-f]{64}", _local("test_wp_image"))
    assert re.fullmatch(
        r"https://downloads\.wordpress\.org/plugin/sqlite-database-integration\.\d+\.\d+\.\d+\.zip",
        _local("test_wp_sqlite_plugin_url"),
    )
    assert re.fullmatch(r"[0-9a-f]{64}", _local("test_wp_sqlite_plugin_sha256"))
    assert re.fullmatch(
        r"https://github\.com/wp-cli/wp-cli/releases/download/v\d+\.\d+\.\d+/wp-cli-\d+\.\d+\.\d+\.phar",
        _local("test_wp_cli_url"),
    )
    assert re.fullmatch(r"[0-9a-f]{128}", _local("test_wp_cli_sha512"))
    side = _sidecar()
    for env in (
        "TEST_WP_SQLITE_PLUGIN_URL",
        "TEST_WP_SQLITE_PLUGIN_SHA256",
        "TEST_WP_CLI_URL",
        "TEST_WP_CLI_SHA512",
        "TEST_WP_HOST",
        "TEST_WP_DEFAULT_USER",
    ):
        assert f'name = "{env}"' in side, env
        assert env in SCRIPT, env


# 3. Secret ---------------------------------------------------------------------------------------------------------


def test_secret_is_the_whole_existing_test_secret_described_only():
    side = _sidecar()
    assert (
        '{ name = "TEST_WP_CREDENTIALS", valueFrom = data.aws_secretsmanager_secret.test_wp_credentials[0].arn }'
        in side
    )
    assert "::" not in side, "no JSON key: a missing key would stop the whole task from starting"
    data = _code(TEST_WP[TEST_WP.index('data "aws_secretsmanager_secret" "test_wp_credentials"') :])
    assert 'name = "aa-cis/${var.environment}/e2e-wordpress-test"' in data
    assert "aws_secretsmanager_secret_version" not in _code(TEST_WP)
    assert 'resource "aws_secretsmanager_secret"' not in TEST_WP, "reuses the existing test secret ($0)"


# 4. Health ---------------------------------------------------------------------------------------------------------


def test_target_group_checks_a_static_file_present_in_both_roots():
    assert 'test_wp_health_path = "/license.txt"' in TEST_WP
    tg = _code(_resource(TEST_WP, "aws_lb_target_group", "test_wp"))
    assert "path                = local.test_wp_health_path" in tg
    assert 'matcher             = "200"' in tg
    assert "count = local.test_wp_on" in tg
    # The fallback root serves the same file before and after a failed set-up; WordPress ships it at its root.
    assert 'cp -f /usr/src/wordpress/license.txt "$FALLBACK_DIR/license.txt"' in SCRIPT


# 5. Edge and switches ----------------------------------------------------------------------------------------------


def test_alb_blocks_sign_in_paths_above_the_forward_rule():
    pri = _block_after(RULES, RULES.index("alb_https_rule_priorities"))
    block_p = int(re.search(r"test_wp_block\s*=\s*(\d+)", pri).group(1))
    fwd_p = int(re.search(r"test_wp\s*=\s*(\d+)", pri).group(1))
    assert block_p < fwd_p

    block = _code(_resource(RULES, "aws_lb_listener_rule", "test_wp_block"))
    assert "listener_arn = module.alb.https_listener_arn" in block
    assert 'type = "fixed-response"' in block and 'status_code  = "403"' in block
    assert "values = [local.test_wp_host]" in block and "values = local.test_wp_blocked_paths" in block
    paths = re.findall(r'"([^"]+)"', EDGE[EDGE.index("test_wp_blocked_paths") :].split("]")[0])
    assert set(paths) == {"/wp-login.php", "/wp-admin", "/wp-admin/*", "/xmlrpc.php"}
    assert len(paths) <= 4, "an ALB rule takes at most 5 condition values (1 host + 4 paths)"

    fwd = _code(_resource(RULES, "aws_lb_listener_rule", "test_wp"))
    assert "listener_arn = module.alb.https_listener_arn" in fwd
    assert "target_group_arn = module.environment.test_wp_target_group_arn" in fwd
    assert "values = [local.test_wp_host]" in fwd
    for body in (block, fwd):
        assert "count = local.test_wp_on" in body
        assert "depends_on = [aws_lb_listener_certificate.staff_web]" in body


def test_host_is_covered_by_the_existing_wildcard_certificate():
    assert 'test_wp_host = "test-wp.${var.dns_zone_name}"' in EDGE
    assert 'test_wp_host      = "test-wp.${var.dns_zone_name}"' in TEST_WP
    # One label under the zone: *.<zone> (staff_web_edge.tf) covers it, no new certificate.
    assert "aws_acm_certificate" not in _code(EDGE)
    staff_edge = (AA365 / "staff_web_edge.tf").read_text(encoding="utf-8")
    assert 'staff_web_cert_domain = "*.${var.dns_zone_name}"' in staff_edge


def test_dns_security_group_and_attachment_follow_the_switches():
    rec = _code(_resource(EDGE, "aws_route53_record", "test_wp"))
    assert "count = local.test_wp_on" in rec and 'type    = "CNAME"' in rec
    assert "records = [module.alb.alb_dns_name]" in rec

    sg = _code(_resource(SGS, "aws_security_group", "staff_web"))
    dyn = [b for b in re.finditer(r'dynamic "ingress"', sg)]
    bodies = [_block_after(sg, m.start()) for m in dyn]
    wp = [b for b in bodies if "test_wp" in b]
    assert len(wp) == 1
    assert "for_each = var.test_wp_enabled ? [module.environment.test_wp_port] : []" in wp[0]
    assert "security_groups = [module.vpc.sg_alb_id]" in wp[0] and "cidr_blocks" not in wp[0]

    assert "test_wp_enabled          = var.test_wp_enabled" in ENVIRONMENT
    assert "test_wp_service_attached = var.test_wp_service_attached" in ENVIRONMENT
    assert "aws_lb_listener_rule.test_wp[*].arn" in ENVIRONMENT, "the service waits for the forward rule"
    # Attaching needs the container in the running revision first (two applies): the module refuses attach alone.
    assert "condition     = !var.test_wp_service_attached || var.test_wp_enabled" in TEST_WP


def test_new_resources_carry_app_and_component():
    assert re.search(r'App\s*=\s*"cis"', TEST_WP) and re.search(r'Component\s*=\s*"web"', TEST_WP)
    assert 'App = "cis", Component = "web", Issue = "AA-1060"' in EDGE
    assert "tags = local.test_wp_tags" in _resource(TEST_WP, "aws_lb_target_group", "test_wp")


# 6. Start script ---------------------------------------------------------------------------------------------------


def test_script_is_valid_bash():
    bash = shutil.which("bash")
    assert bash, "bash is needed for this check"
    res = subprocess.run([bash, "-n", str(SCRIPT_PATH)], capture_output=True, text=True, check=False)
    assert res.returncode == 0, res.stderr


def test_script_order_fallback_then_background_setup_then_apache_without_the_secret():
    lines = [ln.strip() for ln in SCRIPT.splitlines() if ln.strip() and not ln.strip().startswith("#")]
    assert lines[-3:] == ["setup &", "unset TEST_WP_CREDENTIALS", "exec docker-entrypoint.sh apache2-foreground"]
    # The document root is the symlink, pointed at the fallback before apache starts.
    assert "sed -i 's#DocumentRoot /var/www/html$#DocumentRoot /var/www/site#'" in SCRIPT
    fg = SCRIPT[SCRIPT.index("# ---- 1. Foreground") :]
    assert fg.index('ln -sfn "$FALLBACK_DIR" "$SITE_LINK.new"') < fg.index("docker-ensure-installed.sh true")
    # Inside the set-up, WordPress is switched in only after install, users and the application password.
    setup = SCRIPT[SCRIPT.index("setup() {") : SCRIPT.index("# ---- 1. Foreground")]
    switch = setup.index('ln -sfn "$WP_DIR" "$SITE_LINK.new"')
    for step in ("wpc core install", "wpc user create", 'wpc eval-file "$TOOLS_DIR/app-password.php"'):
        assert setup.index(step) < switch, step


def test_script_hardening():
    for needle in (
        "define( 'DISALLOW_FILE_MODS', true );",
        "define( 'DISALLOW_FILE_EDIT', true );",
        "wpc option update blog_public 0",
        "X-Robots-Tag: noindex, nofollow",
        "add_filter( 'xmlrpc_enabled', '__return_false' );",
        "'login_init'",
        "--role=editor",
        "--proto '=https'",
    ):
        assert needle in SCRIPT, needle
    # Downloads are verified before use.
    assert 'got="$("${algo}sum" "$dest.part" | cut -d\' \' -f1)"' in SCRIPT
    assert 'fetch "$TEST_WP_SQLITE_PLUGIN_URL" "$plugin_zip" sha256 "$TEST_WP_SQLITE_PLUGIN_SHA256"' in SCRIPT
    assert 'fetch "$TEST_WP_CLI_URL" "$TOOLS_DIR/wp-cli.phar" sha512 "$TEST_WP_CLI_SHA512"' in SCRIPT


def test_script_never_puts_the_application_password_in_the_log_or_on_a_curl_command_line():
    value_refs = ("$app_password", "${app_password", "$TEST_WP_CREDENTIALS", "${TEST_WP_CREDENTIALS", "$creds", "${creds")
    for ln in SCRIPT.splitlines():
        if re.match(r"\s*(log|fail_setup|echo|printf) ", ln):
            assert not any(ref in ln for ref in value_refs), ln
        if "curl" in ln and "$app_password" in ln:
            # printf is a bash builtin (no process argv); curl reads the credentials from stdin (-K -).
            pre, _, post = ln.partition("| curl")
            assert "printf 'user = " in pre and post.startswith(" -s -K - "), ln
    assert "| curl -s -K - " in SCRIPT, "credentials reach curl on stdin"
    # The application password reaches wp-cli through the environment of that one call, not as an argument.
    assert 'TEST_WP_APP_USER="$app_user" TEST_WP_APP_PASSWORD="$app_password" wpc eval-file' in SCRIPT
