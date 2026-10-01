#!/usr/bin/env bash
# Create the object storage bucket (idempotent). Objects stay private: the web service streams them after its own checks.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" \
  --user "$S3_ACCESS_KEY:$S3_SECRET_KEY" "http://127.0.0.1:9000/${S3_BUCKET:-acf}")
case "$code" in
  200) echo "s3: bucket ${S3_BUCKET:-acf} created" ;;
  409) echo "s3: bucket ${S3_BUCKET:-acf} exists" ;;
  *) echo "s3: unexpected HTTP $code" >&2; exit 1 ;;
esac
