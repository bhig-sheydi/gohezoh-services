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
$testFiles = @(Get-ChildItem -LiteralPath $testsPath -Filter '*.test.sql' | Sort-Object Name)
if ($testFiles.Count -eq 0) { throw 'No database integration tests were found.' }
$batchSize = 9
for ($offset = 0; $offset -lt $testFiles.Count; $offset += $batchSize) {
  $batch = @($testFiles | Select-Object -Skip $offset -First $batchSize)
  $batchNames = ($batch | ForEach-Object { $_.Name }) -join ', '
  Write-Host "Running database integration batch: $batchNames"
  $batchPath = Join-Path $repoRoot 'supabase/.temp/linked-test-batch.sql'
  $batchSql = ($batch | ForEach-Object { "-- $($_.Name)`n" + [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
  [System.IO.File]::WriteAllText($batchPath, $batchSql, [System.Text.UTF8Encoding]::new($false))
  $passed = $false
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $ErrorActionPreference = 'Continue'
    $result = & supabase db query --linked --project-ref $project.ref --file $batchPath 2>&1 | Out-String
    $queryExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($queryExitCode -eq 0) { $passed = $true; break }
    if ($result -notmatch 'Transport\s?Error|NetworkError|Connection terminated due to connection timeout|DbConfigConnectTempRoleError|unsupported or invalid secret format') { throw "Database integration batch failed: $batchNames`n$result" }
    if ($attempt -lt 5) { Start-Sleep -Seconds (2 * $attempt) }
  }
  Remove-Item -LiteralPath $batchPath -ErrorAction SilentlyContinue
  if (-not $passed) { throw "Database integration batch failed after five transport retries: $batchNames" }
}
Write-Host "All database integration tests passed against project $($project.ref). Test rows are rolled back."
