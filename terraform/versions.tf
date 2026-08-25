terraform {
  required_version = ">= 1.7.0"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
    }

    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }

    harness = {
      source  = "harness/harness"
      version = "~> 0.45.0"
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

# Authentication comes from HARNESS_ACCOUNT_ID and HARNESS_PLATFORM_API_KEY in
# the IaCM workspace. Keeping credentials out of HCL also keeps them out of
# plans and variable files.
provider "harness" {}
