# Рисует монохромные иконки трея (щит) во всех размерах, которые
# может запросить Windows, и складывает их многоразмерными .ico.
# Запускать нужно только если хочется поменять цвет или форму -
# готовые иконки уже лежат в assets/.
param(
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'assets')
)
Add-Type -AssemblyName System.Drawing
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$out = $OutDir

# Монохром: цвет подбирается под панель задач.
#   dark  = тёмная панель -> белая иконка
#   light = светлая панель -> графитовая иконка
$themes = @{
    'dark'  = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
    'light' = [System.Drawing.Color]::FromArgb(255, 26, 26, 26)
}

function ShieldPath([single]$s, [single]$inset) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $f = { param($fx, $fy) [System.Drawing.PointF]::new(
            [single]($inset + $fx * ($s - 2 * $inset)),
            [single]($inset + $fy * ($s - 2 * $inset))) }
    $a = & $f 0.50 0.03;  $b = & $f 0.90 0.20
    $c = & $f 0.90 0.52
    $p.AddLine($a, $b)
    $p.AddLine($b, $c)
    $p.AddBezier($c, (& $f 0.90 0.775), (& $f 0.695 0.905), (& $f 0.50 0.97))
    $p.AddBezier((& $f 0.50 0.97), (& $f 0.305 0.905), (& $f 0.10 0.775), (& $f 0.10 0.52))
    $p.AddLine((& $f 0.10 0.52), (& $f 0.10 0.20))
    $p.CloseFigure()
    return $p
}

# Превращает штрих в замкнутый контур - нужно для вычитания из фигуры
function WidenPath([System.Drawing.Drawing2D.GraphicsPath]$path, [single]$width) {
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), $width
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $clone = $path.Clone()
    $clone.Widen($pen)
    return $clone
}

function RenderIcon([string]$state, [string]$theme, [int]$size) {
    $col = $themes[$theme]
    $s = [single]$size
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode   = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $inset = [single]($s * 0.06)
    $shield = ShieldPath $s $inset
    $brush = New-Object System.Drawing.SolidBrush $col
    $stroke = [single]([Math]::Max(1.35, $s * 0.10))
    $f = { param($fx, $fy) [System.Drawing.PointF]::new(
            [single]($inset + $fx * ($s - 2 * $inset)),
            [single]($inset + $fy * ($s - 2 * $inset))) }

    if ($state -eq 'on') {
        # сплошной щит, галочка вырезана насквозь
        $chk = New-Object System.Drawing.Drawing2D.GraphicsPath
        $chk.AddLine((& $f 0.30 0.50), (& $f 0.44 0.645))
        $chk.AddLine((& $f 0.44 0.645), (& $f 0.71 0.35))
        $cut = WidenPath $chk ([single]([Math]::Max(1.5, $s * 0.115)))
        $rg = New-Object System.Drawing.Region $shield
        $rg.Exclude($cut)
        $g.FillRegion($brush, $rg)
    }
    elseif ($state -eq 'wait') {
        # контур щита + три точки
        $ring = WidenPath $shield $stroke
        $g.FillPath($brush, $ring)
        $d = [single]($s * 0.125)
        foreach ($cx in @(0.30, 0.50, 0.70)) {
            $pt = & $f $cx 0.52
            $g.FillEllipse($brush, [single]($pt.X - $d / 2), [single]($pt.Y - $d / 2), $d, $d)
        }
    }
    else {
        # контур щита, перечёркнутый по диагонали
        $ring = WidenPath $shield $stroke
        $rg = New-Object System.Drawing.Region $ring
        $slashCut = New-Object System.Drawing.Drawing2D.GraphicsPath
        $slashCut.AddLine((& $f 0.14 0.90), (& $f 0.86 0.10))
        # прорезь вокруг черты, чтобы она читалась поверх контура
        $rg.Exclude((WidenPath $slashCut ([single]($stroke * 2.0))))
        $g.FillRegion($brush, $rg)
        $slash = New-Object System.Drawing.Drawing2D.GraphicsPath
        $slash.AddLine((& $f 0.20 0.82), (& $f 0.80 0.18))
        $g.FillPath($brush, (WidenPath $slash $stroke))
    }
    $g.Dispose()
    return $bmp
}

function SaveIco([string]$state, [string]$theme, [int[]]$sizes, [string]$path) {
    $pngs = @()
    foreach ($sz in $sizes) {
        $bmp = RenderIcon $state $theme $sz
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs += , $ms.ToArray()
        $ms.Dispose(); $bmp.Dispose()
    }
    $fs = [System.IO.File]::Create($path)
    $bw = New-Object System.IO.BinaryWriter $fs
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $sz = $sizes[$i]
        $bw.Write([byte]$sz); $bw.Write([byte]$sz)
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $bw.Write($p) }
    $bw.Flush(); $bw.Close(); $fs.Close()
}

$sizes = @(16, 20, 24, 32, 48, 64, 128)
foreach ($st in @('on', 'wait', 'off')) {
    foreach ($th in @('dark', 'light')) {
        $f = Join-Path $out "${st}_${th}.ico"
        SaveIco $st $th $sizes $f
        Write-Output ("{0}_{1}.ico  {2} bytes" -f $st, $th, (Get-Item $f).Length)
    }
}
