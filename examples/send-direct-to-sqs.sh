#!/usr/bin/env bash
# Send directly to the SQS queue, bypassing SNS.
# Usage: QUEUE_URL=<your SQS queue URL: terraform output sqs_queue_url> ./send-direct-to-sqs.sh "message"
set -euo pipefail

MESSAGE="${1:-direct SQS test}"

aws sqs send-message \
  --queue-url "${QUEUE_URL:?set QUEUE_URL (terraform output sqs_queue_url)}" \
  --message-body "$MESSAGE"
