# PowerShell tests: catalog, config read/write, Get-ScoopRoot, menu.
# Task 6 (reduced) + Task 7 per the lead plan. ASCII only: the non-ASCII
# save path below uses [char]0xE9.
# Stand-in: docker run --rm -v "$PWD":/w -w /w -e USERPROFILE=/tmp/u -e TEMP=/tmp <image> pwsh -NoProfile -File tests/test_windows.ps1
$ErrorActionPreference = 'Stop'
$Failures = 0

function Check($Name, $Want, $Got) {
  if ("$Got" -eq "$Want") {
    Write-Output "PASS $Name"
  } else {
    Write-Output "FAIL ${Name}: want [${Want}] got [${Got}]"
    $script:Failures = $script:Failures + 1
  }
}

$Root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$FixtureDir = Join-Path (Join-Path $Root 'tests') 'fixtures'
$Fixture = Join-Path $FixtureDir 'catalog.txt'
$ConfigInput = Join-Path $FixtureDir 'config.input'
$ConfigExpected = Join-Path $FixtureDir 'config.expected'
$LibPath = Join-Path (Join-Path $Root 'windows') 'lib.ps1'
$MenuPath = Join-Path (Join-Path $Root 'windows') 'menu.ps1'
. $LibPath
. $MenuPath

function Get-CatalogKeys($Catalog) {
  $Keys = @()
  foreach ($Row in $Catalog) { $Keys += ($Row.Group + '.' + $Row.Item) }
  return ($Keys -join ' ')
}

function Get-WorkDir {
  $Base = $env:TEMP
  if (-not $Base) { $Base = [IO.Path]::GetTempPath() }
  $Dir = Join-Path $Base ('install-test-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $Dir -Force | Out-Null
  return $Dir
}

# Catalog filtering: only windows rows.
$Catalog = Import-Catalog -Path $Fixture
Check 'catalog-keys' 'terminals.cmder win-apps.vlc win-setup.profile' (Get-CatalogKeys $Catalog)
$Cmder = @($Catalog | Where-Object { $_.Item -eq 'cmder' })[0]
Check 'catalog-action' 'scoop:main/cmder' $Cmder.Action
Check 'catalog-key' 'terminals.cmder' $Cmder.Key
Check 'catalog-defaults' 'False True True' ((@($Catalog | ForEach-Object { $_.Selected })) -join ' ')

# Malformed line throws with its line number.
$Work = Get-WorkDir
try {
  $BadText = "# comment`nbad|line`n"
  [IO.File]::WriteAllText((Join-Path $Work 'bad.txt'), $BadText, (New-Object Text.UTF8Encoding($false)))
  Import-Catalog -Path (Join-Path $Work 'bad.txt') | Out-Null
  Check 'catalog-malformed-throws' 'throw' 'no throw'
} catch {
  $Msg = $_.Exception.Message
  if ($Msg -match 'line 2') { Check 'catalog-malformed-line' 'line 2' 'line 2' }
  else { Check 'catalog-malformed-line' 'line 2' $Msg }
}

# Bad config values warn and use defaults.
$Catalog2 = Import-Catalog -Path $Fixture
$BadCfg = Join-Path $Work 'bad.cfg'
[IO.File]::WriteAllText($BadCfg, "terminals.cmder=2`nconfigs.tmux`n=1`n", (New-Object Text.UTF8Encoding($false)))
$WarnText = & { Import-Selection -Path $BadCfg -Catalog $Catalog2 } 3>&1 2>&1 | Out-String
$Zsh = @($Catalog2 | Where-Object { $_.Key -eq 'terminals.cmder' })[0]
Check 'config-bad-value-default' 'False' ([string]$Zsh.Selected)
$WarnCount = ([regex]::Matches($WarnText, 'ignoring')).Count
Check 'config-bad-lines-warn' '3' "$WarnCount"

# Key match is case-sensitive like bash: wrong case stays extra, item keeps default.
$Catalog3b = Import-Catalog -Path $Fixture
$CaseCfg = Join-Path $Work 'case.cfg'
[IO.File]::WriteAllText($CaseCfg, "Terminals.Cmder=1`n", (New-Object Text.UTF8Encoding($false)))
$CaseExtra = Import-Selection -Path $CaseCfg -Catalog $Catalog3b
$CmderSel = @($Catalog3b | Where-Object { $_.Key -eq 'terminals.cmder' })[0]
Check 'config-case-default' 'False' ([string]$CmderSel.Selected)
Check 'config-case-extra' 'Terminals.Cmder=1' ($CaseExtra -join ' ')

# De-duplication is case-sensitive like bash sort -u: A.b and a.b are both kept.
$CaseCat = Import-Catalog -Path $Fixture
$CaseDupPath = Join-Path $Work 'casedup.cfg'
Save-Selection -Path $CaseDupPath -Catalog $CaseCat -Extra @('A.b=1', 'a.b=1')
$CaseDupText = [IO.File]::ReadAllText($CaseDupPath)
Check 'config-casedup-kept' 'True' ([string]($CaseDupText.Contains("A.b=1`n") -and $CaseDupText.Contains("a.b=1`n")))

# BOM plus CRLF reads every key.
$Catalog3 = Import-Catalog -Path $Fixture
$Extra3 = Import-Selection -Path $ConfigInput -Catalog $Catalog3
$Vals = @()
foreach ($Row in $Catalog3) {
  if ($Row.Key -eq 'terminals.cmder' -or $Row.Key -eq 'win-apps.vlc' -or $Row.Key -eq 'win-setup.profile') {
    $Vals += ($Row.Key + '=' + $Row.Selected)
  }
}
Check 'config-bom-crlf-keys' 'terminals.cmder=True win-apps.vlc=False win-setup.profile=True' ($Vals -join ' ')

# Save under a path with a space and a non-ASCII character works.
$SaveDir = Join-Path $Work ('a b' + [char]0xE9)
$BootDir = Join-Path (Join-Path $SaveDir '.local') 'bootstrap'
$SavePath = Join-Path $BootDir 'config'
$Catalog4 = Import-Catalog -Path $Fixture
$Extra4 = Import-Selection -Path $ConfigInput -Catalog $Catalog4
Save-Selection -Path $SavePath -Catalog $Catalog4 -Extra $Extra4
$SavedBytes = [IO.File]::ReadAllBytes($SavePath)
$ExpectedBytes = [IO.File]::ReadAllBytes($ConfigExpected)
$Same = ($SavedBytes.Length -eq $ExpectedBytes.Length)
if ($Same) {
  for ($i = 0; $i -lt $SavedBytes.Length; $i++) {
    if ($SavedBytes[$i] -ne $ExpectedBytes[$i]) { $Same = $false; break }
  }
}
Check 'config-save-bytes' 'True' ([string]$Same)

# Unknown keys (other platforms) survive.
Check 'config-unknown-survives' 'shell.zsh=1 shell.less=1 configs.tmux=0 terminals.ghostty=1 terminals.wezterm-wsl=0 other.thing=1' ($Extra4 -join ' ')

# Failed save throws, keeps the old file byte for byte, leaves no temp file.
$FailDir = Join-Path $Work 'failparent'
[IO.File]::WriteAllText($FailDir, 'x', (New-Object Text.UTF8Encoding($false)))
$FailCfg = Import-Catalog -Path $Fixture
$FailPath = Join-Path (Join-Path $FailDir 'sub') 'config'
$OldText = "old=1`n"
$Threw = $false
try {
  Save-Selection -Path $FailPath -Catalog $FailCfg -Extra @()
} catch { $Threw = $true }
Check 'save-fails-throws' 'True' ([string]$Threw)
Check 'save-fails-parent-untouched' 'x' ([IO.File]::ReadAllText($FailDir))
Check 'save-fails-no-tmp' 'True' ([string](-not (Test-Path "$FailPath.tmp.$PID")))

# Get-ScoopRoot order: SCOOP, then scoop command, then USERPROFILE.
$SavedScoop = $env:SCOOP
$SavedProfile = $env:USERPROFILE
$env:SCOOP = Join-Path $Work 'scoop-env'
Check 'scooproot-env' $env:SCOOP (Get-ScoopRoot)
Remove-Item Env:SCOOP
$env:USERPROFILE = Join-Path $Work 'someprofile'
$CmdRoot = Join-Path $Work 'scoop-cmd'
New-Item -ItemType Directory -Path $CmdRoot -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $CmdRoot 'scoop.ps1') -Force | Out-Null
Check 'scooproot-command' $CmdRoot (Get-ScoopRoot -ScoopCommand (Join-Path $CmdRoot 'scoop.ps1'))
Check 'scooproot-profile' (Join-Path $env:USERPROFILE 'scoop') (Get-ScoopRoot -ScoopCommand (Join-Path $Work 'missing/scoop.ps1'))
$env:USERPROFILE = ''
$env:HOME = Join-Path $Work 'homeprofile'
Check 'scooproot-home' (Join-Path $env:HOME 'scoop') (Get-ScoopRoot -ScoopCommand (Join-Path $Work 'missing/scoop.ps1'))
if ($SavedScoop) { $env:SCOOP = $SavedScoop }
$env:USERPROFILE = $SavedProfile

