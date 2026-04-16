output "uploads_bucket_name" {
  value = aws_s3_bucket.uploads.bucket
}

output "uploads_bucket_arn" {
  value = aws_s3_bucket.uploads.arn
}

output "outputs_bucket_name" {
  value = aws_s3_bucket.outputs.bucket
}

output "outputs_bucket_arn" {
  value = aws_s3_bucket.outputs.arn
}
