# =============================================================================
# AA-878 (S243): the Mapbox geocoding token secret (AA-675, tour-day extraction) has had no reader
# since AA-712 slice 6a moved extraction to CIS: no code on main reads MAPBOX_GEOCODING_TOKEN_ARN,
# and CloudTrail since 18/10 shows only the plan role (refresh) reading it. Terraform FORGETS the
# secret and its version here; it does not delete them (recovery_window_in_days was 0 in dev, so a
# plain resource removal would have deleted the secret at once, with no recovery). The secret is
# then deleted by hand with a 30-day recovery window after a DRY RUN (AA-878 step M2), and the
# token itself is revoked in the Mapbox account.
#
# AA-1004 slice 3 (S267): the rest of the former tripplanner.tf moved to modules/environment. These two blocks name
# root addresses, so they stay in this root (a `removed` block inside the module would name module addresses).
# =============================================================================
removed {
  from = aws_secretsmanager_secret.tripplanner_mapbox

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret_version.tripplanner_mapbox

  lifecycle {
    destroy = false
  }
}
