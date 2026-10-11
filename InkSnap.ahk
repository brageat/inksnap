#Requires AutoHotkey v2.0
#SingleInstance Force
; InkSnap - auto play for Ink Game minigames:
; Tug of war - watches the green dot circling the ring and presses Space
;              right as it lines up with the red zone.
; Mingle     - Power Hold key checks: reads the key on each button and presses it
;              as the shrinking circle reaches the red ring.

Version := "1.2.0"
RepoUrl := "https://github.com/brageat/inksnap"

SetKeyDelay -1
ProcessSetPriority "High"

; ---------- ring layout (measured on a 3840x2160 Roblox window, scaled by window height) ----------
CenterXFrac := 0.4997, CenterYFrac := 0.5681   ; ring center, fraction of the Roblox window
DotRFrac    := 0.0995                           ; radius the green dot travels on
ZoneRFrac   := 0.1472                           ; radius of the red zone arc

GroupAdd "Roblox", "ahk_exe RobloxPlayerBeta.exe"
GroupAdd "Roblox", "ahk_exe Windows10Universal.exe"

; ---------- saved settings ----------
IniFile   := A_ScriptDir "\InkSnap.ini"
if !FileExist(IniFile) && FileExist(A_ScriptDir "\TugSnap.ini")
    FileCopy A_ScriptDir "\TugSnap.ini", IniFile     ; keep settings from when this was called TugSnap
ToggleKey := IniRead(IniFile, "Settings", "ToggleKey", "F6")
; how early to press (ms); learned automatically from where each tug lands
LatencyMs := Float(IniRead(IniFile, "Settings", "LatencyMs", 30))
DarkMode  := IniRead(IniFile, "Settings", "DarkMode", 1) = 1
ShowHud   := IniRead(IniFile, "Settings", "ShowHud", 1) = 1
HudPos    := IniRead(IniFile, "Settings", "HudPos", "Bottom-right")
HudPositions := ["Top-left", "Top-right", "Bottom-left", "Bottom-right"]
TugOn     := IniRead(IniFile, "Settings", "TugOfWar", 1) = 1
MingleOn  := IniRead(IniFile, "Settings", "Mingle", 1) = 1
; Mingle: press when the shrinking circle's radius is this many times the red ring's inner radius
; (the ring itself spans about 1.0-1.45)
MingleTarget := Float(IniRead(IniFile, "Settings", "MingleTarget", 1.3))

global Active := false
; stats
global Hits := 0, Rounds := 0, LastSpeed := 0, TopSpeed := 0, ActiveMs := 0, ActiveSince := 0
global AvgError := "", LastError := ""   ; how far off-center recent tugs landed (ms)
global QteHits := 0                      ; Mingle key checks pressed

; ---------- menu ----------
G := Gui("-MaximizeBox", "InkSnap")
G.SetFont("s10", "Segoe UI")
G.OnEvent("Close", (*) => ExitApp())
G.SetFont("s16 bold")
StatusTxt := G.AddText("w240 Center cRed", "OFF")
G.SetFont("s10 norm")
StartBtn := G.AddButton("w240 h34", "Start  (" ToggleKey ")")
StartBtn.OnEvent("Click", ToggleBot)

G.AddGroupBox("w240 h52 Section", "Games")
TugCb := G.AddCheckbox("xs+10 ys+22 Checked" TugOn, "Tug of war")
MingleCb := G.AddCheckbox("x+20 yp Checked" MingleOn, "Mingle")
TugCb.OnEvent("Click", GamesChanged)
MingleCb.OnEvent("Click", GamesChanged)

G.AddGroupBox("xs w240 h70 Section", "Timing (automatic)")
TimingTxt := G.AddText("xs+10 ys+22 w220 r2", "")

G.AddGroupBox("xs w240 h90 Section", "HUD")
HudCb := G.AddCheckbox("xs+10 ys+24 Checked" ShowHud, "Show stats HUD")
HudDd := G.AddDropDownList("xs+10 y+8 w130", HudPositions)
HudDd.Text := HudPos
ResetBtn := G.AddButton("x+8 yp-1 w82", "Reset stats")
HudCb.OnEvent("Click", (*) => (PlaceHud(), SaveHudSettings()))
HudDd.OnEvent("Change", (*) => (PlaceHud(), SaveHudSettings()))
ResetBtn.OnEvent("Click", ResetStats)

