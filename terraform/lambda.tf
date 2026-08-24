locals {
  arrival_bootstrap_key = "lambdas/${var.pipeline_name}/arrival/bootstrap/arrival.zip"
  active_release_key    = "release-manifests/${var.pipeline_name}/active.json"
}

resource "aws_lambda_function" "arrival" {
  function_name = local.arrival_lambda_name
  description   = "Validate a landing CSV and start the data-pipeline state machine."
  role          = aws_iam_role.lambda_arrival.arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"
  memory_size   = 128
  timeout       = 20

  s3_bucket = aws_s3_bucket.zone["artifacts"].id
  s3_key    = local.arrival_bootstrap_key

  environment {
    variables = {
      ACTIVE_RELEASE_KEY = local.active_release_key
      ARTIFACTS_BUCKET   = aws_s3_bucket.zone["artifacts"].id
      DATA_BUCKET        = aws_s3_bucket.zone["data"].id
      PIPELINE_NAME      = var.pipeline_name
      STATE_MACHINE_ARN  = aws_sfn_state_machine.orchestrator.arn
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_arrival,
    aws_iam_role_policy_attachment.lambda_arrival_basic,
  ]

  tags = {
    Component = "lambda-arrival"
    Artifact  = "zip"
  }
}

resource "aws_lambda_permission" "s3_arrival" {
  statement_id   = "AllowLandingBucketInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.arrival.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.zone["data"].arn
  source_account = local.account_id
}

resource "aws_s3_bucket_notification" "arrival" {
  bucket = aws_s3_bucket.zone["data"].id

  lambda_function {
    id                  = "${var.pipeline_name}-landing-csv"
    lambda_function_arn = aws_lambda_function.arrival.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "${var.pipeline_name}/landing/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.s3_arrival]
}
