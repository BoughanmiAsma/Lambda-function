# Event-Driven Serverless Compute Application Engine

A serverless log-parsing routine built with **AWS Lambda (Python)**, triggered automatically by **S3 upload events**, and deployed with **Terraform** on **Floci** (a local AWS simulator running in Docker). Execution records are written to **CloudWatch Logs**.

## 1. Objective

Program an automated serverless routine that reacts asynchronously to system events.

| Task requirement | How it is met |
|---|---|
| Isolated backend compute function (AWS Lambda) | Python function with its own IAM role, environment variables and zip package |
| System event hook that triggers the function | S3 event notification `s3:ObjectCreated:*` (filter: `.log`) |
| Real-time text log parsing | The function downloads the uploaded file and extracts levels, services and errors |
| Execution records in cloud logging dashboards | Output goes to the CloudWatch Logs group `/aws/lambda/log-parser-function` |

## 2. Architecture

```
 Upload .log file
        |
        v
 +---------------+   s3:ObjectCreated:*   +-------------------+
 |  S3 bucket    | ---------------------> |  Lambda function  |
 | log-uploads-  |   (event notification) |  log-parser-      |
 | bucket        | <--------------------- |  function         |
 +---------------+      GetObject         +---------+---------+
                                                    |
                                                    v
                                         +---------------------+
                                         |  CloudWatch Logs    |
                                         | /aws/lambda/log-    |
                                         | parser-function     |
                                         +---------------------+
```

Everything runs locally on Floci (`http://127.0.0.1:4566`), with the same APIs as real AWS.

## 3. What the function does

For every uploaded `.log` / `.txt` file, the function:

1. Reads the bucket name and object key from the S3 event
2. Downloads the file (with a 5 MB safety limit)
3. Parses each line with a regular expression
4. Counts lines by **level** (DEBUG, INFO, WARNING, ERROR, CRITICAL) and by **service**
5. Collects the first 10 ERROR / CRITICAL entries
6. Writes a summary to CloudWatch Logs

### Expected log line format

```
2026-11-09 10:15:32 ERROR [auth] Invalid password for user bob
<timestamp>         <level> [<service>] <message>
```

Lines that do not match this format are counted as `lines_unparsed`.

### Sample result (for the provided mock log)

```json
{
  "lines_parsed": 8,
  "lines_unparsed": 1,
  "levels": { "INFO": 3, "WARNING": 1, "ERROR": 2, "DEBUG": 1, "CRITICAL": 1 },
  "services": { "auth": 2, "api": 3, "db": 1, "cache": 1, "payment": 1 },
  "error_count": 3
}
```

## 4. Project structure

> Adjust the names below if your files are named differently.

```
task-3-lambda-function/
├── .env                          # dummy credentials + Floci endpoint
├── load-env.ps1                  # loads .env into the PowerShell session
├── lambda_script.py              # Lambda function code (handler)
├── lambda_script_testLocal.py    # local test of the parsing logic (not deployed)
├── mock-logs.log                 # sample log file used for testing
└── terraform/
    ├── providers.tf              # AWS provider pointed at Floci
    ├── variables.tf              # region, endpoint, names
    ├── main.tf                   # bucket, IAM role, Lambda, permission, trigger, log group
    └── outputs.tf                # bucket name and role ARN
```

## 5. Prerequisites

- Docker, with the Floci container running and healthy on port `4566`
- Terraform >= 1.5
- Python 3.12 (for the local test) and `boto3` (`pip install boto3`)
- AWS CLI (v1 works)
- PowerShell (Windows)

## 6. Setup

### 6.1 Environment file (`.env`)

```
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_DEFAULT_REGION=us-east-1
AWS_ENDPOINT_URL=http://127.0.0.1:4566
```

These are dummy values: Floci does not validate credentials. Use `127.0.0.1` instead of `localhost` to avoid IPv6 resolution problems on Windows.

### 6.2 Loader (`load-env.ps1`)

```powershell
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([^#=\s]+)\s*=\s*(.*)\s*$') {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
    }
}
Write-Host "Environment loaded from .env"
```

Run it in every new terminal:

```powershell
. .\load-env.ps1
```

### 6.3 Check that Floci responds

```powershell
curl.exe http://127.0.0.1:4566
aws s3 ls
aws lambda list-functions
aws logs describe-log-groups
```

