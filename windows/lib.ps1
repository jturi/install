# Windows catalog and config. Dot-source from tests and setup.ps1.
# ASCII only: Windows PowerShell 5.1 misreads UTF-8 without a BOM.
$ConfigHeader = '# Saved by the installer. 1 = install, 0 = leave alone. Safe to edit by hand.'

function Get-ScoopRoot {
  param([string]$ScoopCommand = '')
  if ($env:SCOOP -and $env:SCOOP -ne '') { return $env:SCOOP }
  $CmdPath = $ScoopCommand
  if (-not $CmdPath -or $CmdPath -eq '') {
    $Found = Get-Command scoop -ErrorAction SilentlyContinue
    if ($Found -and $Found.Source) { $CmdPath = $Found.Source }
  }
  if ($CmdPath -and $CmdPath -ne '' -and (Test-Path $CmdPath)) {
    $Dir = Split-Path $CmdPath -Parent
    if ((Split-Path $Dir -Leaf) -eq 'shims') { return (Split-Path $Dir -Parent) }
    return $Dir
  }
  $HomeDir = $env:USERPROFILE
  if (-not $HomeDir -or $HomeDir -eq '') { $HomeDir = $env:HOME }
  if (-not $HomeDir -or $HomeDir -eq '') { $HomeDir = '~' }
  return (Join-Path $HomeDir 'scoop')
}

function Test-CatalogLine($Group, $Item, $Label, $Platforms, $Default, $Action, $Extra) {
  if ($Extra -and $Extra -ne '') { return 'too many fields' }
  if (-not $Group -or -not $Item -or -not $Label -or -not $Platforms -or -not $Default -or -not $Action) {
    return 'too few fields'
  }
  if ($Default -ne 'on' -and $Default -ne 'off') { return 'default must be on or off' }
  foreach ($Word in ($Platforms -split ',')) {
    if ($Word -ne 'linux' -and $Word -ne 'macos' -and $Word -ne 'wsl' -and $Word -ne 'windows') {
      return "unknown platform '$Word'"
    }
  }
  if ($Action -eq 'pkg') { return '' }
  if ($Action -match '^scoop:[^/]+/.+') { return '' }
  if ($Action -match '^step:.+') { return '' }
  return "unknown action '$Action'"
}

function Import-Catalog {
  param([string]$Path = '')
  if (-not (Test-Path $Path)) { throw "cannot read catalog: $Path" }
  $Text = [IO.File]::ReadAllText($Path)
  $Lines = $Text -split "`n"
  $Rows = @()
  $n = 0
  foreach ($Raw in $Lines) {
    $n = $n + 1
    $Line = $Raw
    if ($Line.EndsWith("`r")) { $Line = $Line.Substring(0, $Line.Length - 1) }
    if ($n -eq 1 -and $Line.Length -gt 0 -and $Line[0] -eq [char]0xFEFF) {
      $Line = $Line.Substring(1)
    }
    if ($Line -match '^\s*$') { continue }
    if ($Line.StartsWith('#')) { continue }
    $Parts = $Line -split '\|'
    $Group = ''; $Item = ''; $Label = ''; $Platforms = ''; $Default = ''; $Action = ''; $Extra = ''
    if ($Parts.Length -gt 0) { $Group = $Parts[0] }
    if ($Parts.Length -gt 1) { $Item = $Parts[1] }
    if ($Parts.Length -gt 2) { $Label = $Parts[2] }
    if ($Parts.Length -gt 3) { $Platforms = $Parts[3] }
    if ($Parts.Length -gt 4) { $Default = $Parts[4] }
    if ($Parts.Length -gt 5) { $Action = $Parts[5] }
    if ($Parts.Length -gt 6) { $Extra = ($Parts[6..($Parts.Length - 1)] -join '|') }
    $Problem = Test-CatalogLine $Group $Item $Label $Platforms $Default $Action $Extra
    if ($Problem -and $Problem -ne '') { throw "bad catalog $Path line ${n}: $Problem" }
    $Keep = $false
    foreach ($Word in ($Platforms -split ',')) {
      if ($Word -eq 'windows') { $Keep = $true }
    }
    if (-not $Keep) { continue }
    $Selected = ($Default -eq 'on')
    $Row = New-Object PSObject -Property @{
      Group = $Group
      Item = $Item
      Label = $Label
      Default = $Default
      Action = $Action
      Key = ($Group + '.' + $Item)
      Selected = $Selected
      New = $false
    }
    $Rows += $Row
  }
  return $Rows
}
# Read one key=value setting from the config file. '' when absent.
function Get-ConfigValue {
  param([string]$Path = '', [string]$Key = '')
  if (-not $Path -or -not (Test-Path $Path)) { return '' }
  $Found = ''
  foreach ($Raw in ([IO.File]::ReadAllText($Path) -split "`n")) {
    $Line = $Raw.TrimEnd("`r").TrimStart([char]0xFEFF)
    if ($Line.StartsWith($Key + '=')) { $Found = $Line.Substring($Key.Length + 1) }
  }
  return $Found
}

