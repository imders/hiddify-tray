# Полный цикл включения и выключения ядра.
#
# ВНИМАНИЕ: тест реально разрывает VPN на время выполнения, поэтому по
# умолчанию пропускается. Запуск: Run-Tests.ps1 -Destructive

Write-Host 'Переключение ядра (нагрузочный тест)' -ForegroundColor White
$root = Get-RepoRoot
$hcore = Join-Path $root 'src\hcore.ps1'

function Invoke-Core {
    param([string]$Action)
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass `
        -File $hcore -Action $Action 2>&1 | Out-String
}

if (-not $env:HIDDIFYTRAY_DESTRUCTIVE) {
    It 'цикл stop -> start (нужен ключ -Destructive)' { return 'SKIP' }
    It 'приложение переживает остановку ядра (нужен ключ -Destructive)' { return 'SKIP' }
    return
}

if (-not (Test-HiddifyRunning)) {
    It 'цикл stop -> start (Hiddify не запущен)' { return 'SKIP' }
    return
}

$wasUp = (Get-TunnelStatus) -eq 'Up'

It 'Stop гасит туннель' {
    if (-not $wasUp) { return 'SKIP' }
    Invoke-Core -Action stop | Out-Null
    $t = Wait-Until -Condition { (Get-TunnelStatus) -ne 'Up' } -TimeoutSec 30
    Assert-True ($null -ne $t) 'туннель не погас за 30 с'
}

It 'приложение остаётся живым после остановки ядра' {
    # Главное отличие от старого подхода: гасим ядро, а не убиваем процесс
    Assert-True (Test-HiddifyRunning) 'процесс Hiddify исчез, хотя не должен был'
}

It 'Start поднимает туннель обратно' {
    Invoke-Core -Action start | Out-Null
    $t = Wait-Until -Condition { (Get-TunnelStatus) -eq 'Up' } -TimeoutSec 90
    Assert-True ($null -ne $t) 'туннель не поднялся за 90 с'
}

It 'состояние восстановлено' {
    if (-not $wasUp) { return 'SKIP' }
    Assert-Equal 'Up' (Get-TunnelStatus) 'VPN остался выключенным после теста'
}
