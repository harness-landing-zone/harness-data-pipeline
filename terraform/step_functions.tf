resource "aws_cloudwatch_log_group" "orchestrator" {
  name              = "/aws/vendedlogs/states/${local.name}-${var.pipeline_name}-orchestrator"
  retention_in_days = 14

  tags = { Component = "step-functions" }
}

resource "aws_sfn_state_machine" "orchestrator" {
  name     = "${local.name}-${var.pipeline_name}-orchestrator"
  role_arn = aws_iam_role.state_machine.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment        = "Runtime orchestration for one accounts-daily data file"
    StartAt        = "GlueIngestRaw"
    TimeoutSeconds = 3600
    States = {
      GlueIngestRaw = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.ingest_raw.name
          Arguments = {
            "--scriptLocation.$" = "$.release.glue_ingest_raw_script_uri"
            "--source_uri.$"     = "$.source_uri"
            "--raw_uri.$"        = "$.raw_uri"
            "--rejects_uri.$"    = "$.rejects_uri"
            "--business_date.$"  = "$.business_date"
            "--run_id.$"         = "$.run_id"
          }
        }
        TimeoutSeconds = 1800
        Retry = [{
          ErrorEquals = [
            "Glue.ConcurrentRunsExceededException",
            "Glue.InternalServiceException",
            "Glue.OperationTimeoutException",
            "States.Timeout",
          ]
          IntervalSeconds = 10
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "FailIngest"
        }]
        ResultPath = "$.ingest_raw_result"
        End        = true
      }
      FailIngest = {
        Type  = "Fail"
        Error = "GlueIngestFailed"
        Cause = "Inspect the Glue Job Run recorded in the execution history."
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.orchestrator.arn}:*"
    include_execution_data = false
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  tags = { Component = "step-functions" }
}