StatsTxt := G.AddText("xs w240", "")
DarkCb := G.AddCheckbox("xs Checked" DarkMode, "Dark mode")
DarkCb.OnEvent("Click", (*) => (IniWrite(DarkCb.Value, IniFile, "Settings", "DarkMode"), Reload()))
G.SetFont("s8 cGray")
NoteTxt := G.AddText("xs w240", "Only presses keys while Roblox is focused.`nTiming tunes itself over the first few tugs.")
VersionLink := G.AddLink("xs w240", "v" Version " · Checking for updates...")
VersionLink.OnEvent("Click", (*) => Run(RepoUrl "/releases/latest"))
if DarkMode
    ApplyDarkMode(G)
UpdateTimingText()
Hotkey "*" ToggleKey, ToggleBot
; keep the menu off the ring in the middle of the screen
; (WinMove uses real pixels; Gui.Show's x/y get DPI-scaled)
G.Show("Hide")
WinGetPos ,, &gw,, G
WinMove A_ScreenWidth - gw - 40, Round(A_ScreenHeight * 0.3),,, G
G.Show()

; ---------- stats HUD (click-through overlay) ----------
Hud := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20", "InkSnap HUD")
Hud.BackColor := "15181D"
Hud.MarginX := 10, Hud.MarginY := 8
Hud.SetFont("s10 bold cRed", "Consolas")
HudStatus := Hud.AddText("w200", "● INKSNAP OFF")
Hud.SetFont("s9 norm cE6E6E6")
HudBody := Hud.AddText("w200 r9", "")
HudBody.GetPos(,,, &hb)
HudLineH := hb / 9, HudLines := 9      ; the body is resized to fit the stats of the picked games
WinSetTransparent 215, Hud
UpdateStats()
PlaceHud()
SetTimer UpdateStats, 1000

; ---------- update check ----------
SetTimer CheckForUpdate, -1500           ; after the menu has appeared

CheckForUpdate() {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(3000, 3000, 3000, 3000)
        req.Open("GET", "https://api.github.com/repos/brageat/inksnap/releases/latest", false)
        req.SetRequestHeader("User-Agent", "InkSnap")
        req.Send()
        if (req.Status != 200 || !RegExMatch(req.ResponseText, '"tag_name"\s*:\s*"v?([\d.]+)"', &m))
            throw Error("bad response")
        latest := m[1]
    } catch {
        VersionLink.Text := "v" Version " · Couldn't check for updates (<a>open page</a>)"
        return
    }
    if (CompareVersions(latest, Version) <= 0) {
        VersionLink.Text := "v" Version " · Up to date"
        return
    }
    VersionLink.Text := "v" Version " · <a>Update available: v" latest " - download</a>"
    if MsgBox("A new version of InkSnap is available!`n`n"
            . "You have:  v" Version "`nNewest:    v" latest "`n`n"
            . "Open the download page?", "InkSnap update", "YesNo Iconi Owner" G.Hwnd) = "Yes"
        Run RepoUrl "/releases/latest"
}

; Returns >0 if a is newer than b, <0 if older, 0 if equal ("1.2.0" style).
CompareVersions(a, b) {
    pa := StrSplit(a, "."), pb := StrSplit(b, ".")
    loop Max(pa.Length, pb.Length) {
        x := A_Index <= pa.Length ? Integer(pa[A_Index]) : 0
        y := A_Index <= pb.Length ? Integer(pb[A_Index]) : 0
        if (x != y)
            return x - y
    }
    return 0
}

UpdateTimingText() => TimingTxt.Value := "Pressing " Round(LatencyMs) " ms early`n"
    . "Accuracy: " (AvgError = "" ? "learning..." : "±" Round(AvgError) " ms")

FmtMs(v) => (v >= 0 ? "+" : "") Round(v) " ms"

