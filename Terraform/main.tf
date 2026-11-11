# S3 bucket: the event source
resource "aws_s3_bucket" "logs" {
  bucket        = var.bucket_name
  force_destroy = true # lets "terraform destroy" delete it even if it has files
}

# IAM role that the Lambda will assume
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

# Permissions: write logs + read from our bucket
data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.logs.arn}/*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "lambda-log-parser-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}




# Zip the Lambda code automatically
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file  = "${path.module}/../lambda_script.py"
  output_path = "${path.module}/lambda.zip"
}

#  Log group (the "dashboard" where execution records appear)
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 7
}

# The Lambda function
resource "aws_lambda_function" "parser" {
  function_name    = var.function_name
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "lambda_script.lambda_handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      LOG_LEVEL       = "INFO"
      S3_ENDPOINT_URL = "http://floci-floci-1:4566"
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# Allow S3 to invoke the function
resource "aws_lambda_permission" "s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.parser.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.logs.arn
}

#The trigger: S3 upload -> Lambda
resource "aws_s3_bucket_notification" "trigger" {
  bucket = aws_s3_bucket.logs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.parser.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".log"
  }

  depends_on = [aws_lambda_permission.s3]
}