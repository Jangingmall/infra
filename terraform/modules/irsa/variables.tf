variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "name" {
  type = string
}

variable "namespace" {
  type = string
}

variable "service_account" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "policy_json" {
  type    = string
  default = null
}

variable "create_policy" {
  description = "커스텀 IAM 정책(aws_iam_policy.custom)을 생성할지 여부"
  type        = bool
  default     = true
}

variable "managed_policy_arns" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}