variable "bucket_name" {
  description = "Name of the S3 backup bucket"
  type        = string
  default     = "tsdb-backup-da"
}

variable "kms_key_arn" {
  description = "ARN of a customer-managed KMS key for SSE-KMS. Set to null to use SSE-S3 (AES256)."
  type        = string
  default     = null
}

variable "retention_days" {
  description = "Number of days before backup objects are permanently deleted"
  type        = number
  default     = 365
}

variable "noncurrent_version_retention_days" {
  description = "Number of days to keep non-current object versions before deleting"
  type        = number
  default     = 90
}

variable "backup_writer_arns" {
  description = "List of IAM ARNs (users/roles) allowed to write backups (e.g. the rclone host role)"
  type        = list(string)
  default     = null
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "AWS region to deploy the bucket in"
  type        = string
  default     = "eu-central-1"
}