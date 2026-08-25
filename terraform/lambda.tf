locals {
  arrival_bootstrap_key = "lambdas/${var.pipeline_name}/arrival/bootstrap/arrival.zip"
  active_release_key    = "release-manifests/${var.pipeline_name}/active.json"

  # Persistent desired state. Add a ZIP Lambda here only after its role,
  # bootstrap artifact, and integration contract exist in code.
  zip_lambda_components = merge(
    {
      arrival = {
        function_name       = local.arrival_lambda_name
        description         = "Validate a landing CSV and start the data-pipeline state machine."
        role_arn            = aws_iam_role.lambda_arrival.arn
        runtime             = "python3.12"
        handler             = "handler.lambda_handler"
        memory_size         = 128
        timeout             = 20
        bootstrap_key       = local.arrival_bootstrap_key
        service_identifier  = local.arrival_service_identifier
        service_description = "Deploy the arrival-handler ZIP to the Lambda created by OpenTofu."
        environment_variables = {
          ACTIVE_RELEASE_KEY = local.active_release_key
          ARTIFACTS_BUCKET   = aws_s3_bucket.zone["artifacts"].id
          DATA_BUCKET        = aws_s3_bucket.zone["data"].id
          PIPELINE_NAME      = var.pipeline_name
          STATE_MACHINE_ARN  = aws_sfn_state_machine.orchestrator.arn
        }
      }
    },
    {
      for component_id, component in var.additional_zip_lambdas : component_id => {
        function_name       = "${local.name}-${var.pipeline_name}-${replace(component_id, "_", "-")}"
        description         = component.description
        role_arn            = aws_iam_role.lambda_additional[component_id].arn
        runtime             = component.runtime
        handler             = component.handler
        memory_size         = component.memory_size
        timeout             = component.timeout
        bootstrap_key       = "lambdas/${var.pipeline_name}/${component_id}/bootstrap/${component.bootstrap_filename}"
        service_identifier  = component.service_identifier
        service_description = "Deploy the ${component_id} ZIP to the Lambda created by OpenTofu."
        environment_variables = merge(
          { PIPELINE_NAME = var.pipeline_name },
          component.environment_variables,
        )
      }
    }
  )
}

moved {
  from = aws_lambda_function.arrival
  to   = aws_lambda_function.zip["arrival"]
}

# IaCM owns only this minimal creation artifact. Component CI replaces it with
# immutable release ZIPs after the Lambda shell and Harness Service exist.
resource "archive_file" "lambda_bootstrap" {
  for_each = var.additional_zip_lambdas

  type             = "zip"
  output_file_mode = "0666"
  output_path      = "${path.module}/.terraform/${each.key}-bootstrap.zip"

  source {
    filename = "handler.py"
    content  = <<-PY
      def lambda_handler(event, _context):
          return {"component": "${each.key}", "status": "bootstrap"}
    PY
  }
}

resource "aws_s3_object" "lambda_bootstrap" {
  for_each = var.additional_zip_lambdas

  bucket                 = aws_s3_bucket.zone["artifacts"].id
  key                    = local.zip_lambda_components[each.key].bootstrap_key
  source                 = archive_file.lambda_bootstrap[each.key].output_path
  source_hash            = archive_file.lambda_bootstrap[each.key].output_md5
  content_type           = "application/zip"
  server_side_encryption = "AES256"

  tags = {
    Component = "lambda-${each.key}"
    Artifact  = "bootstrap"
  }
}

resource "aws_lambda_function" "zip" {
  for_each = local.zip_lambda_components

  function_name = each.value.function_name
  description   = each.value.description
  role          = each.value.role_arn
  runtime       = each.value.runtime
  handler       = each.value.handler
  memory_size   = each.value.memory_size
  timeout       = each.value.timeout

  s3_bucket = aws_s3_bucket.zone["artifacts"].id
  s3_key    = each.value.bootstrap_key

  environment {
    variables = each.value.environment_variables
  }

  depends_on = [
    aws_iam_role_policy.lambda_arrival,
    aws_iam_role_policy_attachment.lambda_arrival_basic,
    aws_iam_role_policy_attachment.lambda_additional_basic,
    aws_s3_object.lambda_bootstrap,
  ]

  tags = {
    Component = "lambda-${each.key}"
    Artifact  = "zip"
  }

  # IaCM needs bootstrap code to create the function. Harness CD owns every
  # subsequent code deployment and published version.
  lifecycle {
    ignore_changes = [
      s3_bucket,
      s3_key,
      s3_object_version,
      source_code_hash,
    ]
  }
}

resource "harness_platform_file_store_file" "lambda_function_definition" {
  for_each = local.zip_lambda_components

  identifier        = "${each.value.service_identifier}_function_definition"
  name              = "${each.value.service_identifier}-function-definition.json"
  description       = "AWS Lambda function definition for ${aws_lambda_function.zip[each.key].function_name}."
  org_id            = var.harness_org_id
  project_id        = var.harness_project_id
  parent_identifier = "Root"
  content = jsonencode({
    functionName = aws_lambda_function.zip[each.key].function_name
    runtime      = aws_lambda_function.zip[each.key].runtime
    handler      = aws_lambda_function.zip[each.key].handler
    role         = each.value.role_arn
    memorySize   = aws_lambda_function.zip[each.key].memory_size
    timeout      = aws_lambda_function.zip[each.key].timeout
    environment = {
      variables = each.value.environment_variables
    }
  })
  mime_type  = "application/json"
  file_usage = "MANIFEST_FILE"
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
  yaml = templatefile("${path.module}/templates/harness-zip-lambda-service.yaml.tftpl", {
    SERVICE_NAME             = jsonencode(aws_lambda_function.zip[each.key].function_name)
    SERVICE_IDENTIFIER       = jsonencode(each.value.service_identifier)
    SERVICE_DESCRIPTION      = jsonencode(each.value.service_description)
    COMPONENT_ID             = jsonencode(each.key)
    ORG_IDENTIFIER           = jsonencode(var.harness_org_id)
    PROJECT_IDENTIFIER       = jsonencode(var.harness_project_id)
    PIPELINE_NAME            = jsonencode(var.pipeline_name)
    S3_CONNECTOR_REF         = jsonencode(var.harness_s3_connector_ref)
    AWS_REGION               = jsonencode(local.region)
    ARTIFACTS_BUCKET         = jsonencode(aws_s3_bucket.zone["artifacts"].id)
    FUNCTION_DEFINITION_PATH = jsonencode(harness_platform_file_store_file.lambda_function_definition[each.key].path)
  })
}

resource "aws_lambda_permission" "s3_arrival" {
  statement_id   = "AllowLandingBucketInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.zip["arrival"].function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.zone["data"].arn
  source_account = local.account_id
}

resource "aws_s3_bucket_notification" "arrival" {
  bucket = aws_s3_bucket.zone["data"].id

  lambda_function {
    id                  = "${var.pipeline_name}-landing-csv"
    lambda_function_arn = aws_lambda_function.zip["arrival"].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "${var.pipeline_name}/landing/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.s3_arrival]
}
