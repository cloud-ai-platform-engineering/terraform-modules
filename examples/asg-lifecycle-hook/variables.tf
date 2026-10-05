variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "name" {
  type    = string
  default = "lifecycle-demo"
}

variable "availability_zones" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b"]
}

variable "notification_email" {
  type    = string
  default = ""
  description = "Set this to receive SNS alerts during the demo"
}
