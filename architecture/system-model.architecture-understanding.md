# DesktopIconToggle 架构理解（当前态，证据可追溯）

- **这张文档回答的问题**：这个系统由哪些部分组成、每部分依赖谁、哪几跳跨出了自己的进程、边界在哪里。
- **读者**：要在半夜两点改这个程序的人。默认你不记得托盘窗口为什么必须是"可见的 0×0"。
- **范围**：`DesktopIconToggle/` 的 8 个 `.cs`（1,811 行）、`.csproj`、`app.manifest`、`README.md`。**不含** `tools/`、`package/`、`bin/`、`dist/`、`shots/`。
- **视图状态**：只有**当前态**。这张图里没有目标态、没有重构建议。
- **生成时刻**：2026-09-30。行号只对**当时那一版文件**有效，改动后请重跑 `verify_refs.py`（见下）。
- **产出方式**：`architecture-visualization:explore` 路由 → 主技能 `system-modeler`（结构与边界）+ 基础层 `c4model`（Structurizr DSL 产物）+ `graphviz`（依赖图 DOT）。之所以三个一起用：`system-modeler` 只给边界不给出可维护的图源，C4 画不出密集成 52 条的依赖网，所以依赖网交给 DOT。

---

## 0. 一句话架构

**一个 .NET 8 单文件 exe，靠一个低级鼠标钩子把"桌面空白处双击"翻译成对 explorer 进程里 `SysListView32` 窗口的 `ShowWindowAsync`，用一个 0×0 的隐藏顶层窗口同时充当托盘宿主和命令行 IPC 端点，除了 BCL 之外零依赖。**

它没有服务、没有数据库、没有 HTTP、没有主窗口。它的"架构"几乎全部由**一个硬约束**塑形：低级鼠标钩子的回调超时是 300 ms（`LowLevelHooksTimeout`），超时的后果不是我们自己崩，而是**全系统鼠标发涩**并且钩子被系统静默摘掉——而摘掉之后 `hook_set` 这个自证读数照样报 1（`README.md:49`、`README.md:88`）。下面几乎每一条不寻常的设计都是这条约束的推论。

---

## 1. 阅读顺序

| 顺序 | 文件 | 看什么 |
| --- | --- | --- |
| 1 | `system-model.structurizr.dsl` 的 `components` 视图 | 8 个组件和它们的父子归属 |
| 2 | `dependencies.dot` | 52 条边，按颜色分清"进程内 / 跨进 explorer / 读写注册表" |
| 3 | 本文件 §4、§5、§6 | 边上的语义和数字 |
| 4 | `evidence.json` | 任何一条断言的原始出处（`file:line` + anchor） |
| 5 | `dependencies-summary.md` | 判读、过滤、已知缺口、后续动作 |

要看图：用 Qoder 的 Structurizr DSL 预览打开 `.structurizr.dsl`，用 DOT 预览打开 `dependencies.dot`。**本机没有 `dot` 也没有 `structurizr` CLI，所以两个图都没有做本地渲染验证**——这点写在缺口里，不假装验过。

---

## 2. L1 系统语境：谁驱动它，它伸进谁

### 2.1 三个驱动者

| 驱动者 | 入口 | 走哪条路 | 出处 |
| --- | --- | --- | --- |
| 桌面用户（手） | 双击桌面空白 | `WH_MOUSE_LL` 钩子 → `PostMessage` → 消息线程判定 → 切换 | `DesktopGestureHook.cs:87`、`DesktopGestureHook.cs:90` |
| 桌面用户（托盘） | 托盘左键双击 / 右键 | `WM_TRAY` 回调 → `ToggleIcons` 或 `ShowMenu` | `Program.cs:275`、`Program.cs:281` |
| 脚本 / 快捷键 / 任务计划 | `exe --toggle` 等 argv | **不起后台实例也能改**，直接对图标层下手 | `Program.cs:33`、`Program.cs:529`、`README.md:35` |
| 注入输入（`SendInput`、远控、投屏） | 同样是双击，但带注入位 | 钩子读到 `LLMHF` 两个位，按设置决定认不认 | `DesktopGestureHook.cs:22` |

