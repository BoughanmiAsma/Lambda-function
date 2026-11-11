variable "region" {
  type    = string
  default = "us-east-1"
}

variable "endpoint" {
  type    = string
  default = "http://127.0.0.1:4566"
}

variable "bucket_name" {
  type    = string
  default = "log-uploads-bucket"
}

variable "role_name" {
  type    = string
  default = "lambda-log-parser-role"
}

variable "function_name" {
  type    = string
  default = "log-parser-function"
}