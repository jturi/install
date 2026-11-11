#Requires AutoHotkey v2.0.11+
#SingleInstance Force
Persistent
SetWinDelay(-1)
SetControlDelay(0)
CoordMode("Mouse", "Screen")

;; Shift+Win+Arrow keys, in Windows 11 move windows.
;; This shortcut will  stopped working if you switch off the "Snap windows " function (in System / Multitasking ). 

;; Load personal.ahk (optional; setup.ps1 creates it from personal.ahk.example):
#Include *i personal.ahk

;================================================================
; CONFIG - loaded from settings.ini (auto-created next to script)
;================================================================
global INI := A_ScriptDir "\settings.ini"

; Defaults written to the ini on first run
global DEFAULTS := Map(
    "Editor",       "code",
    "EditorExe",    "Code.exe",
    "Browser",      "msedge.exe",
    "BrowserExe",   "msedge.exe",
    "Terminal",     "wt.exe",
    "TerminalExe",  "WindowsTerminal.exe",
    "KeyDelay",     "10",          ; ms between chained key sends
    "ClipTimeout",  "1"            ; seconds to wait for clipboard
)

EnsureIni()                        ; create ini with defaults if missing

global CFG := Map()
for k, v in DEFAULTS
    CFG[k] := IniRead(INI, "General", k, v)

global RELOAD_STARTUP_FLAG := A_Temp "\\ahk-reload-startup.flag"

; Convenience ahk_exe strings
global EDITOR_MATCH   := "ahk_exe " CFG["EditorExe"]
global BROWSER_MATCH  := "ahk_exe " CFG["BrowserExe"]
global TERM_MATCH     := "ahk_exe " CFG["TerminalExe"]

EnsureIni() {
    if FileExist(INI)
        return
    for k, v in DEFAULTS
        IniWrite(v, INI, "General", k)
}
;================================================================
; TRAY MENU
;================================================================
BuildTray()
if ShowStartupTip()
    tip("AHK Hotkeys Active", 2000)  ; show notification on startup
BuildTray() {
    tm := A_TrayMenu
    tm.Delete()                                   ; clear default items
    tm.Add("Reload  (Ctrl+Alt+R)", (*) => Reload())
    tm.Add("Edit script  (Ctrl+Alt+E)", (*) => Run(CFG["Editor"] ' "' A_ScriptFullPath '"'))
    tm.Add("Edit settings.ini", (*) => Run(CFG["Editor"] ' "' INI '"'))
    tm.Add()
    tm.Add("Suspend hotkeys  (Ctrl+Alt+Esc)", (*) => ToggleSuspend())
    tm.Add("Shortcut reference  (Ctrl+?)", (*) => ShowHelp())
    tm.Add()
    tm.Add("Exit", (*) => CleanupExit())
    tm.Default := "Reload  (Ctrl+Alt+R)"
    TraySetIcon("shell32.dll", 44)                ; simple recognizable icon
    A_IconTip := "AHK Utility Script`n" A_ScriptName
}

;================================================================
; GLOBAL HOTKEYS - script lifecycle
;================================================================

; Ctrl+Alt+R reloads the script; Ctrl+Alt+E opens it in the configured editor.
~^!r:: {
    tip("Reloading...", 2000)
    Sleep(600)
    FileAppend("1", RELOAD_STARTUP_FLAG)
    Reload
}
^!e::Run(CFG["Editor"] ' "' A_ScriptFullPath '"')

; Ctrl+S reloads the script when editing it in VS Code or Notepad++ so changes take effect immediately.
; #HotIf WinActive(A_ScriptName " - Visual Studio Code") || WinActive("ahk_exe notepad++.exe") || WinActive(A_ScriptName)
; ~^s:: {
;     Sleep(150)
;     Reload
; }
; #HotIf

;================================================================
; KEY NAVIGATION
;   RAlt + W/A/S/D = arrows (Ctrl+Shift select/scroll in terminals)
;   RAlt + Q/E     = Home / End
;   LAlt + B/F     = word back / forward (hold Shift = select word)
;   RAlt + J/K     = - / _
;================================================================

; Right-Alt acts as a text-navigation modifier: WASD behaves like arrow keys,
; Q/E jump to Home/End, and B/F move one word left/right.
; Example: RAlt+W = Up arrow, RAlt+S = Down arrow, LAlt+B = Ctrl+Left.
; In cmd.exe terminals, the arrow combos use Ctrl+Shift for selection/scroll behavior.

