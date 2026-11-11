# Native Windows entry point. Modes mirror setup.sh: interactive menu,
# -Yes (saved selection, else catalog defaults), -DryRun (plan only, writes
# nothing), -Select (menu then save only), -Config <path>, -Verify (preflight
# plus the read-only checks of the selected steps, changes nothing).
# ASCII only: Windows PowerShell 5.1 misreads UTF-8 without a BOM.
param(
  [switch]$Yes = $false,
  [switch]$DryRun = $false,
  [switch]$Select = $false,
  [string]$Config = '',
  [switch]$Verify = $false,
  [string]$StepsDir = '',
  [string]$CatalogPath = '',
  [string]$HomeDir = '',
  [object]$IsAdmin = $null,
  [object]$ScoopPresent = $null
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $Here (Join-Path 'windows' (Join-Path 'steps' 'helpers.ps1')))
. (Join-Path $Here (Join-Path 'windows' 'lib.ps1'))
. (Join-Path $Here (Join-Path 'windows' 'menu.ps1'))
foreach ($StepFile in (Get-ChildItem -Path (Join-Path $Here (Join-Path 'windows' 'steps')) -Filter '*.ps1')) {
  . $StepFile.FullName
}

# Scoop's installer and the copied profile need local scripts to run. Set
# RemoteSigned for the current user when the policy outside this process
# blocks them. Windows only; a group policy setting wins and only warns.
function Set-SetupExecutionPolicy {
  param([switch]$Verify)
  if ($env:OS -ne 'Windows_NT') { return }
  $Policy = [string](Get-ExecutionPolicy -Scope CurrentUser)
  if ($Policy -eq 'Undefined') { $Policy = [string](Get-ExecutionPolicy -Scope LocalMachine) }
  if ($Policy -ne 'Undefined' -and $Policy -ne 'Restricted' -and $Policy -ne 'AllSigned') { return }
  if ($Verify) { Write-StepInfo ("would set execution policy RemoteSigned for CurrentUser (now " + $Policy + ")"); return }
  try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Write-StepOk 'execution policy: RemoteSigned (CurrentUser)'
  } catch { Write-StepWarn ('could not set execution policy: ' + $_.Exception.Message) }
}

function Get-SetupConfigPath {
  param([string]$Explicit = '', [string]$Home_ = '')
  if ($Explicit -and $Explicit -ne '') { return $Explicit }
  $H = Get-StepConfigHome -HomeDir $Home_
  return (Join-Path $H (Join-Path '.local' (Join-Path 'bootstrap' 'config')))
}

function Get-SetupSelectedItems {
  param([object[]]$Catalog = @(), [string]$Step = '')
  $Out = @()
  foreach ($Row in $Catalog) {
    if ($Row.Action -ne ('step:' + $Step)) { continue }
    if ($Row.Selected) { $Out += $Row.Item }
  }
  return $Out
}

