# Harness data pipeline

Monorepo for the reference AWS data pipeline and its Harness delivery code.

## First milestone: IaCM

The initial Harness IaCM workspace uses `terraform/` and provisions the stable
AWS graph: S3 buckets, IAM, Glue job shell, Step Functions, the bootstrap
arrival Lambda, and its S3 event wiring.

Before the first run:

1. Configure the Harness Git and AWS connectors.
2. Create an OpenTofu workspace with repository path `terraform`.
3. Add `HARNESS_ACCOUNT_ID` and secret `HARNESS_PLATFORM_API_KEY` environment
   variables to the workspace so OpenTofu can manage the Harness CD service.
4. Migrate/import existing state if deploying over the reference environment.
   Set `import_existing_harness_arrival_service=true` for the existing
   `arrival_lambda` Service as documented in `terraform/README.md`.
5. Confirm the bootstrap Glue script, Lambda ZIP, and active release manifest
   exist in the artifact bucket.
6. Run `harness/pipelines/data_pipeline_iacm.yaml` manually: init, plan,
   approval, apply.
7. Create `harness/pipelines/lambda_cd.yaml` and configure an S3 artifact
   trigger or input set for each Lambda Service. Supply an immutable release
   key; the bootstrap key is not a deployment default.

Application CI is intentionally deferred until the component release
relationships are agreed. IaCM and Lambda CD are separate so a later
infrastructure apply cannot redeploy bootstrap code.
