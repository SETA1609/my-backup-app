# ── S3 Bucket ────────────────────────────────────────────────────
# This bucket stores photos and documents in two prefix zones:
#   photos/hot/     — Last 3 months of data in Intelligent-Tiering (fast access)
#   photos/archive/ — Bundled monthly ZIPs uploaded directly to Glacier Deep Archive
#
# IMPORTANT: There is NO lifecycle rule transitioning hot/ → Glacier.
# The Go Bundler Lambda reads originals from Intelligent-Tiering,
# uploads ZIPs directly with StorageClass: DEEP_ARCHIVE to archive/,
# then deletes originals from hot/. This avoids the 180-day early
# deletion fee because Intelligent-Tiering has no minimum duration.

resource "aws_s3_bucket" "backup" {
  bucket = "${var.bucket_name_prefix}-${terraform.workspace}"

  tags = merge(var.tags, {
    Name        = "${var.bucket_name_prefix}-${terraform.workspace}"
    Workspace   = terraform.workspace
  })
}

# ── Versioning ──────────────────────────────────────────────────
# Protects against accidental deletes or overwrites.
# A normal DeleteObject creates a Delete Marker (soft delete).
# Permanent deletion requires explicit version ID — auditable and recoverable.

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# ── Server-Side Encryption ──────────────────────────────────────
# SSE-KMS encrypts objects at rest. AWS managed key is sufficient for PoC.
# A customer managed KMS key can be swapped in later.

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── Public Access Block ─────────────────────────────────────────
# All four settings are blocked. No public access to the bucket.
# Access is only through Supabase Edge Functions using IAM credentials.

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── CORS ─────────────────────────────────────────────────────────
# Allows the React SPA (localhost for dev, GitHub Pages for prod)
# to make authenticated requests via Supabase Edge Functions.
# The browser never calls S3 directly — these CORS rules are for
# presigned URL access and Supabase's proxy.

resource "aws_s3_bucket_cors_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  dynamic "cors_rule" {
    for_each = toset(var.cors_allowed_origins)
    content {
      allowed_headers = ["*"]
      allowed_methods = ["GET", "PUT", "POST", "HEAD"]
      allowed_origins = [cors_rule.value]
      expose_headers  = ["x-amz-restore", "x-amz-request-id", "x-amz-id-2"]
      max_age_seconds = 3600
    }
  }
}

# ── Lifecycle Rules ─────────────────────────────────────────────
# Only cleanup rules — NO transition to Glacier.
# The 30-day expiry on _bundled/ and Delete Markers prevents
# unbilled storage accumulation.

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-delete-markers"
    status = "Enabled"

    filter {
      prefix = "photos/"
    }

    expiration {
      expired_object_delete_marker = true
    }
  }

  rule {
    id     = "expire-bundled-safety-copy"
    status = "Enabled"

    filter {
      prefix = "photos/_bundled/"
    }

    expiration {
      days = 30
    }
  }
}
