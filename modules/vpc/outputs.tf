output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "db_subnet_ids" {
  value = aws_subnet.db[*].id
}

output "db_subnet_group_name" {
  value = aws_db_subnet_group.main.name
}

output "sg_alb_id" {
  value = aws_security_group.alb.id
}

output "sg_app_id" {
  value = aws_security_group.app.id
}

output "sg_rds_id" {
  value = aws_security_group.rds.id
}

output "nat_instance_id" {
  value       = aws_instance.nat.id
  description = "NAT Instance ID (t4g.nano) — stop/start per session"
}

output "nat_instance_eip" {
  value       = aws_eip.nat_instance.public_ip
  description = "NAT Instance public IP (EIP)"
}

output "s3_gateway_endpoint_id" {
  value       = aws_vpc_endpoint.s3.id
  description = "AA-1022: S3 gateway endpoint on the private route table"
}

output "private_route_table_id" {
  value       = aws_route_table.private.id
  description = "Route table of the private (workload) subnets: NAT default route + S3 gateway endpoint route"
}
