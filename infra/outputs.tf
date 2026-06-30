output "bucket_id" {
  description = "Name / ID of the created S3 bucket"
  value       = aws_s3_bucket.backup.id
}

output "bucket_arn" {
  description = "ARN of the created S3 bucket"
  value       = aws_s3_bucket.backup.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name for the S3 bucket"
  value       = aws_s3_bucket.backup.bucket_regional_domain_name
}

output "workspace" {
  description = "Current OpenTofu workspace"
  value       = terraform.workspace
}
