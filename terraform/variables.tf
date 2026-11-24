variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "notify-me"
}

variable "enable_webhook" {
  description = "Deploy the one-purpose webhook Lambda (Function URL) used to capture your LINE userId. Set to false after capture."
  type        = bool
  default     = true
}

variable "lambda_timeout_seconds" {
  description = "Timeout of the notifier Lambda. SQS visibility timeout is set to 6x this value."
  type        = number
  default     = 30
}

variable "sqs_max_receive_count" {
  description = "How many times a message may be received before it moves to the DLQ"
  type        = number
  default     = 3
}

variable "message_retention_seconds" {
  description = "Retention of the main queue (default: 4 days)"
  type        = number
  default     = 345600
}

variable "line_channel_access_token" {
  description = "LINE Messaging API channel access token (long-lived). Leave unset to create a placeholder and write the real value with the AWS CLI afterwards."
  type        = string
  sensitive   = true
  default     = null
}

variable "line_channel_secret" {
  description = "LINE Messaging API channel secret. Leave unset to create a placeholder and write the real value with the AWS CLI afterwards."
  type        = string
  sensitive   = true
  default     = null
}

variable "line_user_id" {
  description = "Destination LINE userId (U...). Leave unset to create a placeholder and write the real value with the AWS CLI afterwards."
  type        = string
  sensitive   = true
  default     = null
}

variable "ssm_value_version" {
  description = "Version counter for the write-only SSM values (value_wo_version). Increment it whenever you change one of the line_* variables above so Terraform sends the new value."
  type        = number
  default     = 1
}
