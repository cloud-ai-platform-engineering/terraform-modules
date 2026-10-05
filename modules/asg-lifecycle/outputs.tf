###############################################################################
# modules/asg-lifecycle/outputs.tf
###############################################################################

output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.this.name
}

output "asg_arn" {
  description = "ARN of the Auto Scaling Group"
  value       = aws_autoscaling_group.this.arn
}

output "lambda_function_name" {
  description = "Name of the lifecycle hook Lambda function"
  value       = aws_lambda_function.lifecycle.function_name
}

output "lambda_function_arn" {
  description = "ARN of the lifecycle hook Lambda function"
  value       = aws_lambda_function.lifecycle.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for lifecycle event notifications"
  value       = aws_sns_topic.lifecycle_events.arn
}

output "dlq_url" {
  description = "URL of the Lambda Dead Letter Queue — monitor this for silent failures"
  value       = aws_sqs_queue.lambda_dlq.url
}

output "dlq_arn" {
  description = "ARN of the Lambda Dead Letter Queue"
  value       = aws_sqs_queue.lambda_dlq.arn
}

output "security_group_id" {
  description = "Security group ID attached to ASG instances"
  value       = aws_security_group.asg.id
}

output "instance_profile_name" {
  description = "IAM instance profile name — use when referencing from other modules"
  value       = aws_iam_instance_profile.ec2.name
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule capturing lifecycle events"
  value       = aws_cloudwatch_event_rule.asg_terminating.arn
}
