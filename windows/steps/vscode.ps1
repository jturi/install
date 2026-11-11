# VS Code step: install VS Code, then install extensions from the repo list.
# ASCII only, PowerShell 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

function Invoke-VscodeStep {
  param([string[]]$Items = @(), [switch]$Verify)
  if ($Verify) { Write-StepInfo 'would install VS Code and extensions'; return }
  scoop install extras/vscode
  $List = Join-Path $script:WinStepRepoRoot (Join-Path 'configs' (Join-Path 'windows' 'vscode_extensions.txt'))
  if (Test-Path $List) {
    $Text = [IO.File]::ReadAllText($List)
    $ListLines = $Text -split "`n"
    foreach ($Raw in $ListLines) {
      $Line = $Raw
      if ($Line.EndsWith("`r")) { $Line = $Line.Substring(0, $Line.Length - 1) }
      if ($Line -match '^\s*$') { continue }
      if ($Line.StartsWith('#')) { continue }
      & code --install-extension $Line
    }
  }
  Write-StepOk 'VS Code'
}
