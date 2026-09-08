#Requires AutoHotkey v2.0
#SingleInstance Force
; ---------------------------------------------------------------
;  HiddifyTray - статус Hiddify в трее и быстрый переключатель.
;  Клик по иконке или Ctrl+Alt+V = подключить/отключить.
;
;  Ядро включается и выключается напрямую через gRPC-интерфейс
;  hiddify-core (/hcore.Core/Start и /hcore.Core/Stop) - тот же
;  вызов, что делает круглая кнопка в окне. Приложение при этом
;  не перезапускается, переключение занимает 3-5 секунд.
;  Транспорт - hcore.ps1 (HTTP/2 средствами .NET, без зависимостей).
;
;  Задача планировщика нужна только чтобы поднять само приложение
;  при входе в систему с правами, достаточными для TUN.
; ---------------------------------------------------------------

try DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

; --- НАСТРОЙКИ ---
global HotkeyToggle := "^!v"                          ; Ctrl + Alt + V
global HiddifyExe   := FindHiddify()
global HiddifyDir   := RegExReplace(HiddifyExe, "\\[^\\]+$", "")
global TaskStart    := "Hiddify_Autostart"
global TaskStop     := "Hiddify_Stop"
global PollInterval := 2500                           ; мс
global WaitTimeout  := 30000                          ; сколько ждём выполнения команды
global AutoOnStart  := true                           ; поднимать VPN при запуске скрипта
global AutoHideWin  := true                           ; прятать окно, открывшееся при автозапуске
global HideWindowMs := 60000                          ; окно автозапуска
global HideTries    := 4                              ; больше не пытаемся: Flutter возвращает окно
; -----------------

global gCtrl := "127.0.0.1:16756", gSecret := ""
global gPrevDown := 0, gPrevUp := 0, gPrevTick := 0
global gState := "", gTheme := ""
global gWant := "", gWantTs := 0, gWarned := false
global gAutoConnect := AutoOnStart
global gAnim := false
; Восстанавливать связь, если она отвалилась сама. По умолчанию выкл:
; отключение через окно Hiddify внешне неотличимо от обрыва, и включённая
; опция переподключала бы VPN против воли.
global gAutoRecover := false
; Hiddify при старте разворачивает окно. Прячем его, но только то,
; что появилось само при запуске: окно, открытое пользователем, не трогаем.
global gProcSeenTs := 0, gHideTries := 0, gUserOpened := false

ReadApiCreds()

A_TrayMenu.Delete()
A_TrayMenu.Add("Переключить`tCtrl+Alt+V", (*) => ToggleVPN())
A_TrayMenu.Default := "Переключить`tCtrl+Alt+V"
A_TrayMenu.Add()
A_TrayMenu.Add("Подключить", (*) => ConnectVPN())
A_TrayMenu.Add("Отключить", (*) => DisconnectVPN())
A_TrayMenu.Add("Перезапустить ядро", (*) => RestartCore())
A_TrayMenu.Add()
A_TrayMenu.Add("Открыть окно Hiddify", (*) => ShowHiddify())
A_TrayMenu.Add("Завершить приложение", (*) => KillApp())
A_TrayMenu.Add()
A_TrayMenu.Add("Прятать окно при запуске", (*) => ToggleAutoHide())
A_TrayMenu.Add("Подключать при запуске", (*) => ToggleAutoConnect())
A_TrayMenu.Add("Восстанавливать при обрыве", (*) => ToggleAutoRecover())
A_TrayMenu.Add("Автозапуск при входе", (*) => ToggleAutostart())
A_TrayMenu.Add()
A_TrayMenu.Add("Открыть журнал", (*) => OpenLog())
A_TrayMenu.Add("Перезагрузить скрипт", (*) => Reload())
A_TrayMenu.Add("Выход", (*) => ExitApp())
if gAutoConnect
    A_TrayMenu.Check("Подключать при запуске")
if AutoHideWin
    A_TrayMenu.Check("Прятать окно при запуске")
RefreshAutostartCheck()

OnMessage(0x404, TrayClick)
Hotkey HotkeyToggle, (*) => ToggleVPN()

