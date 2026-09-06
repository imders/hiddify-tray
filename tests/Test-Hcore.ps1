# Проверки gRPC-транспорта. Читающие вызовы безопасны: GetSystemInfo
# ничего не меняет. Тесты пропускаются, если Hiddify не запущен.

Write-Host 'gRPC-транспорт (hcore.ps1)' -ForegroundColor White
$root = Get-RepoRoot
$hcore = Join-Path $root 'src\hcore.ps1'

function Invoke-Hcore2 {
    param([string]$Action = 'info', [string]$Endpoint)
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hcore, '-Action', $Action)
    if ($Endpoint) { $args += @('-Endpoint', $Endpoint) }
    $out = & (Get-Process -Id $PID).Path @args 2>&1 | Out-String
    return [pscustomobject]@{ Output = $out.Trim(); Code = $LASTEXITCODE }
}

It 'GetSystemInfo отвечает с grpc-status=0' {
    if (-not (Test-HiddifyRunning)) { return 'SKIP' }
    $r = Invoke-Hcore2 -Action info
    Assert-Equal 0 $r.Code "hcore.ps1 вернул $($r.Code): $($r.Output)"
    Assert-Match 'grpc-status=0' $r.Output
}

It 'ответ приходит по HTTP 200' {
    if (-not (Test-HiddifyRunning)) { return 'SKIP' }
    $r = Invoke-Hcore2 -Action info
    Assert-Match 'http=200' $r.Output
}

It 'порт находится сам, если указан неверный' {
    # Порт gRPC у Hiddify стабилен, но зашивать его намертво нельзя -
    # хелпер обязан перебрать порты процесса и найти рабочий.
    if (-not (Test-HiddifyRunning)) { return 'SKIP' }
    $r = Invoke-Hcore2 -Action info -Endpoint '127.0.0.1:19' # заведомо чужой порт
    Assert-Equal 0 $r.Code "автопоиск не сработал: $($r.Output)"
    Assert-Match 'grpc-status=0' $r.Output
}

It 'при остановленном приложении возвращает ошибку, а не виснет' {
    if (Test-HiddifyRunning) { return 'SKIP' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Hcore2 -Action info
    $sw.Stop()
    Assert-True ($r.Code -ne 0) 'ожидался ненулевой код возврата'
    Assert-True ($sw.Elapsed.TotalSeconds -lt 40) "ждали слишком долго: $($sw.Elapsed.TotalSeconds) c"
}

It 'недопустимое действие отклоняется валидацией параметра' {
    $r = Invoke-Hcore2 -Action 'destroy-everything'
    Assert-True ($r.Code -ne 0) 'недопустимое действие должно отклоняться'
}
