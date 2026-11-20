# Bootstrap a new Windows machine: download this repo to ~\install and run
# setup.ps1, which shows the menu and installs the ticked items with Scoop.
# Paste-safe: the body is one script block, so pasting the whole file into
# PowerShell never closes it. Run in a normal (not Administrator) PowerShell.
# Reruns are safe: installed apps are skipped and changed files are backed up.
# A git clone in ~\install is pulled; a downloaded copy is replaced (the old
# one is moved to ~\install.bak.<time>).
#
#   irm https://raw.githubusercontent.com/jturi/install/main/bootstrap.ps1 | iex
#   powershell -ExecutionPolicy Bypass -File bootstrap.ps1
#
# Environment:
#   INSTALL_DIR     where the repo goes (default ~\install)
#   INSTALL_DRYRUN  set to 1 to print what would be installed
#   GITHUB_TOKEN    token for a private repo; else `gh auth token`, else a prompt
#
# What gets installed comes from the setup.ps1 menu, or without one from the
# saved selection in ~\.local\bootstrap\config.
# Log: ~\.local\bootstrap\logs\bootstrap-<time>.log
& {
  $repo = 'jturi/install'
  $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
  $dir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $userHome 'install' }
  $url = if ($env:BOOTSTRAP_URL) { $env:BOOTSTRAP_URL } else { "https://api.github.com/repos/$repo/zipball/main" }
  $dry = $env:INSTALL_DRYRUN -eq '1'
  $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

  function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
  function Ok($m) { Write-Host " ok $m" -ForegroundColor Green }
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

    # --- get the repo ---------------------------------------------------------
    # A git clone (yours, with your changes) is updated in place, like
    # bootstrap.sh does; only a downloaded copy is replaced.
    if (Test-Path (Join-Path $dir '.git')) {
      Info "$dir is a git clone, pulling"
      if (Get-Command git -ErrorAction SilentlyContinue) {
        $global:LASTEXITCODE = 0
        & git -C $dir pull --ff-only | Out-Host
        if ($LASTEXITCODE) { Write-Warning "git pull failed, using $dir as is" }
      }
      else { Write-Warning "git not found, using $dir as is" }
    }
    else {
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
          # Zero and free the unmanaged copy of the token once it is read.
          $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
          try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
          finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
          if (-not $token) { return }
          try { & $get $token } catch { Write-Error "download failed: $url ($_)"; return }
        }
        Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'src')
        $top = @(Get-ChildItem (Join-Path $tmp 'src') -Directory)[0]
        if (-not (Test-Path (Join-Path $top.FullName 'setup.ps1'))) { Write-Error 'no setup.ps1 in the download'; return }
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
        # Short hash, commit date and first message line of the downloaded commit.
        # Informational only: a failed lookup must not stop the install.
        try {
          $h = @{ 'User-Agent' = 'install-bootstrap' }
          if ($token) { $h['Authorization'] = "Bearer $token" }
          $info = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/$commit" -Headers $h -ErrorAction Stop
          $short = ([string]$info.sha).Substring(0, 7)
          $when = ([DateTimeOffset]::Parse($info.commit.committer.date)).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
          $subject = (([string]$info.commit.message) -split "`n")[0].Trim()
          Ok "commit $short from $($when): $subject"
        }
        catch { Write-Warning "could not read the commit date: $($_.Exception.Message)" }
      }
      finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $setup = Join-Path $dir 'setup.ps1'
    Info "running $setup"
    $a = @()
    if ($dry) { $a += '-DryRun' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup @a
    # Report a failure without `exit`: under `irm | iex` exit would close
    # the user's PowerShell window.
    if ($LASTEXITCODE) { Write-Error "setup.ps1 failed (exit $LASTEXITCODE); see the output above" }
  }
  finally {
    if ($logging) { Stop-Transcript | Out-Null }
  }
}
