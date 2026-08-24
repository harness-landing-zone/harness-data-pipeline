# ─────────────────────────────────────────────────────────────────────────────
#  ECR: registry for the container-based Lambda (the data-quality gate).
#
#  Only ONE of the seven pipeline components produces a container image. That
#  asymmetry is the heart of the customer's question: a monolithic CI pipeline
#  would carry the whole container toolchain -- build, scan, SBOM, sign, push --
#  for a single component, and skip it on most commits.
#
#  IMMUTABLE tags below are the concrete implementation of the platform's
#  "build once, scan once, promote digest" principle. Note that this is the ONLY
#  component where that principle works natively. Glue scripts and the shared
#  wheel need an invented equivalent (versioned S3 keys) -- see README.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "dq_gate" {
  name = "${local.name}/${var.pipeline_name}/dq-gate"

  # Cannot overwrite a tag once pushed. Forces every build to produce a new
  # identity, which is what makes digest promotion meaningful.
  image_tag_mutability = "IMMUTABLE"

  force_delete = var.destroyable

  # Ties into the mandated container-scan / SAST gate.
  # This is the AWS-native scan; Harness STO would layer its own scanner on top.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name      = "${local.name}-${var.pipeline_name}-dq-gate"
    Component = "lambda-dq-gate"
    Artifact  = "container-image"
  }
}

# Keep the registry from growing without bound. Untagged images are build
# by-products; tagged ones are potential rollback targets, so keep more.
resource "aws_ecr_lifecycle_policy" "dq_gate" {
  repository = aws_ecr_repository.dq_gate.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Retain the 30 most recent tagged images as rollback targets"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["build-", "sha-", "v"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}

# Lambda pulls the image at function create/update time using a service
# principal, not the execution role. Without this the console gives an unhelpful
# "cannot access image" error, which is a classic first-time-container-Lambda trap.
data "aws_iam_policy_document" "dq_gate_repo" {
  statement {
    sid    = "AllowLambdaServicePull"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]

    condition {
      test     = "StringLike"
      variable = "aws:sourceArn"
      values   = [local.lambda_fn_arn_pattern]
    }
  }
}

resource "aws_ecr_repository_policy" "dq_gate" {
  repository = aws_ecr_repository.dq_gate.name
  policy     = data.aws_iam_policy_document.dq_gate_repo.json
}
