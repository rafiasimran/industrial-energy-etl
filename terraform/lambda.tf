# Terraform zips the source itself, so the deployed code can never drift
# from what is committed in git.
data "archive_file" "transform" {
  type        = "zip"
  source_file = "${path.module}/../lambda/transform.py"
  output_path = "${path.module}/build/transform.zip"
}

resource "aws_cloudwatch_log_group" "transform" {
  name              = "/aws/lambda/${local.name_prefix}-transform"
  retention_in_days = 14 # old logs cost money, so they expire
}

resource "aws_lambda_function" "transform" {
  function_name = "${local.name_prefix}-transform"
  role          = aws_iam_role.lambda.arn
  handler       = "transform.handler"
  runtime       = "python3.12"

  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256

  memory_size = var.lambda_memory_mb
  timeout     = var.lambda_timeout_seconds

  # pandas and pyarrow come from the AWS-managed layer instead of being
  # packaged with the function, which saves about 100 MB.
  layers = [var.awswrangler_layer_arn]

  environment {
    variables = {
      CURATED_BUCKET = aws_s3_bucket.curated.bucket
      CURATED_PREFIX = local.curated_prefix
      QUALITY_PREFIX = local.quality_prefix
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda,
    aws_cloudwatch_log_group.transform,
  ]
}

# S3 cannot invoke the function unless we explicitly allow it.
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transform.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw.arn
}
