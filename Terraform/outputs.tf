output "bucket_name" {
  value = aws_s3_bucket.logs.bucket
}

output "role_arn" {
  value = aws_iam_role.lambda.arn
}