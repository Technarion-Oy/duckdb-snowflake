# Snowflake Iceberg on S3 -> DuckDB (native) -> Power BI. Windows PowerShell / pwsh.
#   .\duck.ps1 setup            install the DuckDB CLI (winget) and create .venv with requirements.txt
#   .\duck.ps1 init             create .env from .env.example
#   .\duck.ps1 refresh          read the Iceberg tables from S3 into data\warehouse.duckdb (+ Parquet) once
#   .\duck.ps1 loop             same, repeated every REFRESH_INTERVAL_SECONDS (foreground)
#   .\duck.ps1 register-task    Windows Scheduled Task that runs 'refresh' every REFRESH_INTERVAL_SECONDS
#   .\duck.ps1 unregister-task  remove that task
#   .\duck.ps1 status           what Power BI will see: tables, row counts, last refresh
#   .\duck.ps1 shell            DuckDB CLI, read-only, on data\warehouse.duckdb
#   .\duck.ps1 live             DuckDB CLI with views products/customers/orders that query S3 directly
#   .\duck.ps1 export-sql       write the whole refresh as plain SQL to data\refresh.sql
#   .\duck.ps1 refresh-sql      run that SQL with the DuckDB CLI instead of the Python job
#   .\duck.ps1 notebook         JupyterLab with notebooks\explore.ipynb
#   .\duck.ps1 powerbi-path     print the path to paste into the Power BI DuckDB connector
#
# Shared server with Docker instead: see docker\README.md.
# If scripts are blocked once:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
param([Parameter(Position = 0)][string]$Command = "help",
      [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest)

$ErrorActionPreference = "Stop"
$Root     = $PSScriptRoot
$EnvFile  = Join-Path $Root ".env"
$Venv     = Join-Path $Root ".venv"
$Py       = Join-Path $Venv "Scripts\python.exe"
$Refresh  = Join-Path $Root "refresh\refresh.py"
$Db       = Join-Path $Root "data\warehouse.duckdb"
$TaskName = "DuckDB Iceberg Refresh"

function Need-Env {
  if (-not (Test-Path $EnvFile)) {
    Write-Host ".env is missing. Run .\duck.ps1 init and fill in the S3 location + AWS access." -ForegroundColor Yellow
    exit 1
  }
}
function Need-Venv {
  if (-not (Test-Path $Py)) {
    Write-Host ".venv is missing. Run .\duck.ps1 setup first." -ForegroundColor Yellow
    exit 1
  }
}
function Need-Cli {
  if (-not (Get-Command duckdb -ErrorAction SilentlyContinue)) {
    Write-Host "duckdb CLI not found on PATH. Run .\duck.ps1 setup (winget install DuckDB.cli) and open a new terminal." -ForegroundColor Yellow
    exit 1
  }
}
function Read-Setting([string]$Key, [string]$Default) {
  if (Test-Path $EnvFile) {
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$Key\s*=" } | Select-Object -Last 1
    if ($line) { $v = ($line -split "=", 2)[1].Trim(); if ($v) { return $v } }
  }
  return $Default
}

switch ($Command) {
  "setup" {
    $py = if (Get-Command py -ErrorAction SilentlyContinue) { "py -3" } else { "python" }
    if (-not (Test-Path $Py)) {
      Write-Host "Creating .venv ..."
      Invoke-Expression "$py -m venv `"$Venv`""
    }
    Write-Host "Installing requirements.txt into .venv ..."
    & $Py -m pip install -q --upgrade pip
    & $Py -m pip install -q -r (Join-Path $Root "requirements.txt")
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      if (-not (Get-Command duckdb -ErrorAction SilentlyContinue)) {
        Write-Host "Installing DuckDB CLI 2.0.0 with winget ..."
        winget install --id DuckDB.cli --version 2.0.0 -e --accept-package-agreements --accept-source-agreements
        Write-Host "Open a new terminal so 'duckdb' is on PATH." -ForegroundColor Yellow
      }
    } else {
      Write-Host "winget not available; install the DuckDB CLI from https://duckdb.org/install/ (optional, only for shell/live/refresh-sql)." -ForegroundColor Yellow
    }
    Write-Host "Done. Next: .\duck.ps1 init"
  }
  "init" {
    if (Test-Path $EnvFile) { Write-Host ".env already exists; not overwriting." }
    else {
      Copy-Item (Join-Path $Root ".env.example") $EnvFile
      Write-Host "Created .env. Edit it: ICEBERG_S3_ROOT, AWS_REGION and AWS_PROFILE (or static keys)."
    }
  }
  "refresh" { Need-Venv; Need-Env; & $Py $Refresh --once; exit $LASTEXITCODE }
  "loop"    { Need-Venv; Need-Env; & $Py $Refresh;        exit $LASTEXITCODE }
  "register-task" {
    Need-Venv; Need-Env
    $seconds = [int](Read-Setting "REFRESH_INTERVAL_SECONDS" "900")
    if ($seconds -lt 60) { $seconds = 60 }
    $interval = New-TimeSpan -Seconds $seconds
    $action   = New-ScheduledTaskAction -Execute $Py -Argument "`"$Refresh`" --once" -WorkingDirectory $Root
    $trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval $interval
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
                  -ExecutionTimeLimit (New-TimeSpan -Hours 1) -RunOnlyIfNetworkAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force `
      -Description "Pull Snowflake Iceberg tables from S3 into data\warehouse.duckdb for Power BI" | Out-Null
    Write-Host "Registered '$TaskName': every $($interval.TotalMinutes) min as $env:USERNAME (runs only while you are logged in)."
    Write-Host "Inspect: Get-ScheduledTask '$TaskName' | Get-ScheduledTaskInfo    Run now: Start-ScheduledTask '$TaskName'"
  }
  "unregister-task" {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed '$TaskName'."
  }
  "status" {
    Need-Venv
    if (-not (Test-Path $Db)) { Write-Host "data\warehouse.duckdb does not exist yet; run .\duck.ps1 refresh first." -ForegroundColor Yellow; exit 1 }
    & $Py -c @"
import duckdb
con = duckdb.connect(r'$Db', read_only=True)
con.sql("SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = 'reporting' ORDER BY 2, 1").show()
con.sql("SELECT refreshed_at, table_name, row_count, snapshot_id, seconds FROM reporting.refresh_log ORDER BY refreshed_at DESC LIMIT 10").show()
"@
  }
  "shell" {
    Need-Cli
    if (-not (Test-Path $Db)) { Write-Host "data\warehouse.duckdb does not exist yet; run .\duck.ps1 refresh first." -ForegroundColor Yellow; exit 1 }
    & duckdb -readonly $Db @Rest
  }
  "live" {
    Need-Venv; Need-Env; Need-Cli
    $init = Join-Path $env:TEMP "duckdb-live.sql"
    & $Py $Refresh --print-sql | Set-Content -Encoding utf8 $init
    & duckdb -init $init @Rest
  }
  "export-sql" {
    Need-Venv; Need-Env
    $out = Join-Path $Root "data\refresh.sql"
    & $Py $Refresh --export-sql $out
    Write-Host "Open $out, or run it with: .\duck.ps1 refresh-sql"
  }
  "refresh-sql" {
    Need-Venv; Need-Env; Need-Cli
    $sql = Join-Path $env:TEMP "duckdb-refresh.sql"
    & $Py $Refresh --export-sql $sql
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $tmp = "$Db.tmp"
    Remove-Item -Force -ErrorAction SilentlyContinue $tmp, "$tmp.wal"
    New-Item -ItemType Directory -Force (Split-Path $Db) | Out-Null
    Get-Content $sql -Raw | & duckdb $tmp
    if ($LASTEXITCODE -ne 0) { Write-Host "DuckDB CLI failed; warehouse left unchanged." -ForegroundColor Red; exit $LASTEXITCODE }
    Move-Item -Force $tmp $Db
    Write-Host "refresh-sql complete -> $Db"
  }
  "notebook" {
    Need-Venv
    if (-not (Test-Path $Db)) { Write-Host "Note: data\warehouse.duckdb does not exist yet; run .\duck.ps1 refresh first." -ForegroundColor Yellow }
    & (Join-Path $Venv "Scripts\jupyter.exe") lab --notebook-dir=(Join-Path $Root "notebooks") (Join-Path $Root "notebooks\explore.ipynb")
  }
  "powerbi-path" { Write-Host $Db }
  default { Get-Content $PSCommandPath | Select-Object -Skip 1 -First 14 }
}
