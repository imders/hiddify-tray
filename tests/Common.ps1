# Минимальный тест-раннер. Намеренно без Pester: у пользователя Windows
# его может не быть, а тянуть зависимость ради десятка проверок незачем.

$script:Total = 0
$script:Failed = 0
$script:Skipped = 0

function Reset-TestStats {
    $script:Total = 0
    $script:Failed = 0
    $script:Skipped = 0
}

function Get-TestStats {
    return [pscustomobject]@{
        Total   = $script:Total
        Failed  = $script:Failed
        Skipped = $script:Skipped
        Passed  = $script:Total - $script:Failed - $script:Skipped
    }
}

# Одна проверка. Тело должно вернуть $true либо кинуть исключение.
function It {
    param([string]$Name, [scriptblock]$Body)

    $script:Total++
    try {
        $r = & $Body
        # Тело может вернуть несколько значений - интересует последнее.
        if ($r -is [array] -and $r.Count) { $r = $r[-1] }
        # Сравнение делаем строго по типу: PowerShell приводит правый
        # операнд к типу левого, и $true -eq 'SKIP' даёт истину.
        if (($r -is [string]) -and ($r -eq 'SKIP')) {
            $script:Skipped++
            Write-Host "  ~ $Name" -ForegroundColor DarkYellow
            return
        }
        if (($r -is [bool]) -and (-not $r)) { throw 'проверка вернула false' }
        Write-Host "  + $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "  - $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}

function Assert-True {
    param($Condition, [string]$Message = 'ожидалось истинное значение')
    if (-not $Condition) { throw $Message }
    return $true
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw ($Message ? $Message : "ожидалось '$Expected', получено '$Actual'")
    }
    return $true
}

function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Message)
    if ($Actual -notmatch $Pattern) {
        throw ($Message ? $Message : "'$Actual' не совпало с /$Pattern/")
    }
    return $true
}

function Assert-FileExists {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "нет файла: $Path" }
    return $true
}

# --- вспомогательное про окружение ---

function Get-RepoRoot {
    return (Split-Path $PSScriptRoot -Parent)
}

function Find-AutoHotkeyExe {
    $paths = @(
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey32.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe')
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $null
}

function Test-HiddifyRunning {
    return [bool](Get-Process -Name 'Hiddify' -ErrorAction SilentlyContinue)
}

function Get-TunnelStatus {
    $a = Get-NetAdapter -Name 'tun0' -ErrorAction SilentlyContinue
    if (-not $a) { return 'ABSENT' }
    return [string]$a.Status
}

# Ждём, пока условие станет истинным. Возвращает секунды или $null.
function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSec = 60, [int]$IntervalSec = 3)
    $waited = 0
    while ($waited -lt $TimeoutSec) {
        Start-Sleep -Seconds $IntervalSec
        $waited += $IntervalSec
        if (& $Condition) { return $waited }
    }
    return $null
}