UpdateStatus()
SetTimer UpdateStatus, PollInterval
SetTimer AnimTick, 450                                ; пульсация во время ожидания
; При входе в систему приложение стартует задачей, но ядро остаётся
; выключенным - поднимаем его сами.
if gAutoConnect
    SetTimer((*) => BootConnect(1), -4000)
return

; Пока идёт команда, иконка мигает между "ожидание" и целевым
; состоянием - сразу видно, что нажатие принято и что-то происходит.
AnimTick() {
    global gAnim
    if (gState != "wait")
        return
    gAnim := !gAnim
    theme := CurrentTheme()
    target := (gWant = "on") ? "on" : "off"
    try TraySetIcon(IconFor(gAnim ? "wait" : target, theme))
}

; Мгновенно показать состояние, не дожидаясь опроса по таймеру
ApplyState(state) {
    global gState, gTheme
    gState := state
    gTheme := CurrentTheme()
    try TraySetIcon(IconFor(state, gTheme))
}

TrayClick(wParam, lParam, msg, hwnd) {
    if (lParam = 0x0202)                              ; WM_LBUTTONUP
        SetTimer((*) => ToggleVPN(), -50)
}

; Hiddify ставится в Program Files, но встречается и установка
; "только для меня" в LocalAppData - проверяем оба варианта.
FindHiddify() {
    candidates := [
        A_ProgramFiles "\Hiddify\Hiddify.exe",
        EnvGet("ProgramW6432") "\Hiddify\Hiddify.exe",
        EnvGet("LOCALAPPDATA") "\Programs\Hiddify\Hiddify.exe",
        EnvGet("LOCALAPPDATA") "\Hiddify\Hiddify.exe"
    ]
    for p in candidates {
        if (p != "\Hiddify\Hiddify.exe" && FileExist(p))
            return p
    }
    return A_ProgramFiles "\Hiddify\Hiddify.exe"      ; путь по умолчанию
}

LogLine(msg) {
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "  " msg "`n"
        , A_ScriptDir "\hiddifytray.log", "UTF-8")
}

OpenLog() {
    f := A_ScriptDir "\hiddifytray.log"
    if FileExist(f) {
        try Run('notepad.exe "' f '"')
    } else {
        TrayTip("Журнал пуст", "Hiddify")
    }
}

; --- Clash API: адрес и секрет меняются при каждом запуске ядра ---
ReadApiCreds() {
    global gCtrl, gSecret
    cfg := A_AppData "\Hiddify\hiddify\data\current-config.json"
    if !FileExist(cfg)
        return
    try {
        txt := FileRead(cfg, "UTF-8")
    } catch {
        return
    }
    if RegExMatch(txt, '"external_controller"\s*:\s*"([^"]+)"', &m)
        gCtrl := m[1]
    if RegExMatch(txt, '"secret"\s*:\s*"([^"]*)"', &m2)
        gSecret := m2[1]
}

Http(method, path) {
    global gCtrl, gSecret
    try {
        w := ComObject("WinHttp.WinHttpRequest.5.1")
        w.Open(method, "http://" gCtrl path, false)
        w.SetTimeouts(300, 300, 500, 1200)     ; порт локальный, ждать долго незачем
        if (gSecret != "")
            w.SetRequestHeader("Authorization", "Bearer " gSecret)
        w.Send()
        return w.ResponseText
    } catch {
        return ""
    }
}

; --- вызов gRPC hiddify-core через хелпер ---
Hcore(action, wait := false) {
    cmd := 'pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "'
         . A_ScriptDir '\hcore.ps1" -Action ' action
    try {
        if wait
            return RunWait(cmd, A_ScriptDir, "Hide")
        Run(cmd, A_ScriptDir, "Hide")
        return 0
    } catch as e {
        LogLine("Hcore " action " не запустился: " e.Message)
        return -1
    }
}

; --- состояние ---
CoreRunning() {
    return InStr(Http("GET", "/version"), "sing-box") ? true : false
}

