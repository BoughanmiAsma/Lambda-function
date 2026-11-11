import json
import logging
import os
import re
import urllib.parse

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# Optional: lets the function reach Floci. Empty on real AWS.
S3_ENDPOINT_URL = os.environ.get("S3_ENDPOINT_URL") or None
MAX_BYTES = int(os.environ.get("MAX_BYTES", 5 * 1024 * 1024))  # safety limit: 5 MB

# Expected line format: 2026-11-09 10:15:32 ERROR [auth] Invalid password for user bob
LINE_PATTERN = re.compile(
    r"^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+"
    r"(?P<level>DEBUG|INFO|WARNING|WARN|ERROR|CRITICAL)\s+"
    r"\[(?P<service>[\w.-]+)\]\s+"
    r"(?P<message>.*)$"
)


def parse_log(text):
    """Parse log text and return a summary dictionary."""
    levels = {}
    services = {}
    errors = []
    parsed = 0
    unparsed = 0

    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        match = LINE_PATTERN.match(line)
        if not match:
            unparsed += 1
            continue

        parsed += 1
        level = match["level"].replace("WARN", "WARNING") if match["level"] == "WARN" else match["level"]
        levels[level] = levels.get(level, 0) + 1
        services[match["service"]] = services.get(match["service"], 0) + 1

        if level in ("ERROR", "CRITICAL"):
            errors.append({
                "line": number,
                "timestamp": match["timestamp"],
                "service": match["service"],
                "message": match["message"],
            })

    return {
        "lines_parsed": parsed,
        "lines_unparsed": unparsed,
        "levels": levels,
        "services": services,
        "error_count": len(errors),
        "errors": errors[:10],  # first 10 only, to keep logs readable
    }


def process_record(s3_client, record):
    bucket = record["s3"]["bucket"]["name"]
    # S3 keys arrive URL-encoded ("my+file.log"), so we decode them
    key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
    size = record["s3"]["object"].get("size", 0)

    logger.info("New object detected: s3://%s/%s (%s bytes)", bucket, key, size)

    if not key.lower().endswith((".log", ".txt")):
        logger.warning("Skipping %s: not a .log or .txt file", key)
        return {"key": key, "status": "skipped"}

    if size and size > MAX_BYTES:
        logger.warning("Skipping %s: file too large (%s bytes)", key, size)
        return {"key": key, "status": "skipped_too_large"}

    response = s3_client.get_object(Bucket=bucket, Key=key)
    text = response["Body"].read().decode("utf-8", errors="replace")

    summary = parse_log(text)
    logger.info("Parsing summary for %s: %s", key, json.dumps(summary))

    if summary["error_count"] > 0:
        logger.error("%s contains %s error(s)", key, summary["error_count"])

    return {"key": key, "status": "processed", "summary": summary}


def lambda_handler(event, context):
    logger.info("Function invoked, request id: %s", getattr(context, "aws_request_id", "local"))

    s3_client = boto3.client("s3", endpoint_url=S3_ENDPOINT_URL)
    results = []

    for record in event.get("Records", []):
        try:
            results.append(process_record(s3_client, record))
        except Exception:
            logger.exception("Failed to process record")
            raise  # lets Lambda mark the invocation as failed

    logger.info("Done: %s record(s) handled", len(results))
    return {"statusCode": 200, "body": json.dumps(results)}