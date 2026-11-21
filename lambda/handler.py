"""
SNS -> SQS -> Lambda -> LINE Messaging API (Push)

- Trigger: SQS event source mapping (ReportBatchItemFailures enabled)
- Input shapes supported:
    1. SNS -> SQS (default, non-raw): SQS body is the SNS Notification JSON
    2. SNS -> SQS (raw message delivery): SQS body is the published payload
    3. Direct SQS send: plain text, or JSON {"subject": "...", "message": "..."}
       / {"title": "...", "text": "..."} / {"text": "..."}
- Secrets: read once per cold start from SSM Parameter Store (SecureString)
    /notify-me/channel-access-token
    /notify-me/user-id
  Env vars LINE_CHANNEL_ACCESS_TOKEN / LINE_USER_ID take precedence
  (useful for local tests only -- do not put real tokens in Lambda env in prod
   if you prefer SSM-only; both are supported intentionally).
- Failure semantics:
    * LINE 429 / 5xx / network error -> raise per-record, record is returned
      in batchItemFailures so SQS retries it and eventually sends it to DLQ.
    * LINE 4xx (other than 429) -> permanent error, logged and dropped
      (retrying a malformed message / blocked user will never succeed).
- Deduplication: X-Line-Retry-Key is a UUIDv5 of the SQS MessageId, so a
  Lambda retry of the same record does not deliver a duplicate within 24h.
"""

import json
import os
import urllib.error
import urllib.request
import uuid

import boto3

LINE_PUSH_URL = "https://api.line.me/v2/bot/message/push"
# LINE text message limit is 5000 chars; keep headroom for the truncation note.
MAX_TEXT_LEN = 4900
# One Push call can contain at most 5 message objects.
MAX_MESSAGES_PER_PUSH = 5

_ssm = None
_credentials = None


def _get_credentials():
    global _ssm, _credentials
    if _credentials:
        return _credentials

    token = os.environ.get("LINE_CHANNEL_ACCESS_TOKEN")
    user_id = os.environ.get("LINE_USER_ID")
    if token and user_id:
        _credentials = (token, user_id)
        return _credentials

    prefix = os.environ.get("SSM_PREFIX", "/notify-me")
    if _ssm is None:
        _ssm = boto3.client("ssm")
    token_param = _ssm.get_parameter(
        Name=f"{prefix}/channel-access-token", WithDecryption=True
    )
    user_param = _ssm.get_parameter(Name=f"{prefix}/user-id", WithDecryption=True)
    _credentials = (
        token_param["Parameter"]["Value"],
        user_param["Parameter"]["Value"],
    )
    return _credentials


def extract_text(body: str) -> str:
    """Turn an SQS record body into the notification text."""
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        return body.strip()

    if not isinstance(data, dict):
        return str(data)

    # Shape 1: SNS Notification envelope delivered into SQS.
    if data.get("Type") == "Notification" and "Message" in data:
        subject = (data.get("Subject") or "").strip()
        message = data["Message"]
        # Message itself may be JSON (e.g. AWS service notifications).
        try:
            inner = json.loads(message)
            if isinstance(inner, dict):
                message = json.dumps(inner, ensure_ascii=False, indent=2)
        except (json.JSONDecodeError, TypeError):
            pass
        return f"{subject}\n{message}".strip() if subject else str(message).strip()

    # Shape 3: direct JSON payload.
    subject = (data.get("subject") or data.get("title") or "").strip()
    message = data.get("message") or data.get("text") or data.get("body") or ""
    if not message:
        message = json.dumps(data, ensure_ascii=False, indent=2)
    return f"{subject}\n{message}".strip() if subject else str(message).strip()


def chunk_text(text: str) -> list:
    if len(text) <= MAX_TEXT_LEN:
        return [text]
    chunks = []
    rest = text
    while rest and len(chunks) < MAX_MESSAGES_PER_PUSH:
        if len(rest) <= MAX_TEXT_LEN:
            chunks.append(rest)
            break
        cut = rest.rfind("\n", 0, MAX_TEXT_LEN)
        if cut < MAX_TEXT_LEN // 2:
            cut = MAX_TEXT_LEN
        chunks.append(rest[:cut])
        rest = rest[cut:].lstrip("\n")
    if rest:
        chunks[-1] = chunks[-1][: MAX_TEXT_LEN - 20] + "\n... (truncated)"
    return chunks


class PermanentError(Exception):
    pass


def push_to_line(token: str, user_id: str, text: str, retry_key: str) -> None:
    payload = {
        "to": user_id,
        "messages": [
            {"type": "text", "text": chunk} for chunk in chunk_text(text)
        ],
    }
    req = urllib.request.Request(
        LINE_PUSH_URL,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
            "X-Line-Retry-Key": retry_key,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        if e.code == 429 or e.code >= 500:
            raise RuntimeError(f"LINE API transient error {e.code}: {body}") from e
        raise PermanentError(f"LINE API permanent error {e.code}: {body}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"LINE API network error: {e}") from e


def lambda_handler(event, context):
    token, user_id = _get_credentials()
    failures = []
    for record in event.get("Records", []):
        message_id = record.get("messageId", "")
        try:
            text = extract_text(record.get("body", ""))
            if not text:
                continue
            retry_key = str(uuid.uuid5(uuid.NAMESPACE_URL, f"sqs:{message_id}"))
            push_to_line(token, user_id, text, retry_key)
        except PermanentError as e:
            # Log and drop: retrying will not fix this record.
            print(f"DROP messageId={message_id}: {e}")
        except Exception as e:  # transient -> let SQS retry / DLQ handle it
            print(f"RETRY messageId={message_id}: {e}")
            failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": failures}
