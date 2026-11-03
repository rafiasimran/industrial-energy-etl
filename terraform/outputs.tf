output "raw_bucket" {
  description = "Upload your CSV here, under the raw/ prefix."
  value       = aws_s3_bucket.raw.bucket
}

output "curated_bucket" {
  value = aws_s3_bucket.curated.bucket
}

output "upload_command" {
  description = "Copy-paste this to kick off the pipeline."
  value       = "aws s3 cp raw_energy_readings.csv s3://${aws_s3_bucket.raw.bucket}/raw/raw_energy_readings.csv"
}

output "athena_database" {
  value = aws_glue_catalog_database.energy.name
}

output "athena_workgroup" {
  value = aws_athena_workgroup.energy.name
}

output "lambda_log_command" {
  description = "Watch the transform run in real time."
  value       = "aws logs tail /aws/lambda/${aws_lambda_function.transform.function_name} --follow"
}
