# 重启前的"布防"：把自启动打开、把桌面置成指定状态、并记下期望值，供重启后 tools\verify-real-boot.ps1 比对。
# 这是 TEST-REPORT §4 里唯一没实测过的路径（真机重启 + explorer 冷启动）的前半步。
#
# 跑法（默认目标状态 = 隐藏图标，因为这正是产品要保住的那个状态）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\arm-for-reboot.ps1
#   然后你手动重启电脑，回到桌面后跑 tools\verify-real-boot.ps1
# 想改回"重启后应当显示图标"：加 -Want visible
param([ValidateSet('hidden', 'visible')][string]$Want = 'hidden')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot     # $PSScriptRoot 是 tools\，期望值文件要落在工程根目录
Set-Location $root

function Invoke-Exe([string[]]$arguments, [string]$path) {
    if (-not $path) { $path = "$PWD\dist\DesktopIconToggle.exe" }
    $outFile = Join-Path $env:TEMP ("arm-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments `
        -PassThru -Wait -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    if (Test-Path "$outFile.err") { $text += (Get-Content "$outFile.err" -Raw) }
    Remove-Item $outFile, "$outFile.err" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

Write-Host "== 1. 打开开机自启动 =="
# 自启登记的就是"开机即执行的那条路径"。dist\ 在工程目录下、同用户可随时改写 —— 那正是 deploy-local.ps1
# 要把执行体搬到 %LOCALAPPDATA% 去规避的风险，所以不能随手从 dist 发 --autostart 把 Run 键改回去。
# 日常那份在就用它登记；确实没装才退回 dist，并把这条风险响亮地打出来。
$distExe = "$PWD\dist\DesktopIconToggle.exe"
$localExe = Join-Path $env:LOCALAPPDATA 'DesktopIconToggle\DesktopIconToggle.exe'
$autostartExe = $distExe
if (Test-Path $localExe) {
    $autostartExe = $localExe
    Write-Host ("   用日常安装那一份登记自启（避开可被同用户改写的 dist 路径）：{0}" -f $autostartExe)
} else {
    Write-Host ("   !! 警告：没找到 {0} ，本次只能用 {1} 登记自启 —— 这条 Run 键指向的是同用户可改写的路径，" -f $localExe, $distExe) -ForegroundColor Yellow
    Write-Host "   !! 等于把「开机自动执行一个可被同用户替换的 exe」留在机器上。要消掉：先跑 tools\deploy-local.ps1 再重新布防。" -ForegroundColor Yellow
}
$on = Invoke-Exe @('--autostart') -path $autostartExe
Write-Host "   $($on.Text)"
$run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name DesktopIconToggle -ErrorAction SilentlyContinue
if (-not $run) { throw "注册表回读不到 Run 键值，不能继续（自启没开成）" }
Write-Host ("   独立回读 Run 键 = {0}" -f $run.DesktopIconToggle)

Write-Host "`n== 2. 起实例并置成目标状态：icons=$Want =="
if (@(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count -eq 0) {
    Start-Process "$PWD\dist\DesktopIconToggle.exe"
    Start-Sleep -Milliseconds 900
}
$flag = if ($Want -eq 'hidden') { '--hide' } else { '--show' }
Write-Host ("   {0} -> {1}" -f $flag, (Invoke-Exe @($flag)).Text)

# 关键：让"关机前应记的状态"确实是被 explorer 侧真实可见性决定的，所以这里用独立探针复查一遍。
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
public static class ArmProbe {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    public static string State() {
        IntPtr progman = FindWindowW("Progman", null);
        IntPtr view = progman == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (view == IntPtr.Zero) {
            IntPtr w = IntPtr.Zero;
            while (true) {
                w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
                if (w == IntPtr.Zero) break;
                view = FindWindowExW(w, IntPtr.Zero, "SHELLDLL_DefView", null);
                if (view != IntPtr.Zero) break;
            }
        }
        if (view == IntPtr.Zero) return "no-defview";
        IntPtr lv = FindWindowExW(view, IntPtr.Zero, "SysListView32", null);
        if (lv == IntPtr.Zero) return "no-iconlayer";
        return IsWindowVisible(lv) ? "visible" : "hidden";
    }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

$actual = [ArmProbe]::State()
Write-Host ("   独立探针复查 = {0}（目标 {1}）" -f $actual, $Want)
if ($actual -ne $Want) { throw "置状态没落地（探针读到 $actual），不该在此时重启，否则期望值是假的" }

Write-Host "`n== 3. 记下期望值供重启后比对 =="
$expectFile = Join-Path $root "boot-expect.txt"   # 落在工程根目录，和 verify-real-boot.ps1 同一个路径
$Content = @($Want, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), ('run=' + $run.DesktopIconToggle))
Set-Content -Path $expectFile -Value $Content -Encoding ASCII
Write-Host ("   写入 {0}" -f $expectFile)
Get-Content $expectFile | ForEach-Object { Write-Host "   | $_" }

Write-Host "`n== 4. 实例留在运行状态（模拟'平常就在用'），不要手动退出 =="
Write-Host ("   当前实例数 = {0}" -f @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count)

# verify-real-boot.ps1 只在"距开机 30 分钟内"才给 PASS，超过就退成 INCONCLUSIVE。
# 所以布防完就把窗口截止时刻算给他，别等等完了才发现白跑一趟。
$deadline = (Get-Date).AddMinutes(30)
Write-Host ("`n   验证窗口截止：{0}（布防于 {1}）—— 请在这之前重启，超过就只能得到 INCONCLUSIVE" -f `
    $deadline.ToString('HH:mm:ss'), (Get-Date).ToString('HH:mm:ss'))

Write-Host @"

布防完成。接下来由你做两件事：
  1) 手动重启电脑（我不碰你的机器）。
  2) 回到桌面后跑：powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-real-boot.ps1
     它会用独立探针核对：图标是否仍是 $actual、自启动有没有把实例拉起来、壁纸有没有被带走。
想撤销布防（关掉自启并恢复显示图标）：
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\disarm-for-reboot.ps1
"@
