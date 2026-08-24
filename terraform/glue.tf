# Terraform owns a stable job shell. CD selects the immutable release for each
# run with StartJobRun --arguments --scriptLocation=s3://.../<sha>/ingest_raw.py.
locals {
  ingest_raw_script_key = "glue-scripts/${var.pipeline_name}/bootstrap/ingest_raw.py"
}

resource "aws_glue_job" "ingest_raw" {
  name     = "${local.name}-${var.pipeline_name}-ingest-raw"
  role_arn = aws_iam_role.glue_job.arn

  glue_version = "5.0"
  worker_type  = "G.1X"

  number_of_workers = 2
  max_retries       = 0
  timeout           = 30

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.zone["artifacts"].id}/${local.ingest_raw_script_key}"
  }

  default_arguments = {
    "--TempDir"                          = "s3://${aws_s3_bucket.zone["data"].id}/${var.pipeline_name}/raw/_glue-temp/"
    "--enable-continuous-cloudwatch-log" = "true"
    "--job-language"                     = "python"
  }

  execution_property {
    # The job overwrites one business-date partition, so concurrent runs would
    # race on the same output when given the same date.
    max_concurrent_runs = 1
  }

  tags = {
    Component = "glue-ingest-raw"
    Artifact  = "python-script"
  }
}
