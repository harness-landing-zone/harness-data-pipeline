# Harness AWS data pipeline

This repository is an example of using Harness to create and deploy an
AWS data pipeline.

The main idea is to keep two jobs separate:

1. OpenTofu creates the AWS resources and the Harness Lambda services.
2. Harness deploys the Lambda ZIP files after the AWS resources exist.

This separation means an infrastructure change does not replace Lambda code
that Harness has already deployed.

## What it creates

- One private S3 bucket for incoming and processed data.
- One private S3 bucket for Lambda ZIP files and Glue scripts.
- IAM roles for Lambda, Glue, and Step Functions.
- A Glue job that reads a CSV file, rejects bad rows, and writes valid rows as
  Parquet.
- A Step Functions workflow that runs the Glue job.
- One AWS Lambda and one Harness service for every entry in
  `terraform/lambdas.auto.tfvars`.

The Lambda and Glue source examples are in `lambdas/` and `glue/jobs/`.
OpenTofu creates only a small placeholder Lambda ZIP so AWS can create the
function. A developer or CI job must package the real handler and upload it to
the artifact bucket before Harness can deploy the real code.

## Repository layout

```text
harness/pipelines/   Harness pipeline
terraform/           AWS resources and generated Harness services
lambdas/              Example Lambda handlers
glue/jobs/            Example Glue job
```

## Before the first run

You need:

- A Harness AWS connector with access to the target AWS account.
- A Harness Git connector with access to this repository.
- A Harness Infrastructure as Code Management (IaCM) workspace that points to
  the `terraform` directory.
- `HARNESS_ACCOUNT_ID` and `HARNESS_PLATFORM_API_KEY` set in the workspace.
  Store the API key as a Harness secret.
- A Harness environment called `development` and a Lambda infrastructure
  definition called `arrival_lambda_eu_west_2`, or matching changes in
  `harness/pipelines/data_pipeline_iacm.yaml`.
- OpenTofu 1.7 or newer if you want to check the files locally.

Copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars` only
when you need to change the supplied defaults. Do not commit credentials.

## Add a Lambda

Add one entry to `terraform/lambdas.auto.tfvars`:

```hcl
lambdas = {
  arrival = {
    description = "Checks an incoming file."
    memory_size = 128
    timeout     = 20
    environment_variables = {
      LOG_LEVEL = "INFO"
    }
  }
}
```

The entry name is the stable Harness service identifier. OpenTofu uses it to
create the Lambda, its IAM role, its Harness function definition, and its
Harness service.

Lambda ZIPs must contain `handler.py` with a function named `lambda_handler`.
Upload each ZIP to this key in the artifact bucket:

```text
lambdas/<pipeline-name>/<lambda-id>/lambda.zip
```

For the example above, the default key is:

```text
lambdas/accounts-daily/arrival/lambda.zip
```

## Run the pipeline

Use `harness/pipelines/data_pipeline_iacm.yaml` in Harness.

1. Start the pipeline and select the IaCM workspace.
2. Check the OpenTofu plan and approve it.
3. OpenTofu creates or updates the AWS resources and Harness services.
4. The deployment stage deploys the Lambda ZIPs from S3.

By default, the deployment stage uses every Lambda service returned by the
OpenTofu apply. To deploy only some of them, set
`LAMBDA_SERVICES_TO_DEPLOY` to a comma-separated list such as
`arrival,transform`.

## Two ways to keep the Lambda function definition

The function definition is the JSON that tells Harness the Lambda name,
runtime, handler, IAM role, memory, timeout, and environment variables. It is
not the Lambda ZIP.

### Option 1: keep the definition in Git

Add a JSON file to Git and use Harness expressions for values that change by
service or environment:

```json
{
  "functionName": "<+serviceVariables.functionName>",
  "runtime": "python3.12",
  "handler": "handler.lambda_handler",
  "role": "<+serviceVariables.roleArn>",
  "memorySize": "<+serviceVariables.memorySize>",
  "timeout": "<+serviceVariables.timeout>"
}
```

In the Harness service, set the AWS Lambda Function Definition source to Git,
select the Git connector, repository, branch, and JSON file path, then add the
matching service variables. Values can be changed for each environment using
Harness overrides.

Use this option when the team wants definition changes reviewed and versioned
in Git. It needs a Git connector and the service variables must be kept in
sync with the AWS resources.

### Option 2: keep the definition in Harness File Store (current setup)

This repository currently builds the JSON from the OpenTofu values and writes
it to Harness File Store in `terraform/lambda.tf`. The generated Harness
service reads that file through
`terraform/templates/harness-lambda-service.yaml.tftpl`.

Use this option when OpenTofu should be the single place that sets the Lambda
name, role, memory, timeout, and environment variables. No separate JSON file
or Harness service variables are needed.

Whichever option is used, the source code stays in Git and the deployable ZIP
stays in S3.

## Useful local checks

```bash
tofu -chdir=terraform init
tofu -chdir=terraform fmt -check -recursive
tofu -chdir=terraform validate
python3 -m unittest discover -s lambdas/arrival -p 'test_*.py'
```

More detail about the OpenTofu files is in `terraform/README.md`.
