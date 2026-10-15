# 发布 + 占用/功能实测。跑法：powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ShellProbe {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);

    /// 直接从 explorer 的窗口树上读图标可见性，不经过被测程序，作为反证用。
    public static string IconState() {
        IntPtr progman = FindWindowW("Progman", null);
        IntPtr defView = progman == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (defView == IntPtr.Zero) {
            IntPtr w = IntPtr.Zero;
            while (true) {
                w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
                if (w == IntPtr.Zero) break;
                defView = FindWindowExW(w, IntPtr.Zero, "SHELLDLL_DefView", null);
                if (defView != IntPtr.Zero) break;
            }
        }
        if (defView == IntPtr.Zero) return "no-defview";
        IntPtr list = FindWindowExW(defView, IntPtr.Zero, "SysListView32", null);
        if (list == IntPtr.Zero) return "no-iconlayer";
        return IsWindowVisible(list) ? "visible" : "hidden";
    }

    public static IntPtr FindIpcWindow() {
        // 和 IpcWindow.FindOther 同口径：类名 + 标题一起匹配，避免把别人的同名标题窗口当成我们。
        return FindWindowExW(IntPtr.Zero, IntPtr.Zero, "DesktopIconToggle.MessageWindow.v1", "DesktopIconToggle.Ipc.v1");
    }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

function Stop-Instance {
    # 用 --exit 正常退出：Stop-Process 强杀会让 explorer 留下幽灵托盘图标（点不到的空位），
    # 而且会污染后续所有基于托盘的测试。强杀只作为兜底。
    # 场里跑的可能是另一条路径的那一份（日常副本在 %LOCALAPPDATA%）。从 dist 发 --exit 认不出它（F28 属主校验），
    # 而互斥体又会让我们随后起的 dist 实例自己退出 —— 于是"冷启动耗时"量到的是超时、占用采样量到的是别人。
    # 所以先按进程的 Path 用**它自己的 exe** 退干净，再退 dist 这份。
    foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
        $lo = Join-Path $env:TEMP ("x-live-" + [Guid]::NewGuid().ToString("N") + ".txt")
        Start-Process $livePath -ArgumentList "--exit" -NoNewWindow -Wait -RedirectStandardOutput $lo -ErrorAction SilentlyContinue
        Remove-Item $lo, "$lo.err" -ErrorAction SilentlyContinue
    }
    if (Test-Path "dist\DesktopIconToggle.exe") {
        $o = Join-Path $env:TEMP ("x-" + [Guid]::NewGuid().ToString("N") + ".txt")
        Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--exit" -NoNewWindow -Wait -RedirectStandardOutput $o -ErrorAction SilentlyContinue
        Remove-Item $o -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline -and @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -gt 0) { Start-Sleep -Milliseconds 150 }
    if (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -gt 0) { Get-Process DesktopIconToggle -EA SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
}

function Step($name, $body) {
    Write-Host "---- $name"
    & $body
}

