# Git identity step: the GitHub username and the email used on commits. Both are
# kept in the bootstrap config (github.user, git.email), even when empty, and set
# as git's global user.name (the GitHub username) and user.email.
# The next run reads them back: a saved value is offered as the default, and the
# user keeps it (Y, the default) or changes it (n).
# ASCII only, PowerShell 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

# One prompt, in its own function so tests can replace it.
function Read-StepLine($Prompt) { return (Read-Host $Prompt) }

# Ask until something is typed (3 tries). Returns '' if still blank.
function Read-StepValue($Prompt) {
  for ($Try = 1; $Try -le 3; $Try++) {
    $Value = ([string](Read-StepLine $Prompt)).Trim()
    if ($Value -ne '') { return $Value }
    # Write-Host, not Write-StepWarn: anything written to the output would be
    # returned together with the value.
    Write-Host ('  [!!] ' + $Prompt + ' is required')
  }
  return ''
}

# A saved value: offer it as the default. Y (or Enter) keeps it; n asks for a
# new one, and a blank new answer keeps the old value.
function Read-StepKeep($Label, $Current) {
  $Answer = ([string](Read-StepLine ($Label + ' [' + $Current + '], keep it? [Y/n]'))).Trim()
  if ($Answer -eq '' -or $Answer -match '^(y|yes)$') { return $Current }
  $New = ([string](Read-StepLine ('New ' + $Label + ' (Enter keeps ' + $Current + ')'))).Trim()
  if ($New -eq '') { return $Current }
  return $New
}

# Value of a git global setting, or '' when git is missing or the key is unset.
function Get-StepGitGlobal($Key) {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
  $global:LASTEXITCODE = 0
  $Val = & git config --global --get $Key
  if ($LASTEXITCODE) { return '' }
  $Text = [string]$Val
  if (-not $Text) { return '' }
  return $Text.Trim()
}

function Invoke-GitIdentityStep {
  param([string]$ConfigPath = '', [string]$User = '', [string]$Email = '', [switch]$Verify, [switch]$NoPrompt, [switch]$Unattended, [object]$Interactive = $null)
  $UserGiven = ($User -ne '')
  $EmailGiven = ($Email -ne '')
  # Default: the saved config value, else git's global setting.
  if (-not $UserGiven) { $User = Get-ConfigValue -Path $ConfigPath -Key 'github.user' }
  if (-not $UserGiven -and $User -eq '') { $User = Get-StepGitGlobal 'user.name' }
  if (-not $EmailGiven) { $Email = Get-ConfigValue -Path $ConfigPath -Key 'git.email' }
  if (-not $EmailGiven -and $Email -eq '') { $Email = Get-StepGitGlobal 'user.email' }

  if ($Verify) {
    Write-StepInfo ('would use git identity ' + $User + ' <' + $Email + '> (asks first when run from a console)')
    return
  }

  # NoPrompt: only apply what is saved (the second call, once git is installed).
  # Unattended (setup -Yes): use what is saved and ask nothing, but still warn.
  $CanAsk = (-not $NoPrompt) -and (-not $Unattended) -and (Test-StepSshConsole -Interactive $Interactive)
  if ($CanAsk) {
    if (-not $UserGiven) {
      if ($User -ne '') { $User = Read-StepKeep 'GitHub username' $User }
      else { $User = Read-StepValue 'GitHub username' }
    }
    if (-not $EmailGiven) {
      if ($Email -ne '') { $Email = Read-StepKeep 'Email for git commits' $Email }
      else { $Email = ([string](Read-StepLine 'Email for git commits (Enter to skip)')).Trim() }
    }
  }
  elseif (-not $NoPrompt -and ($User -eq '' -or $Email -eq '')) {
    if ($Unattended) { Write-StepWarn 'GitHub username or email not set: run setup without -Yes to enter them' }
    else { Write-StepWarn 'GitHub username or email not set: run setup from a console to enter them' }
  }

  # Save every value, even an empty email, so the next run reads it back.
  Set-ConfigValue -Path $ConfigPath -Key 'github.user' -Value $User
  Set-ConfigValue -Path $ConfigPath -Key 'git.email' -Value $Email

  if (-not $NoPrompt -and ($User -eq '' -or $Email -eq '')) {
    Write-StepWarn ('saved without a value: GitHub username [' + $User + '], email [' + $Email + ']; run setup again to fill it in')
  }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-StepInfo 'git is not on PATH yet: the identity is saved and is applied on the next run'
    return
  }
  # Apply only the values that are set; never write an empty one to git.
  foreach ($Pair in @(@('user.name', $User), @('user.email', $Email))) {
    if ($Pair[1] -eq '') { continue }
    if ((Get-StepGitGlobal $Pair[0]) -eq $Pair[1]) { continue }
    $global:LASTEXITCODE = 0
    & git config --global $Pair[0] $Pair[1]
    if ($LASTEXITCODE) { throw ('git config --global ' + $Pair[0] + ' failed (exit ' + $LASTEXITCODE + ')') }
  }
  if ($User -ne '' -and $Email -ne '') {
    Write-StepOk ('git identity: ' + $User + ' <' + $Email + '>')
  }
}
