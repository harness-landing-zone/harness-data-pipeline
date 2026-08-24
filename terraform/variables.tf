variable "aws_region" {
  description = "Region for the replica environment. eu-west-2 mirrors a UK&I footprint."
  type        = string
  default     = "eu-west-2"
}

variable "name_prefix" {
  description = <<-DESC
    Short prefix applied to every resource name. Must be lowercase and DNS-safe
    because it lands inside S3 bucket names.
  DESC
  type        = string
  default     = "data-pipeline"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric or hyphen, 2-21 chars, for S3 bucket-name safety."
  }
}

variable "env" {
  description = "Environment slug. The replica is non-prod only."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.env)
    error_message = "env must be one of: dev, test, prod."
  }
}

variable "pipeline_name" {
  description = "Logical name of the data pipeline this environment hosts. Scopes IAM and ECR naming."
  type        = string
  default     = "accounts-daily"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.pipeline_name))
    error_message = "pipeline_name must be lowercase alphanumeric or hyphen, 2-31 chars."
  }
}

variable "destroyable" {
  description = <<-DESC
    Allow `terraform destroy` to remove non-empty S3 buckets and ECR repositories.
    Keep false unless this is an explicitly disposable environment.
  DESC
  type        = bool
  default     = false
}
