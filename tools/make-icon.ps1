# Generates assets\tray.ico with classic 32bpp DIB entries (BITMAPINFOHEADER + bottom-up BGRA + 1bpp AND mask).
# PNG-in-ICO entries are not readable by GDI+ / some ExtractIconEx paths, so we avoid them.
# Sizes: 16, 32, 48. Run: powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-icon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $root 'assets'
New-Item -ItemType Directory -Force -Path $assets | Out-Null

$backgroundColor = [System.Drawing.Color]::FromArgb(255, 32, 38, 57)
$cellColor = [System.Drawing.Color]::FromArgb(255, 246, 247, 250)
$accentColor = [System.Drawing.Color]::FromArgb(255, 96, 165, 250)
$sizes = @(16, 32, 48)

function New-IconFrame {
    param([int]$size)

    $bmp = New-Object System.Drawing.Bitmap ($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $pad = [Math]::Max(1, [int]($size * 0.06))
    $rect = New-Object System.Drawing.Rectangle ($pad, $pad, ($size - 2 * $pad), ($size - 2 * $pad))
    $radius = [Math]::Max(2, [int]($size * 0.22))
    $d = $radius * 2

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc(($rect.Right - $d), $rect.Y, $d, $d, 270, 90)
    $path.AddArc(($rect.Right - $d), ($rect.Bottom - $d), $d, $d, 0, 90)
    $path.AddArc($rect.X, ($rect.Bottom - $d), $d, $d, 90, 90)
    $path.CloseFigure()

    $bgBrush = New-Object System.Drawing.SolidBrush $backgroundColor
    $g.FillPath($bgBrush, $path)

    $cell = [Math]::Max(2, [int]($size * 0.20))
    $gap = [Math]::Max(1, [int]($size * 0.10))
    $span = 2 * $cell + $gap
    $startX = [int](($size - $span) / 2)
    $startY = [int](($size - $span) / 2)

    for ($r = 0; $r -lt 2; $r++) {
        for ($c = 0; $c -lt 2; $c++) {
            $isAccent = ($r -eq 1) -and ($c -eq 1)
            $useColor = $cellColor
            if ($isAccent) { $useColor = $accentColor }
            $brush = New-Object System.Drawing.SolidBrush $useColor
            $x = $startX + ($c * ($cell + $gap))
            $y = $startY + ($r * ($cell + $gap))
            if ($isAccent -and ($size -ge 32)) {
                # 右下角那一格画成短横：读作"这一格被收起来了"
                $barHeight = [Math]::Max(1, [int]($cell * 0.3))
                $g.FillRectangle($brush, [int]($x + $cell * 0.15), [int]($y + ($cell - $barHeight) / 2), [int]($cell * 0.7), $barHeight)
            }
            else {
                $g.FillRectangle($brush, $x, $y, $cell, $cell)
            }
            $brush.Dispose()
        }
    }

    $bgBrush.Dispose()
    $path.Dispose()
    $g.Dispose()
    return $bmp
}

# Writes one ICONIMAGE (header + XOR + AND mask) into $w, returns how many bytes were written.
function Write-IcoImage {
    param([System.Drawing.Bitmap]$bmp, [System.IO.BinaryWriter]$w)

    $size = $bmp.Width
    $rect = New-Object System.Drawing.Rectangle (0, 0, $size, $size)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = [Math]::Abs($data.Stride)
    $pixels = New-Object byte[] ($size * $size * 4)
    $written = 0
    try {
        $row = New-Object byte[] $stride
        for ($y = $size - 1; $y -ge 0; $y--) {
            [void][System.Runtime.InteropServices.Marshal]::Copy(
                [IntPtr]($data.Scan0.ToInt64() + ($y * $stride)), $row, 0, $stride)
            [Array]::Copy($row, 0, $pixels, (($size - 1 - $y) * $size * 4), ($size * 4))
        }
    }
    finally {
        $bmp.UnlockBits($data)
    }

    $maskRowBytes = [int]([Math]::Ceiling($size / 32.0)) * 4
    $maskLength = $maskRowBytes * $size
    $mask = New-Object byte[] $maskLength          # all zero: alpha carries the transparency

    # BITMAPINFOHEADER：BinaryWriter 没有 (byte[]) 构造函数，必须走 MemoryStream
    $dibMs = New-Object System.IO.MemoryStream
    $dh = New-Object System.IO.BinaryWriter $dibMs
    $dh.Write([int32]40)                # biSize
    $dh.Write([int32]$size)             # biWidth
    $dh.Write([int32]($size * 2))       # biHeight = XOR + AND 两段
    $dh.Write([uint16]1)                # biPlanes
    $dh.Write([uint16]32)               # biBitCount
    $dh.Write([uint32]0)                # BI_RGB
    $dh.Write([uint32]($pixels.Length + $maskLength))
    $dh.Write([int32]0)
    $dh.Write([int32]0)
    $dh.Write([uint32]0)
    $dh.Write([uint32]0)
    $dh.Flush()
    $dib = $dibMs.ToArray()
    $dh.Dispose(); $dibMs.Dispose()

    $w.Write([byte[]]$dib)
    $w.Write([byte[]]$pixels)
    $w.Write([byte[]]$mask)
    $written = $dib.Length + $pixels.Length + $maskLength
    return $written
}

$target = Join-Path $assets 'tray.ico'
$ms = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $ms

$headerLength = 6 + (16 * $sizes.Count)
$w.Write((New-Object byte[] $headerLength))        # 先占位，帧写完再回填

$offsets = @()
$lengths = @()
foreach ($size in $sizes) {
    $offsets += $ms.Length
    $frame = New-IconFrame -size $size
    $lengths += (Write-IcoImage -bmp $frame -w $w)
    $frame.Dispose()
}

[void]$ms.Seek(0, [System.IO.SeekOrigin]::Begin)
$h = New-Object System.IO.BinaryWriter $ms
$h.Write([uint16]0)
$h.Write([uint16]1)
$h.Write([uint16]$sizes.Count)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $h.Write([byte]$sizes[$i])
    $h.Write([byte]$sizes[$i])
    $h.Write([byte]0)
    $h.Write([byte]0)
    $h.Write([uint16]1)
    $h.Write([uint16]32)
    $h.Write([uint32]$lengths[$i])
    $h.Write([uint32]$offsets[$i])
}
$h.Flush()

