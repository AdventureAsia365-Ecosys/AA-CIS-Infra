output "bronze_bucket_name" {
  description = "Bronze S3 bucket name (raw intake — immutable)"
  value       = aws_s3_bucket.bronze.id
}

output "bronze_bucket_arn" {
  value = aws_s3_bucket.bronze.arn
}

output "silver_bucket_name" {
  description = "Silver S3 bucket name (validated JSONL + SEO cache backup)"
  value       = aws_s3_bucket.silver.id
}

output "silver_bucket_arn" {
  value = aws_s3_bucket.silver.arn
}

output "gold_bucket_name" {
  description = "Gold S3 bucket name (published tours + exports + webhooks)"
  value       = aws_s3_bucket.gold.id
}

output "gold_bucket_arn" {
  value = aws_s3_bucket.gold.arn
}

# ACP bucket outputs — AA-40
output "acp_bronze_bucket_name" {
  description = "ACP Bronze S3 bucket name"
  value       = aws_s3_bucket.acp_bronze.id
}

output "acp_bronze_bucket_arn" {
  value = aws_s3_bucket.acp_bronze.arn
}

output "acp_silver_bucket_name" {
  description = "ACP Silver S3 bucket name"
  value       = aws_s3_bucket.acp_silver.id
}

output "acp_silver_bucket_arn" {
  value = aws_s3_bucket.acp_silver.arn
}

output "acp_gold_bucket_name" {
  description = "ACP Gold S3 bucket name"
  value       = aws_s3_bucket.acp_gold.id
}

output "acp_gold_bucket_arn" {
  value = aws_s3_bucket.acp_gold.arn
}

# Convenience: full S3 URIs for use in application env vars
output "s3_paths" {
  description = "Base S3 path URIs for each Medallion layer"
  value = {
    bronze_raw_inbox = "s3://${aws_s3_bucket.bronze.id}/raw-inbox"
    bronze_archive   = "s3://${aws_s3_bucket.bronze.id}/raw-archive"
    silver_processed = "s3://${aws_s3_bucket.silver.id}/processed"
    silver_seo_cache = "s3://${aws_s3_bucket.silver.id}/seo-cache"
    gold_published   = "s3://${aws_s3_bucket.gold.id}/published"
    gold_exports     = "s3://${aws_s3_bucket.gold.id}/exports"
    gold_webhooks    = "s3://${aws_s3_bucket.gold.id}/webhooks"
  }
}
