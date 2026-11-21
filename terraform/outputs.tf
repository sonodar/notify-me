output "sns_topic_arn" {
  description = "Publish notifications here from your programs"
  value       = aws_sns_topic.this.arn
}

output "sqs_queue_url" {
  description = "Main queue URL (you can also send directly to this queue)"
  value       = aws_sqs_queue.this.id
}

output "sqs_dlq_url" {
  description = "Dead-letter queue URL (messages that failed repeatedly land here)"
  value       = aws_sqs_queue.dlq.id
}

output "notifier_lambda_name" {
  value = aws_lambda_function.notifier.function_name
}

output "webhook_url" {
  description = "Register this URL as the Messaging API webhook to capture your userId (null when enable_webhook = false)"
  value       = var.enable_webhook ? aws_lambda_function_url.webhook[0].function_url : null
}

output "ssm_prefix" {
  value = local.ssm_prefix
}
