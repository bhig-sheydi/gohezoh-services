param(
  [string]$ServiceAccountPath = 'C:\Users\hp\Downloads\walkinguniverseenterprise-firebase-adminsdk-rssdh-692761fe06.json'
)

$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $ServiceAccountPath)) { throw 'Firebase service-account JSON was not found.' }
$account = Get-Content -LiteralPath $ServiceAccountPath -Raw | ConvertFrom-Json
if ($account.project_id -ne 'walkinguniverseenterprise' -or !$account.private_key) {
  throw 'The Firebase service account is missing its key or belongs to another project.'
}

$oldToken = $env:SUPABASE_ACCESS_TOKEN
$secureToken = Read-Host 'Paste the Supabase access token for project yejiqfocqmdxjeajoexd' -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
try { $env:SUPABASE_ACCESS_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }

$name = [guid]::NewGuid().ToString('N')
$envFile = Join-Path $env:TEMP "kwik-fcm-$name.env"
$sqlFile = Join-Path $env:TEMP "kwik-fcm-$name.sql"
try {
  $bytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $workerSecret = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
  $compact = $account | ConvertTo-Json -Compress -Depth 20
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($envFile, "FIREBASE_SERVICE_ACCOUNT_JSON=$compact`nADMIN_SPIKE_PUSH_SECRET=$workerSecret`n", $utf8)
  & supabase secrets set --project-ref yejiqfocqmdxjeajoexd --env-file $envFile | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Supabase Edge Function secrets could not be saved.' }

  $sql = @'
do $block$
declare v_id uuid;
begin
  select id into v_id from vault.secrets where name='admin_spike_push_secret';
  if v_id is null then
    perform vault.create_secret('__SECRET__','admin_spike_push_secret');
  else
    perform vault.update_secret(v_id,'__SECRET__');
  end if;
end $block$;
update public.admin_spike_push_config set enabled=true,updated_at=now() where singleton;
'@
  $sql = $sql.Replace('__SECRET__', $workerSecret)
  [IO.File]::WriteAllText($sqlFile, $sql, $utf8)
  & supabase db query --linked --file $sqlFile | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'The database push worker could not be activated.' }
  Write-Host 'Firebase push is activated. Install Android v1.0.12 and enable phone alerts in Service health.'
} finally {
  Remove-Item -LiteralPath $envFile,$sqlFile -Force -ErrorAction SilentlyContinue
  $env:SUPABASE_ACCESS_TOKEN = $oldToken
}
