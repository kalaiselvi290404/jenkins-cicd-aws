terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1" # Mumbai
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "kalaiselvi-cicd"
}

variable "app_instance_count" {
  description = "Number of app EC2 instances behind the ALB (>=2 for zero-downtime)"
  type        = number
  default     = 2
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form (e.g. 1.2.3.4/32) for SSH + Jenkins UI access"
  type        = string
}
