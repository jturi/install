# WSL step: install Ubuntu under WSL once. A registered Ubuntu* distro counts
# as installed, so a rerun does nothing. The first install enables Windows
# features: it needs Administrator and often a reboot before Ubuntu is
# registered. ASCII only, PS 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

# Registered WSL distro names, or @() when WSL has none or is not set up.
function Get-StepWslDistros {
  if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { return @() }
  # PS 5.1 turns native stderr into a terminating error under 'Stop'.
  $ErrorActionPreference = 'Continue'
  # wsl.exe writes UTF-16 unless WSL_UTF8 is set; old builds ignore it, so
  # the NUL bytes are also removed below.
  $SavedUtf8 = $env:WSL_UTF8
  $env:WSL_UTF8 = '1'
  $Out = @()
  $Code = 0
  try {
    $global:LASTEXITCODE = 0
    $Out = @(& wsl -l -q 2>$null)
    $Code = $LASTEXITCODE
  } catch { $Code = 1 }
  finally {
    if ($SavedUtf8) { $env:WSL_UTF8 = $SavedUtf8 } else { Remove-Item Env:WSL_UTF8 -ErrorAction SilentlyContinue }
  }
  if ($Code) { return @() }
  $Names = @()
  foreach ($Raw in $Out) {
    $Name = ([string]$Raw).Replace([string][char]0, '').Trim()
    if ($Name -ne '') { $Names += $Name }
  }
  return $Names
}

function Test-StepWslUbuntu {
  return (@(Get-StepWslDistros | Where-Object { $_ -match '^Ubuntu' }).Count -gt 0)
}

function Invoke-WslStep {
  param([string[]]$Items = @(), [switch]$Verify)
  if (Test-StepWslUbuntu) { Write-StepOk 'WSL (Ubuntu) already installed'; return }
  if ($Verify) { Write-StepInfo 'would install WSL Ubuntu'; return }
  $global:LASTEXITCODE = 0
  & wsl --install -d Ubuntu
  if ($LASTEXITCODE) { throw "wsl --install -d Ubuntu failed (exit $LASTEXITCODE); the first install needs Administrator" }
  if (Test-StepWslUbuntu) { Write-StepOk 'WSL (Ubuntu)'; return }
  Write-StepWarn 'WSL is installing: reboot, finish the Ubuntu setup, then run setup again'
}
