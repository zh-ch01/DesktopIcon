# 场景路由记录：为什么是这三件技能

- **路由时刻**：2026-09-30
- **入口技能**：`architecture-visualization:explore`（路由器）
- **用户问题**：这个仓库的**当前架构是什么**，以及**谁依赖谁**。不是"能不能跑"，不是"好不好"，不是"要怎么改"。

## 路由判断

| 判据 | 结论 |
| --- | --- |
| 视图状态 | **纯当前态**。用户没有表达迁移意图，代码里也没有 target 标记 |
| 是否业务应用 | **否**。桌面工具utility，没有领域实体、没有租户/权限/生命周期状态机，所以**没有**加载 `business-application-fitness.md` |
| 主技能 | `system-modeler` —— MECE 边界里"结构与边界"归它 |
| 基础层 1 | `c4model` —— 需要可维护的 C4 语义源（context / container / component 三视图），Structurizr DSL 是这一类的规定载体 |
| 基础层 2 | `graphviz` —— 用户同时要依赖图。52 条边、18 条出进程的密集关系网不属于 C4，DOT 是它的规定载体 |
| 明确**没**选 | `flow-visualizer`（问的是结构不是流动）、`dependency-impact-analyzer`（没提"改 X 会影响谁"）、`deployment-topology-analyzer`（单机单进程，没有拓扑）、`risk-quality-reviewer` 与 `evolution-planner`（没要评审、没要迁移）、`architecture-communicator`（读者是改代码的人，不是干系人）、`drawio`（没要可编辑交付）、`architecture-health`（本轮是**建**模型不是验已有模型，但它的两个判据被我内联进闸门了） |

**为什么不是只选 `system-modeler` 一个**：c4model 的 SKILL 自己就写明"只在父容器明确时才生成 component 视图，否则退回 container 视图 + graphviz 依赖图"；本例父容器明确（单 exe），但依赖网密度超出 C4 承载力，所以两个基础层都要。

**MECE 检查**：结构 = `system-modeler`；密集关系 = `graphviz`；C4 源 = `c4model`。三者没有互相覆盖的职责，也没有把"流动"混进"结构"。

## 门禁加载情况

路由器要求的三份共享参考全部读过：`architecture-contract.md`、`architecture-evidence-model.md`、`diagram-output-formats.md`。写 Structurizr DSL 前额外读了 `structurizr-canvas-pipeline.md`。**没有**读 `business-application-fitness.md`（判由如上）、**没有**读 `drawio`/`diagram-delivery-recipes.md`（不需要可编辑交付）。

## 取证方式（以及它为什么必须这样）

- 8 个 `.cs` 共 1,811 行。**我完整读过的**：`Settings.cs`(72)、`Autostart.cs`(101)、`DesktopIconToggle.csproj`(33)、`app.manifest`(27)、`README.md`(124 行，全读)。**只按行窗读过的**：`Program.cs`（113–192、260–352 两段，共 172 行）、`Desktop.cs`（88–97）、`IpcWindow.cs`（13–16、24–34、41–43、48–58）、`DesktopGestureHook.cs`（20–25、50–53、85–91）、`Native.cs`（20–36、38–45、286–293、366–382、433–439）。剩下的大面积取证派了两个只读 `Explore` 子体并行跑：一批 `Native.cs` + `Desktop.cs`，一批 `Program.cs` + `IpcWindow.cs` + `TrayIcon.cs` + `DesktopGestureHook.cs`。
- **子体报告是线索，不是证据。** 所以模型里每一条 `file:line` 都附一个 anchor token，由 `verify_refs.py` 现场回读真文件真行做子串匹配。这不是装饰：第一次跑就否决了 **16 处引用 / 11 个不同位置**，主因是 `[DllImport]` 属性行与函数声明行相邻导致的一格偏移（`Native.cs:41` 对 `:42`、`Native.cs:289` 对 `:290`、`Native.cs:368` 对 `:370`、`Native.cs:378` 对 `:379`、`Native.cs:436` 对 `:437`），另有"用常量名而非字面量"的间接寻址（`Desktop.cs:61` 的 `ListViewClass` 对 `Desktop.cs:18` 的 `SysListView32`）。
- 正文文档的引用**也纳入闸门**（`evidence.json` 的 `prose` 段，28 条，覆盖全部 4 份 markdown），因为"出处举证"不该只对下游生效、不对自己生效。
- 依赖图**从证据模型生成**（`gen_dot.py`），杜绝手抄导致的漂移；`cross_check.py` 再把 DOT、DSL、四份 markdown 的每个 `file:line` 反查回 `evidence.json`，并校验节点集合、边集合、边端点双向相等。

## 交付形状对照（`architecture-contract.md` 规定的标准形状）

| 契约要求 | 实际产物 | 偏差说明 |
| --- | --- | --- |
| `<view>.md` | `system-model.architecture-understanding.md` | 命名按 c4model 的 `architecture-understanding` 变体 |
| `<view>.dsl` | `system-model.structurizr.dsl` | —— |
| `<view>.evidence.md` | **未单独产出**，由 `evidence.json` 承担 | 有意为之：人读的 evidence 索引会和第二真源漂移。契约要求的是"可追溯"，机器可读 + 闸门否决比第二份 Markdown 更硬。`dependencies-summary.md` 里给了反查方法 |
| `<view>.summary.md` | `system-model.summary.md` + `dependencies-summary.md` | 前者是产物清单与一页汇报，后者是 graphviz 技能要求的 `<name>-summary.md` |
| `scenario-route.md` | 本文件 | 路由器 Artifacts 段列出的四项之一；`architecture-plan.md` / `architecture-evidence-plan.md` / `artifact-summary.md` 的内容被并入本文件与 `system-model.summary.md`，没有另开三份重复文件 |

**图判读的一条偏离**：`graphviz` 技能要求"大图必须包含过滤或分组说明"。我给的是"按簇过滤，不要按边过滤"+ 颜色语义表，写在 `dependencies-summary.md` 开头，不在 `.dot` 文件里画第二张过滤版。

## 闸门

| 命令 | 否决什么 | 本次读数 |
| --- | --- | --- |
| `python verify_refs.py` | 每条 `file:line` 是否真的存在、行号是否在范围内、anchor 是否真的在那一行；引用/节点 id 的完整性；`current` 态节点的最低置信度 | **170 / 170 通过**（24 节点、52 边、28 条正文引用，读 11 个文件），4 个负控制全部拦住 |
| `python cross_check.py` | DOT / DSL / 全部 markdown 里每个 `file:line` 必须已在证据模型中验证；DOT 的节点集与边集与证据模型双向相等；边端点一致；每条边的引用不得串用别人的；DSL 必须覆盖全部组件 | **144 个已验 pair：dot 102、dsl 68、4 份 markdown 合计 146 条引用全部可反查**，7 个负控制全部拦住 |

两个闸门都**扫到 0 条即失败**（零分母不算通过），也都自带注入型负控制——判据如果连"故意做红"都抓不住，它自己就先被判失败。
