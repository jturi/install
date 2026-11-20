# ==========================================================================
#  PowerShell profile - port of the bash aliases from the dotfiles repo.
#  setup.ps1 copies it to Documents\WindowsPowerShell and Documents\PowerShell
#  as Microsoft.PowerShell_profile.ps1 (the old file is kept as .bak.<time>).
#
#  Scope: git shortcuts + common navigation/listing/search/system/network/
#  process utilities + npm/yarn/pip/cargo + docker + generic kubectl + terraform + chezmoi.
#  Machine-specific hosts and paths stay out of this file.
#  ASCII only: Windows PowerShell 5.1 misreads UTF-8 without a BOM.
# ==========================================================================

# Profile info banner
$profilePath = $MyInvocation.MyCommand.Path
$profileStat = Get-Item $profilePath
$hoursAgo = [math]::Round((New-TimeSpan -Start $profileStat.LastWriteTime -End (Get-Date)).TotalHours)
if ($hoursAgo -lt 1) {
    $timeStr = "just now"
} elseif ($hoursAgo -lt 24) {
    $timeStr = "$([math]::Floor($hoursAgo))h ago"
} else {
    $daysAgo = [math]::Floor($hoursAgo / 24)
    $timeStr = "$daysAgo days ago"
}
$originalColor = $Host.UI.RawUI.ForegroundColor
$Host.UI.RawUI.ForegroundColor = [ConsoleColor]::Green
Write-Host "profile: $profilePath (modified $timeStr)"
$Host.UI.RawUI.ForegroundColor = $originalColor

