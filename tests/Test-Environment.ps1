# Проверки окружения и целостности репозитория.
# Безопасны: ничего не запускают и не переключают.

Write-Host 'Окружение и файлы' -ForegroundColor White
$root = Get-RepoRoot

It 'PowerShell версии 7 или новее' {
    Assert-True ($PSVersionTable.PSVersion.Major -ge 7) `
        "нужен pwsh 7+, найден $($PSVersionTable.PSVersion)"
}

It 'HTTP/2 без TLS доступен в этой сборке .NET' {
    # На h2c держится весь gRPC-транспорт, проверяем что тип есть
    Assert-True ([System.Net.Http.HttpVersionPolicy].FullName -ne $null)
}

It 'AutoHotkey v2 установлен' {
    if (-not (Find-AutoHotkeyExe)) { throw 'AutoHotkey v2 не найден' }
    return $true
}

It 'исходники на месте' {
    Assert-FileExists (Join-Path $root 'src\HiddifyTray.ahk')
    Assert-FileExists (Join-Path $root 'src\hcore.ps1')
}

It 'все шесть иконок присутствуют' {
    $need = 'on_dark', 'on_light', 'wait_dark', 'wait_light', 'off_dark', 'off_light'
    foreach ($n in $need) {
        Assert-FileExists (Join-Path $root "assets\$n.ico")
    }
    return $true
}

It 'иконки содержат несколько размеров' {
    # ICONDIR: reserved(2) type(2) count(2). Один размер = мыло в трее,
    # ради этого всё и собиралось многоразмерным.
    $f = Join-Path $root 'assets\on_dark.ico'
    $b = [System.IO.File]::ReadAllBytes($f)
    $count = [BitConverter]::ToUInt16($b, 4)
    Assert-True ($count -ge 4) "в on_dark.ico всего $count размер(ов)"
}

It 'AHK-скрипт проходит проверку синтаксиса' {
    $ahk = Find-AutoHotkeyExe
    if (-not $ahk) { return 'SKIP' }
    $err = Join-Path $env:TEMP 'hiddifytray_validate.txt'
    $p = Start-Process $ahk -ArgumentList '/ErrorStdOut', '/validate',
        "`"$(Join-Path $root 'src\HiddifyTray.ahk')`"" `
        -Wait -PassThru -NoNewWindow -RedirectStandardError $err
    if ($p.ExitCode -ne 0) {
        $msg = if (Test-Path $err) { (Get-Content $err -Raw).Trim() } else { 'без деталей' }
        throw $msg
    }
    return $true
}

It 'hcore.ps1 разбирается парсером PowerShell' {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'src\hcore.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw ($errors[0].Message) }
    return $true
}

It 'install.ps1 и uninstall.ps1 разбираются парсером' {
    foreach ($n in 'install.ps1', 'uninstall.ps1') {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root "tools\$n"), [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count) { throw "$n : $($errors[0].Message)" }
    }
    return $true
}

It 'в исходниках нет личных данных' {
    # Секрет Clash API обязан читаться из конфига, а не лежать в коде
    $files = Get-ChildItem (Join-Path $root 'src') -File
    foreach ($f in $files) {
        $t = Get-Content $f.FullName -Raw
        if ($t -match 'C:\\Users\\(?!<)[A-Za-z0-9._-]+\\') {
            throw "$($f.Name): найден путь к домашнему каталогу"
        }
        # localhost допустим, любой другой IP - нет
        $ips = [regex]::Matches($t, '\b\d{1,3}(\.\d{1,3}){3}\b') |
               ForEach-Object { $_.Value } |
               Where-Object { $_ -notin '127.0.0.1', '1.1.1.1', '0.0.0.0' }
        if ($ips) { throw "$($f.Name): посторонний IP $($ips -join ', ')" }
    }
    return $true
}
