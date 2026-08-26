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
  description = "Logical name of the data pipeline this environment hosts."
  type        = string
  default     = "accounts-daily"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.pipeline_name))
    error_message = "pipeline_name must be lowercase alphanumeric or hyphen, 2-31 chars."
  }
}

variable "destroyable" {
  description = <<-DESC
    Allow `terraform destroy` to remove non-empty S3 buckets.
    Keep false unless this is an explicitly disposable environment.
  DESC
  type        = bool
  default     = false
}

variable "harness_org_id" {
  description = "Harness organization that owns the generated CD service."
  type        = string
  default     = "data_engineers"
}

variable "harness_project_id" {
  description = "Harness project that owns the generated CD service."
  type        = string
  default     = "data_pipeline_reference"
}

variable "harness_s3_connector_ref" {
  description = "Harness AWS connector used by CD to read Lambda ZIPs from S3."
  type        = string
  default     = "account.s3storage"
}

variable "lambdas" {
  description = "ZIP Lambdas and matching Harness Services, keyed by stable identifier."
  type = map(object({
    description           = optional(string, "ZIP Lambda deployed by Harness CD.")
    memory_size           = optional(number, 128)
    timeout               = optional(number, 10)
    environment_variables = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for lambda_id in keys(var.lambdas) :
      can(regex("^[a-z][a-z0-9_]{1,30}$", lambda_id))
    ])
    error_message = "Lambda keys must be 2-31 lowercase alphanumeric or underscore characters and start with a letter."
  }

  validation {
    condition = alltrue([
      for lambda in values(var.lambdas) :
      lambda.memory_size >= 128 && lambda.memory_size <= 10240 &&
      lambda.timeout >= 1 && lambda.timeout <= 900
    ])
    error_message = "Lambda memory_size must be 128-10240 MB and timeout must be 1-900 seconds."
  }
}
