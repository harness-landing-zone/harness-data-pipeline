# Data pipeline reference environment — Terraform

Creates the stable AWS substrate plus the first complete runtime slice:
`landing CSV -> arrival Lambda -> Step Functions -> Glue ingest -> raw`.

State is managed by the Harness IaCM workspace. Do not commit state files. If
this stack already exists, migrate or import its state before the first plan.

## What gets created

| Resource | Count | Why it's here |
|---|---|---|
| S3 buckets | 2 | `data` for zone prefixes; `artifacts` for deployed code |
| Bucket hardening | ×2 | versioning, SSE, public-access block, TLS-only policy, lifecycle |
| IAM roles | 4 | Glue jobs, arrival Lambda, DQ-gate Lambda, Step Functions |
| ECR repository | 1 | container image for the DQ-gate Lambda, **immutable tags** |
| Glue job | 1 | Stable job shell; each run selects an immutable script key |
| Arrival Lambda | 1 | Validates a landing event, resolves the active release, starts one execution |
| Step Functions workflow | 1 | Standard workflow with one synchronous Glue task |
| S3 event notification | 1 | Only `accounts-daily/landing/*.csv` invokes the arrival Lambda |
| CloudWatch log group | 1 | Step Functions logs retained for 14 days |
| Harness CD service | 1 | Deploys immutable ZIP releases to the OpenTofu-created arrival Lambda |

`artifacts` is the one to look at closely. It is not a data zone — it is where
Glue job code and the shared Python wheel live. **It is a deploy target.**

## Bootstrap prerequisites

The existing reference environment has the Glue bootstrap script, Lambda
bootstrap ZIP, and active-release manifest already published. On a clean
environment those three objects must exist before the full apply; they are
release artifacts, not Terraform resources.

The Glue publication mechanic is:

```bash
aws sso login
tofu init -upgrade

ARTIFACTS_BUCKET="$(tofu output -json buckets | jq -r .artifacts)"
RELEASE_VERSION="$(shasum -a 256 ../glue/jobs/ingest_raw.py | awk '{print $1}')"

aws s3 cp ../glue/jobs/ingest_raw.py \
  "s3://${ARTIFACTS_BUCKET}/glue-scripts/accounts-daily/bootstrap/ingest_raw.py"
aws s3 cp ../glue/jobs/ingest_raw.py \
  "s3://${ARTIFACTS_BUCKET}/glue-scripts/accounts-daily/${RELEASE_VERSION}/ingest_raw.py"

tofu plan -out=glue.tfplan
tofu apply glue.tfplan
tofu output ingest_raw_glue_job
```

The manual `aws s3 cp` is the learning-phase stand-in for CI publishing tested
and scanned artifacts. Terraform deliberately does not own those objects.
After bootstrap, normal releases publish immutable component keys and promote
one active manifest; they do not run `tofu apply` unless infrastructure changes.

Infrastructure settings have working defaults (`eu-west-2`, prefix
`data-pipeline`, env `dev`, pipeline `accounts-daily`).

## Harness service bootstrap

OpenTofu renders `templates/harness-zip-lambda-service.yaml.tftpl` and
creates the Harness CD service after its Lambda and artifact bucket exist. The
Harness service display name is the AWS function name; its identifier remains a
stable Harness-safe input. It also writes the complete generated function
definition to Harness File Store and configures that supported manifest source
on the Service. Select OpenTofu 1.7 or later for the IaCM workspace.

Add these environment variables to the IaCM workspace:

```text
HARNESS_ACCOUNT_ID
HARNESS_PLATFORM_API_KEY  # secret
```

Store the API key as a Harness secret, not an OpenTofu variable. The API key
needs Service create/update permissions in `harness_org_id` and
`harness_project_id`. The S3 connector is supplied by
`harness_s3_connector_ref`.

For brownfield onboarding only, make an existing `arrival_lambda` Harness
service state-managed during the first plan/approval/apply:

```hcl
import_existing_harness_arrival_service = true
```

The declarative import appears in the plan and becomes inert after the service
is in state. New template instances leave the variable `false`, so OpenTofu
creates their service.

For the reusable paved road, create a linked Harness IaCM workspace template
that locks the OpenTofu version, repository path, AWS connector, default
provision pipeline, required tags, and the shared Harness credential variables.
Keep environment, pipeline name, Harness project, Service identifier, and S3
connector reference as workspace inputs.

### Scaling to more Lambdas and services

When the pattern repeats, use an OpenTofu `for_each` over a typed component map
to create each Lambda shell and its matching Harness Service. OpenTofu already
creates independent graph nodes concurrently; dependencies still determine the
order.

