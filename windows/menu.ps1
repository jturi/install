# Selection menu for Windows. ASCII only, PowerShell 5.1 syntax only.
# Mirrors menu_handle_key in lib/menu.sh. State keys: Cursor, OpenGroup,
# Top, Rows, Result, GroupCursor.

function New-MenuState {
  return @{ Cursor = 0; OpenGroup = ''; Top = 0; Rows = 20; Result = ''; GroupCursor = 0 }
}

function Test-MenuAvailable {
  try {
    if ([Console]::IsInputRedirected) { return $false }
    if ([Console]::IsOutputRedirected) { return $false }
  } catch { return $false }
  $Term = $env:TERM
  if (-not $Term -or $Term -eq '' -or $Term -eq 'dumb') { return $false }
  try {
    if ([Console]::WindowHeight -le 0) { return $false }
  } catch { return $false }
  return $true
}

function Format-MenuRow {
  param($Row = $null)
  $Mark = ' '
  if ($Row.Selected) { $Mark = 'x' }
  $Text = '[' + $Mark + '] ' + $Row.Label
  if ($Row.New) { $Text = $Text + '  (new)' }
  return $Text
}

function Update-MenuState {
  param([hashtable]$State = @{}, [string]$Key = '')
  $View = $script:MenuView
  $Groups = $script:MenuGroups
  if (-not $View) { $View = @() }
  if (-not $Groups) { $Groups = @() }
  if ($Key -eq 'up') { $State.Cursor = $State.Cursor - 1 }
  elseif ($Key -eq 'down') { $State.Cursor = $State.Cursor + 1 }
  elseif ($Key -eq 'space') {
    if ($State.OpenGroup -ne '') {
      $Idx = $View[$State.Cursor]
      $script:MenuCatalog[$Idx].Selected = -not $script:MenuCatalog[$Idx].Selected
    } else {
      $Group = $Groups[$State.Cursor]
      $On = 0
      $Total = 0
      for ($i = 0; $i -lt $script:MenuCatalog.Count; $i++) {
        if ($script:MenuCatalog[$i].Group -eq $Group) {
          $Total = $Total + 1
          if ($script:MenuCatalog[$i].Selected) { $On = $On + 1 }
        }
      }
      $Val = $true
      if ($On -ge $Total) { $Val = $false }
      for ($i = 0; $i -lt $script:MenuCatalog.Count; $i++) {
        if ($script:MenuCatalog[$i].Group -eq $Group) { $script:MenuCatalog[$i].Selected = $Val }
      }
    }
  }
  elseif ($Key -eq 'enter') {
    if ($State.OpenGroup -ne '') {
      $State.OpenGroup = ''
      $script:MenuView = @()
      for ($i = 0; $i -lt $Groups.Count; $i++) { $script:MenuView += $i }
      $View = $script:MenuView
      $State.Cursor = $State.GroupCursor
      $State.Top = 0
    } else {
      $Group = $Groups[$State.Cursor]
      $Total = 0
      for ($i = 0; $i -lt $script:MenuCatalog.Count; $i++) {
        if ($script:MenuCatalog[$i].Group -eq $Group) { $Total = $Total + 1 }
      }
      if ($Total -eq 1) {
        for ($i = 0; $i -lt $script:MenuCatalog.Count; $i++) {
          if ($script:MenuCatalog[$i].Group -eq $Group) {
            $script:MenuCatalog[$i].Selected = -not $script:MenuCatalog[$i].Selected
          }
        }
      } else {
        $State.OpenGroup = $Group
        $State.GroupCursor = $State.Cursor
        $State.Cursor = 0
        $State.Top = 0
        $script:MenuView = @()
        for ($i = 0; $i -lt $script:MenuCatalog.Count; $i++) {
          if ($script:MenuCatalog[$i].Group -eq $Group) { $script:MenuView += $i }
        }
        $View = $script:MenuView
      }
    }
  }
  elseif ($Key -eq 'back') {
    if ($State.OpenGroup -ne '') {
      $State.OpenGroup = ''
      $script:MenuView = @()
      for ($i = 0; $i -lt $Groups.Count; $i++) { $script:MenuView += $i }
      $View = $script:MenuView
      $State.Cursor = $State.GroupCursor
      $State.Top = 0
    }
  }
  elseif ($Key -eq 'continue') { $State.Result = 'continue' }
  elseif ($Key -eq 'quit') { $State.Result = 'quit' }
  $Last = $View.Count - 1
  if ($State.Cursor -gt $Last) { $State.Cursor = $Last }
  if ($State.Cursor -lt 0) { $State.Cursor = 0 }
  if ($State.Cursor -lt $State.Top) { $State.Top = $State.Cursor }
  if ($State.Cursor -ge ($State.Top + $State.Rows)) { $State.Top = $State.Cursor - $State.Rows + 1 }
}

function Show-Menu {
  param([object[]]$Catalog = @())
  if (-not (Test-MenuAvailable)) { throw 'menu not available: input is redirected or no console' }
  $script:MenuCatalog = $Catalog
  $script:MenuGroups = @()
  foreach ($Row in $Catalog) {
    if (-not ($script:MenuGroups -contains $Row.Group)) { $script:MenuGroups += $Row.Group }
  }
  $script:MenuView = @()
  for ($i = 0; $i -lt $script:MenuGroups.Count; $i++) { $script:MenuView += $i }
  $State = New-MenuState
  try { $State.Rows = [Console]::WindowHeight - 4 } catch { $State.Rows = 20 }
  if ($State.Rows -lt 3) { $State.Rows = 3 }
  try { [Console]::set_CursorVisible($false) } catch { }
  try {
    while ($State.Result -eq '') {
      [Console]::SetCursorPosition(0, 0)
      $Last = $State.Top + $State.Rows
      if ($Last -gt $script:MenuView.Count) { $Last = $script:MenuView.Count }
      for ($r = $State.Top; $r -lt $Last; $r++) {
        $Pointer = '  '
        if ($r -eq $State.Cursor) { $Pointer = '> ' }
        Write-Output ($Pointer + 'row')
      }
      $Info = [Console]::ReadKey($true)
      $Key = 'none'
      if ($Info.Key -eq 'UpArrow') { $Key = 'up' }
      elseif ($Info.Key -eq 'DownArrow') { $Key = 'down' }
      elseif ($Info.Key -eq 'Spacebar') { $Key = 'space' }
      elseif ($Info.Key -eq 'Enter') { $Key = 'enter' }
      elseif ($Info.KeyChar -eq 'c') { $Key = 'continue' }
      elseif ($Info.KeyChar -eq 'q') { $Key = 'quit' }
      Update-MenuState -State $State -Key $Key
    }
  } finally {
    try { [Console]::set_CursorVisible($true) } catch { }
  }
  return $State.Result
}