# Task 8: steps and setup.ps1. Stub scoop before dot-sourcing.
# $global:ScoopFail lists commands (e.g. 'install extras/vlc') that exit 1.
$global:ScoopFail = @()
function global:scoop {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ScoopArgs)
  $Cmd = ($ScoopArgs -join ' ')
  $global:ScoopLog += $Cmd; $global:ScoopBuckets += $Cmd
  if ($global:ScoopFail -contains $Cmd) { $global:LASTEXITCODE = 1; return }
  $global:LASTEXITCODE = 0
  if ($ScoopArgs.Count -ge 3 -and $ScoopArgs[0] -eq 'bucket' -and $ScoopArgs[1] -eq 'add') {
    New-Item -ItemType Directory -Path (Join-Path (Get-ScoopRoot) (Join-Path 'buckets' $ScoopArgs[2])) -Force | Out-Null
  }
}

function cmp-bytes($A, $B) {
  if (-not (Test-Path $A)) { return 'missing-a' }
  if (-not (Test-Path $B)) { return 'missing-b' }
  $X = [IO.File]::ReadAllBytes($A)
  $Y = [IO.File]::ReadAllBytes($B)
  if ($X.Length -ne $Y.Length) { return 'length' }
  for ($i = 0; $i -lt $X.Length; $i++) { if ($X[$i] -ne $Y[$i]) { return 'differs' } }
  return 'same'
}

function New-StepCatalog {
  $Rows = @()
  $Rows += (New-Object PSObject -Property @{ Group = 'dev-tools'; Item = '7zip'; Label = '7-Zip'; Default = 'on'; Action = 'scoop:main/7zip'; Key = 'dev-tools.7zip'; Selected = $true; New = $false })
  $Rows += (New-Object PSObject -Property @{ Group = 'win-apps'; Item = 'vlc'; Label = 'VLC'; Default = 'off'; Action = 'scoop:extras/vlc'; Key = 'win-apps.vlc'; Selected = $false; New = $false })
  return $Rows
}

$StepsDir = Join-Path (Join-Path $Root 'windows') 'steps'
. (Join-Path $StepsDir 'scoop.ps1')
. (Join-Path $StepsDir 'preflight.ps1')
. (Join-Path $StepsDir 'vscode.ps1')
. (Join-Path $StepsDir 'flameshot.ps1')
. (Join-Path $StepsDir 'wsl.ps1')
. (Join-Path $StepsDir 'wezterm.ps1')

# The scoop stub makes bucket folders under Get-ScoopRoot: keep that root in
# $Work for all step tests, never in the real %USERPROFILE%\scoop.
$SavedStepScoop = $env:SCOOP
$env:SCOOP = Join-Path $Work 'scoop-steps'
$T8 = New-StepCatalog
$global:ScoopLog = @(); $global:ScoopBuckets = @()
Invoke-ScoopStep -Catalog $T8
Check 'step-scoop-installs-ticked' 'True' ([string]($global:ScoopLog -contains 'install main/7zip'))
Check 'step-scoop-skips-unticked' 'False' ([string]($global:ScoopLog -contains 'install extras/vlc'))
Check 'step-scoop-adds-bucket' 'True' ([string]($global:ScoopLog -contains 'bucket add main'))
Check 'step-scoop-always-git-make' 'True' ([string](($global:ScoopLog -contains 'install main/git') -and ($global:ScoopLog -contains 'install main/make')))
Check 'step-scoop-needs-no-extras-bucket' 'False' ([string]($global:ScoopLog -contains 'bucket add extras'))

$T8b = New-StepCatalog
$global:ScoopLog = @()
Invoke-ScoopStep -Catalog $T8b -Verify
Check 'step-scoop-verify-no-install' '0' ([string]$global:ScoopLog.Count)

# Backups taken within the same second never overwrite each other.
$BkDir = Join-Path $Work 'bk'
New-Item -ItemType Directory -Path $BkDir -Force | Out-Null
$BkFile = Join-Path $BkDir 'f.txt'
Set-Content -Path $BkFile -Value 'one'
Backup-StepFile $BkFile
Backup-StepFile $BkFile
Check 'backup-same-second-kept' '2' ([string]@(Get-ChildItem -Path $BkDir -Filter 'f.txt.bak.*').Count)
# Install-StepFile writes through a temp file and leaves none behind.
$InSrc = Join-Path $BkDir 'src.txt'
Set-Content -Path $InSrc -Value 'new'
Install-StepFile $InSrc $BkFile | Out-Null
Check 'install-file-content' 'new' ((Get-Content -Path $BkFile) -join '')
Check 'install-file-no-temp' '0' ([string]@(Get-ChildItem -Path $BkDir -Filter '*.tmp*').Count)

# Save-Selection: two changes within one second keep two backups.
$SvCfg = Join-Path $Work 'sv-config'
$SvCat = Import-Catalog -Path $Fixture
Save-Selection -Path $SvCfg -Catalog $SvCat
$SvCat[0].Selected = -not $SvCat[0].Selected
Save-Selection -Path $SvCfg -Catalog $SvCat
$SvCat[0].Selected = -not $SvCat[0].Selected
Save-Selection -Path $SvCfg -Catalog $SvCat
Check 'save-selection-same-second-backups' '2' ([string]@(Get-ChildItem -Path $Work -Filter 'sv-config.bak.*').Count)

# The token typed at the prompt is zeroed and freed after use.
Check 'bootstrap-frees-token' 'True' ([string]((Get-Content -Raw (Join-Path $Root 'bootstrap.ps1')) -match 'ZeroFreeBSTR'))

# git first (bucket add needs it), then buckets, then scoop update, then apps.
# Fresh Scoop root that has only the main bucket, like a new Scoop install.
$env:SCOOP = Join-Path $Work 'scoop-order'
New-Item -ItemType Directory -Path (Join-Path $env:SCOOP (Join-Path 'buckets' 'main')) -Force | Out-Null
$T8c = New-StepCatalog
@($T8c | Where-Object { $_.Item -eq 'vlc' })[0].Selected = $true
$global:ScoopLog = @()
Invoke-ScoopStep -Catalog $T8c | Out-Null
Check 'step-scoop-order' 'install main/git|bucket add extras|update|install main/7zip|install extras/vlc|install main/make' ($global:ScoopLog -join '|')

# A failed install fails the step but still tries the other apps.
$global:ScoopLog = @(); $global:ScoopFail = @('install extras/vlc')
$ScoopErr = try { Invoke-ScoopStep -Catalog $T8c | Out-Null; '' } catch { $_.Exception.Message }
$global:ScoopFail = @()
Check 'step-scoop-failure-throws' 'scoop install failed: extras/vlc' $ScoopErr
Check 'step-scoop-failure-continues' 'True' ([string]($global:ScoopLog -contains 'install main/make'))

# A bucket that cannot be added fails its apps once; the other apps install.
$env:SCOOP = Join-Path $Work 'scoop-badbucket'
New-Item -ItemType Directory -Path (Join-Path $env:SCOOP (Join-Path 'buckets' 'main')) -Force | Out-Null
$global:ScoopLog = @(); $global:ScoopFail = @('bucket add extras')
$BucketErr = try { Invoke-ScoopStep -Catalog $T8c | Out-Null; '' } catch { $_.Exception.Message }
$global:ScoopFail = @()
Check 'step-scoop-bad-bucket-throws' 'scoop install failed: extras/vlc' $BucketErr
Check 'step-scoop-bad-bucket-log' 'install main/git|bucket add extras|update|install main/7zip|install main/make' ($global:ScoopLog -join '|')

# A second run adds no bucket again: every bucket folder is already there.
$env:SCOOP = Join-Path $Work 'scoop-order'
$global:ScoopLog = @()
Invoke-ScoopStep -Catalog $T8c | Out-Null
Check 'step-scoop-rerun-no-bucket-add' '0' ([string]@($global:ScoopLog | Where-Object { $_ -like 'bucket add*' }).Count)
$env:SCOOP = Join-Path $Work 'scoop-steps'