Keep the desired component inventory and the deployment subset separate.
`local.zip_lambda_components` declares which ZIP Lambdas and Harness Services
exist. `LAMBDA_SERVICES_TO_DEPLOY` is an execution-time CSV list that an Input
Set may narrow to one or more existing Services; it must never be fed back into
OpenTofu because omitted components would then be planned for deletion.
Each generated Service owns its component-specific bootstrap artifact key, so
the provisioning Input Set does not contain a shared Lambda file path.

The deployment stage uses the Harness **Repeat** strategy now, even while its
derived list contains one Service, so the one-to-two component transition can
be tested without changing the pipeline definition. `maxConcurrency` limits
concurrent repeat iterations; the separate **Parallelism** strategy is not used
for this case. Continue only after all repeats complete, then promote the
release manifest and run system integration tests. Keep real dependencies
sequential: infrastructure before code deployment, ZIP/image publication before
its Service deployment, and Step Functions or manifest promotion after every
referenced component is ready.

`destroyable` defaults to `false`. Enable it only for an explicitly disposable
environment.

## The naming contract

The IAM roles grant access by **wildcard over a naming convention**. Anything
you create in the console must match, or you will get `AccessDenied` from the
orchestrator:

```
Glue jobs        data-pipeline-dev-accounts-daily-<stage>
Lambdas          data-pipeline-dev-accounts-daily-<purpose>
State machines   data-pipeline-dev-accounts-daily-<name>
Glue databases   accounts_daily_<zone>
```

`terraform output naming_contract` prints this with worked examples.

> This is itself a finding for the advice: the convention is now a **platform
> contract**. If a team renames a Glue job, the orchestrator silently loses
> permission. That argues for the naming being owned by the golden template,
> not by each team.

## Clickops order

Each step exists to teach one mechanic. Don't skip 3 → 4.

| # | Do this | Notice this |
|---|---|---|
| 1 | Look at the 2 buckets | data zones are prefixes; `artifacts/` is a deploy target |
| 2 | Read the 4 IAM roles in the console | every "allow" is a coupling between two components |
| 3 | Upload the bootstrap and SHA copies, then apply Terraform | the stable job and immutable artifact have separate lifecycles |
| 4 | Start the job with `--scriptLocation` set to the SHA key | the Job Run records the exact release without Terraform drift |
| 5 | Inspect `release-manifests/accounts-daily/active.json` | one release identity selects the exact runtime artifacts |
| 6 | Inspect the arrival Lambda and its S3 trigger | the data event starts runtime; artifact uploads do not |
| 7 | Inspect the Step Functions execution graph and linked Glue Job Run | orchestration owns cross-service retries and execution history |
| 8 | Upload `accounts_YYYYMMDD.csv` to `accounts-daily/landing/` | the automatic first slice runs end to end |
| 9 | Later: add the shared wheel, transform job, DQ gate, and publish job one at a time | composition grows without changing the release/runtime split |

### Step 4 is the important one

The release version is part of the script key. CD passes that exact key in the
`StartJobRun` arguments, overriding the bootstrap location for only that run.
Rollback means starting a new run with a previous SHA key. Terraform does not
change because the Glue job resource did not change.

## Questions to answer before touching CI/CD

Write the answers down — they are the evidence base for the recommendation.

1. If a Glue deploy is an S3 copy, what is the **rollback**? What guarantees
   **immutability**? (Bucket versioning is enabled, so the raw material is
   there — but does anything *use* it?)
2. Does the state machine **hardcode** Glue job names, or take them as input?
   This decides whether one definition can serve dev, test and prod.
3. Lambda `$LATEST` or an **alias**? This decides whether promote-by-digest is
   possible at all.
4. How does a given environment **pin a wheel version**?
5. **What is the smallest realistic change that forces you to touch two or more
   components?** This is the strongest single piece of evidence in the
   one-pipeline-vs-many argument.

## Deliberately not created

| Not here | Why |
|---|---|
| Transform and aggregate Glue jobs | add one at a time after the first composed slice is understood |
| Shared Python wheel | add with transform when there is a real consumer |
| DQ Lambda function/image | add when the DQ branch is introduced |
| Glue Data Catalog databases/tables | let the crawler or the job create them, then compare |
| KMS CMKs | SSE-S3 keeps the reference environment simple |
| The Harness deployer role | needs the Harness AWS connector's principal — stubbed as a commented block at the bottom of `iam.tf`, including the `iam:PassRole` note |
