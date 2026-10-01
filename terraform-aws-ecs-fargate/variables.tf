################################################
#                  Variables                   #
################################################

variable "project" {
  description = "Name prefix for all resources"
  type        = string
  default     = "hc-ecs"
}

variable "environment" {
  description = "Environment, used in names and tags"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

################################################
#                   Network                    #
################################################

variable "vpc_cidr" {
  description = "VPC address range"
  type        = string
  default     = "10.70.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnets: the load balancer and the NAT gateway only"
  type        = list(string)
  default     = ["10.70.1.0/24", "10.70.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly two public subnets are required: an ALB needs two availability zones."
  }
}

variable "private_subnet_cidrs" {
  description = "Private subnets: Fargate tasks and the database, no route from the internet"
  type        = list(string)
  default     = ["10.70.11.0/24", "10.70.12.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Exactly two private subnets are required: the RDS subnet group needs two zones."
  }
}

################################################
#                 Application                  #
################################################

variable "app_port" {
  description = "Port the application listens on inside the container"
  type        = number
  default     = 8000
}

variable "image_tag" {
  description = "ECR image tag to deploy"
  type        = string
  default     = "latest"
}

variable "task_cpu" {
  description = "Fargate CPU units: 256 = 0.25 vCPU. Django with compressor needs more"
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Task memory in MB; AWS allows only certain cpu/memory pairs"
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "How many copies of the application to keep running"
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "Task log retention in days"
  type        = number
  default     = 7
}

################################################
#                   Database                   #
################################################

variable "db_engine_version" {
  description = "PostgreSQL version"
  type        = string
  default     = "18.3"
}

variable "db_instance_class" {
  description = "Database instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Database storage in GB"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Database name inside the instance"
  type        = string
  default     = "hc"
}