第四个驱动者值得单独看：**它是唯一一个"不是人"的输入源**，而且默认是**被接受**的（`Settings.cs:23` 的默认值为 1），因为远程协助场景你需要手势还能用。这个默认值是刻意的取舍，不是遗漏。

### 2.2 四个"不是我们的代码"的外部系统

| 外部系统 | 我们怎么用 | 一旦它变了会怎样 | 出处 |
| --- | --- | --- | --- |
| Explorer 桌面窗口树 | 找 `Progman` 和**所有** `WorkerW`，下钻 `SHELLDLL_DefView`，对最底下的 `SysListView32` 做显隐 | 切换变成"没反应"，不会影响系统 | `Desktop.cs:39`、`Desktop.cs:18`、`Desktop.cs:61` |
| Explorer 通知区（托盘） | 注册图标、收 `WM_TRAY`、shell 重启后重注册 | 托盘图标看不见，命令行还是退路 | `TrayIcon.cs:29`、`Program.cs:199` |
| Win32 API | user32 / shell32 / kernel32 / advapi32，共 61 个 `DllImport` | —— | `Native.cs:42`、`Native.cs:290`、`Native.cs:370`、`Native.cs:379`、`Native.cs:437` |
| HKCU 注册表 | 两个键：设置键 + `Run` 自启键 | 设置回默认、自启消失 | `Settings.cs:12`、`Autostart.cs:11` |

**边界要说清楚**：`SysListView32` 那个窗口**不属于这个进程**。这个程序对它的操作是跨进程的窗口命令，甚至在它的地址空间里分配和读写内存。C4 图上一个箭头，运行期是别人家的句柄。这是整个模型里最容易被低估的一点，所以在 DOT 里这几条边是红色的。

---

## 3. L2 容器：一份 exe，两个身份

只有一个可部署单元：`DesktopIconToggle.exe`（`DesktopIconToggle.csproj:6`，`WinExe` + `net8.0` + x64，`app.manifest:8` 声明 `asInvoker`，不提权）。

但它**按 argv 分裂成两种角色**（`Program.cs:33` 取 `args[0]` 小写，`Program.cs:35` 一个 `switch` 分完）：

| 角色 | 怎么起 | 存活期 | 持有什么 | 出处 |
| --- | --- | --- | --- | --- |
| **后台实例（server）** | 不带参数，或 `--boot`（`Run` 键登记的就是带 `--boot` 的那条） | 分钟到天，直到 `--exit` 或注销 | 命名互斥体、消息循环、隐藏窗口、鼠标钩子、托盘注册 | `Program.cs:62`、`Program.cs:99`、`Program.cs:96`、`Autostart.cs:26` |
| **一次性调用（client）** | 任何带 flag 的启动 | 一条命令的时间 | 什么都不持有；要么直接改图标层，要么给 server 发消息 | `Program.cs:32`、`Program.cs:529`、`Program.cs:635` |

用 Java 的话类比：**一个 jar，`main()` 里根据参数决定自己是"常驻的 Spring Boot 应用"还是"一个 Flyway 那样的 CLI 工具"**，而 CLI 工具需要用 `--status` 探活时，是通过一个命名窗口找到那个正在跑的应用并给它发消息——不是通过 HTTP，也不是通过队列。

两个角色之间的发现机制有身份校验：按**类名 + 标题两个条件**找窗口，再确认这个窗口的属主 exe 路径是不是自己这个文件（`IpcWindow.cs:14`、`IpcWindow.cs:15`、`IpcWindow.cs:77`、`IpcWindow.cs:97`）。为什么这么麻烦：只按标题找的话，任何外部程序起一个同名标题的窗口就能把 `--exit` 收走。这条有正反双向断言（`README.md:73`）。