UpdateStatus() {
    global gState, gTheme, gPrevTick, gWant, gWantTs, gWarned
    global gProcSeenTs, gHideTries, gUserOpened

    running := ProcessExist("Hiddify.exe") ? true : false

    ; Засекаем момент появления процесса, чтобы отличить окно, которое
    ; Hiddify открыл сам при старте, от окна, открытого пользователем.
    if (running && gProcSeenTs = 0)
        gProcSeenTs := A_TickCount
    if (!running) {
        gProcSeenTs := 0
        gHideTries := 0
        gUserOpened := false
    }
    HideStartupWindow(running)

    core := false
    if running {
        core := CoreRunning()
        if !core {
            ReadApiCreds()                     ; секрет мог смениться
            core := CoreRunning()
        }
    }
    actual := core ? "on" : "off"

    ; команда выполнена - снимаем ожидание
    if (gWant != "" && actual = gWant) {
        LogLine("готово: " gWant)
        gWant := ""
        gWarned := false
    }
    pending := (gWant != "" && (A_TickCount - gWantTs) < WaitTimeout)
    if (gWant != "" && !pending && !gWarned) {
        gWarned := true
        LogLine("команда " gWant " не выполнилась за " (WaitTimeout // 1000) " с")
        TrayTip("Не удалось " (gWant = "on" ? "подключить" : "отключить")
            . " за " (WaitTimeout // 1000) " с.", "Hiddify", 3)
        gWant := ""
    }
    state := pending ? "wait" : actual

    theme := CurrentTheme()
    if (state != gState || theme != gTheme) {
        prev := gState
        gState := state
        gTheme := theme
        try TraySetIcon(IconFor(state, theme))
        if (state = "on" && prev != "" && prev != "on")
            TrayTip("Подключено", "Hiddify")
        ; Ушли из "подключён" без нашей команды - связь оборвалась
        ; (или её выключили в окне Hiddify).
        if (state = "off" && prev = "on" && gWant = "") {
            LogLine("связь пропала без команды")
            TrayTip("Соединение разорвано", "Hiddify", 2)
            if gAutoRecover {
                LogLine("автовосстановление")
                SetTimer((*) => ConnectVPN(), -2000)
            }
        }
    }

    if (state = "on") {
        tip := "Hiddify - подключён"
        node := CurrentNode()
        if (node != "")
            tip .= "`nМаршрут: " node
        spd := SpeedText()
        if (spd != "")
            tip .= "`n" spd
    } else if (state = "wait") {
        tip := (gWant = "on") ? "Hiddify - подключается..." : "Hiddify - отключается..."
        gPrevTick := 0
    } else {
        tip := running ? "Hiddify - отключён" : "Hiddify - приложение не запущено"
        tip .= "`nКлик или Ctrl+Alt+V - подключить"
        gPrevTick := 0
    }
    A_IconTip := SubStr(tip, 1, 126)
}

; Hiddify при запуске разворачивает своё окно. Прячем его, но только
; в первые HideWindowMs после появления процесса: всё, что пользователь
; открыл сам, трогать нельзя.
; ВАЖНО про надёжность: окно Hiddify нарисовано на Flutter, и оно само
; себя восстанавливает. WinHide и WinMinimize выполняются без ошибки, но
; окно возвращается через доли секунды - проверено замером. Поэтому здесь
; лишь несколько попыток на самом старте (иногда успевают сработать, пока
; приложение не закончило инициализацию), а не бесконечная борьба, от
; которой окно мигало бы. Надёжно помогает только штатная настройка
; Hiddify: Настройки -> Общие -> Тихий запуск.
HideStartupWindow(running) {
    global AutoHideWin, HideWindowMs, HideTries, gProcSeenTs, gHideTries, gUserOpened
    if (!AutoHideWin || !running || gUserOpened)
        return
    if (gProcSeenTs = 0 || (A_TickCount - gProcSeenTs) > HideWindowMs)
        return
    if (gHideTries >= HideTries)
        return
    hwnd := WinExist("ahk_exe Hiddify.exe")
    if !hwnd
        return
    try {
        WinHide("ahk_id " hwnd)
        gHideTries += 1
        if (gHideTries = 1)
            LogLine("прячу окно Hiddify после автозапуска")
    }
}

ToggleAutoHide() {
    global AutoHideWin
    AutoHideWin := !AutoHideWin
    if AutoHideWin
        A_TrayMenu.Check("Прятать окно при запуске")
    else
        A_TrayMenu.Uncheck("Прятать окно при запуске")
    TrayTip("Скрытие окна при запуске " (AutoHideWin ? "включено" : "выключено"), "Hiddify")
}

CurrentTheme() {
    try {
        v := RegRead("HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme")
        return v ? "light" : "dark"
    } catch {
        return "dark"
    }
}

IconFor(state, theme) {
    p := A_ScriptDir "\" state "_" theme ".ico"
    if FileExist(p)
        return p
    p2 := A_ScriptDir "\" state ".ico"
    return FileExist(p2) ? p2 : "shell32.dll"
}

; --- команды ---
ConnectVPN() {
    global gWant, gWantTs, gWarned
    if !ProcessExist("Hiddify.exe") {
        LogLine("приложение не запущено - поднимаю задачей")
        TrayTip("Запускаю Hiddify...", "Hiddify")
        RunTask(TaskStart)
        gWant := "on"
        gWantTs := A_TickCount
        gWarned := false
        ; ядру нужно время подняться, потом дать команду
        SetTimer((*) => Hcore("start"), -6000)
        return
    }
    LogLine("команда: start")
    gWant := "on"
    gWantTs := A_TickCount
    gWarned := false
    ApplyState("wait")                         ; отклик сразу, до опроса
    A_IconTip := "Hiddify - подключаю..."
    Hcore("start")
    SetTimer((*) => UpdateStatus(), -2000)
}

DisconnectVPN() {
    global gWant, gWantTs, gWarned
    if !ProcessExist("Hiddify.exe") {
        TrayTip("Приложение не запущено", "Hiddify")
        return
    }
    LogLine("команда: stop")
    gWant := "off"
    gWantTs := A_TickCount
    gWarned := false
    ApplyState("wait")                         ; отклик сразу, до опроса
    A_IconTip := "Hiddify - отключаю..."
    Hcore("stop")
    SetTimer((*) => UpdateStatus(), -2000)
}

ToggleVPN() {
    ; Опираемся на уже известное состояние, а не на новый сетевой
    ; запрос - обработчик хоткея должен возвращать управление сразу.
    LogLine("toggle: состояние=" (gState = "" ? "?" : gState))
    if (gState = "wait")                       ; команда уже выполняется
        return
    if (gState = "on")
        DisconnectVPN()
    else
        ConnectVPN()
}

RestartCore() {
    global gWant, gWantTs, gWarned
    LogLine("команда: restart")
    gWant := "on"
    gWantTs := A_TickCount
    gWarned := false
    Hcore("restart")
    SetTimer((*) => UpdateStatus(), -3000)
}

; При входе в систему скрипт и задача стартуют одновременно, причём
; задача ждёт ещё 10 с. Поэтому не гадаем со временем, а ждём, пока
; приложение реально появится (до ~90 с), и только потом подключаем.
BootConnect(attempt) {
    if CoreRunning() {
        LogLine("автозапуск: ядро уже работает")
        return
    }
    if !ProcessExist("Hiddify.exe") {
        if (attempt = 1) {
            LogLine("автозапуск: приложения нет, запускаю задачу")
            RunTask(TaskStart)
        }
        if (attempt < 30) {
            SetTimer((*) => BootConnect(attempt + 1), -3000)
            return
        }
        LogLine("автозапуск: приложение не появилось за 90 с")
        TrayTip("Hiddify не запустился при входе в систему.", "Hiddify", 3)
        return
    }
    LogLine("автозапуск: подключаю (попытка " attempt ")")
    ConnectVPN()
}

RunTask(name) {
    try Run('schtasks.exe /Run /TN "' name '"', , "Hide")
}

KillApp() {
    global gWant
    LogLine("завершаю приложение")
    gWant := ""
    RunTask(TaskStop)
    TrayTip("Завершаю Hiddify...", "Hiddify")
    SetTimer((*) => UpdateStatus(), -3000)
}

ShowHiddify() {
    global HiddifyExe, HiddifyDir
    if !ProcessExist("Hiddify.exe") {
        RunTask(TaskStart)
        return
    }
    gUserOpened := true                        ; дальше окно не прячем
    ; Окно мы могли спрятать сами - обычный WinExist его не найдёт
    ; и мы бы запустили второй экземпляр приложения.
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    hwnd := WinExist("ahk_exe Hiddify.exe")
    DetectHiddenWindows prev
    if hwnd {
        try {
            WinShow("ahk_id " hwnd)
            if (WinGetMinMax("ahk_id " hwnd) = -1)
                WinRestore("ahk_id " hwnd)
            WinActivate("ahk_id " hwnd)
        }
    } else {
        try Run(HiddifyExe, HiddifyDir)
    }
}

ToggleAutoConnect() {
    global gAutoConnect
    gAutoConnect := !gAutoConnect
    if gAutoConnect
        A_TrayMenu.Check("Подключать при запуске")
    else
        A_TrayMenu.Uncheck("Подключать при запуске")
    TrayTip("Подключение при запуске " (gAutoConnect ? "включено" : "выключено"), "Hiddify")
}

ToggleAutoRecover() {
    global gAutoRecover
    gAutoRecover := !gAutoRecover
    if gAutoRecover
        A_TrayMenu.Check("Восстанавливать при обрыве")
    else
        A_TrayMenu.Uncheck("Восстанавливать при обрыве")
    TrayTip("Восстановление при обрыве " (gAutoRecover ? "включено" : "выключено"), "Hiddify")
}

; --- маршрут и скорость для подсказки ---
CurrentNode() {
    j := Http("GET", "/proxies")
    if (j = "")
        return ""
    if RegExMatch(j, '"now"\s*:\s*"([^"]+)"', &m)
        return RegExReplace(m[1], "\s*§.*$", "")
    return ""
}

SpeedText() {
    global gPrevDown, gPrevUp, gPrevTick
    j := Http("GET", "/connections")
    if (j = "")
        return ""
    if !RegExMatch(j, '"downloadTotal"\s*:\s*(\d+)', &md)
        return ""
    if !RegExMatch(j, '"uploadTotal"\s*:\s*(\d+)', &mu)
        return ""
    d := md[1] + 0
    u := mu[1] + 0
    t := A_TickCount
    out := ""
    if (gPrevTick > 0 && t > gPrevTick) {
        secs := (t - gPrevTick) / 1000
        dd := (d - gPrevDown) / secs
        uu := (u - gPrevUp) / secs
        if (dd < 0)
            dd := 0
        if (uu < 0)
            uu := 0
        out := "↓ " Rate(dd) "   ↑ " Rate(uu)
    }
    gPrevDown := d
    gPrevUp := u
    gPrevTick := t
    return out
}

Rate(bps) {
    if (bps >= 1048576)
        return Round(bps / 1048576, 1) " МБ/с"
    if (bps >= 1024)
        return Round(bps / 1024) " КБ/с"
    return Round(bps) " Б/с"
}

; --- автозапуск приложения задачей планировщика ---
AutostartEnabled() {
    global TaskStart
    try {
        svc := ComObject("Schedule.Service")
        svc.Connect()
        return svc.GetFolder("\").GetTask(TaskStart).Enabled ? true : false
    } catch {
        return false
    }
}

RefreshAutostartCheck() {
    try {
        if AutostartEnabled()
            A_TrayMenu.Check("Автозапуск при входе")
        else
            A_TrayMenu.Uncheck("Автозапуск при входе")
    }
}

ToggleAutostart() {
    global TaskStart
    try {
        svc := ComObject("Schedule.Service")
        svc.Connect()
        t := svc.GetFolder("\").GetTask(TaskStart)
        t.Enabled := !t.Enabled
        st := t.Enabled ? "включён" : "выключен"
    } catch as e {
        TrayTip("Не удалось изменить автозапуск:`n" e.Message, "Hiddify", 3)
        return
    }
    RefreshAutostartCheck()
    TrayTip("Автозапуск " st, "Hiddify")
}
