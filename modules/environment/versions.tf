# =============================================================================
# AA-1004 P0 — modules/environment: the environment-scoped stack, one instance per account root.
#
# accounts/aa365 (Dev) instantiates it today; the future accounts/aa-prod root (prod plan P3, root
# docs/audits/2026-11-03-S265-ecosystem-restructure/clarifications.md section 5) instantiates the same module with
# its own inputs. It is filled slice by slice with `moved` blocks in accounts/aa365/environment.tf, so each slice
# is a pure no-op for Dev (0 to add, 0 to change, 0 to destroy; plan shows only "has moved to").
#
# Slice 1 (S266): the AA-Booking service stack (booking.tf, booking_media.tf, booking_ops_docs.tf). Slice 2 (S266,
# AA-1004 P1): the AA-Partner CRM stack (crm_*.tf; its root inputs and naming contract in crm_inputs.tf, what the root
# reads back in crm_outputs.tf). What stays in the account root and why: accounts/aa365/environment.tf header.
#
# No provider block and no backend: the root passes its default aws provider (region, default_tags). Account-level
# bootstrap objects (CI roles, permission boundaries, the OIDC provider, the agent session role) never move here;
# each account root keeps its own and passes the ARNs in.
# =============================================================================

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}
