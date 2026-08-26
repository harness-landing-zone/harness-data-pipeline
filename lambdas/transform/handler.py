"""Minimal second Lambda used to exercise the multi-service deployment path."""


def lambda_handler(event, _context):
    return {
        "component": "transform",
        "release": "cd-only-test-v2",
        "message": "Deployed by Harness CD",
        "event": event,
    }
