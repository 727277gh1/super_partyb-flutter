# 产品边界与可运维性

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。有意不做的端点族、i18n 决策、诊断日志导出、reminder 准入重构、
桌面端可诊断性（本地文件日志 / 会话标记 / 悬浮窗回滚 / 默认同步目录）。

> 编号（`§6.x` / `§5.x` / `[§7](build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](README.md)。

---

### 6.9 有意不做的管理面端点族（**是决策，不是缺口**）

Go API 还有一批**运营 / 排障面**端点，Flutter 客户端**有意不实现**：

| 端点族 | 内容 |
|---|---|
| `/api/api-keys` | 用户自助 API Key 的签发 / 吊销 / scope |
| `/api/users/:user_id/variables`、`/api/admin/variable-defs` | 用户变量与变量定义 |
| `/api/memories` | 记忆条目 CRUD（按 API Key scope 读写分级） |
| `/api/skills` | 技能注册 / 启停（服务端扫描 `SkillsDir`） |
| `/api/router-preferences` | 决策链分层配置（catalog / editable / bands） |
| `/me/im-bindings` | IM 绑定（代理 idp） |
| `/api/admin/llm-providers` | 管理员 LLM 线路 CRUD（含密钥引用） |
| `/api/admin/runtime-settings` | 管理员运行时配置（Admission / turn 生命周期） |
| `/api/tool-agents`、`/toolsets`、`/:name/invoke[/stream]` | Tool Agent 列表 / toolset 元信息 / 直接调用（含 SSE） |
| `/api/chat/inbox-messages` | group 级收件箱消息列表（webapp 只在 debug 页用） |
| `workspace-sync` 其余 6 个（`files` / `local-files` / `files/content` / `ignored-paths` / `ignored-paths/remove` / `ufs-download`） | 浏览器侧 workspace 视图与黑名单管理（客户端只用了 `ufs-upload`） |
| `/chat/groups/:id/auto-schedules` | 列出 pending 自动续跑排程（**含停用入口**，见下「逐项依据」） |
| `/chat/groups/:id/sessions/managed` | 创建 managed session（**死端点**，见下「逐项依据」） |

**为什么不接**：这些不是「聊天」的组成部分，而是**配置与运维**面——签发密钥、
调 LLM 线路、改准入参数、绑 IM 账号。它们的承载点是 **webapp dashboard**
（`super_partyb/apps/webapp`），那里有完整表单、校验与确认流。客户端（桌面 /
移动）是**使用**面：发起对话、看时间线、同步交付物。

**判据**（避免后来者把「有意不做」读成「漏了」）：

- 只影响**服务端配置 / 凭据**，且改错会波及所有用户 → 留在 dashboard；
- 属于**用户自己的一次对话行为**（发消息、取消 turn、反馈、目标、交付物）→ 客户端做。

**对照**：`/api/agents`、`/api/habits`、`/chat/*`（含 goals / confirmations /
feedback）、`/me/preferences`、`/users/:user_id/chat/*` 虽是 CRUD，但直接决定
「我这次的对话怎么跑」，故客户端**已实现**（见 §5.2 前缀表与
`packages/spb_api/lib/src/*_api.dart`）。

#### 6.9.1 非端点族的「有意不做」

上表是**端点族**层面的取舍。另有几项是 UI / 能力层面的，同样**是决策不是缺口**：

| 项 | 理由 |
|---|---|
| 对话页附件 / `file_context` | Go 的 `sendChatToAgentRequest`（`chat_stream.go:46`）只有 `agent_id` / `input` / `request_id` / `group_id` / `agent_type` / `options` / `routing`，**没有**附件字段。带附件的无归属入口走 `/me/quick-capture/enqueue`（见 [§6.7](chat.md)），不是对话页。受「Go API 一行不改」约束，补齐需服务端先加字段。 |
| 移动端打开已下载文件 | 移动端注入 `NoopDesktopCapabilities`，`openFile` / `revealPath` 恒 false。要真正打开需引入 `open_filex` / `share_plus` + Android FileProvider 配置 + 真机验证（模拟器在本机不可用，见 [§9](../development.md)）。当前退化为「只读浏览 + 下载」。 |
| 桌面端「通知订阅」区块 | 该区块（`NotificationSubscriptionsCard`）的语义是**微信小程序订阅消息额度**（`miniapp_subscriptions` 表 + `wx.requestSubscribeMessage` 的配额消耗模型）。桌面端没有小程序运行环境，展示它无法兑现；故只在移动端装配（`settings_page.dart` 按 `loadNotifications` 是否注入决定展示）。是否给桌面端一个只读「额度查看」视图需产品确认。 |
| P2 端点族：`fork` / `canvas` / `plan-import` / `decisions` / `file-evolution` / `semantic-search` | 本轮范围外。它们是**考古 / 分析 / 分叉**类能力（`chat_ext.go` 的 `POST /turns/:turn_id/fork`、`GET /groups/:group_id/canvas`、`POST /groups/:group_id/plan/import`；`ext_routes.go:530` 的 `/groups/:group_id/decisions`；`misc_extra.go:649` 的 `file-evolution` 与 `:650` 的 `semantic-search`），承载点是 webapp 的分析视图。留待后续轮次。 |
| 语义 / 图谱搜索四项面板（`SemanticSearchPanel` / `GraphSearchDialog` / `FileEvolutionPanel` / `DecisionEvolutionPanel`） | 同上——它们正是 P2 端点族的 UI 载体。客户端已有**关键词**搜索（`ChatApi.search` / `searchMyTurns` → `SearchPage`），语义/图谱是**另一种检索方式**而非「搜索缺失」。且语义搜索的数据面为空（`chat_groups` = 0）、两个「演化」面板的数据源已停写——详见 §6.9.6 |
| `SkillPanel`（`dashboard/agents/[id]/chat`） | 属管理面，已被 §6.9 的 `/api/skills` 一行覆盖，无需重复实现 |

#### 6.9.2 未接端点族的逐项依据（issue #11 收口）

上表把「不接」的端点族并排列出。本节记**逐项依据**——尤其有两项，issue #11
的原始判断与实测不符，照抄会把错误的理由固化下来。

| 项 | 结论 | 实测依据 |
|---|---|---|
| `tool-agents` 族的 `listToolsets` | ❌ 不接 | 仅 `dashboard/agents/create` 与 `agents/[id]/edit` 使用——确属**管理面** |
| `tool-agents` 族的 `invoke` / `invoke/stream` | ❌ 不接 | **全仓零调用者**（webapp 自己也没接）——服务端为将来留的接口 |
| `tool-agents` 族的 `listToolAgents` | ⚠️ **不是**「只在 dashboard」 | 它喂给 `ChatInputArea`（`chat/[groupId]/page.tsx:638`），选中后经 `setToolAgentForGroup` + `startNewConversation` 以 `agent_type=tool_agent` 发起会话。**这是聊天面行为**，只是客户端已有 `AgentSwitcher`（`/api/agents` + `sessions/switch`）覆盖了「换 agent」这一诉求，且 `switchGroupAgent` / `sendMessage` 都不发 `agent_type`——补齐需两端都动，故本轮不接 |
| `inbox-messages` | ❌ 不接 | webapp 唯一消费者是 `workbench/[groupId]/debug/page.tsx`（排障），属**逐条消息排障**而非「这一轮在干什么」（后者已由 [§6.54](ui.md) 的「动态」面板回答）。客户端已有**用户级** `PendingMessagesBar`（`/users/:uid/chat/messages/pending`），覆盖了「我的消息还卡着吗」这个真实诉求 |
| `workspace-sync` 其余 6 个 | ❌ 不接 | 5 个只出现在 debug 页；`files/content` 服务 webapp 的**本地 workspace 文件预览**（`file-preview.ts` 的 `!file.fileId && file.filePath` 分支）——客户端时间线的 `AgentFileItem` 本就带 `ufsFileId`，没有「无 id 的本地 workspace 文件」这个概念；`ufs-download` 只在 `group-chat.ts:1308` 内部编排。**客户端的交付物同步走 `UfsApi.listFiles` + `download`（另一条路径），这一族不是「同步缺失」** |
| `auto-schedules` | ✅ **该接（另开 issue）** | issue #11 称「无 UI 调用者」——**与实测不符**。`listGroupAutoSchedules` → `WorkbenchGroupDetailDialog.tsx:160`，`stopGroupAutoSchedule` → 同文件 `:221`，而该 Dialog 由 `chat/[groupId]/page.tsx:588` 的按钮打开，即**聊天页**。语义是「看 pending 排程 + 一键停用」。客户端**已**渲染 `ScheduleCreatedItem`（「将在 30 秒后自动继续」）却**无法查看与停用**——用户看得见它在跑，却没有刹车。⚠️ 分两部分：**停用**（`POST /chat/groups/:id/auto-schedule/stop`，`chat_ext.go:100`）实现完整（按 `policy_json.meta.group_id` 过滤 + `requireOwnedGroup`，返回 `{group_id, disabled_count}`）；**列表**（`admin.go:103`）**静态读码存疑**——handler 取 `c.Query("agent_id")` 而 webapp 只传 `limit`，SQL 又是 `WHERE agent_id = ?`，即实际是 `WHERE agent_id = ''`，可能恒返空（handler 注释自称「Python 通过 group_id 查 agent 再查 schedules」，Go 移植似丢了那一步）。客户端只依赖**停用**即可；列表需服务端先修 |
| `sessions/managed` | ❌ 不接（死端点） | `createManagedChatGroupSession` 在 `group-chat.ts:1365` 是**非 export** 的函数，全仓零调用者。issue #11 此处的判断正确 |

**「有意不做」与「未做」的区分**：上表除 `auto-schedules` 外全部是**有意不做**
（不是缺口）。`auto-schedules` 是唯一实测出的**真缺口**，已另开 issue #13 跟踪。

#### 6.9.3 webapp 十个分析/管理面板的逐项结论（issue #12 收口）

issue #12 登记了 webapp 有而客户端没有的 10 个面板。逐项核实后的结论——
**其中一项（`WorkbenchBacklogCard`）客户端其实已经做了，只是载体不同**：

| 面板 | 面 | 结论 | 依据 |
|---|---|---|---|
| `WorkbenchBacklogCard` | workbench | ✅ **已实现（载体不同）** | 客户端 `PendingMessagesBar` 消费 `/users/:uid/chat/messages/pending`，同样做「pending 收件箱 + 单条撤销 + 批量合并发送」（webapp 的 `use-pending-messages.ts` 是同一个共享 hook 语义）。它在对话页输入区上方，不在侧边栏——与 [§6.10](architecture.md) 的载体差异同一取向 |
| `SemanticSearchPanel` / `GraphSearchDialog` / `FileEvolutionPanel` / `DecisionEvolutionPanel` | 聊天 | ❌ 不接（本轮） | 对应 P2 端点族。**决策依据不只「属 P2」**——还有三条生产实测：客户端搜索面已闭环（载体不同）、语义搜索的数据面为空（`chat_groups` = 0 行）、两个「演化」面板的数据源（`chat_decisions` / `file_versions` / `replies`）**在 Go 时代已停写**。⚠️ 嵌入链路本身**是通的**（`bore` 隧道 + 共享凭证），别误记为「未接嵌入服务」。详见 §6.9.6 |
| `WorkbenchGroupCanvas` | workbench | ❌ 不接 | 是**独立路由** `/workbench/[groupId]/canvas`；客户端没有 workbench 路由概念（`SpbRoutes` 只有 chat / search / settings / confirmations 等） |
| `PlanImportPanel` | workbench | ❌ 不接 | 计划导入是 goal 系统的**批量录入**入口，属 webapp 分析视图 |
| `WorkbenchNotificationCenter` | workbench | ❌ 不接 | 「系统通知 / 确认请求 / 新消息提醒」聚合器。客户端已有各自的原生载体（确认页、待处理栏、SSE 实时流），再加一个聚合层需先有产品需求 |
| `SkillPanel` | dashboard | ❌ 不接 | §6.9 已覆盖 |

**关于 `DashboardRenderer` 与 #8 的 `spec` / `dashboard` / `map`**（issue #12 决策点 1）：
这三种渲染器**不是一个决策**，不要捆绑——

| 类型 | 客户端现状 | 结论 |
|---|---|---|
| `spec` | **已有渲染器**：`SpecUiCard` + `parseSpecUi`，覆盖基础卡片、布局、表格和图表 | ✅ 文件预览、状态快照及真实看板已接通，范围见 §6.9.4 |
| `dashboard`（网格格式） | ✅ **已闭环——不做**。真实 `dashboard.spec.json` 走的是 `spec` 路径，网格格式**无已知生产者**（详见下节） | ✅ 不做 |
| `map` | ✅ **已实现**（issue #12）：`MapSpecCard`（`CustomPaint` 归一化轨迹图）+ `parseMapSchema` / `MapProjection`（`spb_domain`）。**零新依赖**——详见下节 | ✅ 已完成 |

故 issue #12 的三个决策点**已全部闭环**（`spec` / `map` 已实现，`dashboard` 网格格式
无生产者，四项检索面板有生产实测依据）。三种渲染器与两个实测真缺口的去向：

| 类型 | 去向 |
|---|---|
| `spec` | 已拆到 **issue #14**（小活，需补 schema 提取）——⚠️ 但 #14 **引入了一个回归**，见 issue #27（**已修**） |
| `auto-schedules` | 已拆到 **issue #13**（实测出的真缺口） |
| `map` | ✅ **已完成**（issue #12）：`spb_domain` 的 `parseMapSchema` / `MapProjection` + `spb_features` 的 `MapSpecCard`，接入 `agent_file_preview.dart`（`MapTextPreview` 分支）与两端 router（`openMapMarker` → 高德外链）。**零新依赖** |
| `dashboard`（网格格式） | ✅ **不做**（已闭环）。真实 `dashboard.spec.json` 走的是 `spec` 路径（客户端已支持，见 #14 / #27）；网格格式**无已知生产者**——全仓搜该形状只命中一个**测试用例**（`mapspec_test.go:84` 的负例） |

#### 6.9.4 `dashboard` / `map` 的真实成本（**核实后修正早期判断**）

`#14` 的代码注释曾写「`dashboard` / `map` 需**各自的渲染技术栈**」「`map` 需
**底图**」——**与上游实测不符**，会把小活估成引 SDK 的大活。核实结果：

| 判断 | 实测事实 | 证据 |
|---|---|---|
| 「`map` 需底图 / 渲染技术栈」 | ❌ **错**。webapp `MapSchemaRenderer.tsx` 自称「一期轻量实现：**SVG 归一化轨迹图（无底图、无高德 JS key 依赖）**」，实现是 ~25 行投影数学（经纬度 → SVG 坐标，等比缩放 + 居中）+ marker 列表 + 「在高德地图打开」外链。**没有 SDK、没有瓦片、没有密钥** | `super_partyb` `apps/webapp/src/components/features/workbench-ui/MapSchemaRenderer.tsx:6`、`buildProjection` `:43` |
| 「`dashboard` 需重型渲染组件」 | ⚠️ **要分两个渲染器**。① `DashboardRenderer.tsx`（`{type:"dashboard",components:[{type,layout}]}` 网格）只认 **3 个**类型：`stat-cards` / `table` / `chart`，共 **364 行**；② `JsonUiSchemaRenderer.tsx`（`{root,elements}`，即本客户端的 `spec`）。Web 的 ② 使用 `recharts`；Flutter 的六类图表以 `CustomPaint` 实现，不新增依赖 | `DashboardRenderer.tsx:76/124/297`、`package.json` 的 `recharts` |
| 「`dashboard.spec.json` 是网格格式」 | ❌ **错**。上游**真实产出**的 `dashboard.spec.json` 是 **②的 `{root,elements}` 形状**（`Stack`/`Grid`/`Metric`/`Chart`/`Alert`/`Table`） | `super_partyb` `apps/miniapp/src/lib/spec-demo-fixtures.ts` 的 `realDashboardDoc`（注释自称「bcc 工作区实际产出的 dashboard.spec.json 回归基准」）；生产者是 `agent-skills` 的 `json-spec-builder`（其 SKILL.md 明写产出 `root`/`elements`） |
| 网格格式有生产者吗 | **未找到**。全仓搜 `{type:"dashboard", components:[...]}` 只命中一个**测试用例**（`mapspec_test.go:84` 的「非 map 类型」负例） | `super_partyb` `apps/go-api/internal/workers/agentfilerender/mapspec_test.go:84` |

**Flutter spec 的当前范围**：

- `Stack` / `Row` / `Column` / `Grid` 按可用宽度和字号换行；`Table` 支持列别名、横向滚动、分页及结构化单元格。
- `Chart` 支持 line / area / bar / pie / scatter / candlestick；支持 `data`、`dataKey`、多系列、X 键推断与 OHLC 别名。缺失值留空，K 线按实际价格缩放，桌面悬停和移动点击可读数值。
- `$state` / `$bindState` 递归读取初始快照，支持 JSON Pointer 转义、数组索引和静态 `visible` 条件。没有声明 `series` 的真实指数看板按数值列推断系列。
- 文件预览仍只读；表单双向写入、`setState` / `watch` 和通用动作执行不在这一实现范围。

解析和数值范围在 `spb_domain`，布局及 Canvas 绘制在 `spb_features`；两端共用同一入口，不改 Go API。未知容器继续递归、未知叶子保留占位（延续 issue #27），不因新增组件丢失其他内容。测试用真实看板样例覆盖 360/900px、表格分页、六类图表与状态绑定，golden 锁定布局和绘图；真机触摸及桌面显示效果仍需设备验收。

#### 6.9.5 `map` 已落地（issue #12）：实现要点与三个「不要重做」的坑

`map` 的核实结论（§6.9.4）已兑现为代码：`spb_domain` 的 `parseMapSchema` /
`parseMapPolyline` / `MapProjection` + `spb_features` 的 `MapSpecCard`。

**分层归属**（按 §4 的判据）：解析 + 投影数学在 `spb_domain`（纯 Dart，可无
图形环境测）；`CustomPaint` 绘制在 `spb_features`。投影数学是**正确性核心**
（错一点整张图就偏），必须能在纯 Dart 测试里逐点断言。

| 要点 | 结论 | 为什么 |
|---|---|---|
| 底图 / SDK | **不做** | 上游 `MapSchemaRenderer.tsx` 自称「一期轻量实现：SVG 归一化轨迹图（无底图、无高德 JS key 依赖）」。归一化轨迹图回答「这些点在哪、相对关系如何」——正是产物要表达的。要看真地图，点一行走高德外链 |
| 坐标顺序 | polyline 是 `[经度, 纬度]` | 高德惯例；`parseMapPolyline` 同时接受字符串形态 `"lng,lat;lng,lat"`（服务端两种都写过） |
| 判定位置 | **只认顶层 `type: "map"`**，不做深度下探 | 与 webapp 一致（`normalizeMapSchema(parsed)`）。若像 `spec` 那样深度扫，「任意 JSON 里嵌了一个 `{type:"map"}` 的配置对象」会被误判成地图 |
| 空壳处理 | `markers` / `routes` 全空（或无坐标）→ `parseMapSchema` 返回 `null` | 否则预览框会变成**一张空图**——比显示原文差 |
| 缺字段 | 距离 / 耗时 / 模式标签缺失时**不显示**（不写「0 米」「未知」） | 同 §5.4 的 `schedule_created`：没有证据就不编造 |
| 外链 | `amapMarkerUrl` = `uri.amap.com/marker?position=lng,lat&name=…`，经 `AgentFilePreviewCallbacks.openMapMarker` 上抛 | URL 拼接留在**装配层**（同 `openExternal` 的既有约定）：页面只收集意图，不掌握第三方 URI 形状 |
| 无障碍 | 轨迹图是 `CustomPaint`，对屏幕阅读器**完全空白** → 必须给语义标签（「地图轨迹图，公交路线，2 个地点，1 条路线」） | 同 issue #24 对 `SpecUiCard` 进度条的判据：自绘区域必须自己说明「这是什么」 |
| 列表封顶 | 地点列表 `maxHeight: 180` + 内滚 | 对齐 webapp 的 `max-h-[180px] overflow-y-auto`。不封顶时 200 个地点会把卡片撑到几千像素——作为**内联卡片**会直接溢出（实测 50 行 = 1000px，RenderFlex overflow） |

**投影的一个有意偏离**（`MapProjection.build`）：以**数据包围盒中心**为基准施加
跨度下限，而不是 webapp 的「从 `min` 角固定」。两者在跨度**未被抬高时完全等价**
（`center - span/2 == min`），故真实多点产物逐像素一致；差别只在单点 / 极近点时
——webapp 会把单点画到视口左上角（实测 x=146, y=16 而视口 560×300），看起来像
「范围很大、点在角落」。以中心为基准后单点落在视口正中。

**反向验证**（每条修复都能被对应用例抓住，否则用例是空转）：去掉 map 分支 →
2 条失败；大小写敏感 → 1 条；去掉空壳守卫 → 1 条；去掉列表封顶 → 1 条
（`1000.0 > 180.0`）；`hasAny` 计入 `openMapMarker` → 1 条；失败静默 → 1 条。

**#27 已修**（未知容器下钻 + 保留原始 type 字符串），且修的过程中又发现并修掉
两个**既有**缺陷（都不是 #27 引入的，而是递归下钻路径的前置条件）：

- **渲染层用了扁平子树**：`_SpecElementView` 曾用 `childrenOf`（**整棵子树的
  扁平列表**）当「直接子元素」，而对每个子元素又递归一次 → 深层元素**渲染多次**
  （实测 3 层树的叶子出现 **2 次**）。改用新增的 `directChildrenOf`。
- **渲染路径无环检测**：解析层的 `visited` 只保护 `childrenOf`，**保护不到渲染
  层的递归**。`A→B→A` 两个互相引用的未知容器实测**直接栈溢出**。现在渲染层
  自带祖先集合。

**由此得出的通用规则**：解析层的安全边界（环/深度/悬空）**不自动继承**给渲染层
——只要渲染层自己递归，就必须自带同样的保护。

**有意不做的标记**：10 个面板的逐项去向 = **1 已实现**（`WorkbenchBacklogCard`，载体
不同）+ **8 有意不做**（4 个聊天面 P2 面板 + `WorkbenchGroupCanvas` /
`PlanImportPanel` / `WorkbenchNotificationCenter` + `SkillPanel`）+ **1 已闭环**
（`DashboardRenderer` 网格格式，无已知生产者，按「不做」处理）。`auto-schedules`
（issue #13）、`spec` 文件预览（issue #14）与 `map` 文件预览（issue #12）是三个
实测出的真缺口，与上述 10 项**不捆绑**。

#### 6.9.6 四项检索面板的决策依据（2026-10 生产核实）

§6.9.3 把四项检索面板（`SemanticSearchPanel` / `GraphSearchDialog` /
`FileEvolutionPanel` / `DecisionEvolutionPanel`）记为「不接（本轮）」。
决策依据**不只是「属 P2 端点族」**，还有三条 2026-10 实测出来的事实：

**1. 客户端的搜索面已经闭环（载体不同）。** 客户端有 `SearchPage`，两端已接线：

| 端点 | 客户端方法 | 语义 |
|---|---|---|
| `GET /me/turns/search?q=` | `ChatApi.searchMyTurns` | 跨 group 按**输入文本**搜轮次 |
| `GET /users/:uid/chat/search?q=` | `ChatApi.search` | 按 `input_text` / `agent_id` 搜 |
| `GET /me/turns?days=` | 同页数据源 | 列近期轮次 |

故四项里的「搜索」不是缺口，而是**另一种检索方式**（语义/图谱）。

**2. 语义搜索的数据面是空的——但原因**不是**「未接嵌入服务」。**

⚠️ 先纠正一个容易得出的**错误**结论。静态读码会以为「生产未接嵌入服务」，
但实测**嵌入链路是活的**：

| 层 | 实测（2026-10-11） |
|---|---|
| 启动日志 | `embedding_resolver:true`，且 `chatrouter` **真的调了**嵌入：`POST http://127.0.0.1:43001/v1/embeddings` |
| `43001` 端口 | `bore` 隧道（`bore server --min-port 40000 --max-port 50000`，systemd `bore.service` active）——上游是**远端**嵌入服务 |
| 凭证 | `service_name='embedding'` 的 3 个键均为 `owner_type='shared'`，`EMBEDDING_BASE_URL = http://127.0.0.1:43001/v1`，`secret_ref` / `plain_value` 均有值 |
| 连通性 | 连发 5 次 `POST /v1/embeddings` 均得 **401**（0.15–0.18s）——**服务在，只是无凭据时拒**；说明隧道通、上游在 |
| `embeddings` 表 | 4807 行（`user_message` 3629 / `turn_input` 562 / `reply` 316 / `topic` 300），最近写入 2026-10-09 |

真正的阻碍是**数据面**，而不是链路：

- `recallEntities` 先调 `resolveVisibleGroupIDs`（`misc_extra.go:901`）→ `ListVisibleGroupIDs`
  （`graph_search_manual.go:316`）的 SQL 是
  `SELECT id FROM chat_groups WHERE user_id = ? AND status = 'active'`；
- 生产 `chat_groups` = **0 行** → `groupIDs` 为空 → `recallEntities` **直接返回空
  列表**（不报 503，因为它在开头就 `if len(groupIDs) == 0 { return []semanticHit{}, nil }`）。

即：面板接上去会得到**「搜索无结果」**（而非错误），而这不是客户端的问题。

**3. 两个「演化」面板的数据源在 Go 时代已停写。** 生产库（2026-10-11）：
`chat_decisions` = **0**、`file_paths` = **0**、`file_versions` = **0**、`replies` = **0**。
`replies` 的注释已自述「在 Go 时代不再写入（`ReplyProjector` 停用）」
（`misc_extra.go` 的 `chain` 注释）。故 `DecisionEvolutionPanel` /
`FileEvolutionPanel` 即使接上也是空面板——**无数据可演化**。

**结论**：四项维持「有意不做」。若将来要做，**前置条件是服务端先恢复对应数据
链路**（`chat_groups` / `chat_decisions` / `file_versions` 的写入），而不是客户端先动。
语义搜索本身**不需要**再配嵌入凭证——它已经通了。

> ⚠️ **与 #12 无关的一个生产异常（另行跟踪）**：2026-10-11 实测 bcc
> `/opt/<app>/data/dev.db` 的 `chat_turns` / `chat_groups` / `chat_events` /
> `chat_confirmations` **全为 0**，而 2026-09-27 的备份里 `chat_turns` 有 **3559** 行。
> 该库 2026-10-10 22:54 被一份**备份覆盖**过（`dev.db.bak-before-del-baixiaosheng-
> 20261010T225140Z.db`，两者 md5 不同），而「删除百晓生」的迁移 0040 已在库中
> 记录为已执行。故当前库是一份**缺 chat_* 数据的状态**，而 `topics`（2669）/
> `user_memories`（2290）/ `embeddings`（4807）仍在。⚠️ **影响面**：`SearchPage`
> （关键词搜索）与四项语义/演化面板**都**依赖这些表，故目前均无结果——需在
> `super_partyb` 侧单独排查（本仓库代码不受影响）。

### 6.12 i18n：**当前不做**（决策记录，issue #23）

**结论：客户端暂不接入国际化（i18n），界面文案保持硬编码中文。**

这是一个**决策**，不是缺口。本节存在的意义就是让后来者不必重新论证一遍——
若要推翻，请先读完下面「重新评估条件」并给出满足其中一条的事实。

#### 当前硬编码量（可复核）

```bash
# ⚠️ 下面的数字**会漂移**（随实现自然增长）。以命令实测为准，别把这里当权威
# 数字——与 §6.13 的覆盖率基线同一约定。`tools/check_agents_numbers.sh` 会
# 核对本节的数字（只查「标注了复现命令」的这几处，见 §6.19 的守卫清单）。

# 决策时（issue #23 创建于 f446250）的基线：782
# 当前（HEAD）量：1213
cd packages/spb_features && grep -rhoP "'[^']*[\x{4e00}-\x{9fa5}][^']*'" --include=*.dart lib | wc -l
# <!-- number-check: name=spb_features_hardcoded_zh value=1213 -->

# 全仓（9 个 packages + 2 个 apps 的 lib/）
# 决策时基线：约 1200（未单独记录）；当前（HEAD）量：2312
grep -rhoP "'[^']*[\x{4e00}-\x{9fa5}][^']*'" --include=*.dart packages/*/lib apps/*/lib | wc -l
# <!-- number-check: name=repo_hardcoded_zh value=2312 -->

# 是否已接入 i18n（应为空输出）
grep -rn 'AppLocalizations\|flutter_localizations\|package:intl' --include=*.dart packages/*/lib apps/*/lib
grep -rn 'localizationsDelegates\|supportedLocales' --include=*.dart apps/*/lib
```

量级分布（HEAD，字符串字面量数）：`spb_features` 1099、`spb_domain` 226、
`spb_desktop` 201、`spb_models` 98、`spb_mobile` 110、`spb_platform` 110、
`spb_api` 104、`spb_data` 39、`spb_core` 20、`spb_ui` 5、`spb_design` 3。
（[§6.54](ui.md) 的工具批卡与「动态」面板、[§6.56](chat.md) 的用量读数区贡献了 `spb_features`
增量的主要部分。）

⚠️ **`spb_core` 从 0 涨到 20**：issue #40/#45 的诊断报告与错误分类文案（到 13），
加 §6.57 的 `FileLogSink` 启动 / 轮转 / 写失败文案（到 16），之后随功能增加涨到 20——正是「为什么不做」第 1 条说的「文案有一半在纯 Dart 层」的实例：领域/
基础设施层的文案随功能增加而增长，而它们**不在 Widget 里**。

#### 为什么不做

1. **真正的成本不在 Widget 层，而在纯 Dart 层**。文案并非只出现在 `build()` 里：
   `SpbError.message`（`spb_core`）、`GoalGateStoppedItem.message`（`spb_domain`，
   reason → 中文的映射，且需与 miniapp 逐条一致）、`ConfirmationNotificationText`
   （`spb_domain`，OS 通知标题/正文）、`TextPreviewPayload` 的失败原因等都是
   **纯 Dart 生成的字符串**——这正是它们能被无头单测的原因（见 §4）。
   做 i18n 就得把这些文案改成「消息码 + 参数」，并把 locale 穿进 `spb_domain` /
   `spb_core`。那是一次**跨包重构**，不是「加几个 ARB 文件」；而把 locale 穿进去
   会让这四个纯 Dart 包第一次依赖「当前语言」这个环境态，可测性与分层约束
   （§4）都要重新论证。
2. **成本此刻并不「最便宜」**。issue #23 正文的判断是「越晚越贵」，这对
   「文案只活在 Widget 里」的项目成立；但本仓库的文案有一半在领域层，晚做的
   边际成本主要来自**领域层文案的耦合**，而那一层是稳定的（reason 枚举、错误
   分类不随 UI 迭代变化）。UI 层字符串增长快但提取机械、可增量做。
3. **无明确目标语言**。webapp 有完整的 `next-intl` 国际化（`messages/en.json` +
   `zh.json`，各约 1830 条），但那是**浏览器场景**：locale 来自 HTTP 头/URL，
   且已有双语用户。客户端是原生 App，locale 来自 OS 设置，而当前产品用户群是
   中文用户——引入 en 只会得到一个**没人验证过的英文界面**（比中文硬编码更糟：
   用户以为有英文支持，点进去发现是半成品）。
4. **局部「不引 `intl`」的三处**（`spb_domain` 的 `artifact_tree.dart` 的 locale
   排序、`goal_history_panel.dart` / `auto_schedules_panel.dart` 的固定日期格式）
   **不构成**本决策的理由——它们只是「为一种固定格式不引整套 locale 数据」的
   局部取舍，与本节的结论无关。不要拿它们当依据。

#### 重新评估条件（满足**任一条**即可重开）

| # | 条件 | 为什么是它 |
|---|---|---|
| 1 | 产品**进入非中文市场**，且有明确目标语言与验收人 | 无目标语言时引入 i18n 只会产出无人验证的翻译 |
| 2 | `spb_features` 硬编码字符串数 **> 1500**（当前 970，见上方命令） | 提取工作量翻倍，且说明 UI 文案已成规模、值得一次性上工具链 |
| 3 | 出现「**同一文案在 ≥3 处需按语境改写**」的实际需求 | 说明缺的是 message key 机制而非翻译；此时直译方案已不够用 |

#### 若将来要做（供重开时参考，**不要现在就动手**）

- 方案取舍：`flutter_localizations` + ARB（官方、`gen-l10n`、支持复数/性别）vs
  自研轻量 `Map<String, String>`。倾向官方方案，但**必须先解决第 1 条的领域层
  文案问题**（否则两套机制并存）。
- **「界面语言」与「Agent 回复语言」是两个独立维度**：后者已有
  `replyLanguage` 偏好（`user_preferences_card.dart`，`'auto'` 表示跟随输入，
  非法值服务端 400 而非静默回落）。webapp 的 `ReplyLanguagePanel` 注释专门强调过
  「两者独立，勿合并」——重开时不要顺手把它们合成一个设置。
- 分期建议：先做 UI 层（`spb_features` / `spb_ui` / `spb_design`），领域层文案
  作为独立一期（需先定「消息码 + 参数」契约）。

### 6.20 诊断日志导出（issue #40，**第一层已实现**）

> ⚠️ **本节写完后又补了一层本地日志**（§6.57）：`LogSink` 现在还有 `FileLogSink`
> （落 `~/.local/share/super_partyb/logs/app.log`）与 `MultiLogSink`。它解决的是
> 「进程死了、环形缓冲与 stdout 一起没了」这一类，**不是**远程通道——本节的
> 第 2 层（崩溃上报）「有意不做」结论不变。

客户端此前**没有任何远程日志通道**：`LogSink` 只有 `ConsoleLogSink`（打印到
stdout）与 `NullLogSink`（测试用）。用户报障时除了「它不工作」没有别的信息
——没有堆栈、没有版本、没有设备信息。而 [§9](../development.md) 已列出「需真机/有桌面环境手测」
的范围（多窗口、托盘、`Alt+Space`、OIDC 回跳、交付物同步）恰好是最容易出
平台特异性问题、而本机无法验证的部分。

issue #40 给了三层。**本轮只做第一层**，后两层有意不做：

| 层 | 内容 | 状态 |
|---|---|---|
| 1 | 「导出诊断日志」入口（手动附给报障） | ✅ 已实现 |
| 2 | 崩溃上报（Sentry 自托管 / 复用 `logs-collector`） | ❌ 有意不做 |
| 3 | `integration_test/` 覆盖无头可跑的链路 | ❌ 有意不做 |

#### 链路

```
设置页「导出诊断日志」
  └─ onExportDiagnostics 回调（装配层）
       └─ exportDiagnosticsReport(capabilities)      [spb_platform]
            ├─ diagnosticsEnvironment()   ← 版本/平台/Flutter/服务地址（**非机密**）
            ├─ buildDiagnosticsReport(...) ← spb_core：环境信息 + 最近日志
            │    └─ redactSecrets(...)     ← 导出前**最后一道**脱敏
            └─ capabilities.saveDiagnostics(text, suggestedName:)
                 └─ DiagnosticsExporter.save() → 系统「另存为」→ 写文件
