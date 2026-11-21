terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  ssm_prefix = "/${var.name_prefix}"
}

# ---------------------------------------------------------------------------
# SSM Parameter Store: secrets live here, NOT in Terraform state.
# Terraform only creates placeholders; real values are written afterwards
# with `aws ssm put-parameter --overwrite` (see README), and
# lifecycle.ignore_changes keeps Terraform from reverting them.
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "channel_access_token" {
  name        = "${local.ssm_prefix}/channel-access-token"
  description = "LINE Messaging API channel access token (long-lived)"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "channel_secret" {
  name        = "${local.ssm_prefix}/channel-secret"
  description = "LINE Messaging API channel secret (webhook signature verification)"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "user_id" {
  name        = "${local.ssm_prefix}/user-id"
  description = "Destination LINE userId (U...) for push messages"
  type        = "String"
  value       = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}

# ---------------------------------------------------------------------------
# SNS Topic -> SQS Queue (+ DLQ) -> Lambda
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "this" {
  name = var.name_prefix
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "this" {
  name                       = var.name_prefix
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.lambda_timeout_seconds * 6

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })
}

# Allow only this SNS topic to send into the queue.
resource "aws_sqs_queue_policy" "this" {
  queue_url = aws_sqs_queue.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.this.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.this.arn }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "sqs" {
  topic_arn = aws_sns_topic.this.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.this.arn
  # Keep the SNS envelope: handler.py understands it, and Subject survives.
  raw_message_delivery = false
}

# ---------------------------------------------------------------------------
# Lambda: notifier
# ---------------------------------------------------------------------------
data "archive_file" "notifier" {
  type        = "zip"
  source_file = "${path.module}/../lambda/handler.py"
  output_path = "${path.module}/build/notifier.zip"
}

resource "aws_iam_role" "notifier" {
  name = "${var.name_prefix}-notifier"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "notifier" {
  name = "${var.name_prefix}-notifier"
  role = aws_iam_role.notifier.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.this.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
      },
    ]
  })
}

resource "aws_lambda_function" "notifier" {
  function_name    = "${var.name_prefix}-notifier"
  role             = aws_iam_role.notifier.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = var.lambda_timeout_seconds
  filename         = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256

  environment {
    variables = {
      SSM_PREFIX = local.ssm_prefix
    }
  }
}

resource "aws_cloudwatch_log_group" "notifier" {
  name              = "/aws/lambda/${aws_lambda_function.notifier.function_name}"
  retention_in_days = 30
}

resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn                   = aws_sqs_queue.this.arn
  function_name                      = aws_lambda_function.notifier.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
}

# ---------------------------------------------------------------------------
# Lambda: webhook (userId capture only, optional)
# ---------------------------------------------------------------------------
data "archive_file" "webhook" {
  count       = var.enable_webhook ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/../lambda/webhook_handler.py"
  output_path = "${path.module}/build/webhook.zip"
}

resource "aws_iam_role" "webhook" {
  count = var.enable_webhook ? 1 : 0
  name  = "${var.name_prefix}-webhook"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "webhook" {
  count = var.enable_webhook ? 1 : 0
  name  = "${var.name_prefix}-webhook"
  role  = aws_iam_role.webhook[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/channel-secret"
      },
    ]
  })
}

resource "aws_lambda_function" "webhook" {
  count            = var.enable_webhook ? 1 : 0
  function_name    = "${var.name_prefix}-webhook"
  role             = aws_iam_role.webhook[0].arn
  handler          = "webhook_handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = data.archive_file.webhook[0].output_path
  source_code_hash = data.archive_file.webhook[0].output_base64sha256

  environment {
    variables = {
      SSM_PREFIX = local.ssm_prefix
    }
  }
}

resource "aws_cloudwatch_log_group" "webhook" {
  count             = var.enable_webhook ? 1 : 0
  name              = "/aws/lambda/${aws_lambda_function.webhook[0].function_name}"
  retention_in_days = 30
}

resource "aws_lambda_function_url" "webhook" {
  count              = var.enable_webhook ? 1 : 0
  function_name      = aws_lambda_function.webhook[0].function_name
  authorization_type = "NONE"
}
