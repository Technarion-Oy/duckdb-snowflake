# AWS access for DuckDB

DuckDB needs **read-only** access to the external volume prefix. Replace `my-bucket` and
`snowflake/mock_data` in `iam-read-policy.json` with the values from
`snowflake/02-find-s3-locations.sql`, then either:

**A. Named profile (default). DuckDB's credential chain reads `%USERPROFILE%\.aws` directly.**

```powershell
aws configure --profile duckdb-reader        # or an SSO profile: aws sso login --profile duckdb-reader
# .env
AWS_PROFILE=duckdb-reader
AWS_REGION=eu-west-1
```

SSO sessions expire; when a refresh logs `403`/credential errors, run `aws sso login` again. The
next refresh picks up the new token automatically.

**B. Static keys for a dedicated IAM user**

```bash
aws iam create-user --user-name duckdb-reader
aws iam put-user-policy --user-name duckdb-reader --policy-name iceberg-read \
    --policy-document file://aws/iam-read-policy.json
aws iam create-access-key --user-name duckdb-reader
# .env
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=eu-west-1
```

If the bucket uses SSE-KMS, also allow `kms:Decrypt` on the key.
