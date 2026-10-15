# 桌面图标开关 DesktopIconToggle —— 安装脚本（免依赖、不提权、不装服务）
# 做什么：把 exe 装进"只有你自己能写"的目录，用那一份登记开机自启，然后起一份常驻实例并反证它真的在跑。
# 为什么不是随手放哪个目录都行：如果 exe 放在同用户可写的路径（例如 D:\ 根被授了 Authenticated Users:(M)），
# 而 Run 键又指着它，任何同用户进程都能就地把它换成别的程序，让它在开机时以你的身份运行。
param(
    [string]$TargetDir = (Join-Path $env:LOCALAPPDATA 'DesktopIconToggle'),
    [switch]$NoAutostart = $false,
    [switch]$NoStart = $false
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'DesktopIconToggle.exe'
if (-not (Test-Path $src)) { throw "安装包里没有 DesktopIconToggle.exe：$src" }
$dst = Join-Path $TargetDir 'DesktopIconToggle.exe'

function Invoke-Exe([string]$path, [string[]]$arguments) {
    $o = Join-Path $env:TEMP ("inst-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError "$o.err"
    $t = ''
    if (Test-Path $o) { $t += (Get-Content $o -Raw) }
    if (Test-Path "$o.err") { $t += (Get-Content "$o.err" -Raw) }
    Remove-Item $o, "$o.err" -ErrorAction SilentlyContinue
    return $t.Trim()
}

Write-Host "== 1. 复制并核对字节 =="
New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
if (Test-Path $dst) {
    $h0 = (Get-FileHash $dst -Algorithm SHA256).Hash
    $h1 = (Get-FileHash $src -Algorithm SHA256).Hash
    if ($h0 -eq $h1) { Write-Host "   已存在且字节一致，跳过复制" }
    else {
        # 正在运行的 exe 会被系统锁住，覆盖会失败：先按它自己的路径把它退掉。
        foreach ($live in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
            Write-Host ("   覆盖前先退掉在跑的实例：{0}" -f $live)
            $null = Invoke-Exe $live @('--exit')
        }
        Start-Sleep -Milliseconds 800
        Copy-Item $src $dst -Force
    }
} else { Copy-Item $src $dst -Force }
$hs = (Get-FileHash $src -Algorithm SHA256).Hash
$hd = (Get-FileHash $dst -Algorithm SHA256).Hash
Write-Host ("   源   SHA256 = {0}" -f $hs)
Write-Host ("   目标 SHA256 = {0}   一致 = {1}" -f $hd, ($hs -eq $hd))
if ($hs -ne $hd) { throw "复制后字节不一致" }

# 卸载脚本必须跟着一起装进去：install.ps1 结尾会提示"去安装目录跑 uninstall.ps1"，
# 只提示不复制 = 那条提示是假的。
foreach ($extra in @('uninstall.ps1', '使用说明.txt')) {
    $srcExtra = Join-Path $PSScriptRoot $extra
    if (Test-Path $srcExtra) { Copy-Item $srcExtra (Join-Path $TargetDir $extra) -Force }
}

if (-not $NoAutostart) {
    Write-Host "`n== 2. 登记开机自启（HKCU\...\Run，不需要管理员）=="
    $null = Invoke-Exe $dst @('--autostart')
    $read = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -EA SilentlyContinue).DesktopIconToggle
    Write-Host ("   独立回读 Run 键 = {0}" -f $read)
    if ($read -notlike ("*" + $dst + "*")) { throw "Run 键没指向刚装的这一份" }
} else { Write-Host "`n== 2. 跳过自启登记（-NoAutostart）==" }

if (-not $NoStart) {
    Write-Host "`n== 3. 起一份常驻实例并反证它在跑 =="
    foreach ($live in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
        if ($live -ne $dst) { Write-Host ("   先退掉另一路径的实例：{0}" -f $live); $null = Invoke-Exe $live @('--exit') }
    }
    Start-Process $dst | Out-Null
    Start-Sleep -Seconds 2
    $st = Invoke-Exe $dst @('--status')
    $st -split "`n" | Select-String 'instance|icons|autostart|flags' | ForEach-Object { "   " + $_.ToString().Trim() }
    if ($st -notmatch 'instance\s+= 运行中') { throw "装完了但实例没起来" }
}

Write-Host "`n完成。用法：双击桌面空白处 = 显示/隐藏桌面图标；右下角托盘图标右键 = 菜单。"
Write-Host ("卸载：powershell -File " + (Join-Path $TargetDir 'uninstall.ps1'))
