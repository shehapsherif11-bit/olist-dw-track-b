# Runs the whole project in the documented order and saves each output in .\results
# Usage:   powershell -ExecutionPolicy Bypass -File .\run_all.ps1 -Reset
# -Reset deletes the database OlistDW_Project first (needed when it already exists).
param(
    [string]$Server = '.',
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force results | Out-Null

$scripts = @(
    'sql\01_database_schemas.sql', 'sql\02_source_import.sql', 'sql\03_staging_etl_tables.sql',
    'sql\04_prepare_batches.sql', 'sql\05_dw_sf_tables.sql', 'sql\06_etl_extract_validate.sql',
    'sql\07_etl_dimensions.sql', 'sql\08_etl_scd_seller.sql', 'sql\09_etl_fact_sales.sql',
    'sql\10_etl_track_b.sql', 'sql\11_etl_run_batch.sql', 'sql\12_mart_views.sql',
    'tests\T1_check_batch.sql',
    'sql\13_run_B1.sql', 'sql\14_run_B2.sql', 'sql\15_run_B3_replay.sql',
    'tests\T2_reconciliation.sql', 'tests\T3_scd_checks.sql', 'tests\T4_integrity.sql', 'tests\T5_negative_dq.sql',
    'sql\19_snowflake_compare.sql', 'sql\18_olap.sql',
    'sql\16_run_X1.sql', 'sql\17_track_b_queries.sql', 'sql\20_batch_manifest.sql'
)
if ($Reset) { $scripts = @('sql\00_reset.sql') + $scripts }

foreach ($script in $scripts) {
    $output = Join-Path 'results' ([IO.Path]::GetFileNameWithoutExtension($script) + '.txt')
    Write-Host "Running $script"
    # -I: QUOTED_IDENTIFIER on. -b: stop on error. -C: trust the local server certificate.
    sqlcmd -S $Server -E -C -I -b -f 65001 -W -s '|' -i $script -o $output
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $script  (see $output)" -ForegroundColor Red
        Get-Content $output -Tail 20
        exit 1
    }
}
Write-Host 'ALL SCRIPTS PASSED' -ForegroundColor Green
