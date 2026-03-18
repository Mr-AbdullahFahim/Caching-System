<#
What it does on Windows:
  - NPM: points registry to Verdaccio (http://SERVER:4873/)
  - PIP: points index-url to devpi (http://SERVER:3141/root/pypi/+simple/) and sets trusted-host

Usage examples (PowerShell):
  .\pkg-cache-client.ps1 -Action install -ServerHost 192.168.1.50
  .\pkg-cache-client.ps1 -Action status  -ServerHost 192.168.1.50
  .\pkg-cache-client.ps1 -Action reset
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('install','reset','status')]
  [string]$Action,

  [Parameter(Mandatory = $false)]
  [string]$ServerHost
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StateDir  = Join-Path $env:USERPROFILE '.pkg-cache-state'
$StateFile = Join-Path $StateDir 'client.json'

# --- Improved Visual Feedback ---
function Write-Log($msg)     { Write-Host "[pkg-cache-client] $msg" -ForegroundColor Cyan }
function Write-Warn($msg)    { Write-Host "[pkg-cache-client] WARNING: $msg" -ForegroundColor Yellow }
function Write-Success($msg) { Write-Host "[pkg-cache-client] SUCCESS: $msg" -ForegroundColor Green }
function Die($msg)           { Write-Host "[pkg-cache-client] ERROR: $msg" -ForegroundColor Red; exit 1 }

function Ensure-StateDir {
  if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir | Out-Null
  }
}

function Test-ServerHost([string]$h) {
  if ([string]::IsNullOrWhiteSpace($h)) {
    Die "-ServerHost is required for Action=install/status. Example: -ServerHost 192.168.1.50"
  }
  if ($h.Contains(',')) {
    Die "Invalid ServerHost '$h' (comma found). Use dots for IPs, e.g. 192.168.1.50"
  }

  $ipv4 = '^(?:\d{1,3}\.){3}\d{1,3}$'
  $hostPattern = '^[A-Za-z0-9.-]+$'

  if ($h -match $ipv4) { return }
  if (-not ($h -match $hostPattern)) {
    Die "Invalid ServerHost '$h'. Use an IPv4 (192.168.x.x) or a hostname (cache.local)."
  }
}

function Find-PythonCmd {
  if (Get-Command python -ErrorAction SilentlyContinue) { return 'python' }
  if (Get-Command python3 -ErrorAction SilentlyContinue) { return 'python3' }
  if (Get-Command py -ErrorAction SilentlyContinue) { return 'py' }
  return $null
}

# FIX: Refactored to use Start-Process for much more reliable execution
function Pip-Run([string[]]$pipArgs) {
  $py = Find-PythonCmd
  if ($null -eq $py) { Die "Python not found. Install Python to configure pip." }

  $argsList = @()
  if ($py -eq 'py') { $argsList += '-3' }
  $argsList += '-m'
  $argsList += 'pip'
  $argsList += $pipArgs

  # We use Start-Process to avoid PowerShell array parsing quirks
  $process = Start-Process -FilePath $py -ArgumentList $argsList -NoNewWindow -Wait -PassThru
  
  if ($process.ExitCode -ne 0) {
      throw "Command '$py $argsList' exited with code $($process.ExitCode)"
  }
}

function Pip-Run-Quiet([string[]]$pipArgs) {
  $py = Find-PythonCmd
  if ($null -eq $py) { return $null }

  $argsList = @()
  if ($py -eq 'py') { $argsList += '-3' }
  $argsList += '-m'
  $argsList += 'pip'
  $argsList += $pipArgs

  # Native call for retrieving output strings silently
  try {
      $out = & $py $argsList 2>$null
      return $out
  } catch {
      return $null
  }
}