# Helper: define an alias, overriding any built-in PowerShell alias (gc, gm, h, ...)
function Set-UserAlias {
    param([string]$Name, $Value)
    Set-Alias -Name $Name -Value $Value -Scope Global -Option AllScope -Force
}
# @group nav
# -------------------------------------------------------------------------
#  NAVIGATION
# -------------------------------------------------------------------------
function md { param([Parameter(Mandatory)][string]$Path) New-Item -ItemType Directory -Force -Path $Path | Out-Null }
function rd { param([Parameter(Mandatory)][string]$Path) Remove-Item -Path $Path -Recurse -Force }
function Invoke-Tree { tree.com /F /A $args }
function cdUp1 { Set-Location .. }
function cdUp2 { Set-Location ..\.. }
function cdUp3 { Set-Location ..\..\.. }
function cdHome { Set-Location $HOME }
function cdDownloads { Set-Location (Join-Path $HOME 'Downloads') }
function Install-File {
    param([Parameter(Mandatory)][string]$Path)

    $installer = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $installer.Path -PathType Leaf)) {
        throw "Installer file not found: $Path"
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ([IO.Path]::GetExtension($installer.Path) -ieq '.msi') {
        $startParameters = @{
            FilePath     = (Join-Path $env:SystemRoot 'System32\msiexec.exe')
            ArgumentList = "/i `"$($installer.Path)`" /qn /norestart"
            Wait         = $true
            PassThru     = $true
        }
    } else {
        $startParameters = @{
            FilePath     = $installer.Path
            ArgumentList = '/S'
            Wait         = $true
            PassThru     = $true
        }
    }
    if (-not $isAdmin) {
        $startParameters.Verb = 'RunAs'
    }

    $process = Start-Process @startParameters
    if ($process.ExitCode -ne 0) {
        throw "Installer exited with code $($process.ExitCode): $($installer.Path)"
    }
}
function up {
    param([int]$Levels = 1)
    $path = (,'..' * $Levels) -join '\'
    Set-Location $path
}
function mkdircd {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Set-Location $Path
}

Set-UserAlias 'cd..'  'cdUp1'
Set-UserAlias 'cd...' 'cdUp2'
Set-UserAlias '....'  'cdUp3'
Set-UserAlias 'dow'   'cdDownloads'
Set-UserAlias 'installit' 'Install-File'
Set-UserAlias 'tree'  'Invoke-Tree'

# -------------------------------------------------------------------------
#  FILE LISTING
# -------------------------------------------------------------------------
function Get-ChildItemLong          { Get-ChildItem -Force @args | Format-Table -AutoSize }
function Get-ChildItemAll            { Get-ChildItem -Force @args }
function Get-ChildItemAllLong        { Get-ChildItem -Force @args | Format-Table -AutoSize }
function Get-ChildItemByTimeDesc     { Get-ChildItem -Force @args | Sort-Object LastWriteTime -Descending | Format-Table -AutoSize }
function Get-ChildItemBySizeDesc     { Get-ChildItem -Force @args | Sort-Object Length -Descending | Format-Table -AutoSize }
function Get-ChildItemLast10         { Get-ChildItem -Force @args | Sort-Object LastWriteTime -Descending | Select-Object -First 10 }
function Get-ChildItemDotOnly        { Get-ChildItem -Force -Filter ".*" @args }
function Get-DirSize                 { Get-ChildItem -Directory @args | ForEach-Object { [PSCustomObject]@{ Name=$_.Name; SizeMB=[math]::Round(((Get-ChildItem $_.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum/1MB),2) } } }
function Search-Aliases              { param([string]$Pattern) Get-Alias | Where-Object { $_.Name -match $Pattern }; Get-Command -CommandType Function | Where-Object { $_.Name -match $Pattern } }

Set-UserAlias 'l'    'Get-ChildItemLong'
Set-UserAlias 'la'   'Get-ChildItemAll'
Set-UserAlias 'll'   'Get-ChildItemAllLong'
Set-UserAlias 'lr'   'Get-ChildItemByTimeDesc'
Set-UserAlias 'lS'   'Get-ChildItemBySizeDesc'
Set-UserAlias 'lart' 'Get-ChildItemByTimeDesc'
Set-UserAlias 'lrt'  'Get-ChildItemByTimeDesc'
Set-UserAlias 'lsn'  'Get-ChildItemAll'
Set-UserAlias 'ldot' 'Get-ChildItemDotOnly'
Set-UserAlias 'lt'   'Get-ChildItemLast10'
Set-UserAlias 'dud'  'Get-DirSize'
Set-UserAlias 'alg'  'Search-Aliases'

# @end

# @group search
# -------------------------------------------------------------------------
#  SEARCH
# -------------------------------------------------------------------------
function Find-FileByName    { param([string]$Name) Get-ChildItem -Recurse -Filter "*$Name*" -File -ErrorAction SilentlyContinue }
function Search-InFiles     { param([string]$Pattern) Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue | Select-String -Pattern $Pattern -Context 5 }
function Get-HistoryGrep    { param([string]$Pattern) Get-History | Where-Object { $_.CommandLine -match $Pattern } }
function Sort-NumericDesc   { $input | Sort-Object { [double]$_ } -Descending }

Set-UserAlias 'ff'     'Find-FileByName'
Set-UserAlias 'sgrep'  'Search-InFiles'
Set-UserAlias 'h'      'Get-History'
Set-UserAlias 'hgrep'  'Get-HistoryGrep'
Set-UserAlias 'sortnr' 'Sort-NumericDesc'

# @end

# @group system
# -------------------------------------------------------------------------
#  SYSTEM
# -------------------------------------------------------------------------
function Clear-HostAlias   { Clear-Host }
function Get-EnvPath       { $env:Path -split ';' }
function Remove-EnvVar     { param([string]$Name) Remove-Item "Env:\$Name" -ErrorAction SilentlyContinue }
function Invoke-ReloadProfile { . $PROFILE }
function Watch-File        { param([Parameter(Mandatory)][string]$Path) Get-Content -Path $Path -Wait -Tail 10 }
function Get-WeekNumber    { Get-Date -UFormat %V }
function Toggle-WindowsTheme {
    $personalizeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path -LiteralPath $personalizeKey)) {
        New-Item -Path $personalizeKey -Force -ErrorAction Stop | Out-Null
    }

    $settings = Get-ItemProperty -LiteralPath $personalizeKey -ErrorAction Stop
    $currentlyLight = $true
    if ($null -ne $settings.AppsUseLightTheme) {
        $currentlyLight = [int]$settings.AppsUseLightTheme -eq 1
    }
    $lightTheme = if ($currentlyLight) { 0 } else { 1 }

    foreach ($settingName in 'AppsUseLightTheme', 'SystemUsesLightTheme') {
        New-ItemProperty -LiteralPath $personalizeKey -Name $settingName -Value $lightTheme -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    }

    if (-not ('WindowsNotes.NativeThemeBroadcast' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WindowsNotes {
    public static class NativeThemeBroadcast {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint msg, IntPtr wParam, string lParam,
            uint flags, uint timeout, out IntPtr result);
    }
}
'@
    }

    $result = [IntPtr]::Zero
    $broadcast = [WindowsNotes.NativeThemeBroadcast]::SendMessageTimeout(
        [IntPtr]0xffff, 0x001A, [IntPtr]::Zero, 'ImmersiveColorSet', 0x0002, 5000, [ref]$result
    )
    $themeName = if ($lightTheme -eq 0) { 'dark' } else { 'light' }
    if ($broadcast -eq [IntPtr]::Zero) {
        Write-Warning "Windows switched to $themeName mode, but did not acknowledge the theme-change broadcast."
    } else {
        Write-Host "Switched Windows to $themeName mode."
    }
}

Set-UserAlias 'cl'        'Clear-HostAlias'
Set-UserAlias 'path'      'Get-EnvPath'
Set-UserAlias 'unexport'  'Remove-EnvVar'
Set-UserAlias 'reload'    'Invoke-ReloadProfile'
Set-UserAlias 'darkit'    'Toggle-WindowsTheme'
Set-UserAlias 't'         'Watch-File'
Set-UserAlias 'help'      'Get-Help'
Set-UserAlias 'p'         'Get-Process'
Set-UserAlias 'week'      'Get-WeekNumber'

# @end

# @group network
# -------------------------------------------------------------------------
#  NETWORK
# -------------------------------------------------------------------------
function Get-MyIp         { (Invoke-RestMethod -Uri 'https://ifconfig.co/ip').Trim() }
function Get-MyIpLocal     { Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } | Select-Object IPAddress, InterfaceAlias }
function Get-Ips           { Get-NetIPAddress | Format-Table -AutoSize }
function Get-Ports         { Get-NetTCPConnection -State Listen | Sort-Object LocalPort | Format-Table -AutoSize }
function Get-DefaultRoute  { Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Format-Table -AutoSize }
function Get-LocalIp       { Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object InterfaceAlias, IPAddress }

Set-UserAlias 'myip'      'Get-LocalIp'
Set-UserAlias 'myiplocal' 'Get-MyIpLocal'
Set-UserAlias 'ips'       'Get-Ips'
Set-UserAlias 'ports'     'Get-Ports'
Set-UserAlias 'router'    'Get-DefaultRoute'

# -------------------------------------------------------------------------
#  TAILSCALE
# -------------------------------------------------------------------------
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    function Invoke-TailscaleStatus { tailscale status @args }
    Set-UserAlias 'tas' 'Invoke-TailscaleStatus'
    function tailcheck {
        $status = tailscale status -json | ConvertFrom-Json
        foreach ($peer in $status.Peer.PSObject.Properties) {
            $node = $peer.Value
            $name = $node.HostName
            $ip = $node.TailscaleIPs[0]
            $result = ping -n 1 -w 2000 $ip 2>&1 | Out-String
            if ($result -match 'TTL=') {
                Write-Host "  $name ($ip) : reachable" -ForegroundColor Green
            } else {
                Write-Host "  $name ($ip) : unreachable" -ForegroundColor Red
            }
        }
    }
}

# @end

# @group system
# -------------------------------------------------------------------------
#  PROCESSES
# -------------------------------------------------------------------------
function Get-ProcessesFull { Get-Process | Format-Table -AutoSize }
function Get-TopMem        { Get-Process | Sort-Object WS -Descending | Select-Object -First 10 Name, Id, WS, CPU }
function Get-TopCpu        { Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, Id, WS, CPU }
function Stop-ProcessOnPort {
    param([Parameter(Mandatory)][int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($conn) { $conn.OwningProcess | ForEach-Object { Stop-Process -Id $_ -Force } }
    else { Write-Host "No process found listening on port $Port" }
}

Set-UserAlias 'psu'      'Get-ProcessesFull'
Set-UserAlias 'psmem'    'Get-TopMem'
Set-UserAlias 'pscpu'    'Get-TopCpu'
Set-UserAlias 'killport' 'Stop-ProcessOnPort'
Set-UserAlias 'mytop'    'Get-TopCpu'

# @end

# @group tools
# -------------------------------------------------------------------------
#  MISC CLI TOOL WRAPPERS (only active if the tool is installed)
# -------------------------------------------------------------------------
if (Get-Command jq -ErrorAction SilentlyContinue) {
    function Invoke-JqColor { jq -C @args }
    Set-UserAlias 'jqc' 'Invoke-JqColor'
}
if (Get-Command lazygit -ErrorAction SilentlyContinue) { Set-UserAlias 'lg' 'lazygit' }
if (Get-Command lazydocker -ErrorAction SilentlyContinue) { Set-UserAlias 'lzd' 'lazydocker' }
if (Get-Command bat -ErrorAction SilentlyContinue) {
    function Invoke-BatPlain { bat --style=plain --paging=never @args }
    Set-UserAlias 'B' 'Invoke-BatPlain'
}

# @end

# @group dev
# -------------------------------------------------------------------------
#  NPM
# -------------------------------------------------------------------------
if (Get-Command npm -ErrorAction SilentlyContinue) {
    function ni    { npm install @args }
    function nis   { npm install --save @args }
    function nid   { npm install --save-dev @args }
    function nig   { npm install --global @args }
    function nr    { npm run @args }
    function nrs   { npm run start @args }
    function nrt   { npm run test @args }
    function nrb   { npm run build @args }
    function nrd   { npm run dev @args }
    function nlg   { npm list -g --depth 0 }
    function nout  { npm outdated }
    function nup   { npm update }
    function nuke  { Remove-Item -Recurse -Force node_modules, package-lock.json -ErrorAction SilentlyContinue; npm install }
    function nprune { npm prune }
}

# -------------------------------------------------------------------------
#  YARN
# -------------------------------------------------------------------------
if (Get-Command yarn -ErrorAction SilentlyContinue) {
    function ya  { yarn add @args }
    function yad { yarn add --dev @args }
    function yrm { yarn remove @args }
    function yb  { yarn build @args }
    function yd  { yarn dev @args }
    function ys  { yarn start @args }
    function yt  { yarn test @args }
    function yup { yarn upgrade-interactive @args }
    Set-UserAlias 'y' 'yarn'
}

# -------------------------------------------------------------------------
#  PIP / PYTHON
# -------------------------------------------------------------------------
if (Get-Command pip -ErrorAction SilentlyContinue) {
    function pi  { pip install @args }
    function pir { pip install -r requirements.txt }
    function pu  { pip install --upgrade @args }
    function pf  { pip freeze }
    function pfr { pip freeze | Out-File -Encoding utf8 requirements.txt }
    function pun { pip uninstall @args }
    function pde { pip install --editable . }
}
if (Get-Command python -ErrorAction SilentlyContinue) { Set-UserAlias 'py' 'python' }

# -------------------------------------------------------------------------
#  CARGO
# -------------------------------------------------------------------------
if (Get-Command cargo -ErrorAction SilentlyContinue) {
    function cr  { cargo run @args }
    function cb  { cargo build @args }
    function cbr { cargo build --release @args }
    function ct  { cargo test @args }
    function cc  { cargo check @args }
    function ci  { cargo install @args }
    function cup { cargo install-update -a }
}

# @end

# @group docker
# -------------------------------------------------------------------------
#  DOCKER
# -------------------------------------------------------------------------
if (Get-Command docker -ErrorAction SilentlyContinue) {
    function dps    { docker ps }
    function dpsa   { docker ps -a }
    function di     { docker images }
    function dprune { docker system prune -f }
    function dcon   { docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' }
    function dlog   { docker logs -f --tail 100 @args }
    function dexec  { docker exec -it @args }
    Set-UserAlias 'd' 'docker'

    function dc  { docker compose @args }
    function dcu { docker compose up -d @args }
    function dcd { docker compose down @args }
    function dcl { docker compose logs -f --tail 50 @args }
    function dcr { docker compose restart @args }
}

# @end

# @group terraform
# -------------------------------------------------------------------------
#  TERRAFORM
# -------------------------------------------------------------------------
if (Get-Command terraform -ErrorAction SilentlyContinue) {
    # Planning & Applying
    function tfp       { terraform plan @args }
    function tfpo      { terraform plan -out=tfplan @args }
    function tftrace   { $env:TF_LOG='TRACE'; terraform plan -out=tfplan @args; $env:TF_LOG=$null }
    function tfdebug   { $env:TF_LOG='DEBUG'; terraform apply @args; $env:TF_LOG=$null }
    function tfa       { terraform apply @args }
    function tfay      { terraform apply -auto-approve @args }
    function tfapl     { terraform apply tfplan @args }
    function tfat      { param([Parameter(Mandatory)][string]$Target) terraform apply -target=$Target @args }
    function tfplo     { terraform plan -lock=false @args }
    function tfaauto   { terraform plan -out=tfplan; if ($?) { terraform apply tfplan } }
    function tfd       { terraform destroy @args }
    function tfdt      { param([Parameter(Mandatory)][string]$Target) terraform destroy -target=$Target @args }

    # Init
    function tfi       { terraform init @args }
    function tfiu      { terraform init -upgrade @args }
    function tfim      { terraform init -migrate-state @args }
    function tfirc     { terraform init -reconfigure @args }

    # Format & Validate
    function tff       { terraform fmt -recursive @args }
    function tfv       { terraform validate @args }
    function tffc      { terraform fmt; terraform validate }

    # Output & Inspection
    function tfo       { terraform output @args }
    function tfoj      { terraform output -json @args }
    function tfgraph   { terraform graph | dot -Tpng > graph.png }

    # State Management
    function tfsl      { terraform state list @args }
    function tfss      { param([Parameter(Mandatory)][string]$Resource) terraform state show $Resource @args }
    function tfsmv     { param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Dst) terraform state mv $Src $Dst @args }
    function tfsr      { param([Parameter(Mandatory)][string]$Resource) terraform state rm $Resource @args }
    function tfimp     { param([Parameter(Mandatory)][string]$Addr, [Parameter(Mandatory)][string]$Id) terraform import $Addr $Id @args }
    function tfspl     { terraform state pull @args }
    function tfspu     { param([Parameter(Mandatory)][string]$File) terraform state push $File @args }

    # State Lock Management
    function tfunlock  { param([string]$LockId) if ($LockId) { terraform force-unlock $LockId } else { Write-Host 'Usage: tfunlock <LOCK_ID>' -ForegroundColor Yellow } }
    function tflock    { terraform force-unlock -force @args }

    # Workspace Management
    function tfwl      { terraform workspace list @args }
    function tfws      { param([Parameter(Mandatory)][string]$Name) terraform workspace select $Name @args }
    function tfwn      { param([Parameter(Mandatory)][string]$Name) terraform workspace new $Name @args }
    function tfwd      { param([Parameter(Mandatory)][string]$Name) terraform workspace delete $Name @args }

    # Interactive
    function tfconsole { terraform console @args }

    Set-UserAlias 't' 'terraform'
    Set-UserAlias 'tf' 'terraform'
}

# @end

# @group kubectl
# -------------------------------------------------------------------------
#  KUBECTL (generic only - no company-specific resource names)
# -------------------------------------------------------------------------
if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    function k       { kubectl @args }
    function ka      { kubectl apply -f @args }
    function kr      { kubectl replace -f @args }
    function kdiff   { kubectl diff -f @args }
    function kd      { kubectl delete -f @args }
    function kev     { kubectl get events -f @args }
    function kc      { kubectl config get-contexts @args }
    function kall    { kubectl get po,deploy,statefulset,svc,ingress,pvc }
    function kallw   { kubectl get po,deploy,svc,ingress,pvc -A -w }
    function kapi    { kubectl api-versions }
    function kuc     { kubectl config use-context @args }
    function kgn     { kubectl get namespace @args }
    function kn       { kubectl config set-context --current --namespace @args }
    function kposort { kubectl get pods -A --sort-by=.metadata.creationTimestamp }
    function ktop    { kubectl top pods @args }
    function kctx    { kubectl config current-context }
    function kdesc   { kubectl describe @args }
    function ktail   { kubectl logs -f --tail=50 @args }
}

# @end

# @group tools
# -------------------------------------------------------------------------
#  CHEZMOI
# -------------------------------------------------------------------------
if (Get-Command chezmoi -ErrorAction SilentlyContinue) {
    function cha  { chezmoi apply }
    function chaf { chezmoi --refresh-externals apply }
    Set-UserAlias 'ch' 'chezmoi'
}

# @end

# @group ai
# -------------------------------------------------------------------------
#  AI CLI SHORTCUTS (only if the tool is installed)
# -------------------------------------------------------------------------
if (Get-Command claude -ErrorAction SilentlyContinue) { function claudeyolo { claude --dangerously-skip-permissions @args } }
if (Get-Command codex -ErrorAction SilentlyContinue) { function codexyolo { codex --dangerously-bypass-approvals-and-sandbox @args } }
if (Get-Command gemini -ErrorAction SilentlyContinue) { function geminiyolo { gemini --yolo @args } }
if (Get-Command opencode -ErrorAction SilentlyContinue) {
    function opencodeyolo { $env:OPENCODE_PERMISSION = '{"*":"allow"}'; opencode @args }
}

# @end

# -------------------------------------------------------------------------
#  CLIPBOARD / PROFILE BONUS UTILS
# -------------------------------------------------------------------------
function Copy-Pwd    { (Get-Location).Path | Set-Clipboard }
function Edit-Profile { if (Get-Command code -ErrorAction SilentlyContinue) { code $PROFILE } else { notepad $PROFILE } }
Set-UserAlias 'pwdc'     'Copy-Pwd'
Set-UserAlias 'eprofile' 'Edit-Profile'

# @group git
# -------------------------------------------------------------------------
#  GIT - navigation / status / branch
# -------------------------------------------------------------------------
function GitAdd            { git add @args }
function GitAddDot          { git add . }
function GitAddAll          { git add --all }
function GitAddPatch        { git add --patch @args }
function GitAddUpdate       { git add --update @args }
function GitAddVerbose      { git add --verbose @args }
function GitAddCommit        { git add . ; git commit @args }
function GitBranch          { git branch @args }
function GitBranchAll       { git branch -a }
function GitBranchDelete    { git branch -d @args }
function GitBranchDeleteForce { git branch -D @args }
function GitBranchNoMerged  { git branch --no-merged }
function GitBranchAllSorted { git fetch; git branch -a --sort=-committerdate @args }
function GitBranchAllSortedGrep { param([string]$Pattern) git fetch; git branch -a --sort=-committerdate | Select-String $Pattern }
function GitBranchNewFrom   { git checkout -b @args }
function GitBranchDeleteForceArg { git branch -D @args }
function GitBranchRecentTable {
    git fetch --all --prune | Out-Null
    git for-each-ref --sort=-committerdate refs/heads refs/remotes --format="%(refname:short)|%(committerdate:format:%Y%m%d %H:%M)|(%(committerdate:relative))" |
        ForEach-Object { $_ -split '\|' } |
        Format-Table -AutoSize
}
function GitCheckout        { git checkout @args }
function GitCheckoutBranch  { git checkout -b @args }
function GitCheckoutMain    { git checkout main 2>$null }
function GitCheckoutOurs    { git checkout --ours @args }
function GitCheckoutTheirs  { git checkout --theirs @args }
function GitClone           { git clone @args }
function GitClean           { git clean -fd }
function GitCommit          { git commit @args }
function GitCommitMessage   { git commit -m @args }
function GitCherryPick      { git cherry-pick @args }
function GitCherryPickAbort { git cherry-pick --abort }
function GitCherryPickContinue { git cherry-pick --continue }
function GitRoot            { Set-Location (git rev-parse --show-toplevel) }
function GitStatusShort     { git status -s }
function GitStatusShortBranch { git status --short --branch }
function GitStatus          { git status }
function com                { param([Parameter(ValueFromRemainingArguments)]$msg) if (-not $msg) { Write-Host 'Usage: com "commit message"'; return }; git add .; git commit -m "$($msg -join ' ')" }
function compush            { param([Parameter(ValueFromRemainingArguments)]$msg) if (-not $msg) { Write-Host 'Usage: compush "commit message"'; return }; git add .; git commit -m "$($msg -join ' ')"; git push origin (git rev-parse --abbrev-ref HEAD) }

# -------------------------------------------------------------------------
#  GIT - diff / fetch / log
# -------------------------------------------------------------------------
function GitDiff             { git diff @args }
function GitDiffCached        { git diff --cached @args }
function GitDiffStaged        { git diff --staged @args }
function GitDiffWord          { git diff --word-diff @args }
function GitDiffFilesOnly     { git diff --name-only @args }
function GitFetchStatus       { git fetch -v; git status }
function GitFetchAllPrune     { git fetch --all --tags --prune }
function GitFetchOrigin       { git fetch origin }
function GitAmend             { git commit --amend }
function GitAddInteractive    { git add --interactive }
function GitLogPretty         { git log --pretty='%C(Yellow)%h  %C(reset)%ad (%C(Green)%cr%C(reset))%x09 %C(Cyan)%an: %C(reset)%s' -20 }
function GitLogPrettyLongHash { git log --pretty='%C(Yellow)%H  %C(reset)%ad (%C(Green)%cr%C(reset))%x09 %C(Cyan)%an: %C(reset)%s' -20 }
function GitLogAllGraph       { git log --oneline --all --graph --decorate }
function GitLogStatPatch      { git log --stat --patch }
function GitLogGraphPretty    { git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%ar) %C(bold blue)<%an>%Creset' }
function GitLogGraphPrettyAll { git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%ar) %C(bold blue)<%an>%Creset' --all }
function GitLogGraphPrettyDate { git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%ad) %C(bold blue)<%an>%Creset' --date=short }
function GitLogGraph          { git log --oneline --decorate --graph }
function GitLogGraphAll       { git log --oneline --decorate --graph --all }
function GitShow              { git show @args }
function GitShowBranchAll     { git show-branch -a }
function GitTagGrep           { param([string]$Pattern) git show-ref --tags | Select-String $Pattern }
function GitWch                { git log --patch --abbrev-commit --pretty=medium --raw }

# -------------------------------------------------------------------------
#  GIT - merge / rebase / reset / restore / stash / switch / tag / worktree
# -------------------------------------------------------------------------
function GitMergeAbort        { git merge --abort }
function GitMergeContinue     { git merge --continue }
function GitMergeSquash        { git merge --squash @args }
function GitMergeFfOnly        { git merge --ff-only @args }
function GitMergeDance {
    git checkout main; git pull; git merge develop; git push; git checkout develop
}
function GitPushForceLease     { git push --force-with-lease }
function GitPushSetUpstream    { git push --set-upstream origin (git rev-parse --abbrev-ref HEAD) }
function GitPushOriginAllTags  { git push origin --all; git push origin --tags }
function GitPush               { git push origin (git rev-parse --abbrev-ref HEAD) }
function GitPull {
    $branch = git rev-parse --abbrev-ref HEAD
    git pull origin $branch
    Write-Host ""
    git log --pretty="%h %cr`t %an: %s" -10 | more
}
function GitRemoteVerbose      { git remote -v }
function GitRemoteAdd          { git remote add @args }
function GitRemoteRemove       { git remote remove @args }
function GitRemoteRename       { git remote rename @args }
function GitRemoteUpdate       { git remote update }
function GitRebase             { git rebase @args }
function GitRebaseInteractive  { git rebase -i @args }
function GitRebaseAbort        { git rebase --abort }
function GitRebaseContinue     { git rebase --continue }
function GitRebaseOnto         { git rebase --onto @args }
function GitRebaseDevelop      { git rebase develop }
function GitRebaseMain         { git rebase main }
function GitRebaseSkip         { git rebase --skip }
function GitReset              { git reset @args }
function GitResetDashDash      { git reset -- @args }
function GitResetHard          { git reset --hard @args }
function GitResetHardOneBack   { git reset HEAD^ --hard }
function GitResetSoftOneBack   { git reset HEAD^ --soft }
function GitResetKeep          { git reset --keep }
function GitResetSoft          { git reset --soft }
function GitResetUndo          { git reset --soft HEAD~1 }
function GitRestore            { git restore @args }
function GitRestoreSource      { git restore --source @args }
function GitRestoreStaged      { git restore --staged @args }
function GitPristine           { git reset --hard; git clean -dfx }
function GitSubmoduleInit      { git submodule init }
function GitSubmoduleUpdate    { git submodule update }
function GitStashPush          { git stash push @args }
function GitStashApply         { git stash apply }
function GitStashClear         { git stash clear }
function GitStashDrop          { git stash drop }
function GitStashList          { git stash list }
function GitStashPop           { git stash pop }
function GitStashShow          { git stash show --text }
function GitStashAll           { git stash --all }
function GitStash              { git stash }
function GitSwitch             { git switch @args }
function GitSwitchCreate       { git switch --create @args }
function GitSwitchDevelop      { git switch develop }
function GitSwitchMain         { git switch main }
function GitTagAnnotate        { git tag --annotate @args }
function GitTagSign            { git tag --sign @args }
function GitTagSortedVersion   { git tag | Sort-Object }
function GitShortlogCount      { git shortlog -sn }
function GitShortlogUsers      { git shortlog -s -n --all --no-merges }
function GitArchiveExport      { git archive --format zip --output @args }
function GitIgnoreAssumeUnchanged   { git update-index --assume-unchanged @args }
function GitUnignoreAssumeUnchanged { git update-index --no-assume-unchanged @args }
function GitWorktree           { git worktree @args }
function GitWorktreeAdd        { git worktree add @args }
function GitWorktreeList       { git worktree list }
function GitWorktreeRemove     { git worktree remove @args }
function GitTrackUpstream      { git branch "--set-upstream-to=origin/$(git rev-parse --abbrev-ref HEAD)" }
function GitUnstageAll         { git rm --cached -rf . }
function GitSize {
    git status --porcelain | ForEach-Object { $_.Substring(3).Trim('"') } | ForEach-Object {
        if (Test-Path $_) { (Get-Item $_).Length } else { 0 }
    } | Measure-Object -Sum | ForEach-Object { '{0:N2}MB' -f ($_.Sum / 1MB) }
}
if (Get-Command gitk -ErrorAction SilentlyContinue) {
    function GitK { gitk --all $(git log --walk-reflogs --pretty=%h) }
    Set-UserAlias 'gke' 'GitK'
}

# -------------------------------------------------------------------------
#  GIT alias table (git-alias-name -> function-name)
# -------------------------------------------------------------------------
$gitAliasMap = @{
    'ga'          = 'GitAdd'
    'ga.'         = 'GitAddDot'
    'gaa'         = 'GitAddAll'
    'gac'         = 'GitAddCommit'
    'gapa'        = 'GitAddPatch'
    'gau'         = 'GitAddUpdate'
    'gav'         = 'GitAddVerbose'
    'gba'         = 'GitBranchAll'
    'gbd'         = 'GitBranchDelete'
    'gbdf'        = 'GitBranchDeleteForce'
    'gbnm'        = 'GitBranchNoMerged'
    'gbr'         = 'GitBranch'
    'gbra'        = 'GitBranchAllSorted'
    'gbrc'        = 'GitBranchNewFrom'
    'gbrdelete'   = 'GitBranchDeleteForceArg'
    'gbrg'        = 'GitBranchAllSortedGrep'
    'gbrt'        = 'GitBranchRecentTable'
    'gco'         = 'GitCheckout'
    'gcob'        = 'GitCheckoutBranch'
    'gcom'        = 'GitCheckoutMain'
    'gch'         = 'GitCheckout'
    'gchm'        = 'GitCheckoutMain'
    'gchours'     = 'GitCheckoutOurs'
    'gchtheirs'   = 'GitCheckoutTheirs'
    'gcl'         = 'GitClone'
    'gclean'      = 'GitClean'
    'gc'          = 'GitCommit'
    'gcm'         = 'GitCommitMessage'
    'gcp'         = 'GitCherryPick'
    'gcpa'        = 'GitCherryPickAbort'
    'gcpc'        = 'GitCherryPickContinue'
    'groot'       = 'GitRoot'
    'gss'         = 'GitStatusShort'
    'gsb'         = 'GitStatusShortBranch'
    'gs'          = 'GitStatusShort'
    'gst'         = 'GitStatus'
    'gd'          = 'GitDiff'
    'gdc'         = 'GitDiffCached'
    'gdca'        = 'GitDiffCached'
    'gds'         = 'GitDiffStaged'
    'gdw'         = 'GitDiffWord'
    'gfiles'      = 'GitDiffFilesOnly'
    'gf'          = 'GitFetchStatus'
    'gfa'         = 'GitFetchAllPrune'
    'gfo'         = 'GitFetchOrigin'
    'gfix'        = 'GitAmend'
    'gi'          = 'GitAddInteractive'
    'gl'          = 'GitLogPretty'
    'gla'         = 'GitLogPrettyLongHash'
    'glall'       = 'GitLogAllGraph'
    'glgp'        = 'GitLogStatPatch'
    'glol'        = 'GitLogGraphPretty'
    'glola'       = 'GitLogGraphPrettyAll'
    'glods'       = 'GitLogGraphPrettyDate'
    'glog'        = 'GitLogGraph'
    'gloga'       = 'GitLogGraphAll'
    'gshow'       = 'GitShow'
    'gshowall'    = 'GitShowBranchAll'
    'gtag'        = 'GitTagGrep'
    'gwch'        = 'GitWch'
    'gma'         = 'GitMergeAbort'
    'gmc'         = 'GitMergeContinue'
    'gms'         = 'GitMergeSquash'
    'gmff'        = 'GitMergeFfOnly'
    'gmerge'      = 'GitMergeDance'
    'gpf'         = 'GitPushForceLease'
    'gpsup'       = 'GitPushSetUpstream'
    'gpoat'       = 'GitPushOriginAllTags'
    'gpush'       = 'GitPush'
    'gpull'       = 'GitPull'
    'gpop'        = 'GitStashPop'
    'grv'         = 'GitRemoteVerbose'
    'gremote'     = 'GitRemoteVerbose'
    'gra'         = 'GitRemoteAdd'
    'grrm'        = 'GitRemoteRemove'
    'grmv'        = 'GitRemoteRename'
    'gru'         = 'GitResetDashDash'
    'grb'         = 'GitRebase'
    'grbi'        = 'GitRebaseInteractive'
    'grba'        = 'GitRebaseAbort'
    'grbc'        = 'GitRebaseContinue'
    'grc'         = 'GitRebaseContinue'
    'grbo'        = 'GitRebaseOnto'
    'grbd'        = 'GitRebaseDevelop'
    'grbm'        = 'GitRebaseMain'
    'grbs'        = 'GitRebaseSkip'
    'grh'         = 'GitReset'
    'grhh'        = 'GitResetHard'
    'grhard'      = 'GitResetHardOneBack'
    'grsoft'      = 'GitResetSoftOneBack'
    'grhk'        = 'GitResetKeep'
    'grhs'        = 'GitResetSoft'
    'gundo'       = 'GitResetUndo'
    'grs'         = 'GitRestore'
    'grss'        = 'GitRestoreSource'
    'grst'        = 'GitRestoreStaged'
    'gpristine'   = 'GitPristine'
    'gsi'         = 'GitSubmoduleInit'
    'gsu'         = 'GitSubmoduleUpdate'
    'gsta'        = 'GitStashPush'
    'gstaa'       = 'GitStashApply'
    'gstc'        = 'GitStashClear'
    'gstd'        = 'GitStashDrop'
    'gstl'        = 'GitStashList'
    'gstp'        = 'GitStashPop'
    'gsts'        = 'GitStashShow'
    'gstall'      = 'GitStashAll'
    'gstash'      = 'GitStash'
    'gsw'         = 'GitSwitch'
    'gswc'        = 'GitSwitchCreate'
    'gswd'        = 'GitSwitchDevelop'
    'gswm'        = 'GitSwitchMain'
    'gta'         = 'GitTagAnnotate'
    'gts'         = 'GitTagSign'
    'gtv'         = 'GitTagSortedVersion'
    'gcount'      = 'GitShortlogCount'
    'guser'       = 'GitShortlogUsers'
    'gexport'     = 'GitArchiveExport'
    'gignore'     = 'GitIgnoreAssumeUnchanged'
    'gunignore'   = 'GitUnignoreAssumeUnchanged'
    'gwt'         = 'GitWorktree'
    'gwta'        = 'GitWorktreeAdd'
    'gwtls'       = 'GitWorktreeList'
    'gwtrm'       = 'GitWorktreeRemove'
    'gtrack'      = 'GitTrackUpstream'
    'gunstage'    = 'GitUnstageAll'
    'gsize'       = 'GitSize'
}

foreach ($kv in $gitAliasMap.GetEnumerator()) {
    Set-UserAlias -Name $kv.Key -Value $kv.Value
}

Write-Host "Loaded $($gitAliasMap.Count) git aliases + nav/util/npm/yarn/pip/cargo/docker/kubectl/terraform/chezmoi aliases from the profile" -ForegroundColor DarkGray

# -------------------------------------------------------------------------
#  GIT - common short aliases (g, gs, gc, gp, gl, gd)
# -------------------------------------------------------------------------
Set-UserAlias 'g'  'GitStatusShort'
Set-UserAlias 'gs' 'GitStatusShort'
Set-UserAlias 'gc' 'GitCommit'
Set-UserAlias 'gp' 'GitPush'
Set-UserAlias 'gl' 'GitLogPretty'
Set-UserAlias 'gd' 'GitDiff'

# @end

# @group system
# -------------------------------------------------------------------------
#  ENVIRONMENT
# -------------------------------------------------------------------------
# 1. setenv variablenamehere valuehere
function Set-UserEnv {
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [string]$Value
    )

    # Check if both parameters are provided
    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Value)) {
        Write-Host "Description: Sets a persistent User environment variable."
        Write-Host "Usage:       setenv <Variable_Name> <Value>" -ForegroundColor Yellow
        Write-Host "Example:     setenv MY_API_KEY 12345-abcde" -ForegroundColor Cyan
        return
    }

    # Set the variable permanently in the Windows User registry
    [Environment]::SetEnvironmentVariable($Name, $Value, [System.EnvironmentVariableTarget]::User)
    
    # Set the variable temporarily for the current PowerShell session so it can be used immediately
    Set-Item -Path "Env:\$Name" -Value $Value
    
    Write-Host "Environment variable '$Name' has been set successfully." -ForegroundColor Green
}

