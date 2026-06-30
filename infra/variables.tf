variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "bucket_name_prefix" {
  description = "Prefix for the S3 bucket name. The workspace (dev/prod) is appended automatically."
  type        = string
  default     = "my-backup"
}

variable "cors_allowed_origins" {
  description = "List of origins allowed by the S3 CORS policy. Add your GitHub Pages domain for production."
  type        = list(string)
  default     = [
    "http://localhost:5173",
    "https://localhost:5173",
  ]
}

variable "enable_versioning" {
  description = "Enable S3 versioning to protect against accidental deletes"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "my-backup-app"
    ManagedBy   = "opentofu"
    Environment = "dev"
  }
}
