# Parse one .ps1 file with the PowerShell parser. Exit 1 on syntax errors.
# Called by make lint through powershell.exe on Windows. ASCII only.
$ErrorActionPreference = 'Stop'
$Tokens = $null
$Errors = $null
$Path = $args[0]
$Full = (Resolve-Path $Path).Path
[void][System.Management.Automation.Language.Parser]::ParseFile($Full, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count -gt 0) {
  foreach ($e in $Errors) { Write-Output $e.Message }
  exit 1
}
