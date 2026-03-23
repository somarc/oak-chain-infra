output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC ID"
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "Public subnet IDs"
}

output "efs_id" {
  value       = aws_efs_file_system.oak.id
  description = "EFS filesystem ID"
}

output "eb_environment_name" {
  value       = aws_elastic_beanstalk_environment.env.name
  description = "Elastic Beanstalk environment name"
}