GamesChanged(*) {
    IniWrite TugCb.Value, IniFile, "Settings", "TugOfWar"
    IniWrite MingleCb.Value, IniFile, "Settings", "Mingle"
    UpdateStats()
}

; Shows only the stats of the games that are turned on.
UpdateStats() {
    global HudLines
    tug := TugCb.Value, mingle := MingleCb.Value
    StatsTxt.Value := !(tug || mingle) ? "No games picked"
        : (tug ? "Tugs: " Hits (mingle ? "    " : "") : "") (mingle ? "Mingle keys: " QteHits : "")
    secs := (ActiveMs + (Active ? A_TickCount - ActiveSince : 0)) // 1000
    lines := []
    if tug
        lines.Push("Tugs:        " Hits
            , "Rounds:      " Rounds
            , "Tugs/min:    " (secs >= 10 ? Round(Hits * 60 / secs) : "-")
            , "Dot speed:   " (LastSpeed ? LastSpeed "°/s" : "-")
            , "Top speed:   " (TopSpeed ? TopSpeed "°/s" : "-")
            , "Last tug:    " (LastError = "" ? "-" : FmtMs(LastError) (LastError > 0 ? " late" : " early")))
    if mingle
        lines.Push("Mingle keys: " QteHits)
    if !(tug || mingle)
        lines.Push("No games picked")
    lines.Push("Timing:      " Round(LatencyMs) " ms early"
        , "Run time:    " Format("{:02}:{:02}", secs // 60, Mod(secs, 60)))
    text := ""
    for l in lines
        text .= (A_Index > 1 ? "`n" : "") l
    HudBody.Value := text
    if (lines.Length != HudLines) {
        HudLines := lines.Length
        HudBody.Move(,,, Round(HudLineH * HudLines))
        PlaceHud()
    }
}

PlaceHud() {
    if !HudCb.Value {
        Hud.Hide()
        return
    }
    Hud.Show("NoActivate AutoSize")
    ; WinGetPos/WinMove use real pixels (Hud.Move would apply DPI scaling);
    ; the corners stay clear of the ring in the middle of the screen
    WinGetPos(, , &hudW, &hudH, Hud)
    scrW := A_ScreenWidth, scrH := A_ScreenHeight
    pos := HudDd.Text
    x := InStr(pos, "left") ? 12 : scrW - hudW - 12
    y := InStr(pos, "Top") ? Round(scrH * 0.12) : scrH - hudH - Round(scrH * 0.15)
    WinMove x, y, , , Hud
}

SaveHudSettings() {
    IniWrite HudCb.Value, IniFile, "Settings", "ShowHud"
    IniWrite HudDd.Text, IniFile, "Settings", "HudPos"
}

ResetStats(*) {
    global Hits := 0, Rounds := 0, LastSpeed := 0, TopSpeed := 0, ActiveMs := 0, LastError := "", QteHits := 0
    global ActiveSince := A_TickCount
    UpdateStats()
}

ApplyDarkMode(g) {
    g.BackColor := "1E1F22"
    ; dark title bar (attribute 20 on newer Windows 10/11, 19 on older builds)
    if DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "Int", 20, "Int*", 1, "Int", 4)
        DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "Int", 19, "Int*", 1, "Int", 4)
    for ctl in g {
        switch ctl.Type, false {
            case "Button":
                DllCall("uxtheme\SetWindowTheme", "Ptr", ctl.Hwnd, "Str", "DarkMode_Explorer", "Ptr", 0)
            case "DDL":
                DllCall("uxtheme\SetWindowTheme", "Ptr", ctl.Hwnd, "Str", "DarkMode_CFD", "Ptr", 0)
                ctl.Opt("Background2B2D31")
                ctl.SetFont("cE6E6E6")
            case "CheckBox", "GroupBox":
                ; themed checkboxes/groupboxes ignore text color, so drop the theme
                DllCall("uxtheme\SetWindowTheme", "Ptr", ctl.Hwnd, "Str", "", "Str", "")
                ctl.SetFont("cE6E6E6")
            case "Text":
                if (ctl != StatusTxt)
                    ctl.SetFont(ctl = NoteTxt ? "c8A8A8A" : "cE6E6E6")
            case "Link":
                ctl.SetFont("c8A8A8A")
        }
    }
}

