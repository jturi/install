# Bootstrap a new Windows machine: install Scoop and git, download this repo to
# ~\install, then install the Windows items from catalog.txt with Scoop.
# Paste-safe: the body is one script block, so pasting the whole file into
# PowerShell never closes it. Run in a normal (not Administrator) PowerShell.
# Reruns are safe: installed apps are skipped and changed files are backed up.
#
#   irm https://raw.githubusercontent.com/jturi/install/main/bootstrap.ps1 | iex
#   powershell -ExecutionPolicy Bypass -File bootstrap.ps1
#
# Environment:
#   INSTALL_DIR     where the repo goes (default ~\install)
#   INSTALL_ITEMS   extra catalog items, e.g. "wezterm,vlc"; "-rustup" drops a
#                   default; "all" selects every Windows item
#   INSTALL_DRYRUN  set to 1 to print what would be installed
#   GITHUB_TOKEN    token for a private repo; else `gh auth token`, else a prompt
#
# Log: ~\.local\bootstrap\logs\bootstrap-<time>.log
# When the repo ships setup.ps1 (the menu-driven installer), this hands off to it.
& {
  $repo = 'jturi/install'
  $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
  $dir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $userHome 'install' }
  $url = if ($env:BOOTSTRAP_URL) { $env:BOOTSTRAP_URL } else { "https://api.github.com/repos/$repo/zipball/main" }
  $dry = $env:INSTALL_DRYRUN -eq '1'
  $wanted = @(($env:INSTALL_ITEMS -split '[,\s]+') | Where-Object { $_ })
  $results = New-Object System.Collections.Generic.List[object]
  $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

  function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
  function Ok($m) { Write-Host " ok $m" -ForegroundColor Green }
  function Add-Result($status, $label, $note) {
    $results.Add([pscustomobject]@{ Status = $status; Label = $label; Note = $note })
  }
  # Run a native command, print it first, retry once (network hiccups).
  function Invoke-Native($text, [scriptblock]$cmd) {
    if ($dry) { Write-Host "   [dry-run] $text"; return }
    for ($try = 1; $try -le 2; $try++) {
      Write-Host "   `$ $text" -ForegroundColor DarkGray
      # Out-Host: tool output must not leak into a function's return value.
      & $cmd | Out-Host
      if (-not $LASTEXITCODE) { return }
      if ($try -lt 2) { Write-Warning "$text exited $LASTEXITCODE; retrying in 5s"; Start-Sleep 5 }
    }
    throw "$text exited $LASTEXITCODE"
  }
  # Next free <path>.bak.<time>[.n], so backups never overwrite each other.
  function Get-BackupPath($path) {
    $bak = $base = "$path.bak.$stamp"
    $n = 0
    while (Test-Path $bak) { $n++; $bak = "$base.$n" }
    $bak
  }

  $logDir = Join-Path $userHome '.local\bootstrap\logs'
  $logging = $false
  if (-not $dry) {
    try {
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
      Start-Transcript -Path (Join-Path $logDir "bootstrap-$stamp.log") | Out-Null
      $logging = $true
    } catch { Write-Warning "not logging: $_" }
  }

  try {
    Info "bootstrap.ps1 on PowerShell $($PSVersionTable.PSVersion)"
    # INSTALL_ALLOW_ADMIN=1 is for CI runners, which are always elevated.
    if ($env:OS -eq 'Windows_NT' -and $env:INSTALL_ALLOW_ADMIN -ne '1') {
      $id = [Security.Principal.WindowsIdentity]::GetCurrent()
      if ((New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning 'Run this in a normal PowerShell, not as Administrator: Scoop refuses elevated installs.'
        return
      }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # --- download the repo ----------------------------------------------------
    $token = $env:GITHUB_TOKEN
    if (-not $token -and (Get-Command gh -ErrorAction SilentlyContinue)) {
      try { $token = (& gh auth token 2>$null) } catch { $token = $null }
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("install-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
      $zip = Join-Path $tmp 'repo.zip'
      Info "downloading $repo"
      $get = {
        param($t)
        $h = @{ 'User-Agent' = 'install-bootstrap' }
        if ($t) { $h['Authorization'] = "Bearer $t" }
        Invoke-WebRequest -Uri $url -OutFile $zip -Headers $h -UseBasicParsing -ErrorAction Stop
      }
      try { & $get $token } catch {
        if ($token) { Write-Error "download failed: $url ($_)"; return }
        $sec = Read-Host 'Download failed; the repo may be private. GitHub token (blank to abort)' -AsSecureString
        $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        if (-not $token) { return }
        try { & $get $token } catch { Write-Error "download failed: $url ($_)"; return }
      }
      Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'src')
      $top = @(Get-ChildItem (Join-Path $tmp 'src') -Directory)[0]
      if (-not (Test-Path (Join-Path $top.FullName 'catalog.txt'))) { Write-Error 'no catalog.txt in the download'; return }
      # GitHub names the top folder <owner>-<repo>-<commit>.
      $commit = ($top.Name -split '-')[-1]
      Set-Content -Path (Join-Path $top.FullName '.source') -Value "$repo@$commit downloaded $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -Encoding Ascii
      if (Test-Path $dir) {
        $bak = Get-BackupPath $dir
        Info "moving the old $dir to $bak"
        Move-Item $dir $bak
      }
      New-Item -ItemType Directory -Path (Split-Path $dir) -Force | Out-Null
      Move-Item $top.FullName $dir
      Ok "$dir ($repo@$commit)"
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    $setup = Join-Path $dir 'setup.ps1'
    if (Test-Path $setup) {
      Info "running $setup"
      $a = @()
      if ($dry) { $a += '-DryRun' }
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup @a
      return
    }

    # --- Scoop and git --------------------------------------------------------
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
      Ok 'Scoop (already installed)'
    }
    else {
      if ((Get-ExecutionPolicy -Scope CurrentUser) -in 'Undefined', 'Restricted', 'AllSigned') {
        Info 'setting the CurrentUser execution policy to RemoteSigned (Scoop needs it)'
        if (-not $dry) { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force }
      }
      Info 'installing Scoop'
      if ($dry) { Write-Host '   [dry-run] irm https://get.scoop.sh | iex' }
      else {
        try {
          Invoke-RestMethod https://get.scoop.sh | Invoke-Expression
          $env:PATH = "$(Join-Path $userHome 'scoop\shims');$env:PATH"
        }
        catch { Write-Error "Scoop install failed: $_"; return }
      }
    }
    $scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $userHome 'scoop' }
    function Test-ScoopApp($app) { Test-Path (Join-Path $scoopRoot "apps\$app\current") }
    function Install-ScoopApp($bucket, $app, $label) {
      if (Test-ScoopApp $app) { Ok "$label (already installed)"; return 'SKIP' }
      if ($bucket -ne 'main' -and -not (Test-Path (Join-Path $scoopRoot "buckets\$bucket"))) {
        Invoke-Native "scoop bucket add $bucket" { scoop bucket add $bucket }
      }
      Info $label
      Invoke-Native "scoop install $bucket/$app" { scoop install "$bucket/$app" }
      'OK'
    }

    try { Add-Result (Install-ScoopApp 'main' 'git' 'git (Scoop buckets need it)') 'git' '' }
    catch { Add-Result 'FAILED' 'git' "$_" }

    # --- catalog items --------------------------------------------------------
    # Format: group|item|label|platforms|default|action
    $items = Get-Content (Join-Path $dir 'catalog.txt') | Where-Object { $_ -match '^[^#\s]' } | ForEach-Object {
      $f = $_ -split '\|'
      if (($f[3] -split ',') -contains 'windows') {
        $on = ($f[4] -eq 'on' -or $wanted -contains 'all' -or $wanted -contains $f[1]) -and -not ($wanted -contains "-$($f[1])")
        if ($on) { [pscustomobject]@{ Item = $f[1]; Label = $f[2]; Action = $f[5] } }
      }
    }
    Info ("selected: " + (($items | ForEach-Object { $_.Label }) -join ', '))

    foreach ($it in $items) {
      try {
        if ($it.Action -like 'scoop:*') {
          $bucket, $app = $it.Action.Substring(6) -split '/'
          Add-Result (Install-ScoopApp $bucket $app $it.Label) $it.Label ''
        }
        elseif ($it.Action -eq 'step:wezterm') {
          $status = Install-ScoopApp 'extras' 'wezterm' $it.Label
          $from = Join-Path $dir 'configs\wezterm\windows.lua'
          $to = Join-Path $userHome '.wezterm.lua'
          if ((Test-Path $to) -and ((Get-FileHash $to).Hash -eq (Get-FileHash $from).Hash)) {
            Ok "$to (unchanged)"
          }
          else {
            if (Test-Path $to) {
              $b = Get-BackupPath $to
              Info "backing up $to to $b"
              if (-not $dry) { Copy-Item $to $b }
            }
            if ($dry) { Write-Host "   [dry-run] copy $from -> $to" }
            else {
              # Write a temp file, then swap it in: never a half-written config.
              Copy-Item $from "$to.tmp" -Force
              Move-Item "$to.tmp" $to -Force
              Ok $to
            }
            $status = 'OK'
          }
          Add-Result $status $it.Label ''
        }
        else {
          Write-Warning "$($it.Label): needs setup.ps1, which this repo does not have yet"
          Add-Result 'WARN' $it.Label 'needs setup.ps1 (not built yet)'
        }
      }
      catch {
        Write-Warning "$($it.Label) failed: $_"
        Add-Result 'FAILED' $it.Label "$_"
      }
    }

    # --- summary --------------------------------------------------------------
    Info 'Summary'
    $colors = @{ OK = 'Green'; SKIP = 'DarkGray'; WARN = 'Yellow'; FAILED = 'Red' }
    foreach ($r in $results) {
      $line = '  {0,-7} {1}' -f $r.Status, $r.Label
      if ($r.Note) { $line += "  - $($r.Note)" }
      Write-Host $line -ForegroundColor $colors[$r.Status]
    }
    if ($logging) { Write-Host "  Log: $(Join-Path $logDir "bootstrap-$stamp.log")" }
    if (@($results | Where-Object { $_.Status -eq 'FAILED' }).Count) {
      Write-Warning 'some steps failed; rerun to retry (installed apps are skipped)'
    }
  }
  finally {
    if ($logging) { Stop-Transcript | Out-Null }
  }
}