function Invoke-Setup {
  param(
    [switch]$Yes = $false,
    [switch]$DryRun = $false,
    [switch]$Select = $false,
    [string]$Config = '',
    [switch]$Verify = $false,
    [string]$StepsDir = '',
    [string]$CatalogPath = '',
    [string]$HomeDir = '',
    [object]$IsAdmin = $null,
    [object]$ScoopPresent = $null,
    [switch]$ConfigExplicit = $false
  )
  $StepsDirParam = $StepsDir
  if (-not $StepsDirParam -or $StepsDirParam -eq '') { $StepsDirParam = Join-Path (Get-Location) 'windows-steps' }
  $ShowMenu = $false
  if (-not $Yes -and -not $DryRun -and -not $Verify) { $ShowMenu = $true }
  if ($Select) { $ShowMenu = $true }
  $Cfg = Get-SetupConfigPath -Explicit $Config -Home_ $HomeDir
  $Catalog = Import-Catalog -Path $CatalogPath
  $Extra = Import-Selection -Path $Cfg -Catalog $Catalog
  $menuShown = $false
  if ($ShowMenu) {
    if (-not (Test-MenuAvailable)) { throw '--select needs a terminal: input is redirected or no console' }
    $Choice = Show-Menu -Catalog $Catalog
    $menuShown = $true
    if ($Choice -ne 'continue') { Write-Output 'Nothing saved, nothing installed.'; return 0 }
  }
  if ($ConfigExplicit -and $Yes -and -not $menuShown) {
    if (-not (Test-Path $Cfg)) { throw "config file not found: $Cfg" }
  }
  $IsElevated = Test-StepAdmin -IsAdmin $IsAdmin
  $HasScoop = $false
  if ($ScoopPresent -ne $null) { $HasScoop = ([bool]$ScoopPresent) }
  else { try { $HasScoop = ((Get-Command scoop -ErrorAction SilentlyContinue) -ne $null) } catch { $HasScoop = $false } }
  if ($IsElevated -and -not $HasScoop) {
    throw 'Running as Administrator with no Scoop installed: install Scoop as a normal user first (https://scoop.sh).'
  }
  if ($Verify -or $DryRun) { Set-SetupExecutionPolicy -Verify } else { Set-SetupExecutionPolicy }
  if (-not $HasScoop -and -not $Verify -and -not $DryRun) {
    Write-Output 'Scoop not found: installing from https://get.scoop.sh ...'
    try { Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://get.scoop.sh')) } catch { throw }
  }
  foreach ($Row in $Catalog) { $Row.New = $false }
  if ($DryRun -or $Verify) {
    Invoke-PreflightStep -Catalog $Catalog -CatalogPath $CatalogPath
    Invoke-ScoopStep -Catalog $Catalog -Verify
    $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'profile'
    if ($Items.Count -gt 0) { Invoke-ProfileStep -Items $Items -Verify }
    $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'hotkeys'
    if ($Items.Count -gt 0) { Invoke-HotkeysStep -Items $Items -Verify -HotkeysHome $HomeDir }
    $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'vscode'
    if ($Items.Count -gt 0) { Invoke-VscodeStep -Items $Items -Verify }
    $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'flameshot'
    if ($Items.Count -gt 0) { Invoke-FlameshotStep -Items $Items -Verify }
    $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'wsl'
    if ($Items.Count -gt 0) { Invoke-WslStep -Items $Items -Verify }
    $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'wezterm'
    if ($Items.Count -gt 0) { Invoke-WeztermStep -Items $Items -Verify -WeztermHome $HomeDir }
    $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'ssh-key'
    if ($Items.Count -gt 0) { Invoke-SshKeyStep -Items $Items -Verify -HomeDir $HomeDir }
    if ($DryRun) { Write-Output 'Dry run: nothing changed.' }
    return 0
  }
  if ($ShowMenu) {
    Save-Selection -Path $Cfg -Catalog $Catalog -Extra $Extra
    Write-Output ("Selection saved to " + $Cfg)
  }
  if ($Select) { Write-Output 'Done.'; return 0 }
  Invoke-PreflightStep -Catalog $Catalog -CatalogPath $CatalogPath
  $Failures = @()
  try { Invoke-ScoopStep -Catalog $Catalog } catch { $Failures += ('scoop: ' + $_.Exception.Message) }
  $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'profile'
  if ($Items.Count -gt 0) {
    try { Invoke-ProfileStep -Items $Items } catch { $Failures += ('profile: ' + $_.Exception.Message) }
  }
  $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'hotkeys'
  if ($Items.Count -gt 0) {
    try { Invoke-HotkeysStep -Items $Items -HotkeysHome $HomeDir } catch { $Failures += ('hotkeys: ' + $_.Exception.Message) }
  }
  $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'vscode'
  if ($Items.Count -gt 0) {
    try { Invoke-VscodeStep -Items $Items } catch { $Failures += ('vscode: ' + $_.Exception.Message) }
  }
  $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'flameshot'
  if ($Items.Count -gt 0) {
    try { Invoke-FlameshotStep -Items $Items } catch { $Failures += ('flameshot: ' + $_.Exception.Message) }
  }
  $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'wsl'
  if ($Items.Count -gt 0) {
    try { Invoke-WslStep -Items $Items } catch { $Failures += ('wsl: ' + $_.Exception.Message) }
  }
  $Items = Get-SetupSelectedItems -Catalog $Catalog -Step 'wezterm'
  if ($Items.Count -gt 0) {
    try { Invoke-WeztermStep -Items $Items -WeztermHome $HomeDir } catch { $Failures += ('wezterm: ' + $_.Exception.Message) }
  }
  $SshItems = Get-SetupSelectedItems -Catalog $Catalog -Step 'ssh-key'
  if ($SshItems.Count -gt 0) {
    try { Invoke-SshKeyStep -Items $SshItems -HomeDir $HomeDir } catch { $Failures += ('ssh-key: ' + $_.Exception.Message) }
  }
  $Missing = 0
  try { Invoke-CheckStep -Catalog $Catalog -HomeDir $HomeDir -Missing ([ref]$Missing) } catch { $Failures += ('check: ' + $_.Exception.Message) }
  if ($Missing -gt 0) { $Failures += ('check: ' + $Missing + ' item(s) missing') }
  foreach ($F in $Failures) { Write-Warning $F }
  if ($Failures.Count -eq 0) { Write-Output 'Done.' }
  # Last, so the key is the final thing on screen.
  if ($SshItems.Count -gt 0) {
    try { Show-StepSshKey -HomeDir $HomeDir } catch { Write-Warning ('ssh-key: ' + $_.Exception.Message) }
  }
  if ($Failures.Count -gt 0) { return 1 }
  return 0
}

if ($MyInvocation.InvocationName -ne '.') {
  $RunStepsDir = Join-Path $Here (Join-Path 'windows' 'steps')
  $RunCatalog = Join-Path $Here 'catalog.txt'
  $RealStepsDir = $StepsDir
  if (-not $RealStepsDir -or $RealStepsDir -eq '') { $RealStepsDir = $RunStepsDir }
  $RealCatalog = $CatalogPath
  if (-not $RealCatalog -or $RealCatalog -eq '') { $RealCatalog = $RunCatalog }
  $RealHome = $HomeDir
  $RealAdmin = $IsAdmin
  $RealScoop = $ScoopPresent
  $WasConfigExplicit = $false
  if ($PSBoundParameters.ContainsKey('Config')) { $WasConfigExplicit = $true }
  # Stream messages as they come; the int Invoke-Setup returns is the exit code.
  $script:SetupExitCode = 0
  Invoke-Setup -Yes:$Yes -DryRun:$DryRun -Select:$Select -Config $Config -Verify:$Verify -StepsDir $RealStepsDir -CatalogPath $RealCatalog -HomeDir $RealHome -IsAdmin $RealAdmin -ScoopPresent $RealScoop -ConfigExplicit:$WasConfigExplicit | ForEach-Object {
    if ($_ -is [int]) { $script:SetupExitCode = $_ } else { $_ }
  }
  exit $script:SetupExitCode
}