ToggleBot(*) {
    global Active := !Active, ActiveMs, ActiveSince
    if Active
        ActiveSince := A_TickCount
    else
        ActiveMs += A_TickCount - ActiveSince
    StatusTxt.Value := Active ? "ON" : "OFF"
    StatusTxt.SetFont(Active ? "cGreen" : "cRed")
    StartBtn.Text := (Active ? "Stop" : "Start") "  (" ToggleKey ")"
    HudStatus.Value := Active ? "● INKSNAP ON" : "● INKSNAP OFF"
    HudStatus.SetFont(Active ? "c3DDC84" : "cRed")
    UpdateStats()
    if Active
        SetTimer RunBot, -1
}

; ---------- screen capture (one BitBlt of the ring area per tick) ----------
global MemDC := 0, Bmp := 0, OldBmp := 0, Bits := 0, CapSize := 0, CapX := 0, CapY := 0
global DotOff := [], ZoneOff := [], CosT := [], SinT := [], GeoKey := ""
global CliX := 0, CliY := 0, CliW := 0, CliH := 0      ; Roblox client area

loop 360 {
    a := (A_Index - 1) * 0.0174533
    CosT.Push(Cos(a)), SinT.Push(Sin(a))
}

; Recomputes the capture box and sample points if the Roblox window moved or resized.
UpdateGeometry() {
    global
    local wx, wy, ww, wh, cx, cy, dr, zr, box, key
    WinGetClientPos &wx, &wy, &ww, &wh, "ahk_group Roblox"
    key := wx "," wy "," ww "," wh
    CliX := wx, CliY := wy, CliW := ww, CliH := wh
    if (key = GeoKey)
        return
    GeoKey := key
    cx := wx + Round(ww * CenterXFrac), cy := wy + Round(wh * CenterYFrac)
    dr := wh * DotRFrac, zr := wh * ZoneRFrac
    box := Ceil(zr) + 4
    CapX := cx - box, CapY := cy - box
    size := box * 2 + 1
    if (size != CapSize) {
        if !MemDC
            MemDC := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
        if Bmp
            DllCall("SelectObject", "Ptr", MemDC, "Ptr", OldBmp), DllCall("DeleteObject", "Ptr", Bmp)
        bi := Buffer(40, 0)
        NumPut("UInt", 40, bi, 0), NumPut("Int", size, bi, 4), NumPut("Int", -size, bi, 8)   ; top-down
        NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14)
        Bmp := DllCall("CreateDIBSection", "Ptr", MemDC, "Ptr", bi, "UInt", 0, "Ptr*", &Bits := 0, "Ptr", 0, "UInt", 0, "Ptr")
        OldBmp := DllCall("SelectObject", "Ptr", MemDC, "Ptr", Bmp, "Ptr")
        CapSize := size
    }
    DotOff := [], ZoneOff := []
    loop 360 {
        DotOff.Push((Round(box + dr * SinT[A_Index]) * CapSize + Round(box + dr * CosT[A_Index])) * 4)
        ZoneOff.Push((Round(box + zr * SinT[A_Index]) * CapSize + Round(box + zr * CosT[A_Index])) * 4)
    }
}

Grab() {
    sdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    DllCall("BitBlt", "Ptr", MemDC, "Int", 0, "Int", 0, "Int", CapSize, "Int", CapSize
        , "Ptr", sdc, "Int", CapX, "Int", CapY, "UInt", 0x00CC0020)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", sdc)
}

; Angle (degrees, 0 = right, clockwise) of the matching pixels on a ring, or "" if too few.
RingAngle(offs, green, &count) {
    sx := 0, sy := 0, count := 0
    for off in offs {
        c := NumGet(Bits, off, "UInt")
        r := (c >> 16) & 0xFF, g := (c >> 8) & 0xFF, b := c & 0xFF
        if green ? (g > 150 && r < 130 && b < 130) : (r > 150 && g < 80 && b < 120)
            sx += CosT[A_Index], sy += SinT[A_Index], count++
    }
    if (count < 4)
        return ""
    a := DllCall("msvcrt\atan2", "Double", sy, "Double", sx, "Cdecl Double") * 57.29578
    return a < 0 ? a + 360 : a
}

