#!/usr/bin/env bash
# AA-1060 — start wrapper of the WordPress test site sidecar (AA-CIS-Infra modules/environment/test_wp.tf, read its
# header first). The task definition runs it as `bash -c "<this file>"` in the official wordpress php-apache image.
#
# Order, and why:
#   1. Foreground, local only (seconds): apache / PHP limits, a STATIC fallback document root that serves the health
#      file (/license.txt) and a short notice, the document root /var/www/site as a symlink to that fallback, then the
#      image's own copy of WordPress into /var/www/html (docker-ensure-installed.sh, which also writes wp-config.php).
#   2. Background: the site set-up (fetch the SQLite plugin and wp-cli at pinned versions, checksums verified; install
#      the site if missing; random passwords for both users; ONE application password from the secret), then the
#      symlink is switched to WordPress. A half-installed WordPress (its installer) is never served; a failed set-up
#      leaves the fallback up and says why in the log, and the host task's health never waits on the network.
#   3. The secret is removed from the environment and apache replaces this shell (PID 1, ECS stop signals reach it).
#
# Idempotent: a container restarted in place re-runs every step on the files already there.
# Inputs (task definition): TEST_WP_HOST, TEST_WP_DEFAULT_USER, TEST_WP_SQLITE_PLUGIN_URL / _SHA256, TEST_WP_CLI_URL /
# _SHA512, and the secret TEST_WP_CREDENTIALS = JSON {site_url, app_user, app_password}. Never prints a password.
set -uo pipefail

WP_DIR=/var/www/html
SITE_LINK=/var/www/site
FALLBACK_DIR=/var/www/fallback
TOOLS_DIR=/usr/local/share/test-wp
ADMIN_USER=site-admin

log() { printf 'test-wp: %s\n' "$*" >&2; }

# A random value nobody keeps: the dashboard passwords (no browser sign-in on this site).
rand() { php -r 'echo bin2hex(random_bytes(24));'; }

# fetch <url> <dest> <sha256|sha512> <expected hex>: download over https only, keep the file only if the checksum matches.
fetch() {
  local url="$1" dest="$2" algo="$3" want="$4" got
  if ! curl -fsSL --proto '=https' --connect-timeout 10 --max-time 180 --retry 3 --retry-delay 5 -o "$dest.part" "$url"; then
    log "download failed: $url"
    rm -f "$dest.part"
    return 1
  fi
  got="$("${algo}sum" "$dest.part" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    log "checksum mismatch ($algo): $url"
    rm -f "$dest.part"
    return 1
  fi
  mv -f "$dest.part" "$dest"
}

# wp-cli as root on the WordPress files (the files are handed to www-data at the end of the set-up).
wpc() {
  timeout 180 php -d memory_limit=128M "$TOOLS_DIR/wp-cli.phar" --allow-root --path="$WP_DIR" --url="https://$TEST_WP_HOST" "$@"
}

fallback_page() {
  printf '<!doctype html><meta charset="utf-8"><meta name="robots" content="noindex,nofollow"><title>Test site</title><p>%s</p>\n' "$1" \
    >"$FALLBACK_DIR/index.html"
}

fail_setup() {
  log "set-up FAILED: $* (the fallback page stays up; /wp-json/ answers 404)"
  fallback_page "This test site is not available. The set-up failed; see the container log."
  return 1
}

# Writes the mu-plugin and the application password helper (both root-owned files, the helper outside the web root).
write_php_files() {
  mkdir -p "$WP_DIR/wp-content/mu-plugins" "$TOOLS_DIR"
  cat >"$WP_DIR/wp-content/mu-plugins/aa-test-site.php" <<'PHP'
<?php
/**
 * Plugin Name: AA test site guard (AA-1060)
 * Description: Test site only. No search indexing, no XML-RPC, no browser sign-in: the REST API with the application password is the only way in.
 */
if ( 'cli' !== PHP_SAPI && ! headers_sent() ) {
	header( 'X-Robots-Tag: noindex, nofollow', true );
}
add_filter( 'xmlrpc_enabled', '__return_false' );
add_filter(
	'pre_option_blog_public',
	static function () {
		return '0';
	}
);
add_action(
	'login_init',
	static function () {
		wp_die( 'Sign-in is disabled on this test site.', 'Not available', array( 'response' => 403 ) );
	}
);
PHP

  cat >"$TOOLS_DIR/app-password.php" <<'PHP'
<?php
// AA-1060: ONE application password ("aa-e2e") for the publishing user, from the secret; it replaces any other.
// WordPress compares application passwords without their non-alphanumeric characters (spaces between groups).
$login = (string) getenv( 'TEST_WP_APP_USER' );
$raw   = (string) getenv( 'TEST_WP_APP_PASSWORD' );
$plain = preg_replace( '/[^a-z\d]/i', '', $raw );
if ( '' === $login || strlen( $plain ) < 24 ) {
	WP_CLI::error( 'app_user or app_password (at least 24 letters and digits) is missing in the secret' );
}
$user = get_user_by( 'login', $login );
if ( ! $user ) {
	WP_CLI::error( 'the publishing user does not exist' );
}
// The same hash WordPress gives a password it creates itself (6.8+: hash_password() = wp_fast_hash(); before: phpass).
$hash = method_exists( 'WP_Application_Passwords', 'hash_password' )
	? WP_Application_Passwords::hash_password( $plain )
	: wp_hash_password( $plain );
update_user_meta(
	$user->ID,
	WP_Application_Passwords::USERMETA_KEY_APPLICATION_PASSWORDS,
	array(
		array(
			'uuid'      => wp_generate_uuid4(),
			'app_id'    => '',
			'name'      => 'aa-e2e',
			'password'  => $hash,
			'created'   => time(),
			'last_used' => null,
			'last_ip'   => null,
		),
	)
);
update_network_option( get_main_network_id(), WP_Application_Passwords::OPTION_KEY_IN_USE, true );
// Self-check through the real authentication function. The two filters make this CLI call count as an API request
// over HTTPS (the site sees HTTPS through the ALB's X-Forwarded-Proto).
add_filter( 'application_password_is_api_request', '__return_true' );
add_filter( 'wp_is_application_passwords_available', '__return_true' );
$checked = wp_authenticate_application_password( null, $login, $raw );
if ( ! ( $checked instanceof WP_User ) || (int) $checked->ID !== (int) $user->ID ) {
	WP_CLI::error( 'application password self-check failed' );
}
WP_CLI::success( 'application password set for the publishing user' );
PHP
}