## 7. Test the parsing logic locally (no Floci needed)

```powershell
python lambda_script_testLocal.py
```

Expected: `lines_parsed: 8`, `lines_unparsed: 1`, `error_count: 3`.

## 8. Deploy with Terraform

```powershell
cd terraform
terraform init -upgrade
terraform plan
terraform apply
```

Resources created:

| Resource | Purpose |
|---|---|
| `aws_s3_bucket.logs` | Event source (`log-uploads-bucket`) |
| `aws_iam_role.lambda` + `aws_iam_role_policy.lambda` | Isolated role: write logs, read only from this bucket |
| `aws_cloudwatch_log_group.lambda` | Log group `/aws/lambda/log-parser-function` |
| `aws_lambda_function.parser` | The function (Python 3.12, 30 s timeout) |
| `aws_lambda_permission.s3` | Allows S3 (and only this bucket) to invoke the function |
| `aws_s3_bucket_notification.trigger` | The trigger: `ObjectCreated` on `*.log` |

### Key configuration notes

- **Handler**: `lambda_script.lambda_handler` = file name without `.py` + function name.
- **`S3_ENDPOINT_URL`**: set to the Floci container name (`http://floci-floci-1:4566`). Inside the Lambda runtime container, `127.0.0.1` points to the container itself, not to Floci.
- **Permission vs notification**: the permission says S3 *may* invoke the function; the notification tells S3 *when* to do it. Both are required.

## 9. Run the end-to-end test

```powershell
cd ..
aws s3 cp .\mock-logs.log s3://log-uploads-bucket/mock-logs.log
Start-Sleep -Seconds 15
aws logs filter-log-events --log-group-name /aws/lambda/log-parser-function --query "events[].message" --output text
```

The Floci UI shows the same events: **CloudWatch Logs > `/aws/lambda/log-parser-function` > Streams & Events**.

### Expected log output

```
Function invoked, request id: ...
New object detected: s3://log-uploads-bucket/mock-logs.log (... bytes)
Parsing summary for mock-logs.log: {"lines_parsed": 8, "lines_unparsed": 1, ... "error_count": 3, ...}
mock-logs.log contains 3 error(s)
Done: 1 record(s) handled
```

### Direct invocation (tests the function without S3)

```powershell
aws lambda invoke --function-name log-parser-function --payload '{"Records":[]}' --cli-binary-format raw-in-base64-out out.json
type out.json
```

Expected: `StatusCode: 200` and `Done: 0 record(s) handled` in the logs.

> With the S3 trigger the call is asynchronous, so the return value is discarded. **The logs are the output.**

## 10. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `aws` hangs or `Connection was closed` / `Empty reply from server` | Floci overloaded or stuck. Stop the UI container, run `docker-compose down` then `docker-compose up -d` from the Floci folder, then retest `curl.exe http://127.0.0.1:4566`. |
| CLI still uses `localhost` | The variable was not loaded in this terminal. Run `. .\load-env.ps1`. |
| `Inconsistent dependency lock file` | A provider was added. Run `terraform init -upgrade`. |
| `Runtime.ImportModuleError` | `handler` value does not match the Python file name. |
| Function does not run after upload | The key must end in `.log` (trigger filter). Wait 15-30 s on the first run. |
| Connection error to S3 inside the function | Check `S3_ENDPOINT_URL` points to the Floci container name. |
| `No module named 'boto3'` locally | `pip install boto3` |

## 11. Cleanup

```powershell
cd terraform
terraform destroy
```

`force_destroy = true` on the bucket lets Terraform delete it even if it contains files.

## 12. Design decisions

- **Standard library only** (plus `boto3`, included in the Lambda runtime): no layers or dependency packaging.
- **Least privilege**: the role can only write logs and read objects from this one bucket; the invoke permission is restricted to this bucket's ARN.
- **Safety checks**: files that are not `.log` / `.txt`, or larger than 5 MB, are skipped with a warning.
- **Error handling**: exceptions are logged with a stack trace and re-raised so Lambda marks the invocation as failed.
- **Infrastructure as code**: the whole environment is reproducible with `terraform apply`.

## 13. Evidence for the deliverable

Screenshots to include:

1. `terraform apply` output (`Apply complete!`)
2. `aws s3 cp` upload of the log file
3. CloudWatch Logs stream showing the parsing summary and `contains 3 error(s)`