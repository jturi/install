# VS Code step: install VS Code, then the extensions from the repo list that
# are not installed yet. A failed extension doesn't stop the others; the step
# then fails and names it. ASCII only, PowerShell 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

# The VS Code CLI: `code` on PATH, else the Scoop copy (PATH in this process
# can predate the shim). '' when neither exists.
function Get-VscodeStepCli {
  if (Get-Command code -ErrorAction SilentlyContinue) { return 'code' }
  if (Get-Command Get-ScoopRoot -ErrorAction SilentlyContinue) {
    $Cmd = Join-Path (Get-ScoopRoot) (Join-Path 'apps' (Join-Path 'vscode' (Join-Path 'current' (Join-Path 'bin' 'code.cmd'))))
    if (Test-Path -LiteralPath $Cmd) { return $Cmd }
  }
  return ''
}

# Extension ids from the list file: no blanks, no comments, no duplicates.
function Get-VscodeStepExtensions {
  param([string]$ListPath = '')
  if (-not (Test-Path -LiteralPath $ListPath)) { return @() }
  $Ids = @()
  foreach ($Raw in ([IO.File]::ReadAllText($ListPath) -split "`n")) {
    $Line = $Raw.Trim()
    if ($Line -eq '' -or $Line.StartsWith('#')) { continue }
    if (-not ($Ids -contains $Line)) { $Ids += $Line }
  }
  return $Ids
}

function Invoke-VscodeStep {
  param([string[]]$Items = @(), [switch]$Verify, [string]$ListPath = '')
  $List = $ListPath
  if (-not $List -or $List -eq '') {
    $List = Join-Path $script:WinStepRepoRoot (Join-Path 'configs' (Join-Path 'windows' 'vscode_extensions.txt'))
  }
  $Wanted = @(Get-VscodeStepExtensions -ListPath $List)
  if ($Verify) { Write-StepInfo ('would install VS Code and ' + $Wanted.Count + ' extension(s)'); return }
  Install-StepScoopApp 'extras' 'vscode'
  if ($Wanted.Count -eq 0) { Write-StepOk 'VS Code'; return }
  $Cli = Get-VscodeStepCli
  if ($Cli -eq '') { throw 'VS Code CLI (code) not found after scoop install' }
  # -contains is case-insensitive, like VS Code extension ids.
  $global:LASTEXITCODE = 0
  $Have = @(& $Cli --list-extensions)
  if ($LASTEXITCODE) { $Have = @() }
  $Failed = @()
  foreach ($Id in $Wanted) {
    if ($Have -contains $Id) { continue }
    $global:LASTEXITCODE = 0
    & $Cli --install-extension $Id
    if ($LASTEXITCODE) { Write-StepWarn "code --install-extension $Id failed (exit $LASTEXITCODE)"; $Failed += $Id }
  }
  if ($Failed.Count -gt 0) { throw ('VS Code extensions failed: ' + ($Failed -join ', ')) }
  Write-StepOk 'VS Code'
}
