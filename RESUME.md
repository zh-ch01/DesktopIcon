# RESUME — 断点快照（2026-09-26 01:00 更新，第 9 段：**已交付（含安装包），无待实测项**）

暗号：**继续桌面图标开关 第9段**（这次跨重启会断会话，所以给；平时我不再要暗号——我是主控，我继续）
（本文件是断点快照；读之前先对时间戳，并与 `dist\` 的实际产物哈希核一遍。）

工程目录：`D:\z\workspace\work3\DesktopIconToggle\`
最终产物：`dist\DesktopIconToggle.exe`，**219,889 字节**（2026-09-25 19:47，同一份源码两次 publish 逐字节一致）
SHA256 `E00600E5265283A20C1DE2F929D49F85A64AFFC2AA77291E5C52221C9C8CB8F0`
日常运行副本：`%LOCALAPPDATA%\DesktopIconToggle\DesktopIconToggle.exe`（同一份字节，Run 键指向它）
历史产物：`502A354D…49BDB7`（17:37，被第 9 轮评审的 B21–B25 取代）、`F1EF8087…703CD`（16:37）、`82FE88B5…766BAB`（15:09）、`BD7387E7…898C2F`（07:22，第 7 段真机冷启动那份证据）、`2C9B2DEA…6588FF`、`DCEAF425…525C09`

## 现在是什么状态

**34 条受控用例全 PASS + 开机现场顺采 1 条（F22b）；31 个缺陷全修（10 个夹具自身、2 个安装包脚本）、每个都有回归证据。** 明细在 `TEST-REPORT.md`（含被测 exe 哈希，可复算）。

占用（本二进制实测）：私有内存 **6.3 – 7.1 MB**（跨运行 ±0.8 MB 抖动，不挑小的报）/ 工作集 25.9 – 28.9 MB / **空闲 30 秒 CPU 增量 0 ms** / 冷启动 279 – 455 ms / **最终哈希上 70 分钟驻留**：漂移 **-0.73 MB**、句柄 -5、线程 -4、CPU **1.80 ms/分**。0 警告 0 错误；同一份源码连续两次 publish 逐字节一致（可复现构建）。

第 8 段（16:00–18:00）做的事，一半是推翻我自己上一轮的结论：

| # | 内容 | 状态 |
| --- | --- | --- |
| F27 | 图标保护端到端：同一条 IPC 通道，落点压图标 → `on_icon +1` 而 `showwindow` 纹丝不动；落空白 → 必须切换。落点由**测试自己的** `LVM_SUBITEMHITTEST` 认定（`flags=0x2`） | 新增，PASS |
| B16 | 夹具的 `trap { …; continue }` 会咽掉异常，让 `VERDICT: PASS` 在哨兵根本没满足时打印出来——F21 第一条 PASS 就是这么来的（真因：更早一次编辑把一段 C# 落进了 PowerShell here-string，靶面子进程解析失败、窗口没建） | 已修（trap 打印异常 + 还原遮挡 + `exit 1`；`$script:coveredWin`；子脚本落盘后先过 `Parser::ParseFile`） |
| B17 | 夹具的"桌面空白落点"只验根窗口是 `Progman/WorkerW`，**没验压不压图标** → 产品判 `on_icon` 是对的，却被报成 FAIL | 已修（落点要求该点及四周 24px 的命中测试都不含 `ONITEMICON`/`ONITEMLABEL`）。F21 第三次重跑 PASS |
| B18 | 托盘判据只数"任务栏那一条带"，把**被 Win11 收进溢出区**与**根本没注册**混成一件事（溢出区收起时子元素不在 UIA 树里）；放松成"扫全树"又会被 shell 被强杀后的**幽灵按钮**骗 | 已修（两层口径：硬口径只数任务栏带，数到 0 才用 UIA `InvokePattern` 展开溢出区 peek 一次，报 `bar/overflow/absent/unknown`）。**并撤回上一版据此写下的 B15 结论** |
| B20 | `verify-real-boot.ps1` 三处毛病凑成一条**假 FAIL**：过期的 `boot-expect.txt` 当期望值、30 分钟闸门只打印不否决、`Invoke-Exe` 路径写死 `dist\` | 已修（布防文件须晚于本次开机；现场外一律 `INCONCLUSIVE` 退 3；按在场实例自身路径问）。19:3x 复跑：`exit=3 INCONCLUSIVE` + `instance = 运行中 pid=21992` 交叉验证正常 |
| B19 | 夹具从 `dist\` 发 `--status`，而场里跑的是 `%LOCALAPPDATA%` 那一份 → 产品按属主校验**正确地**答"未运行"，字段在夹具眼里"凭空消失"，F29 假 FAIL | 已修（先按进程的 `Path` 用其自身路径退掉在场实例，再起要测的这份） |
| B15′ | 那一轮真正修掉的产品问题：**启动时 `NIM_ADD` 失败只往 stderr 喊一声、不重试**（开机时 Run 键比 explorer 的通知区更早是常态） | 已修（失败即进入有界重补 0/800/1600ms，补满拆表；`TaskbarCreated` 共用同一条调度，那里属便宜的保险）。两个定时器共用 `WM_TIMER`，按 `wParam` 里的 id 分流 |

## 还剩什么（都不是产品缺口，是环境限制）

1. **同哈希的真机冷启动：已完成。** 用户 22:09 重启，22:14 现场跑 `tools\verify-real-boot.ps1` → **退出码 0 / PASS**（`run-real-boot-POSTREBOOT2.log`）：开机 34 秒后 Run 键把 `%LOCALAPPDATA%` 那份拉起来；期望值 `hidden` 由注册表独立给出（21:52 那份 `boot-expect.txt` 因早于本次开机被按 B20 规则忽略，两源仍一致）；独立探针 `hidden`、亮度 199.7、托盘 1、`showwindow=1`（确实是我们改回 hidden 的那一次调用）、开机后用户自己的 `ups=40 / pairs=0`（一次都没抢）。**仍存的窄口子**：开机顺序是顺风（实例比 explorer 晚 17 秒），所以 `TaskbarCreated` 补偿在真机开机里还是没上岗——它只在 F24 实验室竞态与 F20 下取过证据。

2. **多屏**：本机单屏，副屏的图标层枚举与 `LVM_SUBITEMHITTEST` 客户区坐标在负原点屏上的语义未实测。
3. **远程桌面 / 投屏**：其双击带不带注入位未测（现按"两个注入位都算非真实鼠标"处理，默认接受注入，可在托盘菜单关）。
4. **非 110% DPI**：未测。小时级驻留已实测（F26：70 分钟、私有内存漂移 -0.05 MB、句柄 -5、CPU 9.16 ms/分）。
5. **B10 的"重试次数用尽"那一半**：这台 Win11 24H2 上 `Stop-Process explorer -Force` 之后系统会**自动拉起 explorer**，"全程没有图标层"的前提本机造不出来，只剩代码级证据。能测的"拆完之后确实安静"已测（F31：60 秒 CPU 增量 0 ms）。
6. 可选功能 `--hotkey`（RegisterHotKey）：你没要，我没加。
7. **安装包已交付**：`DesktopIconToggle-1.0.0.zip`（101,409 字节，SHA256 `8450D2FA27ACA656DB23EDDC5E326A70B54EB200DEBAFD85907F6F4AF79F44D4`）。五条路径都真跑过：首装 / 幂等重装 / 升级覆盖 / 真卸载 / 拒绝误删（F34）。做安装包时自己写出又自己抓掉的两个安全缺陷记在 B30/B31。
8. 图标造型可换：`tools\make-icon.ps1` 改参数 → 看 `assets\tray-preview.png`（1:1）→ 重新发布 + `tools\deploy-local.ps1`。

## 你机器现在的状态（交付态）

- 桌面图标：**visible**（没把桌面留在特殊状态）。
- 开机自启：**ON**，Run 键 = `"%LOCALAPPDATA%\DesktopIconToggle\DesktopIconToggle.exe" --boot`（只有你能写的目录，理由见 README 首屏 + `TEST-REPORT.md` §9）。
- 实例：**正在运行**（最后由 `tools\deploy-local.ps1` 起的那一份），托盘注册在位。**摆在哪儿由 Win11 决定**：它可能把图标收进「显示隐藏的图标」，点任务栏上的 `^` 就能看到；命令行 `--toggle` 永远可用。
- `HKCU\Software\DesktopIconToggle`：`DesktopDoubleClickGesture=1`、`RespondToInjectedDoubleClick=1`、`RestoreStateOnStartup=1`、`IconsVisibleOnExit=1`。
- 唯一一处工程目录外的痕迹：第 4 轮测试最早拿记事本当靶面，Win11 记事本是单进程多标签，探针文件被开进了那个 Notepad 进程，留下一个 `gesture-probe-….txt` 标签页（临时文件本身已删，你的 `task.txt` 没碰）。脚本随后改成自建窗口当靶面，不再碰任何第三方进程。不紧急，你自己关就行。
- `boot-expect.txt` 留着：它是第 7 段 F22「收着图标过重启」证据链的一环（报告 §1/§4 引用），不是待收的布防状态。

## 历次段落

| 段 | 做了什么 | 产物 |
| --- | --- | --- |
| 第 9 段（20:25） | 两路独立评审（产品源码 / 测试夹具各一路，互不知情）。产品侧修 **B21–B25**：`TrayIcon.Add()` 赋值覆盖 `_added` 会在退出时**留幽灵托盘图标**、钩子回调里 `Marshal.PtrToStructure` **每个抬起分配一次**（改成按 `Marshal.OffsetOf` 标定过的偏移直读）、`RegisterWindowMessageW` 返 0 时把 `WM_NULL` 当成 shell 广播、csproj 没锁 x64、跨路径第二份实例静默退出（新增 **F33**）。夹具侧修 9 类（**B26–B29** 等）：`LVM_GETITEMPOSITION` 消息号写错导致 F27 的"锚点 (0,0)"是假的、F7 写死托盘坐标差 38px 造成假 FAIL 且 FAIL 不给退出码、六份 COV 还原会把用户最大化窗口改成浮动尺寸、`verify-shell-race` 杀 explorer 却没有 trap、B19 前置铺到 14 个脚本 + `build.ps1`。**两条评审意见复核后拒绝并写明理由**（IPC 随机密钥、多屏 `layers.Any`）。全部对最终哈希复跑 | `E00600E5…C8CB8F0` |
| 第 8 段（19:25） | 新增 **F27**（图标保护端到端）、**F31**（拆表后 60 秒零 CPU）、**F32**（shell 连环重启后托盘注册不丢不重、对象不涨）；抓到 **B16**（夹具吞异常造出假 PASS）、**B17**（落点前提不严，把产品的正确行为报成 FAIL）、**B18**（托盘判据分不清溢出区与没注册），**撤回 B15 的原结论**、留下真正该修的 **B15′**（启动注册失败不重试）；全量对最终哈希复跑；清掉 11 个脚本的双 BOM 与 `build.ps1` 的 `%%` | `502A354D…49BDB7` |
| 第 7 段续（12:50） | 把"真机顺风没触发"的分支搬进实验室：**F24** 无 shell 起实例 → 托盘 `0→1→0→1`；**F25** 真竞态复原 0.4 秒落地 + `showwindow 0→1` 行为归因；**F23** 注入开关两条路径；**F26** 70 分钟驻留。抓到并修掉 4 条夹具/判据自身的错（报告 §8），其中一条必须标白：**线程判据是看到数据之后才从"变化即 FAIL"改成"增长才是泄漏"**。确立环境事实：本机 `Stop-Process explorer` 后系统会自动拉起 explorer，"全程无 shell"前提不可造 | `82FE88B5…`（当时） |
| 第 7 段（09:05） | 真机冷启动实测 F22 PASS；§4 记"两个子分支未触发" | `BD7387E7…898C2F` |
| 第 6 段（07:46） | 补测 explorer 重启 → 挖出并修 **B13**（重启后托盘图标不回来，缺 `TaskbarCreated`）、**B14**（"双击没落地"说不出原因 → 新增 `gesture = on_icon/not_desktop/last`）；新增 F20/F21/F19；诚实修正 `build.ps1` 拿不到退出码、占用表头写 45s 实采 30s | 同上 |
| 第 5 段（03:31） | 第 3 轮评审 + 自查：**B10**（重试定时器用尽不拆表）、**B11**（`FindOther` 只按标题 → 会误退陌生窗口，加类名 + 诱饵反证 F18）、**B12**（`SIZE_T` 按 `int` 声明，x64 上会踩栈）；清死代码；F17 快速连击 | `2C9B2DEA…6588FF` |
| 通宵段（03:03） | 第二轮评审 9 项修复（含 B9 可见 0×0 owner）、分级自证、开机复原、路径无关性 | `DCEAF425…525C09` |

## 复跑（全绿顺序）

```
dotnet build -c Release -v q --nologo            # 应为 0 警告 0 错误
# publish 前先 --exit，否则 exe 被锁、Remove-Item 会终止脚本（build.ps1 已把停实例提到第 1 步）

