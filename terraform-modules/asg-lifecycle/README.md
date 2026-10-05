# Module: asg-lifecycle

Implements the **graceful EC2 termination pattern** for Auto Scaling Groups.

When an instance is selected for termination, this module intercepts the event via a lifecycle hook, runs a cleanup script on the instance (via SSM Run Command), and only allows termination to proceed after the script completes successfully.

Designed for workloads that hold vendor licenses, open persistent connections, or need to flush state before an instance disappears.

---

## Architecture

```
CloudWatch Alarm (CPU > threshold)
         │
         ▼
  ASG Scaling Policy triggers scale-in
         │
         ▼
  Lifecycle Hook: EC2_INSTANCE_TERMINATING
  → Instance enters "Terminating:Wait"
  → Held for up to heartbeat_timeout seconds
         │
         ▼
  EventBridge Rule
  (matches on ASG name — no false triggers)
         │
         ▼
  Lambda Function (Python 3.12)
  ├── Sends SSM Run Command to instance
  ├── Polls for completion (renews heartbeat every 2 min)
  ├── On success → complete-lifecycle-action CONTINUE
  └── On failure → complete-lifecycle-action ABANDON + SNS alert
         │
         ▼
  SNS Notification → email/ops channel
         │
         ▼
  Instance terminates (or stays in wait on ABANDON)
```

## Failure Modes Handled

| Failure | Behaviour |
|---------|-----------|
| Lambda timeout | Heartbeat renewed every 2 min; lifecycle ABANDON if Lambda runs out of time |
| SSM command fails (non-zero exit) | Lifecycle ABANDON, SNS alert with error output |
| SSM agent unreachable | Lifecycle ABANDON, SNS alert prompting direct license server call |
| Unexpected Lambda exception | Lifecycle ABANDON (always runs in `finally` block) |
| Lambda invocation failure (async) | DLQ captures failure, CloudWatch alarm fires |
| Lifecycle action completion fails | Critical SNS alert — manual intervention required |

---

## Usage

```hcl
module "asg_lifecycle" {
  source = "../../modules/asg-lifecycle"

  name             = "payments-service"
  vpc_id           = module.vpc.vpc_id
  subnet_ids       = module.vpc.private_subnet_ids
  ami_id           = data.aws_ami.hardened.id
  instance_type    = "t3.medium"
  min_size         = 2
  max_size         = 10
  desired_capacity = 3

  heartbeat_timeout        = 600   # 10 min
  lifecycle_default_result = "ABANDON"
  lambda_timeout           = 300   # 5 min — must be < heartbeat_timeout

  notification_email = "platform-ops@yourcompany.com"

  tags = {
    Environment = "prod"
    Service     = "payments"
  }
}
```

## Customising the Cleanup Script

Edit `function/index.py`, specifically the `LICENSE_DROP_COMMAND` string at the top of the file. Replace the placeholder with your actual vendor license release command.

For more complex scripts, upload the script to S3 and use the `AWS-RunRemoteScript` SSM document instead of `AWS-RunShellScript`.

---

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name` | `string` | required | Name prefix for all resources |
| `vpc_id` | `string` | required | VPC ID for instances |
| `subnet_ids` | `list(string)` | required | Private subnets (min 2 AZs) |
| `ami_id` | `string` | required | AMI with SSM agent pre-installed |
| `instance_type` | `string` | `t3.medium` | EC2 instance type |
| `min_size` | `number` | `1` | ASG minimum size |
| `max_size` | `number` | required | ASG maximum size |
| `desired_capacity` | `number` | required | ASG desired count (ignored at runtime) |
| `cpu_target_value` | `number` | `60` | Target CPU % for scaling policy |
| `heartbeat_timeout` | `number` | `600` | Lifecycle hook wait time in seconds |
| `lifecycle_default_result` | `string` | `ABANDON` | Action on timeout: CONTINUE or ABANDON |
| `lambda_timeout` | `number` | `300` | Lambda timeout in seconds |
| `notification_email` | `string` | `""` | Email for SNS alerts |
| `tags` | `map(string)` | `{}` | Resource tags |

## Outputs

| Name | Description |
|------|-------------|
| `asg_name` | Auto Scaling Group name |
| `asg_arn` | Auto Scaling Group ARN |
| `lambda_function_name` | Lifecycle Lambda function name |
| `sns_topic_arn` | SNS topic ARN for notifications |
| `dlq_url` | Dead Letter Queue URL — monitor this |
| `security_group_id` | Security group attached to instances |
