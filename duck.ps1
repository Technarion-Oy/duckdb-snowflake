# Helper for the DuckDB <- Snowflake Iceberg on S3 -> Power BI stack (Windows PowerShell / pwsh).
#   .\duck.ps1 init             create docker\.env from the example
#   .\duck.ps1 build            build the DuckDB 2.0 image
#   .\duck.ps1 refresh          one-off read of the Iceberg tables from S3 into data\warehouse.duckdb (+ Parquet)
#   .\duck.ps1 up               start the background sync loop (REFRESH_INTERVAL_SECONDS)
#   .\duck.ps1 down             stop it
#   .\duck.ps1 logs             follow the sync log
#   .\duck.ps1 shell            DuckDB CLI, read-only, on data\warehouse.duckdb
#   .\duck.ps1 live             DuckDB CLI querying the S3 Iceberg tables directly (no local copy)
#   .\duck.ps1 status           what Power BI will see: tables, row counts, last refresh
#   .\duck.ps1 notebook         JupyterLab (local venv) with notebooks\explore.ipynb on data\warehouse.duckdb
#   .\duck.ps1 powerbi-path     print the path to paste into the Power BI DuckDB connector
#
# If scripts are blocked:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
param([Parameter(Position = 0)][string]$Command = "help",
      [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest)

$ErrorActionPreference = "Stop"
$Root    = $PSScriptRoot
$EnvFile = Join-Path $Root "docker\.env"
$Compose = @("compose", "-f", (Join-Path $Root "docker\docker-compose.yml"), "--env-file", $EnvFile)

function Need-Env {
  if (-not (Test-Path $EnvFile)) {
    Write-Host "docker\.env is missing. Run .\duck.ps1 init and fill in the S3 location + AWS access." -ForegroundColor Yellow
    exit 1
  }
}
function Need-Docker {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "docker was not found on PATH. Install/start Docker Desktop." -ForegroundColor Yellow
    exit 1
  }
  docker info *> $null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker engine is not running. Start Docker Desktop and wait until it says 'Engine running'." -ForegroundColor Yellow
    exit 1
  }
}
function Invoke-Compose { param([string[]]$Args) & docker @Compose @Args; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }

switch ($Command) {
  "init" {
    if (Test-Path $EnvFile) { Write-Host "docker\.env already exists; not overwriting." }
    else {
      Copy-Item (Join-Path $Root "docker\.env.example") $EnvFile
      Write-Host "Created docker\.env. Edit it: ICEBERG_S3_ROOT, AWS_REGION and AWS_PROFILE (or static keys)."
      Write-Host "AWS_DIR defaults to $env:USERPROFILE\.aws"
    }
  }
  "build"   { Need-Docker; Need-Env; Invoke-Compose @("build") }
  "refresh" { Need-Docker; Need-Env; Invoke-Compose @("run", "--rm", "duckdb", "refresh") }
  "up"      { Need-Docker; Need-Env; Invoke-Compose @("up", "-d", "--build"); Write-Host "Sync loop running. .\duck.ps1 logs to follow." }
  "down"    { Need-Docker; Invoke-Compose @("down") }
  "logs"    { Need-Docker; Invoke-Compose @("logs", "-f", "duckdb") }
  "shell"   { Need-Docker; Need-Env; Invoke-Compose (@("run", "--rm", "-it", "duckdb", "shell") + $Rest) }
  "live"    { Need-Docker; Need-Env; Invoke-Compose (@("run", "--rm", "-it", "duckdb", "live") + $Rest) }
  "status"  {
    Need-Docker; Need-Env
    $sql = "SELECT table_schema, table_name, table_type FROM information_schema.tables WHERE table_schema = 'reporting' ORDER BY 3, 2; SELECT * FROM reporting.refresh_log ORDER BY refreshed_at DESC LIMIT 10;"
    Invoke-Compose @("run", "--rm", "duckdb", "shell", "-c", $sql)
  }
  "notebook" {
    $Venv = Join-Path $Root "notebooks\.venv"
    $Jupyter = Join-Path $Venv "Scripts\jupyter.exe"
    if (-not (Test-Path $Jupyter)) {
      Write-Host "Creating notebooks\.venv and installing notebooks\requirements.txt ..."
      $py = if (Get-Command py -ErrorAction SilentlyContinue) { "py" } else { "python" }
      if ($py -eq "py") { & py -3 -m venv $Venv } else { & python -m venv $Venv }
      & (Join-Path $Venv "Scripts\pip.exe") install -q -r (Join-Path $Root "notebooks\requirements.txt")
    }
    if (-not (Test-Path (Join-Path $Root "data\warehouse.duckdb"))) { Write-Host "Note: data\warehouse.duckdb does not exist yet; run .\duck.ps1 refresh first." -ForegroundColor Yellow }
    & $Jupyter lab --notebook-dir=(Join-Path $Root "notebooks") (Join-Path $Root "notebooks\explore.ipynb")
  }
  "powerbi-path" { Write-Host (Join-Path $Root "data\warehouse.duckdb") }
  default { Get-Content $PSCommandPath | Select-Object -Skip 1 -First 13 }
}
