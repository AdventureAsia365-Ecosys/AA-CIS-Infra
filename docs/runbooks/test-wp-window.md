# WordPress test site: opening and closing an E2E test window (AA-1185)

The WordPress test site (`https://test-wp.<zone>`, AA-1060) is a sidecar container of the Booking admin task. The
CIS WordPress publish path and its retire / restore check use it. Since AA-1185 (tech lead decision Q10 of the S295
security audit) it is **off outside a test window**: both switches in `accounts/aa365/terraform.tfvars` are `false`,
so no WordPress image runs, nothing answers on the host and the nightly Image Scan has nothing to report on it.

Design and switches: header of `modules/environment/test_wp.tf` and `accounts/aa365/test_wp_edge.tf`.

## Open a window

1. **Image.** The nightly Image Scan (`.github/workflows/image-scan.yml`) scans every image that runs. Check that the
   pinned `test_wp_image` (`modules/environment/test_wp.tf`) has no fixable finding at the gate severity:
   - read the newest digest of the same tag on `public.ecr.aws/docker/library/wordpress` (the official images are
     rebuilt under the same tag);
   - if it differs from the pin, move the pin to it in the same PR as step 2 (Trivy `image --platform linux/arm64`
     on the new digest first);
   - if a fixable finding has no rebuilt image yet, add a dated row to the root exception register
     `docs/security/vuln-exceptions.toml` and the mirror line in `.trivyignore`, both expiring when the window ends
     (at most a few days), approved by the tech lead.
2. **PR 1** sets `test_wp_enabled = true` (container, target group, ALB rules, DNS record, security group port).
   Merge, let Terraform Apply run.
3. **Deploy the Booking admin** (AA-Booking `deploy-admin-dev.yml`): the deploy copies the family's latest revision,
   which now has the sidecar.
4. **PR 2** sets `test_wp_service_attached = true` (the service registers the sidecar in its target group; ECS
   refuses this before step 3). Merge, let Terraform Apply run.
5. Check: `curl -s -o /dev/null -w '%{http_code}' https://test-wp.<zone>/wp-json/` → `200`;
   `curl -s -o /dev/null -w '%{http_code}' https://test-wp.<zone>/xmlrpc.php/` → `403`;
   `curl -s -o /dev/null -w '%{http_code}' https://test-wp.<zone>/wp-json/wp/v2/users` → `404` (no anonymous user list).

## Close the window (the same day the checks are done)

1. **One PR** sets both switches back to `false`. Merge, let Terraform Apply run. The service drops the second target
   group (ECS starts a new deployment of the revision it runs), then the rules, target group, DNS record and port go.
2. **Deploy the Booking admin** again: the family's latest revision (registered by the apply) has no sidecar, so the
   WordPress container stops with this deployment.
3. Check: `aws ecs describe-tasks` on the Booking admin service shows one container; the next Image Scan run lists no
   WordPress digest; remove any exception row added in step 1 of the opening.

Cost: 0 USD either way (the sidecar shares the Booking admin task; one target group and two rules on the existing ALB).