AngDiff(a, b) => Mod(a - b + 540, 360) - 180    ; signed a - b in -180..180

; ---------- bot ----------
RunBot() {
    global Hits, Rounds, LastSpeed, TopSpeed
    omega := 0, refA := "", refT := 0, lastZone := "", lastPress := 0, tickMs := 10, prevT := Now(), lastSeen := -1e9
    while Active {
        if !WinActive("ahk_group Roblox") {
            Sleep 100
            omega := 0, refA := ""
            continue
        }
        UpdateGeometry()
        if !TugCb.Value {
            if MingleCb.Value
                MingleTick()
            else
                Sleep 50
            continue
        }
        t := Now()
        tickMs := tickMs * 0.8 + Min(t - prevT, 50) * 0.2
        prevT := t
        Grab()
        dot := RingAngle(DotOff, true, &_)
        zone := RingAngle(ZoneOff, false, &zoneW)
        ; a new round when the minigame shows up after being gone for a while
        if (dot != "" && zone != "") {
            if (t - lastSeen > 8000)
                Rounds++, UpdateStats()
            lastSeen := t
        }
        ; no minigame on screen, or the dot is reversing / the zone moving right after a tug
        if (dot = "" || zone = "" || t - lastPress < 120) {
            omega := 0, refA := "", lastZone := ""
            if (dot = "" && MingleCb.Value)
                MingleTick()                 ; no tug ring: look for Mingle key checks instead
            else
                Sleep dot = "" ? 30 : 1
            continue
        }
        ; dot speed in degrees per ms (signed: + = clockwise)
        if (refA = "") {
            refA := dot, refT := t
        } else if (t - refT >= 20) {
            v := AngDiff(dot, refA) / (t - refT)
            if (Abs(v) > 0.03 && Abs(v) < 2.5)
                omega := (omega && (omega > 0) = (v > 0)) ? omega * 0.5 + v * 0.5 : v
            refA := dot, refT := t
        }
        stable := lastZone != "" && Abs(AngDiff(zone, lastZone)) < 3
        lastZone := zone
        if (!omega || !stable)
            continue
        ; degrees until the dot reaches the zone's center, going the way it's moving
        ahead := Mod((omega > 0 ? zone - dot : dot - zone) + 720, 360)
        if (ahead > 180 && 360 - ahead < zoneW * 0.4)
            ahead := 0                   ; just passed the center but still in the zone
        wait := ahead / Abs(omega) - LatencyMs
        if (wait > tickMs * 1.5)
            continue                     ; the next tick is soon enough
        ; wait out the remaining time precisely, then tug
        target := t + wait
        while Now() < target
            continue
        Press()
        Hits++, LastSpeed := Round(Abs(omega) * 1000), TopSpeed := Max(TopSpeed, LastSpeed)
        LearnTiming(MeasureTug(dot, t, omega, zone))
        lastPress := Now()
        UpdateStats()
        omega := 0, refA := "", lastZone := ""
    }
}

; After a tug the dot bounces back from wherever the press landed. Watches the bounce and
; returns how many ms after (+) or before (-) the zone's center the tug landed, or "" if unclear.
; a0/t0/omega: the dot's angle, capture time and speed the press was timed from.
MeasureTug(a0, t0, omega, zone) {
    dir := omega > 0 ? 1 : -1
    pts := [[t0, 0]]                     ; [time, degrees travelled from a0 (unwrapped)]
    backs := 0
    deadline := Now() + 300
    while Now() < deadline {
        t := Now()
        Grab()
        if ((d := RingAngle(DotOff, true, &_)) = "")
            continue
        prev := pts[pts.Length]
        rel := prev[2] + AngDiff(d, a0 + prev[2])
        pts.Push([t, rel])
        ; two moves in a row back the other way = both points are past the turnaround
        backs := (rel - prev[2]) * dir < -1 ? backs + 1 : 0
        if (backs < 2)
            continue
        t1 := prev[1], r1 := prev[2]
        w2 := (rel - r1) / (t - t1)                  ; speed coming back
        if (Abs(w2) < Abs(omega) * 0.3 || Abs(w2) > Abs(omega) * 3)
            return ""
        ; the turnaround is where the line going out meets the line coming back
        tTurn := (r1 - w2 * t1 + omega * t0) / (omega - w2)
        if (tTurn < t0 - 50 || tTurn > t1)
            return ""
        turn := omega * (tTurn - t0)
        return (turn - AngDiff(zone, a0)) * dir / Abs(omega)
    }
    return ""
}

