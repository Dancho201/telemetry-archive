output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.this.id
}

output "instance_public_ip" {
  description = "Public IP of the instance (changes after a stop/start)"
  value       = aws_instance.this.public_ip
}

output "ssh_command" {
  description = "Command to SSH into the instance"
  value       = "ssh -i ${var.private_key_path} ubuntu@${aws_instance.this.public_ip}"
}
