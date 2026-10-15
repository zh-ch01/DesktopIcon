# 换图标后的验收：重新发布 → 重启实例 → 截托盘区域（放大 4 倍便于看 16px 细节）→ 复跑两套实测。
function Stop-Instance {
    # 用 --exit 正常退出：Stop-Process 强杀会让 explorer 留下幽灵托盘图标（点不到的空位），
    # 而且会污染后续所有基于托盘的测试。强杀只作为兜底。
    $o = Join-Path $env:TEMP ("x-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--exit" -NoNewWindow -Wait -RedirectStandardOutput $o -ErrorAction SilentlyContinue
    Remove-Item $o -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline -and @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -gt 0) { Start-Sleep -Milliseconds 150 }
    if (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -gt 0) { Get-Process DesktopIconToggle -EA SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
}

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes, WindowsBase

# 先杀掉实例再发布：exe 正在运行时 publish 覆盖不了它，会静默留下旧产物
Stop-Instance

dotnet publish DesktopIconToggle.csproj -c Release -r win-x64 --self-contained false `
    -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=false -v q --nologo -o dist 2>&1 |
    Select-String -Pattern 'error|MSB' | ForEach-Object { "发布报错: $_" }
"产物 = $((Get-Item 'dist\DesktopIconToggle.exe').Length) 字节  hash=$((Get-FileHash 'dist\DesktopIconToggle.exe' -Algorithm SHA256).Hash.Substring(0,12))"

Start-Process "dist\DesktopIconToggle.exe"
Start-Sleep -Seconds 2

$root = [System.Windows.Automation.AutomationElement]::RootElement
$c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$mine = $null
foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $c)) {
    if ($b.Current.Name -like '*桌面图标开关*') { $mine = $b; break }
}
if ($null -eq $mine) { "UIA 没找到托盘图标"; exit 1 }
$r = $mine.Current.BoundingRectangle
$cx = [Math]::Round($r.X + $r.Width / 2); $cy = [Math]::Round($r.Y + $r.Height / 2)
"图标位置 ($cx,$cy)"

$shots = Join-Path (Get-Location) 'shots'
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap ($b.Width, $b.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, 0, 0, 0, $bmp.Size); $g.Dispose()
$w = 120; $h = 54
$x = [Math]::Max(0, $cx - 60)
$crop = New-Object System.Drawing.Bitmap ($w * 4), ($h * 4)
$cgg = [System.Drawing.Graphics]::FromImage($crop)
$cgg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$cgg.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0, 0, ($w * 4), ($h * 4)),
                     (New-Object System.Drawing.Rectangle $x, 1146, $w, $h), [System.Drawing.GraphicsUnit]::Pixel)
$cgg.Dispose()
$crop.Save((Join-Path $shots 'tray-icon-4x.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$crop.Dispose(); $bmp.Dispose()
"放大截图 = shots\tray-icon-4x.png"
