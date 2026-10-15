# 反证：客户端"找正在运行的实例"如果只按窗口标题匹配，任何外部程序只要起一个同名标题的窗口就会被当成我们。
# 后果不是难看，是 --exit 把 WM_APP_QUIT 投给陌生窗口（用户会看到"已请求退出"但真实例还在跑），
# --status 也会把陌生窗口的返回值当成诊断。
# 做法：真实例在跑 + 另起一个子 powershell 进程，建一个"标题相同、窗口类不同"的可见顶层窗口；
# 新窗口压在 z 序最前面，所以只按标题找一定先撞上它。然后看 --status 报的 pid、--exit 退掉的是谁。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;

public static class WinFind {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder sb, int max);

    // 只按标题找第一个命中的顶层窗口（FindWindowEx 按 z 序从前往后扫）。
    public static string FirstByTitle(string title) {
        IntPtr h = FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, title);
        if (h == IntPtr.Zero) return "none";
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        System.Text.StringBuilder sb = new System.Text.StringBuilder(128);
        int len = GetClassNameW(h, sb, sb.Capacity);
        return "hwnd=" + h.ToString() + " pid=" + pid + " class=" + sb.ToString(0, len);
    }

    public static uint FirstByTitlePid(string title) {
        IntPtr h = FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, title);
        if (h == IntPtr.Zero) return 0;
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return pid;
    }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

function Invoke-Exe([string[]]$arguments) {
    $outFile = Join-Path $env:TEMP ("decoy-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $errFile = Join-Path $env:TEMP ("decoy-err-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath "$PWD\dist\DesktopIconToggle.exe" -ArgumentList $arguments `
        -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $p.WaitForExit()
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    if (Test-Path $errFile) { $text += (Get-Content $errFile -Raw) }
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

# 诱饵窗口用一个独立 powershell 进程来承载：WinForms 的 Form + Application.Run 自带消息循环，
# 比手写 CreateWindowEx 可靠；类名是 WindowsForms10_...，和我们的类名不同但标题完全相同。
$decoyScript = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f = New-Object Windows.Forms.Form
$f.Text = 'DesktopIconToggle.Ipc.v1'
$f.FormBorderStyle = 'None'
$f.ShowInTaskbar = $false
$f.StartPosition = 'Manual'
$f.Location = New-Object System.Drawing.Point(-31000, -31000)
$f.Size = New-Object System.Drawing.Size(2, 2)
$f.TopLevel = $true
$f.Show()
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
$f.Close()
'@
$decoyFile = Join-Path $env:TEMP ("decoy-window-" + [Guid]::NewGuid().ToString("N") + ".ps1")
Set-Content -Path $decoyFile -Value $decoyScript -Encoding UTF8

$title = "DesktopIconToggle.Ipc.v1"
$fails = @()

Write-Host "== 准备：起真实例 =="
$null = Invoke-Exe @('--exit')          # 先清场
Start-Process "$PWD\dist\DesktopIconToggle.exe"
Start-Sleep -Milliseconds 900
$real = @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue)
if ($real.Count -ne 1) { throw "真实例没起来（count=$($real.Count)）" }
$realPid = $real[0].Id
Write-Host "  真实例 pid = $realPid"

Write-Host "== 准备：起同名标题的诱饵进程 =="
$decoy = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $decoyFile) -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 3500
Write-Host ("  诱饵 pid = {0}，进程存活 = {1}" -f $decoy.Id, (-not $decoy.HasExited))
Write-Host ("  只按标题找到的第一个窗口 -> {0}" -f [WinFind]::FirstByTitle($title))
$hitPid = [WinFind]::FirstByTitlePid($title)
if ($hitPid -ne $decoy.Id) {
    Write-Host "  注意：标题搜索第一个命中的不是诱饵，反证区分度会变弱（断言仍照跑）" -ForegroundColor Yellow
}

Write-Host "`n== 断言 1：--status 报的必须是真实例的 pid =="
$status = (Invoke-Exe @('--status')).Text
$status | Out-String -Stream | ForEach-Object { Write-Host "  $_" }
$m = [regex]::Match($status, 'pid=(\d+)')
if (-not $m.Success) { $fails += "--status 里没有 pid 字段" }
else {
    $reported = [int]$m.Groups[1].Value
    if ($reported -eq $decoy.Id) { $fails += "--status 把诱饵窗口当成了实例（pid=$reported）" }
    if ($reported -ne $realPid) { $fails += "--status pid=$reported != 真实例 $realPid" }
    Write-Host "  报告 pid = $reported / 真实例 = $realPid / 诱饵 = $($decoy.Id)"
}
# 诱饵的窗口过程对 WM_APP 只会返回 0，所以一旦 ping 发错对象，flags 必然全 0。
if ($status -notmatch 'hook_set=1') { $fails += "--status 的 flags 全 0：ping 发给了不该发的窗口" }

Write-Host "`n== 断言 2：--exit 退掉的是真实例，诱饵必须还活着 =="
$null = Invoke-Exe @('--exit')
Start-Sleep -Milliseconds 1500
$decoy.Refresh()
$survived = @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count
Write-Host ("  真实例剩余 = {0}，诱饵存活 = {1}" -f $survived, (-not $decoy.HasExited))
if ($survived -ne 0) { $fails += "--exit 之后真实例还在：退出指令发给了诱饵" }
if ($decoy.HasExited) { $fails += "诱饵进程被我们的 --exit 弄退了：WM_APP_QUIT 发到了陌生窗口" }

Write-Host "`n== 收尾 =="
# 诱饵是本次测试自己生的子进程，超时 120s 也会自己退；这里显式收掉，不留尾巴。
if (-not $decoy.HasExited) { Stop-Process -Id $decoy.Id -Force -ErrorAction SilentlyContinue }
Remove-Item $decoyFile -ErrorAction SilentlyContinue
$null = Invoke-Exe @('--show')

Write-Host ""
if ($fails.Count -eq 0) {
    Write-Host "VERDICT: PASS - 客户端按类名+标题找实例：诱饵既没被当成实例，也没被误退" -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "  FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
