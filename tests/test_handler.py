import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda"))
os.environ.setdefault("LINE_CHANNEL_ACCESS_TOKEN", "test-token")
os.environ.setdefault("LINE_USER_ID", "test-user-id")

# boto3 is only used for SSM fallback; stub it if not installed locally.
try:
    import boto3  # noqa: F401
except ImportError:
    import types

    sys.modules["boto3"] = types.SimpleNamespace(client=lambda *a, **k: None)

import handler


class ExtractTextTest(unittest.TestCase):
    def test_sns_envelope_with_subject(self):
        body = json.dumps(
            {
                "Type": "Notification",
                "Subject": "Batch finished",
                "Message": "job=42 status=ok",
            }
        )
        self.assertEqual(handler.extract_text(body), "Batch finished\njob=42 status=ok")

    def test_plain_text(self):
        self.assertEqual(handler.extract_text("hello"), "hello")

    def test_direct_json(self):
        body = json.dumps({"title": "Deploy", "text": "done"})
        self.assertEqual(handler.extract_text(body), "Deploy\ndone")

    def test_sns_envelope_json_message_is_pretty_printed(self):
        body = json.dumps(
            {"Type": "Notification", "Message": json.dumps({"a": 1})}
        )
        self.assertIn('"a": 1', handler.extract_text(body))


class ChunkTest(unittest.TestCase):
    def test_short_text_single_chunk(self):
        self.assertEqual(handler.chunk_text("abc"), ["abc"])

    def test_long_text_is_capped(self):
        chunks = handler.chunk_text("x" * 20000)
        self.assertLessEqual(len(chunks), handler.MAX_MESSAGES_PER_PUSH)
        for c in chunks:
            self.assertLessEqual(len(c), 5000)


class HandlerTest(unittest.TestCase):
    def test_permanent_error_drops_record(self):
        calls = []

        def fake_push(token, user_id, text, retry_key):
            calls.append(text)
            raise handler.PermanentError("400 blocked")

        orig = handler.push_to_line
        handler.push_to_line = fake_push
        try:
            event = {"Records": [{"messageId": "m1", "body": "hi"}]}
            result = handler.lambda_handler(event, None)
        finally:
            handler.push_to_line = orig
        self.assertEqual(result, {"batchItemFailures": []})
        self.assertEqual(calls, ["hi"])

    def test_transient_error_returns_failure(self):
        def fake_push(token, user_id, text, retry_key):
            raise RuntimeError("429")

        orig = handler.push_to_line
        handler.push_to_line = fake_push
        try:
            event = {"Records": [{"messageId": "m2", "body": "hi"}]}
            result = handler.lambda_handler(event, None)
        finally:
            handler.push_to_line = orig
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "m2"}]})


if __name__ == "__main__":
    unittest.main()
