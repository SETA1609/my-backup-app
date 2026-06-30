# Production environment overrides
aws_region = "eu-central-1"
bucket_name_prefix = "my-backup-prod"
cors_allowed_origins = [
  "https://yourusername.github.io",
]
tags = {
  Project     = "my-backup-app"
  ManagedBy   = "opentofu"
  Environment = "prod"
}
