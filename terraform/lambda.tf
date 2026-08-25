locals {
  arrival_bootstrap_key = "lambdas/${var.pipeline_name}/arrival/bootstrap/arrival.zip"
  active_release_key    = "release-manifests/${var.pipeline_name}/active.json"

  # Persistent desired state. Add a ZIP Lambda here only after its role,
  # bootstrap artifact, and integration contract exist in code.
  zip_lambda_components = {
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
  }
}

moved {
  from = aws_lambda_function.arrival
  to   = aws_lambda_function.zip["arrival"]
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
  ]

  tags = {
    Component = "lambda-${each.key}"
    Artifact  = "zip"
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
