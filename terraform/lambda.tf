locals {
  lambdas = {
    for lambda_id, lambda in var.lambdas : lambda_id => {
      function_name = "${local.name}-${var.pipeline_name}-${replace(lambda_id, "_", "-")}"
      description   = lambda.description
      runtime       = "python3.12"
      handler       = "handler.lambda_handler"
      memory_size   = lambda.memory_size
      timeout       = lambda.timeout
      environment   = lambda.environment_variables
      artifact_key  = "lambdas/${var.pipeline_name}/${lambda_id}/lambda.zip"
    }
  }

  lambda_definitions = {
    for lambda_id, lambda in local.lambdas : lambda_id => {
      functionName = lambda.function_name
      runtime      = lambda.runtime
      handler      = lambda.handler
      role         = aws_iam_role.lambda[lambda_id].arn
      memorySize   = lambda.memory_size
      timeout      = lambda.timeout
      environment = {
        variables = lambda.environment
      }
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each = local.lambdas

  name               = "${each.value.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume["lambda"].json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  for_each = local.lambdas

  role       = aws_iam_role.lambda[each.key].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# AWS needs code at creation time. Harness replaces this bootstrap in the next stage.
resource "archive_file" "lambda_bootstrap" {
  for_each = local.lambdas

  type             = "zip"
  output_file_mode = "0666"
  output_path      = "${path.module}/.terraform/${each.key}-bootstrap.zip"

  source {
    filename = "handler.py"
    content  = <<-PY
      def lambda_handler(event, _context):
          return {"lambda": "${each.key}", "status": "bootstrap"}
    PY
  }
}

resource "aws_s3_object" "lambda_bootstrap" {
  for_each = local.lambdas

  bucket      = aws_s3_bucket.zone["artifacts"].id
  key         = each.value.artifact_key
  source      = archive_file.lambda_bootstrap[each.key].output_path
  source_hash = archive_file.lambda_bootstrap[each.key].output_md5

  # The delivery pipeline owns the ZIP after the bootstrap upload.
  lifecycle {
    ignore_changes = [source, source_hash]
  }
}

resource "aws_lambda_function" "lambda" {
  for_each = local.lambdas

  function_name = each.value.function_name
  description   = each.value.description
  role          = aws_iam_role.lambda[each.key].arn
  runtime       = each.value.runtime
  handler       = each.value.handler
  filename      = archive_file.lambda_bootstrap[each.key].output_path
  memory_size   = each.value.memory_size
  timeout       = each.value.timeout

  environment {
    variables = each.value.environment
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic]

  # Harness CD owns code after IaCM creates the function.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

resource "harness_platform_file_store_file" "lambda_definition" {
  for_each = local.lambdas

  identifier        = "${each.key}_function_definition"
  name              = "${each.key}-function-definition.json"
  org_id            = var.harness_org_id
  project_id        = var.harness_project_id
  parent_identifier = "Root"
  content           = jsonencode(local.lambda_definitions[each.key])
  mime_type         = "application/json"
  file_usage        = "MANIFEST_FILE"
}

resource "harness_platform_service" "lambda" {
  for_each = local.lambdas

  identifier  = each.key
  name        = each.value.function_name
  description = each.value.description
  org_id      = var.harness_org_id
  project_id  = var.harness_project_id
  yaml = templatefile("${path.module}/templates/harness-lambda-service.yaml.tftpl", {
    SERVICE_NAME             = jsonencode(each.value.function_name)
    SERVICE_IDENTIFIER       = jsonencode(each.key)
    SERVICE_DESCRIPTION      = jsonencode(each.value.description)
    ORG_IDENTIFIER           = jsonencode(var.harness_org_id)
    PROJECT_IDENTIFIER       = jsonencode(var.harness_project_id)
    CONNECTOR_REF            = jsonencode(var.harness_s3_connector_ref)
    AWS_REGION               = jsonencode(local.region)
    ARTIFACTS_BUCKET         = jsonencode(aws_s3_bucket.zone["artifacts"].id)
    ARTIFACT_KEY             = jsonencode(each.value.artifact_key)
    FUNCTION_DEFINITION_PATH = jsonencode(harness_platform_file_store_file.lambda_definition[each.key].path)
  })
}
