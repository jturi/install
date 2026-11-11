# Profile step: copy the repo PowerShell profile for Windows PowerShell 5.1
# and PowerShell 7. Handles a Documents folder moved by OneDrive.
# ASCII only, PowerShell 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

function Get-ProfileStepTargets {
  param([string]$DocumentsDir = '')
  $Docs = $DocumentsDir
  if (-not $Docs -or $Docs -eq '') { $Docs = [Environment]::GetFolderPath('MyDocuments') }
  if (-not $Docs -or $Docs -eq '') { $Docs = Join-Path (Get-StepConfigHome) 'Documents' }
  $Name = 'Microsoft.PowerShell_profile.ps1'
  return @(
    (Join-Path $Docs (Join-Path 'WindowsPowerShell' $Name)),
    (Join-Path $Docs (Join-Path 'PowerShell' $Name))
  )
}

function Invoke-ProfileStep {
  param([string[]]$Items = @(), [switch]$Verify, [string]$DocumentsDir = '', [string]$SrcPath = '')
  $Src = $SrcPath
  if (-not $Src -or $Src -eq '') {
    $Src = Join-Path $script:WinStepRepoRoot (Join-Path 'configs' (Join-Path 'windows' 'profile.ps1'))
  }
  $Targets = Get-ProfileStepTargets -DocumentsDir $DocumentsDir
  foreach ($Dst in $Targets) {
    if ($Verify) { Write-StepInfo ("would copy profile to " + $Dst); continue }
    Install-StepFile $Src $Dst
  }
}
