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

variable "harness_arrival_service_identifier" {
  description = "Stable Harness identifier for the arrival Lambda service. Override for each generated pipeline instance."
  type        = string
  default     = "arrival_lambda"

  validation {
    condition     = can(regex("^[A-Za-z_][0-9A-Za-z_$-]*$", var.harness_arrival_service_identifier))
    error_message = "harness_arrival_service_identifier must be a valid Harness identifier."
  }
}

variable "harness_s3_connector_ref" {
  description = "Harness AWS connector used by CD to read the Lambda ZIP from S3. Include account. or org. for scoped connectors."
  type        = string
  default     = "account.s3storage"
}

variable "additional_zip_lambdas" {
  description = "Additional ZIP Lambdas and matching Harness Services managed by the component loop."
  type = map(object({
    service_identifier    = string
    description           = string
    bootstrap_filename    = optional(string, "lambda.zip")
    runtime               = optional(string, "python3.12")
    handler               = optional(string, "handler.lambda_handler")
    memory_size           = optional(number, 128)
    timeout               = optional(number, 20)
    environment_variables = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for component_id, component in var.additional_zip_lambdas :
      component_id != "arrival" &&
      can(regex("^[a-z0-9][a-z0-9_-]*$", component_id)) &&
      can(regex("^[A-Za-z_][0-9A-Za-z_$-]*$", component.service_identifier)) &&
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*\\.zip$", component.bootstrap_filename)) &&
      component.memory_size >= 128 && component.memory_size <= 10240 &&
      component.timeout >= 1 && component.timeout <= 900
    ])
    error_message = "Additional Lambda keys, Service identifiers, ZIP filenames, memory, or timeout values are invalid; the reserved key 'arrival' cannot be replaced."
  }

  validation {
    condition     = length(distinct([for component in values(var.additional_zip_lambdas) : component.service_identifier])) == length(var.additional_zip_lambdas)
    error_message = "Each additional Lambda must have a unique Harness Service identifier."
  }
}

variable "import_existing_harness_arrival_service" {
  description = "Import an existing Harness arrival service during plan/apply instead of creating it. Enable only for brownfield onboarding."
  type        = bool
  default     = false
}
