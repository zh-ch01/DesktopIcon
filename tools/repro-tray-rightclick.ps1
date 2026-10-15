# 复现并观察：右键托盘图标时，菜单到底弹成什么样、哪一项在光标底下、进程会不会退。
# 会点开 Win11 的"隐藏图标"抽屉、右键我们的托盘图标、然后按 Esc 收起。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase, System.Windows.Forms

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;

public static class T {
    [StructLayout(LayoutKind.Sequential)] struct INPUT {
        public uint type; public uint pad; public int dx; public int dy;
        public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra;
    }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int cb);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }

    static INPUT Make(uint flags) { INPUT i = new INPUT(); i.type = 0; i.dwFlags = flags; return i; }

    public static int Click(int x, int y, string button) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(250);
        uint down = button == "right" ? 0x0008u : 0x0002u;
        uint up   = button == "right" ? 0x0010u : 0x0004u;
        INPUT[] a = new INPUT[] { Make(down), Make(up) };
        int n = (int)SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
        return n;
    }

    public static void MoveOnly(int x, int y) { SetCursorPos(x, y); }

    public static void Esc() {
        // VK_ESCAPE = 0x1B，用 keybd_event 关掉弹出菜单
        keybd_event(0x1B, 0, 0, IntPtr.Zero);
        keybd_event(0x1B, 0, 2, IntPtr.Zero);
    }
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    public static P Cursor() { P p; GetCursorPos(out p); return p; }
}
'@

function Get-TrayButton([string]$match) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    foreach ($b in $all) {
        if ($b.Current.Name -like $match) { return $b }
    }
    return $null
}

function Get-MenuItems {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)
    $items = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    $out = @()
    foreach ($i in $items) {
        $r = $i.Current.BoundingRectangle
        if ($r.Width -gt 0) {
            $out += [pscustomobject]@{
                名称 = $i.Current.Name
                左上 = "$([Math]::Round($r.X)),$([Math]::Round($r.Y))"
                中心 = "$([Math]::Round($r.X + $r.Width/2)),$([Math]::Round($r.Y + $r.Height/2))"
                高 = [Math]::Round($r.Height)
            }
        }
    }
    return $out
}

$exe = "dist\DesktopIconToggle.exe"
Get-Process DesktopIconToggle -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600
Start-Process $exe
Start-Sleep -Seconds 2
"实例 = $(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)"

# 1) 点开 Win11 的隐藏图标抽屉
$chevron = Get-TrayButton "*隐藏的图标*"
if ($null -eq $chevron) { "找不到『显示隐藏的图标』按钮，停止"; exit 1 }
$cr = $chevron.Current.BoundingRectangle
$cx = [Math]::Round($cr.X + $cr.Width / 2); $cy = [Math]::Round($cr.Y + $cr.Height / 2)
"抽屉按钮在 ($cx,$cy)，点开"
$null = [T]::Click($cx, $cy, "left")
Start-Sleep -Milliseconds 900

# 2) 找我们的托盘图标
$mine = Get-TrayButton "*桌面图标开关*"
if ($null -eq $mine) { "抽屉里没找到我们的图标（可能已经在外面）"; $mine = Get-TrayButton "*图标开关*" }
if ($null -eq $mine) { "找不到，停止"; exit 1 }
$mr = $mine.Current.BoundingRectangle
$mx = [Math]::Round($mr.X + $mr.Width / 2); $my = [Math]::Round($mr.Y + $mr.Height / 2)
"我们的图标: 名字=[$($mine.Current.Name)] 中心=($mx,$my)"

# 3) 右键它，然后立刻把弹出的菜单项列出来
$null = [T]::Click($mx, $my, "right")
Start-Sleep -Milliseconds 700
$alive = @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count
$cur = [T]::Cursor()
"右键后：进程数=$alive  光标=($($cur.X),$($cur.Y))"
$items = Get-MenuItems
if ($items.Count -eq 0) { "  (没有枚举到任何菜单项)" } else {
    $items | ForEach-Object { "  项: [$($_.名称)] 左上=$($_.左上) 中心=$($_.中心) 高=$($_.高)" }
    $hit = $items | Where-Object { $_.名称 -ne '' } | ForEach-Object {
        $p = $_.中心 -split ','
        if ([int]$p[0] -le $cur.X -and $cur.X -le ([int]$p[0] + 200) -and [int]$p[1] -le $cur.Y -and $cur.Y -le ([int]$p[1] + [int]($_.高)) ) { $_ }
    }
    "  光标正压在哪一项上: " + $(if ($hit) { "[$($hit.名称)]" } else { "(没有正好压住的)" })
}

Start-Sleep -Milliseconds 600
[T]::Esc()
Start-Sleep -Milliseconds 500
$alive2 = @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count
"按 Esc 之后：进程数=$alive2"
$icons = (& $exe --status) | Out-String
($icons -split "`r?`n" | Where-Object { $_ -match 'icons|diag' })
