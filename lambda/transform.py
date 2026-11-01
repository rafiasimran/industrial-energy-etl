"""
The transform step.

Runs when a CSV lands in the raw S3 bucket. Cleans the data, writes it to the
curated bucket as partitioned Parquet, and saves a data quality report next to
it so every run records what was rejected and why.
"""
import json
import os
import urllib.parse
from datetime import datetime, timezone

import pandas as pd

VALID_STATUSES = {"running", "idle", "maintenance"}
MAX_PLAUSIBLE_TEMP_C = 200.0
MAX_PLAUSIBLE_KWH = 500.0
TIMESTAMP_FORMATS = ("%Y-%m-%d %H:%M:%S", "%d/%m/%Y %H:%M", "%Y-%m-%dT%H:%M:%S")


def parse_timestamp(value):
    """The source system emits three different formats. Try each in turn."""
    if pd.isna(value):
        return pd.NaT
    text = str(value).strip()
    for fmt in TIMESTAMP_FORMATS:
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return pd.NaT


def transform(df: pd.DataFrame):
    quality = {"rows_in": int(len(df))}

    # 1. Deduplicate. A re-ingested batch must not double-count energy.
    before = len(df)
    df = df.drop_duplicates(subset=["reading_id"], keep="first").copy()
    quality["duplicates_removed"] = before - len(df)

    # 2. Normalise text before anything groups on it.
    for col in ("status", "plant", "machine_id", "energy_unit"):
        df[col] = df[col].astype(str).str.strip().str.lower()
    df["plant"] = df["plant"].str.title()
    df["machine_id"] = df["machine_id"].str.upper()

    # 3. Coerce numerics so bad strings become NaN instead of crashing.
    for col in ("energy", "voltage_v", "temperature_c"):
        df[col] = pd.to_numeric(df[col], errors="coerce")

    # 4. Harmonise units. Wh and kWh in one column is a silent 1000x error.
    is_wh = df["energy_unit"] == "wh"
    df["energy_kwh"] = df["energy"].where(~is_wh, df["energy"] / 1000)
    quality["rows_converted_from_wh"] = int(is_wh.sum())

    # 5. Timestamps.
    df["reading_ts"] = df["timestamp"].apply(parse_timestamp)
    quality["unparseable_timestamps"] = int(df["reading_ts"].isna().sum())

    # 6. Reject physically impossible readings, but count them first.
    impossible = (
        (df["energy_kwh"] < 0)
        | (df["energy_kwh"] > MAX_PLAUSIBLE_KWH)
        | (df["temperature_c"] > MAX_PLAUSIBLE_TEMP_C)
    ).fillna(False)
    quality["impossible_values_rejected"] = int(impossible.sum())
    df = df[~impossible]

    # 7. Rows with no usable energy value or timestamp cannot be analysed.
    before = len(df)
    df = df.dropna(subset=["energy_kwh", "reading_ts"])
    quality["rows_dropped_missing_critical"] = before - len(df)

    # 8. Nulls in non-critical fields are reported, not dropped.
    quality["null_voltage"] = int(df["voltage_v"].isna().sum())
    quality["null_temperature"] = int(df["temperature_c"].isna().sum())

    # 9. Unexpected status values get flagged rather than silently accepted.
    quality["unknown_status_values"] = sorted(set(df["status"].unique()) - VALID_STATUSES)

    # 10. Derived columns the analysts will ask for anyway.
    df["reading_hour"] = df["reading_ts"].dt.hour.astype("int32")
    df["is_peak_hour"] = df["reading_hour"].between(6, 21)
    df["reading_date"] = df["reading_ts"].dt.strftime("%Y-%m-%d")
    df["energy_kwh"] = df["energy_kwh"].round(3)

    out = df[[
        "reading_id", "machine_id", "plant", "reading_ts",
        "energy_kwh", "voltage_v", "temperature_c", "status",
        "reading_hour", "is_peak_hour", "reading_date",
    ]]

    quality["rows_out"] = int(len(out))
    quality["pass_rate_pct"] = round(100 * len(out) / max(quality["rows_in"], 1), 2)
    return out, quality


def handler(event, context):
    # AWS-only imports live here so transform() can be tested without AWS.
    import awswrangler as wr
    import boto3

    curated_bucket = os.environ["CURATED_BUCKET"]
    curated_prefix = os.environ.get("CURATED_PREFIX", "readings")
    quality_prefix = os.environ.get("QUALITY_PREFIX", "quality-reports")

    record = event["Records"][0]["s3"]
    bucket = record["bucket"]["name"]
    key = urllib.parse.unquote_plus(record["object"]["key"])
    source = f"s3://{bucket}/{key}"
    print(f"Reading {source}")

    df = wr.s3.read_csv(source, dtype=str)
    clean, quality = transform(df)

    wr.s3.to_parquet(
        df=clean,
        path=f"s3://{curated_bucket}/{curated_prefix}/",
        dataset=True,
        partition_cols=["reading_date"],
        mode="overwrite_partitions",
        compression="snappy",
    )

    quality["source_file"] = source
    quality["processed_at_utc"] = datetime.now(timezone.utc).isoformat()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    boto3.client("s3").put_object(
        Bucket=curated_bucket,
        Key=f"{quality_prefix}/quality_{stamp}.json",
        Body=json.dumps(quality, indent=2).encode("utf-8"),
        ContentType="application/json",
    )

    print(json.dumps(quality, indent=2))
    return {"status": "ok", "quality": quality}
