output "db_endpoint" {
  value = aws_db_instance.main.endpoint
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
