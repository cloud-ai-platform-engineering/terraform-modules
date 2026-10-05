###############################################################################
# examples/asg-lifecycle-hook/main.tf
#
# Full working example: VPC + ASG with graceful termination lifecycle hook
# Run this to validate both modules work together end-to-end.
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Uncomment and configure for real deployments
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "examples/asg-lifecycle-hook/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Example     = "asg-lifecycle-hook"
      Repository  = "cloud-ai-platform-engineering/terraform-modules"
    }
  }
}

# Latest Amazon Linux 2023 with SSM agent pre-installed
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# VPC for the ASG
module "vpc" {
  source = "../../modules/vpc"

  name               = "${var.name}-example"
  vpc_cidr           = "10.10.0.0/16"
  availability_zones = var.availability_zones
  enable_nat_gateway = true
  environment        = "example"

  tags = {
    Purpose = "asg-lifecycle-example"
  }
}

# ASG with lifecycle hook
module "asg_lifecycle" {
  source = "../../modules/asg-lifecycle"

  name             = "${var.name}-app"
  vpc_id           = module.vpc.vpc_id
  subnet_ids       = module.vpc.private_subnet_ids
  ami_id           = data.aws_ami.amazon_linux.id
  instance_type    = "t3.micro" # smallest for example cost
  min_size         = 1
  max_size         = 3
  desired_capacity = 1

  # Lifecycle hook — generous timeout for demo
  heartbeat_timeout        = 300
  lifecycle_default_result = "ABANDON"
  lambda_timeout           = 120

  notification_email = var.notification_email

  tags = {
    Environment = "example"
  }
}
