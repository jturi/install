# Preflight step: validate the catalog. Always runs first.
# ASCII only, PowerShell 5.1 syntax only.
. (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'helpers.ps1')

function Invoke-PreflightStep {
  param([string[]]$Items = @(), [object[]]$Catalog = @(), [string]$CatalogPath = '')
  if (-not $CatalogPath -or $CatalogPath -eq '') { throw 'preflight: no catalog path given' }
  $Rows = Import-Catalog -Path $CatalogPath
  if ($Rows -eq $null -or $Rows.Count -eq 0) { throw "preflight: no rows in $CatalogPath" }
  Write-StepOk ("catalog ok: " + $Rows.Count + " windows rows")
}
