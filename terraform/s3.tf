# Bucket names are globally unique across every AWS account on earth,
# so a random suffix is added to avoid name clashes.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix     = "${var.project_name}-${random_id.suffix.hex}"
  curated_prefix  = "readings"
  quality_prefix  = "quality-reports"
  curated_s3_path = "s3://${aws_s3_bucket.curated.bucket}/${local.curated_prefix}"
}

# ---------- RAW ZONE: exactly what the source system sent us ----------
resource "aws_s3_bucket" "raw" {
  bucket        = "${local.name_prefix}-raw"
  force_destroy = true # demo project: let destroy clean up fully
}

# ---------- CURATED ZONE: cleaned, typed, partitioned Parquet ----------
resource "aws_s3_bucket" "curated" {
  bucket        = "${local.name_prefix}-curated"
  force_destroy = true
}

# ---------- ATHENA QUERY RESULTS ----------
resource "aws_s3_bucket" "athena_results" {
  bucket        = "${local.name_prefix}-athena-results"
  force_destroy = true
}

# Block public access on all three buckets.
resource "aws_s3_bucket_public_access_block" "all" {
  for_each = {
    raw     = aws_s3_bucket.raw.id
    curated = aws_s3_bucket.curated.id
    athena  = aws_s3_bucket.athena_results.id
  }

  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encryption at rest.
resource "aws_s3_bucket_server_side_encryption_configuration" "all" {
  for_each = {
    raw     = aws_s3_bucket.raw.id
    curated = aws_s3_bucket.curated.id
    athena  = aws_s3_bucket.athena_results.id
  }

  bucket = each.value

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Athena results are disposable. Delete them after a week so they cost nothing.
resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-query-results"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }
  }
}

# The trigger: any CSV landing under raw/ invokes the transform Lambda.
resource "aws_s3_bucket_notification" "raw_to_lambda" {
  bucket = aws_s3_bucket.raw.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.transform.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
