# Dev environment overrides
aws_region = "eu-central-1"
bucket_name_prefix = "my-backup-dev"
cors_allowed_origins = [
  "http://localhost:5173",
  "https://localhost:5173",
]
tags = {
  Project     = "my-backup-app"
  ManagedBy   = "opentofu"
  Environment = "dev"
}
