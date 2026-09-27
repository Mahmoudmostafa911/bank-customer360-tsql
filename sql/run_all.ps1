<#
.SYNOPSIS
  Runs the Bank Customer 360 & Churn Warehouse project end to end with sqlcmd.
.EXAMPLE
  .\run_all.ps1                                   # local default instance, Windows auth
  .\run_all.ps1 -Server "localhost\SQLEXPRESS"    # named instance
  .\run_all.ps1 -Server myserver.database.windows.net -User me -Password '***'   # Azure SQL (create the DB first)
#>
param(
    [string]$Server   = "localhost",
    [string]$User     = "",
    [string]$Password = "",
    [switch]$SkipTests
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$auth = if ($User) { @("-U", $User, "-P", $Password) } else { @("-E") }

$scripts = @("00_create_database.sql", "01_source_extracts.sql", "02_generate_source_data.sql",
             "03_warehouse_tables.sql", "04_etl_procedures.sql", "05_analytics_views.sql")
foreach ($s in $scripts) {
    Write-Host ">> $s" -ForegroundColor Cyan
    & sqlcmd -S $Server @auth -b -i (Join-Path $root $s)
    if ($LASTEXITCODE -ne 0) { throw "$s failed" }
}

Write-Host ">> initial full load" -ForegroundColor Cyan
& sqlcmd -S $Server @auth -b -d BankDW -Q "EXEC etl.usp_RunFullLoad @Mode = 'Full';"
if ($LASTEXITCODE -ne 0) { throw "full load failed" }

if (-not $SkipTests) {
    Write-Host ">> tests" -ForegroundColor Cyan
    & sqlcmd -S $Server @auth -b -i (Join-Path $root "08_tests.sql")
    & sqlcmd -S $Server @auth -b -d BankDW -Q "EXEC test.usp_RunAll @IncludeIdempotencyRun = 1;"
    if ($LASTEXITCODE -ne 0) { throw "tests failed" }
}
Write-Host "Done. Try 06_analytics_queries.sql, 07_performance.sql and 09_incremental_demo.sql next." -ForegroundColor Green
