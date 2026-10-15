# `dependencies.dot` 判读、发现与后续动作

- **这张图回答的问题**：`DesktopIconToggle.exe` 的每一部分依赖谁，其中哪几跳跨出了自己的进程。
- **规模**：24 个节点、52 条边、6 个分簇、`rankdir=TB`（竖排，因为要在 Canvas 里读，横条会跑出视口）。
- **它是生成的，不是手画的**：由 `gen_dot.py` 从 `evidence.json` 产出。**手画是行号漂移的来源**，所以这条路径干脆切断。
- **为什么不装在 C4 里**：52 条边、18 条出进程、4 条协议族不同的依赖网，C4 的 component 视图放不下也不该放。C4 只留结构，密集成网交给 graphviz。

## 怎么看（颜色即语义）

| 视觉 | 含义 | 数量 | 典型 |
| --- | --- | --- | --- |
| **红色粗边** | 跨进 **explorer 的进程**：窗口命令、跨进程内存、跨进程消息 | 5 条加粗 | `Desktop.cs:91` 的 `ShowWindowAsync`；`Desktop.cs:202` 的 `VirtualAllocEx`；`Desktop.cs:165` 的 `LVM_SUBITEMHITTEST` |
| **虚线红** | 不是普通调用：异步投递、进程间发现、只读诊断 | 3 条 | `e.cli-server-discover`（类名+标题+属主 exe 三重校验）、`e.status-diag` |
| **绿色** | **守工时预算的守卫**：节流、并发闸、有界定时器、会话末落盘 | 5 条 | `e.gesture-throttle`（100 ms）、`e.gesture-inflight`（并发 1）、`e.bootrestore-timer`（2000 ms × 10，必拆） |
| **灰实线** | 进程内方法调用 | 17 条 `in-process call` | 各组件到 `Native` |
| **自环（3 条）** | 时序守卫，不是依赖 | 3 条 | 见绿色那行；C4 语义里它们本该被省略，这里留着是因为它们是这个程序的设计中心 |

分簇：`Actors` / `System boundary`（一份 exe 的两个身份）/ `In-process components`（8 个文件 + 嵌套的 `RemoteBlock`）/ `Win32 subsystem`（4 个 DLL）/ `Explorer (foreign process)` / `HKCU registry`。

**要过滤时按簇过滤，不要按边过滤**：边上的 label 第一段就是 `evidence.json` 里的 edge id，任何一条断言都能反查回 JSON 再反查回代码行。

## 从图上读出来的五条结论

1. **`Native` 是全系统唯一的接缝**：入边 7（除自己外每个组件都指向它），出边 5（4 个 DLL + 给 `Program` 提供协议常量）。业务代码里搜不到 DLL 名，`README.md:116` 就是这么规定的。要换 API 或加 Win32 调用，改动面固定在 `Native.cs` 一处。
2. **真正的效果只有一条边**：`Desktop → Explorer 桌面窗口树` 上的 `ShowWindowAsync`（`Desktop.cs:91`）。整张图 52 条边，能改变用户可见世界的就那一条，其余全是为它服务的前置判定、守卫、注册、自证。**这条边的失败模式是"没反应"，不是"崩"**，所以排查只能靠 `--status` 的分级读数，不能靠退出码。
3. **`Program` 是全图最大的聚合中心**：出边 14、入边 5，同时是入口 / argv 分派 / 消息循环 / WndProc / 托盘菜单 / 手势判定 / 开机复原。35.7% 的代码在这一个 646 行的文件里。图上看不出来它"该被拆"，但它是任何一个改动的必经之地——**改这个程序时的注意力应该集中在这里**。
4. **一层跨进程内存借用被画成了独立节点**：`RemoteBlock`（`Desktop.cs:197`、`Desktop.cs:202`、`Desktop.cs:213`、`Desktop.cs:216`）。它藏在 `Desktop.cs` 里面，但架构上它是本系统里唯一"在别的进程地址空间里分配并读写内存"的东西，风险等级和 `ShowWindowAsync` 同级，所以不该被文件边界掩盖。
5. **`Desktop → Settings` 是一条反向侧击**（`Desktop.cs:86`、`Desktop.cs:106`）。持久化"上次可见状态"的責任不在编排者 `Program`，而在下层 `Desktop`。这是图上唯一一条"底层组件横向写配置"的边。**为什么合理**：状态真正改变的时机只有 `Desktop` 自己知道（切换是幂等的，`IsWindowVisible` 相同就不动它），把落盘放到调用方就会漏掉从命令行、从托盘、从开机复原进来的三条路。**代价**是 `Desktop` 不再是一个纯窗口层工具，它现在有了副作用。