$SpaceHome = Join-Path $Work 'a b'
New-Item -ItemType Directory -Path $SpaceHome -Force | Out-Null
$WezSrc = Join-Path (Join-Path (Join-Path $Root 'configs') 'wezterm') 'windows.lua'
$global:ScoopLog = @()
Invoke-WeztermStep -Items @('wezterm') -WeztermHome $SpaceHome -SrcPath $WezSrc
Check 'step-wezterm-adds-extras' 'True' ([string]($global:ScoopLog -contains 'bucket add extras'))
# VS Code: only missing extensions install; a failed one fails the step.
$global:CodeLog = @(); $global:CodeFail = @()
function global:code {
  $global:LASTEXITCODE = 0
  if ($args[0] -eq '--list-extensions') { Write-Output 'MS-VSCODE.PowerShell'; return }
  $global:CodeLog += ($args -join ' ')
  if ($global:CodeFail -contains $args[1]) { $global:LASTEXITCODE = 1 }
}
$ExtList = Join-Path $Work 'ext.txt'
[IO.File]::WriteAllText($ExtList, "# c`r`nms-vscode.powershell`r`n`r`n  a.b  `r`na.b`r`nc.d`r`n", (New-Object Text.UTF8Encoding($false)))
Check 'step-vscode-list-parse' 'ms-vscode.powershell a.b c.d' ((Get-VscodeStepExtensions -ListPath $ExtList) -join ' ')
Invoke-VscodeStep -Items @('vscode') -ListPath $ExtList | Out-Null
Check 'step-vscode-skips-installed' '--install-extension a.b|--install-extension c.d' ($global:CodeLog -join '|')
$global:CodeLog = @(); $global:CodeFail = @('a.b')
$CodeErr = try { Invoke-VscodeStep -Items @('vscode') -ListPath $ExtList 3>$null | Out-Null; '' } catch { $_.Exception.Message }
$global:CodeFail = @()
Check 'step-vscode-failure-throws' 'VS Code extensions failed: a.b' $CodeErr
Check 'step-vscode-failure-continues' 'True' ([string]($global:CodeLog -contains '--install-extension c.d'))
Remove-Item Function:\code

Check 'step-wezterm-copies-config' 'same' (cmp-bytes (Join-Path $SpaceHome '.wezterm.lua') (Join-Path (Join-Path (Join-Path $Root 'configs') 'wezterm') 'windows.lua'))

. (Join-Path $StepsDir 'profile.ps1')
. (Join-Path $StepsDir 'hotkeys.ps1')
$ProfSrc = Join-Path (Join-Path (Join-Path $Root 'configs') 'windows') 'profile.ps1'
$DocsDir = Join-Path $Work 'Docs a b'
$Ps5Profile = Join-Path (Join-Path $DocsDir 'WindowsPowerShell') 'Microsoft.PowerShell_profile.ps1'
$Ps7Profile = Join-Path (Join-Path $DocsDir 'PowerShell') 'Microsoft.PowerShell_profile.ps1'
New-Item -ItemType Directory -Path (Split-Path $Ps5Profile -Parent) -Force | Out-Null
[IO.File]::WriteAllText($Ps5Profile, '# old profile', (New-Object Text.UTF8Encoding($false)))
Invoke-ProfileStep -Items @('profile') -DocumentsDir $DocsDir | Out-Null
Check 'step-profile-copies-ps5' 'same' (cmp-bytes $Ps5Profile $ProfSrc)
Check 'step-profile-copies-ps7' 'same' (cmp-bytes $Ps7Profile $ProfSrc)
Check 'step-profile-backs-up-old' '1' ([string]@(Get-ChildItem -Path (Split-Path $Ps5Profile -Parent) -Filter '*.bak.*').Count)
$VerifyDocs = Join-Path $Work 'verify-docs'
Invoke-ProfileStep -Items @('profile') -DocumentsDir $VerifyDocs -Verify | Out-Null
Check 'step-profile-verify-no-copy' 'False' ([string](Test-Path $VerifyDocs))

$AhkHome = Join-Path $Work 'ahk home'
$AhkSrcDir = Join-Path (Join-Path $Root 'configs') 'windows'
$global:ScoopLog = @()
Invoke-HotkeysStep -Items @('hotkeys') -HotkeysHome $AhkHome -NoLaunch | Out-Null
$AhkDir = Join-Path $AhkHome 'hotkeys'
Check 'step-hotkeys-installs-ahk' 'True' ([string]($global:ScoopLog -contains 'install extras/autohotkey'))
Check 'step-hotkeys-copies-script' 'same' (cmp-bytes (Join-Path $AhkDir 'hotkeys.ahk') (Join-Path $AhkSrcDir 'hotkeys.ahk'))
Check 'step-hotkeys-creates-personal' 'same' (cmp-bytes (Join-Path $AhkDir 'personal.ahk') (Join-Path $AhkSrcDir 'personal.ahk.example'))
[IO.File]::WriteAllText((Join-Path $AhkDir 'personal.ahk'), '; mine', (New-Object Text.UTF8Encoding($false)))
Invoke-HotkeysStep -Items @('hotkeys') -HotkeysHome $AhkHome -NoLaunch | Out-Null
Check 'step-hotkeys-keeps-personal' '; mine' ([IO.File]::ReadAllText((Join-Path $AhkDir 'personal.ahk')))

# SSH key: find an existing pair, plan a new key, print the public key.
. (Join-Path $StepsDir 'sshkey.ps1')
$SshHome = Join-Path $Work 'ssh home'
Check 'step-sshkey-none' '' (Find-StepSshKey -HomeDir $SshHome)
$SshDir = Join-Path $SshHome '.ssh'
New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $SshDir 'lonely.pub'), 'ssh-ed25519 AAAA lonely', (New-Object Text.UTF8Encoding($false)))
Check 'step-sshkey-pub-without-private' '' (Find-StepSshKey -HomeDir $SshHome)
$SshPlan = Invoke-SshKeyStep -Items @('ssh-key') -Verify -HomeDir $SshHome | Out-String
Check 'step-sshkey-verify-plans' 'True' ([string]($SshPlan -match 'would create'))
[IO.File]::WriteAllText((Join-Path $SshDir 'id_ed25519'), 'private', (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $SshDir 'id_ed25519.pub'), "ssh-ed25519 AAAATEST user@host`n", (New-Object Text.UTF8Encoding($false)))
Check 'step-sshkey-found' (Join-Path $SshDir 'id_ed25519') (Find-StepSshKey -HomeDir $SshHome)
$SshShown = & { Show-StepSshKey -HomeDir $SshHome } 6>&1 | Out-String
Check 'step-sshkey-show-prints-key' 'True' ([string]($SshShown -match 'ssh-ed25519 AAAATEST user@host'))
# The standard name wins over a pair that sorts before it.
[IO.File]::WriteAllText((Join-Path $SshDir 'aaa'), 'private', (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $SshDir 'aaa.pub'), 'ssh-ed25519 AAAA aaa', (New-Object Text.UTF8Encoding($false)))
Check 'step-sshkey-prefers-standard' (Join-Path $SshDir 'id_ed25519') (Find-StepSshKey -HomeDir $SshHome)

# ssh-keygen stub: logs its arguments; -y prints a public key, else it writes
# the pair named by -f.
$global:KeygenLog = @()
function global:ssh-keygen {
  $global:KeygenLog += ($args -join ' ')
  $global:LASTEXITCODE = 0
  if ($args -contains '-y') { Write-Output 'ssh-ed25519 AAAAREBUILT'; return }
  $F = $args[[Array]::IndexOf($args, '-f') + 1]
  [IO.File]::WriteAllText($F, 'private', (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText(($F + '.pub'), "ssh-ed25519 AAAANEW`n", (New-Object Text.UTF8Encoding($false)))
}
# No console: warn and leave everything alone.
$NoConHome = Join-Path $Work 'ssh nocon'
Invoke-SshKeyStep -Items @('ssh-key') -HomeDir $NoConHome -Interactive $false 3>$null | Out-Null
Check 'step-sshkey-no-console-skips' '0' ([string]$global:KeygenLog.Count)
# Console: create the pair; a second run finds it and does not run ssh-keygen.
Invoke-SshKeyStep -Items @('ssh-key') -HomeDir $NoConHome -Interactive $true | Out-Null
Check 'step-sshkey-creates' (Join-Path (Join-Path $NoConHome '.ssh') 'id_ed25519') (Find-StepSshKey -HomeDir $NoConHome)
Invoke-SshKeyStep -Items @('ssh-key') -HomeDir $NoConHome -Interactive $true | Out-Null
Check 'step-sshkey-idempotent' '1' ([string]$global:KeygenLog.Count)
# A private key with no .pub is never overwritten: its .pub is rebuilt.
$PrivHome = Join-Path $Work 'ssh privonly'
$PrivKey = Join-Path (Join-Path $PrivHome '.ssh') 'id_ed25519'
New-Item -ItemType Directory -Path (Join-Path $PrivHome '.ssh') -Force | Out-Null
[IO.File]::WriteAllText($PrivKey, 'keep me', (New-Object Text.UTF8Encoding($false)))
$global:KeygenLog = @()
Invoke-SshKeyStep -Items @('ssh-key') -HomeDir $PrivHome -Interactive $true | Out-Null
Check 'step-sshkey-private-kept' 'keep me' ([IO.File]::ReadAllText($PrivKey))
Check 'step-sshkey-pub-rebuilt' "ssh-ed25519 AAAAREBUILT`n" ([IO.File]::ReadAllText($PrivKey + '.pub'))
Check 'step-sshkey-rebuild-only' ('-y -f ' + $PrivKey) ($global:KeygenLog -join '|')
# A .pub with no private half is backed up before ssh-keygen replaces it.
$PubHome = Join-Path $Work 'ssh pubonly'
New-Item -ItemType Directory -Path (Join-Path $PubHome '.ssh') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path (Join-Path $PubHome '.ssh') 'id_ed25519.pub'), 'ssh-ed25519 AAAAELSEWHERE', (New-Object Text.UTF8Encoding($false)))
Invoke-SshKeyStep -Items @('ssh-key') -HomeDir $PubHome -Interactive $true | Out-Null
$PubBak = @(Get-ChildItem -Path (Join-Path $PubHome '.ssh') -Filter 'id_ed25519.pub.bak.*')
Check 'step-sshkey-lonely-pub-backup' 'ssh-ed25519 AAAAELSEWHERE' $(if ($PubBak.Count -eq 1) { [IO.File]::ReadAllText($PubBak[0].FullName) } else { 'backups: ' + $PubBak.Count })
Remove-Item Function:\ssh-keygen

