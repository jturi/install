# Shared helpers for Windows steps. ASCII only, PowerShell 5.1 syntax only.
# Dot-sourced by each step file; safe to dot-source more than once.

if (-not (Get-Variable -Name WinStepHelpersLoaded -ErrorAction SilentlyContinue)) {
  $script:WinStepHelpersLoaded = $true

  function Write-StepInfo($Msg) { Write-Output ("==> " + $Msg) }
  function Write-StepOk($Msg) { Write-Output (" ok " + $Msg) }
  function Write-StepWarn($Msg) { Write-Warning $Msg }

  function Test-StepFilesEqual($A, $B) {
    if (-not (Test-Path $A)) { return $false }
    if (-not (Test-Path $B)) { return $false }
    $X = [IO.File]::ReadAllBytes($A)
    $Y = [IO.File]::ReadAllBytes($B)
    if ($X.Length -ne $Y.Length) { return $false }
    for ($i = 0; $i -lt $X.Length; $i++) {
      if ($X[$i] -ne $Y[$i]) { return $false }
    }
    return $true
  }

  function Backup-StepFile($File) {
    if (-not (Test-Path $File)) { return }
    $Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    Copy-Item -Force $File ($File + '.bak.' + $Stamp)
  }

  function Install-StepFile($Src, $Dst) {
    if (-not (Test-Path $Src)) { throw "missing config source: $Src" }
    if ((Test-Path $Dst) -and (Test-StepFilesEqual $Src $Dst)) {
      Write-StepOk "$Dst (unchanged)"
      return
    }
    Backup-StepFile $Dst
    $Dir = Split-Path $Dst -Parent
    if ($Dir -and $Dir -ne '') { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    Copy-Item -Force $Src $Dst
    Write-StepOk $Dst
  }

  function Get-StepConfigHome {
    param([string]$HomeDir = '')
    if ($HomeDir -and $HomeDir -ne '') { return $HomeDir }
    if ($env:USERPROFILE -and $env:USERPROFILE -ne '') { return $env:USERPROFILE }
    if ($env:HOME -and $env:HOME -ne '') { return $env:HOME }
    return '~'
  }

  function Test-StepAdmin {
    param([object]$IsAdmin = $null)
    if ($IsAdmin -ne $null) { return ([bool]$IsAdmin) }
    try {
      $Id = [Security.Principal.WindowsIdentity]::GetCurrent()
      $P = New-Object Security.Principal.WindowsPrincipal($Id)
      return $P.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
  }
}
