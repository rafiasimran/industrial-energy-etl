variable "region" {
  description = "AWS region. Frankfurt keeps the data in the EU."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Prefix for every resource name, so nothing collides."
  type        = string
  default     = "industrial-energy-etl"
}

variable "awswrangler_layer_arn" {
  description = <<-EOT
    ARN of the AWS-managed "AWS SDK for pandas" Lambda layer.
    Layer versions change over time. Get the current one with:

      aws lambda list-layer-versions \
        --layer-name arn:aws:lambda:eu-central-1:336392948345:layer:AWSSDKPandas-Python312 \
        --region eu-central-1 \
        --query 'LayerVersions[0].LayerVersionArn' --output text
  EOT
  type        = string
}

variable "lambda_memory_mb" {
  description = "Lambda CPU scales with memory, so 1024 MB finishes faster than 512 MB."
  type        = number
  default     = 1024
}

variable "lambda_timeout_seconds" {
  type    = number
  default = 300
}

variable "partition_range_start" {
  description = "Earliest date Athena partition projection will look for."
  type        = string
  default     = "2026-01-01"
}
