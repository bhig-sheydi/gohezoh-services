$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectFile = Join-Path $repoRoot 'supabase/.temp/linked-project.json'
$testsPath = Join-Path $repoRoot 'supabase/tests'
if (-not (Test-Path -LiteralPath $projectFile)) {
  throw 'Link the intended Supabase project first with supabase link.'
}
$project = Get-Content -LiteralPath $projectFile -Raw | ConvertFrom-Json
if (-not $project.ref) { throw 'The linked Supabase project reference is missing.' }
$env:SUPABASE_HOME = Join-Path $env:LOCALAPPDATA 'Gohezoh\SupabaseCLI'
$testFiles = Get-ChildItem -LiteralPath $testsPath -Filter '*.test.sql' | Sort-Object Name
if ($testFiles.Count -eq 0) { throw 'No database integration tests were found.' }
foreach ($testFile in $testFiles) {
  Write-Host "Running database integration test: $($testFile.Name)"
  supabase db query --linked --project-ref $project.ref --file $testFile.FullName
  if ($LASTEXITCODE -ne 0) { throw "Database integration test failed: $($testFile.Name)" }
}
Write-Host "All database integration tests passed against project $($project.ref). Test rows are rolled back."
