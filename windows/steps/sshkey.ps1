# SSH key step: create ~\.ssh\id_ed25519 with the Windows OpenSSH client when
# the user has no key pair. ssh-keygen asks for the passphrase, so it needs a
# console; without one the step only warns. An existing private key is never
# overwritten: a lost .pub is rebuilt from it. setup.ps1 prints the public key
# in green at the end of the run. ASCII only, PowerShell 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

# True when ssh-keygen can ask for a passphrase. -Interactive overrides (tests).
function Test-StepSshConsole {
  param([object]$Interactive = $null)
  if ($Interactive -ne $null) { return ([bool]$Interactive) }
  try { return (-not [Console]::IsInputRedirected) } catch { return $false }
}

# Private key path of a ~\.ssh\*.pub that has its private half, or ''. The
# standard names win, then the first other pair by name.
function Find-StepSshKey {
  param([string]$HomeDir = '')
  $Dir = Join-Path (Get-StepConfigHome -HomeDir $HomeDir) '.ssh'
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return '' }
  foreach ($Name in @('id_ed25519', 'id_ecdsa', 'id_rsa')) {
    $Priv = Join-Path $Dir $Name
    if ((Test-Path -LiteralPath $Priv -PathType Leaf) -and (Test-Path -LiteralPath ($Priv + '.pub') -PathType Leaf)) { return $Priv }
  }
  $Pubs = @()
  try { $Pubs = @(Get-ChildItem -LiteralPath $Dir -Filter '*.pub' -File -ErrorAction Stop | Sort-Object Name) } catch { return '' }
  foreach ($Pub in $Pubs) {
    # -Filter also matches longer extensions through 8.3 short names.
    if ($Pub.Extension -ne '.pub') { continue }
    $Priv = $Pub.FullName.Substring(0, $Pub.FullName.Length - 4)
    if (Test-Path -LiteralPath $Priv -PathType Leaf) { return $Priv }
  }
  return ''
}

function Invoke-SshKeyStep {
  param([string[]]$Items = @(), [switch]$Verify, [string]$HomeDir = '', [object]$Interactive = $null)
  $Found = Find-StepSshKey -HomeDir $HomeDir
  if ($Found -ne '') { Write-StepOk ("SSH key found: " + $Found); return }
  $Dir = Join-Path (Get-StepConfigHome -HomeDir $HomeDir) '.ssh'
  $Key = Join-Path $Dir 'id_ed25519'
  $Pub = $Key + '.pub'
  $HasPriv = Test-Path -LiteralPath $Key
  if ($Verify) {
    if ($HasPriv) { Write-StepInfo ("would rebuild " + $Pub + " from the existing private key") }
    else { Write-StepInfo ("would create " + $Key) }
    return
  }
  if (-not (Test-StepSshConsole -Interactive $Interactive)) { Write-StepWarn 'skipped SSH key: ssh-keygen needs a console for the passphrase'; return }
  if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    throw 'ssh-keygen not found: add the Windows optional feature "OpenSSH Client" (Settings > System > Optional features)'
  }
  if ($HasPriv) {
    # ssh-keygen would ask to overwrite the private key. Rebuild the .pub.
    $global:LASTEXITCODE = 0
    $PubText = @(& ssh-keygen -y -f $Key) -join "`n"
    if ($LASTEXITCODE -or $PubText.Trim() -eq '') { throw "could not read the public key from $Key (exit $LASTEXITCODE)" }
    [IO.File]::WriteAllText($Pub, ($PubText.Trim() + "`n"), (New-Object Text.ASCIIEncoding))
    Write-StepOk ("rebuilt " + $Pub)
    return
  }
  New-Item -ItemType Directory -Path $Dir -Force | Out-Null
  # A .pub with no private half can belong to a key kept elsewhere: keep a copy.
  Backup-StepFile $Pub
  $Comment = $env:USERNAME + '@' + $env:COMPUTERNAME
  $global:LASTEXITCODE = 0
  & ssh-keygen -t ed25519 -f $Key -C $Comment
  if ($LASTEXITCODE) { throw "ssh-keygen failed (exit $LASTEXITCODE)" }
  if ((Find-StepSshKey -HomeDir $HomeDir) -eq '') { throw "ssh-keygen did not create $Key" }
  Write-StepOk ("created " + $Key)
}

# Print the public key in green, for the end of the run.
function Show-StepSshKey {
  param([string]$HomeDir = '')
  $Key = Find-StepSshKey -HomeDir $HomeDir
  if ($Key -eq '') { return }
  $Text = ''
  try { $Text = [IO.File]::ReadAllText($Key + '.pub').Trim() } catch { Write-StepWarn ('cannot read ' + $Key + '.pub: ' + $_.Exception.Message); return }
  Write-Output ''
  Write-Output ('SSH public key ' + $Key + '.pub (add it to GitHub/servers):')
  Write-Host $Text -ForegroundColor Green
}