# Set one key=value setting, keeping every other line. Writes atomically.
function Set-ConfigValue {
  param([string]$Path = '', [string]$Key = '', [string]$Value = '')
  if ($Value -match "[\r\n]") { throw "config value for $Key must be one line" }
  $Lines = @()
  if (Test-Path $Path) {
    $Lines = @(([IO.File]::ReadAllText($Path) -split "`n") | ForEach-Object { $_.TrimEnd("`r").TrimStart([char]0xFEFF) } | Where-Object { $_ -ne '' })
  }
  $Out = @()
  $Done = $false
  foreach ($Line in $Lines) {
    if ($Line.StartsWith($Key + '=')) {
      if (-not $Done) { $Out += ($Key + '=' + $Value); $Done = $true }
      continue
    }
    $Out += $Line
  }
  if (-not $Done) { $Out += ($Key + '=' + $Value) }
  $Dir = Split-Path $Path -Parent
  if ($Dir -and $Dir -ne '') { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
  $Tmp = "$Path.tmp.$PID"
  try {
    [IO.File]::WriteAllText($Tmp, (($Out -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Move-Item -Force $Tmp $Path
  } catch {
    if (Test-Path $Tmp) { Remove-Item -Force $Tmp }
    throw
  }
}

function Import-Selection {
  param([string]$Path = '', [object[]]$Catalog = @())
  $Seen = @{}
  foreach ($Row in $Catalog) {
    if ($Row.Default -eq 'on') { $Row.Selected = $true } else { $Row.Selected = $false }
    $Row.New = $false
    $Seen[$Row.Key] = $false
  }
  if (-not (Test-Path $Path)) { return @() }
  $Text = [IO.File]::ReadAllText($Path)
  $Lines = $Text -split "`n"
  $Extra = @()
  $n = 0
  foreach ($Raw in $Lines) {
    $n = $n + 1
    $Line = $Raw
    if ($Line.EndsWith("`r")) { $Line = $Line.Substring(0, $Line.Length - 1) }
    if ($n -eq 1 -and $Line.Length -gt 0 -and $Line[0] -eq [char]0xFEFF) {
      $Line = $Line.Substring(1)
    }
    if ($Line -match '^\s*$') { continue }
    if ($Line.StartsWith('#')) { continue }
    $Eq = $Line.IndexOf('=')
    $Key = ''
    $Value = ''
    if ($Eq -ge 0) {
      $Key = $Line.Substring(0, $Eq)
      $Value = $Line.Substring($Eq + 1)
    }
    # Free-text settings (GitHub user, git email) are kept as they are, not as 0/1 flags.
    if ($Eq -ge 0 -and (@('github.user', 'git.email') -ccontains $Key)) { $Extra += $Line; continue }
    if ($Eq -lt 0 -or $Key -eq '' -or ($Value -ne '0' -and $Value -ne '1')) {
      Write-Warning "$Path line ${n}: ignoring '$Line'"
      continue
    }
    $Matched = $false
    foreach ($Row in $Catalog) {
      if ($Row.Key -ceq $Key) {
        $Row.Selected = ($Value -eq '1')
        $Seen[$Key] = $true
        $Matched = $true
        break
      }
    }
    if (-not $Matched) { $Extra += $Line }
  }
  foreach ($Row in $Catalog) {
    if (-not $Seen[$Row.Key]) { $Row.New = $true }
  }
  return $Extra
}

function Save-Selection {
  param([string]$Path = '', [object[]]$Catalog = @(), [string[]]$Extra = @())
  $ErrorActionPreference = 'Stop'
  $Tmp = "$Path.tmp.$PID"
  try {
    $Dir = Split-Path $Path -Parent
    if ($Dir -and $Dir -ne '') {
      New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $Lines = @()
    $Lines += $ConfigHeader
    foreach ($Row in $Catalog) {
      $Val = '0'
      if ($Row.Selected) { $Val = '1' }
      $Lines += ($Row.Key + '=' + $Val)
    }
    foreach ($Line in $Extra) { $Lines += $Line }
    $Rest = @($Lines | Select-Object -Skip 1)
    [Array]::Sort($Rest, [StringComparer]::Ordinal)
    $Unique = @()
    $Prev = $null
    foreach ($Line in $Rest) {
      if ($Prev -ne $null -and $Line -ceq $Prev) { continue }
      $Unique += $Line
      $Prev = $Line
    }
    $Text = $ConfigHeader + "`n" + (($Unique -join "`n") + "`n")
    $Enc = (New-Object Text.UTF8Encoding($false))
    [IO.File]::WriteAllText($Tmp, $Text, $Enc)
    if (Test-Path $Path) {
      $Old = [IO.File]::ReadAllBytes($Path)
      $New = [IO.File]::ReadAllBytes($Tmp)
      $Same = ($Old.Length -eq $New.Length)
      if ($Same) {
        for ($i = 0; $i -lt $Old.Length; $i++) {
          if ($Old[$i] -ne $New[$i]) { $Same = $false; break }
        }
      }
      if ($Same) {
        Remove-Item -Force $Tmp
        return
      }
      $Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
      Copy-Item -Force $Path "$Path.bak.$Stamp"
    }
    Move-Item -Force $Tmp $Path
  } catch {
    if (Test-Path $Tmp) { Remove-Item -Force $Tmp }
    throw
  }
}
