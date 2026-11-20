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

# The profile text with only the selected alias groups: a block from
# '# @group <name>' to '# @end' is kept when <name> is in $Groups. Lines
# outside any block are always kept, and so are a kept block's marker lines.
function Get-ProfileGroupText {
  param([string]$SrcPath = '', [string[]]$Groups = @())
  $Out = New-Object System.Collections.Generic.List[string]
  $Drop = $false
  foreach ($Line in [IO.File]::ReadAllLines($SrcPath)) {
    if ($Line -match '^# @group ([A-Za-z0-9_-]+)\s*$') { $Drop = -not ($Groups -contains $Matches[1]) }
    if (-not $Drop) { $Out.Add($Line) }
    if ($Line -match '^# @end\s*$') { $Drop = $false }
  }
  return (($Out -join "`n") + "`n")
}

function Invoke-ProfileStep {
  param([string[]]$Items = @(), [switch]$Verify, [string]$DocumentsDir = '', [string]$SrcPath = '')
  $Src = $SrcPath
  if (-not $Src -or $Src -eq '') {
    $Src = Join-Path $script:WinStepRepoRoot (Join-Path 'configs' (Join-Path 'windows' 'profile.ps1'))
  }
  # Items: 'profile' (the profile itself) plus the ticked alias groups
  # (catalog group 'aliases', action step:profile).
  if (-not ($Items -contains 'profile')) {
    Write-StepInfo 'alias groups need the PowerShell profile item; skipped'
    return
  }
  $Groups = @($Items | Where-Object { $_ -ne 'profile' })
  $Targets = Get-ProfileStepTargets -DocumentsDir $DocumentsDir
  if ($Verify) {
    foreach ($Dst in $Targets) { Write-StepInfo ("would copy profile to " + $Dst) }
    Write-StepInfo ("alias groups: " + ($Groups -join ', '))
    return
  }
  $Tmp = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($Tmp, (Get-ProfileGroupText -SrcPath $Src -Groups $Groups), (New-Object Text.UTF8Encoding($false)))
    foreach ($Dst in $Targets) { Install-StepFile $Tmp $Dst }
  } finally {
    Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
  }
}
