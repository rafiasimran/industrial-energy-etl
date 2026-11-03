# Industrial Energy ETL Pipeline

[![CI](https://github.com/rafiasimran/industrial-energy-etl/actions/workflows/ci.yml/badge.svg)](https://github.com/rafiasimran/industrial-energy-etl/actions/workflows/ci.yml)

A serverless ETL pipeline on AWS, built with Terraform. It takes messy energy readings from factory machines, cleans and checks them, stores them as partitioned Parquet in S3 and makes them queryable with SQL in Athena.

I built this to learn AWS and Terraform properly, and deployed it in my own AWS account from CloudShell. Nothing was set up by clicking in the console: every bucket, role, function and table is in the Terraform code, so the whole thing can be created and destroyed with two commands.

## How it works

```
  raw_energy_readings.csv
           │  upload
           ▼
   ┌───────────────┐   S3 event    ┌──────────────────┐
   │  S3 raw       │ ────────────► │  Lambda          │
   │               │               │  transform.py    │
   └───────────────┘               │  (pandas)        │
                                   └────────┬─────────┘
                          ┌─────────────────┴──────────────┐
                          ▼                                ▼
               ┌─────────────────────┐        ┌────────────────────┐
               │ S3 curated          │        │ Quality report     │
               │ Parquet, by date    │        │ (JSON, every run)  │
               └──────────┬──────────┘        └────────────────────┘
                          ▼
               ┌─────────────────────┐
               │ Glue Data Catalog   │  schema defined in Terraform
               └──────────┬──────────┘
                          ▼
               ┌─────────────────────┐
               │ Athena (SQL)        │
               └─────────────────────┘
```

1. A CSV is uploaded to the raw bucket.
2. The upload triggers a Lambda function that cleans the data with pandas.
3. Clean rows are written to the curated bucket as Parquet, split into one folder per day.
4. A JSON quality report is saved for every run.
5. Athena queries the Parquet files through a table defined in the Glue Data Catalog.

## The data

The data is synthetic (`data/generate_raw_data.py`): 3 plants, 12 machines, 30 days. I made it messy on purpose, with the kind of problems a real export has:

| Problem | What would go wrong |
|---|---|
| Three timestamp formats in one column | Parsing only one format loses a big part of the rows |
| Some energy values in Wh, some in kWh | Totals would be off by 1000x for those rows |
| A batch of duplicate rows | Energy use counted twice |
| Missing voltage, temperature and energy values | Averages break if not handled |
| Negative energy and 999 °C temperatures | Sensor faults that shouldn't end up in averages |
| `running`, `RUNNING` and ` running ` | Three groups instead of one |

## Quality report

The transform doesn't just drop bad rows, it counts them. One run on the generated data:

```json
{
  "rows_in": 7416,
  "duplicates_removed": 216,
  "rows_converted_from_wh": 583,
  "impossible_values_rejected": 223,
  "rows_dropped_missing_critical": 137,
  "null_voltage": 296,
  "null_temperature": 186,
  "rows_out": 6840,
  "pass_rate_pct": 92.23
}
```

So 92.2% of rows pass, and the report says exactly why the rest didn't. The test suite checks these numbers.

## Design choices

- **Lambda instead of Glue jobs.** Glue jobs are billed per DPU-hour with no free tier. For this amount of data Lambda does the same work for almost nothing.
- **Partition projection instead of a Glue crawler.** Athena works out the partition folders from the date pattern, so there's no crawler to run or pay for, and the schema stays in the Terraform code.
- **Schema defined, not inferred.** If the schema were guessed from the data, one bad file could change a column type without anyone noticing.
- **Least-privilege IAM.** The Lambda can read the raw bucket, write the curated bucket and write logs. Nothing else.
- **Scan limit on the Athena workgroup.** Athena charges per byte scanned, so queries scanning more than 100 MB are refused.
- **Parquet in the curated zone.** It's columnar and compressed, so a query that needs two columns only reads those two.

## SQL

`sql/analysis.sql` has the Athena queries: daily energy per plant, a 7-day moving average, ranking machines within each plant, the hourly load profile, z-score anomaly detection per machine, the peak vs off-peak split, and idle machines that are still running hot. They use CTEs and window functions.

## Tests and CI

`tests/test_transform.py` checks each cleaning step on small hand-made examples, plus a full run on the generated data. GitHub Actions runs the tests and `terraform fmt`/`validate` on every push.

```bash
pip install -r requirements-dev.txt
pytest -q
```

## Deploying

Step by step in [docs/RUNBOOK.md](docs/RUNBOOK.md). Short version:

```bash
cd terraform
terraform init
terraform apply
python3 ../data/generate_raw_data.py
aws s3 cp raw_energy_readings.csv s3://$(terraform output -raw raw_bucket)/raw/
```

Then query in Athena, and remove everything with `terraform destroy`.

It stays within the AWS free tier at this size.

## Project structure

```
terraform/      S3, IAM, Lambda, Glue and Athena
lambda/         transform.py: cleaning, checks, quality report
data/           generator for the messy test data
sql/            Athena queries
tests/          pytest tests for the transform
docs/           deployment runbook
```

## Tech

AWS (S3, Lambda, Glue Data Catalog, Athena, IAM, CloudWatch) · Terraform · Python (pandas, AWS SDK for pandas) · Parquet · SQL · pytest · GitHub Actions

## Licence

MIT, see [LICENSE](LICENSE).
