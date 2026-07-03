# Applies pending SQL migrations to the nexus Postgres container, in order.
# Idempotent: skips versions already recorded in public.schema_migrations.
# Usage: pwsh ./apply-migrations.ps1   (from the db/ directory)

$ErrorActionPreference = "Stop"
$container = "nexus-postgres"

$applied = docker exec $container psql -U nexus -d nexus -tAc `
    "SELECT version FROM public.schema_migrations" 2>$null
if ($LASTEXITCODE -ne 0) { $applied = @() }  # table doesn't exist yet -> nothing applied

$files = Get-ChildItem -Path "$PSScriptRoot/migrations" -Filter "*.sql" | Sort-Object Name
foreach ($f in $files) {
    $version = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    if ($applied -contains $version) {
        Write-Host "skip  $version (already applied)"
        continue
    }
    Write-Host "apply $version ..."
    docker exec $container psql -U nexus -d nexus -v ON_ERROR_STOP=1 -f "/migrations/$($f.Name)"
    if ($LASTEXITCODE -ne 0) { throw "Migration $version failed — stopping." }
}
Write-Host "done."
