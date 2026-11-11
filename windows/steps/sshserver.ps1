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

# What the elevated PowerShell runs. Errors go to $LogPath and exit 1.
function Get-StepSshServerScript {
  param([string]$LogPath = '')
  $Log = $LogPath.Replace("'", "''")
  return @"
`$ErrorActionPreference = 'Stop'
try {
  `$Cap = Get-WindowsCapability -Online | Where-Object { `$_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
  if (`$Cap -eq `$null) { throw 'Windows offers no OpenSSH.Server capability' }
  if (`$Cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name `$Cap.Name | Out-Null }
  Set-Service -Name sshd -StartupType Automatic
  Start-Service -Name sshd
  # Only the local network may connect. The feature's own rule allows any
  # address, so it is narrowed (or created) with RemoteAddress LocalSubnet.
  if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Action Allow -RemoteAddress LocalSubnet
  } else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -RemoteAddress LocalSubnet | Out-Null
  }
  exit 0
} catch {
  try { [IO.File]::WriteAllText('$Log', [string]`$_.Exception.Message) } catch { }
  exit 1
}
"@
}

# Run $Script in Windows PowerShell, elevated unless this one already is.
# Returns the exit code; a declined UAC prompt throws.
function Invoke-StepElevated {
  param([string]$Script = '', [object]$IsAdmin = $null)
  $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
  $ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $Encoded)
  if (Test-StepAdmin -IsAdmin $IsAdmin) {
    $P = Start-Process -FilePath 'powershell.exe' -ArgumentList $ArgList -Wait -PassThru -NoNewWindow
  } else {
    try {
      $P = Start-Process -FilePath 'powershell.exe' -ArgumentList $ArgList -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    } catch { throw 'needs administrator rights and the UAC prompt was declined' }
  }
  return $P.ExitCode
}

function Invoke-SshServerStep {
  param([string[]]$Items = @(), [switch]$Verify, [object]$IsAdmin = $null)
  if (Test-StepSshdRunning) { Write-StepOk 'OpenSSH server (sshd running)'; return }
  if ($Verify) { Write-StepInfo 'would install OpenSSH Server, start sshd and open TCP 22 to the local network (asks for administrator rights)'; return }
  Write-StepInfo 'installing OpenSSH Server: Windows asks for administrator rights'
  $LogPath = Join-Path ([IO.Path]::GetTempPath()) ('sshserver-' + [Guid]::NewGuid().ToString('N') + '.log')
  $Code = Invoke-StepElevated -Script (Get-StepSshServerScript -LogPath $LogPath) -IsAdmin $IsAdmin
  $Why = ''
  if (Test-Path -LiteralPath $LogPath) {
    try { $Why = [IO.File]::ReadAllText($LogPath).Trim() } catch { }
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
  }
  if ($Code -ne 0) {
    if ($Why -eq '') { $Why = 'exit ' + $Code }
    throw ('OpenSSH Server setup failed: ' + $Why)
  }
  if (-not (Test-StepSshdRunning)) { throw 'OpenSSH Server installed but sshd is not running' }
  Write-StepOk 'OpenSSH server (sshd running, TCP 22 open to the local network)'
  Write-StepInfo ('connect from another machine: ssh ' + $env:USERNAME + '@' + $env:COMPUTERNAME)
}
