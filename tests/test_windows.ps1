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
function global:scoop { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ScoopArgs) $global:ScoopLog += ($ScoopArgs -join ' '); $global:ScoopBuckets += ($ScoopArgs -join ' ') }

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

$SpaceHome = Join-Path $Work 'a b'
New-Item -ItemType Directory -Path $SpaceHome -Force | Out-Null
$WezSrc = Join-Path (Join-Path (Join-Path $Root 'configs') 'wezterm') 'windows.lua'
Invoke-WeztermStep -Items @('wezterm') -WeztermHome $SpaceHome -SrcPath $WezSrc
Check 'step-wezterm-copies-config' 'same' (cmp-bytes (Join-Path $SpaceHome '.wezterm.lua') (Join-Path (Join-Path (Join-Path $Root 'configs') 'wezterm') 'windows.lua'))

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

$ElevMsg = try { Invoke-Setup -Yes -Config $FailCfg2 -ConfigExplicit -CatalogPath $FailCatalog -HomeDir $DryHome -StepsDir $StepsDir -IsAdmin $true -ScoopPresent $false | Out-Null; '' } catch { $_.Exception.Message }
Check 'setup-elevated-scoop-missing' 'True' ([string]($ElevMsg -match 'Administrator|Scoop'))

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

if ($Failures -gt 0) {
  Write-Output "$Failures test(s) failed"
  exit 1
}
Write-Output 'all tests passed'
