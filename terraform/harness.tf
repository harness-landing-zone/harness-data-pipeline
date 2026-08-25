locals {
  zip_lambda_service_yaml = {
    for component_id, component in local.zip_lambda_components :
    component_id => templatefile("${path.module}/templates/harness-zip-lambda-service.yaml.tftpl", {
      SERVICE_NAME        = jsonencode(aws_lambda_function.zip[component_id].function_name)
      SERVICE_IDENTIFIER  = jsonencode(component.service_identifier)
      SERVICE_DESCRIPTION = jsonencode(component.service_description)
      COMPONENT_ID        = jsonencode(component_id)
      ORG_IDENTIFIER      = jsonencode(var.harness_org_id)
      PROJECT_IDENTIFIER  = jsonencode(var.harness_project_id)
      PIPELINE_NAME       = jsonencode(var.pipeline_name)
      S3_CONNECTOR_REF    = jsonencode(var.harness_s3_connector_ref)
      AWS_REGION          = jsonencode(local.region)
      ARTIFACTS_BUCKET    = jsonencode(aws_s3_bucket.zone["artifacts"].id)
      FUNCTION_DEFINITION = jsonencode({
        functionName = aws_lambda_function.zip[component_id].function_name
        runtime      = aws_lambda_function.zip[component_id].runtime
        handler      = aws_lambda_function.zip[component_id].handler
        role         = component.role_arn
        memorySize   = aws_lambda_function.zip[component_id].memory_size
        timeout      = aws_lambda_function.zip[component_id].timeout
        environment = {
          variables = component.environment_variables
        }
      })
    })
  }
}

moved {
  from = harness_platform_service.arrival
  to   = harness_platform_service.lambda["arrival"]
}

import {
  for_each = var.import_existing_harness_arrival_service ? {
    arrival = "${var.harness_org_id}/${var.harness_project_id}/${local.arrival_service_identifier}"
  } : {}

  to = harness_platform_service.lambda[each.key]
  id = each.value
}

resource "harness_platform_service" "lambda" {
  for_each = local.zip_lambda_components

  identifier  = each.value.service_identifier
  name        = aws_lambda_function.zip[each.key].function_name
  description = each.value.service_description
  org_id      = var.harness_org_id
  project_id  = var.harness_project_id
  yaml        = local.zip_lambda_service_yaml[each.key]
}
