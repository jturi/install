# SSH server step: add the Windows optional feature "OpenSSH Server", set the
# sshd service to start automatically, start it, and allow TCP 22 inbound from
# the local network only (firewall RemoteAddress LocalSubnet).
# That needs administrator rights: a normal run starts an elevated Windows
# PowerShell (one UAC prompt) and waits for it. Nothing is done when sshd is
# already running. ASCII only, PowerShell 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

# The sshd service, or $null when the OpenSSH Server feature is not installed.
function Get-StepSshdService {
  return (Get-Service -Name 'sshd' -ErrorAction SilentlyContinue)
}

# True when sshd is running and starts with Windows.
function Test-StepSshdRunning {
  $Svc = Get-StepSshdService
  if ($Svc -eq $null) { return $false }
  return ([string]$Svc.Status -eq 'Running' -and [string]$Svc.StartType -eq 'Automatic')
}

# What the elevated PowerShell runs. Errors go to $LogPath and exit 1; exit 2
# means the feature is staged and sshd appears after a restart. Each stage
# writes "<percent>|<text>" to $StatusPath for the progress bar.
function Get-StepSshServerScript {
  param([string]$LogPath = '', [string]$StatusPath = '')
  $Log = $LogPath.Replace("'", "''")
  $Status = $StatusPath.Replace("'", "''")
  return @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
function Set-Stage(`$Pct, `$Text) { try { [IO.File]::WriteAllText('$Status', ([string]`$Pct + '|' + `$Text)) } catch { } }
try {
  Set-Stage 5 'looking up the OpenSSH Server feature'
  `$Cap = Get-WindowsCapability -Online | Where-Object { `$_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
  if (`$Cap -eq `$null) { throw 'Windows offers no OpenSSH.Server capability' }
  if (`$Cap.State -ne 'Installed') {
    Set-Stage 15 'installing the OpenSSH Server feature (can take a few minutes)'
    Add-WindowsCapability -Online -Name `$Cap.Name | Out-Null
  }
  Set-Stage 75 'allowing TCP 22 from the local network'
  # Only the local network may connect. The feature's own rule allows any
  # address, so it is narrowed (or created) with RemoteAddress LocalSubnet.
  if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Action Allow -RemoteAddress LocalSubnet
  } else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -RemoteAddress LocalSubnet | Out-Null
  }
  # Windows can stage the feature until the next restart: it reports
  # Installed, but sshd.exe and the sshd service appear only after a reboot.
  if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) { exit 2 }
  Set-Stage 85 'setting sshd to start automatically'
  Set-Service -Name sshd -StartupType Automatic
  Set-Stage 95 'starting sshd'
  Start-Service -Name sshd
  Set-Stage 100 'done'
  exit 0
} catch {
  try { [IO.File]::WriteAllText('$Log', [string]`$_.Exception.Message) } catch { }
  exit 1
}
"@
}

# The stage the elevated script last wrote: @{ Percent; Text }, or $null when
# there is none yet (or the file is being written).
function Read-StepStatus {
  param([string]$Path = '')
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { $Raw = [IO.File]::ReadAllText($Path).Trim() } catch { return $null }
  if ($Raw -notmatch '^(\d{1,3})\|(.*)$') { return $null }
  return @{ Percent = [Math]::Min(100, [int]$Matches[1]); Text = $Matches[2] }
}

# Percent for the bar: the stage's own value, and during the long feature
# install (15 to 75) a slow creep with the elapsed seconds so it never looks stuck.
function Get-StepProgressPercent {
  param([int]$Stage = 0, [double]$StageSeconds = 0)
  if ($Stage -ne 15) { return $Stage }
  # Half way after 90 s, approaching 74 after that.
  $Creep = 59 * (1 - [Math]::Exp(-$StageSeconds / 130))
  return [int][Math]::Min(74, 15 + $Creep)
}

# Run $Script in Windows PowerShell, elevated unless this one already is, and
# show a progress bar from $StatusPath until it exits. Returns the exit code;
# a declined UAC prompt throws.
function Invoke-StepElevated {
  param([string]$Script = '', [object]$IsAdmin = $null, [string]$StatusPath = '', [string]$Activity = 'Working')
  $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
  $ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $Encoded)
  if (Test-StepAdmin -IsAdmin $IsAdmin) {
    $P = Start-Process -FilePath 'powershell.exe' -ArgumentList $ArgList -PassThru -WindowStyle Hidden
  } else {
    try {
      $P = Start-Process -FilePath 'powershell.exe' -ArgumentList $ArgList -Verb RunAs -PassThru -WindowStyle Hidden
    } catch { throw 'needs administrator rights and the UAC prompt was declined' }
  }
  $Watch = [Diagnostics.Stopwatch]::StartNew()
  $Stage = 0; $Text = 'waiting for administrator rights'; $StageStart = 0
  try {
    while (-not $P.HasExited) {
      $S = Read-StepStatus -Path $StatusPath
      if ($S -ne $null -and $S.Percent -ne $Stage) { $Stage = $S.Percent; $Text = $S.Text; $StageStart = $Watch.Elapsed.TotalSeconds }
      $Pct = Get-StepProgressPercent -Stage $Stage -StageSeconds ($Watch.Elapsed.TotalSeconds - $StageStart)
      $Took = $Watch.Elapsed.ToString('mm\:ss')
      Write-Progress -Activity $Activity -Status ($Text + ' (' + $Took + ')') -PercentComplete $Pct
      Start-Sleep -Milliseconds 500
    }
  } finally {
    Write-Progress -Activity $Activity -Completed
  }
  $P.WaitForExit()
  return $P.ExitCode
}

# Ask before the UAC prompt. Enter or y/Y means yes. -Answer overrides (tests);
# with no console there is nobody to click the prompt, so the answer is no.
function Read-StepSshServerConfirm {
  param([object]$Answer = $null)
  if ($Answer -ne $null) { return ([bool]$Answer) }
  try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
  $Reply = Read-Host 'Install SSH server with admin rights? [Y/n]'
  return ($null -eq $Reply -or $Reply.Trim() -eq '' -or $Reply.Trim() -match '^[Yy]')
}

# Why the check should print SKIPPED instead of MISSING for the SSH server
# ('' when it should not): the user said no, or Windows needs a restart.
$script:StepSshServerSkip = ''

function Invoke-SshServerStep {
  param([string[]]$Items = @(), [switch]$Verify, [object]$IsAdmin = $null, [object]$Answer = $null)
  $script:StepSshServerSkip = ''
  if (Test-StepSshdRunning) { Write-StepOk 'OpenSSH server (sshd running)'; return }
  if ($Verify) { Write-StepInfo 'would install OpenSSH Server, start sshd and open TCP 22 to the local network (asks for administrator rights)'; return }
  if (-not (Test-StepAdmin -IsAdmin $IsAdmin)) {
    if (-not (Read-StepSshServerConfirm -Answer $Answer)) {
      $script:StepSshServerSkip = 'not confirmed'
      Write-StepWarn 'skipped OpenSSH server: it needs administrator rights (run setup again and answer y)'
      return
    }
  }
  Write-StepInfo 'installing OpenSSH Server: confirm the Windows administrator prompt'
  $Base = Join-Path ([IO.Path]::GetTempPath()) ('sshserver-' + [Guid]::NewGuid().ToString('N'))
  $LogPath = $Base + '.log'
  $StatusPath = $Base + '.status'
  $Script = Get-StepSshServerScript -LogPath $LogPath -StatusPath $StatusPath
  try {
    $Code = Invoke-StepElevated -Script $Script -IsAdmin $IsAdmin -StatusPath $StatusPath -Activity 'OpenSSH server'
  } finally {
    Remove-Item -LiteralPath $StatusPath -Force -ErrorAction SilentlyContinue
  }
  $Why = ''
  if (Test-Path -LiteralPath $LogPath) {
    try { $Why = [IO.File]::ReadAllText($LogPath).Trim() } catch { }
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
  }
  if ($Code -eq 2) {
    $script:StepSshServerSkip = 'restart needed'
    Write-StepWarn 'OpenSSH Server is installed but Windows needs a restart: restart, then run setup again to start sshd'
    return
  }
  if ($Code -ne 0) {
    if ($Why -eq '') { $Why = 'exit ' + $Code }
    throw ('OpenSSH Server setup failed: ' + $Why)
  }
  if (-not (Test-StepSshdRunning)) { throw 'OpenSSH Server installed but sshd is not running' }
  Write-StepOk 'OpenSSH server (sshd running, TCP 22 open to the local network)'
  Write-StepInfo ('connect from another machine: ssh ' + $env:USERNAME + '@' + $env:COMPUTERNAME)
}