## 图上看不见、但必须知道的风险

**最该改的那条依赖不在代码里。** 这个程序 NuGet 依赖数为 0（`DesktopIconToggle.csproj` 里没有任何 `PackageReference`），供应链面基本是空的；但它对 explorer 有一份**隐性契约**：四个窗口类名字符串 `Progman` / `WorkerW` / `SHELLDLL_DefView` / `SysListView32`（`Desktop.cs:15`、`Desktop.cs:18`）。没有版本协商、没有契约测试、没有运行期校验。README 的判断是从 XP 到 Win11 24H2 都稳定，失效表现为"没反应"而不影响系统（`README.md:81`）。

依赖图把它画成一条普通箭头。**"脆弱"是因为它是字符串常量，不是因为它是跨进程调用**——这是"代码依赖图不等于架构风险图"的现成例子，别把图当风险清单读。

## 后续动作（按性价比排，不含自动执行）

1. **要动多屏机器之前**，先跑 `tools/test-gesture.ps1` 与 `tools/verify-icon-guard.ps1` 取证。README 承认两处未实测（`README.md:84`）：① `LVM_SUBITEMHITTEST` 客户区坐标在负原点副屏上的语义有两种解释；② 可见性判定与切换以 `FindIconLayers()` 的第一层为基准（`Desktop.cs:70`、`Desktop.cs:88`），两屏状态不一致时可能判反方向。**本机单屏 1920×1200，我无法取证，也不建议在没有证据时把它改成 `layers.Any(...)`**——README 自己就拒绝过一次这种"改完更像对的但依旧没证据"的修法。
2. **把两个渲染器补上再谈视觉验收**：本机没有 `dot`，也没有 `structurizr` CLI（只有 `java` 在 `D:/z/dev/sdk/jdk17/bin/java`）。现在两张图的语法由我按规范写、引用由闸门验，但**渲染成功没被证明过**。要 SVG/PNG 交付需要先装 Graphviz。
3. **`Autostart.cs:70` 与 `Autostart.cs:74` 两个 XML `summary` 叠在一起**，第一个（讲 `SelfHeal` 的重写条件）被第二个（讲 `Unquote`）顶成悬空注释。行为无影响，纯文档注释瑕疵。要改的话是删一个块，属于他自己能顺手做的小事，我不动代码。
4. **想要"验证拓扑"是另一次路由**：`tools/` 下 5 个脚本（`test-gesture.ps1`、`verify-icon-guard.ps1`、`verify-decoy-window.ps1`、`deploy-local.ps1`、`make-icon.ps1`）和 `install.ps1`/`uninstall.ps1` 的自证链条本轮没建模——它们是测试与发布链路。要画就用 `deployment-topology-analyzer`，或者 `flow-visualizer` 画"发布 + 反证"的流程。
5. **这份模型该在什么时候重跑**：`.cs` 文件行数变了、`Desktop.cs` 的类名常量变了、`Native.cs` 的 `DllImport` 数量变了，就重跑 `verify_refs.py`。它一定会红，因为行号被搬走了。红点是**正常信号**，不是工具坏了。

## 这份交付**没有**做的事（免得你以为它做了）

- 没跑过 exe、没读 live 进程、没执行 `--status`。README 里的实测数字（私有内存 6.3–7.1 MB、空闲 30 s CPU 0 ms、冷启动 279–455 ms、双击到消失 239–306 ms）是我**从 `README.md:7`、`README.md:8` 复述**的，没有复测。
- 没读 `TEST-REPORT.md` 和 `RESUME.md`（读取被权限判定拦下）。README 引用的 F22 / F28 / B15′ / B18 / F30 等编号我**没有核对**，所以模型里也没有把它们当作证据引用。
- 没做架构评审、没给重构方案、没评估质量属性。那是 `risk-quality-reviewer` / `evolution-planner` 的活，本次路由里没有它们，也不该有。
