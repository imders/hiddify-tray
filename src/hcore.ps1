# Вызов gRPC-метода hiddify-core без сторонних библиотек.
# gRPC = HTTP/2 (h2c) + кадр: [1 байт сжатия][4 байта длины BE][protobuf].
# Методы Start/Stop/Restart принимают пустое сообщение, поэтому payload пуст.
#
# Порт gRPC у Hiddify 4.1.1 стабильно 17078, но если он вдруг сменится,
# ищем его среди слушающих портов процесса Hiddify.
param(
    [ValidateSet('start', 'stop', 'restart', 'info')]
    [string]$Action = 'info',
    [string]$Endpoint = '127.0.0.1:17078',
    [int]$TimeoutSec = 25
)

$map = @{
    'start'   = '/hcore.Core/Start'
    'stop'    = '/hcore.Core/Stop'
    'restart' = '/hcore.Core/Restart'
    'info'    = '/hcore.Core/GetSystemInfo'
}
$path = $map[$Action]

function Invoke-Hcore {
    param([string]$Target, [string]$Path, [int]$Timeout)

    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
    $client.DefaultRequestVersion = [Version]::new(2, 0)
    $client.DefaultVersionPolicy = [System.Net.Http.HttpVersionPolicy]::RequestVersionExact

    $req = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post, "http://$Target$Path")
    $req.Version = [Version]::new(2, 0)
    $req.VersionPolicy = [System.Net.Http.HttpVersionPolicy]::RequestVersionExact

    # пустое protobuf-сообщение: флаг сжатия 0 + длина 0
    $body = [byte[]]@(0, 0, 0, 0, 0)
    $content = [System.Net.Http.ByteArrayContent]::new($body)
    $content.Headers.ContentType =
        [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/grpc')
    $req.Content = $content
    $req.Headers.TryAddWithoutValidation('te', 'trailers') | Out-Null
    $req.Headers.TryAddWithoutValidation('grpc-timeout', "${Timeout}S") | Out-Null

    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()

    $status = $null
    $n = 'grpc-status'
    if ($resp.TrailingHeaders -and $resp.TrailingHeaders.Contains($n)) {
        $status = ($resp.TrailingHeaders.GetValues($n) | Select-Object -First 1)
    } elseif ($resp.Headers.Contains($n)) {
        $status = ($resp.Headers.GetValues($n) | Select-Object -First 1)
    }
    $payload = ''
    if ($bytes.Length -gt 5) {
        $payload = -join ($bytes[5..($bytes.Length - 1)] | ForEach-Object {
            if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
    }
    return [pscustomobject]@{
        Target  = $Target
        Http    = [int]$resp.StatusCode
        Status  = $status
        Bytes   = $bytes.Length
        Payload = $payload
    }
}

# Кандидаты: сперва заданный порт, затем прочие порты процесса Hiddify.
# Известные не-gRPC порты пропускаем (mixed-прокси, dns, clash api, pprof).
function Get-Candidates {
    param([string]$Preferred)
    $list = @($Preferred)
    try {
        $proc = Get-Process -Name Hiddify -ErrorAction Stop | Select-Object -First 1
        $skip = @(12334, 12337, 6060)
        $cfg = Join-Path $env:APPDATA 'Hiddify\hiddify\data\current-config.json'
        if (Test-Path $cfg) {
            $raw = Get-Content $cfg -Raw
            if ($raw -match '"external_controller"\s*:\s*"[^:"]+:(\d+)"') { $skip += [int]$Matches[1] }
        }
        $ports = Get-NetTCPConnection -State Listen -ErrorAction Stop |
                 Where-Object { $_.OwningProcess -eq $proc.Id -and $_.LocalPort -notin $skip } |
                 Select-Object -ExpandProperty LocalPort -Unique
        foreach ($p in $ports) {
            $t = "127.0.0.1:$p"
            if ($list -notcontains $t) { $list += $t }
        }
    } catch { }
    return $list
}

$lastErr = ''
foreach ($target in (Get-Candidates -Preferred $Endpoint)) {
    try {
        $r = Invoke-Hcore -Target $target -Path $path -Timeout $TimeoutSec
        "http=$($r.Http) grpc-status=$($r.Status) target=$($r.Target) bytes=$($r.Bytes) payload=$($r.Payload)"
        if ($null -ne $r.Status -and $r.Status -ne '0') { exit 2 }
        exit 0
    }
    catch {
        $lastErr = $_.Exception.Message
        continue
    }
}
"ERROR: $lastErr"
exit 1
