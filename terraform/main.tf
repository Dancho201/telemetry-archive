resource "aws_s3_bucket" "tsdb_backup" {
  bucket = var.bucket_name

  tags = merge(var.tags, {
    Name    = var.bucket_name
    Purpose = "tsdb-deep-archive-backup"
  })
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "tsdb_backup" {
  bucket = aws_s3_bucket.tsdb_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable versioning (recommended for backup buckets)
resource "aws_s3_bucket_versioning" "tsdb_backup" {
  bucket = aws_s3_bucket.tsdb_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "tsdb_backup" {
  bucket = aws_s3_bucket.tsdb_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null ? true : false
  }
}

# Lifecycle policy: move to Deep Archive + expire old versions
resource "aws_s3_bucket_lifecycle_configuration" "tsdb_backup" {
  bucket = aws_s3_bucket.tsdb_backup.id

  # Abort incomplete multipart uploads (important for large backup tarballs)
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Transition current objects to Deep Archive and eventually expire them
  rule {
    id     = "backups-deep-archive-lifecycle"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }

    transition {
      days          = 0
      storage_class = "DEEP_ARCHIVE"
    }

    expiration {
      days = var.retention_days
    }

    # Clean up old non-current versions
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
  }
}