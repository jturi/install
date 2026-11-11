# Scoop step: install ticked scoop:<bucket>/<app> items; git and make always.
# git goes first: `scoop bucket add` needs it. Then the buckets are added and
# `scoop update` refreshes Scoop and every bucket before the installs.
# ASCII only, PowerShell 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

function Invoke-ScoopStep {
  param([object[]]$Catalog = @(), [switch]$Verify)
  $Wanted = @()
  foreach ($Row in $Catalog) {
    if (-not $Row.Selected) { continue }
    if ($Row.Action -match '^scoop:([^/]+)/(.+)') {
      $Wanted += @{ Bucket = $Matches[1]; App = $Matches[2] }
    }
  }
  $Wanted += @{ Bucket = 'main'; App = 'make' }
  $Buckets = @()
  foreach ($W in $Wanted) {
    if (-not ($Buckets -contains $W.Bucket)) { $Buckets += $W.Bucket }
  }
  if ($Verify) {
    Write-StepInfo 'would install main/git'
    foreach ($B in $Buckets) { if (-not (Test-StepScoopBucket $B)) { Write-StepInfo ("would add bucket " + $B) } }
    Write-StepInfo 'would run scoop update'
    foreach ($W in $Wanted) { Write-StepInfo ("would install " + $W.Bucket + "/" + $W.App) }
    return
  }
  Install-StepScoopApp 'main' 'git'
  # A bucket that cannot be added fails its own apps only, and only once.
  $BadBuckets = @()
  foreach ($B in $Buckets) {
    try { Add-StepScoopBucket $B } catch { Write-StepWarn $_.Exception.Message; $BadBuckets += $B }
  }
  $global:LASTEXITCODE = 0
  scoop update
  if ($LASTEXITCODE) { Write-StepWarn "scoop update failed (exit $LASTEXITCODE); installing from the current buckets" }
  $Failed = @()
  foreach ($W in $Wanted) {
    if ($BadBuckets -contains $W.Bucket) { $Failed += ($W.Bucket + '/' + $W.App); continue }
    try { Install-StepScoopApp $W.Bucket $W.App }
    catch { Write-StepWarn $_.Exception.Message; $Failed += ($W.Bucket + '/' + $W.App) }
  }
  if ($Failed.Count -gt 0) { throw ('scoop install failed: ' + ($Failed -join ', ')) }
  Write-StepOk ("scoop: " + ($Wanted.Count + 1) + " apps")
}