# Check step: OK for what is there, MISSING for what is not, count in -Missing.
. (Join-Path $StepsDir 'check.ps1')
function global:git { }
function global:make { }
$env:SCOOP = Join-Path $Work 'scoop-check'
$CheckApp = Join-Path $env:SCOOP (Join-Path 'apps' (Join-Path '7zip' '24.08'))
New-Item -ItemType Directory -Path $CheckApp -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $CheckApp 'install.json'), '{}', (New-Object Text.UTF8Encoding($false)))
# A version folder with no install.json is a failed install: MISSING.
New-Item -ItemType Directory -Path (Join-Path $env:SCOOP (Join-Path 'apps' (Join-Path 'vlc' '3.0'))) -Force | Out-Null
$CheckCat = New-StepCatalog
@($CheckCat | Where-Object { $_.Item -eq 'vlc' })[0].Selected = $true
$CheckCat += (New-Object PSObject -Property @{ Group = 'win-setup'; Item = 'ssh-key'; Label = 'SSH key (ed25519)'; Default = 'on'; Action = 'step:ssh-key'; Key = 'win-setup.ssh-key'; Selected = $true; New = $false })
$CheckMissing = -1
$CheckOut = Invoke-CheckStep -Catalog $CheckCat -HomeDir $SshHome -Missing ([ref]$CheckMissing) | Out-String
Check 'step-check-ok-git' 'True' ([string]($CheckOut -match '(?m)^  OK +git'))
Check 'step-check-ok-scoop-app' 'True' ([string]($CheckOut -match '(?m)^  OK +7-Zip'))
Check 'step-check-missing-scoop-app' 'True' ([string]($CheckOut -match '(?m)^  MISSING +VLC'))
Check 'step-check-ok-sshkey' 'True' ([string]($CheckOut -match '(?m)^  OK +SSH key'))
Check 'step-check-table-summary' 'True' ([string]($CheckOut -match '(?m)^  Summary: \d+ ok, 1 missing, 0 skipped'))
Check 'step-check-missing-count' '1' ([string]$CheckMissing)
# No key and no console: SKIPPED, not counted. With a console: MISSING.
$SkipCat = @($CheckCat | Where-Object { $_.Item -eq 'ssh-key' })
$SkipHome = Join-Path $Work 'ssh none'
$SkipMissing = -1
$SkipOut = Invoke-CheckStep -Catalog $SkipCat -HomeDir $SkipHome -Missing ([ref]$SkipMissing) -Interactive $false | Out-String
Check 'step-check-sshkey-skipped' 'True|0' (([string]($SkipOut -match '(?m)^  SKIPPED +SSH key')) + '|' + $SkipMissing)
$SkipOut = Invoke-CheckStep -Catalog $SkipCat -HomeDir $SkipHome -Missing ([ref]$SkipMissing) -Interactive $true | Out-String
Check 'step-check-sshkey-missing' 'True|1' (([string]($SkipOut -match '(?m)^  MISSING +SSH key')) + '|' + $SkipMissing)

# Scoop writes scoop-install.json (current) or install.json (older): both count.
$NewApp = Join-Path $env:SCOOP (Join-Path 'apps' (Join-Path 'wezterm' '20240203'))
New-Item -ItemType Directory -Path $NewApp -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $NewApp 'scoop-install.json'), '{}', (New-Object Text.UTF8Encoding($false)))
Check 'check-scoop-new-json' 'True' ([string](Test-CheckScoopApp 'wezterm'))
Check 'check-scoop-old-json' 'True' ([string](Test-CheckScoopApp '7zip'))
Check 'check-scoop-no-json' 'False' ([string](Test-CheckScoopApp 'vlc'))

# WSL counts only with an installed Ubuntu distro. Stub wsl.exe; its output is
# UTF-16 when piped, so one case has NUL characters between the letters.
function global:wsl.exe { $global:WslOut }
$global:WslOut = @('docker-desktop')
Check 'wsl-no-ubuntu' 'False' ([string](Test-WslUbuntuInstalled))
$global:WslOut = @('Ubuntu', 'docker-desktop')
Check 'wsl-ubuntu' 'True' ([string](Test-WslUbuntuInstalled))
$global:WslOut = @("U`0b`0u`0n`0t`0u`0`r`0", "`0")
Check 'wsl-ubuntu-utf16' 'True' ([string](Test-WslUbuntuInstalled))
$global:WslOut = @()
Check 'wsl-none' 'False' ([string](Test-CheckItem -Row (New-Object PSObject -Property @{ Action = 'step:wsl' })))
Remove-Item Function:\wsl.exe

