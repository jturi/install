# Check step: after the run, test that every ticked item is really there and
# print one "OK <label>", "MISSING <label>" or "SKIPPED <label>" line each.
# Scoop apps count as installed when scoop\apps\<app>\<version>\install.json
# exists (Scoop writes it last); commands must be on PATH. An SSH key that
# was skipped for lack of a console is SKIPPED, not missing.
# Puts the number of missing items in -Missing (a [ref]): setup.ps1 reads an
# int on the pipeline as its exit code. ASCII only, PS 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

function Test-CheckScoopApp($App) {
  if (-not (Get-Command Get-ScoopRoot -ErrorAction SilentlyContinue)) { return $false }
  # <version>\install.json also covers "current" and a no_junction Scoop.
  return (Test-Path (Join-Path (Get-ScoopRoot) (Join-Path 'apps' (Join-Path $App (Join-Path '*' 'install.json')))))
}

function Test-CheckCommand($Name) {
  return ((Get-Command $Name -ErrorAction SilentlyContinue) -ne $null)
}

function Test-CheckItem {
  param([object]$Row = $null, [string]$HomeDir = '', [string]$DocumentsDir = '')
  $H = Get-StepConfigHome -HomeDir $HomeDir
  if ($Row.Action -match '^scoop:[^/]+/(.+)') { return (Test-CheckScoopApp $Matches[1]) }
  switch ($Row.Action) {
    'step:profile' {
      foreach ($P in (Get-ProfileStepTargets -DocumentsDir $DocumentsDir)) { if (-not (Test-Path $P)) { return $false } }
      return $true
    }
    'step:hotkeys' {
      if (-not (Test-Path (Join-Path $H (Join-Path 'hotkeys' 'hotkeys.ahk')))) { return $false }
      return ((Get-HotkeysAhkExe) -ne '')
    }
    'step:vscode' { return ((Test-CheckScoopApp 'vscode') -or (Test-CheckCommand 'code')) }
    'step:flameshot' { return (Test-CheckScoopApp 'flameshot') }
    'step:wezterm' { return ((Test-CheckScoopApp 'wezterm') -and (Test-Path (Join-Path $H '.wezterm.lua'))) }
    'step:wsl' { return (Test-CheckCommand 'wsl') }
    'step:ssh-server' { return (Test-StepSshdRunning) }
    'step:ssh-key' { return ((Find-StepSshKey -HomeDir $HomeDir) -ne '') }
  }
  return $true
}

function Write-CheckLine($Ok, $Label) {
  if ($Ok) { Write-Output ('OK      ' + $Label) } else { Write-Output ('MISSING ' + $Label) }
}

function Invoke-CheckStep {
  param([object[]]$Catalog = @(), [string]$HomeDir = '', [string]$DocumentsDir = '', $Missing = $null, [object]$Interactive = $null)
  Write-Output ''
  Write-StepInfo 'Check'
  $Count = 0
  foreach ($Name in @('git', 'make')) {
    $Ok = Test-CheckCommand $Name
    Write-CheckLine $Ok $Name
    if (-not $Ok) { $Count++ }
  }
  foreach ($Row in $Catalog) {
    if (-not $Row.Selected) { continue }
    # A check that throws counts as missing; it must not stop the others.
    $Ok = $false
    try { $Ok = [bool](Test-CheckItem -Row $Row -HomeDir $HomeDir -DocumentsDir $DocumentsDir) }
    catch { Write-StepWarn ('check ' + $Row.Label + ': ' + $_.Exception.Message) }
    if (-not $Ok -and $Row.Action -eq 'step:ssh-key' -and -not (Test-StepSshConsole -Interactive $Interactive)) {
      Write-Output ('SKIPPED ' + $Row.Label + ' (no console)')
      continue
    }
    Write-CheckLine $Ok $Row.Label
    if (-not $Ok) { $Count++ }
  }
  if ($Missing -is [ref]) { $Missing.Value = $Count }
}
