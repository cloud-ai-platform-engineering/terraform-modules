###############################################################################
# modules/asg-lifecycle/variables.tf
###############################################################################

variable "name" {
  type        = string
  description = "Name prefix for all resources in this module"
  validation {
    condition     = length(var.name) <= 32 && can(regex("^[a-z0-9-]+$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, max 32 chars."
  }
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where ASG instances will be launched"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for ASG instances — must be in at least 2 AZs for HA"
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least 2 subnets in different AZs required for high availability."
  }
}

variable "ami_id" {
  type        = string
  description = "AMI ID for EC2 instances — use a hardened, SSM-agent-enabled image"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type"
  default     = "t3.medium"
}

variable "min_size" {
  type        = number
  description = "Minimum number of instances in the ASG"
  default     = 1
  validation {
    condition     = var.min_size >= 1
    error_message = "Minimum size must be at least 1."
  }
}

variable "max_size" {
  type        = number
  description = "Maximum number of instances in the ASG"
}

variable "desired_capacity" {
  type        = number
  description = "Desired number of instances — ignored at runtime if autoscaling is active"
}

variable "cpu_target_value" {
  type        = number
  description = "Target CPU utilization percentage for target tracking scaling policy"
  default     = 60
  validation {
    condition     = var.cpu_target_value > 0 && var.cpu_target_value < 100
    error_message = "CPU target must be between 1 and 99."
  }
}

# ---- Lifecycle Hook ----

variable "heartbeat_timeout" {
  type        = number
  description = <<-EOT
    Seconds the lifecycle hook will wait for Lambda to call complete-lifecycle-action.
    Set this to at least 2x your Lambda timeout to allow for retries and SSM latency.
    Maximum: 172800 (48 hours). Recommended: 600 (10 minutes).
  EOT
  default     = 600
  validation {
    condition     = var.heartbeat_timeout >= 30 && var.heartbeat_timeout <= 172800
    error_message = "Heartbeat timeout must be between 30 and 172800 seconds."
  }
}

variable "lifecycle_default_result" {
  type        = string
  description = <<-EOT
    Action if heartbeat timeout expires before Lambda completes:
    - ABANDON: Instance stays in Terminating:Wait — ops team investigates. Safest for license-critical workloads.
    - CONTINUE: Instance terminates anyway — use only if vendor license can be recovered externally.
  EOT
  default     = "ABANDON"
  validation {
    condition     = contains(["CONTINUE", "ABANDON"], var.lifecycle_default_result)
    error_message = "lifecycle_default_result must be either CONTINUE or ABANDON."
  }
}

variable "lambda_timeout" {
  type        = number
  description = "Lambda function timeout in seconds. Must be less than heartbeat_timeout."
  default     = 300
  validation {
    condition     = var.lambda_timeout >= 10 && var.lambda_timeout <= 900
    error_message = "Lambda timeout must be between 10 and 900 seconds."
  }
}

# ---- Notifications ----

variable "notification_email" {
  type        = string
  description = "Email address for SNS lifecycle event notifications. Leave empty to skip email subscription."
  default     = ""
}

# ---- Tagging ----

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources. Merged with module-level tags."
  default     = {}
}