# Git identity: asked once, kept in the config, applied to git's global config.
# GIT_CONFIG_GLOBAL points git at a scratch file, never the real ~\.gitconfig.
. (Join-Path $StepsDir 'gitidentity.ps1')
$SavedGitGlobal = $env:GIT_CONFIG_GLOBAL
# The check tests stub git as a no-op; this section needs the real one.
Remove-Item Function:\git -ErrorAction SilentlyContinue
$GitGlobal = Join-Path $Work 'gitconfig-test'
$GitEmpty = Join-Path $Work 'gitconfig-empty'
$Utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($GitEmpty, '', $Utf8)
[IO.File]::WriteAllText($GitGlobal, '', $Utf8)
$global:Prompts = @('octo', 'octo@example.com')
$global:PromptLog = @()
function global:Read-StepLine($Prompt) {
  $global:PromptLog += $Prompt
  $Value = $global:Prompts[0]
  $global:Prompts = @($global:Prompts | Select-Object -Skip 1)
  return $Value
}
# No console: nothing is asked, nothing is written.
$env:GIT_CONFIG_GLOBAL = $GitEmpty
$NoCfg = Join-Path $Work 'gitid-none\.local\bootstrap\config'
$NoOut = Invoke-GitIdentityStep -ConfigPath $NoCfg -Interactive $false | Out-String
Check 'git-no-console-no-ask' '0' ([string]$global:PromptLog.Count)
Check 'git-no-console-warns' 'True' ([string]($NoOut -match 'run setup from a console'))
# Empty values are saved even without a console, so the next run reads them back.
Check 'git-no-console-saves-empty' 'True' ([string]((Get-Content -Raw $NoCfg) -match '(?m)^github\.user=\r?$'))
# Console, nothing saved: asked for both, saved, applied to git.
$env:GIT_CONFIG_GLOBAL = $GitGlobal
$GitCfg = Join-Path $Work 'gitid\.local\bootstrap\config'
$global:Prompts = @('octo', 'octo@example.com')
Invoke-GitIdentityStep -ConfigPath $GitCfg -Interactive $true | Out-Null
Check 'git-asked-twice' '2' ([string]$global:PromptLog.Count)
Check 'git-config-user' 'octo' (Get-ConfigValue -Path $GitCfg -Key 'github.user')
Check 'git-config-email' 'octo@example.com' (Get-ConfigValue -Path $GitCfg -Key 'git.email')
Check 'git-global-name' 'octo' (Get-StepGitGlobal 'user.name')
Check 'git-global-email' 'octo@example.com' (Get-StepGitGlobal 'user.email')
# Next run: the saved values are offered; Enter keeps them, no new prompt text.
$global:Prompts = @('', '')
Invoke-GitIdentityStep -ConfigPath $GitCfg -Interactive $true | Out-Null
Check 'git-keep-asked' '4' ([string]$global:PromptLog.Count)
Check 'git-keep-user' 'octo' (Get-ConfigValue -Path $GitCfg -Key 'github.user')
Check 'git-keep-prompt-shows-default' 'True' ([string]($global:PromptLog[2] -match '\[octo\], keep it'))
# n changes the username; a blank new answer keeps the old one.
$global:Prompts = @('n', 'newname', '')
Invoke-GitIdentityStep -ConfigPath $GitCfg -Interactive $true | Out-Null
Check 'git-change-user' 'newname' (Get-ConfigValue -Path $GitCfg -Key 'github.user')
Check 'git-change-keeps-email' 'octo@example.com' (Get-ConfigValue -Path $GitCfg -Key 'git.email')
Check 'git-change-global' 'newname' (Get-StepGitGlobal 'user.name')
# Config keeps other settings: a catalog flag written earlier survives.
Set-ConfigValue -Path $GitCfg -Key 'terminals.wezterm' -Value '1'
Check 'git-config-keeps-flags' '1' (Get-ConfigValue -Path $GitCfg -Key 'terminals.wezterm')
Check 'git-config-keeps-user' 'newname' (Get-ConfigValue -Path $GitCfg -Key 'github.user')
# An empty email is saved too (as git.email=), and the next run asks for it.
$env:GIT_CONFIG_GLOBAL = $GitEmpty
$PartCfg = Join-Path $Work 'gitid-part\.local\bootstrap\config'
$global:Prompts = @('pc_win', '')
$global:PromptLog = @()
$PartOut = Invoke-GitIdentityStep -ConfigPath $PartCfg -Interactive $true | Out-String
Check 'git-partial-user-saved' 'pc_win' (Get-ConfigValue -Path $PartCfg -Key 'github.user')
# The email can be left empty: one prompt, no retry.
Check 'git-email-skip-one-prompt' '2' ([string]$global:PromptLog.Count)
Check 'git-email-skip-no-retry' 'False' ([string]($PartOut -match 'required'))
Check 'git-empty-email-line' 'True' ([string]((Get-Content -Raw $PartCfg) -match '(?m)^git\.email=\r?$'))
Check 'git-partial-warns' 'True' ([string]($PartOut -match 'saved without a value'))
$global:Prompts = @('', 'a@b.c')
$global:PromptLog = @()
Invoke-GitIdentityStep -ConfigPath $PartCfg -Interactive $true | Out-Null
Check 'git-empty-email-asked-only' '2' ([string]$global:PromptLog.Count)
Check 'git-partial-email-saved' 'a@b.c' (Get-ConfigValue -Path $PartCfg -Key 'git.email')
Check 'git-partial-user-kept' 'pc_win' (Get-ConfigValue -Path $PartCfg -Key 'github.user')
# No console: nothing is asked, saved values are still read and written back.
$global:PromptLog = @()
Invoke-GitIdentityStep -ConfigPath $PartCfg -Interactive $false | Out-Null
Check 'git-no-console-reads-saved' '0' ([string]$global:PromptLog.Count)
# -NoPrompt (the call after Scoop): applies the saved values, never asks.
$global:PromptLog = @()
Invoke-GitIdentityStep -ConfigPath $PartCfg -Interactive $true -NoPrompt | Out-Null
Check 'git-noprompt-no-ask' '0' ([string]$global:PromptLog.Count)
$env:GIT_CONFIG_GLOBAL = $GitGlobal
Remove-Item Function:\Read-StepLine
if ($SavedGitGlobal) { $env:GIT_CONFIG_GLOBAL = $SavedGitGlobal } else { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue }
function global:git { }

# VS Code: the code command is found on PATH or in Scoop's own folder.
$VsSaved = $env:SCOOP
$env:SCOOP = Join-Path $Work 'scoop-vscode'
$VsCmd = Join-Path $env:SCOOP 'apps\vscode\current\bin\code.cmd'
New-Item -ItemType Directory -Path (Split-Path $VsCmd) -Force | Out-Null
[IO.File]::WriteAllText($VsCmd, '', $Utf8)
. (Join-Path $StepsDir 'vscode.ps1')
Check 'vscode-cli-found' 'True' ([string]((Get-VscodeStepCli) -ne ''))
$env:SCOOP = $VsSaved

# WSL install that is still finishing adds a TODO line for the end of the run.
$global:StepTodos = @()
function global:wsl.exe { }
Invoke-WslStep -Items @() | Out-Null
Remove-Item Function:\wsl.exe
Check 'wsl-todo-added' 'True' ([string]((@($global:StepTodos) -join '|') -match 'WSL Ubuntu is not ready yet'))

# A fresh install never launches Ubuntu here (its first-run prompts garble in
# this run); the user is told to open it once instead.
$global:StepTodos = @()
$global:WslArgs = @()
$global:WslInstalled = $false
function global:wsl.exe { if ($args -contains '--install') { $global:WslArgs = $args; $global:WslInstalled = $true; return }; if ($global:WslInstalled) { 'Ubuntu' } }
Invoke-WslStep -Items @() | Out-Null
Remove-Item Function:\wsl.exe
Check 'wsl-no-launch' 'True' ([string]($global:WslArgs -contains '--no-launch'))
Check 'wsl-first-run-todo' 'True' ([string]((@($global:StepTodos) -join '|') -match 'open Ubuntu'))
Remove-Item Function:\git, Function:\make
$env:SCOOP = Join-Path $Work 'scoop-steps'

