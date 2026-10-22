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
  $passed = $false
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $ErrorActionPreference = 'Continue'
    $result = & supabase db query --linked --project-ref $project.ref --file $testFile.FullName 2>&1 | Out-String
    $queryExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($queryExitCode -eq 0) { $passed = $true; break }
    if ($result -notmatch 'Transport\s?Error|NetworkError|Connection terminated due to connection timeout') { throw "Database integration test failed: $($testFile.Name)`n$result" }
    if ($attempt -lt 5) { Start-Sleep -Seconds (2 * $attempt) }
  }
  if (-not $passed) { throw "Database integration test failed after five transport retries: $($testFile.Name)" }
}
Write-Host "All database integration tests passed against project $($project.ref). Test rows are rolled back."
