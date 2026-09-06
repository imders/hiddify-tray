<#
.SYNOPSIS
    Устанавливает HiddifyTray: копирует файлы, создаёт задачи планировщика
    и ярлык автозапуска, запускает трей-скрипт.

.DESCRIPTION
    Задачи планировщика создаются с RunLevel Highest. Это нужно по двум
    причинам: Hiddify в режиме TUN требует повышенных прав, и запуск через
    задачу позволяет трею поднимать приложение без UAC-окна при каждом
    переключении.

    Для создания задач нужны права администратора - скрипт сам запросит их
    через UAC, если запущен без них.

.PARAMETER InstallDir
    Куда положить файлы. По умолчанию %LOCALAPPDATA%\HiddifyTray.

.PARAMETER NoAutostart
    Не создавать ярлык в автозагрузке и задачу входа в систему.

.PARAMETER OriginalUser
    Служебный параметр: под каким пользователем создавать задачи.
    Заполняется автоматически при перезапуске с повышением прав.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File tools\install.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'HiddifyTray'),
    [switch]$NoAutostart,
    [string]$OriginalUser
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-AutoHotkey {
    $paths = @(
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey32.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe')
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $null
}

function Find-Hiddify {
    $paths = @(
        (Join-Path $env:ProgramFiles 'Hiddify\Hiddify.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Hiddify\Hiddify.exe'),
        (Join-Path $env:LOCALAPPDATA 'Hiddify\Hiddify.exe')
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $null
}

# ---------------------------------------------------------------- проверки
Write-Step 'Проверяю окружение'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Нужен PowerShell 7+ (pwsh). Текущая версия: $($PSVersionTable.PSVersion). " +
          "Установите: winget install Microsoft.PowerShell"
}
Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

$ahk = Find-AutoHotkey
if (-not $ahk) {
    throw 'Не найден AutoHotkey v2. Установите: winget install AutoHotkey.AutoHotkey'
}
Write-Ok "AutoHotkey: $ahk"

$hiddify = Find-Hiddify
if (-not $hiddify) {
    Write-Warn2 'Hiddify не найден в стандартных каталогах.'
    Write-Warn2 'Установка продолжится, но трей не сможет запускать приложение.'
} else {
    Write-Ok "Hiddify: $hiddify"
}

# ------------------------------------------------- повышение прав при нужде
if (-not $NoAutostart -and -not (Test-Admin)) {
    Write-Step 'Нужны права администратора для задач планировщика - запрашиваю'
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
        '-InstallDir', "`"$InstallDir`"", '-OriginalUser', "`"$me`""
    )
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList `
                       -Verb RunAs -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Установка с повышением прав завершилась с кодом $($p.ExitCode)" }
    Write-Ok 'Готово'
    return
}

$taskUser = if ($OriginalUser) { $OriginalUser } else { "$env:USERDOMAIN\$env:USERNAME" }

# ---------------------------------------------------------------- файлы
Write-Step "Копирую файлы в $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item (Join-Path $repoRoot 'src\HiddifyTray.ahk') $InstallDir -Force
Copy-Item (Join-Path $repoRoot 'src\hcore.ps1')       $InstallDir -Force
Get-ChildItem (Join-Path $repoRoot 'assets') -Filter '*.ico' |
    Copy-Item -Destination $InstallDir -Force
Write-Ok "$((Get-ChildItem $InstallDir -File).Count) файлов"

# ---------------------------------------------------------------- задачи
if (-not $NoAutostart) {
    Write-Step 'Создаю задачи планировщика'
    if (-not $hiddify) {
        Write-Warn2 'Пропускаю: путь к Hiddify неизвестен'
    } else {
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -DontStopOnIdleEnd `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
            -StartWhenAvailable
        $principal = New-ScheduledTaskPrincipal -UserId $taskUser `
            -LogonType Interactive -RunLevel Highest

        $action = New-ScheduledTaskAction -Execute $hiddify `
            -WorkingDirectory (Split-Path $hiddify -Parent)
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
        $trigger.Delay = 'PT10S'
        Register-ScheduledTask -TaskName 'Hiddify_Autostart' -Action $action `
            -Trigger $trigger -Principal $principal -Settings $settings `
            -Description 'Запускает Hiddify при входе; трей использует эту же задачу для старта.' `
            -Force | Out-Null
        Write-Ok 'Hiddify_Autostart'

        $stopAction = New-ScheduledTaskAction -Execute 'taskkill.exe' `
            -Argument '/IM Hiddify.exe /F /T'
        Register-ScheduledTask -TaskName 'Hiddify_Stop' -Action $stopAction `
            -Principal $principal -Settings $settings `
            -Description 'Полностью завершает Hiddify (используется пунктом меню трея).' `
            -Force | Out-Null
        Write-Ok 'Hiddify_Stop'
    }

    Write-Step 'Добавляю трей в автозагрузку'
    $startup = [Environment]::GetFolderPath('Startup')
    if ($OriginalUser) {
        # под повышенными правами %APPDATA% может указывать на другого
        # пользователя - берём каталог автозагрузки исходного
        $name = $OriginalUser.Split('\')[-1]
        $candidate = "C:\Users\$name\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
        if (Test-Path $candidate) { $startup = $candidate }
    }
    $lnkPath = Join-Path $startup 'HiddifyTray.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = $ahk
    $lnk.Arguments = "`"$(Join-Path $InstallDir 'HiddifyTray.ahk')`""
    $lnk.WorkingDirectory = $InstallDir
    $lnk.IconLocation = Join-Path $InstallDir 'on_dark.ico'
    $lnk.Description = 'HiddifyTray - статус и переключатель Hiddify'
    $lnk.Save()
    Write-Ok $lnkPath
}

Write-Step 'Готово'
Write-Host ''
Write-Host '  Запустить сейчас:' -ForegroundColor White
Write-Host "    & `"$ahk`" `"$(Join-Path $InstallDir 'HiddifyTray.ahk')`"" -ForegroundColor Gray
Write-Host ''
Write-Host '  Переключение: клик по иконке в трее или Ctrl+Alt+V' -ForegroundColor White
Write-Host ''
exit 0
