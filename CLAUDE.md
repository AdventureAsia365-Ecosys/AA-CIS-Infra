# CLAUDE.md — AA-CIS-Infra

## Project Context
Terraform infrastructure for AA-CIS platform.
Region: us-west-1 | Account: 867490540162 | Profile: pqnghiep-admin

## Stack
- Terraform ~> 1.5
- AWS Provider ~> 5.0
- Modules: vpc, ecs, rds, alb, elasticache, s3, lambda, waf, secrets, monitoring

## Git Workflow
```
chore/desc → main (direct for infra — review plan first)
```
- Always run `terraform plan` and review before apply
- Never apply without plan review
- Commit plan file: `plan_description.tfplan`

## Key Architecture Decisions (locked)

### NAT Instance (NOT NAT Gateway) — since 05/06/2026
- Resource: `module.vpc.aws_instance.nat` (t4g.nano, AL2023 ARM64)
- Instance ID: i-04ebd090e97184f45 | EIP: 50.18.72.86
- Cost: ~$3-5/mo vs $42-67/mo for NAT Gateway
- Stop/start per session — see ~/.zshrc aliases
- ⚠️ Interface: `ens5` (NOT eth0) — AL2023 ARM64 naming
- iptables MASQUERADE on ens5, saved to /etc/sysconfig/iptables
- Private route table → network_interface_id (not nat_gateway_id)

### ECS Fargate Spot
- 75% Spot, 25% On-Demand base
- ECS Exec enabled on service

### VPC Layout
- VPC: vpc-0770c0bbc63988b15 (10.2.0.0/16)
- Public subnets: subnet-0d610f1825a7ac030 (us-west-1a), subnet-0f8649d1e637cbd63 (us-west-1c)
- NAT Instance in: subnet-0d610f1825a7ac030 (public-1, us-west-1a)
- VPC Endpoint Secrets Manager: vpce-07abbd6b2c9f5dfa7

## Terraform State
- Backend: S3 (aa-cis-tfstate-867490540162)
- Init: `terraform init`
- Plan: `terraform plan -out=plan_description.tfplan`
- Apply: `terraform apply plan_description.tfplan`

## Current State (05/06/2026)
- NAT GW removed, NAT Instance active (PR #1 merged)
- All modules stable — no pending changes

## Do NOT
- Apply without plan review
- Use eth0 in user_data (use ens5 for AL2023 ARM64)
- Create NAT Gateway (locked decision — use NAT Instance)
- Multi-line AWS CLI with backslash (hangs WSL2)