function Tool-Exists([string]$name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Save-State($obj) {
  Ensure-StateDir
  ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Load-State {
  if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
  $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  return ($raw | ConvertFrom-Json)
}

function Npm-GetRegistry {
  if (-not (Tool-Exists 'npm')) { return $null }
  try {
    $v = (npm config get registry 2>$null)
    if ($null -eq $v) { return $null }
    $v = $v.Trim()
    if ($v -eq 'undefined') { return $null }
    return $v
  } catch { return $null }
}

function Npm-SetRegistry([string]$url) {
  if (-not (Tool-Exists 'npm')) {
    Write-Warn "npm not found; skipping npm config."
    return
  }
  Write-Log "Setting npm registry to $url"
  npm config set registry $url
}

function Npm-RestoreRegistry([string]$prev) {
  if (-not (Tool-Exists 'npm')) { return }
  if ([string]::IsNullOrWhiteSpace($prev)) {
    $prev = 'https://registry.npmjs.org/'
  }
  Write-Log "Restoring npm registry to $prev"
  npm config set registry $prev
}

function Pip-GetConfig([string]$key) {
  $out = Pip-Run-Quiet @('config','get',$key)
  if ($null -eq $out) { return $null }
  $v = ($out | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  return $v
}

function Pip-SetConfig([string]$key, [string]$value) {
  Write-Log "pip config set $key = $value"
  Pip-Run @('config','set',$key,$value)
}

function Pip-UnsetConfig([string]$key) {
  Write-Log "Unsetting pip config: $key"
  try { Pip-Run @('config','unset',$key) } catch { Write-Warn "Could not unset $key" }
}

function Check-Ports([string]$h) {
  $ports = @(
    @{ Name='verdaccio (NPM)';  Port=4873 },
    @{ Name='devpi (PIP)';      Port=3141 }
  )

  foreach ($p in $ports) {
    $ok = $false
    try {
      $r = Test-NetConnection -ComputerName $h -Port $p.Port -WarningAction SilentlyContinue
      $ok = [bool]$r.TcpTestSucceeded
    } catch { $ok = $false }

    if ($ok) {
      Write-Success "TCP reachable: $($p.Name) on ${h}:$($p.Port)"
    } else {
      Write-Warn "TCP not reachable: $($p.Name) on ${h}:$($p.Port) (Check server firewall)"
    }
  }
}

function Install-Client([string]$h) {
  Test-ServerHost $h

  $state = [ordered]@{
    serverHost = $h
    npm = [ordered]@{ prevRegistry = $null }
    pip = [ordered]@{ prevIndexUrl = $null; prevTrustedHost = $null }
    savedAt = (Get-Date).ToString('o')
  }

  Write-Log "--- Configuring NPM ---"
  if (Tool-Exists 'npm') {
    $state.npm.prevRegistry = Npm-GetRegistry
    Npm-SetRegistry "http://${h}:4873/"
  } else { Write-Warn "npm not found; skipping." }

  Write-Log "--- Configuring PIP ---"
  $py = Find-PythonCmd
  if ($null -ne $py) {
    try {
      $state.pip.prevIndexUrl    = Pip-GetConfig 'global.index-url'
      $state.pip.prevTrustedHost = Pip-GetConfig 'global.trusted-host'

      Pip-SetConfig 'global.index-url' "http://${h}:3141/root/pypi/+simple/"
      Pip-SetConfig 'global.trusted-host' $h
    } catch {
      # FIX: Print the exact system error
      Write-Warn "Error occurred configuring PIP: $_"
      Write-Warn "You may need to run PowerShell as Administrator."
    }
  } else { Write-Warn "Python not found; skipping." }

  Save-State $state

  Write-Log ""
  Write-Success "Client configured to use cache server: $h"
  Check-Ports $h
}

function Reset-Client {
  $state = Load-State
  if ($null -eq $state) {
    Write-Warn "No state file found ($StateFile). Nothing to reset."
    return
  }

  Write-Log "--- Resetting NPM ---"
  if (Tool-Exists 'npm') {
    Npm-RestoreRegistry $state.npm.prevRegistry
  }

  Write-Log "--- Resetting PIP ---"
  $py = Find-PythonCmd
  if ($null -ne $py) {
    Pip-UnsetConfig 'global.index-url'
    Pip-UnsetConfig 'global.trusted-host'

    if (-not [string]::IsNullOrWhiteSpace($state.pip.prevIndexUrl)) {
      Pip-SetConfig 'global.index-url' $state.pip.prevIndexUrl
    }
    if (-not [string]::IsNullOrWhiteSpace($state.pip.prevTrustedHost)) {
      Pip-SetConfig 'global.trusted-host' $state.pip.prevTrustedHost
    }
  }

  try { Remove-Item -LiteralPath $StateFile -Force } catch { }
  Write-Success "Client reset done."
}

function Status-Client([string]$h) {
  Test-ServerHost $h

  Write-Log "--- Current Client Configuration ---"
  if (Tool-Exists 'npm') {
    $reg = Npm-GetRegistry
    Write-Host "  npm registry: " -NoNewline; Write-Host "$reg" -ForegroundColor Magenta
  } else { Write-Host "  npm registry: (npm not installed)" }

  $py = Find-PythonCmd
  if ($null -ne $py) {
    $idx = Pip-GetConfig 'global.index-url'
    $thr = Pip-GetConfig 'global.trusted-host'
    Write-Host "  pip index-url: " -NoNewline; Write-Host "$idx" -ForegroundColor Magenta
    Write-Host "  pip trusted-host: " -NoNewline; Write-Host "$thr" -ForegroundColor Magenta
  } else { Write-Host "  pip: (python not installed)" }

  Write-Log "`n--- Server Reachability Checks ---"
  Check-Ports $h
}

switch ($Action) {
  'install' { Install-Client $ServerHost }
  'reset'   { Reset-Client }
  'status'  { Status-Client $ServerHost }
}