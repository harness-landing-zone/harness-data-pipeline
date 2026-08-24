# ─────────────────────────────────────────────────────────────────────────────
#  IAM: one execution role per compute component.
#
#  Read this file as the dependency graph of the data pipeline. Every "allow"
#  is a coupling between two components, and couplings are what decide whether
#  the components can be released independently.
#
#  Note in particular sfn_role: it needs glue:StartJobRun on job names and
#  lambda:InvokeFunction on function names that DO NOT EXIST YET. The ARNs are
#  matched by wildcard on a naming convention. That convention is now a
#  platform contract -- if a team renames a Glue job, the orchestrator loses
#  permission. This is a strong argument for the naming being template-owned
#  rather than team-owned.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Wildcards over the not-yet-created compute, matched by naming convention.
  glue_job_arn_pattern      = "arn:${local.partition}:glue:${local.region}:${local.account_id}:job/${local.name}-${var.pipeline_name}-*"
  lambda_fn_arn_pattern     = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.name}-${var.pipeline_name}-*"
  state_machine_arn_pattern = "arn:${local.partition}:states:${local.region}:${local.account_id}:stateMachine:${local.name}-${var.pipeline_name}-*"
}

# ── Trust policies ───────────────────────────────────────────────────────────

data "aws_iam_policy_document" "assume" {
  for_each = {
    glue   = "glue.amazonaws.com"
    lambda = "lambda.amazonaws.com"
    states = "states.amazonaws.com"
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = [each.value]
    }

    # Confused-deputy guard: only this account may induce the service to assume.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
#  1. Glue job role -- shared by all three PySpark jobs.
#
#  DESIGN NOTE worth raising with the platform team: one role for all three jobs is the
#  convenient choice, but it means the `ingest` job can write to `published`.
#  A per-job role would be true least privilege at the cost of more moving
#  parts. Whichever they pick, the golden template must decide it -- this is
#  precisely the sort of thing that fragments if left to each team.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "glue_job" {
  name                 = "${local.name}-${var.pipeline_name}-glue-job"
  description          = "Execution role for the ${var.pipeline_name} Glue PySpark jobs."
  assume_role_policy   = data.aws_iam_policy_document.assume["glue"].json
  max_session_duration = 3600

  tags = { Component = "glue" }
}

# Grants Glue the CloudWatch Logs and ENI permissions it needs to run at all.
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_job.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_job" {
  statement {
    sid    = "ReadPipelineInputsAndCode"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = [
      local.bucket_objects["landing"],
      local.bucket_objects["raw"],
      local.bucket_objects["curated"],
      local.bucket_objects["artifacts"], # job script + shared wheel
    ]
  }

  statement {
    sid    = "ListPipelineBuckets"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      local.bucket_arns["landing"],
      local.bucket_arns["raw"],
      local.bucket_arns["curated"],
      local.bucket_arns["published"],
      local.bucket_arns["artifacts"],
    ]
  }

  statement {
    sid    = "WritePipelineOutputs"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      local.bucket_objects["raw"],
      local.bucket_objects["curated"],
      local.bucket_objects["published"],
      local.bucket_objects["landing"], # rejects are written back beside the drop
      # EMRFS creates these sibling markers before writing each zone prefix.
      "${aws_s3_bucket.zone["data"].arn}/${var.pipeline_name}/raw_$folder$",
      "${aws_s3_bucket.zone["data"].arn}/${var.pipeline_name}/curated_$folder$",
      "${aws_s3_bucket.zone["data"].arn}/${var.pipeline_name}/published_$folder$",
    ]
  }

  # Glue Data Catalog: the jobs register and read table metadata.
  statement {
    sid    = "GlueDataCatalog"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:GetTable",
      "glue:GetTables",
      "glue:BatchCreatePartition",
      "glue:CreatePartition",
      "glue:UpdatePartition",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
    ]
    resources = [
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/${replace(var.pipeline_name, "-", "_")}_*",
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/${replace(var.pipeline_name, "-", "_")}_*/*",
    ]
  }

  statement {
    sid    = "JobLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:AssociateKmsKey",
    ]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws-glue/*"]
  }
}

resource "aws_iam_role_policy" "glue_job" {
  name   = "pipeline-access"
  role   = aws_iam_role.glue_job.id
  policy = data.aws_iam_policy_document.glue_job.json
}

# ─────────────────────────────────────────────────────────────────────────────
#  2. Lambda: arrival handler (ZIP artifact).
#
#  Triggered by the S3 event on landing/. Validates the drop and starts the
#  Step Functions execution. Deliberately tiny: boto3 only, no heavy deps,
#  so it fits the ZIP path (golden-ci-python-zip).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda_arrival" {
  name               = "${local.name}-${var.pipeline_name}-lambda-arrival"
  description        = "Execution role for the ${var.pipeline_name} arrival handler Lambda (ZIP)."
  assume_role_policy = data.aws_iam_policy_document.assume["lambda"].json

  tags = { Component = "lambda-arrival" }
}

resource "aws_iam_role_policy_attachment" "lambda_arrival_basic" {
  role       = aws_iam_role.lambda_arrival.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_arrival" {
  statement {
    sid       = "ReadTheDrop"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:HeadObject"]
    resources = [local.bucket_objects["landing"]]
  }

  statement {
    sid       = "ListLanding"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arns["landing"]]
  }

  statement {
    sid       = "ReadActiveRelease"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.zone["artifacts"].arn}/release-manifests/${var.pipeline_name}/active.json"]
  }

  statement {
    sid       = "WriteManifestAndRejects"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = [local.bucket_objects["landing"]]
  }

  # The coupling that matters: this Lambda must know the state machine ARN.
  statement {
    sid       = "StartTheOrchestrator"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [local.state_machine_arn_pattern]
  }
}

resource "aws_iam_role_policy" "lambda_arrival" {
  name   = "pipeline-access"
  role   = aws_iam_role.lambda_arrival.id
  policy = data.aws_iam_policy_document.lambda_arrival.json
}

# ─────────────────────────────────────────────────────────────────────────────
#  3. Lambda: data-quality gate (CONTAINER artifact).
#
#  Needs pandas/pyarrow to assert on curated data, which blows the 250 MB
#  unzipped ZIP limit. That single dependency decision is what forces a second
#  artifact type -- and therefore a second CI toolchain (container scan, SBOM,
#  signing). It is the cleanest example of why "one CI pipeline" struggles.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda_dq_gate" {
  name               = "${local.name}-${var.pipeline_name}-lambda-dq-gate"
  description        = "Execution role for the ${var.pipeline_name} data-quality gate Lambda (container image)."
  assume_role_policy = data.aws_iam_policy_document.assume["lambda"].json

  tags = { Component = "lambda-dq-gate" }
}

resource "aws_iam_role_policy_attachment" "lambda_dq_basic" {
  role       = aws_iam_role.lambda_dq_gate.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_dq_gate" {
  statement {
    sid       = "ReadCurated"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = [local.bucket_objects["curated"]]
  }

  statement {
    sid       = "ListCurated"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.bucket_arns["curated"]]
  }

  statement {
    sid       = "WriteQualityReport"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = [local.bucket_objects["published"]]
  }

  statement {
    sid    = "CatalogRead"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetPartitions",
    ]
    resources = [
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/${replace(var.pipeline_name, "-", "_")}_*",
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/${replace(var.pipeline_name, "-", "_")}_*/*",
    ]
  }
}

