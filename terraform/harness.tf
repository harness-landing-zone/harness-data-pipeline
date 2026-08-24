locals {
  arrival_service_yaml = templatefile("${path.module}/templates/harness-arrival-lambda-service.yaml.tftpl", {
    SERVICE_NAME       = jsonencode(aws_lambda_function.arrival.function_name)
    SERVICE_IDENTIFIER = jsonencode(local.arrival_service_identifier)
    ORG_IDENTIFIER     = jsonencode(var.harness_org_id)
    PROJECT_IDENTIFIER = jsonencode(var.harness_project_id)
    PIPELINE_NAME      = jsonencode(var.pipeline_name)
    S3_CONNECTOR_REF   = jsonencode(var.harness_s3_connector_ref)
    AWS_REGION         = jsonencode(local.region)
    ARTIFACTS_BUCKET   = jsonencode(aws_s3_bucket.zone["artifacts"].id)
    FUNCTION_DEFINITION = jsonencode({
      functionName = aws_lambda_function.arrival.function_name
      runtime      = aws_lambda_function.arrival.runtime
      handler      = aws_lambda_function.arrival.handler
      role         = aws_iam_role.lambda_arrival.arn
      memorySize   = aws_lambda_function.arrival.memory_size
      timeout      = aws_lambda_function.arrival.timeout
      environment = {
        variables = {
          ACTIVE_RELEASE_KEY = local.active_release_key
          ARTIFACTS_BUCKET   = aws_s3_bucket.zone["artifacts"].id
          DATA_BUCKET        = aws_s3_bucket.zone["data"].id
          PIPELINE_NAME      = var.pipeline_name
          STATE_MACHINE_ARN  = aws_sfn_state_machine.orchestrator.arn
        }
      }
    })
  })
}

import {
  for_each = var.import_existing_harness_arrival_service ? toset([
    "${var.harness_org_id}/${var.harness_project_id}/${local.arrival_service_identifier}"
  ]) : toset([])

  to = harness_platform_service.arrival
  id = each.value
}

resource "harness_platform_service" "arrival" {
  identifier  = local.arrival_service_identifier
  name        = aws_lambda_function.arrival.function_name
  description = "Deploy the arrival-handler ZIP to the Lambda created by OpenTofu."
  org_id      = var.harness_org_id
  project_id  = var.harness_project_id
  yaml        = local.arrival_service_yaml
}
