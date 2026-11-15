# Shared helpers for Windows steps. ASCII only, PowerShell 5.1 syntax only.
# Dot-sourced by each step file; safe to dot-source more than once.

# Repo root for config sources. Inside a function $MyInvocation.MyCommand.Path
# is empty, so steps read this instead.
$script:WinStepRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

if (-not (Get-Variable -Name WinStepHelpersLoaded -ErrorAction SilentlyContinue)) {
  $script:WinStepHelpersLoaded = $true

  # Output vocabulary, shared by every step (ASCII only):
  #   == Title ==     section header, one per step
  #     - text        progress or a note
  #     [OK] text     done, or already in place
  #     [!!] text     warning, the run goes on (Write-StepWarn)
  function Write-StepSection($Title) { Write-Output ("`n== " + $Title + " ==") }
  function Write-StepInfo($Msg) { Write-Output ("  - " + $Msg) }
  function Write-StepOk($Msg) { Write-Output ("  [OK] " + $Msg) }
  function Write-StepWarn($Msg) { Write-Output ("  [!!] " + $Msg) }

  # Things the user must still do by hand (a restart, a first-run setup). Steps
  # add them; setup prints them under TODO at the end of the run, in yellow.
  function Add-StepTodo($Msg) {
    if ($null -eq $global:StepTodos) { $global:StepTodos = @() }
    $global:StepTodos += [string]$Msg
  }
  function Write-StepTodos {
    if ($null -eq $global:StepTodos -or @($global:StepTodos).Count -eq 0) { return }
    Write-Output "`n== TODO =="
    foreach ($Todo in @($global:StepTodos)) { Write-Host ('  [!!] ' + $Todo) -ForegroundColor Yellow }
  }

  # Run a scoop command with its output captured: the progress noise stays out
  # of the run. Returns the exit code and the captured lines.
  function Invoke-StepScoop {
    param([string[]]$ScoopArgs = @())
    $global:LASTEXITCODE = 0
    $Out = @(& scoop @ScoopArgs *>&1 | ForEach-Object { [string]$_ })
    return @{ Code = $LASTEXITCODE; Lines = $Out }
  }

  # The last few captured lines, for an error message.
  function Get-StepTail($Lines, [int]$Count = 4) {
    $Clean = @($Lines | Where-Object { $_ -and $_.Trim() -ne '' })
    if ($Clean.Count -eq 0) { return '' }
    $Start = [Math]::Max(0, $Clean.Count - $Count)
    return (($Clean[$Start..($Clean.Count - 1)]) -join ' | ')
  }

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

  # Next free <file>.bak.<time>[.n]: two backups in one second both stay.
  function Get-StepBackupPath($File) {
    $Base = $File + '.bak.' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    $Bak = $Base
    $n = 0
    while (Test-Path -LiteralPath $Bak) { $n++; $Bak = $Base + '.' + $n }
    return $Bak
  }

  function Backup-StepFile($File) {
    if (-not (Test-Path -LiteralPath $File)) { return }
    Copy-Item -LiteralPath $File (Get-StepBackupPath $File)
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
    # Write a temp file next to it, then swap it in: an interrupted run never
    # leaves a half-written config.
    $Tmp = $Dst + '.tmp.' + $PID
    try {
      Copy-Item -LiteralPath $Src $Tmp -Force
      Move-Item -LiteralPath $Tmp $Dst -Force
    } catch {
      Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
      throw
    }
    Write-StepOk $Dst
  }

  function Get-StepConfigHome {
    param([string]$HomeDir = '')
    if ($HomeDir -and $HomeDir -ne '') { return $HomeDir }
    if ($env:USERPROFILE -and $env:USERPROFILE -ne '') { return $env:USERPROFILE }
    if ($env:HOME -and $env:HOME -ne '') { return $env:HOME }
    return '~'
  }

  # True when the bucket folder exists under the Scoop root.
  function Test-StepScoopBucket($Bucket) {
    if (-not (Get-Command Get-ScoopRoot -ErrorAction SilentlyContinue)) { return $false }
    return (Test-Path (Join-Path (Get-ScoopRoot) (Join-Path 'buckets' $Bucket)))
  }

  # Add a bucket once. Needs git, so the scoop step installs main/git first.
  function Add-StepScoopBucket($Bucket) {
    if (Test-StepScoopBucket $Bucket) { return }
    $Res = Invoke-StepScoop @('bucket', 'add', $Bucket)
    if ($Res.Code) { throw "scoop bucket add $Bucket failed (exit $($Res.Code)): $(Get-StepTail $Res.Lines)" }
    Write-StepInfo ("added bucket " + $Bucket)
  }

  # Install <bucket>/<app>, adding the bucket first. Quiet: one line per app.
  # Throws on a scoop error, with the last output lines.
  function Install-StepScoopApp($Bucket, $App) {
    Add-StepScoopBucket $Bucket
    $Res = Invoke-StepScoop @('install', ($Bucket + '/' + $App))
    if ($Res.Code) { throw "scoop install $Bucket/$App failed (exit $($Res.Code)): $(Get-StepTail $Res.Lines)" }
    if (($Res.Lines -join ' ') -match 'already installed') { Write-StepOk ($App + ' (already installed)') }
    else { Write-StepOk $App }
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

  # Names of the installed WSL distros. wsl.exe prints UTF-16 when piped, so
  # NUL characters, CRs and a BOM are stripped. Empty when WSL is absent.
  function Get-WslDistroNames {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    try {
      $Raw = & wsl.exe --list --quiet
    } catch { return @() }
    $Names = @()
    foreach ($Line in @($Raw)) {
      $Name = ([string]$Line -replace '[\x00\r\uFEFF]', '').Trim()
      if ($Name -ne '') { $Names += $Name }
    }
    return $Names
  }

  # True when the Ubuntu distro is installed (not just wsl.exe present).
  function Test-WslUbuntuInstalled {
    return ((Get-WslDistroNames) -contains 'Ubuntu')
  }
}