setup() {
  local creds app_user app_password plugin_zip plugin_dir code i

  for v in TEST_WP_HOST TEST_WP_DEFAULT_USER TEST_WP_SQLITE_PLUGIN_URL TEST_WP_SQLITE_PLUGIN_SHA256 TEST_WP_CLI_URL TEST_WP_CLI_SHA512; do
    [ -n "${!v:-}" ] || { fail_setup "$v is not set"; return 1; }
  done

  # The secret: JSON {site_url, app_user, app_password}. Parsed by PHP (the image has no jq).
  creds="${TEST_WP_CREDENTIALS:-}"
  app_user="$(TEST_WP_CREDENTIALS="$creds" php -r '$j = json_decode((string) getenv("TEST_WP_CREDENTIALS"), true); echo (is_array($j) && isset($j["app_user"]) && is_string($j["app_user"])) ? $j["app_user"] : "";')"
  app_password="$(TEST_WP_CREDENTIALS="$creds" php -r '$j = json_decode((string) getenv("TEST_WP_CREDENTIALS"), true); echo (is_array($j) && isset($j["app_password"]) && is_string($j["app_password"])) ? $j["app_password"] : "";')"
  [ -n "$app_user" ] || app_user="$TEST_WP_DEFAULT_USER"
  if ! [[ "$app_user" =~ ^[A-Za-z0-9._-]{1,60}$ ]] || [ "$app_user" = "$ADMIN_USER" ]; then
    fail_setup "app_user in the secret is not a plain login name"
    return 1
  fi

  mkdir -p "$TOOLS_DIR"
  plugin_zip="$TOOLS_DIR/sqlite-database-integration.zip"
  plugin_dir="$WP_DIR/wp-content/plugins/sqlite-database-integration"
  fetch "$TEST_WP_SQLITE_PLUGIN_URL" "$plugin_zip" sha256 "$TEST_WP_SQLITE_PLUGIN_SHA256" || { fail_setup "SQLite plugin"; return 1; }
  fetch "$TEST_WP_CLI_URL" "$TOOLS_DIR/wp-cli.phar" sha512 "$TEST_WP_CLI_SHA512" || { fail_setup "wp-cli"; return 1; }

  # The SQLite drop-in (no MySQL): the plugin files, then wp-content/db.php from the plugin's db.copy.
  php -r '$z = new ZipArchive(); if ($z->open($argv[1]) !== true || !$z->extractTo($argv[2])) { exit(1); } $z->close();' \
    "$plugin_zip" "$WP_DIR/wp-content/plugins" || { fail_setup "unzip of the SQLite plugin"; return 1; }
  sed -e "s#{SQLITE_IMPLEMENTATION_FOLDER_PATH}#$plugin_dir#g" \
    -e 's#{SQLITE_PLUGIN}#sqlite-database-integration/load.php#g' \
    "$plugin_dir/db.copy" >"$WP_DIR/wp-content/db.php" || { fail_setup "db.php drop-in"; return 1; }
  mkdir -p "$WP_DIR/wp-content/database"
  write_php_files

  if ! wpc core is-installed >/dev/null 2>&1; then
    log "installing the site"
    wpc core install --title="AA test site" --admin_user="$ADMIN_USER" --admin_password="$(rand)" \
      --admin_email="$ADMIN_USER@test-wp.invalid" --skip-email >/dev/null || { fail_setup "wp core install"; return 1; }
  else
    log "site already installed (container restart): resetting users and the application password"
    wpc user update "$ADMIN_USER" --user_pass="$(rand)" --skip-email >/dev/null || { fail_setup "admin password reset"; return 1; }
  fi

  wpc option update blog_public 0 >/dev/null &&
    wpc option update blogdescription "Test site for automated publishing checks. Not a real site." >/dev/null &&
    wpc option update default_comment_status closed >/dev/null &&
    wpc option update users_can_register 0 >/dev/null &&
    wpc rewrite structure '/%postname%/' >/dev/null || { fail_setup "site options"; return 1; }
  wpc plugin activate sqlite-database-integration >/dev/null 2>&1 || log "SQLite plugin not marked active (the drop-in works without it)"

  # The publishing user: an editor (posts, not site settings), random dashboard password.
  if wpc user get "$app_user" --field=ID >/dev/null 2>&1; then
    wpc user update "$app_user" --role=editor --user_pass="$(rand)" --skip-email >/dev/null || { fail_setup "publishing user update"; return 1; }
  else
    wpc user create "$app_user" "publisher@test-wp.invalid" --role=editor --user_pass="$(rand)" \
      --display_name="AA test publisher" >/dev/null || { fail_setup "publishing user create"; return 1; }
  fi

  if [ -n "$app_password" ]; then
    TEST_WP_APP_USER="$app_user" TEST_WP_APP_PASSWORD="$app_password" wpc eval-file "$TOOLS_DIR/app-password.php" \
      || { fail_setup "application password"; return 1; }
  else
    log "no app_password in the secret: the REST sign-in stays off until the secret has one and the container restarts"
  fi

  chown -R www-data:www-data "$WP_DIR/wp-content"

  # Switch the document root to WordPress (atomic rename of the symlink; apache follows it per request).
  ln -sfn "$WP_DIR" "$SITE_LINK.new" && mv -Tf "$SITE_LINK.new" "$SITE_LINK" || { fail_setup "document root switch"; return 1; }
  log "site ready at https://$TEST_WP_HOST/ (publishing user $app_user)"

  # Self-check through apache (log only): /wp-json/ and, with a password, the signed-in /users/me.
  for i in $(seq 1 30); do
    curl -fsS -o /dev/null http://127.0.0.1/license.txt && break
    sleep 1
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $TEST_WP_HOST" -H 'X-Forwarded-Proto: https' http://127.0.0.1/wp-json/)"
  log "self-check GET /wp-json/ -> $code"
  if [ -n "$app_password" ]; then
    # The credentials go to curl on stdin (-K -), never on its command line.
    code="$(printf 'user = "%s:%s"\n' "$app_user" "$app_password" | curl -s -K - -o /dev/null -w '%{http_code}' \
      -H "Host: $TEST_WP_HOST" -H 'X-Forwarded-Proto: https' http://127.0.0.1/wp-json/wp/v2/users/me)"
    log "self-check signed-in GET /wp-json/wp/v2/users/me -> $code"
  fi
}

