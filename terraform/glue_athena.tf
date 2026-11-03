resource "aws_glue_catalog_database" "energy" {
  name        = replace("${local.name_prefix}_db", "-", "_")
  description = "Catalog for cleaned industrial energy readings"
}

# The table is defined here instead of running a Glue crawler.
# A crawler costs money per run and keeps the schema out of git.
resource "aws_glue_catalog_table" "readings" {
  name          = "energy_readings"
  database_name = aws_glue_catalog_database.energy.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"      = "parquet"
    "parquet.compression" = "SNAPPY"
    "EXTERNAL"            = "TRUE"

    # --- Partition projection ---
    # Without this you would have to run MSCK REPAIR TABLE after every load,
    # or pay a crawler to rediscover partitions. Projection tells Athena to
    # calculate the partition paths instead of looking them up. No extra cost
    # and no waiting.
    "projection.enabled"                    = "true"
    "projection.reading_date.type"          = "date"
    "projection.reading_date.format"        = "yyyy-MM-dd"
    "projection.reading_date.range"         = "${var.partition_range_start},NOW"
    "projection.reading_date.interval"      = "1"
    "projection.reading_date.interval.unit" = "DAYS"
    "storage.location.template"             = "${local.curated_s3_path}/reading_date=$${reading_date}"
  }

  partition_keys {
    name = "reading_date"
    type = "string"
  }

  storage_descriptor {
    location      = local.curated_s3_path
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet-serde"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters            = { "serialization.format" = "1" }
    }

    columns {
      name = "reading_id"
      type = "string"
    }

    columns {
      name = "machine_id"
      type = "string"
    }

    columns {
      name = "plant"
      type = "string"
    }

    columns {
      name = "reading_ts"
      type = "timestamp"
    }

    columns {
      name = "energy_kwh"
      type = "double"
    }

    columns {
      name = "voltage_v"
      type = "double"
    }

    columns {
      name = "temperature_c"
      type = "double"
    }

    columns {
      name = "status"
      type = "string"
    }

    columns {
      name = "reading_hour"
      type = "int"
    }

    columns {
      name = "is_peak_hour"
      type = "boolean"
    }
  }
}

resource "aws_athena_workgroup" "energy" {
  name = local.name_prefix

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    # Refuse any query that would scan more than 100 MB.
    # Athena bills per byte scanned.
    bytes_scanned_cutoff_per_query = 104857600
  }

  force_destroy = true
}