; --- Terminal-specific (cmd.exe only, NOT PowerShell or WSL) ---
#HotIf WinActive("ahk_exe cmd.exe")
RAlt & w::Send("^{Up}")      ; scroll up
RAlt & a::Send("^+{Left}")   ; select word left
RAlt & s::Send("^+{Down}")   ; scroll down
RAlt & d::Send("^+{Right}")  ; select word right
#HotIf

; --- Generic navigation ---
RAlt & w::Send("{Up}")
RAlt & a::Send("{Left}")
RAlt & s::Send("{Down}")
RAlt & d::Send("{Right}")
RAlt & q::Send("{Home}")
RAlt & e::Send("{End}")

; Word back/forward - hold Shift to select the word (FIXED: was invalid +LAlt & b)
LAlt & b::Send(GetKeyState("Shift", "P") ? "+^{Left}"  : "^{Left}")
LAlt & f::Send(GetKeyState("Shift", "P") ? "+^{Right}" : "^{Right}")

; Modifier keys
RAlt & j::Send("-")
RAlt & k::Send("_")
RAlt & l::Send("+")

;================================================================
; WINDOW TERMINAL FOCUS VISUAL CUE
;   Dims Windows Terminal when it loses focus, restores full
;   opacity when focused. Disable via TermOpacity=0 in settings.ini.
;================================================================







;================================================================
; WINDOW MANAGEMENT
;================================================================