; Nudges the press timing toward the zone's center using the last tug's error.
LearnTiming(err) {
    global LatencyMs, LastError, AvgError
    if (err = "" || Abs(err) > 120)
        return
    LastError := err
    AvgError := AvgError = "" ? Abs(err) : AvgError * 0.8 + Abs(err) * 0.2
    LatencyMs := Min(150, Max(0, LatencyMs + Max(-25, Min(25, err)) * 0.4))
    UpdateTimingText()
    SetTimer SaveTiming, -3000           ; save once things settle, not on every tug
}

SaveTiming() => IniWrite(Round(LatencyMs, 1), IniFile, "Settings", "LatencyMs")

; ---------- Mingle: Power Hold key checks ----------
; Each check is a white button showing a key (R, G, F, Q or E) inside a red ring. A see-through
; circle shrinks onto the ring, and the key has to be pressed while it overlaps the ring.
; Buttons can show up anywhere on screen, several at once.
global MDC := 0, MBmp := 0, MOld := 0, MBits := 0, MW := 0, MH := 0, MX := 0, MY := 0
global Qtes := [], MingleTickMs := 30

; 6x6 letter shapes (# filled, + partly, . empty), measured from real Power Hold buttons.
; G never showed up in the footage, so its shape comes from Arial Bold.
LetterShapes := Map(
    "f", "######" "##...." "##+++." "#####+" "##...." "##....",
    "e", "#####+" "##...." "#####." "####+." "###++." "######",
    "r", "#####+" "##..##" "##..##" "#####+" "##+##." "##..##",
    "q", ".####." "##..##" "#+..+#" "##++##" ".###+." "...###",
    "g", ".####+" "##..##" "#+..++" "#+.###" "##..+#" ".####+")

; Captures the whole Roblox client area.
MGrab() {
    global
    if (CliW != MW || CliH != MH) {
        if !MDC
            MDC := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
        if MBmp
            DllCall("SelectObject", "Ptr", MDC, "Ptr", MOld), DllCall("DeleteObject", "Ptr", MBmp)
        local bi := Buffer(40, 0)
        NumPut("UInt", 40, bi, 0), NumPut("Int", CliW, bi, 4), NumPut("Int", -CliH, bi, 8)   ; top-down
        NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14)
        MBmp := DllCall("CreateDIBSection", "Ptr", MDC, "Ptr", bi, "UInt", 0, "Ptr*", &MBits := 0, "Ptr", 0, "UInt", 0, "Ptr")
        MOld := DllCall("SelectObject", "Ptr", MDC, "Ptr", MBmp, "Ptr")
        MW := CliW, MH := CliH
    }
    local sdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    DllCall("BitBlt", "Ptr", MDC, "Int", 0, "Int", 0, "Int", MW, "Int", MH
        , "Ptr", sdc, "Int", CliX, "Int", CliY, "UInt", 0x00CC0020)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", sdc)
}

MPx(x, y) {
    x := Round(x), y := Round(y)
    return (x < 0 || y < 0 || x >= MW || y >= MH) ? 0 : NumGet(MBits, (y * MW + x) * 4, "UInt")
}
IsRedC(c) => ((c >> 16) & 0xFF) > 170 && ((c >> 16) & 0xFF) - ((c >> 8) & 0xFF) > 55 && ((c >> 16) & 0xFF) - (c & 0xFF) > 45
Bright(c) => (((c >> 16) & 0xFF) + ((c >> 8) & 0xFF) + (c & 0xFF)) / 3

