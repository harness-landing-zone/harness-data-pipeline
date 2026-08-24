data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.aws_region

  name = "${var.name_prefix}-${var.env}"

  common_tags = {
    Project      = "data-pipeline-reference"
    Environment  = var.env
    DataPipeline = var.pipeline_name
    ManagedBy    = "terraform"
    Purpose      = "data-pipeline-cicd-reference"
  }

  # One bucket holds data zones as prefixes. Artifacts stay separate so runtime
  # roles can read deployed code without permission to overwrite it.
  buckets = {
    data = {
      purpose                = "Landing, raw, curated and published data, separated by pipeline prefixes."
      versioning             = true
      transition_ia_days     = 0
      expire_days            = 0
      noncurrent_expire_days = 30
    }
    artifacts = {
      purpose                = "Glue job scripts, shared Python wheels, rendered Step Functions definitions. Deploy target."
      versioning             = true
      transition_ia_days     = 0
      expire_days            = 0
      noncurrent_expire_days = 365
    }
  }

  # Keep IAM statements readable while scoping data access to prefixes.
  bucket_arns = {
    data      = aws_s3_bucket.zone["data"].arn
    landing   = aws_s3_bucket.zone["data"].arn
    raw       = aws_s3_bucket.zone["data"].arn
    curated   = aws_s3_bucket.zone["data"].arn
    published = aws_s3_bucket.zone["data"].arn
    artifacts = aws_s3_bucket.zone["artifacts"].arn
  }

  bucket_objects = {
    landing   = "${aws_s3_bucket.zone["data"].arn}/${var.pipeline_name}/landing/*"
    raw       = "${aws_s3_bucket.zone["data"].arn}/${var.pipeline_name}/raw/*"
    curated   = "${aws_s3_bucket.zone["data"].arn}/${var.pipeline_name}/curated/*"
    published = "${aws_s3_bucket.zone["data"].arn}/${var.pipeline_name}/published/*"
    artifacts = "${aws_s3_bucket.zone["artifacts"].arn}/*"
  }
}