Set-Alias -Name setenv -Value Set-UserEnv

# 2. getenv: Saves search results to a global map
function Get-UserEnv {
    param(
        [Parameter(Position = 0)]
        [string]$Pattern = ""
    )
    
    $vars = Get-ChildItem Env: | Where-Object { $_.Name -match $Pattern -or $_.Value -match $Pattern } | Sort-Object Name
    
    if ($vars.Count -eq 0) {
        Write-Host "No environment variables found matching '$Pattern'." -ForegroundColor Yellow
        return
    }

    # Reset the global map for this session
    $global:LastGetEnvMap = @{}
    $id = 1

    $vars | ForEach-Object {
        $global:LastGetEnvMap[$id] = $_.Name
        [PSCustomObject]@{
            ID    = $id
            Name  = $_.Name
            Value = $_.Value
        }
        $id++
    } | Format-Table -AutoSize
}
Set-Alias -Name getenv -Value Get-UserEnv


# 3. delenv valuehere
function Remove-UserEnv {
    param(
        [Parameter(Position = 0)]
        [string]$Pattern
    )

    # Print help if no search pattern is provided
    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        Write-Host "Description: Searches and interactively removes an environment variable."
        Write-Host "Usage:       delenv <Search_Term>" -ForegroundColor Yellow
        Write-Host "Example:     delenv git" -ForegroundColor Cyan
        return
    }

    # Search for variables matching the pattern (case-insensitive)
    $vars = Get-ChildItem Env: | Where-Object { $_.Name -match$Pattern } | Sort-Object Name
    
    if ($vars.Count -eq 0) {
        Write-Host "No environment variables found matching '$Pattern'." -ForegroundColor Yellow
        return
    }

    # Generate the numbered list and display it
    $map = @{}; $id = 1
    
    Write-Host "`nSelect an environment variable to delete:" -ForegroundColor Cyan
    $displayList = @()
    foreach ($v in $vars) {
        $map[$id] = $v.Name
        $displayList += [PSCustomObject]@{
            ID    = $id
            Name  = $v.Name
            Value = $v.Value
        }
        $id++
    }
    
    # Print the table to the console
    $displayList | Format-Table -AutoSize | Out-String | Write-Host

    # Prompt the user for the ID
    $selection = Read-Host "Enter the ID to delete (or press Enter to cancel)"
    
    if ([string]::IsNullOrWhiteSpace($selection)) {
        Write-Host "Operation cancelled." -ForegroundColor DarkGray
        return
    }

    # Validate that the input is a valid number from the generated list
    if (-not ($selection -match '^\d+$') -or -not $map.ContainsKey([int]$selection)) {
        Write-Host "Invalid ID selected. Operation cancelled." -ForegroundColor Red
        return
    }

    $nameToDelete = $map[[int]$selection]

    # Show the selected variable and ask for final confirmation
    $userValue = [Environment]::GetEnvironmentVariable($nameToDelete, [System.EnvironmentVariableTarget]::User)
    $sessionValue = (Get-Item "Env:\$nameToDelete" -ErrorAction SilentlyContinue).Value
    $displayValue = if ($userValue) { $userValue } elseif ($sessionValue) { $sessionValue } else { $null }

    Write-Host "`n--- Deleting Environment Variable ---" -ForegroundColor Cyan
    Write-Host "Name:   $nameToDelete"
    Write-Host "Value:  $displayValue"
    Write-Host "-------------------------------------" -ForegroundColor Cyan

    $confirm = Read-Host "Are you sure you want to delete this variable? (y/n)"
    
    if ($confirm.Trim().ToLower() -ne 'y') {
        Write-Host "Deletion cancelled." -ForegroundColor DarkGray
        return
    }

    # Execute the deletion permanently and locally
    [Environment]::SetEnvironmentVariable($nameToDelete,$null, [System.EnvironmentVariableTarget]::User)
    
    if (Test-Path "Env:\$nameToDelete") {
        Remove-Item "Env:\$nameToDelete"
    }

    Write-Host "Successfully deleted '$nameToDelete'." -ForegroundColor Green
}

