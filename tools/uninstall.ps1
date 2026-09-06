<#
.SYNOPSIS
    Удаляет HiddifyTray: останавливает скрипт, убирает задачи планировщика,
    ярлык автозагрузки и файлы.

.DESCRIPTION
    Сам Hiddify не трогает - удаляется только обвязка. Для удаления задач
    планировщика нужны права администратора, скрипт запросит их сам.

.PARAMETER InstallDir
    Откуда удалять. По умолчанию %LOCALAPPDATA%\HiddifyTray.

.PARAMETER KeepFiles
    Оставить файлы на диске, убрать только автозапуск и задачи.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File tools\uninstall.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'HiddifyTray'),
    [switch]$KeepFiles,
    [string]$OriginalUser
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Скрипт трея останавливаем до повышения прав - он работает от пользователя
Write-Step 'Останавливаю трей'
$stopped = 0
Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*HiddifyTray.ahk*' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $stopped++
    }
Write-Ok "$stopped процесс(ов)"

Write-Step 'Убираю ярлык автозагрузки'
$startup = [Environment]::GetFolderPath('Startup')
if ($OriginalUser) {
    $name = $OriginalUser.Split('\')[-1]
    $candidate = "C:\Users\$name\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
    if (Test-Path $candidate) { $startup = $candidate }
}
$lnk = Join-Path $startup 'HiddifyTray.lnk'
if (Test-Path $lnk) {
    [System.IO.File]::Delete($lnk)
    Write-Ok $lnk
} else {
    Write-Ok 'ярлыка не было'
}

if (-not (Test-Admin)) {
    Write-Step 'Для удаления задач планировщика нужны права администратора'
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-InstallDir', "`"$InstallDir`"", '-OriginalUser', "`"$me`"")
    if ($KeepFiles) { $argList += '-KeepFiles' }
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList `
                       -Verb RunAs -Wait -PassThru
    exit $p.ExitCode
}

Write-Step 'Удаляю задачи планировщика'
foreach ($t in 'Hiddify_Autostart', 'Hiddify_Stop') {
    if (Get-ScheduledTask -TaskName $t -TaskPath '\' -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t -TaskPath '\' -Confirm:$false
        Write-Ok $t
    }
}

if (-not $KeepFiles) {
    Write-Step "Удаляю файлы из $InstallDir"
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
        Write-Ok 'удалено'
    } else {
        Write-Ok 'каталога не было'
    }
}

Write-Step 'Готово. Сам Hiddify не тронут.'
exit 0
