output "db_endpoint" {
  value = aws_db_instance.main.endpoint
}

# AA-829: the bare hostname (no ":port"), the target of the private CNAME db.<env>.internal (db_dns.tf).
output "db_address" {
  value = aws_db_instance.main.address
}

output "db_name" {
  value = aws_db_instance.main.db_name
}

output "db_port" {
  value = aws_db_instance.main.port
}

output "db_identifier" {
  value = aws_db_instance.main.identifier
}

# Configured base size (not the autoscaled size), used for the FreeStorageSpace alarm threshold.
output "allocated_storage" {
  value = var.allocated_storage
}

output "db_arn" {
  value = aws_db_instance.main.arn
}

# AA-1182: the RDS-managed master secret (rds!db-<id>). Its value is JSON {username, password}; host, port and database
# come from the reader's own DSN (DB Migrate: the task's DATABASE_URL). null until the apply that turns management on
# has run (a splat, never [0]: the first plan still sees the empty list of the state, review S297).
output "master_user_secret_arn" {
  value = one(aws_db_instance.main.master_user_secret[*].secret_arn)
}
