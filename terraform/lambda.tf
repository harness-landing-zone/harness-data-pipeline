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