```

#### 分层归属（按 §4 的判据）

| 层 | 内容 | 为什么在这一层 |
|---|---|---|
| `spb_core` | 环形缓冲（`SpbLog.recentLogs`）、`LogRecord.format()`、`redactSecrets`、`buildDiagnosticsReport` | 「保留哪些、怎么渲染、怎么脱敏」是**正确性核心**，必须能在无 Flutter 引擎的环境下逐条断言 |
| `spb_platform` | `DesktopCapabilities.saveDiagnostics` + `DiagnosticsExporter` + `diagnosticsEnvironment` / `exportDiagnosticsReport` | 环境信息要 `FlutterVersion` / `appBuildName`（Flutter 侧常量，纯 Dart 包拿不到）；保存要走 `file_selector` |
| `spb_features` | `SettingsPage.onExportDiagnostics` + 入口 + 四态反馈 | 渲染与交互 |
| `apps/*` | 一行 `onExportDiagnostics: () => exportDiagnosticsReport(caps)` | 装配 |

#### 四态而非「成功/失败」二元（**最易写错**）

`DiagnosticsExportOutcome` 有四个值，因为**用户看到的反馈不同**：

| 值 | 页面反馈 | 为什么不能合并 |
|---|---|---|
| `saved` | 弹「诊断报告已导出」 | — |
| `cancelled` | **什么都不说** | 用 `bool` 会把取消当失败，用户点一下取消就看到「导出失败」，以为功能坏了 |
| `failed` | 弹「导出失败，请重试」 | 静默失败会让用户以为导出成功、去磁盘里白找一场 |
| `unsupported` | 弹「当前平台不支持」 | 与「失败」不同：一个是可以换平台，一个是该重试 |

`NoopDesktopCapabilities.saveDiagnostics` 恒返回 `unsupported`，所以**移动端
不接**（两端 router 都传同一个装配函数也不会出事）——真到了移动端，页面会
如实说「不支持」而不是「失败」。

#### 安全红线：导出文本必须已脱敏

报告会被用户贴进**公开** issue / 聊天窗口，而泄漏的凭证收不回来。两道防线：

1. **来源侧克制**：`spb_api` 的 `session_credential.dart` 明写「本函数**绝不
   记录 token 值**」；`diagnosticsEnvironment()` 只含版本/平台/地址（逐条依据
   写在函数文档里，每个值都是公开的——`client_id` 本就是公开值，`env.dart`
   已说明；发布地址来自 CI Variables，而 Variables 在公开仓库里本来就可见）。
2. **导出侧按形态掩码**：`redactSecrets` 是**最后一道**，不依赖「谁记了什么」。
   将来有人不小心把 header 打进日志，这里仍然拦住。

`redactSecrets` 掩的是：`Bearer <token>`、JWT（`eyJ…`）、已知前缀令牌
（`sk-` / `ghp_` / `xox[bpoa]-` / `AKIA`）、PEM 私钥头、URL 里的 `user:pass@`、
以及**凭据类键名**后的值（`authorization` / `access_token` / `refresh_token` /
`id_token` / `api_key` / `apikey` / `client_secret` / `password` / `passwd` /
`token` / `secret`）。

⚠️ **不能过度掩码**。把「收到 401，会话凭证可能已失效」这种无辜文本抹掉，等于
把诊断信息删了。故键名是**白名单式列举**（不是关键词黑名单），且有专门一组
用例钉住「不误伤」（真实日志文案、路径/域名/端口、无凭据 JSON、英文句里的
`bearer` 一词）。

两个实现细节（都踩过）：

- 凭据键名里的 `\b` 让 `access_token` **不会**被 `token` 分支命中（`_` 是词字符，
  其与 `t` 之间没有词边界），故 `access_token` / `refresh_token` 必须逐个列出。
- PEM 头的正则**不能**在模式前加 `\b`（模式开头是 `-`，`\b` 要求前面是词字符
  → 永远匹配不到行首的 PEM 头）。

#### 三处「看起来能省、其实不能」的取舍

| 取舍 | 结论 | 为什么 |
|---|---|---|
| 写固定目录（应用数据目录） | ❌ | macOS 沙箱与 Linux 下都是隐藏路径，用户找不着——「导出成功但用户拿不到文件」比导出失败更糟 |
| 走剪贴板 | ❌ | 报告最多 500 条日志（上千行），粘进聊天窗口会被截断；且剪贴板是**静默**的（用户不知道复制成功没有） |
| 文件名用 `toIso8601String()` | ❌ | 它含 `:`，而 `:` 在 NTFS 上是数据流分隔符，`File.writeAsString` 会失败——**Linux 开发机一切正常、Windows 用户报导出失败**，而 CI 只跑 Linux。改用 `20261012-203045` 形态 |

#### 环形缓冲的两个不变式

- **上限 500 条，丢最旧的**。桌面端是常驻进程（关窗只隐藏到托盘），跑一周能
  产生几十万条日志；全留会让内存随运行时长线性增长——而这是用户**看不见**的
  泄漏。方向写反（丢最新）会让报告只剩启动时的日志。
- **阈值过滤在记录之前**。故报告只包含运行时**实际可见**的日志——想让报告
  带上 debug 细节，得用 `--dart-define=SPB_VERBOSE_LOG=true` 构建，而不是
  期待导出时能补回来。否则「日志里没有」会被误读成「没发生」。

`SpbLog.clearRecentLogs()` 是**测试专用**（全局单例的缓冲会跨用例累积，断言
「缓冲里有什么」之前必须先清）。

#### 有意不做：移动端导出

`file_selector` 的 `getSaveLocation` 在 **Android/iOS 上未实现**（基类抛
`UnimplementedError`）。移动端要做需引入 `share_plus` + 真机验证，属独立一轮
（同 §6.9.1「移动端打开已下载文件」的取舍）。当前移动端**不注入**
`onExportDiagnostics`，故入口不渲染。

#### 反向验证（逐条实测）

去掉 `redactSecrets` 调用 → 1 条失败；键名去掉 `access_token` → 1 条；PEM
正则加回 `\b` → 1 条；文件名改回 ISO8601 → 1 条（`:` 检测）；环形缓冲改丢
最新 → 1 条；阈值过滤移到缓冲之后 → 1 条；取消态也弹提示 → 1 条。

### 6.49 同步 partyb 的 reminder 准入重构：群级开关 → 个人运行时开关（2026-11）

上游 `super_partyb` 把四个 turn reminder 的准入全部收敛到 `/me/preferences`
个人运行时开关（Go `452cc432` / `47e9950e` / `1bdbc38c` / `7a814ed6`）：

| reminder | 旧形态 | 新形态 |
|---|---|---|
| follow_up_suggest | group 级 `metadata.follow_up_suggest` + 专用端点 + 建组播种 + 个人「新建默认值」 | 个人运行时开关，**缺省关** |
| habit_suggest | group 级 `metadata.habit_suggest` + 专用端点 + 建组播种 + 个人「新建默认值」 | 个人运行时开关（准入 = 开关 × 意图判定），**缺省关** |
| agent_recommend | env 准入闸 + 个人否决权 | **准入就是个人开关**，缺省**开**；env 退为单向急停 |
| goal_judge | group 级 `metadata.goal_gate.smart_injection` | 个人运行时开关，**缺省关** |

四个开关的可用性都由 `*_available` 下发（运维 `*_DISABLED` env，单向急停——
只能关不能开，且**不改写**用户开关本身）。

#### 客户端的同步内容

| 改动 | 文件 | 说明 |
|---|---|---|
| 删除群级端点方法 | `spb_api/chat_api.dart` | `setGroupFollowUpSuggest` / `setGroupHabitSuggest`——服务端已删端点，调用即 404 |
| 删除群级 metadata getter | `spb_models/chat_group.dart` | `followUpSuggestEnabled` / `habitSuggestEnabled`——键已成死键（存量无害，不清理） |
| 删除群设置面板区块 | `spb_features/group_settings_panel.dart` | 两个开关区块 + 参数 + typedef；两端 router 接线一并删除 |
| 偏好模型扩四个开关 | `spb_models/user_preferences.dart` | `followUpSuggest` / `habitSuggest` / `agentRecommend` / `goalJudge` + 各自 `available`；`agentRecommendSet` 区分「默认开」与「显式开启」 |
| 偏好卡新增开关区块 | `spb_features/user_preferences_card.dart` | 「对话提醒开关」四开关 + 急停置灰；删「新建对话的默认开关」旧文案（语义已不成立） |
| PUT 补两个新键 | `spb_api/chat_api.dart` `updatePreferences` | `agent_recommend` / `goal_judge`（非 null 即提交） |
| goal_gate_stopped 补两个 reason | `spb_domain/conversation_item.dart` | `planning_stalled`（连续规划无产出）/ `goal_not_active`（目标 paused/archived），文案与 miniapp 逐条一致；`no_tasks` 保留兼容历史事件 |

#### 易写错的四个点

1. **缺省方向逐个不同，勿照抄同一句**：`follow_up_suggest` / `habit_suggest` /
   `goal_judge` 缺省**关**（判定/注入有真实成本，不该由平台默认替用户按下），
   `agent_recommend` 缺省**开**（未表态即收提示）。解析侧用
   `json['agent_recommend'] != false`（缺省开）vs `== true`（缺省关）——写反了
   会让所有用户在不知情时开关翻转。
2. **`*_available` 缺失按可用处理**（`!= false`），不是 `== true`：把「旧响应 /
   加载中」显示成「已停用」会让每次打开设置页都闪一次误导性红条（webapp
   FollowUpSuggestPanel 的同款取舍）。
3. **急停置灰不改写草稿**：开关值保持原样，只禁用 `onChanged` 并换副标题为
   原因说明。改写值会让「解除急停后恢复原设置」变成谎话。
4. **「新建对话默认值」的旧文案必须删**，不能只改行为：用户读到「仅影响之后
   新建的对话」会去老对话里验证、发现没变化、误以为设置坏了。

#### 测试

| 层 | 用例 |
|---|---|
| `spb_api` | `updatePreferences` 四开关各一个键 / 四 false 全发出 / 不传不发键；`available=false` 解析为不可用；缺失按可用；`agent_recommend` 缺省开；`agent_recommend_set` 区分默认与显式 |
| `spb_models` | 同上字段的解析与容错 |
| `spb_features` | 偏好卡四开关初值 / 单键提交 / 未改不误报 / 急停置灰不改值且说明原因；面板与用例的群级开关测试随之删除 |
| `spb_domain` | `goal_gate_stopped` 七种 reason 文案与 miniapp 逐条一致 |

#### 反向验证要点

- `agent_recommend` 解析改回 `== true` → 缺省开用例失败；
- 急停置灰改回「不改值也允许拨动」→ 置灰用例失败；
- `_pendingChanges` 漏比对新键 → 「未改不误报」用例失败；
- `planning_stalled` / `goal_not_active` 缺映射 → 退化为兜底文案（「自动推进已停止」）
  ，正是 miniapp `7a952437` 修的那个症状。

#### 6.49.1 第五个开关 goal_discovery + 两个 409 错误码 + 排程 DTO 重写（2026-11）

上游 Go `040855fe` / `a18a017e` / `ceff2f81` / `b2a54b5a` 四个提交的客户端同步。
另在 upstream 登记了 issue #95（GET /me/preferences 缺 goal_discovery 下发）。

| 上游提交 | 客户端同步 |
|---|---|
| `040855fe` goal_discovery 偏好开关 + createGoal auto_start | 偏好模型/PUT/偏好卡加第五个开关 `goalDiscovery`（缺省**关**）；`createGoal auto_start` **暂不接**（客户端建目标场景未出现，字段留服务端可选） |
| `a18a017e` 反馈回执原子化 + 可重放 | 新失败形态 `409 {code: feedback_not_applied}`，与 404 同文案「这条反馈已失效，无法再作答」 |
| `ceff2f81` 发送重放保护 | 新失败形态 `409 {code: group_unavailable}`，特判文案「目标对话已失效，请返回列表重新选择对话后发送」；`SendMessageResult` 的 `status`/`deduped` 既有解析不变 |
| `b2a54b5a` 排程 DTO 重写 + 授权修复 | ⚠️ **真破坏**：`GET …/auto-schedules` 从 sqlc camelCase 行改为 `scheduleToDTO` **snake_case**（`policy` 对象化、新增 `schedule_state`、`last_error` 对象化、`trigger_status` 平串）——旧模型按 camelCase 解析**不报错但全部字段落空**（`?? ''` 吞掉），面板表现为「没有排程」。`ChatTurnSchedule` 整体重写为新 DTO；`AutoSchedulesUseCase` 的两步 workaround（GET group 拿 agentId）随服务端修复撤销，改单次请求 |

**`HttpError.errorCode`（`spb_core`）**：服务端 2026-11 起给 409 带 `code` 键，但
`ChatApi._bodyPreview` 存的是 `data.toString()`——Dio 已解析成 Map，故 body 实际是
**Dart Map 字面量**（键值不带引号），不是 JSON。getter 用宽松正则兼容两种形态；
**不**解析成结构化字段——哪些错误带 code 由服务端决定，客户端按需特判。

**goal_discovery 的解析防御**：GET 响应当前**不下发** `goal_discovery` /
`goal_discovery_available`（上游 #95），解析按「缺省关 / 缺省可用」兜底——与
§6.49 的 `*_available` 取舍一致。服务端修复后 UI 开关才能正确回显已开启状态，
在那之前：用户开了开关 → 重新打开设置页会显示关（但 PUT 已提交，服务端行为
是对的）。夹具已按「修复后的形状」写键并注明。

**auto-schedules 两个易错点**：① `last_error` 现在是 parseJSON 解析过的**对象**，
原文串不可得——面板压缩为单行文本（优先取 `error`/`message`/`reason` 键，形状
不可假设）；② `groupId` 本地断言从 workaround **降级为校验**但不能删：停用端点
的 SQL 仍按 `policy.meta.group_id` 过滤，解析不出该键的行停用端点碰不到，显示
出来会让「停用全部」永远可点。

**测试**：models（DTO 新形状 + camelCase 负例回归 + `chatScheduleGroupIdFromPolicy`
防御）、api（五个开关 body + 排程 snake_case 契约）、core（`errorCode` 两形态 +
无 code）、features（第五开关 UI 4 条 + 排程用例重写 + 409 两处文案 + 无 code 反例）。

#### 6.49.2 上游对齐收尾：任务时间元信息 / 4xx 文案分支 / auto_start / 标题重生成 / 停用反馈（2026-11）

§6.49.1 之后的第二轮收尾，全部对齐上游 webapp 既有行为（不是新发功能）：

| 项 | 改动 | 判据 |
|---|---|---|
| 任务时间 chips（Go `8733e5b1`） | `goal_tasks_panel.dart` 给任务行补时间标签：`开始`（`started_at` 且 status ≠ pending）、`完成`（`completed_at` 且 completed）、`跳过`（同上且 skipped）；`定时`（`not_before` 未来）原有保留 | 对齐 webapp `taskTimeMeta` 规则：`not_before` 只在仍未来时显示；`error_stopped` 永无完成时间（服务端不写） |
| 发送 4xx 文案分支（Go `a18a017e`/`ceff2f81` 同批错误码） | `_handleSubmit` 的 `HttpError` 分支改为 switch on `e.errorCode`：`group_archived` → 「该对话已归档，请先恢复后再发送」；`queued_quota_exceeded` / `workspace_quota_exceeded` → 各自可行动的中文；未知 code 回落「发送失败：HTTP <status>」 | 归档≠失效（恢复即可用，不该叫用户重选对话）；429 是「稍后再试」不是「失败」。服务端英文文案（如 "queued turn quota exceeded"）不能直接给用户 |
| `createGoal auto_start`（Go `040855fe`） | `GoalApi.createGoal` 新增 `bool? autoStart`（非 null 即提交）；目标历史面板新建对话框加「创建后自动推进」勾选（key `goal-create-autostart`，**默认不勾**）；两端 router 同构接线 | 一次调用完成「建 goal + 开 goal_gate」避免中间态；自动推进连续消耗轮次，不该由客户端默认替用户按下；显式 `false` 也要发（非 null 即提交，同 §6.49 开关语义） |
| 标题重新生成（Go `210db5f3`） | `ChatApi.regenerateTitle`（POST `/chat/groups/:id/title/regenerate`）+ `GroupSettingsUseCase.regenerateTitle`（写后回读权威 group）+ `GroupSettingsPanel` 标题区块（key `group-title-regenerate`，未注入不渲染、busy 禁用），两端接线 | 与手动改名语义不同：改名会打 `title_generated` 标记（gate 永不覆盖），重生成是「放弃自动标题、让它重新起」；写端点无响应体，不回读会让界面继续显示旧标题 |
| 停用全部反馈（Go `b2a54b5a` 停用端点语义） | `StopAllAutoSchedules` 返回完整 `AutoSchedulesStopResult`（含 `disabledCount`）；面板成功后显示一次性反馈：`> 0` → 「已停用 N 个自动续跑排程」，`== 0` → 「没有在途的自动续跑排程」 | 条数是服务端谓词的**唯一权威回执**：并发下「列表里仍有 pending」与「实际停用了 0 条」可能同时为真；「已停用 0 个」看起来像功能坏了，「没有在途」是有效结论 |

**两个易写错处**：① 任务时间断言——`Goal.fromJson._date` 做 `.toLocal()`，chip 用
toLocal 后的 hour/minute。⚠️ **期望值不能写死时刻**（如「开始 3/5 16:30」）：
本机是 UTC+8、CI 是 UTC，写死必有一边红（2026-11 CI 实测）。必须与被测代码
同口径推导期望（`DateTime.parse(iso).toLocal()` 再取 month/day/hour/minute）；
② 停用反馈的测试 harness 不能从返回的
items 自动推断 `disabledCount`（items 是停用**后**的列表，已全部非 pending，推断
恒为 0）——必须显式传，否则「已停用 N」用例在正确实现上也会红。

**测试**：features（时间 chips + 4xx 三分支 + 新建勾选 + 面板重生成 3 条 + 停用反馈
2 条）、api（`regenerateTitle` 契约 + `createGoal auto_start` 三态 body + useCase 两步）、
两端 router 接线随编译器/既有用例覆盖。全量 1262（features）/ 490（api）/ 208（desktop）/
116（mobile）用例绿。

### 6.57 桌面端可诊断性：本地文件日志 + 会话标记 + 悬浮窗失败回滚（2026-11）

用户报障原话：「按 Alt+Space 弹出了一个小输入窗口，但**卡住不动**，然后**应用退出了**。
是否需要新增本地日志来协助调试？」这一节把**诊断结论**（哪些是确证、哪些是假设）与
三项改动一起记下来——因为「要不要加日志」这个问题本身就是这次排障的产出之一。

#### 一、诊断结论（严格区分确证 / 假设）

| 结论 | 强度 | 依据 |
|---|---|---|
| 「卡住的小窗」是**窗口属性半改造**状态 | ✅ **确证（代码级）** | `enterOverlayMode` 串行改 7 项窗口属性（minSize → size → resizable → alwaysOnTop → skipTaskbar → position → show/focus），任一中途抛异常时**只丢弃快照、不回滚**；而 `exitOverlayMode` 的早退判据是 `_preOverlayBounds == null`——快照已丢 ⇒ 之后所有退出都是**空操作**。于是窗口停在「720×360 / 置顶 / 不进任务栏」这类形态 |
| 「应用退出了」= 进程真的退出 | ❌ **未确证** | 全仓 grep 无 `exit(`；`windowManager.destroy()` 只在 `quit()`（会先记 info「用户请求退出应用」）。更符合代码的解释是：`skipTaskbar=true` 让窗口**从任务栏消失**，而小窗一旦失去置顶/焦点就再也找不到入口 → 用户读作「退出了」。要证伪需要真实日志，而**当时没有日志** |
| 「快捷键触发过」 | ❌ 当时**不可知** | `_onHotkeyPressed` 原为 `SpbLog.debug`，而 `SpbLog._minLevel` 默认 `info` ⇒ 生产里根本没写。这是 [§6.43](sync.md) 那条教训的**同型复发**：门控/触发类日志用 debug 等于没写。现已升为 `info` |

⇒ 回答用户的问题：**需要，但不是新起一套**。`SpbLog` + 环形缓冲 + `redactSecrets` +
「导出诊断日志」的骨架已经建好（§6.20），缺的是三个具体的洞。

#### 二、三个真实缺口（本轮补齐）

| 缺口 | 后果 | 补法 |
|---|---|---|
| **只有 stdout** | 桌面启动器/双击拉起时 stdout 无处可去，日志等于**没产生** | `FileLogSink`（`spb_core`）追加写文件，`MultiLogSink` 与控制台并行 |
| **无持久会话边界** | 「崩了」与「被关了」事后无法区分 | 每次启动写 `logSessionStartMessage`，`quit()` 写 `logSessionCleanExitMessage`；下次启动扫出结论并 warn |
| **环形缓冲只在内存** | 进程死了证据就没了，而「导出诊断日志」要求应用**还活着**且用户能进设置页 | 文件日志天然解决——崩溃前最后写的一行就是证据 |

##### `FileLogSink` 的四条判据（`packages/spb_core/lib/src/log_file_sink.dart`）

| 判据 | 取值 | 为什么 |
|---|---|---|
| 写盘方式 | 每条 `File.writeAsBytesSync(mode: append)`，**不持有 `IOSink`** | 「崩了之后还有内容」是本 sink 存在的唯一理由。`IOSink` 有内部缓冲，进程被杀就丢最后一段——而那一段恰好最想看 |
| 轮转 | 默认 5 MB × 2 份历史（`app.log` / `.1` / `.2`） | 常驻进程跑一周能写几十万条；无轮转就是无界增长。**先删 `.maxFiles` 再从后往前逐个后移**：Linux 上 `rename` 覆盖目标、省掉删除也能跑，但 Windows 上目标已存在时 `renameSync` **抛异常**——统一「先删后移」就不必按平台分叉 |
| 脱敏 | 写盘前过 `redactSecrets`（可用 `redact: false` 关掉） | 日志会被用户**整份贴进公开 issue**（§6.20 的安全红线）。实测掩码后是 `authorization: ***`——键名保留、值整体掩掉 |
| 失败处理 | 首次写失败 → **停用** + `print` 一次，之后静默跳过 | 日志是旁路：磁盘满/目录只读不能让应用起不来；而「每条都重试 + 每条都 print」会变成刷屏。⚠️ **内部绝不调 `SpbLog`**——那在 `SpbLog` 的调用链上，会无限递归 |

`MultiLogSink` 同理：单个 sink 抛异常不影响其它 sink，也不冒泡（同样不能记日志，理由同上）。

##### ⚠️ 会话标记的判据是「从后往前找边界标记」，不是「最后一条是不是退出标记」

这是本轮**自己踩到并改掉**的一处（原实现只看最后一条非空日志）。后者会**级联误报**：
一次崩溃之后，下次启动会写「会话启动」+ 一条「上次未正常退出」的告警；此后即使每次
都干净退出，只要退出标记**之后**还有任何一条日志（`quit()` 之后的 `dispose()` 就会写），
下一次启动又判成崩溃 —— 告警从此**永远**出现，于是它不再携带信息。

现在的判据（`previousSessionExitedCleanly`）：读文件末尾 8 KB，**从后往前**看先遇到哪个边界标记。

| 先遇到 | 返回 | 含义 |
|---|---|---|
| `logSessionCleanExitMessage` | `true` | 上次走到了 `quit()` 收尾（其后的收尾日志不影响） |
| `logSessionStartMessage` | `false` | 新会话开了头，上一个没留退出标记 |
| 都没有 | `null` | 首次运行 / 刚轮转 / 标记之前的老日志 —— **不可**当成崩溃 |

`_configureLogging()` 里的**顺序有语义**：必须先读上次结论、再装 sink、再写启动标记。
写反就永远等于「上次正常退出」——启动标记会把「最后一条」抢走（对应上一条教训）。

##### 日志位置与取证方式（报障时直接给用户这一句）

```
Linux / macOS：${XDG_DATA_HOME:-~/.local/share}/super_partyb/logs/app.log
Windows：      %APPDATA%/super_partyb/logs/app.log
覆盖目录：      --dart-define 无关，运行期 SPB_LOG_DIR=<dir> 即可
```

⚠️ **与 `sync.db` 同一根目录**是刻意的：报障时「把 `~/.local/share/super_partyb/` 打包发来」
一句话就够了，多一个根目录（如 `$XDG_STATE_HOME`）会让「日志在哪」变成需要解释的问题。

零改动的替代取证手段（临时构建，不必等发版）：

```bash
flutter build linux --release --dart-define=SPB_VERBOSE_LOG=true
# 然后**从终端**启动二进制，debug 级日志也会出来（含快捷键触发细节）
```

#### 三、A：悬浮窗进入失败的回滚（`overlayRollbackOrder`）

| 判据 | 内容 |
|---|---|
| 只回滚**真的改过**的 | `_overlayApplied` 逐步记账（`_applyOverlayStep` 成功才记账）。全量重设会篡改未改过的属性——`setResizable(true)` 对一个用户手动设为不可缩放的窗口就是破坏「撤销」语义 |
| **逆序**回滚 | 最后改的最先还原（`overlayRollbackOrder`） |
| 剔除 `visibility` | 它没有「之前的值」可还原；改为**无条件** `show()` + `focus()`——失败路径上「用户能找到窗口」优先于「窗口尺寸正确」 |
| 回滚尽力而为、**不抛** | 已在出错路径上，抛出会吞掉原异常。逐步 try/catch + 汇总日志（`回滚悬浮窗属性失败` / `悬浮窗属性已回滚` / `悬浮窗属性回滚不完整`） |
| 失败后**仍然导航**到 `/overlay` | 既有测试明确要求（`enterSucceeds=false` 仍须 `router.state.uri.path == SpbRoutes.overlay`）。回滚后窗口恢复主窗口尺寸，页面可输入 —— 比完全不导航好 |
| 判据放 `spb_platform` | `PlatformDesktopCapabilities` 要 `window_manager` 才能构造，**测试里造不出来**（[§6.41](platform.md) / [§6.45](platform.md) 同一取向）。故顺序判据抽成纯函数，6 条用例逐条钉 |

⚠️ **最小尺寸不做快照**：`window_manager` 0.5.2 **没有 `getMinimumSize()`**（只有 setter），
「调用那一刻的值」取不到。回滚时退回 `WindowSpec.main.minWidth/minHeight`——那正是启动时
由本类设置的唯一来源，实践上等价（将来若支持运行期改最小尺寸，需自己记字段）。

##### ⚠️ 本节的回滚防不了原生崩溃（2026-11 Windows 实测，已修）

用户报「按 Alt+Space 后主窗口变小、卡住、进程退出」。事件查看器（Event ID 1000）：
**故障模块 `window_manager_plugin.dll`，异常码 c0000005（访问违例）**，紧随「全局快捷键触发」
日志 200ms——**原生崩溃不走 Dart 的 catch，本节整套回滚 + error 日志完全不可见**（这也是
逐步日志 `_applyOverlayStep` 每步记 info 的由来：日志最后一行即崩溃点）。

根因（读插件 0.5.2 Windows 原生源码钉死，`window_manager.cpp`）：

```cpp
ITaskbarList3* taskbar_ = nullptr;            // 初始为空
void WaitUntilReadyToShow() {                 // taskbar_ 的**唯一**初始化点
  ::CoCreateInstance(CLSID_TaskbarList, ..., &taskbar_);
}
void SetSkipTaskbar(...) {
  taskbar_->HrInit();                         // ← 无空检查；nullptr 上调 COM 虚方法
  taskbar_->DeleteTab(hWnd);                  //   → c0000005，进程即死
}
```

而本仓库 bootstrap 因「runApp 前调它会等首帧、死锁」（旧版语义）**从不调**
`waitUntilReadyToShow` → `taskbar_` 永远是 nullptr → 悬浮窗第一步 `setSkipTaskbar(true)`
即崩。修法：`initialize()` 里调一次**裸的**（无 options 无回调）`waitUntilReadyToShow()`——
三平台原生实现都已核实（Windows = CoCreateInstance 立即返回、Linux = 返回 true、
macOS = 空函数体），应用运行后调用不存在「等首帧」；放在 initialize() 而非 enterOverlayMode，
是因为后面**四处** `setSkipTaskbar`（applyWindowSpec 分支 + 悬浮窗改写步 + 两处回滚）一次全覆盖。

⚠️ 两个教训：① 「插件文档说的推荐用法有死锁」这类结论要区分**平台实现**与**Dart 包装**——
死锁风险在带 options/callback 的包装层，原生调用本身不等待；② 窗口属性类插件调用的崩溃
在 Windows 上表现为**进程静默死亡**，排障时事件查看器的故障模块比应用日志更快指向根因。

顺带修的第二个 Windows 缺陷：`_dbFile()` 只认 Linux 的 `XDG_DATA_HOME`/`HOME`，
Windows 上两者都不存在 → `sync.db` 落临时目录、同步状态每次启动清零（日志里那句
「未找到 XDG_DATA_HOME 与 HOME」就是它）。已抽 `spb_core.defaultAppDataDir()`
（Windows 用 `%APPDATA%`，与 `FileLogSink` 同一份解析）供两个调用点共用——
重构时曾弄丢 `SPB_LOG_DIR` 覆盖逻辑，被既有测试当场抓住。

日志侧同时补了三项（都按 [§6.43](sync.md) 的「门控/触发类用 info」）：快捷键触发 `debug → info`、
未绑定 id `→ warn`、`桌面能力触发导航` `debug → info`，失败日志带
`failed_step` / `applied` / `attribute` / `failed` / `rolled_back`。

#### 四、C：同步目录未选择时给默认值（`defaultSyncLocalRoot`）

用户另一句诉求是「同步目录如果没选的话给个默认设置」。此前 `localRoot == null` 的语义是
「未选择 ⇒ 不能同步」，于是首次启动的用户必须先进设置页：托盘「立即同步」是禁用的、
进对话的按需同步被 `canSync` 跳过 —— 功能**看起来不存在**。

| 顺序 | 条件 | 结果 |
|---|---|---|
| 1 | `SPB_SYNC_ROOT` 非空 | 直接用它（便携部署 / 测试） |
| 2 | `<home>/Documents` **存在** | `<home>/Documents/Super PartyB` |
| 3 | 有应用数据目录 | `<data>/super_partyb/deliverables` |
| 4 | 连 home 都没有 | `null`（保持「未配置」语义，设置页提示选目录） |

| 判据 | 为什么 |
|---|---|
| 优先 `~/Documents` | 同步目录的价值是「用户能自己打开它」。藏在 `.local/share` 下是隐藏目录，与「交付物放到我电脑上」的预期不符；但 `~/Documents` 不总存在，故必须有不成立时的第二条 |
| **两处读点共用** `effectiveSyncLocalRoot` | `syncLocalRootProvider`（托盘/门控/自动同步）与 `loadSyncSettingsProvider`（设置页表单）。只在一处加默认值会得到「托盘认为未配置（按钮置灰）而设置页显示了一个目录」——[§6.17](testing.md) 同一类漂移 |
| 默认目录**顺手建出来** | 「打开同步目录」会 `revealPath`，目录不存在时返回 false，表现成「点了没反应」（[§6.41](platform.md) 同一症状）。创建失败只 warn，不阻断（同步引擎写文件时会再试） |
| 不持久化 | 默认值每次纯计算。写进 `sync_bindings` 会把旧机器的绝对路径带到新机器；代价是「用户清空目录」会静默回落默认值 |
| desktop-only | 移动端已有 `syncLocalRootProvider`，本轮不改其语义（移动端没有本地目录这个使用场景，见 [§6.42](sync.md) 的取向） |
| 纯函数 + 参数全注入 | 环境、`isWindows`、`documentsExists` 都得注入才能覆盖四个分支（本机有 `~/Documents`，CI 容器没有） |

##### 默认值必须**可见**：「默认，可修改」标签（用户确认后补）

默认值生效后设置页出现一个新歧义：卡片显示一条路径，用户分不清这是他配的还是应用猜的
（「配的」不该动、「猜的」可以换）。故桌面端 router 传入 `localRootIsDefault`，卡片在
路径下方加一行蓝字「默认，可修改」（key `settings-local-root-default`）：

| 判据 | 为什么 |
|---|---|
| `isDefault` 与 `root` **同源解析**（`effectiveSyncLocalRoot` 返回 `(root, isDefault)` 二元组） | 拆成两次独立判定会出现「显示目录 A、却标着 B 是默认」的撕裂 |
| 保存后 `syncLocalRootIsDefaultProvider` 一并 invalidate | 任何保存都会 `bindLocalRoot`（显式落库），此后就不再是默认——不失效的话用户保存过后仍看到「默认」 |
| 有未保存草稿时不标（`isDefault && !_dirty`） | 标签描述的是**已落盘**的事实；草稿里刚换了目录（还没保存），同一张卡片不能同时说「默认」和显示别的路径 |
| **移动端不传**（默认 false），登记进 `check_wiring_parity.sh` 的桌面豁免 | 移动端目录由系统分配，永远不是「默认值」也不是「用户选的」——两个标签都不成立，保持原样最诚实 |
| 无目录时不显示标签（`hasRoot && isDefault`） | 「尚未选择」分支没有路径可标，硬标会出现「默认但什么都没写」的怪态 |

#### 五、测试与反向验证

| 文件 | 条数 | 钉住 |
|---|---|---|
| `packages/spb_core/test/log_file_sink_test.dart` | 31 | 追加不覆盖 / 自动建目录 / 一行一日志（`format()` 把换行转义成字面 `\n`）/ 脱敏 / 轮转（`.1`+`.2` 存在、`.3` 不出现、最新在当前文件、`maxFiles=0` 不留历史、`size` 归零）/ 目录不可写时停用且不抛 / `MultiLogSink` 扇出与隔离 / 会话标记六态（true / false / null / 收尾日志在其后仍 true / 崩溃后一次干净退出不级联误报 / 截断半行）/ 路径推导六变体 |
| `packages/spb_platform/test/overlay_window_state_test.dart` | 6 | 逆序 / 剔除 `visibility` / 部分失败只回滚前缀 / 空清单 / 去重 / 返回值独立于入参 |
| `packages/spb_domain/test/default_sync_root_test.dart` | 9 | 覆盖优先 / 空白不算覆盖 / Documents 存在与不存在 / Windows 与 Linux 各两条 / Windows 不读 Linux 变量 / 无 home → null |
| `packages/spb_features/test/settings/settings_page_test.dart`（新增 group） | +3 | 默认值有标签、用户选过没有 / 未配置目录不标 / **改草稿后标签消失**（未保存前不双标） |
| `apps/spb_desktop/test/router_settings_test.dart` | +1 | **router 层**断言「默认，可修改」真的渲染出来（页面测试自己传参，捕不住接线漏了，[§6.17](testing.md)/[§6.44](ui.md) 同一失败模式） |

回归：`spb_core` 147、`spb_domain` 1094、`spb_platform` 166、`spb_features` 1278、
`spb_desktop` 210 全绿；十个守卫 + codegen 全绿。

反向验证（逐条实测）：

| 改坏 | 失败用例数 |
|---|---|
| `previousSessionExitedCleanly` 退回「只看最后一条非空日志」 | **3**（收尾日志在其后 / 崩溃后一次干净退出 / 截断半行） |
| 轮转删错对象（删 `.1` 而不是 `.maxFiles`） | 1 |
| 写盘不追加而覆盖（`FileMode.write`） | 5 |
| 写失败后不禁用（每条都重试 + 每条都 print） | 1 |
| `MultiLogSink` 去掉 try/catch | 1 |
| `overlayRollbackOrder` 改正序 | 2 |
| `overlayRollbackOrder` 不剔除 `visibility` | 2 |
| `defaultSyncLocalRoot` 去掉应用数据目录那一档兜底 | 2 |
| 目录卡片去掉 `!_dirty` 守卫（草稿已换目录仍标「默认」） | 1（未保存前不双标） |
| 桌面 router 漏接 `localRootIsDefault`（写死 false） | 1（router 层用例，⭐页面测试抓不到接线） |
| 只在 `syncLocalRootProvider` 加默认值 | —（**未写成用例**：两个读点之间的漂移靠 code review，`check_wiring_parity.sh` 查不到函数内部实现） |
| `_configureLogging` 里先写标记、再读上次结论 | —（**未写成用例**：装配顺序在 `main.dart`，不在测试树里；已写成代码注释） |

⚠️ 用 `cp` 备份/还原被改文件，**不要**用 `git checkout`——这些文件都是未提交的
工作区改动，`checkout` 会把本轮新增整段冲掉（[§6.28.2](chat.md) 踩过）。

#### 六、有意不做

- **不做崩溃上报（Sentry / logs-collector）**：仍是 §6.20 第 2 层「有意不做」——文件日志已能回答
  「崩了还是被关了」，上报会引入隐私审查与新依赖。
- **不引入 `path_provider` 到 `spb_core`**：`FileLogSink` 只收路径，目录由 app 侧算好传入。
  纯 Dart 包为「找目录」引插件是层级下沉（§4）。
- **不异步批量写盘**：会重新引入缓冲丢失，与这个 sink 的存在理由冲突。同步 append 的量
  （info 级、每条几十字节）不足以影响帧率；真要优化应先降日志量而不是改写法治。
- **不给 `previousSessionExitedCleanly` 加「崩溃后自动上传/弹窗」**：只记一条 warn 留证据。
  主动弹窗会把「上次崩了」变成每次启动的骚扰，而多数用户不在意。
- **不持久化默认同步目录**：见上表。
- **不改移动端**：无本地同步目录使用场景，且不写文件日志（沙箱无稳定可写目录）。

#### 七、已知边界

- **「进程真的退出」仍未被证实**。本轮把「能观测到」做齐了（快捷键触发、失败步骤、回滚结果、
  会话边界都进了文件日志），但用户的两次报障发生在**没有日志的版本**上，故成因仍是假设。
  下次复现时先取 `app.log` 再动代码。
- **`_initTray` 的降级本身不改**（[§6.55](platform.md) 已修掉图标资源那一半）：托盘不可用时记 warn 后继续运行
  是设计（桌面环境没有 tray 协议时不该报错）。仍只有 debug 的是 `popUpContextMenu` 缺实现
  （[§6.55](platform.md) 有意如此，Linux 上属常态），需要时用 `SPB_VERBOSE_LOG=true` 临时构建。
- **轮转会把退出标记带走**：这是 `null`（不知道）而非 `false`（崩溃）存在的原因，也是
  「刚轮转后的首次启动不误报崩溃」的依据。
- **默认目录不感知本地化**：Windows 上「文档」可能是 OneDrive 重定向路径，探测不到就落到
  应用数据目录——不会错，只是不够显眼。
- **需真机验证**：本机无 `DISPLAY`（[§9](../development.md)）。悬浮窗回滚的**真实表现**（窗口是否回到原尺寸/位置、
  是否重新出现在任务栏）必须在有桌面环境的机器上确认；本轮只验证了顺序判据与接线。

### 6.99 通知统一消费站内事实（issue #120，2026-11-20）

用户要求 PWA 与 SPBF 对齐后，原“只通知确认卡”策略已被取代。
通知类型与文案以 Go `internal/notify` 和 `owner_notices` 为真源：
确认、完成、失败、沙箱告警以及未来新增类型都按服务端内容展示，客户端不维护类型白名单。

- SPBF 桌面/移动共用 `NoticeCenter`、`ConfirmationNotificationInbox.handleNotices`、
  `NoticeCenterCard` 与 `NoticeBanner`；生产不再从对话 SSE / 待确认列表直接发通知。
- 应用运行时每 15 秒读 `/me/notices?limit=200`，回前台立即刷新；包含已读项，
  未读数不变也继续读取，才能发现同 ID 更新与其他设备的已读操作。
- 后台使用系统通知，前台使用应用内提示；每批前台只提示最新一项，其余留在通知中心。
  系统通知采用持久化 receipts，按 `id + updated_at + data.turn_id` 判重。
- 展示、关闭、点击跳转不自动 ack；用户点击“标记已读 / 全部标记已读 / 知道了”
  才写 `/me/notices/read`。PWA 与 SPBF 使用同一用户级 `read_at`，通过轮询最终同步。
- 过期确认卡加“已失效，仅作记录”，通知不因卡过期消失；别端已读会撤销对应本地通知。
- 桌面托盘未读来自通知中心。它是**站内通知数**，不是聊天消息未读数。
- 两端的凭证更换与 receipts 共用 SQLite 互斥及 generation；旧请求不能向新账号发通知。

平台差异只属于投递能力：PWA 的 Service Worker 使用 Web Push；桌面需要进程运行；
Android WorkManager 保留至少 15 分钟的后台兜底；iOS 无原生远程推送。
Windows 非 MSIX 的撤销限制仍见 §6.112，不能宣称所有系统横幅实时同步。
当前接口只返回最近 200 条（按 `updated_at` 倒序），不宣称完整历史或可靠消息队列。

维护流程和三端共用样本见 `docs/api-contract.md` 的“站内通知契约”；服务端修改后
刷新 fixture 并跑对拍测试。

---

### 6.102 移动端后台无远程推送：客户端只做「回到前台对账」，推送本身在服务端（issue #88，2026-11）

**现状**：进程冻结后不能保证即时通知。当前通知由站内事实驱动（§6.99），
Android 有 WorkManager 兜底（§6.111），iOS 尚无原生远程推送。
以下为引入后台兜底前的方案比较，不再描述现有通知数据源：
Android 需要 FCM 或厂商通道（小米/vivo 等要求应用市场上架）、iOS 需要 APNs
（当前被 Apple 开发者账号阻塞，#83/#84）。

**已实现（issue #88 方案 C 的客户端半边）**：切后台再回来时对一次账，解决
"回到前台看到陈旧列表"这个可观测症状：

| 动作 | 落点 | 为什么 |
|---|---|---|
| 重拉待确认收件箱 | `_SpbMobileAppState._resyncOnResume` → `ref.invalidate(pendingConfirmationsProvider)` | 服务端确认卡 10 分钟 TTL 就转 expired，挂起期间到达的那批事件永久丢失 |
| 共享 SSE 自救 | `ChatStreamController.recoverIfStalled()` | `maxRetries=10` 耗尽后是**永久** `failed`，没人会再连；僵尸连接（无 error 也无 onDone）同理 |

判定矩阵（`recoverIfStalled`）：`failed` / `idle` / `connected` 但静默超
`resumeSilenceThreshold`（10s ≈ 3 个 3s 心跳）→ 重连；`connecting` /
`reconnecting` → 让位给既有退避；未 `start` 或已 `dispose` → 空操作。
静默判据来自 `SseClient.isSilentFor()`——`lastByteAt` 由**任何字节**（含
`: heartbeat` 注释行）刷新，`_teardown` 时清零（新连接不得继承上一跳的活跃时刻）。

**一个必须记住的平台事实**：回前台**不是** `paused → resumed` 一跳。
真机序列是 `paused → hidden → inactive → resumed`，进入 `resumed` 时上一层
**永远是 `inactive`**。故 `_LifecycleFocusObserver` 记的是"本次可见期内是否真的
离开过"，不是"上一跳是不是 paused"——按上一层判定在真机上永不触发，而只发一跳的
单测看不出来。`inactive → resumed`（下拉通知中心又回来）**不触发**对账。

**有意不做**（各自的否决理由，不要"顺手加"）：

| 方案 | 否决理由 |
|---|---|
| `WorkManager` 周期拉取（最小 15 分钟） | 与服务端推送的秒级差一个数量级；`force-stop` 后失效；还要额外维护一套"本地补发通知"语义。**2026-11 更新：已作为「尽力而为」的兜底落地**（见 §6.111），上面三条一条也没消失——它换掉的是「什么都收不到」，不是「秒级送达」 |
| 前台服务常驻长连接 | Android 15 起 `dataSync` 型 FGS 有 6h/日上限且不能 `BOOT_COMPLETED` 启动，`specialUse` 型需应用商店审核理由；iOS 零可能。真要做得是 opt-in 实验开关，不能当默认 |
| WebSocket 保活 | §6.1 已禁；且后台仍是同一堵墙 |

**真正解在服务端**：WebPush（VAPID + `webpush-go`，iOS 16.4+ 走 APNs 但
**不需要** Apple 开发者账号，前提是 PWA 加到主屏）或厂商通道聚合，均属
`super_partyb` / `mq-server` 侧，本仓库只提供订阅与回调的本地面。

> **2026-11-15 进展**：服务端 WebPush 已落地（`super_partyb` `239e30ce`：
> `internal/webpush` + `/api/push/*` + webapp 的 `manifest.json`/`sw.js`/设置面板，
> 部署与 iOS 两条硬约束见该项目 `docs/push-notifications.md`）。
> 它让 **webapp/PWA** 在后台收到确认、完成、失败等通知，但**不覆盖 Flutter 的原生推送**
> ——「App 被杀」这条仍要等 FCM/APNs（被 #83/#84 的 Apple 账号阻塞）。
> 本节「客户端加代码突破不了」的结论不变。
>
> **2026-11 补记**：另有一条**客户端兜底**——Android 的 `WorkManager` 每 15 分钟拉一次
> 待确认列表（`§6.111`）。它把「什么都收不到」变成「可能晚到，且用户能看见跑没跑」，
> 但**不是**推送：15 分钟下限、Doze、`force-stop` 一条也没消失。本节结论仍然成立。

**可观测判据**：

1. 挂起 ≥ 1 分钟后回前台 → 待确认列表发**一次** `GET /chat/confirmations`；
2. 同一场景下若连接是 `failed`，SSE 重连**恰好一次**；健康连接 → **0 次**；
3. `inactive → resumed` → **0 次**（两个计数都不动）。

**重新评估触发条件**：服务端 WebPush / 厂商通道落地后，本节的"客户端无法突破"
随之失效——届时需要重排 §6.99 的事件范围，并给移动端补通知渠道注册与
`DisplayMode.standalone` 的 PWA 壳。

---

### 6.109 通知的真机验证压成「三步」：Linux 走真 D-Bus 自动化，其余靠 App 内自检（2026-11，issue #90）

issue #90 的原始形态是一张 12 项的真机清单，在本机（Debian 12 LXC，无 `DISPLAY`、
无真机、无 `/dev/kvm`，§9）**一项都跑不了**。本轮把它拆成「能自动化的自动化、
不能的压到用户点三下」。

#### 关键事实：Linux 这条路不需要 GUI

`flutter_local_notifications_linux` 是**纯 Dart**（`dartPluginClass`，走 `dbus` 包
直连 `org.freedesktop.Notifications`，不依赖 libnotify 的 C 库）。因此
`flutter test` 可以驱动**真实现**，只要：

1. 有会话总线（`dbus-run-session`）；
2. 有人占住 `org.freedesktop.Notifications` 这个名字——测试里自己实现一个
   进程内假 daemon（`DBusObject` + 方法分派 + `emitSignal`）。

于是「通知弹出」被等价替换成「`Notify` 的参数正确」，「点击回到应用」被等价替换成
「daemon 发 `ActionInvoked` 后 `LocalNotificationSink` 拿回期望 payload」。
两条都在 `packages/spb_platform/test/local_notification_sink_linux_test.dart` 里。

**三个坑（改这条测试前必看）**：

| 坑 | 现象 | 解法 |
|---|---|---|
| `flutter test` 的 `defaultTargetPlatform` 默认是 **android** | 插件按 android 分派 → `initialize()` 返回 false、静默降级 | `debugDefaultTargetPlatformOverride = TargetPlatform.linux` |
| `flutter test` 不跑插件注册器 | `LateInitializationError: Field '_instance' ...` | 手动 `FlutterLocalNotificationsPlatform.instance = LinuxFlutterLocalNotificationsPlugin()`（不要写 `registerWith()`——它在 web 分支的 stub 上不存在，analyzer 报 `undefined_method`） |
| 机器上真装了 `xfce4-notifyd` 时 D-Bus 会按需激活它 | 名字被抢走；它无 `DISPLAY` 起不来 → `Spawn.ChildExited` | 假 daemon 用 `doNotQueue` 先占名字，**占不到就跳过**（不是失败） |

对齐的取舍：**没有会话总线时整组 skip**，不让「环境没总线」变成红灯；「插件不可用
时的静默降级」由 `local_notification_sink_no_dbus_test.dart` 单独守（它刻意不注册
平台实现，等价于无 D-Bus / 插件缺失）。

#### 其余三档，以及为什么不再逐项手工验

| 平台 | 覆盖方式 | 还差什么 |
|---|---|---|
| Linux | 上述自动化（含 `cancel` → `CloseNotification`） | 真实 daemon 的视觉呈现 |
| Android | CI emulator（`dumpsys notification` 断言 + `uiautomator` 点击）；本机无 `/dev/kvm`（§8 / #30） | 厂商 ROM 的额外权限页 |
| Windows / macOS | **App 内自检** + 用户口述结论 | toast 是否真弹、是否留在操作中心——CI 无交互桌面会话，只能真机 |

#### App 内自检（`LocalNotificationSink.selfTest`）

设置页多一个「通知自检」入口：发一条真的系统通知（payload = `/settings`），
**等点击最长 30 秒**，然后给出**四步里第一个失败点**的可读结论并写进日志
（于是也进诊断报告）。

四个设计取舍：

1. **四步分别记录，而不是一个 bool**：`initialize` / `permission` / `show` / 点击
   失败时用户看到的都是「没反应」，但修法完全不同（装配 / 权限 / 环境 / 回调接线）。
   报告给出 `outcome` 枚举 + 一行中文 `verdict`，是**给用户念给我们的那句话**。
2. **旁路捕获点击，不接管 `onSelect`**：`onSelect` 是业务导航的接线；自检若临时
   替换它，用户恰好在自检期间点了一张真实确认卡的通知，那次点击就丢了。
3. **结论留在页面上（subtitle）而不只是 SnackBar**：SnackBar 几秒后消失，
   报障时用户无话可念、无据可截。
4. **payload 用 `/settings` 而不是某个对话**：指向 `/chat/<gid>` 要先有真实群 id
   （换账号 / 空列表会退化成不存在的路由，用户点了落到错误页 → 被判成「点击坏了」）。
   设置页总是有效，且用户就在那里点自检、能在同一页看到结论。

入口显隐用**类型判定**（`sink is LocalNotificationSink`）而不是另开一个布尔开关：
开关会与真实装配脱钩（override 改了、开关忘了改 → 用户点一个永远失败的自检）。

#### 验证

- `local_notification_sink_linux_test.dart` 3 条（Notify 参数 / 点击回传 payload /
  `clickMissing` 不得渲染成 passed）+ `cancel` 一条；
- `local_notification_sink_no_dbus_test.dart` 3 条（初始化 false 不抛 / show+cancel
  静默 / 自检给出 `notInitialized` 与可读结论）；
- `settings_page_test.dart` 6 条（未注入隐藏 / 注入展示 / 单次触发 + 等待态禁用 /
  结论留存 / 未通过不得渲染成通过 / 抛异常不红屏）；
- 两端 `production_overrides_test.dart` 各 +1（真 sink 才有入口，Noop 下必须为 null）。

#### 未验证

- **Windows / macOS 的真机结论**：本机无这两端，自检入口只保证「装配正确、结论可读」，
  不保证 toast 真的弹出（**这正是 issue #90 保持 open 的原因**，#90 的勾选状态
  仍是事实记录，不要因为它「有工具了」就关掉）。
- **Android emulator 路径**：CI 里尚未接（需要 `reactivecircus/android-emulator-runner`
  与 KVM 的 ubuntu runner）；在那之前 Android 只能靠真机跑自检。

#### 状态栏小图标：必须是纯白剪影（`ic_notification`）

插件的 `AndroidNotificationDetails(icon:)` 决定**状态栏**那枚图标；不传时回落到
`AndroidInitializationSettings` 的 `defaultIcon`——我们曾经传的是 `@mipmap/ic_launcher`
（彩色启动器图标）。API 21 起状态栏图标必须是单色剪影，系统把彩色图当 alpha 蒙版用，
结果是一块实心白/灰方块，且只在真机上看得出来（CI 与单测都验不到）。

现在走**生成**而不是手绘：`tools/gen_brand_assets.py` 的 `notification_icon` 取
`_extract_bubble()` 的 alpha（浅色气泡轮廓，对勾处本就是透明洞），整片涂白 → 24dp 画布
留 2dp 内边距 → 五个 density。`--only notification` 只重生成这 5 张，不会顺手重写启动器
图标（那只会制造无意义的二进制 diff）。

同时修掉一处**静默失效**：`androidChannelId/Name/Description` 三个构造参数一直存在，
但 `_details()` 里写的是字面量，传了不生效、也不报错。现在读字段，并由
`packages/spb_platform/test/local_notification_sink_details_test.dart` 断言「传进去的
就是发出去的」——这几项都是**只有系统侧才看得出问题**的配置，测试至少能挡住「有人删了
某一行」。

**仍未验证**：真机上状态栏图标是否真的清晰（本机只能证明参数正确、剪影像素是纯白 + 透明）。

### 6.111 移动端后台检查（`WorkManager`）：一条「尽力而为」的兜底，以及它必须补的三件事（2026-11）

§6.102 的结论是「客户端突破不了后台送达」。**本节不推翻它**，而是记录后来做的一件事：
把「App 被杀后什么都收不到」改善成「可能晚到，且用户能看见它跑没跑」。定位写在最前面：

> 这不是推送，是**轮询**。它不承诺时效，只承诺「有机会补上一条」。
> 任何「确认卡要秒级到达」的需求，仍然要等 §6.102 说的服务端推送 / 厂商通道。

#### 能力边界（别把它当推送）

| 事实 | 后果 |
|---|---|
| `PeriodicWorkRequest` 最小间隔 **15 分钟**（硬下限，`setInitialDelay` 也不能更短） | 一张需要 1 分钟内回答的确认卡，通知到得比 turn 结束还晚 |
| Doze 会把任务推迟到维护窗口；App Standby 分桶到 `restricted` 时约 **1 次/24h** | 锁屏久了就是没有 |
| 用户从最近任务划掉（部分 ROM 等同 `force-stop`）→ 任务**完全不执行**，直到重新打开 App | 与 FCM 一样，这是用户动作，客户端绕不过 |
| **重启后 `WorkManager` 会恢复任务** | 这是它相对「前台服务常驻」唯一的实质优势（FGS 不能 `BOOT_COMPLETED`） |
| 国产 ROM 的自启动 / 省电策略 | 同上，需用户手动放行；与 distributor 那条路是同一堵墙 |

因此只做了两件事：**能补就补**，以及**让「跑没跑」可见**（见下文设置页读数）。

#### 必须补的三件事（缺一件就变成「重复打扰」或「静默失效」）

**① 跨 engine 的判重**。后台任务跑在**另一个 Flutter engine**（同进程、不同 isolate），
`ConfirmationNotifier` 内存里的 `notifiedIds` 不共享 → 前后台各弹一次同一条卡。
落地：`ConfirmationNotificationInbox`（`spb_domain`）+ `NotificationStateStore`（`spb_data`，
独立小库 `notifications.db`，避免占聊天缓存/文件同步的写锁）。互斥靠 **SQLite 写锁**
（`exclusive` 先写一个 mutex 键），不用 Dart `Future` 锁或 `File.lock`——后者不隔离同进程
的两个 engine。前台 `pendingConfirmationsProvider` 也走同一个 inbox，且传 `focused: true`
（只记账、不弹），这样「前台看过了」这条语义跨重启仍然成立。

**② 凭证与通知的联动**。后台刷新会**轮换 `refresh_token`**，两个 engine 并发刷新时后到的
那个拿着已作废的 token → 用户被永久登出。落地：`CoordinatedTokenStore`
（`ExclusiveTokenStore`）让 `SessionManager._doRefresh` 在锁内**二次读**，发现已被另一
engine 轮换就直接采用；登出 / 换账号时 `advanceSession` 递增会话版本、清空 receipts 并撤销
已发通知。

> **读路径刻意不加锁**：`currentAccessToken()` 每个 HTTP 请求都调，而 `exclusive` 是靠写
> 一个 mutex 键取 SQLite 写锁的——加锁等于「每个请求一次写事务」，还会排在另一个 engine
> 的刷新（跨网络，最长 30 秒）后面。锁的作用是串行化**轮换**，不是保护读。

**③ 稳定通知 id**。`String.hashCode` 不跨 isolate 稳定（Dart 文档明说），后台发的通知
前台撤不掉——#87 的另一半。落地：`stableNotificationId`（FNV-1a 取正 31 位）。
**一次性代价**：升级后旧通知的 id 映射变了，那几条残留通知撤不掉，只能等系统超时。

#### 不该弹的时候不能弹

判定链（任一条为「是」就不发）：

1. **前台**——`NotificationForegroundBridge`：`IsolateNameServer` 进程内端口，界面 engine
   注册、后台 engine 询问。**没有注册 = 不在前台**（进程被杀后重建的常态）；1 秒无回应按
   「在前台」处理（宁可少弹，不可误弹）。
2. **网络期间用户回到了前台**——发通知前**再问一次**（请求可能耗时几十秒）。
3. **换账号 / 登出**——比对会话版本，旧响应直接丢弃。
4. **没权限**——后台只**查询**权限（`areNotificationsEnabled`），绝不发运行时权限请求
   （后台弹不出权限框，那条通知只会被系统丢掉）。
5. **已过期**——`expiresAt` 到点不发；已发出的用 `timeoutAfter` 交给系统移除，不必等下一轮
   15 分钟去撤销。

#### 设置页必须给出「跑没跑」的读数

`notifications.last_success` 只在**成功**时写，设置页渲染三种**不同**的状态：

| 状态 | 文案 | 为什么必须分开 |
|---|---|---|
| 从未成功 | 「尚未成功执行过（需已登录并允许通知）」 | 这是「还没跑」，不是「功能坏了」 |
| 读取失败 | 「上次检查时间读取失败」 | 存储故障与「从未跑过」处置不同 |
| 有时刻 | 「上次成功：今天 09:32（系统可能延迟或跳过）」 | 只陈述事实，不承诺送达 |

没有这条读数时，用户报「收不到通知」我们只能猜——而「压根没跑」与「跑了但没有卡」的
排查方向完全相反。

#### 刻意不做开关

`enabled` 由「已登录 + 有通知权限」推导，不另设 UI 开关：多一个开关就多一个「关了但用户
以为是 bug」的状态，而且它和真实装配会脱钩（§6.109 里入口显隐用类型判定而非布尔开关，
是同一个理由）。要停就在系统设置里关通知——那时 `enabled` 也自动变成 false。

#### 依赖

`workmanager: ^0.10.10`（只在 `apps/spb_mobile` 声明，插件不进共享包）。它是 **0.x**
包，minor 版本就可能破坏 API，所以这个 caret 实际起「锁 minor」的作用——升级时必须重跑
后台任务那套测试（scheduler 注册/取消、worker 七条路径），不能只看编译通过。

#### 验证边界

- 单测覆盖：scheduler 的注册/取消与 `keep` 策略、worker 的七条路径（前台 / 无权限 / 登出 /
  503 重试 / 换账号 / 回到前台 / 正常发通知）、跨 engine 判重与互斥、`read` 不加锁、
  bridge 的四种形态、设置页三态渲染；
- **真机未验证**（与 §6.109 / #90 同一个瓶颈）：Doze 下的实际到达率、国产 ROM 省电策略、
  重启恢复、以及「15 分钟」在真实设备上到底是多久。这些只能真机跑，且**结论要回填 issue**，
  不要因为「代码齐了」就认为功能可用。

---

### 6.112 Windows 通知初始化缺一条设置：`InitializationSettings.windows` 必填，且失败要能查（2026-11）

Windows 桌面端「通知自检」报 **「通知插件初始化失败，通知将静默不生效（装配/平台通道问题）」**。
排查结论：**装配与平台通道都没问题，缺的是插件要求的一条初始化设置。**

#### 根因

`flutter_local_notifications` 在 Windows 分支对空值是硬性要求：

```dart
} else if (defaultTargetPlatform == TargetPlatform.windows) {
  if (settings.windows == null) {
    throw ArgumentError('Windows settings must be set when targeting Windows platform.');
  }
```

而 `LocalNotificationSink.initialize` 的 `catch` 会把任何异常吞成 `_initialized = false`
（**这是对的**：无平台通道 / 无 D-Bus 时不该崩），于是自检只能报四步里第一个失败点
（§6.109 的 `notInitialized`），文案指向「装配/平台通道」——**方向完全指错**。

漏掉的原因很具体：`flutter test` 都在 Linux 上跑（`defaultTargetPlatform == linux`，
`linux:` 一直是给着的），Windows 分支只由 GH Actions 的 tag 构建编译，没人跑过自检。

#### 修法

| 面 | 做法 |
|---|---|
| 设置 | `windows: WindowsInitializationSettings(appName, appUserModelId, guid)`；`appName` / `appUserModelId` 做成构造参数（可测），`guid` 是**写死的常量** |
| GUID | 它是 COM 激活器的注册键：换值 = 旧通知点不动（payload 回不来）+ 每次启动留一条无主注册项。不是密钥，公开无风险，**不要**随机化 |
| AUMID | 与安装包标识一致（`windows/runner/Runner.rc` 的 `CompanyName.ProductName` = `com.atjog.spb.spb_desktop`）；不一致时 toast 归不到本应用，部分 Windows 版本静默丢弃 |
| 可测性 | 插件是**单例**（私有构造 + factory），无法继承捕获参数 → 抽 `@visibleForTesting debugInitializationSettings` getter（与 `debugNotificationDetails` 同一取向：能验的只有「喂给插件的参数对不对」） |
| 回归测试 | `local_notification_sink_windows_settings_test.dart`：用 `debugDefaultTargetPlatformOverride = TargetPlatform.windows` 断言 `windows != null` + 字段来源 + GUID 形态 + 「真插件不再抛 ArgumentError」+ 其他平台设置没被顺手删掉 |
| 可观测 | 失败日志从 `debugPrint` 改 `SpbLog.warn`：诊断报告只导出 `SpbLog` 的环形缓冲，而 release 的 Windows 包没有控制台——`debugPrint` 等于把唯一线索丢给空气 |

#### 修好之后仍然改不掉的两条（别当 bug 再查一遍）

1. **非 MSIX 打包：`cancel()` 是空操作**（插件 README「Windows limitations」），
   `getActiveNotifications` 也返回空。确认卡过期后横幅**不会**从操作中心消失，只能等系统
   超时；「撤销已发通知」在 Windows 上等于没做。要去掉得改用 MSIX 分发（有签名成本，
   本仓库目前没有 `msix` 配置）。
2. **`timeoutAfter` 是 Android 专属**：Windows 端没有等价物，过期抑制只能靠我们自己
   的 `expiresAt` 判断（`_showInternal` 已有）。

#### 验证边界

单测证明「设置项齐全、插件不再因此抛 `ArgumentError`」；**证明不了 toast 真的弹、
点了真的回到应用**——仍需 Windows 真机（§9），且 `flutter run -d windows` 才能在控制台
看到那条 `[notifications] …` 日志。
