"""Minimal second Lambda used to exercise the multi-service deployment path."""


def lambda_handler(event, _context):
    return {"component": "transform", "event": event}
