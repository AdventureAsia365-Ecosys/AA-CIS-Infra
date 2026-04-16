output "efs_id" {
  value = aws_efs_file_system.main.id
}

output "efs_dns_name" {
  value = aws_efs_file_system.main.dns_name
}

output "chromadb_access_point_id" {
  value = aws_efs_access_point.chromadb.id
}

output "langgraph_access_point_id" {
  value = aws_efs_access_point.langgraph.id
}
