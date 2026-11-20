# Hotkeys step: install AutoHotkey v2 through Scoop, copy hotkeys.ahk to
# %USERPROFILE%\hotkeys, create personal.ahk once from the example, add a
# Startup shortcut and start the script. ASCII only, PS 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

function Get-HotkeysAhkExe {
  $Root = ''
  if (Get-Command Get-ScoopRoot -ErrorAction SilentlyContinue) { $Root = Get-ScoopRoot }
  if ($Root -and $Root -ne '') {
    $App = Join-Path $Root (Join-Path 'apps' (Join-Path 'autohotkey' 'current'))
    foreach ($Rel in @((Join-Path 'v2' 'AutoHotkey64.exe'), 'AutoHotkey64.exe', 'AutoHotkey.exe')) {
      $Exe = Join-Path $App $Rel
      if (Test-Path $Exe) { return $Exe }
    }
  }
  $Cmd = Get-Command autohotkey -ErrorAction SilentlyContinue
  if ($Cmd -and $Cmd.Source) { return $Cmd.Source }
  return ''
}

function Invoke-HotkeysStep {
  param([string[]]$Items = @(), [switch]$Verify, [string]$HotkeysHome = '', [switch]$NoLaunch)
  $HomeDir = Get-StepConfigHome -HomeDir $HotkeysHome
  $Dir = Join-Path $HomeDir 'hotkeys'
  $AhkFile = Join-Path $Dir 'hotkeys.ahk'
  $Personal = Join-Path $Dir 'personal.ahk'
  $SrcDir = Join-Path $script:WinStepRepoRoot (Join-Path 'configs' 'windows')
  if ($Verify) { Write-StepInfo ("would install AutoHotkey and copy " + $AhkFile); return }
  Install-StepScoopApp 'extras' 'autohotkey'
  Install-StepFile (Join-Path $SrcDir 'hotkeys.ahk') $AhkFile
  if (Test-Path $Personal) {
    Write-StepOk "$Personal (kept)"
  } else {
    Copy-Item -Force (Join-Path $SrcDir 'personal.ahk.example') $Personal
    Write-StepOk "$Personal (from example, fill in your values)"
  }
  if ($NoLaunch) { return }
  $Exe = Get-HotkeysAhkExe
  if (-not $Exe -or $Exe -eq '') { throw 'AutoHotkey executable not found after scoop install' }
  $Startup = [Environment]::GetFolderPath('Startup')
  $Link = Join-Path $Startup 'hotkeys.lnk'
  $Shell = New-Object -ComObject WScript.Shell
  $Lnk = $Shell.CreateShortcut($Link)
  $Lnk.TargetPath = $Exe
  $Lnk.Arguments = '"' + $AhkFile + '"'
  $Lnk.WorkingDirectory = $Dir
  $Lnk.Save()
  Write-StepOk $Link
  Start-Process -FilePath $Exe -ArgumentList ('"' + $AhkFile + '"') -WorkingDirectory $Dir
  Write-StepOk 'hotkeys started'
}
