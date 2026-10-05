# terraform-modules

Production-grade, reusable Terraform modules for AWS platform infrastructure.
Built for real-world product engineering teams — opinionated defaults, explicit security posture, and designed to be composed across environments.

---

## Modules

| Module | Status | Description | Key Features |
|--------|--------|-------------|--------------|
| [`asg-lifecycle`](./modules/asg-lifecycle/) | ✅ Available | ASG with graceful termination lifecycle hooks | EventBridge → Lambda → SSM, DLQ, SNS notification, heartbeat handling |
| [`vpc`](./modules/vpc/) | 🚧 In Progress | Multi-AZ VPC with public/private subnets | Conditional NAT Gateway, EKS-ready subnet tags, VPC Flow Logs |
| [`security-group`](./modules/security-group/) | 🚧 In Progress | Dynamic security group with declarative rules | Dynamic ingress/egress blocks, description enforcement |
| [`eks`](./modules/eks/) | 🚧 In Progress | EKS cluster with managed node groups | IRSA, Karpenter-ready, cluster add-ons, OIDC provider |
| [`lambda`](./modules/lambda/) | 🚧 In Progress | Lambda with production reliability defaults | DLQ, X-Ray, reserved concurrency, Secrets Manager integration |

---

## Architecture — ASG Lifecycle Hook Pattern

This repo includes a full implementation of the **graceful termination pattern** for EC2 instances in an ASG — a common production requirement when instances hold vendor licenses, open database connections, or need to drain in-flight requests before termination.

```
CloudWatch Alarm (CPU metric)
        │
        ▼
   ASG Scale-Down Triggered
        │
        ▼
Lifecycle Hook: autoscaling:EC2_INSTANCE_TERMINATING
→ Instance enters "Terminating:Wait" (held, not yet terminated)
        │
        ▼
   EventBridge Rule
(matches on ASG name — no false triggers from other ASGs)
        │
        ▼
   Lambda Function (Python 3.12)
→ Sends SSM Run Command to terminating EC2
→ Executes vendor license drop script on the instance
→ Renews lifecycle heartbeat every 2 min while waiting
→ Calls complete-lifecycle-action: CONTINUE (success) or ABANDON (failure)
        │
        ▼
   SNS Notification
→ Ops team notified of event outcome (success or failure)
        │
        ▼
   Instance Terminates (or stays in Terminating:Wait on ABANDON)
```

**Failure handling:** If Lambda times out or SSM is unreachable, the hook defaults to `ABANDON` — instance stays in wait state and on-call is paged via DLQ alarm. No silent failures.

| Failure Scenario | Behaviour |
|-----------------|-----------|
| Lambda times out | Heartbeat renewed every 2 min; ABANDON if Lambda exhausted |
| SSM command fails (non-zero exit) | ABANDON + SNS alert with error output |
| SSM agent unreachable on instance | ABANDON + SNS alert prompting direct license server call |
| Unexpected Lambda exception | ABANDON (always runs in `finally` block) |
| Lambda invocation failure (async) | DLQ captures it, CloudWatch alarm fires within 1 minute |

---

## Usage

### ASG with Lifecycle Hook

```hcl
module "asg_lifecycle" {
  source = "./modules/asg-lifecycle"

  name             = "payments-app"
  vpc_id           = module.vpc.vpc_id
  subnet_ids       = module.vpc.private_subnet_ids
  ami_id           = data.aws_ami.amazon_linux.id
  instance_type    = "t3.medium"
  min_size         = 2
  max_size         = 10
  desired_capacity = 3

  # Lifecycle hook — set heartbeat generously above lambda_timeout
  heartbeat_timeout        = 600   # 10 minutes
  lifecycle_default_result = "ABANDON"  # safe default: hold instance if Lambda fails
  lambda_timeout           = 300   # 5 minutes

  notification_email = "platform-ops@yourcompany.com"

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
    Service     = "payments"
  }
}
```

---

## Repository Structure

```
terraform-modules/
├── modules/
│   ├── asg-lifecycle/          # ✅ ASG + lifecycle hook + EventBridge + Lambda + SNS
│   ├── vpc/                    # 🚧 VPC, subnets, NAT Gateway, route tables
│   ├── security-group/         # 🚧 Dynamic SG with declarative ingress/egress rules
│   ├── eks/                    # 🚧 EKS cluster + managed node groups + IRSA + Karpenter
│   └── lambda/                 # 🚧 Lambda with DLQ, X-Ray, reserved concurrency
└── examples/
    └── asg-lifecycle-hook/     # ✅ Full working example: VPC + ASG graceful termination
```

---

## Design Principles

- **`for_each` over `count`** — all multi-instance resources use map-based addressing to prevent index-shift destruction on list element removal
- **`prevent_destroy` on critical resources** — VPCs, RDS clusters, S3 state buckets are guarded against accidental deletion
- **Explicit lifecycle rules** — every module documents what it owns and what it deliberately defers to external systems (e.g., EKS node desired count deferred to Karpenter)
- **No plaintext secrets** — all sensitive values sourced from Secrets Manager or SSM Parameter Store, never in `.tfvars` or environment variables directly
- **Default tags via provider** — cost allocation tags enforced at the AWS provider block so no resource can be created without them
- **DLQ on every async Lambda** — no silent failures; every Lambda invocation failure is captured and alarmed within 60 seconds
- **ABANDON as lifecycle default** — instances never terminate silently on hook failure; ops team investigates before proceeding

---

## Requirements

| Tool | Version |
|------|---------|
| Terraform | >= 1.5.0 |
| AWS Provider | >= 5.0 |
| AWS CLI | >= 2.0 |
| Python | 3.12 (Lambda runtime) |

---

## Author

Platform Engineering · [cloud-ai-platform-engineering](https://github.com/cloud-ai-platform-engineering)