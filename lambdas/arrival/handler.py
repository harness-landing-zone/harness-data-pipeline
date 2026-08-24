"""Validate a landing event and start one data-pipeline execution.

The artifacts bucket never invokes this function. CI publishes immutable code;
an S3 ObjectCreated event under the data bucket's landing prefix starts runtime.
"""

import csv
import hashlib
import json
import os
import re
from datetime import datetime
from urllib.parse import unquote_plus


LANDING_HEADER = [
    "account_id",
    "customer_id",
    "country",
    "opened_date",
    "credit_limit",
    "balance",
    "status",
    "updated_at",
]
FILENAME = re.compile(r"accounts_(\d{8})\.csv\Z")


def _read_json(body):
    return json.loads(body.read().decode("utf-8"))


def _load_release(s3, bucket, key, pipeline):
    response = s3.get_object(Bucket=bucket, Key=key)
    manifest = _read_json(response["Body"])
    release_id = manifest.get("release_id")
    script_uri = manifest.get("components", {}).get("glue_ingest_raw", {}).get("script_uri")
    expected_prefix = f"s3://{bucket}/glue-scripts/{pipeline}/"

    if not release_id or not isinstance(script_uri, str):
        raise ValueError("active release is missing release_id or Glue script_uri")
    if not script_uri.startswith(expected_prefix) or not script_uri.endswith("/ingest_raw.py"):
        raise ValueError("active release points outside the approved Glue script prefix")

    return release_id, script_uri, response.get("VersionId")


def _source(s3, record, expected_bucket, pipeline):
    bucket = record["s3"]["bucket"]["name"]
    obj = record["s3"]["object"]
    key = unquote_plus(obj["key"])
    prefix = f"{pipeline}/landing/"

    if bucket != expected_bucket or not key.startswith(prefix):
        raise ValueError(f"event outside approved landing location: s3://{bucket}/{key}")

    filename = key[len(prefix) :]
    match = FILENAME.fullmatch(filename)
    if not match:
        raise ValueError(f"unexpected landing filename: {filename}")
    if int(obj.get("size", 0)) <= 0:
        raise ValueError(f"zero-byte landing object: s3://{bucket}/{key}")

    business_date = datetime.strptime(match.group(1), "%Y%m%d").date().isoformat()
    first_kib = s3.get_object(Bucket=bucket, Key=key, Range="bytes=0-1023")["Body"].read()
    first_line = first_kib.decode("utf-8-sig").splitlines()[0]
    if next(csv.reader([first_line]), []) != LANDING_HEADER:
        raise ValueError(f"landing header does not match the contract: s3://{bucket}/{key}")

    identity = obj.get("versionId") or obj.get("sequencer") or obj.get("eTag", "")
    digest = hashlib.sha256(f"{bucket}\0{key}\0{identity}".encode()).hexdigest()[:32]
    run_id = f"{pipeline[:30]}-{match.group(1)}-{digest}"
    return bucket, key, business_date, run_id, obj


def lambda_handler(event, context, *, s3=None, sfn=None, environ=None):
    """AWS Lambda entry point; keyword clients keep the core locally testable."""
    environ = os.environ if environ is None else environ
    data_bucket = environ["DATA_BUCKET"]
    artifacts_bucket = environ["ARTIFACTS_BUCKET"]
    pipeline = environ["PIPELINE_NAME"]
    active_release_key = environ["ACTIVE_RELEASE_KEY"]
    state_machine_arn = environ["STATE_MACHINE_ARN"]

    if s3 is None or sfn is None:
        import boto3  # Available in Lambda; deliberately absent from the ZIP.

        s3 = s3 or boto3.client("s3")
        sfn = sfn or boto3.client("stepfunctions")

    release_id, script_uri, manifest_version = _load_release(
        s3, artifacts_bucket, active_release_key, pipeline
    )
    executions = []

    for record in event.get("Records", []):
        if record.get("eventSource") != "aws:s3":
            raise ValueError("arrival Lambda accepts only S3 events")

        bucket, key, business_date, run_id, obj = _source(s3, record, data_bucket, pipeline)
        execution_input = {
            "pipeline": pipeline,
            "run_id": run_id,
            "business_date": business_date,
            "source_uri": f"s3://{bucket}/{key}",
            "raw_uri": f"s3://{data_bucket}/{pipeline}/raw/",
            "rejects_uri": f"s3://{data_bucket}/{pipeline}/landing/_rejects/",
            "source": {
                "bucket": bucket,
                "key": key,
                "size": obj.get("size"),
                "etag": obj.get("eTag"),
                "version_id": obj.get("versionId"),
            },
            "release": {
                "id": release_id,
                "manifest_uri": f"s3://{artifacts_bucket}/{active_release_key}",
                "manifest_version": manifest_version,
                "glue_ingest_raw_script_uri": script_uri,
            },
        }

        try:
            result = sfn.start_execution(
                stateMachineArn=state_machine_arn,
                name=run_id,
                input=json.dumps(execution_input, separators=(",", ":")),
            )
            executions.append({"run_id": run_id, "execution_arn": result["executionArn"]})
        except Exception as exc:
            code = getattr(exc, "response", {}).get("Error", {}).get("Code")
            if code != "ExecutionAlreadyExists":
                raise
            executions.append({"run_id": run_id, "duplicate": True})

    if not executions:
        raise ValueError("S3 event contained no records")
    return {"release_id": release_id, "executions": executions}