MingleTick() {
    global QteHits, MingleTickMs
    t := Now()
    MGrab()
    for q in FindQtes() {
        known := 0
        for k in Qtes
            if (Abs(k.x - q.x) + Abs(k.y - q.y) < q.ri) {
                known := k
                break
            }
        if !known
            Qtes.Push(known := {votes: Map(), key: "", pts: [], done: false})
        known.x := q.x, known.y := q.y, known.ri := q.ri, known.seen := t
    }
    i := Qtes.Length
    while (i >= 1) {
        q := Qtes[i--]
        ; forget checks that are gone; pressed ones linger a bit so their fading ring isn't pressed again
        if (t - q.seen > (q.done ? 700 : 250)) {
            Qtes.RemoveAt(i + 1)
            continue
        }
        if (q.done || q.seen != t)
            continue
        ; read the key until the same letter shows up twice
        if (q.key = "" && (k := ReadLetter(q)) != "") {
            q.votes[k] := q.votes.Get(k, 0) + 1
            if (q.votes[k] >= 2)
                q.key := k
        }
        R := OuterRadius(q)
        if (R > q.ri * 1.2 && R < q.ri * 3.5) {
            q.pts.Push([t, R])
            if (q.pts.Length > 6)
                q.pts.RemoveAt(1)
        }
        if (q.key = "" || q.pts.Length < 3)
            continue
        ; shrink speed in px per ms; signs and other still rings never shrink
        p0 := q.pts[1], p1 := q.pts[q.pts.Length]
        v := (p0[2] - p1[2]) / (p1[1] - p0[1])
        if (v < q.ri * 0.0002)
            continue
        wait := (p1[2] - q.ri * MingleTarget) / v - LatencyMs
        if (wait > MingleTickMs * 1.5)
            continue                     ; the next tick is soon enough
        target := t + wait
        while Now() < target
            continue
        PressKey(q.key)
        q.done := true, QteHits++
        UpdateStats()
    }
    MingleTickMs := MingleTickMs * 0.8 + Min(Now() - t, 100) * 0.2
}

; Finds Power Hold buttons: a white spot with red on all four sides, evenly spaced.
FindQtes() {
    found := [], probes := 0
    step := Max(8, Round(MH * 0.01))     ; smaller than the smallest button
    maxS := Round(MH * 0.06)
    y := step
    while (y < MH - step) {
        row := y * MW * 4
        x := step
        while (x < MW - step) {
            c := NumGet(MBits, row + x * 4, "UInt")
            r := (c >> 16) & 0xFF, g := (c >> 8) & 0xFF, b := c & 0xFF
            if (r > 205 && g > 205 && b > 205 && Max(r, g, b) - Min(r, g, b) < 20 && probes++ < 400) {
                near := false
                for f in found
                    if (Abs(f.x - x) + Abs(f.y - y) < f.ri * 2)
                        near := true
                if (!near && (q := ProbeQte(x, y, maxS)))
                    found.Push(q)
            }
            x += step
        }
        y += step
    }
    return found
}

