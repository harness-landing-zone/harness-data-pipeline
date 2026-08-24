import io
import json
import unittest

from handler import LANDING_HEADER, lambda_handler


class FakeS3:
    def get_object(self, Bucket, Key, Range=None):
        if Key.endswith("active.json"):
            manifest = {
                "release_id": "accounts-daily-test",
                "components": {
                    "glue_ingest_raw": {
                        "script_uri": (
                            f"s3://{Bucket}/glue-scripts/accounts-daily/abc123/ingest_raw.py"
                        )
                    }
                },
            }
            return {"Body": io.BytesIO(json.dumps(manifest).encode()), "VersionId": "manifest-v1"}
        return {"Body": io.BytesIO((",".join(LANDING_HEADER) + "\nrow").encode())}


class FakeStepFunctions:
    def __init__(self):
        self.calls = []

    def start_execution(self, **kwargs):
        self.calls.append(kwargs)
        return {"executionArn": "arn:aws:states:eu-west-2:123:execution:test:one"}


class ArrivalTest(unittest.TestCase):
    def test_landing_event_starts_sha_pinned_execution(self):
        sfn = FakeStepFunctions()
        event = {
            "Records": [
                {
                    "eventSource": "aws:s3",
                    "s3": {
                        "bucket": {"name": "data-bucket"},
                        "object": {
                            "key": "accounts-daily/landing/accounts_20260820.csv",
                            "size": 100,
                            "eTag": "etag-1",
                            "sequencer": "001",
                        },
                    },
                }
            ]
        }
        environ = {
            "DATA_BUCKET": "data-bucket",
            "ARTIFACTS_BUCKET": "artifacts-bucket",
            "PIPELINE_NAME": "accounts-daily",
            "ACTIVE_RELEASE_KEY": "release-manifests/accounts-daily/active.json",
            "STATE_MACHINE_ARN": "arn:aws:states:eu-west-2:123:stateMachine:test",
        }

        result = lambda_handler(event, None, s3=FakeS3(), sfn=sfn, environ=environ)
        execution_input = json.loads(sfn.calls[0]["input"])

        self.assertEqual(result["release_id"], "accounts-daily-test")
        self.assertEqual(execution_input["business_date"], "2026-08-20")
        self.assertEqual(execution_input["source_uri"], "s3://data-bucket/accounts-daily/landing/accounts_20260820.csv")
        self.assertEqual(
            execution_input["release"]["glue_ingest_raw_script_uri"],
            "s3://artifacts-bucket/glue-scripts/accounts-daily/abc123/ingest_raw.py",
        )


if __name__ == "__main__":
    unittest.main()
