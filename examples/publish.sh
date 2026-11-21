#!/usr/bin/env bash
# Send a test notification via SNS (the normal producer path).
# Usage: TOPIC_ARN=<your SNS topic ARN: terraform output sns_topic_arn> ./publish.sh "message" "subject"
set -euo pipefail

MESSAGE="${1:-test notification from notify-me}"
SUBJECT="${2:-Test}"

aws sns publish \
  --topic-arn "${TOPIC_ARN:?set TOPIC_ARN (terraform output sns_topic_arn)}" \
  --subject "$SUBJECT" \
  --message "$MESSAGE"