function Invoke-Exe([string[]]$arguments) {
    $outFile = Join-Path $env:TEMP ("dit-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $errFile = Join-Path $env:TEMP ("dit-err-" + [Guid]::NewGuid().ToString("N") + ".txt")
    # -Wait 必须和 -PassThru 一起给：只 WaitForExit() 的话 $p.ExitCode 会是空的，
    # 而"退出码"正是"未知参数被拒/失败路径有码"这两条判据的证据。
    $p = Start-Process -FilePath "$root\dist\DesktopIconToggle.exe" -ArgumentList $arguments `
        -PassThru -Wait -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    if (Test-Path $errFile) { $text += (Get-Content $errFile -Raw) }
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

Write-Host "== 1. 发布 ==" -ForegroundColor Cyan
# 先停掉正在跑的实例：它在时 dist\DesktopIconToggle.exe 被锁住，删不掉也写不进。
Stop-Instance
if (Test-Path "$root\dist") { Remove-Item "$root\dist" -Recurse -Force }
dotnet publish $root\DesktopIconToggle.csproj -c Release -r win-x64 --self-contained false `
    -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=false -p:UseAppHost=true -v q --nologo `
    -o $root\dist | Select-Object -Last 3
$exe = Get-Item "$root\dist\DesktopIconToggle.exe"
Write-Host ("产物 {0}  磁盘 {1:N0} 字节" -f $exe.FullName, $exe.Length)
Get-ChildItem "$root\dist" | ForEach-Object { Write-Host ("  {0}  {1:N0} B" -f $_.Name, $_.Length) }

Write-Host "`n== 2. 启动耗时 ==" -ForegroundColor Cyan
Stop-Instance
$baseline = [ShellProbe]::IconState()
Write-Host "启动前图标状态(独立探测) = $baseline"

$sw = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $exe.FullName -PassThru
while ($sw.ElapsedMilliseconds -lt 5000) {
    if ([ShellProbe]::FindIpcWindow() -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 20
}
$sw.Stop()
Write-Host ("冷启动到 IPC 窗口就绪: {0} ms (pid={1})" -f $sw.ElapsedMilliseconds, $proc.Id)

Write-Host "`n== 3. 占用采样（0s / 15s / 30s 空闲）==" -ForegroundColor Cyan
$samples = @()
for ($i = 0; $i -lt 3; $i++) {
    if ($i -gt 0) { Start-Sleep -Seconds 15 }
    $proc.Refresh()
    $samples += [pscustomobject]@{
        t      = "$($i * 15)s"
        wsMB   = [Math]::Round($proc.WorkingSet64 / 1MB, 1)
        privMB = [Math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
        cpuMs  = [Math]::Round($proc.TotalProcessorTime.TotalMilliseconds, 0)
    }
}
$samples | Format-Table -AutoSize | Out-String | Write-Host
$cpuTotalMs = ($samples[-1].cpuMs - $samples[0].cpuMs)
Write-Host ("30s 空闲累计 CPU = {0} ms → 平均 {1:N3}% 单核" -f $cpuTotalMs, ($cpuTotalMs / 30000 * 100))

Write-Host "`n== 4. 功能：命令行切换（含独立反证）==" -ForegroundColor Cyan
$first = Invoke-Exe @('--toggle')
Write-Host ("--toggle #1 -> exit={0} out='{1}' 反证={2}" -f $first.Code, $first.Text, [ShellProbe]::IconState())
$second = Invoke-Exe @('--toggle')
Write-Host ("--toggle #2 -> exit={0} out='{1}' 反证={2}" -f $second.Code, $second.Text, [ShellProbe]::IconState())
Write-Host ("回到基线? {0}" -f ([ShellProbe]::IconState() -eq $baseline))
Write-Host "--hide / --show:"
Invoke-Exe @('--hide') | ForEach-Object { Write-Host ("  --hide  -> {0} 反证={1}" -f $_.Text, [ShellProbe]::IconState()) }
Invoke-Exe @('--show') | ForEach-Object { Write-Host ("  --show  -> {0} 反证={1}" -f $_.Text, [ShellProbe]::IconState()) }

Write-Host "`n== 5. 单实例 ==" -ForegroundColor Cyan
$dup = Start-Process -FilePath $exe.FullName -PassThru
$dup.WaitForExit(3000) | Out-Null
Write-Host ("第二个实例 exit={0}（0=识别到已运行并自行退出）存活={1}" -f $dup.ExitCode, (-not $dup.HasExited))
$alive = @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue)
Write-Host ("当前实例数 = {0}" -f $alive.Count)

Write-Host "`n== 6. 开机自启（注册表回读，独立于被测程序）==" -ForegroundColor Cyan
Invoke-Exe @('--autostart') | ForEach-Object { Write-Host ("  --autostart -> {0}" -f $_.Text) }
$run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name DesktopIconToggle -ErrorAction SilentlyContinue
Write-Host ("  注册表值 = {0}" -f $run.DesktopIconToggle)
Invoke-Exe @('--no-autostart') | ForEach-Object { Write-Host ("  --no-autostart -> {0}" -f $_.Text) }
$after = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name DesktopIconToggle -ErrorAction SilentlyContinue
Write-Host ("  删除后注册表值 = {0}" -f ($(if ($after) { $after.DesktopIconToggle } else { '(已清除)' })))

Write-Host "`n== 7. --status ==" -ForegroundColor Cyan
(Invoke-Exe @('--status')).Text -split "`n" | ForEach-Object { Write-Host "  $_" }

Write-Host "`n== 8. 收尾 ==" -ForegroundColor Cyan
Invoke-Exe @('--exit') | ForEach-Object { Write-Host ("  --exit -> {0}" -f $_.Text) }
Start-Sleep -Milliseconds 500
Write-Host ("  剩余实例数 = {0}" -f @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count)
Write-Host ("  图标最终状态 = {0} (基线 {1})" -f [ShellProbe]::IconState(), $baseline)
