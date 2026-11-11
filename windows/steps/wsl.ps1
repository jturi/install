# WSL step: install Ubuntu under WSL. ASCII only, PS 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

function Invoke-WslStep {
  param([string[]]$Items = @(), [switch]$Verify)
  if ($Verify) { Write-StepInfo 'would install WSL Ubuntu'; return }
  wsl --install -d Ubuntu
  Write-StepOk 'WSL (Ubuntu)'
}
