terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # No explicit backend: Harness IaCM manages workspace state. Add a separate
  # backends.tf only when the customer-owned S3 state backend is available.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
