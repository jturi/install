# Flameshot step: install Flameshot via Scoop. ASCII only, PS 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

function Invoke-FlameshotStep {
  param([string[]]$Items = @(), [switch]$Verify)
  if ($Verify) { Write-StepInfo 'would install Flameshot'; return }
  scoop install extras/flameshot
  Write-StepOk 'Flameshot'
}