; Window management shortcuts:
; - Ctrl+Space toggles always-on-top for the active window.
; - Alt+` minimizes the current window.
; - Shift+Alt+Left/Right snaps to half-screen left/right.
; - Shift+Alt+Up maximizes; Shift+Alt+Down restores.
; - Ctrl+Enter toggles pseudo-fullscreen borderless mode.
^Space:: {                                     ; toggle always-on-top
    WinSetAlwaysOnTop(-1, "A")
    onTop := WinGetExStyle("A") & 0x8           ; WS_EX_TOPMOST
    tip("Always on top: " (onTop ? "ON" : "OFF"))
}

!`::WinMinimize("A")                           ; Alt+` - minimize

; Ctrl+Enter - toggle pseudo-fullscreen (borderless)
global FS := Map()
^Enter:: {
    id := WinGetID("A")
    if FS.Has(id) {
        s := FS.Delete(id)
        WinSetStyle("+0xC40000", id)            ; restore caption + borders
        WinMove(s.x, s.y, s.w, s.h, id)
        return
    }
    WinGetPos(&x, &y, &w, &h, id)
    FS[id] := {x: x, y: y, w: w, h: h}
    WinSetStyle("-0xC40000", id)
    WinMove(0, 0, A_ScreenWidth, A_ScreenHeight, id)
}

; +!Left::  snapHalf("left")
; +!Right:: snapHalf("right")
; +!Up::    snapHalf("max")
; +!Down::  snapHalf("restore")

; +#Left::  moveToMonitor("left")
; +#Right:: moveToMonitor("right")

;================================================================
; TEXT & PRODUCTIVITY SHORTCUTS
;================================================================

; Paste clipboard contents as a single line by replacing newlines with spaces.
; Example: use Ctrl+Shift+V to paste a multi-line snippet as one line.
^+!v:: {
    old := ClipboardAll()
    A_Clipboard := RegExReplace(A_Clipboard, "\r?\n", " ")
    Send("^v")
    Sleep(80)
    A_Clipboard := old
}


UriEncode(str) {
    out := ""
    for _, ch in StrSplit(str) {
        if RegExMatch(ch, "[0-9A-Za-z\-_.~]")
            out .= ch
        else
            for _, b in StrToUtf8Bytes(ch)
                out .= Format("%{:02X}", b)
    }
    return out
}

StrToUtf8Bytes(s) {
    buf := Buffer(StrPut(s, "UTF-8"))
    StrPut(s, buf, "UTF-8")
    bytes := []
    Loop buf.Size - 1                           ; drop trailing null
        bytes.Push(NumGet(buf, A_Index - 1, "UChar"))
    return bytes
}

; Text expansion shortcuts:
; Example: type .kd and it turns into 'kubectl describe pod'.
; Example: type ;now and it inserts the current timestamp.
:*:.kd::kubectl describe pod
:*:.kl::kubectl logs -f
:*:.kexec::kubectl exec -it  -- /bin/sh
:*:.kga::kubectl get pods -A
:*:.dcb::docker compose build
:*:.dcu::docker compose up -d
:*:.dcd::docker compose down
:*:.dps::docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
:*:.gco::git checkout
:*:.gpl::git pull --rebase
:*:.gps::git push
:*:.gst::git status
:*:.gca::git commit --amend --no-edit
:*:.tfp::terraform plan
:*:.tfa::terraform apply
:*:.tfw::terraform workspace

; Dynamic ones need execute blocks (otherwise they'd paste literal code)
; Ctrl+Shift+Alt+D - insert timestamp YYYYMMDD_HHMMSS (useful for log filenames, backups, notes)
^!+d:: {
    SendText(FormatTime(, "yyyyMMdd_HHmmss"))
}

:*:;now:: {
    SendText(FormatTime(, "yyyy-MM-dd HH:mm:ss"))
}
:*:;today:: {
    SendText(FormatTime(, "yyyy-MM-dd"))
}

;================================================================
; APP & SYSTEM SHORTCUTS
;================================================================

; Open the current Explorer folder in the terminal or editor from File Explorer.
; Example: in File Explorer, press Ctrl+Alt+T to open the current folder in Terminal.
#HotIf WinActive("ahk_class CabinetWClass") || WinActive("ahk_class ExploreWClass")
^!t:: Run(CFG["Terminal"] ' -d "' ExplorerPath() '"')
^!e:: Run(CFG["Editor"] ' "' ExplorerPath() '"')
#HotIf

; App launcher shortcuts:
; Example: Win+C opens or focuses the browser; Win+T opens the terminal; Win+V opens VS Code.
#c::FocusOrRun(BROWSER_MATCH, CFG["Browser"])
#t::FocusOrRun(TERM_MATCH,    CFG["Terminal"])
#v::FocusOrRun(EDITOR_MATCH,  CFG["Editor"])

FocusOrRun(match, exe) {
    if !WinExist(match) {
        Run(exe)
        return
    }
    if WinActive(match) {
        list := WinGetList(match)               ; cycle to next instance
        if (list.Length > 1) {
            WinActivate("ahk_id " list[list.Length])
            return
        }
    }
    WinActivate(match)
}

; Use mouse wheel over the taskbar to control system volume.
; Example: hover the taskbar and roll the wheel to raise/lower volume.
#HotIf MouseIsOver("ahk_class Shell_TrayWnd")
WheelUp::Send("{Volume_Up}")
WheelDown::Send("{Volume_Down}")
MButton::Send("{Volume_Mute}")
#HotIf

MouseIsOver(win) {
    MouseGetPos(, , &id)
    return WinExist(win " ahk_id " id)
}

; Lock the workstation and turn off the monitor with Ctrl+Alt+L.
^!l:: {
    DllCall("LockWorkStation")
    Sleep(1500)
    SendMessage(0x0112, 0xF170, 2, , "Program Manager")  ; SC_MONITORPOWER off
}

; Temporarily disable all hotkeys with Ctrl+Alt+Esc.
^!Esc::ToggleSuspend()

ToggleSuspend() {
    Suspend(-1)
    tip("Hotkeys " (A_IsSuspended ? "suspended" : "active"))
}

; Show a popup listing the script's parsed hotkeys and shortcuts.
^?::ShowHelp()

ShowHelp() {
    txt := FileRead(A_ScriptFullPath)
    out := ""
    Loop Parse, txt, "`n", "`r" {
        if RegExMatch(A_LoopField, "^\s*([#^!+<>~*&.\w]+)::(.*)", &m)
            out .= m[1] "`t" Trim(m[2]) "`n"
    }
    MsgBox(out = "" ? "No shortcuts parsed." : out, "Shortcut reference")
}

;================================================================
; HELPERS
;================================================================
ShowStartupTip() {
    if FileExist(RELOAD_STARTUP_FLAG) {
        FileDelete(RELOAD_STARTUP_FLAG)
        return false
    }
    return true
}

ExplorerPath() {
    hwnd := WinGetID("A")
    path := ""
    try {
        for w in ComObject("Shell.Application").Windows {
            if (w.HWND = hwnd) {
                path := w.Document.Folder.Self.Path
                break
            }
        }
    }
    return (path = "") ? A_Desktop : path
}

tip(msg, ms := 2000) {
    TrayTip("AHK Hotkeys", msg, 1)  ; 1 = info icon
    SetTimer(() => TrayTip(), -ms)  ; dismiss after ms milliseconds
}

CleanupExit() {
    ExitApp()
}