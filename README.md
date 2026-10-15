# 桌面图标开关 DesktopIconToggle

双击桌面空白处 → 隐藏全部桌面图标；再双击 → 恢复。托盘常驻，可设置开机自启。

- 单文件 `dist\DesktopIconToggle.exe`，**219,889 字节**，框架依赖（机器已装 .NET 8 桌面运行时即可，不需管理员权限）
- 日常那份装在 `%LOCALAPPDATA%\DesktopIconToggle\DesktopIconToggle.exe`（`tools\deploy-local.ps1` 负责搬并同步 Run 键）：`D:\` 根在本机被 ACL 授予了 `Authenticated Users:(M)`，放在那种可写目录里的 exe 又是 Run 键自启 = 任何同用户进程可以就地换成自己的文件让它在开机时以你的身份运行。装到只有你能写的目录，这条链就断了（详见 `TEST-REPORT.md` §9）
- 实测常驻：私有内存 **6.3 – 7.1 MB**（跨运行有 ±0.8 MB 抖动，不挑小的报）、工作集 25.9 – 28.9 MB、空闲 30 秒累计 CPU **0 ms（=0.000% 单核）**、冷启动到可通信 279 – 455 ms。连采 70 分钟：私有内存漂移 **-0.05 MB**、句柄 **-5**、平均 **9.16 ms CPU/分**
- 桌面双击到图标消失 **239 – 306 ms**（含测试脚本自己的 150ms 定位停顿）
- 没有主窗口、没有任务栏项、没有轮询线程；只有一个 0×0 的隐藏顶层窗口（托盘宿主 + 命令行 IPC）+ 一个鼠标低级钩子。空闲期连定时器都没有：全过程只存在两个有限寿命的定时器——开机复原的重试（成功或用尽都拆）和 shell 重启后的托盘连补（补满 3 次即拆），两者共用一条 `WM_TIMER`，按 `wParam` 里的 id 分流
- `--status` 分级自证：钩子是否装上 / 回调是否真被调用过 / 是否配出过双击 / 实际执行过几次 ShowWindow / 有没有因为上一次还没测完而丢弃，例如
  `diag = ups=20 pairs=10 showwindow=10 dropped=0 toggle_failed=0`；再加一行手势结局 `gesture = on_icon=1 not_desktop=2 throttled=0 last=not_desktop`。
  「装上了」和「真的在起作用」是两件事——分开报，才不会像今晚这样被一个状态位骗过去；而"配出了双击却没切换"这一格也必须有名有姓，否则排查只能靠猜。
  注意 `showwindow` 记的是**后台实例自己执行**的次数：用 `--toggle/--hide/--show` 从命令行改不算（那是另一个进程在做）。

## 用法

| 操作 | 结果 |
| --- | --- |
| 双击桌面**空白处** | 隐藏 / 恢复桌面图标 |
| 双击**桌面图标** | 照常启动程序（手势让位，不会被拦截） |
| 托盘图标：左键双击 | 手动切换一次 |
| 托盘图标：右键 | 菜单：隐藏/显示桌面图标 · 开机自启动 · 双击桌面空白处切换 · 接受注入的双击（脚本/远控） · 开机后保持上次状态 · 恢复默认设置 · 退出 |

命令行（可从脚本、快捷键、任务计划调用；不带参数就是启动后台实例）：

```
DesktopIconToggle.exe              后台启动（已有一份在跑就静默退出，不会多开）
DesktopIconToggle.exe --toggle     切换一次（不需要后台实例在场）
DesktopIconToggle.exe --hide / --show
DesktopIconToggle.exe --status     看实例/图标/自启/手势状态
DesktopIconToggle.exe --autostart / --no-autostart
DesktopIconToggle.exe --exit       退出后台实例（图标保持当前状态）
```

三个显示动作本质上就是对 explorer 的图标层 `SysListView32("FolderView")` 做 `ShowWindowAsync`，谁来做结果一样，所以 `--toggle/--hide/--show` **不依赖后台实例**——这也保证了万一你找不到托盘图标，命令行永远是一条退路。

自启动写在 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，值名 `DesktopIconToggle`。exe 换过存放位置后，下次启动会自己把注册表里的旧路径改成当前路径。

**两份 exe 是两个身份。** 日常常驻的那一份在 `%LOCALAPPDATA%\DesktopIconToggle\`，Run 键指的就是它；仓库里的 `dist\` 是构建与回归测试用的同一份字节。因为实例发现要校验"属主 exe 是否同一个文件"（F28），所以在 `dist\` 路径下敲 `--status` 会如实报「未运行」——这不是坏了，而是它不肯把陌生窗口当成我们。要用命令行操纵正在跑的那一份，就调 `%LOCALAPPDATA%\DesktopIconToggle\DesktopIconToggle.exe --status`。
设置项在 `HKCU\Software\DesktopIconToggle`。删掉这个键 = 恢复默认。

**你收起来的图标活得过重启。** 每次真正改变可见性都会记下状态，开机自启时按原样复原（托盘菜单「开机后保持上次状态」可关）。不然自启动就只是"开机后还能双击"，而你要的是"桌面一直是收起来的"。这条已在真机冷启动上实测过：关机前收着 → 开机 37 秒后实例由 Run 键自己起来 → 桌面仍是收着的，壁纸没丢（`TEST-REPORT.md` F22）。

## 设计取舍（为什么是这样做）

**只用 net8.0 + 手写 Win32 P/Invoke，不引 WinForms/WPF，也不拉任何 NuGet 包。**
托盘、菜单、注册表、跨进程命中测试全部是 `user32/shell32/kernel32/advapi32`。少了 `System.Windows.Forms` 整套装配的加载，工作集因此压在 20 MB 级；同时避免"装不上环境"这个风险（本机没有 C/C++ 工具链，只有 .NET 8 SDK 8.0.425）。

**钩子回调里一次堆内存都不分配。** `WH_MOUSE_LL` 回调是全局的、挂在系统输入链上，超时（`LowLevelHooksTimeout`，默认 300 ms）不只是我们被静默摘钩（`hook_set` 照样报 1，骗人），而是全系统鼠标发涩。所以回调只做「消息号比较 + 按偏移直读坐标与注入位 + 几个整数比较 + `PostMessage`」——连 `Marshal.PtrToStructure` 都换成了 `Marshal.ReadInt32(lParam, 0/4/12)`（偏移用 `Marshal.OffsetOf` 标定过），因为每次装箱分配都可能在 300ms 预算里插一次 GC。判定落点、跨进程命中测试全部挪到本进程消息循环里做。空闲时进程完全不消耗 CPU（实测 30 s 累计 0 ms）。切换可见性也刻意用 `ShowWindowAsync` 而不是同步的 `ShowWindow`：同步版会等目标线程处理 show-window 事件，而这个线程装着全局钩子，explorer 一卡就是全系统鼠标发涩。

**退出只认显式指令。** 隐藏窗口的 `WM_CLOSE` 一律忽略。原因很实在：`TrackPopupMenuEx` 跟踪菜单期间，系统会给菜单 owner 窗口发 `WM_CLOSE`；早期版本把它和"退出"画了等号，结果**右键托盘图标 = 菜单还没显示就把自己杀了**（现象就是"图标消失、程序没了"）。现在退出只有两个入口：菜单里的"退出"，和 `--exit`，都走自定义的 `WM_APP_QUIT`。

**状态不落缓存，每次现查 `IsWindowVisible(图标层)`。** 用户可能用资源管理器自己的「右键桌面 → 查看 → 显示桌面图标」改状态，也可能按 F5、重启 explorer。缓存会立刻和真实状态脱节，所以程序不记状态。

**explorer 重启后托盘图标要自己回来，靠的是 `TaskbarCreated` 这条广播。** shell 侧的托盘注册随 explorer 进程一起没了，我们的窗口还活着但图标会消失——不订阅这条广播时实测重启 explorer 后按钮数从 1 变 0。消息号每个会话动态分配，所以用 `RegisterWindowMessageW("TaskbarCreated")` 取，收到就重发 `NIM_ADD` + `NIM_SETVERSION`。

**注册补上了不等于"你就看得见它"。** Win11 会把不常动的托盘图标收进「显示隐藏的图标」溢出区，摆在哪儿是 shell 的决定，不是我们能保证的；找不到图标时点任务栏上的 `^` 展开看一眼，命令行 `--toggle` 永远可用。（这条区分是第 8 轮补的课：我一度把"任务栏带上数不到"当成"注册丢了"，因为溢出区收起时它的子元素根本不在 UIA 树里 —— 见 `TEST-REPORT.md` B18。）

**启动时注册失败会重试。** 开机时 Run 键完全可能比 explorer 的通知区更早起来，那时第一次 `NIM_ADD` 直接失败；现在失败即进入有界重补（0 / 800ms / 1600ms 三次，补满立刻拆定时器），`TaskbarCreated` 到达时共用同一条调度 —— 后者是便宜的保险，不是修某个被证实的丢失（`TEST-REPORT.md` B15′）

**隐藏的是图标层，不是桌面层。** Win11 24H2 上 `SHELLDLL_DefView` 被隐掉会连桌面背景一起消失（三打法截图对照：整屏平均亮度 128.5 → 27.8，就是"黑屏"）。真正该隐的是它下面那个 `SysListView32("FolderView")`：只隐它，图标没了、壁纸不动（128.5 → 128.3）。现在由 `tools\test-gesture.ps1` 的 CASE4 当回归断言守着，它采样的是固定的一块壁纸区域，所以绝对亮度基线不同（本轮 224.6 → 224.8），看的是"隐藏前后几乎不变"这件事。

**低级钩子不给双击事件。** `WH_MOUSE_LL` 只能看到原始 `LBUTTONDOWN/LBUTTONUP`，`WM_LBUTTONDBLCLK` 是系统稍后在目标线程里合成的——旁路探针抓到你真实双击时也只有 `0x201/0x202`。所以双击是程序自己按 `GetDoubleClickTime()` 时间窗 + `SM_C?DOUBLECLK` 位移窗配的。

**双击图标必须还给用户。** 图标列表控件的客户区铺满整屏，所以"命中窗口是列表控件"并不等于"点在图标上"。程序用 `LVM_SUBITEMHITTEST`（`LVM_FIRST+57 = 0x1039`，不是 `0x103F`）做真正的项命中测试：往 explorer 写 24 字节 `LVHITTESTINFO`、发消息、读回来，随后 `VirtualFreeEx`。命中图标 → 不切换；空白 → 切换。判不了的时候一律当作"点在图标上"，宁可不切也不抢你的点击。命中位用 `LVHT_ONITEM = 0xE`（`ICON|LABEL|STATEICON`），**不能含 `LVHT_NOWHERE(0x1)`**，否则空白会被判成图标、手势永久失效。

**取自身图标要按 `ExtractIconEx` 的真实返回语义判。** 同时传 large+small 两个数组时它返回的是"取出的句柄数"=2，不是图标数 1；判 `==1` 会永远落空、悄悄退回系统通用图标（这个 bug 是靠截图发现的，不是靠读代码）。取到的两个句柄都要 `DestroyIcon`，只留实际使用的那个。

**注入双击可关。** 远程协助、自动化脚本用 `SendInput` 发的双击在钩子层带 `LLMHF_INJECTED` 标志。默认接受（远控时你还能用这个手势），但托盘菜单里可以关掉，只认真实鼠标。

**多屏**：桌面图标层每个监视器一个，只切一个屏幕会留一半图标没藏。`FindDefViews()` 同时扫 `Progman` 和所有顶层 `WorkerW`，切换时一并处理。

**托盘菜单的 owner 必须是"可见的"窗口。** 承载托盘的是一个 `WS_POPUP | WS_VISIBLE` 的 **0×0 顶层窗口**，放在 (-32000,-32000)，再加 `WS_EX_TOOLWINDOW`——看不见、不进任务栏、不进 Alt+Tab（已实测：任务栏按钮数 0）。之所以不能是 message-only 窗口：`TrackPopupMenuEx` 的"点击菜单外部自动收起"要求 owner 有资格成为前台窗口，而不可见窗口没这个资格，实测 `SetForegroundWindow` 一直返回 0、菜单会永远挂在屏幕上。命令行客户端也刻意按**类名 + 标题**两个条件找后台实例：只按标题的话，任何外部程序起一个同名标题的窗口就会被当成我们，`--exit` 会把退出指令投给那个陌生窗口（已由 `tools\verify-decoy-window.ps1` 做正反双向断言）。

**开机复原只在自启动路径上做。** Run 键登记的是 `"...exe" --boot`；只有带 `--boot` 启动才去复原上次状态，你手动双击 exe 时程序绝不改你的桌面。状态在每次切换时写一次（防崩溃丢失），并在 `WM_QUERYENDSESSION` 时按**真实**值再刷一次（覆盖"你用 explorer 右键菜单改的"那种情况）。

**状态自证是分级的，不是"一切正常"。** `--status` 逐列报：`hook_set`（注册调用成功）/ `hook_saw_up`（回调真的被调用过）/ `hook_paired_dblclk`（配出过双击）/ `gesture_on` / `accept_injected` / `restore_on_boot`，再加计数行 `diag = ups/pairs/showwindow/dropped/toggle_failed` 和 `menu = tracks/last_track_ms`。这套自证是必须的——今晚有两次"看起来一切正常而功能完全不响"，都是靠这些分级读数定位的。

## 已知边界

- **依赖 explorer 的窗口类名**（`Progman` / `SHELLDLL_DefView`）。这几个类名从 XP 到 Win11 24H2 都稳定，但如果哪天 Windows 改了实现，程序切换会失效（表现为没反应），不会影响系统。右键桌面 → 查看 → 显示桌面图标 是系统侧的兜底开关。
- **图标隐藏期间的双击命中区域判定偏保守**：隐藏后命中窗口变成 `Progman` 本身，判定"在桌面上"依赖根窗口类名。
- **双击配对不校验"两次按下是否同一个窗口"**：低级钩子只能看到原始抬起事件，配对按系统的 `GetDoubleClickTime()` 时间窗 + `SM_C?DOUBLECLK` 位移窗（本机 ±2px）判定。极窄的一条时序会误判：第一次点在某个小程序按钮上、那个窗口在几百毫秒内消失、第二次正好落在腾出来的桌面空白同一像素上——这会多切一次图标，再双击一下即可回来。没有为此在钩子回调里加任何窗口查询：那条路上多花 300 ms 就是全系统鼠标发涩，代价不对称。
- **多显示器：两处未实测，程序在副屏上可能判反方向**（本机单屏 1920×1200）。① `LVM_SUBITEMHITTEST` 的客户区坐标换算在负原点副屏上的语义存在两种解释，没验过；② 可见性判定与切换以 `FindIconLayers()` 的**第一层**为基准（`Desktop.cs` 的 `IconsVisible`/`SetIconsVisible`），两屏状态不一致时（比如你在副屏用右键菜单单独改过）可能判反方向。这两条都**没有在多屏机器上实测过，所以不按评审建议改成 `layers.Any(...)`** —— 改完更"像对的"但依旧没证据，反而把没验证过的行为推上线。要上多屏机器时，跑 `tools	est-gesture.ps1` + `tools\verify-icon-guard.ps1` 即可当场取证。
- **托盘图标已换成自定义图标**：深色圆角 + 2×2 网格，右下角那格画成蓝色短横表示"被收起的一格"，16/32/48 三档经典 DIB 条目（PNG 压缩的 ICO 条目 GDI+ 读不了）。生成脚本 `tools\make-icon.ps1`，1:1 预览 `assets\tray-preview.png`，托盘实际渲染见 `shots\tray-icon-4x.png`。
- **退出时不改图标可见状态**：如果你在图标隐藏时退出程序，用右键桌面 → 查看 → 显示桌面图标 恢复。
- **命令行的信任边界 = 你这个用户本身。** 后台实例的消息窗口只对**同完整性级别**的进程敞开（低特权进程被 UIPI 挡住，发 `WM_APP_*` 只会静默失败）；能发 `--exit`／`--status`／投一次手势的进程，本来也就能终止你的进程、读你的注册表。也就是说它没有新增任何攻击面，但也没有假装抵御"已经是你"的进程。`--status` 的三条自证通道（`diag` / `menu` / `gesture`）都是只读查询。
- **手势有 100ms 节流。** 一次判定要在消息线程上做几次注册表读 + 十来次窗口查询，队列堆起来会撞 `LowLevelHooksTimeout`（300ms）——后果不是我们自己崩，而是全系统鼠标发涩 + 钩子被系统悄悄摘掉（而且 `hook_set` 照样报 1）。人手背靠背双击实测最快约 330ms 一次，所以 100ms 只挡洪水不挡你。被挡掉的次数记在 `gesture = ... throttled=N`，爆发式连点下 `throttled=32 / pairs=100` 是真拦到了（F30）。

## 安装包

`DesktopIconToggle-1.0.0.zip`（101,409 字节，SHA256 `8450D2FA27ACA656DB23EDDC5E326A70B54EB200DEBAFD85907F6F4AF79F44D4`），里面是：`DesktopIconToggle.exe` + `install.ps1` + `uninstall.ps1` + `README.md` + `使用说明.txt` + `SHA256SUMS.txt`。

```
powershell -ExecutionPolicy Bypass -File install.ps1        # 装 + 登记自启 + 起实例 + 独立回读反证
powershell -ExecutionPolicy Bypass -File install.ps1 -NoAutostart
powershell -File "$env:LOCALAPPDATA\DesktopIconToggle\uninstall.ps1"
```

刻意**没有**做成 Inno/WiX 那种 `setup.exe`：那要先往你机器上装打包工具链，而这个程序只需要"复制到只有你能写的目录 + 写一条 HKCU Run 键"。`install.ps1` 把这两步做完并且**自己反证**（回读 Run 键必须指向刚装的那一份、`--status` 必须报"运行中"，否则 throw）；`uninstall.ps1` **先验明身份再动手**：用 `VersionInfo.ProductName` 确认目标目录确实是本程序（绝不"跑一下看看"），然后 `--show` → `--exit`（不硬杀，硬杀会在任务栏留下点不到的幽灵图标）、只在 Run 键确实指向这一份时才删它、目录里混有别家 exe 就不删目录。指错路径时它 `exit 4` 并且什么都不改。

## 构建

```
dotnet publish DesktopIconToggle.csproj -c Release -r win-x64 --self-contained false `
    -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=false -o dist
```

或者 `powershell -File build.ps1`（发布 + 全部实测步骤，含独立探针反证；会临时改动你桌面的图标显示与自启注册表项，跑完复原）。

## 文件

| 文件 | 作用 |
| --- | --- |
| `Program.cs` | 入口、命令行客户端、消息循环、托盘菜单、手势判定 |
| `Native.cs` | 全部 P/Invoke 声明与结构体（业务代码里不出现 DllImport） |
| `Desktop.cs` | 找 DefView、切换可见性、落点判定、跨进程命中测试、`RemoteBlock` |
| `DesktopGestureHook.cs` | `WH_MOUSE_LL` 钩子 |
| `IpcWindow.cs` | 隐藏顶层窗口（托盘宿主 + 命令行 IPC，0×0 且屏幕外） |
| `TrayIcon.cs` / `Autostart.cs` / `Settings.cs` | 托盘、HKCU Run、HKCU 设置项 |
| `app.manifest` | asInvoker + PerMonitorV2 DPI 声明 |
| `TEST-REPORT.md` | 独立测试人的实测记录（含被测 exe 的 SHA256） |
| `RESUME.md` | 断点快照与下一步 |
