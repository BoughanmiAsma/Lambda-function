terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region     = var.region
  access_key = "test"
  secret_key = "test"

  # Floci is not real AWS, so skip the checks that need real AWS
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3         = var.endpoint
    iam        = var.endpoint
    sts        = var.endpoint
    lambda     = var.endpoint
    cloudwatchlogs = var.endpoint
  }
}