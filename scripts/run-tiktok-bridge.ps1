param(
  [Parameter(Mandatory = $true)]
  [string]$UniqueId,
  [Parameter(Mandatory = $true)]
  [string]$Token,
  [ValidateRange(1024, 65535)]
  [int]$Port = 38101,
  [ValidateRange(1, 500)]
  [int]$DurationMs = 120,
  [ValidatePattern('.+')]
  [string]$Prefix = '!',
  [ValidateRange(0, 60)]
  [double]$GlobalCooldown = 0.125,
  [ValidateRange(0, 60)]
  [double]$UserCooldown = 0.8,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $Root '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $Python)) {
  throw 'Python environment missing. Run scripts\setup.ps1 first.'
}

& $Python -c 'import TikTokLive' 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'Installing the TikTok bridge dependency...'
  & $Python -m pip install -r (Join-Path $Root 'requirements-tiktok.txt')
  if ($LASTEXITCODE -ne 0) { throw 'TikTok bridge dependency installation failed.' }
}

$arguments = @(
  (Join-Path $Root 'tools\tiktok_bridge.py'),
  '--unique-id', $UniqueId,
  '--token', $Token,
  '--port', $Port,
  '--duration-ms', $DurationMs
)
$arguments += '--prefix', $Prefix
$arguments += '--global-cooldown', $GlobalCooldown
$arguments += '--user-cooldown', $UserCooldown
if ($DryRun) { $arguments += '--dry-run' }
& $Python @arguments
exit $LASTEXITCODE
