output "bucket_id" {
  description = "The name (ID) of the S3 bucket"
  value       = aws_s3_bucket.tsdb_backup.id
}

output "bucket_arn" {
  description = "The ARN of the S3 bucket"
  value       = aws_s3_bucket.tsdb_backup.arn
}

output "bucket_region" {
  description = "The AWS region the bucket lives in"
  value       = aws_s3_bucket.tsdb_backup.region
}

output "rclone_remote_path" {
  description = "The rclone destination path matching this bucket"
  value       = "s3-deep-archive:${aws_s3_bucket.tsdb_backup.id}/backups/"
}