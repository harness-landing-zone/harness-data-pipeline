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
    glue_job      = aws_iam_role.glue_job.arn
    lambdas       = { for lambda_id, role in aws_iam_role.lambda : lambda_id => role.arn }
    state_machine = aws_iam_role.state_machine.arn
  }
}

output "ingest_raw_glue_job" {
  description = "Stable Glue job and its bootstrap script. CD overrides script_location per run with an immutable SHA key."
  value = {
    name            = aws_glue_job.ingest_raw.name
    script_location = aws_glue_job.ingest_raw.command[0].script_location
  }
}

output "runtime_orchestration" {
  description = "Lambda functions and state machine created by IaCM."
  value = {
    lambdas           = { for lambda_id, lambda in aws_lambda_function.lambda : lambda_id => lambda.function_name }
    state_machine_arn = aws_sfn_state_machine.orchestrator.arn
  }
}

output "harness_lambda_service_identifiers" {
  description = "Harness Service identifiers created for the Lambda deployment stage."
  value       = sort([for service in harness_platform_service.lambda : service.identifier])
}

output "harness_lambda_service_identifiers_csv" {
  description = "Comma-separated Harness Service identifiers consumed by the downstream Repeat stage."
  value       = join(",", sort([for service in harness_platform_service.lambda : service.identifier]))
}

output "naming_contract" {
  description = <<-DESC
    The IAM roles grant access by wildcard over these name patterns. Anything you
    create in the console MUST match, or the orchestrator will fail with
    AccessDenied. This convention is a platform contract -- see iam.tf.
  DESC
  value = {
    glue_jobs      = "${local.name}-${var.pipeline_name}-<stage>          e.g. ${local.name}-${var.pipeline_name}-ingest-raw"
    lambdas        = "${local.name}-${var.pipeline_name}-<component>      e.g. ${local.name}-${var.pipeline_name}-example-zip"
    state_machines = "${local.name}-${var.pipeline_name}-<name>           e.g. ${local.name}-${var.pipeline_name}-orchestrator"
    glue_databases = "${replace(var.pipeline_name, "-", "_")}_<zone>      e.g. ${replace(var.pipeline_name, "-", "_")}_curated"
  }
}
