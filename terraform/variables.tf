variable "region" {
  default = "us-west-2"
}

variable "instance_type" {
  default = "t3.micro"
}

variable "sns_email" {
  description = "Email address for alarm notifications"
  type        = string
}

variable "project" {
  default = "obs-demo"
}