# SSH server: stub the sshd service and the elevated PowerShell. The stub
# "starts" sshd unless asked to fail, and writes the error log like the real one.
. (Join-Path $StepsDir 'sshserver.ps1')
$global:Sshd = $null
$global:ElevLog = @()
$global:ElevFail = $false
function global:Get-StepSshdService { $global:Sshd }
function global:Invoke-StepElevated {
  param([string]$Script = '', [object]$IsAdmin = $null, [string]$StatusPath = '', [string]$Activity = '')
  $global:ElevLog += $Script
  $global:ElevStatus = $StatusPath
  if ($global:ElevFail) {
    if ($Script -match "WriteAllText\('([^']+\.log)'") { [IO.File]::WriteAllText($Matches[1], 'no capability here') }
    return 1
  }
  $global:Sshd = New-Object PSObject -Property @{ Status = 'Running'; StartType = 'Automatic' }
  return 0
}
# The firewall rule counts as scoped unless a test says otherwise.
function global:Test-StepSshFirewallScoped { $true }
# The check step also tests for git and make: present on a set-up machine,
# absent in the Linux container. Stubbed so the SSH counts mean what they say.
function global:git { }
function global:make { }
$SrvRow = New-Object PSObject -Property @{ Action = 'step:ssh-server' }
Check 'sshd-check-missing' 'False' ([string](Test-CheckItem -Row $SrvRow))
$SrvPlan = Invoke-SshServerStep -Items @('ssh-server') -Verify | Out-String
Check 'sshd-verify-plans' 'True|0' (([string]($SrvPlan -match 'would install OpenSSH Server')) + '|' + $global:ElevLog.Count)
# Not admin and the answer is no: no UAC prompt, and the check says SKIPPED.
Invoke-SshServerStep -Items @('ssh-server') -IsAdmin $false -Answer $false 3>$null | Out-Null
Check 'sshd-declined-no-elevation' '0' ([string]$global:ElevLog.Count)
$DeclOut = Invoke-CheckStep -Catalog @((New-Object PSObject -Property @{ Group = 'win-setup'; Item = 'ssh-server'; Label = 'OpenSSH server (sshd)'; Action = 'step:ssh-server'; Selected = $true })) -Missing ([ref]$SkipMissing) | Out-String
Check 'sshd-declined-check-skipped' 'True|0' (([string]($DeclOut -match '(?m)^SKIPPED OpenSSH server \(sshd\) \(not confirmed\)')) + '|' + $SkipMissing)
# The question comes only without admin rights: an admin run has no popup.
Check 'sshd-admin-no-question' 'True' ([string]((Get-Content -Raw (Join-Path $StepsDir 'sshserver.ps1')) -match "if \(-not \(Test-StepAdmin -IsAdmin \`$IsAdmin\)\) \{\s+if \(-not \(Read-StepSshServerConfirm"))
$SrvOut = Invoke-SshServerStep -Items @('ssh-server') -IsAdmin $false -Answer $true | Out-String
Check 'sshd-elevates-once' '1' ([string]$global:ElevLog.Count)
Check 'sshd-script-capability' 'True' ([string]($global:ElevLog[0] -match 'Add-WindowsCapability -Online'))
Check 'sshd-script-automatic' 'True' ([string]($global:ElevLog[0] -match 'Set-Service -Name sshd -StartupType Automatic'))
Check 'sshd-script-firewall' 'True' ([string]($global:ElevLog[0] -match 'LocalPort 22'))
# Both the new rule and the narrowed existing rule allow the local subnet only.
Check 'sshd-script-local-only' '2' ([string]([regex]::Matches($global:ElevLog[0], '-RemoteAddress LocalSubnet').Count))
# ... and only on trusted networks: on a Public network LocalSubnet means strangers.
Check 'sshd-script-profiles' '2' ([string]([regex]::Matches($global:ElevLog[0], '-Profile Private,Domain').Count))
Check 'sshd-ok' 'True' ([string]($SrvOut -match 'sshd running'))
Check 'sshd-check-ok' 'True' ([string](Test-CheckItem -Row $SrvRow))
# Already running: nothing elevated again.
Invoke-SshServerStep -Items @('ssh-server') -IsAdmin $true | Out-Null
Check 'sshd-idempotent' '1' ([string]$global:ElevLog.Count)
# Running, but the rule is the old unscoped one: elevate once to narrow it.
function global:Test-StepSshFirewallScoped { $false }
Invoke-SshServerStep -Items @('ssh-server') -IsAdmin $true | Out-Null
Check 'sshd-narrows-old-rule' '2' ([string]$global:ElevLog.Count)
function global:Test-StepSshFirewallScoped { $true }
# Connected to a Public network: the step says sshd is unreachable there.
$PubNets = @((New-Object PSObject -Property @{ Name = 'HomeWifi'; NetworkCategory = 'Public' }))
$PubOut = Invoke-SshServerStep -Items @('ssh-server') -IsAdmin $true -NetProfiles $PubNets 3>&1 | Out-String
Check 'sshd-public-network-warns' 'True' ([string]($PubOut -match "network 'HomeWifi' is Public"))
# Installed but stopped or manual start counts as not running.
$global:Sshd = New-Object PSObject -Property @{ Status = 'Stopped'; StartType = 'Manual' }
Check 'sshd-stopped-not-ok' 'False' ([string](Test-StepSshdRunning))
# A failure throws with the elevated script's message.
$global:ElevFail = $true
$SrvErr = try { Invoke-SshServerStep -Items @('ssh-server') -IsAdmin $true | Out-Null; '' } catch { $_.Exception.Message }
Check 'sshd-failure-message' 'OpenSSH Server setup failed: no capability here' $SrvErr
# Exit 2: the feature is staged until a restart. A warning, not a failure,
# and the check says SKIPPED (restart needed).
$global:ElevFail = $false
$global:Sshd = $null
function global:Invoke-StepElevated { param([string]$Script = '', [object]$IsAdmin = $null, [string]$StatusPath = '', [string]$Activity = '') $global:ElevLog += $Script; return 2 }
$RestartErr = try { $RestartOut = Invoke-SshServerStep -Items @('ssh-server') -IsAdmin $true 3>&1 | Out-String; '' } catch { $_.Exception.Message }
Check 'sshd-restart-no-throw' '' $RestartErr
Check 'sshd-restart-warns' 'True' ([string]($RestartOut -match 'needs a restart'))
$RestartCheck = Invoke-CheckStep -Catalog @((New-Object PSObject -Property @{ Group = 'win-setup'; Item = 'ssh-server'; Label = 'OpenSSH server (sshd)'; Action = 'step:ssh-server'; Selected = $true })) -Missing ([ref]$SkipMissing) | Out-String
Check 'sshd-restart-check-skipped' 'True|0' (([string]($RestartCheck -match '\(restart needed\)')) + '|' + $SkipMissing)
Remove-Item Function:\git, Function:\make
# The script exits 2 when the sshd service is missing after the install, and
# opens the firewall before that, so the rule is in place after the restart.
$SrvScript = Get-StepSshServerScript -LogPath 'x.log' -StatusPath 'x.status'
Check 'sshd-script-exit-2' 'True' ([string]($SrvScript -match "Get-Service -Name sshd -ErrorAction SilentlyContinue\)\) \{ exit 2 \}"))
Check 'sshd-script-firewall-first' 'True' ([string]($SrvScript.IndexOf('LocalPort 22') -lt $SrvScript.IndexOf('exit 2')))
# The elevated script must parse as PowerShell.
$ParseErr = $null
[Management.Automation.PSParser]::Tokenize((Get-StepSshServerScript -LogPath "C:\it's\log.txt"), [ref]$ParseErr) | Out-Null
Check 'sshd-script-parses' '0' ([string]@($ParseErr).Count)
Check 'sshd-script-writes-status' 'True' ([string]($global:ElevLog[-2] -match [regex]::Escape($global:ElevStatus)))
Check 'sshd-status-file-removed' 'False' ([string](Test-Path -LiteralPath $global:ElevStatus))
Remove-Item Function:\Get-StepSshdService, Function:\Invoke-StepElevated, Function:\Test-StepSshFirewallScoped, Function:\git, Function:\make
. (Join-Path $StepsDir 'sshserver.ps1')
# Scoped-rule detection on injected objects (no NetSecurity module in a container).
$FwRule = New-Object PSObject -Property @{ Profile = 'Domain, Private' }
$FwAddr = New-Object PSObject -Property @{ RemoteAddress = 'LocalSubnet' }
Check 'fw-scoped-ok' 'True' ([string](Test-StepSshFirewallScoped -Rule $FwRule -Filter $FwAddr))
Check 'fw-scoped-any' 'False' ([string](Test-StepSshFirewallScoped -Rule (New-Object PSObject -Property @{ Profile = 'Any' }) -Filter $FwAddr))
Check 'fw-scoped-public' 'False' ([string](Test-StepSshFirewallScoped -Rule (New-Object PSObject -Property @{ Profile = 'Private, Public' }) -Filter $FwAddr))
Check 'fw-scoped-private-only' 'False' ([string](Test-StepSshFirewallScoped -Rule (New-Object PSObject -Property @{ Profile = 'Private' }) -Filter $FwAddr))
Check 'fw-scoped-any-address' 'False' ([string](Test-StepSshFirewallScoped -Rule $FwRule -Filter (New-Object PSObject -Property @{ RemoteAddress = 'Any' })))
Check 'fw-scoped-no-rule' 'False' ([string](Test-StepSshFirewallScoped))
$Nets = @((New-Object PSObject -Property @{ Name = 'Cafe'; NetworkCategory = 'Public' }), (New-Object PSObject -Property @{ Name = 'Office'; NetworkCategory = 'DomainAuthenticated' }), (New-Object PSObject -Property @{ Name = 'Home'; NetworkCategory = 'Private' }))
Check 'public-networks' 'Cafe' ((Get-StepPublicNetworks -Profiles $Nets) -join ',')
Check 'public-networks-none' '0' ([string]@(Get-StepPublicNetworks -Profiles @($Nets[2])).Count)

# Progress bar: the status file the elevated script writes, and the percent.
$StatusFile = Join-Path $Work 'ssh.status'
Check 'sshd-status-none' 'True' ([string]($null -eq (Read-StepStatus -Path $StatusFile)))
[IO.File]::WriteAllText($StatusFile, '85|starting sshd')
$St = Read-StepStatus -Path $StatusFile
Check 'sshd-status-read' '85|starting sshd' ([string]$St.Percent + '|' + $St.Text)
[IO.File]::WriteAllText($StatusFile, 'garbage')
Check 'sshd-status-garbage' 'True' ([string]($null -eq (Read-StepStatus -Path $StatusFile)))
Check 'sshd-progress-stage' '85' ([string](Get-StepProgressPercent -Stage 85 -StageSeconds 30))
Check 'sshd-progress-creeps' 'True' ([string](((Get-StepProgressPercent -Stage 15 -StageSeconds 60) -gt 15) -and ((Get-StepProgressPercent -Stage 15 -StageSeconds 60) -lt (Get-StepProgressPercent -Stage 15 -StageSeconds 180))))
Check 'sshd-progress-capped' '74' ([string](Get-StepProgressPercent -Stage 15 -StageSeconds 100000))
# A real child process (not elevated): its stages show up and the exit code
# comes back. Windows only: it starts powershell.exe with -WindowStyle, which
# PowerShell on Linux rejects (that used to abort the container run here).
if ($env:OS -eq 'Windows_NT') {
  $ElevCode = Invoke-StepElevated -Script ("[IO.File]::WriteAllText('" + $StatusFile + "', '50|half'); Start-Sleep -Milliseconds 700; exit 3") -IsAdmin $true -StatusPath $StatusFile -Activity 'test'
  Check 'sshd-elevated-exit-code' '3' ([string]$ElevCode)
} else { Write-Output 'SKIP sshd-elevated-exit-code: needs Windows PowerShell' }

