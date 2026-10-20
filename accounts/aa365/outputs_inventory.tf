# =============================================================================
# AA-893 step 2 — core inventory outputs of the acc2 root.
#
# One place to look up the IDs and names of the network, database, compute and edge resources instead
# of copying them into docs (they change on a replace). Read them with
#   terraform -chdir=accounts/aa365 output -json
# or from the generated pages in the root repo (docs/generated/{network,inventory,iam-roles}.md),
# which tools/docs/gen_docs.py renders from the state (workflow docs-gen.yml) and which list these
# outputs too. Outputs only: no resource, no cost. None is sensitive (no secret, no password).
# =============================================================================

output "network_vpc_id" {
  description = "The one VPC of the dev stack (all three apps)."
  value       = module.vpc.vpc_id
}

output "network_subnet_ids" {
  description = "Subnet IDs per tier: public (ALB, NAT), private (ECS, Lambda), db (RDS, Redis)."
  value = {
    public  = module.vpc.public_subnet_ids
    private = module.vpc.private_subnet_ids
    db      = module.vpc.db_subnet_ids
  }
}

output "network_security_group_ids" {
  description = "Security group IDs by role (ADR 0004b: one group per caller, plus the shared legacy groups)."
  value = {
    alb         = module.vpc.sg_alb_id
    app_shared  = module.vpc.sg_app_id
    rds         = module.vpc.sg_rds_id
    nlb         = module.alb.nlb_security_group_id
    cis_api     = aws_security_group.cis_api.id
    cis_worker  = aws_security_group.cis_worker.id
    booking_api = aws_security_group.booking_api.id
    tp_lambda   = aws_security_group.tp_lambda.id
    db_migrate  = aws_security_group.db_migrate.id
    ops_lambda  = aws_security_group.ops_lambda.id
  }
}

output "network_nat_instance_id" {
  description = "NAT instance carrying all private-subnet egress."
  value       = module.vpc.nat_instance_id
}

output "rds_instance" {
  description = "The shared RDS instance (CIS, TripPlanner, Booking). No credentials here: see the secrets register."
  value = {
    identifier = module.rds.db_identifier
    endpoint   = module.rds.db_endpoint
    port       = module.rds.db_port
  }
}

output "ecs" {
  description = "ECS cluster and its services."
  value = {
    cluster_name = module.ecs.cluster_name
    services     = [module.ecs.service_name, module.ecs.worker_service_name, aws_ecs_service.booking.name]
  }
}

output "load_balancers" {
  description = "Internet-facing ALB and the internal NLB behind the API Gateway VPC link."
  value = {
    alb_dns_name = module.alb.alb_dns_name
    alb_arn      = module.alb.alb_arn
    nlb_dns_name = module.alb.nlb_dns_name
  }
}

output "api_gateway" {
  description = "REST APIs (CIS, Booking) with their stage, the shared VPC link, and the TripPlanner HTTP API."
  value = {
    cis_rest_api_id         = module.api_gateway.api_gateway_id
    cis_stage               = module.api_gateway.stage_name
    booking_rest_api_id     = aws_api_gateway_rest_api.booking.id
    booking_stage           = aws_api_gateway_stage.booking.stage_name
    vpc_link_id             = module.alb.vpc_link_id
    tripplanner_http_api_id = aws_apigatewayv2_api.tripplanner.id
  }
}
