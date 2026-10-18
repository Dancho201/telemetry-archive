variable "aws_region" {
  description = "AWS region to deploy the instance in"
  type        = string
  default     = "eu-west-1"
}

variable "name" {
  description = "Name prefix used for the instance and related resources"
  type        = string
  default     = "mon-backup"
}

variable "instance_type" {
  description = "EC2 instance type (t3.nano is the cheapest t3 size)"
  type        = string
  default     = "t3.nano"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB (8 is the minimum for Ubuntu 24.04)"
  type        = number
  default     = 8
}

variable "private_key_path" {
  description = "Path to the SSH private key; its public key is registered as the EC2 key pair"
  type        = string
  default     = "mon_backup.pem"
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH into the instance. Restrict this to your own IP (e.g. 203.0.113.10/32)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
