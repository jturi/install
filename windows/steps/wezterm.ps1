# WezTerm step: install through Scoop, copy the repo config home.
# Handles home paths with spaces. ASCII only, PowerShell 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

function Invoke-WeztermStep {
  param([string[]]$Items = @(), [switch]$Verify, [string]$WeztermHome = '', [string]$SrcPath = '')
  $HomeDir = Get-StepConfigHome -HomeDir $WeztermHome
  $Src = $SrcPath
  if (-not $Src -or $Src -eq '') {
    $Src = Join-Path $script:WinStepRepoRoot (Join-Path 'configs' (Join-Path 'wezterm' 'windows.lua'))
  }
  $Dst = Join-Path $HomeDir '.wezterm.lua'
  if ($Verify) { Write-StepInfo ("would install WezTerm and copy $Dst"); return }
  scoop install extras/wezterm
  Install-StepFile $Src $Dst
}
