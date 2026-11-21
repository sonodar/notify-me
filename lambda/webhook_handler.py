"""
One-purpose webhook receiver: capture your LINE userId.

Deploy behind a Lambda Function URL, register the URL as the Messaging API
webhook, then add the official account as a friend (or send it any message).
Your userId (U...) is written to CloudWatch Logs:

    USER_ID_CAPTURED Uxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

Then store it in SSM and you no longer need this webhook
(set enable_webhook = false in Terraform to remove it).

Signature verification uses the channel secret from SSM:
    /notify-me/channel-secret
If that parameter is still the placeholder, verification is skipped
and a warning is logged -- acceptable only during the first capture.
"""

import base64
import hashlib
import hmac
import json
import os

import boto3

_ssm = None
_secret = None


def _channel_secret():
    global _ssm, _secret
    if _secret is not None:
        return _secret
    secret = os.environ.get("LINE_CHANNEL_SECRET")
    if not secret:
        prefix = os.environ.get("SSM_PREFIX", "/notify-me")
        if _ssm is None:
            _ssm = boto3.client("ssm")
        secret = _ssm.get_parameter(
            Name=f"{prefix}/channel-secret", WithDecryption=True
        )["Parameter"]["Value"]
    _secret = secret
    return secret


def _valid_signature(body: bytes, signature: str, secret: str) -> bool:
    mac = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).digest()
    expected = base64.b64encode(mac).decode("utf-8")
    return hmac.compare_digest(expected, signature or "")


def lambda_handler(event, context):
    raw_body = event.get("body") or ""
    body_bytes = raw_body.encode("utf-8")
    if event.get("isBase64Encoded"):
        body_bytes = base64.b64decode(raw_body)
        raw_body = body_bytes.decode("utf-8", errors="replace")

    secret = _channel_secret()
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if secret and secret != "REPLACE_ME":
        if not _valid_signature(
            body_bytes, headers.get("x-line-signature", ""), secret
        ):
            print("WARNING: invalid LINE signature")
            return {"statusCode": 403, "body": "invalid signature"}
    else:
        print("WARNING: channel secret not set, skipping signature verification")

    try:
        payload = json.loads(raw_body or "{}")
    except json.JSONDecodeError:
        return {"statusCode": 400, "body": "invalid json"}

    for ev in payload.get("events", []):
        source = ev.get("source") or {}
        user_id = source.get("userId")
        if user_id:
            # This exact line is what you grep in CloudWatch Logs.
            print(f"USER_ID_CAPTURED {user_id} event_type={ev.get('type')}")
        else:
            print(f"event without userId: type={ev.get('type')} source={source}")

    # LINE expects a 200 response; reply messages are intentionally not used
    # (they are free, but this receiver exists only to capture the userId).
    return {"statusCode": 200, "body": "ok"}