resource "aws_iam_role_policy" "lambda_dq_gate" {
  name   = "pipeline-access"
  role   = aws_iam_role.lambda_dq_gate.id
  policy = data.aws_iam_policy_document.lambda_dq_gate.json
}

# ─────────────────────────────────────────────────────────────────────────────
#  4. Step Functions role -- the orchestrator.
#
#  This role is the composition. It is the one component that must know about
#  every other component, which is why the state machine cannot sensibly be
#  released on its own schedule.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "state_machine" {
  name               = "${local.name}-${var.pipeline_name}-sfn"
  description        = "Execution role for the ${var.pipeline_name} Step Functions state machine."
  assume_role_policy = data.aws_iam_policy_document.assume["states"].json

  tags = { Component = "step-functions" }
}

data "aws_iam_policy_document" "state_machine" {
  statement {
    sid    = "RunGlueJobs"
    effect = "Allow"
    actions = [
      "glue:StartJobRun",
      "glue:GetJobRun",
      "glue:GetJobRuns",
      "glue:BatchStopJobRun",
    ]
    resources = [local.glue_job_arn_pattern]
  }

  statement {
    sid       = "InvokePipelineLambdas"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.lambda_fn_arn_pattern, "${local.lambda_fn_arn_pattern}:*"]
  }

  # Step Functions logging needs these at "*" -- the log delivery APIs are not
  # resource-scopable. Worth knowing before a security review asks why.
  statement {
    sid    = "ExecutionLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "Tracing"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "state_machine" {
  name   = "pipeline-access"
  role   = aws_iam_role.state_machine.id
  policy = data.aws_iam_policy_document.state_machine.json
}

# ─────────────────────────────────────────────────────────────────────────────
#  5. Deployer role trust anchor (placeholder).
#
#  This is the role Harness will assume to deploy. Left commented because it
#  needs the Harness AWS connector's OIDC/IAM principal, which does not exist
#  yet. Flagged here so it is not forgotten when we get to the Harness phase.
# ─────────────────────────────────────────────────────────────────────────────
#
# resource "aws_iam_role" "harness_deployer" {
#   name = "${local.name}-${var.pipeline_name}-harness-deployer"
#   # trust: Harness delegate role ARN, or OIDC provider for Harness Cloud
#   # permissions needed:
#   #   s3:PutObject          -> artifacts/glue-scripts/**  (deploy Glue code)
#   #   s3:PutObject          -> artifacts/python-libs/**   (deploy shared wheel)
#   #   glue:UpdateJob/CreateJob
#   #   lambda:UpdateFunctionCode, PublishVersion, UpdateAlias
#   #   states:UpdateStateMachine, CreateStateMachine
#   #   ecr:GetAuthorizationToken, BatchCheckLayerAvailability, PutImage, ...
#   #   iam:PassRole          -> the four roles above
#   # NOTE: iam:PassRole on those roles is the privilege that makes the deployer
#   #       role powerful. It belongs in a platform-owned policy, not a team one.
# }