Set-Alias -Name delenv -Value Remove-UserEnv


# delhistory pass
# 1-3, 5, 7-15
function Remove-HistoryItem {
    param(
        [Parameter(Position = 0)]
        [string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        Write-Host "Description: Searches and deletes specific commands from your PowerShell history."
        Write-Host "Usage:       delhistory <Search_Term>" -ForegroundColor Yellow
        Write-Host "Example:     delhistory password" -ForegroundColor Cyan
        return
    }

    # Locate the PSReadLine history file
    $historyPath = (Get-PSReadLineOption).HistorySavePath;
    if (-not (Test-Path -Path $historyPath)) {
        Write-Host "No PSReadLine history file found." -ForegroundColor Yellow
        return
    }

    # Fast file read using .NET
    $allLines = [System.IO.File]::ReadAllLines($historyPath);
    if ($allLines.Count -eq 0) {
        Write-Host "History file is empty." -ForegroundColor Yellow
        return
    }

    $map = @{};$displayId = 1;
    $displayList = New-Object 'System.Collections.Generic.List[PSCustomObject]';

    # Fast match scanning
    for ($i = 0; $i -lt $allLines.Count; $i++) {
        if ($allLines[$i] -match $Pattern) {$map[$displayId] =$i;
            $displayList.Add([PSCustomObject]@{
                ID      = $displayId
                Command = $allLines[$i]
            });
            $displayId++;
        }
    }

    if ($displayList.Count -eq 0) {
        Write-Host "No history entries found matching '$Pattern'." -ForegroundColor Yellow
        return
    }

    # Display results
    Write-Host "`nSelect history items to delete:" -ForegroundColor Cyan
    $displayList | Format-Table -AutoSize | Out-String | Write-Host

    # Prompt user
    $selection = Read-Host "Enter IDs to delete (e.g. 1-3, 5, 7-15) or press Enter to cancel"
    if ([string]::IsNullOrWhiteSpace($selection)) {
        Write-Host "Operation cancelled." -ForegroundColor DarkGray
        return
    }

    # Parse inputs into a HashSet to prevent duplicate entries
    $selectedIds = New-Object 'System.Collections.Generic.HashSet[int]';
    $parts = $selection -split ',';

    foreach ($part in $parts) {
        $cleanPart = $part.Trim();
        if ($cleanPart -match '^(\d+)-(\d+)$') {
            $start = [int]$matches[1];
            $end = [int]$matches[2];
            $step = if ($start -le $end) { 1 } else { -1 };
            for ($num = $start; $num -ne ($end + $step); $num += $step) {
                [void]$selectedIds.Add($num);
            }
        } elseif ($cleanPart -match '^\d+$') {
            [void]$selectedIds.Add([int]$cleanPart);
        }
    }

    # Filter to valid display IDs present in map
    $validIds = $selectedIds | Where-Object { $map.ContainsKey($_) };

    if (-not $validIds) {
        Write-Host "No valid IDs selected. Operation cancelled." -ForegroundColor Red
        return
    }

    # Map selected IDs to target line indexes with O(1) HashSet lookup
    $indexesToDelete = New-Object 'System.Collections.Generic.HashSet[int]';
    foreach ($id in $validIds) {
        [void]$indexesToDelete.Add($map[$id]);
    }

    Write-Host "`nYou selected $($validIds.Count) item(s) to delete." -ForegroundColor Cyan
    $confirm = Read-Host "Are you sure? (y/n)"
    if ($confirm.Trim().ToLower() -ne 'y') {
        Write-Host "Deletion cancelled." -ForegroundColor DarkGray
        return
    }

    # Rebuild history list in memory
    $newLines = New-Object 'System.Collections.Generic.List[string]' ($allLines.Count -$indexesToDelete.Count);
    for ($i = 0; $i -lt $allLines.Count; $i++) {
        if (-not $indexesToDelete.Contains($i)) {$newLines.Add($allLines[$i]);
        }
    }

    # Fast file write back to disk
    [System.IO.File]::WriteAllLines($historyPath,$newLines);

    # Clear matches from active session memory
    Get-History | Where-Object { $_.CommandLine -match$Pattern } | Clear-History -ErrorAction SilentlyContinue;

    Write-Host "Successfully deleted $($validIds.Count) item(s) from history." -ForegroundColor Green
}

Set-Alias -Name delhistory -Value Remove-HistoryItem

# @end

# @group nav
# -------------------------------------------------------------------------
#  DIRECTORY JUMPS - quick cd to common paths
# -------------------------------------------------------------------------
function cdProjects { Set-Location "$HOME\Projects" }
function cdDocs     { Set-Location "$HOME\Documents" }
function cdDesktop { Set-Location "$HOME\Desktop" }
function cdDownloads { Set-Location "$HOME\Downloads" }
function cdTemp     { Set-Location "$env:TEMP" }

Set-UserAlias 'jp'  'cdProjects'
Set-UserAlias 'jd'  'cdDocs'
Set-UserAlias 'jdp' 'cdDesktop'
Set-UserAlias 'jdl' 'cdDownloads'
Set-UserAlias 'jt'  'cdTemp'

# @end

# -------------------------------------------------------------------------
#  POSIX CLI ALIASES
# -------------------------------------------------------------------------
Set-UserAlias 'cat'  'Get-Content'
Set-UserAlias 'grep' 'Select-String'
Set-UserAlias 'which' 'Get-Command'

# mkdir -p equivalent
function MkDirP {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}
Set-UserAlias 'mkdirp' 'MkDirP'

# @group dev
# -------------------------------------------------------------------------
#  NPM / YARN - additional shortcuts
# -------------------------------------------------------------------------
if (Get-Command npm -ErrorAction SilentlyContinue) {
    Set-UserAlias 'np' 'npm'
}
if (Get-Command yarn -ErrorAction SilentlyContinue) {
    Set-UserAlias 'yn' 'yarn'
}

# @end

# @group search
# -------------------------------------------------------------------------
#  HISTORY - bash-like history access
# -------------------------------------------------------------------------
Set-UserAlias 'history' 'Get-History'
# @end
