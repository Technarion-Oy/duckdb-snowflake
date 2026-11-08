# Docker image for a shared server (optional)

On a single Windows workstation you do not need this: `duck.ps1` runs DuckDB natively and a
Scheduled Task keeps the warehouse fresh. Use the image when the refresh should run unattended
on a Linux server that nobody logs into, or in CI.

The image is DuckDB 2.0.0 (Python package + CLI) with `httpfs` and `iceberg` pre-installed.
It runs the same `refresh/refresh.py` and reads the same `.env` from the repo root.

```bash
cp .env.example .env            # ICEBERG_S3_ROOT, AWS_* ; AWS_DIR = folder with AWS config to mount
docker/server.sh refresh        # one-off sync into ./data/warehouse.duckdb + ./data/parquet
docker/server.sh up             # loop every REFRESH_INTERVAL_SECONDS, restart: unless-stopped
docker/server.sh logs
docker/server.sh status
```

Container modes (`docker compose run --rm duckdb <mode>`): `refresh`, `loop`, `shell`, `live`,
`export-sql`, `refresh-sql`. See `entrypoint.sh`.

AWS access inside the container: either static keys in `.env`, or mount your AWS config folder
read-only via `AWS_DIR` and set `AWS_PROFILE`. On a server an instance/task role also works with
no keys at all, since the secret uses the AWS credential chain.

Serve `./data` to Power BI users via a file share, or run the on-premises data gateway on a
Windows box that can see it (see `../powerbi/README.md`).
