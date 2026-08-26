# Data pipeline POC — OpenTofu

The IaCM stage creates each ZIP Lambda and matching Harness Service declared in
`lambdas.auto.tfvars`. The next Harness stage deploys the ZIP from S3.

```hcl
lambdas = {
  example_zip = {
    description = "Example ZIP Lambda deployed by Harness CD."
    memory_size = 128
    timeout     = 10
    environment_variables = {
      LOG_LEVEL = "INFO"
    }
  }

  second_zip = {
    description = "Second ZIP Lambda deployed by Harness CD."
    memory_size = 256
    timeout     = 30
    environment_variables = {
      LOG_LEVEL = "DEBUG"
    }
  }
}
```

Each stable map key creates:

- An IAM execution role and AWS Lambda.
- A bootstrap ZIP in the artifacts S3 bucket.
- A Lambda definition in Harness File Store.
- A Harness AWS Lambda Service that uses that definition and ZIP.

The Lambda is Python 3.12 with handler `handler.lambda_handler`. Harness owns
later code deployments; the Lambda and S3 object lifecycle rules ignore code
changes, so adding another map entry does not restore old code on existing
functions.

The deployment stage can repeat over the
`harness_lambda_service_identifiers` output. No triggers, application IAM, Git
definitions, or image Lambdas are included in this POC; those belong in a
module if they become requirements.

Set `HARNESS_ACCOUNT_ID` and `HARNESS_PLATFORM_API_KEY` in the IaCM workspace.
The `harness_s3_connector_ref` connector must be able to read the artifacts
bucket.