[System.IO.File]::WriteAllBytes($target, $ms.ToArray())
$w.Dispose(); $ms.Dispose(); $h.Dispose()

$probe = New-Object System.Drawing.Icon ($target, 32, 32)
Write-Host ("icon written: {0} ({1} bytes, GDI+ probe {2}x{3})" -f $target, (Get-Item $target).Length, $probe.Width, $probe.Height)
$probe.Dispose()

# 1:1 preview on mid gray, so the asset can be eyeballed at real tray size before it ships
$previewPath = Join-Path $assets 'tray-preview.png'
$canvas = New-Object System.Drawing.Bitmap (192, 64, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$cg = [System.Drawing.Graphics]::FromImage($canvas)
$cg.Clear([System.Drawing.Color]::FromArgb(255, 128, 128, 128))
$i16 = New-Object System.Drawing.Icon ($target, 16, 16)
$i32 = New-Object System.Drawing.Icon ($target, 32, 32)
$i48 = New-Object System.Drawing.Icon ($target, 48, 48)
$cg.DrawIcon($i16, 12, 24)
$cg.DrawIcon($i32, 44, 16)
$cg.DrawIcon($i48, 92, 8)
$cg.Dispose()
$canvas.Save($previewPath, [System.Drawing.Imaging.ImageFormat]::Png)
$i16.Dispose(); $i32.Dispose(); $i48.Dispose(); $canvas.Dispose()
Write-Host ("preview written: {0}" -f $previewPath)