# WSL: an installed Ubuntu is not installed again (that fails with
# Wsl/InstallDistro/ERROR_ALREADY_EXISTS).
$global:WslCalls = @()
function global:wsl.exe { $global:WslCalls += ($args -join ' '); if ($args -contains '--list') { $global:WslOut } }
$global:WslOut = @("U`0b`0u`0n`0t`0u`0`r`0", "`0")
$WslSkip = Invoke-WslStep -Items @('wsl') | Out-String
Check 'wsl-existing-no-install' '0' ([string]@($global:WslCalls | Where-Object { $_ -like '*--install*' }).Count)
Check 'wsl-existing-ok' 'True' ([string]($WslSkip -match 'already installed'))
$global:WslOut = @('docker-desktop'); $global:WslCalls = @()
Invoke-WslStep -Items @('wsl') 3>$null | Out-Null
Check 'wsl-install-no-launch' 'True' ([string]($global:WslCalls -contains '--install -d Ubuntu --no-launch'))
Check 'wsl-check-needs-ubuntu' 'False' ([string](Test-CheckItem -Row (New-Object PSObject -Property @{ Action = 'step:wsl' })))
Remove-Item Function:\wsl.exe

# setup.ps1 run as its own process must load lib, menu and steps itself.
$Shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$SoloHome = Join-Path $Work 'solo home'
New-Item -ItemType Directory -Path $SoloHome -Force | Out-Null
$SoloOut = & $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'setup.ps1') -DryRun -Config (Join-Path $Work 'solo-config') -CatalogPath $Fixture -HomeDir $SoloHome 2>&1 | Out-String
Check 'setup-standalone-exit' '0' ([string]$LASTEXITCODE)
Check 'setup-standalone-dryrun' 'True' ([string]($SoloOut -match 'Dry run: nothing changed'))

$ThrewPre = $false
try { Invoke-PreflightStep -Catalog @() -CatalogPath (Join-Path $Work 'no-catalog-here.txt') } catch { $ThrewPre = $true }
Check 'step-preflight-missing-catalog' 'True' ([string]$ThrewPre)
. (Join-Path $Root 'setup.ps1')

$DryHome = Join-Path $Work 'dryrun-home'
New-Item -ItemType Directory -Path $DryHome -Force | Out-Null
$global:ScoopLog = @()
Invoke-Setup -DryRun -Config (Join-Path $Work 'dryrun-config') -CatalogPath $Fixture -HomeDir $DryHome -StepsDir $StepsDir | Out-Null
Check 'setup-dryrun-no-config' 'False' ([string](Test-Path (Join-Path $Work 'dryrun-config')))
Check 'setup-dryrun-no-steps' '0' ([string]$global:ScoopLog.Count)

$VerifyCfg = Join-Path $Work 'verify-save'
$Cat9 = Import-Catalog -Path $Fixture
$Extra9 = Import-Selection -Path $ConfigInput -Catalog $Cat9
Save-Selection -Path $VerifyCfg -Catalog $Cat9 -Extra $Extra9
$global:ScoopLog = @()
Invoke-Setup -Verify -Config $VerifyCfg -CatalogPath $Fixture -HomeDir $DryHome -StepsDir $StepsDir | Out-Null
Check 'setup-verify-no-save' 'same' (cmp-bytes $VerifyCfg $ConfigExpected)
Check 'setup-verify-no-steps' '0' ([string]$global:ScoopLog.Count)

$SelThrew = $false
try { Invoke-Setup -Select -Config (Join-Path $Work 'select-config') -CatalogPath $Fixture -HomeDir $DryHome -StepsDir $StepsDir | Out-Null } catch { $SelThrew = $true }
Check 'setup-select-no-console-errors' 'True' ([string]$SelThrew)

$global:ScoopLog = @()
$MissThrew = $false
try { Invoke-Setup -Yes -Config (Join-Path $Work 'no-such-dir-x/config') -ConfigExplicit -CatalogPath $Fixture -HomeDir $DryHome -StepsDir $StepsDir | Out-Null } catch { $MissThrew = $true }
Check 'setup-yes-missing-config-errors' 'True' ([string]$MissThrew)
Check 'setup-yes-missing-no-steps' '0' ([string]$global:ScoopLog.Count)

$FailCatalog = Join-Path $Work 'failcat.txt'
[IO.File]::WriteAllText($FailCatalog, 'win-setup|vscode|VS Code + extensions|windows|on|step:vscode', (New-Object Text.UTF8Encoding($false)))
$FailCfg2 = Join-Path $Work 'failrun-config'
[IO.File]::WriteAllText($FailCfg2, '# empty', (New-Object Text.UTF8Encoding($false)))
function Invoke-VscodeStep { param([string[]]$Items = @(), [switch]$Verify) throw "boom" }
$FailOut = Invoke-Setup -Yes -Config $FailCfg2 -CatalogPath $FailCatalog -HomeDir $DryHome -StepsDir $StepsDir
$FailCode = @($FailOut)[(@($FailOut)).Count - 1]
Check 'setup-step-failure-exit' '1' ([string]$FailCode)
. (Join-Path $Root (Join-Path 'windows' (Join-Path 'steps' 'vscode.ps1')))

# Like setup.sh: a version header, then the plan, one line per group.
$PlanCat = Join-Path $Work 'plancat.txt'
[IO.File]::WriteAllText($PlanCat, ("dev-tools|7zip|7-Zip|windows|on|scoop:main/7zip`n" + "dev-tools|curl|curl|windows|off|scoop:main/curl`n" + "win-setup|wsl|WSL (Ubuntu)|windows|off|step:wsl`n"), (New-Object Text.UTF8Encoding($false)))
$PlanOut = @(Invoke-Setup -DryRun -Config (Join-Path $Work 'plan-config') -CatalogPath $PlanCat -HomeDir $DryHome -StepsDir $StepsDir | ForEach-Object { [string]$_ })
Check 'setup-header-version' 'True' ([string](($PlanOut -join "`n") -match '==> install .+, PowerShell \d'))
Check 'setup-header-platform' 'True' ([string]($PlanOut -contains '==> Detected platform: windows'))
Check 'setup-plan-install' 'True' ([string]($PlanOut -contains '  install dev-tools     7-Zip'))
Check 'setup-plan-skip' 'True' ([string]($PlanOut -contains '  skip    dev-tools     curl'))
Check 'setup-plan-skip-only' 'True' ([string]($PlanOut -contains '  skip    win-setup     WSL (Ubuntu)'))
Check 'setup-plan-before-steps' 'True' ([string]([Array]::IndexOf($PlanOut, '==> Plan') -lt [Array]::IndexOf($PlanOut, 'Dry run: nothing changed.')))

# A "no" at Go ahead? after the menu saves and installs nothing.
$StubDir = Join-Path $Work 'confirm-stub'
function Test-MenuAvailable { return $true }
function Show-Menu { param([object[]]$Catalog) return 'continue' }
function Read-SetupConfirm { param([string]$Question) return $false }
$global:ScoopLog = @()
$NoOut = @(Invoke-Setup -Config (Join-Path $StubDir 'config') -CatalogPath $PlanCat -HomeDir $DryHome -StepsDir $StepsDir | ForEach-Object { [string]$_ })
Check 'setup-confirm-no-nothing' 'True' ([string]($NoOut -contains 'Nothing saved, nothing installed.'))
Check 'setup-confirm-no-save' 'False' ([string](Test-Path (Join-Path $StubDir 'config')))
Check 'setup-confirm-no-steps' '0' ([string]$global:ScoopLog.Count)
. (Join-Path $Root (Join-Path 'windows' 'menu.ps1'))
. (Join-Path $Root 'setup.ps1')

$ElevMsg = try { Invoke-Setup -Yes -Config $FailCfg2 -ConfigExplicit -CatalogPath $FailCatalog -HomeDir $DryHome -StepsDir $StepsDir -IsAdmin $true -ScoopPresent $false | Out-Null; '' } catch { $_.Exception.Message }
Check 'setup-elevated-scoop-missing' 'True' ([string]($ElevMsg -match 'Administrator|Scoop'))

if ($SavedStepScoop) { $env:SCOOP = $SavedStepScoop } else { Remove-Item Env:SCOOP -ErrorAction SilentlyContinue }