ProbeQte(x, y, maxS) {
    l := RedEdge(x, y, -1, 0, maxS), r := RedEdge(x, y, 1, 0, maxS)
    if (l < 0 || r < 0)
        return 0
    cx := x + (r - l) // 2
    u := RedEdge(cx, y, 0, -1, maxS), d := RedEdge(cx, y, 0, 1, maxS)
    if (u < 0 || d < 0)
        return 0
    ri := (l + r + u + d) / 4            ; red ring's inner radius
    if (ri < MH * 0.008 || Abs((l + r) - (u + d)) > ri * 0.25)
        return 0
    return {x: cx, y: y + (d - u) // 2, ri: ri}
}

; Distance to the first red pixel in a direction, or -1. Inside a button everything is
; white/grey (button and letter) up to the pinkish ring, so another color first means this isn't one.
RedEdge(x, y, dx, dy, maxS) {
    loop maxS {
        c := MPx(x + dx * A_Index, y + dy * A_Index)
        if IsRedC(c)
            return A_Index
        r := (c >> 16) & 0xFF, g := (c >> 8) & 0xFF, b := c & 0xFF
        if (Max(r, g, b) - Min(r, g, b) > 45 && r < Max(g, b))
            return -1
    }
    return -1
}

; Radius of the shrinking see-through circle: its edge is where the image gets darker going outward.
OuterRadius(q) {
    rs := []
    gap := Max(2, Round(q.ri / 12))
    loop 8 {
        a := (A_Index - 1) * 0.785398 + 0.2
        ca := Cos(a), sa := Sin(a)
        best := 0, bs := -1
        s := Round(q.ri * 1.6)
        while (s <= q.ri * 3.4) {
            g := Bright(MPx(q.x + ca * (s - gap), q.y + sa * (s - gap))) - Bright(MPx(q.x + ca * (s + gap), q.y + sa * (s + gap)))
            if (g > best)
                best := g, bs := s
            s++
        }
        if (best > 18)
            rs.Push(bs)
    }
    if (rs.Length < 4)
        return -1
    ; median
    loop rs.Length - 1 {
        j := A_Index + 1
        while (j > 1 && rs[j - 1] > rs[j])
            tmp := rs[j], rs[j] := rs[j - 1], rs[j - 1] := tmp, j--
    }
    return rs[rs.Length // 2 + 1]
}

; Reads the key on a button by comparing its dark pixels to the letter shapes; "" if unsure.
ReadLetter(q, &bestD := 0, &second := "") {
    rad := q.ri * 0.75, st := Max(1, Floor(q.ri / 30))
    pts := [], x0 := 1e9, x1 := -1e9, y0 := 1e9, y1 := -1e9
    yy := -rad
    while (yy <= rad) {
        xx := -rad
        while (xx <= rad) {
            if (xx * xx + yy * yy <= rad * rad) {
                c := MPx(q.x + xx, q.y + yy)
                r := (c >> 16) & 0xFF, g := (c >> 8) & 0xFF, b := c & 0xFF
                if ((r + g + b) / 3 < 150 && Max(r, g, b) - Min(r, g, b) < 40) {
                    pts.Push([xx, yy])
                    x0 := Min(x0, xx), x1 := Max(x1, xx), y0 := Min(y0, yy), y1 := Max(y1, yy)
                }
            }
            xx += st
        }
        yy += st
    }
    if (pts.Length < 12)
        return ""
    w := x1 - x0 + st, h := y1 - y0 + st
    grid := []
    grid.Length := 36, grid.Default := 0
    for p in pts {
        gi := Min(5, Floor((p[2] - y0) / h * 6)) * 6 + Min(5, Floor((p[1] - x0) / w * 6)) + 1
        grid[gi] += 1
    }
    cell := (w / st) * (h / st) / 36
    bestKey := "", bestD := 1e9, nextD := 1e9
    for key, shape in LetterShapes {
        dist := 0
        loop 36 {
            ; same 3 levels as the shapes: filled, partly, empty
            f := grid[A_Index] / cell
            want := SubStr(shape, A_Index, 1)
            dist += Abs((f > 0.5 ? 1 : f > 0.2 ? 0.5 : 0) - (want = "#" ? 1 : want = "+" ? 0.5 : 0))
        }
        if (dist < bestD)
            nextD := bestD, second := bestKey, bestD := dist, bestKey := key
        else if (dist < nextD)
            nextD := dist, second := key
    }
    return bestD <= 6 ? bestKey : ""
}

PressKey(k) {
    Send "{" k " down}"
    Sleep 20
    Send "{" k " up}"
}

; High-resolution time in ms (A_TickCount is only ~15 ms accurate).
Now() {
    static freq := 0
    if !freq
        DllCall("QueryPerformanceFrequency", "Int64*", &freq)
    DllCall("QueryPerformanceCounter", "Int64*", &c := 0)
    return c * 1000 / freq
}

Press() {
    Send "{Space down}"
    Sleep 20
    Send "{Space up}"
}
