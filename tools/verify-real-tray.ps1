# 真实托盘图标验收：用 UIA 定位图标 → 真实左键双击（应切换图标）→ 真实右键（应弹菜单且不自杀）→ 截图 → Esc 收起。
# 前提：托盘图标已经从 Win11 的"隐藏图标"抽屉拖到可见区。会移动你的鼠标。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase, System.Windows.Forms, System.Drawing

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class Z {
    [StructLayout(LayoutKind.Sequential)] struct INPUT {
        public uint type; public uint pad; public int dx; public int dy;
        public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra;
    }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int cb);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte s, uint f, IntPtr e);

    static INPUT Mk(uint f) { INPUT i = new INPUT(); i.type = 0; i.dwFlags = f; return i; }

    public static int RightClick(int x, int y) {
        SetCursorPos(x, y); Thread.Sleep(250);
        INPUT[] a = new INPUT[] { Mk(0x0008), Mk(0x0010) };
        return (int)SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }

    /// 两次独立的按下+抬起，中间 60ms：一次批量塞 4 个事件会被合并，配不出双击
    public static int LeftDoubleClick(int x, int y) {
        SetCursorPos(x, y); Thread.Sleep(250);
        INPUT[] first = new INPUT[] { Mk(0x0002), Mk(0x0004) };
        int a = (int)SendInput(2, first, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(60);
        INPUT[] second = new INPUT[] { Mk(0x0002), Mk(0x0004) };
        int b = (int)SendInput(2, second, Marshal.SizeOf(typeof(INPUT)));
        return a + b;
    }

    public static void Esc() { keybd_event(0x1B, 0, 0, IntPtr.Zero); keybd_event(0x1B, 0, 2, IntPtr.Zero); }
}
'@

function Find-TrayIcon {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $c)
    foreach ($b in $all) { if ($b.Current.Name -like '*桌面图标开关*') { return $b } }
    return $null
}

function Icons {
    $o = Join-Path $env:TEMP ("i-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--status" -NoNewWindow -Wait -RedirectStandardOutput $o
    $t = [IO.File]::ReadAllText($o); Remove-Item $o -ErrorAction SilentlyContinue
    ([regex]::Match($t, 'icons\s+= (\w+)')).Groups[1].Value
}
function Diag {
    $o = Join-Path $env:TEMP ("d-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--status" -NoNewWindow -Wait -RedirectStandardOutput $o
    $t = [IO.File]::ReadAllText($o); Remove-Item $o -ErrorAction SilentlyContinue
    ([regex]::Match($t, 'diag\s+= (.*)')).Groups[1].Value.Trim()
}
function Alive { @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count }

function Shot([string]$name, [int]$cx, [int]$cy) {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap ($b.Width, $b.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size); $g.Dispose()
    $bmp.Save((Join-Path $shots "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $w = 460; $h = 340
    $x = [Math]::Max(0, [Math]::Min($cx - 30, $b.Width - $w))
    $y = [Math]::Max(0, [Math]::Min($cy - $h - 6, $b.Height - $h))
    $crop = New-Object System.Drawing.Bitmap $w, $h
    $cg = [System.Drawing.Graphics]::FromImage($crop)
    $cg.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0, 0, $w, $h),
                        (New-Object System.Drawing.Rectangle $x, $y, $w, $h), [System.Drawing.GraphicsUnit]::Pixel)
    $cg.Dispose(); $crop.Save((Join-Path $shots "crop-$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $crop.Dispose(); $bmp.Dispose()
    return "crop-$name.png (取自 $x,$y)"
}

$shots = Join-Path (Get-Location) 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份自己退出 —— 于是活动与托盘注册都发生在
# 那一份身上，而每一次 --status 读回来的 diag 行却是空的（字段"凭空没了"）。先按 Path 用它自己的 exe 退干净。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $eo = Join-Path $env:TEMP ("rt-exit-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process $livePath -ArgumentList '--exit' -NoNewWindow -Wait -RedirectStandardOutput $eo -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $eo, "$eo.err" -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 800
if ((Alive) -eq 0) { Start-Process "dist\DesktopIconToggle.exe"; Start-Sleep -Seconds 2 }
"实例=$(Alive)  icons=$(Icons)  $(Diag)"

$icon = Find-TrayIcon
if ($null -eq $icon) { "UIA 没找到托盘图标（名字里没有『桌面图标开关』）。当前可见托盘按钮："
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $c)) {
        $r = $b.Current.BoundingRectangle
        if ($r.Y -gt 1100 -and $r.X -gt 1500) { "  [$($b.Current.Name -replace "`r|`n','")] @ $([Math]::Round($r.X)),$([Math]::Round($r.Y))" }
    }
    exit 1 }

$r = $icon.Current.BoundingRectangle
$cx = [Math]::Round($r.X + $r.Width / 2); $cy = [Math]::Round($r.Y + $r.Height / 2)
"找到图标：名字=[$($icon.Current.Name)] 中心=($cx,$cy)"

# 1) 真实左键双击图标 -> 应切换
$i0 = Icons
$inj = [Z]::LeftDoubleClick($cx, $cy)
Start-Sleep -Milliseconds 900
$i1 = Icons
"左键双击图标：注入事件=$inj  icons $i0 -> $i1  实例=$(Alive)  $(Diag)"

# 2) 再双击一次 -> 应切回
$inj2 = [Z]::LeftDoubleClick($cx, $cy)
Start-Sleep -Milliseconds 900
$i2 = Icons
"再双击：注入事件=$inj2  icons $i1 -> $i2  实例=$(Alive)  $(Diag)"

# 3) 真实右键 -> 菜单应出现且进程存活
$null = [Z]::RightClick($cx, $cy)
Start-Sleep -Milliseconds 900
$shot = Shot "real-tray-menu" $cx $cy
"右键：实例=$(Alive)  截图 $shot  $(Diag)"
Start-Sleep -Milliseconds 700
[Z]::Esc()
Start-Sleep -Milliseconds 500
"Esc 之后：实例=$(Alive)  icons=$(Icons)"

$pass = ($i0 -ne $i1) -and ($i1 -ne $i2) -and ((Alive) -eq 1)
"结论：$(if ($pass) { 'PASS —— 托盘左键双击可切换、右键不再自杀' } else { 'FAIL —— 见上面逐行数据' })"
# 打印了 FAIL 就必须给非零退出码，否则自动化把这轮当成成功（原先结尾没有 exit）。
if ($pass) { exit 0 }
exit 1