powershell -File build.ps1                             # 发布 + F8 F9 F10 + 占用/冷启动（会把自启切成 off，跑完补一次 deploy-local）
powershell -File tools\test-gesture.ps1                # F1 F2 F3 + 壁纸亮度回归
powershell -File tools\stress-rapid-toggle.ps1         # F17
powershell -File tools\verify-icon-guard.ps1           # F27 图标保护端到端（找不到落点报 SKIP/退 4，不降级）
powershell -File tools\verify-gesture-reason.ps1       # F21
powershell -File tools\verify-real-tray.ps1            # F5 F6
powershell -File tools\verify-dismiss-final.ps1        # F7（必须真实右键）
powershell -File tools\check-window-hygiene.ps1        # F15
powershell -File tools\verify-path-independent.ps1     # F11 F16
powershell -File tools\verify-decoy-window.ps1         # F18
powershell -File tools\verify-owner-spoof.ps1          # F28
powershell -File tools\verify-restore-on-boot.ps1      # F12 F13
powershell -File tools\verify-injected-toggle.ps1      # F23
powershell -File tools\verify-shell-race.ps1           # F24 F25（全过也给 PARTIAL/退 2；B 组是弱证据，见 B18）
powershell -File tools\verify-retry-exhaustion.ps1     # F31
powershell -File tools\stress-leak-objects.ps1         # F29 F30（约 6 分钟）
powershell -File tools\verify-explorer-restart.ps1     # F20（真杀 explorer，跑完重开你的文件夹窗口）
powershell -File tools\probe-tray-rereg.ps1 -Rounds 2  # F32/B15′ 复验（报 bar/overflow/absent/unknown）
powershell -File tools\verify-real-boot.ps1            # F22（只在开机 30 分钟内算数）
powershell -File tools\deploy-local.ps1                # 日常那一份装进 %LOCALAPPDATA% 并指 Run 键
```

## 做夹具时的几条硬规矩（这几轮踩出来的）

- **异常必须有地方去**：`trap { …; exit 1 }`，不许 `continue`。`continue` 会咽掉哨兵的 `throw`，脚本继续往下跑并照常打印 `VERDICT: PASS`（B16 的真实现场）。
- 函数里改脚本级变量要写 `$script:name`，否则只是局部变量——还原逻辑会重复执行（日志里那一串"已还原 4 个遮挡窗口"就是它）。
- **闸门必须是否决性的闸门**：只打印"距开机 636 分钟"却不改变结论，等于没有闸门（B20）。凡是"这次算不算数"的判断，都必须落到退出码上。
- **判据必须能区分它声称区分的两件事**（B18 的一句话总结）。数不到 ≠ 不存在：Win11 的托盘溢出区收起时子元素不在 UIA 树里；反过来 shell 被强杀后 UIA 里会留幽灵按钮。所以分两层：硬口径只数任务栏带，数到 0 才展开溢出区 peek 一次，四态报出来。
- **测"哪一份"就要用哪一份的路径问它**：日常副本在 `%LOCALAPPDATA%`、构建产物在 `dist\`，产品按属主 exe 校验实例（F28），所以夹具从 `dist\` 发 `--status` 会正确地拿到"未运行"，字段看起来像"凭空消失"（B19）。先按进程的 `Path` 退掉在场那一份，再起要测的这份。
- **对照数据不利的观测量要加静默对照，而不是调阈值**：explorer 侧句柄/私有内存同机四次读数 -14 / -4 / ±0 / +37，绝对阈值对它没有意义。加了 90 秒静默对照当噪声地板；**规则改在看过数据之后、方向是变宽松，所以绝对阈值告警一律保留成"注"一起打印**。
- **"桌面空白点"必须现扫并排除图标**：只验根窗口是 `Progman/WorkerW` 不够——图标布局会变，写死的候选点会失效（B17）。要求该点及四周 24px 的命中测试都不含 `ONITEMICON`/`ONITEMLABEL`。
- 需要"桌面真空出来"的断言：先 `COV::MinimizeCovering()` 临时最小化遮挡窗口、收尾（含异常路径）还原；挑空白点之前先把图标显示出来。
- **要重启/等外部事件才能收口的验证，别要求用户专门腾一次**：夹具要能搭自然事件的班车——期望值取自被测程序自己落盘的状态（这里是注册表 `IconsVisibleOnExit`），而不是靠我事先摆现场。
- **夹具必须自带「这次算不算数」的闸门**：`verify-real-boot.ps1` 距开机超过 30 分钟给 `INCONCLUSIVE`（退 3）；`verify-icon-guard.ps1` 造不出落点给 `SKIP`（退 4）；`verify-shell-race.ps1` 前提造不出来给 `PARTIAL`（退 2）。都不许降级成 PASS。
- **前置条件要在动作前后各验一次；状态归因必须有行为证据；测量口径必须前后一致；结论文案不许超过数据**（报告 §8 那四条）。
- **别把机器留在"等着被验证"的特殊状态还不说**：交付态写在上面「你机器现在的状态」。
- 工具脚本一律 UTF-8 **带 BOM**（PS 5.1 无 BOM 按 ANSI 读，中文注释会直接把脚本解析炸），**且只能有一个 BOM**（`EF BB BF` 写两遍会让首行变成 `?# 注释` 并报错，本轮 11 个文件中招）。
- 给子进程加 `-WindowStyle Hidden` 会把它第一个 WinForms 窗口一起压成不可见。
- 用 python 批量改文档时：**`str.find()` 返回 -1 会把切片边界变成"从文件末尾倒数"**，一次编辑就能吃掉半篇（本轮 RESUME.md 被截到 2.5 KB 后重写）。所以切片边界一律先 `assert 0 <= idx < len(s)`，改完 `wc -c` 对一下尺寸。

## 重启验证已完成（22:14 现场）

用户重启后跑 `tools\verify-real-boot.ps1`，退出码 0 / PASS，证据 `run-real-boot-POSTREBOOT2.log`，已写进 `TEST-REPORT.md` F22 与 §4。
桌面图标已放回 `visible`（`--show`），机器回到交付态。
回来如果只想让我接手，说：**继续桌面图标开关 第9段**。
