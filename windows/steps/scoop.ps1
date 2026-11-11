# Scoop step: install ticked scoop:<bucket>/<app> items; git and make always.
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
  $Wanted += @{ Bucket = 'main'; App = 'git' }
  $Wanted += @{ Bucket = 'main'; App = 'make' }
  $Buckets = @()
  foreach ($W in $Wanted) {
    if (-not ($Buckets -contains $W.Bucket)) { $Buckets += $W.Bucket }
  }
  foreach ($B in $Buckets) {
    if ($Verify) { Write-StepInfo ("would add bucket " + $B); continue }
    scoop bucket add $B
  }
  foreach ($W in $Wanted) {
    if ($Verify) { Write-StepInfo ("would install " + $W.Bucket + "/" + $W.App); continue }
    scoop install ($W.Bucket + '/' + $W.App)
  }
  Write-StepOk ("scoop: " + $Wanted.Count + " apps")
}