副作用你应该知道：所以在 `dist\` 目录下敲 `--status` 会如实报"未运行"——那是设计，不是坏（`README.md:39`）。

---

## 4. L3 组件：8 个文件，真实度数

扇入扇出是**从 `evidence.json` 的 52 条边现算的**，不是估的。占比按 `wc -l` 实测行数。

| 组件 | 行数 | 占比 | 出边 | 入边 | 职责一句话 | 锚点 |
| --- | --- | --- | --- | --- | --- | --- |
| `Program` | 646 | 35.7% | **14** | **5** | 入口、argv 分派、消息循环、WndProc、托盘菜单、手势判定、开机复原 | `Program.cs:30` |
| `Native` | 442 | 24.4% | 5 | **7** | 唯一出现 `DllImport` 的地方；61 个声明 + 结构体 + 委托 + 消息/样式常量 | `Native.cs:290`、`README.md:116` |
| `Desktop` | 225 | 12.4% | 7 | 4 | 找 DefView 与图标层、读写可见性、判点、发起跨进程命中测试 | `Desktop.cs:91`、`Desktop.cs:70` |
| `IpcWindow` | 136 | 7.5% | 2 | 2 | 0×0 隐藏顶层窗口：托盘宿主 + 命令行端点 | `IpcWindow.cs:14`、`IpcWindow.cs:41` |
| `DesktopGestureHook` | 108 | 6.0% | 3 | 4 | `WH_MOUSE_LL`，自己配对双击，回调里不分配堆 | `DesktopGestureHook.cs:52`、`DesktopGestureHook.cs:44` |
| `Autostart` | 101 | 5.6% | 2 | 1 | `Run` 键一条 REG_SZ，路径自愈 | `Autostart.cs:11`、`Autostart.cs:99` |
| `TrayIcon` | 81 | 4.5% | 3 | 2 | 通知区注册 / v4 / 有界重补 / 注销 | `TrayIcon.cs:39` |
| `Settings` | 72 | 4.0% | 4 | 2 | HKCU 四个 REG_DWORD | `Settings.cs:12`、`Settings.cs:33` |
| `RemoteBlock`（嵌在 `Desktop.cs` 内） | —— | —— | 1 | 1 | 在 explorer 里借 24 字节用完还 | `Desktop.cs:197`、`Desktop.cs:202` |

两个读数要说：**`Native` 入边 7 = 除自己以外每个组件都依赖它**，这是刻意的接缝（seam）设计，业务代码里搜不到 DLL 名。**`Program` 出边 14 = 唯一的全局协调者**，它同时是入口、消息处理、UI 菜单、手势判定、开机复原五件事的宿主——这是这个程序最大的一块聚合，我不给它编造"应该拆"的建议，但它就是最大的耦合中心。

---

## 5. 五条最要紧的边

### 5.1 `Desktop → Explorer 桌面窗口树`：**唯一的真实效果**

```csharp
foreach (IntPtr layer in FindIconLayers())
{
    if (Native.IsWindowVisible(layer) == visible) continue;
    Native.ShowWindowAsync(layer, visible ? Native.SW_SHOW : Native.SW_HIDE);   // Desktop.cs:91
```

三件事压在这一跳上：

1. **切的是图标层不是 DefView**。Win11 24H2 上隐 `SHELLDLL_DefView` 会连壁纸一起黑掉（README 记的三打法亮度读数：整屏平均 128.5 → 27.8），只隐它下面的 `SysListView32` 才是图标没了壁纸不动（128.5 → 128.3，`README.md:61`）。
2. **用 `ShowWindowAsync` 不用同步 `ShowWindow`**（`Desktop.cs:91` 属性行在 `Native.cs:289`，声明在 `Native.cs:290`）。同步版会等目标线程处理 show-window 事件，而 explorer 一卡就是**全系统鼠标发涩**——300 ms 那条约束的推论。
3. **状态一律现查、绝不缓存**（`Desktop.cs:70` 用 `IsWindowVisible`）。因为用户随时可能用资源管理器自己的"右键桌面 → 查看 → 显示桌面图标"改掉它，缓存会立刻和真实状态脱节（`README.md:53`）。这条决定了 `Desktop` 每次调用都重新枚举窗口树（`Desktop.cs:39`、`Desktop.cs:61`），也就是**没有状态缓存这一层**，多屏时副屏的 DefView 也一起扫到。

### 5.2 `RemoteBlock → explorer 进程内存`：最重的一跳

命中测试要问 explorer 的列表控件"这个点落在不在某一项上"。做法是**在对端进程里借内存**：`OpenProcess`（`Desktop.cs:197`）→ `VirtualAllocEx`（`Desktop.cs:202`）→ `WriteProcessMemory` 写 24 字节的 `LVHITTESTINFO`（`Desktop.cs:213`）→ `SendMessageTimeoutW(listView, LVM_SUBITEMHITTEST, ...)`（`Desktop.cs:165`，超时 **150 ms**，带 `SMTO_ABORTIFHUNG | SMTO_BLOCK`）→ `ReadProcessMemory` 读回（`Desktop.cs:216`）→ `VirtualFreeEx` 还。

`LVM_SUBITEMHITTEST = LVM_FIRST + 57 = 0x1039`，**不是 `0x103F`**；命中位用 `LVHT_ONITEM = 0xE`，**不能含 `LVHT_NOWHERE(0x1)`**，否则空白会被判成图标、手势永久失效（`README.md:65`）。测不出来时的兜底方向是保守的：当作"点在图标上"、**不切换**（`Program.cs:343`）——宁可不切，也不抢你启动程序的点击。

Java 类比：这相当于**为了问一个字段，往另一个 JVM 的堆里 `Unsafe` 分配了一块内存、塞结构体、发 IPC 消息、再读回来**。之所以要这么绕，是因为 listview 的命中测试本来就是同步消息，参数必须在对端地址空间。

### 5.3 `DesktopGestureHook → IpcWindow`：300 ms 预算决定的形状

钩子回调只做四件事：消息号比较、按偏移直读坐标和注入位、几个整数比较、`PostMessage`（`DesktopGestureHook.cs:90`）。连 `Marshal.PtrToStructure` 都换成了 `Marshal.ReadInt32`，因为每次装箱分配都可能在 300 ms 预算里插一次 GC（`README.md:49`）。

判定落点和跨进程命中测试**全部挪出回调**。挪法还多一层：消息线程只做便宜判定（`Desktop.IsDesktopPoint` `Program.cs:319`、`Desktop.ClicksThrough` `Program.cs:325`），凡是要给 explorer 发消息的都丢到 `ThreadPool`（`Program.cs:341`），测完再 `PostMessage` 回消息线程（`Program.cs:346`）。**消息循环被跨进程调用占住 = 鼠标发涩**，所以这条边界必须存在。

另外：低级钩子**不给 `WM_LBUTTONDBLCLK`**，双击是程序自己按 `GetDoubleClickTime()` 的时间窗 + `SM_CXDOUBLECLK/SM_CYDOUBLECLK` 的位移窗配对的（`DesktopGestureHook.cs:44`、`DesktopGestureHook.cs:46`，位移窗半幅取 `Math.Max(2, c/2)`）。

### 5.4 `proc.cli ↔ proc.server`：一条 WM_APP 协议，三个只读自证通道

协议常量全部固定（只有 `TaskbarCreated` 是运行期 `RegisterWindowMessageW` 动态取，`Native.cs:42`）：

| 消息 | 值 | 用途 | 出处 |
| --- | --- | --- | --- |
| `WM_TRAY` | `0x0400` | 托盘回调 | `Native.cs:21` |
| `WM_APP_PING` | `0x8002` | 探活，返回值低位是状态标志 | `Native.cs:30` |
| `WM_APP_QUIT` | `0x8003` | 退出（唯一的退出消息） | `Native.cs:36` |
| `WM_APP_GESTURE` | `0x8004` | 钩子入队，`wParam` 打包坐标、`lParam` 真实/注入 | `Native.cs:24` |
| `WM_APP_ICON_TEST` | `0x8007` | 命中测试结果回投 | `Native.cs:27` |
| `WM_APP_MENU_STATS` | `0x8008` | 第二诊断通道 | `Native.cs:33` |
| `WM_APP_GESTURE_STATS` | `0x8009` | 第三诊断通道 | `Native.cs:35` |

同步查询走 `SendMessageTimeoutW`（1000 ms，`IpcWindow.cs:109`），`--exit` 是 fire-and-forget 的 `PostMessageW`（`Program.cs:635`）。

自证是**分级**的而不是一个"健康/不健康"布尔：`hook_set`（注册调用成功）≠ `hook_saw_up`（回调真被调用过）≠ `hook_paired_dblclk`（配出过双击）≠ `showwindow`（真的执行了几次）≠ `dropped`（因为上一次还没测完而丢弃）（`Program.cs:545`、`Program.cs:559`、`Program.cs:568`、`Program.cs:398`、`Program.cs:407`、`Program.cs:444`）。README 里明写这套是必须的——有两次"看起来一切正常而功能完全不响"，都靠这些读数定位（`README.md:77`）。

这里有个**读数的坑**要记住：`showwindow` 记的是**后台实例自己**执行的次数，你用 `--toggle/--hide/--show` 从命令行改的不算——那是另一个进程在做（`README.md:13`）。

### 5.5 `Explorer 通知区 → Program`：唯一的入站异步广播

shell 换进程后旧注册必然作废，而我们的窗口还活着，图标就没了。靠 `TaskbarCreated` 这条每个会话动态分配的消息号重注册（`Program.cs:199`、`Native.cs:42`），失败进入有界重补：0 / 800 ms / 1600 ms 三次，补满立刻拆定时器（`Program.cs:175`、`Program.cs:177`）。

README 对这条的定性要照抄：**"②这一条属于'便宜的保险'而不是'已证实的缺陷'"**（`Program.cs:168` 的注释），并且澄清了一次误判——把"任务栏带上数不到"当成"注册丢了"，而 Win11 会把不常动的图标收进溢出区，收起时子元素根本不在 UIA 树里（`README.md:57`）。**模型里这条边是虚线，就是因为它的动机一半是保险**。

---

## 6. 三个自环：C4 画不出来的守卫

52 条边里有 3 条是自环（`e.bootrestore-timer`、`e.gesture-throttle`、`e.gesture-inflight`）。它们不是依赖，是**时序守卫**，用箭头画出来很别扭，但漏掉它们就等于漏掉这个程序的设计中心：

| 守卫 | 数值 | 为什么是这个数 | 出处 |
| --- | --- | --- | --- |
| 手势节流 | **100 ms** | 一次手势要做 4~8 次注册表读 + 十来次窗口查询；队列堆起来就撞 300 ms。人手背靠背双击实测最快约 **330 ms** 一次，所以 100 ms 只挡洪水不挡真人 | `Program.cs:312`、`Program.cs:350` |
| 命中测试并发闸 | **1**（`Interlocked.CompareExchange`） | 全程序唯一的并发原语。丢弃的次数计入 `dropped`，不然表现就是"我明明双击了却没反应"而 `pairs` 一直涨，看不出差错在哪 | `Program.cs:332` |
| 开机复原重试 | **2000 ms × 最多 10 次**，成功或用尽都 `KillTimer` | 开机时 explorer 可能还没建出图标层。不拆表就是每 2 秒空转到进程结束——**"占用小"这条承诺会被一次没成功的复原悄悄破坏** | `Program.cs:115`、`Program.cs:149`、`Program.cs:146` |
| 托盘重补 | **800 ms × 2 次**（加调用方已试的 1 次，共 4 次） | 同上纪律：一个活着的周期定时器就等于违背占用承诺 | `Program.cs:175`、`Program.cs:177` |

顺带给一张实测占用表（README 记的数值，我**没有**在本机复测）：私有内存 6.3–7.1 MB、工作集 25.9–28.9 MB、空闲 30 秒累计 CPU **0 ms**、冷启动到可通信 279–455 ms、双击到图标消失 239–306 ms（`README.md:7`、`README.md:8`）。`DesktopIconToggle.csproj:28` 起那三行 GC 配置（工作站 GC、不并发回收、不保留堆段）就是这些数字的成因之一。

---

## 7. 一个 C4 依赖图看不见的耦合，也是最该记住的风险

`Program` 到 `Native` 到 61 个 Win32 函数，**NuGet 依赖数 = 0**（`.csproj` 里没有一个 `PackageReference`）。供应链攻击面基本是空的。

但这个程序真正依赖的东西不在代码里：**三个窗口类名字符串**——`Progman`、`WorkerW`、`SHELLDLL_DefView`、`SysListView32`（`Desktop.cs:15`–`Desktop.cs:18`）。这是一份**没有版本协商、没有契约测试、没有运行时校验**的隐性接口合同，对方是 explorer 的实现细节。README 的判断是"从 XP 到 Win11 24H2 都稳定，但如果哪天 Windows 改了实现，程序切换会失效（表现为没反应），不会影响系统"（`README.md:81`）。

在依赖图里这条边就是 `Desktop → Explorer 桌面窗口树`，看不出它脆弱；**它脆弱是因为它是字符串常量而不是因为它是跨进程调用**。这就是"代码依赖图 ≠ 架构风险图"的教科书例子，值得单独记一句。

---

## 8. 假设与缺口（不假装验过）

**这份模型基于的证据**：8 个 `.cs` 源码、`.csproj`、`app.manifest`、`README.md`。全部静态读。

明确缺口：

1. **没有运行期证据**。没跑过 exe、没读过 live 进程、没测过 `--status`。README 的实测数字是**文档记载**，我复述但不背书。
2. **`TEST-REPORT.md` 与 `RESUME.md` 本轮未读**（读取被权限判定拦下）。里面 README 引用的 F22 / F28 / B15′ / B18 / F30 等编号我**没有**核对过，所以模型里没有引用它们。
3. **多屏行为未验证，两条**（README 自己承认，`README.md:84`）：① `LVM_SUBITEMHITTEST` 的客户区坐标在负原点副屏上的语义有两种解释；② 可见性判定与切换以 `FindIconLayers()` 的**第一层**为基准，两屏状态不一致时可能判反方向。**本机是单屏 1920×1200，这两条无法取证**。我在模型里没有把它们画成缺陷，也没有画成正常——它们不在图上，写在缺口里。
4. **两张图都没有本地渲染验证**：本机没有 `dot`，也没有 `structurizr` CLI。语法是我按规范写的，闸门验的是**引用一致性**，不是渲染成功。
5. **`tools/` 下的回归脚本未纳入模型**（`test-gesture.ps1`、`verify-icon-guard.ps1`、`verify-decoy-window.ps1`、`deploy-local.ps1`、`make-icon.ps1`）。它们是测试与发布链路，不是产品架构；要画"验证拓扑"的话是另一张图、另一次路由。
6. **`Autostart.cs:70`–`Autostart.cs:74` 有两个叠在一起的 XML `summary` 块**（第一个描述 `SelfHeal` 的条件，第二个描述紧随其后的 `Unquote`），第二个把第一个顶成了悬空注释。是文档注释瑕疵，不影响行为，我在模型里不改架构事实去迁就它——记在这里。

---

## 9. 复现与验证（可跑）

任何一条断言都可回读。闸门在 `DesktopIconToggle/architecture/` 下：

```bash
cd DesktopIconToggle/architecture
python verify_refs.py     # 170 条 sourceRef 逐条回读真文件真行 + anchor 命中；4 个负控制
python cross_check.py     # .dot / .dsl / 全部 4 份 .md 的每个引用必须在 evidence.json 里已验；节点边集合双向相等；7 个负控制
python gen_dot.py         # 从 evidence.json 重新生成 dependencies.dot（图不手抄，避免行号漂移）
python add_prose_refs.py  # markdown 增删引用后，重建 evidence.json 的 prose 段（缺 anchor 即中止）
```

两个闸门都以非零码否决，且**扫到 0 条也算失败**（零分母不是通过）。

`verify_refs.py` 今天的实际战绩：第一次跑否决了 **16 处引用、落在 11 个不同位置**，全部来自我照抄下游报告的行号。主因是 C# 的 `[DllImport]` 属性和函数声明在**相邻两行**——下游报的是属性行，函数名在下一行（`Native.cs:41` 对 `:42`、`Native.cs:289` 对 `:290`、`Native.cs:368` 对 `:370`、`Native.cs:378` 对 `:379`、`Native.cs:436` 对 `:437`，五处同一形状）；另一类是**间接寻址**：`Desktop.cs:61` 用的是常量名 `ListViewClass`，字面量 `SysListView32` 其实在 `Desktop.cs:18`；剩下的是 README 里三处段落级行号和两处注册表/托盘的行号偏差。**这 16 处全被 anchor 匹配当场否决，也就是说：想让引用可信，就得先让它有能力否决。**
