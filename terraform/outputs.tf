# ─────────────────────────────────────────────────────────────────────────────
#  Outputs are grouped to match the clickops order in README.md, so you can keep
#  `terraform output` open in one pane while working through the console.
# ─────────────────────────────────────────────────────────────────────────────

output "region" {
  description = "Region everything was created in."
  value       = local.region
}

output "account_id" {
  description = "Account the replica lives in."
  value       = local.account_id
}

output "buckets" {
  description = "Physical data and artifact bucket names."
  value       = { for k, v in aws_s3_bucket.zone : k => v.id }
}

output "s3_paths" {
  description = "Fully-qualified S3 URIs the Glue jobs and state machine will reference."
  value = {
    landing_drop     = "s3://${aws_s3_bucket.zone["data"].id}/${var.pipeline_name}/landing/"
    landing_rejects  = "s3://${aws_s3_bucket.zone["data"].id}/${var.pipeline_name}/landing/_rejects/"
    raw              = "s3://${aws_s3_bucket.zone["data"].id}/${var.pipeline_name}/raw/"
    curated          = "s3://${aws_s3_bucket.zone["data"].id}/${var.pipeline_name}/curated/"
    published        = "s3://${aws_s3_bucket.zone["data"].id}/${var.pipeline_name}/published/"
    glue_scripts     = "s3://${aws_s3_bucket.zone["artifacts"].id}/glue-scripts/${var.pipeline_name}/"
    python_libs      = "s3://${aws_s3_bucket.zone["artifacts"].id}/python-libs/"
    statemachine_def = "s3://${aws_s3_bucket.zone["artifacts"].id}/statemachines/${var.pipeline_name}/"
  }
}

output "iam_roles" {
  description = "Execution role ARNs to select while clickopsing each component."
  value = {
    glue_job       = aws_iam_role.glue_job.arn
    lambda_arrival = aws_iam_role.lambda_arrival.arn
    lambda_dq_gate = aws_iam_role.lambda_dq_gate.arn
    state_machine  = aws_iam_role.state_machine.arn
  }
}

output "ecr_repository_url" {
  description = "Push target for the data-quality gate container image."
  value       = aws_ecr_repository.dq_gate.repository_url
}

output "ingest_raw_glue_job" {
  description = "Stable Glue job and its bootstrap script. CD overrides script_location per run with an immutable SHA key."
  value = {
    name            = aws_glue_job.ingest_raw.name
    script_location = aws_glue_job.ingest_raw.command[0].script_location
  }
}

output "runtime_orchestration" {
  description = "Arrival trigger and state machine for the event-driven landing-to-raw path."
  value = {
    arrival_lambda     = aws_lambda_function.zip["arrival"].function_name
    state_machine_arn  = aws_sfn_state_machine.orchestrator.arn
    active_release_uri = "s3://${aws_s3_bucket.zone["artifacts"].id}/${local.active_release_key}"
  }
}

output "harness_arrival_service" {
  description = "Harness CD service generated for the OpenTofu-managed arrival Lambda."
  value = {
    identifier      = harness_platform_service.lambda["arrival"].identifier
    name            = harness_platform_service.lambda["arrival"].name
    lambda_function = aws_lambda_function.zip["arrival"].function_name
  }
}

output "harness_arrival_service_identifier" {
  description = "Scalar Harness Service identifier for a downstream CD stage."
  value       = harness_platform_service.lambda["arrival"].identifier
}

output "harness_lambda_service_identifiers" {
  description = "Harness Service identifiers for every OpenTofu-managed ZIP Lambda."
  value       = sort([for service in harness_platform_service.lambda : service.identifier])
}

output "naming_contract" {
  description = <<-DESC
    The IAM roles grant access by wildcard over these name patterns. Anything you
    create in the console MUST match, or the orchestrator will fail with
    AccessDenied. This convention is a platform contract -- see iam.tf.
  DESC
  value = {
    glue_jobs      = "${local.name}-${var.pipeline_name}-<stage>          e.g. ${local.name}-${var.pipeline_name}-ingest-raw"
    lambdas        = "${local.name}-${var.pipeline_name}-<purpose>        e.g. ${local.name}-${var.pipeline_name}-arrival"
    state_machines = "${local.name}-${var.pipeline_name}-<name>           e.g. ${local.name}-${var.pipeline_name}-orchestrator"
    glue_databases = "${replace(var.pipeline_name, "-", "_")}_<zone>      e.g. ${replace(var.pipeline_name, "-", "_")}_curated"
  }
}

output "docker_login_command" {
  description = "Run this before pushing the dq-gate image."
  value       = "aws ecr get-login-password --region ${local.region} | docker login --username AWS --password-stdin ${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
}
