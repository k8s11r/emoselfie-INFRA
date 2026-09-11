variable "aws_region" {
  description = "AWS region in which to create the k3s cluster."
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Prefix used for resource names and tags."
  type        = string
  default     = "emoselfie"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name may contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "environment may contain only lowercase letters, numbers, and hyphens."
  }
}

variable "admin_cidr" {
  description = "Public IPv4 CIDR allowed to use SSH and the Kubernetes API, for example 203.0.113.10/32."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid IPv4 CIDR and must not be 0.0.0.0/0. Use your current public IP with /32."
  }
}

variable "key_name" {
  description = "Name of an existing EC2 key pair in aws_region."
  type        = string
  default     = "project1_key"
}

variable "instance_type" {
  description = "EC2 type used by all k3s nodes. The application needs at least 2 vCPU and 4 GiB RAM."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size per node in GiB."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size >= 30
    error_message = "root_volume_size must be at least 30 GiB."
  }
}

variable "k3s_channel" {
  description = "K3s install channel. Use a version in k3s_version to pin an exact release."
  type        = string
  default     = "stable"
}

variable "k3s_version" {
  description = "Optional exact K3s release, for example v1.35.4+k3s1. Null installs from k3s_channel."
  type        = string
  default     = null
  nullable    = true
}

variable "cluster_token" {
  description = "Optional preselected k3s join token. A random token is generated when null."
  type        = string
  default     = null
  nullable    = true
  sensitive   = true
}

variable "additional_tags" {
  description = "Additional tags to add to all supported AWS resources."
  type        = map(string)
  default     = {}
}

