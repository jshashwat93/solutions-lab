variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "The GCP region to deploy resources"
  type        = string
  default     = "us-east1"
}