# Menu (Task 7). Mirrors the Task 4 key tests from lib/menu.sh.
function New-TestState { return @{ Cursor = 0; OpenGroup = ''; Top = 0; Rows = 20; Result = ''; GroupCursor = 0 } }
Check 'menu-available-redirected' 'False' ([string](Test-MenuAvailable))
Check 'menu-available-console' 'True' ([string](Test-MenuAvailable -InputRedirected $false -OutputRedirected $false -WindowHeight 24))
Check 'menu-available-input' 'False' ([string](Test-MenuAvailable -InputRedirected $true -OutputRedirected $false -WindowHeight 24))
Check 'menu-available-term-unset' 'True' ([string](Test-MenuAvailable -InputRedirected $false -OutputRedirected $false -WindowHeight 24 -Term ''))
Check 'menu-available-dumb' 'False' ([string](Test-MenuAvailable -InputRedirected $false -OutputRedirected $false -WindowHeight 24 -Term 'dumb'))
$FrameDup = New-Object PSObject -Property @{ Group = 'terminals'; Item = 'cmder-extra'; Label = 'Cmder extra'; Default = 'off'; Action = 'scoop:main/cmder'; Key = 'terminals.cmder-extra'; Selected = $false; New = $false }
$FrameCat = @($Catalog3) + @($FrameDup)
$FrameGroups = @('terminals', 'win-apps', 'win-setup')
$OpenState = New-TestState
$OpenState.OpenGroup = 'terminals'
$OpenState.Rows = 20
$script:MenuView = @(0, 1)
$OpenFrame = Get-MenuFrame -State $OpenState -Catalog $FrameCat -Groups $FrameGroups -View $script:MenuView -Width 80
Check 'menu-frame-padded' 'True' ([string](($OpenFrame | Where-Object { $_.Length -ne 79 }).Count -eq 0))
$WideState = New-TestState
$WideState.OpenGroup = 'terminals'
$WideState.Rows = 1
$script:MenuView = @(0)
$WideRow = New-Object PSObject -Property @{ Group = 'terminals'; Item = 'wide'; Label = 'Long label abcdefghij klmnopqrst uvwxyz 0123456789;'; Default = 'off'; Action = 'scoop:main/wide'; Key = 'terminals.wide'; Selected = $false; New = $false }
$WideFrame = Get-MenuFrame -State $WideState -Catalog @($WideRow) -Groups @('terminals') -View $script:MenuView -Width 20
Check 'menu-frame-truncates' 'True' ([string](($WideFrame | Where-Object { $_.Length -ne 19 }).Count -eq 0))
Check 'menu-frame-long-label' 'True' ([string]($WideFrame[1] -eq '> [ ] Long label ab'))
Check 'menu-frame-no-wrap' 'True' ([string]($WideFrame[1].Length -eq 19))
$OpenText = ($OpenFrame -join "`n")
$ClosedState = New-TestState
$ClosedState.Rows = 20
$script:MenuView = @(0, 1, 2)
$ClosedFrame = Get-MenuFrame -State $ClosedState -Catalog $FrameCat -Groups $FrameGroups -View $script:MenuView -Width 80
$ClosedText = ($ClosedFrame -join "`n")
Check 'menu-frame-close-clears' 'False' ([string]($ClosedText.Contains('What to install > terminals')))
Check 'menu-frame-footer' 'True' ([string]($ClosedText.Contains('c continues')))
$script:MenuCatalog = @($Catalog3)
$script:MenuGroups = @('terminals', 'win-apps', 'win-setup')
$script:MenuView = @(0, 1, 2)
$State = New-TestState
Update-MenuState -State $State -Key 'down'
Check 'menu-down' '1' ([string]$State.Cursor)
$Stuck = New-TestState
for ($k = 0; $k -lt 4; $k++) { Update-MenuState -State $Stuck -Key 'down' }
Check 'menu-down-stops' '2' ([string]$Stuck.Cursor)
$Top = New-TestState
Update-MenuState -State $Top -Key 'up'
Check 'menu-up-stops' '0' ([string]$Top.Cursor)
$One = New-TestState
Update-MenuState -State $One -Key 'space'
$OffCount = @($script:MenuCatalog | Where-Object { $_.Group -eq 'terminals' -and $_.Selected }).Count
Check 'menu-space-clears' '0' ([string]$OffCount)
Update-MenuState -State $One -Key 'space'
$OnCount = @($script:MenuCatalog | Where-Object { $_.Group -eq 'terminals' -and $_.Selected }).Count
Check 'menu-space-all' '1' ([string]$OnCount)
$Opener = New-TestState
$DupRow = New-Object PSObject -Property @{ Group = 'terminals'; Item = 'cmder-extra'; Label = 'Cmder extra'; Default = 'off'; Action = 'scoop:main/cmder'; Key = 'terminals.cmder-extra'; Selected = $false; New = $false }
$script:MenuCatalog = @($Catalog3) + @($DupRow)
$script:MenuGroups = @('terminals', 'win-apps', 'win-setup')
$script:MenuView = @(0, 1, 2)
Update-MenuState -State $Opener -Key 'enter'
Check 'menu-enter-opens' 'terminals' $Opener.OpenGroup
Update-MenuState -State $Opener -Key 'back'
Check 'menu-back-group' '' $Opener.OpenGroup
Check 'menu-back-cursor' '0' ([string]$Opener.Cursor)
$Single = New-TestState
$Single.Cursor = 2
$script:MenuCatalog = @($Catalog3)
Update-MenuState -State $Single -Key 'enter'
$SetupOn = @($script:MenuCatalog | Where-Object { $_.Group -eq 'win-setup' -and $_.Selected }).Count
Check 'menu-enter-single-toggles' '0' ([string]$SetupOn)
$Cont = New-TestState
Update-MenuState -State $Cont -Key 'continue'
Check 'menu-continue' 'continue' $Cont.Result
$Quit = New-TestState
Update-MenuState -State $Quit -Key 'quit'
Check 'menu-quit' 'quit' $Quit.Result
$Big = @()
for ($n = 1; $n -le 20; $n++) {
  $Big += (New-Object PSObject -Property @{ Group = 'big'; Item = 'x'; Label = 'y'; Selected = $true; New = $false })
}
$script:MenuCatalog = $Big
$script:MenuGroups = @('big')
$script:MenuView = @(0)
$Scroll = New-TestState
$Scroll.Rows = 5
Update-MenuState -State $Scroll -Key 'enter'
for ($k = 0; $k -lt 30; $k++) { Update-MenuState -State $Scroll -Key 'down' }
Check 'menu-scroll-bottom' '19|15' ([string]($Scroll.Cursor.ToString() + '|' + $Scroll.Top.ToString()))
$InView = ($Scroll.Cursor -ge $Scroll.Top) -and ($Scroll.Cursor -le ($Scroll.Top + $Scroll.Rows - 1))
Check 'menu-cursor-visible' 'True' ([string]$InView)
$NewRow = New-Object PSObject -Property @{ Label = 'Ghostty'; Selected = $true; New = $true }
Check 'menu-row-new-marker' 'True' ([string]((Format-MenuRow -Row $NewRow) -match '[(]new[)]'))

# bootstrap.ps1: an existing git clone is used in place (pulled when git is
# there), never moved aside, and its setup.ps1 runs. Runs the real script in a
# child PowerShell with a fake home; off Windows a powershell.exe shim stands in.
$BsHome = Join-Path $Work 'bs-home'
$BsDir = Join-Path $BsHome 'install'
New-Item -ItemType Directory -Path (Join-Path $BsDir '.git') -Force | Out-Null
$BsMarker = Join-Path $BsHome 'setup-ran'
[IO.File]::WriteAllText((Join-Path $BsDir 'setup.ps1'), ("Set-Content -Path '" + $BsMarker + "' -Value ran`n"))
$BsSaved = @{}
foreach ($N in @('USERPROFILE', 'INSTALL_DIR', 'BOOTSTRAP_URL', 'INSTALL_ALLOW_ADMIN', 'GITHUB_TOKEN', 'PATH')) { $BsSaved[$N] = [Environment]::GetEnvironmentVariable($N) }
$env:USERPROFILE = $BsHome; $env:INSTALL_DIR = $BsDir; $env:INSTALL_ALLOW_ADMIN = '1'
$env:BOOTSTRAP_URL = 'http://127.0.0.1:9/no-download-expected'; $env:GITHUB_TOKEN = 'x'
if (-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
  $Shim = Join-Path $Work 'ps-shim'
  New-Item -ItemType Directory -Path $Shim -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $Shim 'powershell.exe'), "#!/bin/sh`nexec pwsh `"`$@`"`n")
  & chmod +x (Join-Path $Shim 'powershell.exe')
  $env:PATH = $Shim + [IO.Path]::PathSeparator + $env:PATH
}
$BsOut = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $Root 'bootstrap.ps1') 2>&1 | Out-String
foreach ($N in $BsSaved.Keys) { [Environment]::SetEnvironmentVariable($N, $BsSaved[$N]) }
Check 'bootstrap-clone-not-moved' '0' ([string]@(Get-ChildItem -Path $BsHome -Filter 'install.bak.*').Count)
Check 'bootstrap-clone-setup-ran' 'True' ([string](Test-Path $BsMarker))
Check 'bootstrap-clone-no-download' 'False' ([string]($BsOut -match 'downloading'))

if ($Failures -gt 0) {
  Write-Output "$Failures test(s) failed"
  exit 1
}
Write-Output 'all tests passed'