# ---- 1. Foreground (local only) ----------------------------------------------------------------------------------
# Small footprint: the Booking admin shares this task's 512 MB (hard cap of this container: 256 MB).
cat >/etc/apache2/conf-enabled/zz-test-wp.conf <<'CONF'
<IfModule mpm_prefork_module>
	StartServers 1
	MinSpareServers 1
	MaxSpareServers 2
	MaxRequestWorkers 3
	MaxConnectionsPerChild 500
</IfModule>
ServerTokens Prod
ServerSignature Off
CONF
cat >/usr/local/etc/php/conf.d/zz-test-wp.ini <<'INI'
memory_limit = 96M
opcache.memory_consumption = 32
expose_php = Off
upload_max_filesize = 8M
post_max_size = 10M
INI

mkdir -p "$FALLBACK_DIR"
cp -f /usr/src/wordpress/license.txt "$FALLBACK_DIR/license.txt"
fallback_page "This test site is starting."
ln -sfn "$FALLBACK_DIR" "$SITE_LINK.new" && mv -Tf "$SITE_LINK.new" "$SITE_LINK"
sed -i 's#DocumentRoot /var/www/html$#DocumentRoot /var/www/site#' /etc/apache2/sites-available/000-default.conf

# wp-config.php extras: the image's wp-config.php evaluates WORDPRESS_CONFIG_EXTRA from the environment on every load
# (apache and wp-cli both inherit it from this shell). Its proxy block already turns X-Forwarded-Proto https into
# HTTPS on, which application passwords require.
export WORDPRESS_CONFIG_EXTRA="
define( 'WP_HOME', 'https://' . getenv( 'TEST_WP_HOST' ) );
define( 'WP_SITEURL', 'https://' . getenv( 'TEST_WP_HOST' ) );
define( 'DISALLOW_FILE_MODS', true );
define( 'DISALLOW_FILE_EDIT', true );
define( 'AUTOMATIC_UPDATER_DISABLED', true );
define( 'DISABLE_WP_CRON', true );
define( 'WP_ENVIRONMENT_TYPE', 'staging' );
"
cd "$WP_DIR" || exit 1
docker-ensure-installed.sh true || log "copy of WordPress reported an error (the set-up will say what is missing)"

# ---- 2. Background set-up ----------------------------------------------------------------------------------------
setup &

# ---- 3. Apache in the foreground, without the secret ------------------------------------------------------------
unset TEST_WP_CREDENTIALS
exec docker-entrypoint.sh apache2-foreground
