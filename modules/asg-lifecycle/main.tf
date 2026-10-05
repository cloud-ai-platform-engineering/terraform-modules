###############################################################################
# modules/asg-lifecycle/main.tf
#
# Graceful EC2 termination pattern:
#   ASG scale-down → Lifecycle Hook → EventBridge → Lambda → SSM → SNS
#
# Design decisions:
#   - default_result = "ABANDON" so instances never terminate silently on
#     Lambda failure — ops team is paged and can manually resolve
#   - Lambda has a DLQ so no invocation failure goes undetected
#   - heartbeat_timeout is configurable — set generously (>= Lambda timeout)
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "asg-lifecycle"
  })
  name_prefix = var.name
}

###############################################################################
# IAM — EC2 instance profile
###############################################################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.ec2.name
  tags = local.common_tags
}

###############################################################################
# Security Group
###############################################################################

resource "aws_security_group" "asg" {
  name        = "${local.name_prefix}-sg"
  description = "Security group for ${local.name_prefix} ASG instances"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (SSM, license server, etc.)"
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Launch Template
###############################################################################

resource "aws_launch_template" "this" {
  name_prefix   = "${local.name_prefix}-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  vpc_security_group_ids = [aws_security_group.asg.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 enforced
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true # detailed monitoring for accurate CPU alarms
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = local.name_prefix })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.common_tags
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

###############################################################################
# Auto Scaling Group
###############################################################################

resource "aws_autoscaling_group" "this" {
  name                = local.name_prefix
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300

  # Lifecycle hook registered separately — required for graceful termination
  initial_lifecycle_hook {
    name                 = "${local.name_prefix}-termination-hook"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
    default_result       = var.lifecycle_default_result
    heartbeat_timeout    = var.heartbeat_timeout
    # notification_target_arn and role_arn not needed — EventBridge picks up
    # the lifecycle notification automatically via the autoscaling event bus
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    # Karpenter or external autoscaler controls desired_count at runtime
    ignore_changes = [desired_capacity]
  }
}

###############################################################################
# Scaling Policy — Target Tracking on CPU
###############################################################################

resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "${local.name_prefix}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = var.cpu_target_value
    disable_scale_in = false
  }
}

###############################################################################
# SNS — Ops notification topic
###############################################################################

resource "aws_sns_topic" "lifecycle_events" {
  name = "${local.name_prefix}-lifecycle-events"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.lifecycle_events.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

###############################################################################
# SQS — Dead Letter Queue for Lambda failures
###############################################################################

resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${local.name_prefix}-lambda-dlq"
  message_retention_seconds = 1209600 # 14 days
  tags                      = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${local.name_prefix}-lambda-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Lifecycle hook Lambda failed — instance may be stuck in Terminating:Wait. Investigate immediately."
  alarm_actions       = [aws_sns_topic.lifecycle_events.arn]
  ok_actions          = [aws_sns_topic.lifecycle_events.arn]

  dimensions = {
    QueueName = aws_sqs_queue.lambda_dlq.name
  }

  tags = local.common_tags
}

###############################################################################
# IAM — Lambda execution role
###############################################################################

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_permissions" {
  # CloudWatch Logs
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # SSM — run command on terminating instance
  statement {
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations"
    ]
    resources = ["*"]
  }

  # ASG — complete lifecycle action (CONTINUE or ABANDON)
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:CompleteLifecycleAction",
      "autoscaling:RecordLifecycleActionHeartbeat"
    ]
    resources = [aws_autoscaling_group.this.arn]
  }

  # SNS — publish termination notification
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.lifecycle_events.arn]
  }

  # SQS — write to DLQ on failure
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.lambda_dlq.arn]
  }

  # X-Ray tracing
  statement {
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name_prefix}-lifecycle-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${local.name_prefix}-lifecycle-lambda-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

###############################################################################
# Lambda — Lifecycle hook executor
###############################################################################

data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"
  source {
    content  = file("${path.module}/function/index.py")
    filename = "index.py"
  }
}

resource "aws_lambda_function" "lifecycle" {
  function_name    = "${local.name_prefix}-lifecycle-hook"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = var.lambda_timeout
  memory_size      = 256

  # Limit concurrency — prevents Lambda from being starved by other functions
  reserved_concurrent_executions = 10

  environment {
    variables = {
      ASG_NAME        = aws_autoscaling_group.this.name
      SNS_TOPIC_ARN   = aws_sns_topic.lifecycle_events.arn
      HOOK_NAME       = "${local.name_prefix}-termination-hook"
      DEFAULT_RESULT  = var.lifecycle_default_result
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  tracing_config {
    mode = "Active" # X-Ray on by default
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy.lambda]
}

# CloudWatch log group with retention — don't let logs accumulate forever
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${aws_lambda_function.lifecycle.function_name}"
  retention_in_days = 30
  tags              = local.common_tags
}

# Alarm on Lambda errors — separate from DLQ (catches sync errors too)
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name_prefix}-lifecycle-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Lifecycle hook Lambda is erroring. Check CloudWatch logs."
  alarm_actions       = [aws_sns_topic.lifecycle_events.arn]

  dimensions = {
    FunctionName = aws_lambda_function.lifecycle.function_name
  }

  tags = local.common_tags
}

###############################################################################
# EventBridge — Route ASG lifecycle events to Lambda
###############################################################################

resource "aws_cloudwatch_event_rule" "asg_terminating" {
  name        = "${local.name_prefix}-instance-terminating"
  description = "Capture EC2_INSTANCE_TERMINATING lifecycle hook events for ${local.name_prefix}"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance-terminate Lifecycle Action"]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.this.name]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.asg_terminating.name
  target_id = "LifecycleLambda"
  arn       = aws_lambda_function.lifecycle.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lifecycle.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.asg_terminating.arn
}
