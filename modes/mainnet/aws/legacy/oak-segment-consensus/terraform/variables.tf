variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "app_name" {
  type        = string
  description = "Elastic Beanstalk application name"
  default     = "oak-segment-consensus"
}

variable "env_name" {
  type        = string
  description = "Elastic Beanstalk environment name"
  default     = "osc-prod"
}

variable "solution_stack" {
  type        = string
  description = "Elastic Beanstalk solution stack for Docker"
  default     = "64bit Amazon Linux 2 v3.5.7 running Docker"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type"
  default     = "t3.large"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR"
  default     = "10.50.0.0/16"
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Public subnet CIDRs (2 AZs recommended)"
  default     = ["10.50.1.0/24", "10.50.2.0/24"]
}

variable "allowed_ingress_cidr" {
  type        = string
  description = "CIDR for ALB ingress (use 0.0.0.0/0 for internet)"
  default     = "0.0.0.0/0"
}

variable "health_check_path" {
  type        = string
  description = "Health check path for ALB"
  default     = "/v1/health"
}
