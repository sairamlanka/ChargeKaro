# Runs the ChargeKaro customer app against the hosted (cloud) Supabase project.
# Usage (from anywhere):  powershell -ExecutionPolicy Bypass -File <path>\apps\retailer_app\run.ps1 [extra flutter args]
# Reads env\development.json (gitignored; copy env\development.json.example and
# fill in the project URL and publishable key from the Supabase dashboard).
$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$envFile = Join-Path $repoRoot 'env\development.json'

if (-not (Test-Path $envFile)) {
    Write-Host "Missing $envFile (copy env\development.json.example and fill in your Supabase project URL and key)." -ForegroundColor Red
    exit 1
}

$config = Get-Content $envFile -Raw | ConvertFrom-Json
if ($config.SUPABASE_URL -notmatch '^https://' -or $config.SUPABASE_ANON_KEY -match '^<') {
    Write-Host "$envFile must point at the hosted project: SUPABASE_URL like https://<ref>.supabase.co and a real SUPABASE_ANON_KEY." -ForegroundColor Red
    exit 1
}

Push-Location $PSScriptRoot
try {
    & flutter run "--dart-define-from-file=$envFile" @args
} finally {
    Pop-Location
}
