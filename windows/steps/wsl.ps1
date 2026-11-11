# WSL step: install Ubuntu under WSL. ASCII only, PS 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

function Invoke-WslStep {
  param([string[]]$Items = @(), [switch]$Verify)
  # An installed Ubuntu is left alone: wsl --install would fail with
  # Wsl/InstallDistro/ERROR_ALREADY_EXISTS.
  if (Test-WslUbuntuInstalled) { Write-StepOk 'WSL (Ubuntu, already installed)'; return }
  if ($Verify) { Write-StepInfo 'would install WSL Ubuntu'; return }
  # --no-launch: Ubuntu's first-run setup (Linux user, password) is
  # interactive and garbles inside this run; the user does it in Ubuntu itself.
  $global:LASTEXITCODE = 0
  & wsl.exe --install -d Ubuntu --no-launch
  $Code = $LASTEXITCODE
  if (Test-WslUbuntuInstalled) {
    Write-StepOk 'WSL (Ubuntu)'
    Add-StepTodo 'open Ubuntu from the Start menu once to create your Linux user'
    return
  }
  if ($Code -ne 0) {
    throw "wsl --install -d Ubuntu failed (exit $Code): run as administrator and check that virtualization is enabled"
  }
  # Exit 0 without a listed distro: the install finishes after a restart.
  $Msg = 'WSL Ubuntu is not ready yet: restart Windows, then open Ubuntu once to finish its setup'
  Write-StepWarn $Msg
  Add-StepTodo $Msg
}
