# Runbook: deploying from AWS CloudShell

I deployed this from AWS CloudShell, which runs in the browser, so nothing has
to be installed locally. Region: Frankfurt (`eu-central-1`).

## 0. Set a budget alarm first

1. AWS Console → **Billing and Cost Management** → **Budgets** → **Create budget**
2. Pick **Zero spend budget** (or a cost budget of €5)
3. Enter your email and create it

That way you get an email if anything starts costing money.

## 1. Open CloudShell in the right region

Set the region (top right) to **Europe (Frankfurt) eu-central-1**, then open
CloudShell (the `>_` icon). Check:

```bash
aws sts get-caller-identity
echo $AWS_REGION      # should print eu-central-1
```

S3 buckets, Lambda functions and the Glue catalog are regional. If the console
is set to a different region later, the resources look like they've disappeared.

## 2. Install Terraform

CloudShell doesn't include Terraform, and only the home folder survives between
sessions, so install it there:

```bash
mkdir -p ~/bin && cd ~
curl -sLo tf.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
unzip -o tf.zip -d ~/bin && rm tf.zip
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
export PATH=$HOME/bin:$PATH
terraform -version
```

## 3. Get the code

```bash
git clone https://github.com/rafiasimran/industrial-energy-etl.git
cd industrial-energy-etl
```

## 4. Look up the pandas layer

The Lambda needs pandas and pyarrow. Instead of packaging them (around 100 MB),
it uses the AWS-managed "AWS SDK for pandas" layer. The version number changes
over time, so look up the current one:

```bash
aws lambda list-layer-versions \
  --layer-name arn:aws:lambda:eu-central-1:336392948345:layer:AWSSDKPandas-Python312 \
  --region eu-central-1 \
  --query 'LayerVersions[0].LayerVersionArn' --output text
```

Put the ARN it prints into `terraform.tfvars`:

```bash
cd terraform
cp example.tfvars terraform.tfvars
nano terraform.tfvars
```

## 5. Deploy

```bash
terraform init
terraform plan      # read this: it lists everything that will be created
terraform apply     # type yes
```

It creates about 20 resources and takes around a minute.

## 6. Run the pipeline

```bash
cd ..
python3 data/generate_raw_data.py
aws s3 cp raw_energy_readings.csv \
  s3://$(cd terraform && terraform output -raw raw_bucket)/raw/raw_energy_readings.csv
```

The upload triggers the Lambda. To watch it:

```bash
cd terraform
$(terraform output -raw lambda_log_command)
```

The quality report is printed as JSON at the end (Ctrl+C to stop following).
Check the Parquet output:

```bash
aws s3 ls s3://$(terraform output -raw curated_bucket)/readings/ --recursive | head
```

You should see folders like `reading_date=2026-06-01/`. Those are the partitions.

## 7. Query in Athena

1. Athena console → set the **workgroup** to `terraform output athena_workgroup`
2. Set the **database** to `terraform output athena_database`
3. Run the queries in `sql/analysis.sql` one at a time, starting with query 0

Query results can be downloaded as CSV for a BI tool like Power BI, or connected
live with the Amazon Athena ODBC driver.

## 8. Tear it down

```bash
cd terraform
terraform destroy   # type yes
aws s3 ls           # check nothing is left
```

Everything can be rebuilt any time with `terraform apply`.

Never commit `*.tfstate` or `terraform.tfvars`. Both are in `.gitignore`.

## Troubleshooting

**`BucketAlreadyExists`**: bucket names are global. Run `terraform apply` again
and a new random suffix is generated.

**Lambda fails with `Unable to import module`**: the layer ARN is wrong or for a
different Python version. Redo step 4 and check it ends in `Python312`, matching
the runtime in `lambda.tf`.

**`AccessDenied` when the Lambda writes to S3**: IAM changes take a few seconds
to apply. Wait 30 seconds and upload the CSV again.

**Athena: `Table not found`**: wrong database or workgroup selected. Both come
from `terraform output`.

**Athena returns no rows but the Parquet files exist**: check that
`partition_range_start` in `variables.tf` is earlier than the data (June 2026).

**`terraform: command not found` in a new CloudShell session**: run
`export PATH=$HOME/bin:$PATH` again.
