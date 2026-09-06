<#
.SYNOPSIS
    Прогоняет все проверки HiddifyTray.

.DESCRIPTION
    По умолчанию выполняются только безопасные тесты: они ничего не
    переключают и не рвут соединение. Тесты, зависящие от запущенного
    Hiddify, помечаются как пропущенные, если он не работает.

.PARAMETER Destructive
    Дополнительно прогнать полный цикл stop -> start. VPN на время теста
    будет разорван, затем восстановлен.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File tests\Run-Tests.ps1

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 -Destructive
#>
[CmdletBinding()]
param([switch]$Destructive)

. (Join-Path $PSScriptRoot 'Common.ps1')

Reset-TestStats
if ($Destructive) { $env:HIDDIFYTRAY_DESTRUCTIVE = '1' }

Write-Host ''
Write-Host 'HiddifyTray - проверки' -ForegroundColor Cyan
Write-Host ('-' * 46)
Write-Host ("Hiddify запущен : {0}" -f (Test-HiddifyRunning))
Write-Host ("Туннель tun0    : {0}" -f (Get-TunnelStatus))
Write-Host ('-' * 46)

foreach ($f in 'Test-Environment.ps1', 'Test-Hcore.ps1', 'Test-Toggle.ps1') {
    Write-Host ''
    . (Join-Path $PSScriptRoot $f)
}

$s = Get-TestStats
Write-Host ''
Write-Host ('-' * 46)
Write-Host ("Всего: {0}   Успешно: {1}   Пропущено: {2}   Провалено: {3}" -f `
    $s.Total, $s.Passed, $s.Skipped, $s.Failed) -ForegroundColor (
        $(if ($s.Failed) { 'Red' } else { 'Green' }))
Write-Host ''

if ($env:HIDDIFYTRAY_DESTRUCTIVE) { Remove-Item Env:\HIDDIFYTRAY_DESTRUCTIVE -ErrorAction SilentlyContinue }
exit ($s.Failed -gt 0 ? 1 : 0)
