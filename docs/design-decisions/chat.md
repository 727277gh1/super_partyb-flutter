# 对话与流式

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。对话时间线的正确性核心：无归属入口、失败重发、对话内搜索、定位键所有权、
流式归约合并、缓冲裁剪、乐观回显、用量读数、归属提示。

> 编号（`§6.x` / `§5.x` / `[§7](build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](README.md)。

---

### 6.7 无归属入口：两端统一走 enqueue

无归属入口（没有对话 UI 的入口）**两端只有一条路径**，走 `OverlayQuickCapturePage`：

| | `OverlayQuickCapturePage` |
|---|---|
| 端点 | `POST /me/quick-capture/enqueue`（附件先经 `POST /me/quick-capture/attachments` 上传） |
| 附件 | ✅ |
| 返回 | **异步**投递，只有受理结果，**无 `group_id`** |
| 路由 | `/overlay`（桌面端 `Alt+Space` / 移动端 AppBar） |
| 落点 | `router_preferences`（worker 消费后写） |

**为什么删掉了同步端点那条路径**：`ChatApi.quickCapture`（同步返回归属
`group_id`、**无附件**）是 enqueue 的**功能子集**，却单独占一条客户端路由。
两端都已删除该路由（桌面端 commit `1866b14`；移动端见
`apps/spb_mobile/lib/router.dart` 中 `SpbRoutes` 的文档与 `providers.dart` 里
`quickCaptureEnqueueUseCaseProvider` 的说明）。

⚠️ `spb_features` 里仍保留 `QuickCapturePage` 组件（走同步端点、展示服务端
归属判定结果、由 `onQueued` 交出导航目标），但**当前无生产调用点**，只被自身
测试覆盖。这是**有意保留**而非遗漏：将来若需要「提交后立即导航」的场景
（enqueue 拿不到 `groupId`，做不到），再把它接回去。

**附件只能走 enqueue**：附件的「落用户级暂存区 → 建 turn 时搬进 workspace」
这条链路只存在于 MQ 渠道（`mq-server` 的通用入站口）。

**提交链路**（客户端**不得**持有 mq-server 的 `api_token`，那是服务级凭据）：

```
Flutter → POST /me/quick-capture/attachments  → PartyB Go API → mq-server /api/v1/inbound/uploads
Flutter → POST /me/quick-capture/enqueue      → PartyB Go API → mq-server /api/v1/inbound/enqueue
                                                   ↑ 服务级 Bearer 在这里注入
```

**两个安全约束**（改动时不要绕过）：

1. **身份取自网关注入的 session**，请求体里的 `user_id`/`group_id`/`agent_id` 一律忽略。
2. **附件只接受文件名，不接受 URL**——消费侧会带服务级 Bearer 去下载它，
   允许客户端指定 URL 就是个 SSRF 面。

**enqueue 提交后不导航**：投递是异步的，本页拿不到 `groupId`。结果由主窗口订阅 SSE 呈现。

### 6.14 失败 turn 的重发（`ErrorItem` → 重新投递）

`error` 事件是**回合终态**（`event_reducer.dart` 把它登记进 `terminalTurnIds`）：
服务端执行失败后本轮不会再产出任何内容。此前客户端只在时间线渲染一条错误条
——用户唯一的出路是手动重打一遍，而那会变成一个**新 turn**，与失败那轮并列。

webapp 早有这个入口（`ChatMessageList.tsx` 的 `handleRetryTurn`），客户端此前没有。

#### 链路

| 层 | 改动 |
|---|---|
| `spb_ui` | `ErrorBanner` 新增可选 `onRetry` / `retryLabel`（为 null 时不渲染按钮，同 `ErrorState`） |
| `spb_domain` | `UserMessageItem.agentId`（本地回显独有） |
| `spb_features` | `ConversationPage.onRetryTurn` + `_handleRetryTurn`（防重复点击） |
| `apps/*` | 注入 `onRetryTurn`，走 `controller.send(groupId:, agentId:, routingMode: 'manual')` |

#### 四个易写错的点

1. **必须换一个新的 `request_id`。** 沿用失败那轮的 id 会命中服务端
   `(user_id, request_id)` 幂等去重，直接返回**那个已失败的 turn**，等于什么都没做
   （webapp 的注释专门记了这一点）。故装配层**不传** `requestId`，由服务端生成。
2. **`routingMode: 'manual'`**：锁定原 group，不再跑归属判定——否则可能再触发一次
   归属歧义确认（而那正是用户刚失败的那一轮的前置步骤）。
3. **按 `turnId` 找原输入，不能取「最后一条用户消息」**：用户在失败后又发了几条时，
   后者找到的是别人的输入。找不到原输入时**不发请求**（按钮静默无反应）——拿别的
   文本去发会把「重发」变成「乱发一条」。
4. **`agentId` 在权威帧到达后仍要保留**：服务端 `user_message` 事件不带 `agent_id`
   （那是客户端回显独有的键），归约器原位替换时从旧项继承。否则用户看到的输入框还
   选着某 agent，重发却换了人。

#### 有意不做：`session_expired` 的串行 restore

webapp 在 `errorType === 'session_expired'` 时先逐个 `restoreChatSession` 再重发。
客户端不做，因为**服务端不产出 `errorType`**：客户端拿到的 `error` 事件 payload
只有 `message`/`error`，没有类型字段。没有这个信号就无法区分「会话失效」与普通
执行失败——按 webapp 那样无条件 restore 会引入一个无用的往返。

同理，**`ErrorItem.isRecoverable` 归约层恒为 true**（`error` payload 没有可判定的
分类字段），由调用方按需置 false。

#### 相关：`createTurn` 的请求体契约（同批修复）

`ChatApi.createTurn`（`POST /chat/groups/:group_id/turns`）此前发的是
`{input, agent_id, request_id}` 并解析成 `ChatTurn`——**字段名与响应形状双双不符**：

| 项 | Go 期望 | 此前发的 |
|---|---|---|
| 文本键 | `inputText`（`binding:"required"`） | `input` → 400 |
| 幂等键 | `requestId`（camelCase） | `request_id` |
| 响应 | `{status, groupId, turnId}` 平铺 | 解析成 `ChatTurn`（得到全空对象） |

该方法此前**无生产调用者**，故缺陷未暴露。现已修正为 `CreateTurnResult` 并补
真 server 断言（`chat_api_schedule_test.dart` 的 `createTurn 请求体字段名`）。

⚠️ **重发走的是消息流而不是本端点**：`CreateTurnRequest` 没有 `agent_id` 字段
（服务端按 group 的 active session 决定），且 webapp 也因同样理由弃用了它。
本端点保留给「已知 group 且要绕过前置链」的脚本化场景。

### 6.15 对话内搜索（搜已加载的时间线，**非**服务端检索）

客户端此前只有**全局搜索页**（`SearchPage`：`GET /me/turns/search`，只搜用户输入、
跨对话）。issue #31 的排查过程中补上了**对话内搜索**：搜当前已加载的时间线，
**含 agent 回复**。

#### 为什么是本地的、而不是新加一个服务端端点

时间线本就全在内存里（`_items`，归约结果）。补一个服务端端点要做：
新 SQL（`chat_events` 全文）、新分页契约、新事件类型同步——而**已加载的部分**
用户本来就能用 `Ctrl+F` 式的本地查找回答。两端的分工是明确的：

| 面板 | 数据面 | 语义 |
|---|---|---|
| 全局搜索页 | 服务端（跨 group、仅用户输入） | 「我在哪儿说过这件事」 |
| 对话内搜索 | **本地已加载的时间线** | 「这段对话里 agent 说的那句在哪」 |

⚠️ **本地搜索有边界，必须告知用户**：只搜**已加载**的（分页加载的历史不在内）。
故面板顶部在 `upperHistoryUnloaded` 为真时显示「仅搜索已加载部分，上方还有更早历史」
——不告知会让用户把「没搜到」误读成「不存在」。
（⚠️ 参数名是 `upperHistoryUnloaded`，**不是** `hasMore`：后者是 controller 里
「是否还有更早历史」的字段，语义不同——见 `ConversationSearchResult` 文档。）

#### 分层归属

| 层 | 内容 | 为什么在这一层 |
|---|---|---|
| `spb_domain` | `conversation_search.dart`：`searchConversationItems(items, query)` → `ConversationSearchResult`（命中项 + 摘要 + 是否截断） | 匹配/摘要/排序是**正确性核心**，须能无头单测 |
| `spb_ui` | `HighlightedText`（命中片段高亮） | 无业务语义的展示组件 |
| `spb_features` | `conversation_search_sheet.dart`（面板）+ `ConversationPage` 的 `_openSearch` / `_scrollToItem` | 需要页面的 `ScrollController` 与 `_items` |

#### 四个易写错的点

1. **查询词按字面量匹配，不做正则**。用户输入 `(`、`*`、`[` 等元字符时，
   `RegExp` 会抛 `FormatException`。`search_page.dart` 曾有同样的高亮需求，
   也踩过这个坑——`HighlightedText` 用 `indexOf` 循环而非 `split`/`replaceAll`。
2. **高亮保留原文大小写**。查询 `todo` 命中 `TODO` 时，高亮的 span 文本必须是
   `TODO`（原文），不是 `todo`。服务端 `LIKE` 也是大小写不敏感的——两端语义一致。
3. **命中后要滚回时间线**。搜索面板是**弹层**（`showModalBottomSheet`），点击
   命中项要 `Navigator.pop` 关闭它**再**滚动——在弹层还开着时滚动，用户看不到
   效果，会以为「点了没反应」。
4. **摘要要截断且居中命中处**。一条几千字的回复若从头截，命中词可能落在第 3000
   字（摘要里看不到）。`searchConversationItems` 内部以命中位置为中心取窗口
   （产出 `ConversationSearchHit.snippet`），两端都加省略号。

#### 有意不做

- **不搜交付物文件名 / 工具调用参数**：前者是 UFS 数据面（另一条路径，面板已
  有），后者是工具入参与输出（服务端事件里的 `tool_args` / `output`）——它们是过程
  信息，看的地方是「动态」面板（[§6.54](ui.md)），不是对话内搜索。
- **不做「高亮全部 + 上/下跳转」**（浏览器 `Ctrl+F` 那种）：需要维护「当前第几个
  命中」的游标与循环跳转，属独立交互；当前只做「列出命中 + 点一条滚过去」。
- **不做正则 / 模糊 / 拼音**：与全局搜索页的 `LIKE` 语义保持一致（AGENTS.md [§6.2](architecture.md)
  的契约同步取向）。

### 6.18 `_rowKeys` 的注册与回收（issue #39）

时间线搜索定位用 `GlobalKey`（变高列表无法自己算偏移量），其注册 + 回收抽在
`spb_features` 的 `RowLocateRegistry`（`packages/spb_features/lib/src/chat/row_locate_registry.dart`）。

**此前只有注册（`putIfAbsent`）、从不回收**：时间线只保留最近 2000 条事件，
旧项被裁掉后键仍在 Map 里；跨 group 切换（State 复用）持续累积，且旧
`GlobalKey` 会让对应 Element 无法回收。

#### 三条互相拉扯的约束

| 做错的方向 | 后果 |
|---|---|
| 注册少了 | 搜索命中后找不到键 → 退化成「请向上滚动」，而目标在屏幕上 |
| 回收少了（修复前的状态） | 跨 group 累积，Element 无法回收 |
| **回收多了** | 仍在渲染的行的键被删 → 下一帧生成新键，`KeyedSubtree` 卸载重挂，**滚动位置丢失** |

故 `recycle(liveIds)` **只删不在时间线上的 id**，绝不 `clear()` 重建。

#### 「一行占哪些 id」是领域层口径

`locateIdsOf(row)` / `locateIdsOfAll(rows)`（`spb_domain` 的 `agent_file_batch.dart`）
是唯一口径，页面用它**同时**做注册与回收——两处若各写一份，回收会漏算
**批量卡的非首成员**（批内 5 个文件共用同一张卡、同一个定位点），把仍在渲染的
行的键删掉。

`RowLocateRegistry` 与 `locateIdsOf` 都是纯函数/纯逻辑，故可在无 widget 环境逐条
断言（`row_locate_registry_test.dart` 17 条、`agent_file_batch_test.dart` 新增 5 条）。

#### ⚠️ 键的**所有权**必须与「成员定位入口」分开（一次真实事故）

上面那句「批内 5 个文件共用同一张卡、同一个定位点」曾被实现成「把同一个
`GlobalKey` 实例写给每个成员」。那是错的，用户报障是
**「对话内容一滚动就会丢失，然后继续滚动又出现」**。

| 表 | 内容 | 用途 |
|---|---|---|
| `_owned` | 行主键（`ids.first`）→ `GlobalKey` | **真正挂在 widget 上的键**，一行一个，绝不共享 |
| `_aliases` | 成员 id → 行主键**名** | 只供 `operator []` 查（批内任一成员都要能定位到那张卡） |

**为什么「共享键实例」会渲染空白**：一旦**同一段文件被拆成多行**，多行就会拿到
同一个 `GlobalKey` → Flutter 抛 `Multiple widgets used the same GlobalKey` →
**后出现的那几行渲染为空白**（滚走再滚回来又重建出来）。而 `recycle` 拦不住
——它按 id 是否在时间线上过滤，那些 id 确实还在。

拆分是真实会发生的，有两条路径：

1. **缓冲区裁剪**（`ChatStreamController._trimBuffer`，上限 `maxBufferEvents`=2000）
   从头部丢最旧事件，边界可能落在批量卡中间：7 个文件剩 4 个，不足
   `FILE_BATCH_MIN_COUNT`（5）→ 退回 4 个 `SingleItemRow`；
2. **翻页拼接**：`loadOlder` 前插的一页与缓冲区头部同 turn 同秒时会**合并**成
   批量卡；页边界若切在批中间，头部那段先以「不足阈值」落单，补上更早那一页后
   又并回批量卡。用户「滚上去、再滚下来」就能让它在两种形态间反复翻转。

故 `keyFor` 里**只有 `ids.first` 能成为键的所有者**，其余 id 只登记别名；且
`keyFor` 会把「上一帧还是主键、现在变成别名」的那个 id 从 `_owned` 里摘掉
（否则 `operator []` 按「主键优先」返回悬空键）。

#### 两个易写错的点（写测试时踩过）

1. **纯逻辑测试抓不到它**。`row_locate_registry_test.dart` 自己构造拆分状态，能
   钉住「各行拿到不同的键」，但钉不住「页面真的这样用它」。故另加页面级用例
   `conversation_page_row_keys_test.dart`（真实控制器 + 真实 `_trimBuffer`）。
2. **页面级用例必须分两阶段推事件，中间真正 `pump` 一次**。缺陷只在「页面已经
   为批量卡建好键、随后该卡被拆散」时触发；若把 2003 条一次推完再 pump，页面
   首次构建看到的**已经**是 4 个落单行，撞键根本不发生——用例会在**修复前的
   代码上变绿**（实测踩过）。

那条用例用 `executor_started`（诊断事件，进缓冲区但不产对话项、也不产
`executionStatus`）当填充物：既让裁剪逻辑与真实场景一致，又只渲染 4 行，
耗时 ~1s。换成 `user_message` 会让时间线真有 2000 行（`pumpAndSettle` 十几秒），
换成 `queue_state` 会挂出转圈的「排队中」条（`pumpAndSettle` 永不静止）。

### 6.23 流式归约合并（issue #44）——**并纠正 issue 里的一个错误方案**

#### 问题（实测）

流式回复是逐 token 增量（`message` 的 `transient: true`）。一个长回复产生几百条
事件，而 `_emit` 原来**每条**都 `EventReducer.reduce(_buffer)` 全量重算（缓冲区
上限 2000 条）并重建整个 items 列表。

```
单次归约（2000 条）: 1767 µs
300 条增量 × 全量归约: 640 ms   ← 全在 UI 线程
```

> ⚠️ **§6.48 之后，「300 条增量」不会再是 300 条缓冲事件**：紧邻同类增量在
> 入缓冲前就合并成 1 条了。故本节的「640 ms → 19 ms」现在实际是「19 ms → 几乎
> 免费」——归约只在**批次**上跑一次，输入也从 300 条降回 1 条。这里的数字保留
> 作为「合并**前**」的历史基线，`_emit` 的 `Timer` 合并仍然必要（它管的是
> 多个**不同**事件的批处理，与增量合并是两层）。

#### ⚠️ issue 建议的 `scheduleMicrotask` **不成立**（实测）

issue 原文建议用 `scheduleMicrotask` 合并，并给出理由「microtask 在同一事件循环
轮次结束前执行」。但**投递粒度**决定了这行不通：

| 调度方式 | 5 条同步增量的归约次数（实测） |
|---|---|
| `scheduleMicrotask` | **5**（完全没合并） |
| `Timer(Duration.zero, ...)` | **1** |

原因：broadcast stream 把 N 次同步 `add` 投递成 **N 个独立 microtask**（每次只投
一个事件，实测 `listener(0)` → 一个 microtask → `listener(1)` → …）。从 listener
里排的 microtask 排在「下一个事件」之前，于是每条都夹一次归约。

只有事件循环**任务**（Timer）能跨过整批。故实现用 `Timer(Duration.zero, ...)`。
延迟代价只是一个事件循环轮次（实测顺序 `microtask → timer → delayed(zero)`），
远小于一帧。

#### 三个设计要点

1. **`touchedTurnIds` 必须是 `Set`**，不能只留最后一个。一批里可能含**多个
   turn** 的事件（turn A 的尾部 + turn B 的开头）。只留最后一个会让另一个 turn
   的看门狗计时器不被重排 → 它会按**原**到期时刻被判 stale（误报）。
2. **`_reductionDirty` 脏标记 + 同步兜底**。归约被推迟后，`snapshot` /
   `gateDecisionsSnapshot` 等同步读不能拿到旧缓存。置脏后 `_reduction` getter
   现场重算（有专门用例钉住「push 后不 await 直接读就是新内容」）。
3. **dispose / switchGroup 丢弃挂起的合并**。`dispose` 取消计时器（
   `hasPendingEmit` 断言）；`switchGroup` 清 `_pendingTouchedTurnIds`——后者是
   fail-safe 路径（清与不清在现有断言下不可观测），已在代码里注明。

#### 效果

```
300 条增量 × 全量归约(2000): 640 ms   →   19 ms（合并后只归约 1 次）
```

#### 测试（`chat_stream_controller_emit_test.dart`，12 条）

- 一批 5/10/300 条增量 → **只推送 1 次** items（修复前是 5/10/300 次）；
- 分两批推 → 各自归约一次（不跨批错误合并）；
- 合并**不得丢内容**：5 段增量仍拼成完整文本；
- 同步读不得拿到过期结果（缓存置脏后现场重算）；
- 一批里两个 turn 都有增量时，**两个**计时器都被重排；只触及一个时不误续期旁边那个；
- 调度方式的**证据测试**：钉住「broadcast 同步 add 是每事件一个 microtask」这一
  事实，避免将来有人「优化」回 microtask 又退回每条一归约；
- dispose 取消挂起计时器；switchGroup 丢弃挂起的 touched。

#### 反向验证（逐条实测）

| 改坏 | 失败用例数 |
|---|---|
| 去掉合并（每次立刻归约） | 3 |
| 去掉脏标记兜底 | 6 |
| `touchedTurnIds` 改成只留最后一个 | 1 |
| dispose 不取消挂起的计时器 | 1 |
| switchGroup 不丢弃挂起的 touched | **0（fail-safe，诚实记录）** |

#### 对既有测试的影响（两处适配，非放宽断言）

归约延迟到事件循环任务后，测试需要显式跑该任务：

| 文件 | 适配 |
|---|---|
| `chat_stream_controller_stale_test.dart` | 新增 `drain(async)`：`flushMicrotasks` + `elapse(Duration.zero)` + `flushMicrotasks`。`fake_async` 里零延迟 Timer 必须 `elapse` 才跑 |
| `conversation_page_*_test.dart`（6 个，共享 `test/support/conversation_page_harness.dart`） | `pushEvent` 在 `runAsync` 内多等一个真实轮次 |

⚠️ **`conversation_page_harness.dart` 的坑**：控制器的帧订阅是在
`startController` 的 `runAsync` 里注册的，故 `_emit` 的 Timer 落在**真实时区**
——`tester.pumpAndSettle()` **永远跑不到它**（实测 `pump(5ms)` 也不触发，只有
`runAsync` 内真实等待才行）。这是「测试环境与生产时区不一致」的又一实例。

#### 关于 `_displayRows()`（issue 的「备选」方案）：**本轮不改**

实测 `groupFileEventsForDisplay` 的成本：

| items | 成本 |
|---|---|
| 200 | 245 µs |
| 1000 | 511 µs |
| 2000 | 1007 µs |

即满缓冲区下一次 build 约 1 ms。合并把一次突发的 build 次数从 300 降到 1，
总成本已从「640 ms」降到「19 ms + 1 ms」——**备选方案要解决的那个「每次 build
重算」已被主修大幅摊薄**，单独缓存它收益不足（且需在 `_onItems` 里同步维护，
多一处可忘的地方，与 `_displayRows` 现有注释里的取舍一致）。

### 6.28 零调用者端点的契约测试——**并查出第二个同类缺陷**（issue #49）

issue #49 的出发点是 §6.14 记录的先例：`createTurn` 因为**零生产调用者**，
字段名与响应形状双双写错却长期潜伏。本轮给同类的零调用者端点补契约测试，
**过程中查出了 `groupConfirmations` 的路径缺陷**。

#### 一、查出的真实缺陷：`groupConfirmations` 缺 `/api` 前缀

| | 客户端拼的 | 服务端注册的 |
|---|---|---|
| `groupConfirmations` | `/chat/groups/:id/confirmations` ❌ | `/api/chat/groups/:group_id/confirmations` |
| `listConfirmations` | `/chat/confirmations` ✅ | `/chat/confirmations`（无 `/api`）|

两者**前缀不同**，容易看错：

- `/chat/confirmations`（**无** `/api`）：`router.go:138` 的
  `confirmRG := chatRG.Group("/confirmations")`，挂在 `chatRG := r.Group("/chat")` 下；
- `/api/chat/groups/:group_id/confirmations`（**有** `/api`）：
  `ext_routes.go:40` 的 `registerConfirmRoutes(api.Group("/chat/groups/:group_id/confirmations"), db)`，
  而 `registerExtRoutes` 的唯一调用点是 `router.go:170` 的
  `registerExtRoutes(apiv1, ...)`，`apiv1 := r.Group("/api")`。

故客户端的 `groupConfirmations` **必然 404**。它此前无生产调用者，缺陷潜伏。

⚠️ **webapp 的 `listGroupConfirmations` 也拼同一个错路径**
（`group-chat.ts:1569`）——那是上游的既有缺陷，不在本仓库修复范围。客户端按
**服务端真实路由表**拼，不照抄 webapp 的 bug（否则两边一起错、更难发现）。

#### 二、为什么用真实 `HttpServer` 而不是 `DioAdapter`

**这是本轮最关键的方法论**：`DioAdapter` **测不出路径缺陷**——它按测试注册的
路由匹配，测试注册什么就匹配什么。只有真实 server 的 `req.uri.path` 才能断言
「客户端到底请求了哪个路径」。

故新文件 `chat_api_contract_test.dart` 用 `dart:io HttpServer` + 一个记录
`req.uri.path` 的小 `Recorder`（与 [§6.27](testing.md) 的端到端测试同一取向）。

#### 三、覆盖的端点（31 条）

| group | 端点 | 断言要点 |
|---|---|---|
| group CRUD | `listGroups` / `getGroup` / `createGroup` / `patchGroup` / `deleteGroup` / `archiveGroup` / `unarchiveGroup` | 路径；`groupToDict` 的 snake_case；**`patchGroup` 只发显式传入的键**（服务端用指针字段三态区分「未提交」与「清空」，多发键会强制覆盖）；空串=清空必须真的发键 |
| timeline | `groupTimeline` | 路径；`eventToDict` 的 snake_case；**游标优先 `next_before_global_seq` 而非 `next_cursor`**；空页 |
| turns | `listTurns` / `getTurn` / `cancelTurn` | 路径；`turnToDict`；`cancelTurn` 是 POST 不是 DELETE |
| confirmations | `listConfirmations` / `listConfirmationsTyped` / `groupConfirmations` | **两套前缀不同**（见上表）；`{items: [...]}` 解析 |
| sendMessage | `POST /users/:uid/chat/messages` | 平铺响应（**不是** `{turn: {...}}`）；**无归属入口不得发 `group_id`**（否则绕过服务端分类链，§5.5）；`feedback_recorded` 回执；`deduped` |

#### 四、决策表（issue #49 的验收标准）

issue 要求逐项给出结论。实际核实后：**除了新查出的 `groupConfirmations`，其余
零调用者方法都已有契约测试**（在 `agents_api_test` / `habit_api_test` /
`ufs_api_test` / `miniapp_api_test` 里），故本轮只需补缺的那几个。

| 方法 | 结论 | 依据 |
|---|---|---|
| `createTurn` | ✅ 补测试（已 3 条，本轮 +2） | §6.14 已明确「保留给脚本化场景」 |
| `listTurns` | ✅ **本轮补测试**（此前 0 条） | 路径正确（`/chat/groups/:id/turns`，`chat.go:39`），但响应形状未验 |
| `groupConfirmations` | ✅ **本轮补测试 + 修缺陷** | 见上（缺 `/api`） |
| `listConfirmations` | ✅ **本轮补测试**（此前 0 条） | 路径正确，但 `{items}` 解析与 typed 版未验 |
| `getAgent` / `listGroupSessions` | ✅ 已有测试，**保留** | `agents_api_test.dart:225/262`；路径核实正确 |
| `getHabit` | ✅ 已有测试，**保留** | `habit_api_test.dart:146`；`/api/habits/:id` 核实正确 |
| `getFile` | ✅ 已有测试，**保留** | `ufs_api_test.dart:354/365` |
| `getArtifact` | ✅ 已有测试，**保留** | `miniapp_api_test.dart:546/565` |

**为什么不全删**：issue 的路线 B（删掉）适用于「确认客户端永远不做」的方法。
但上述几个的路径经核实**全部正确**且已有测试——删掉反而是损失能力（单对象读取
在将来「已知 id 要刷新一条」的场景有用）。真正的「有意不做」是 [§6.9](runtime-and-ops.md) 的**端点族**
（管理面），不是这些单个读方法。

#### 五、覆盖率

| | 前 | 后 |
|---|---|---|
| `chat_api.dart` | 66.9% | **85.8%**（350/408）|
| `spb_api` 整包 | 82.6% | **87.8%**（1303/1484）|
| `spb_api` 用例数 | 386 | **430** |

#### 六、反向验证（逐条实测）

| 改动 | 结果 |
|---|---|
| `groupConfirmations` 去掉 `/api`（原缺陷） | **2 条失败** |
| `listTurns` 路径 `turn` 少个 `s` | **1 条失败** |
| `createTurn` 发 `input` 而非 `inputText`（§6.14 原缺陷） | **1 条失败** |
| `listGroups` 路径加 `/api` + `cancelTurn` 改 `_delete` | **2 条失败** |
| `patchGroup` 无条件发全部键（破坏 PATCH 语义） | **1 条失败** |
| `sendMessage` 无条件发 `group_id`（绕过分类链） | **1 条失败** |

#### 七、一个易踩的断言细节

`ChatTurn.fromJson` 把 `created_at` 做了 **`.toLocal()`**（与 `spb_models`
其余模型一致）。故断言时间不能写 `expect(t.createdAt, DateTime.utc(...))`
——本机是 UTC+8，实际得到 `16:09:10`。要写 `expect(t.createdAt.toUtc(), DateTime.utc(...))`。

---

### 6.28.1 归属反馈「点了没反应」：两个叠加的缺陷（2026-10）

用户报障「归属反馈卡点了没反应」。查下来是**两个独立缺陷叠加**，且都属
§6.28 同一类「零契约测试 + 错误断言把 bug 固化成预期」。

#### 缺陷一：请求体键名错（`correct` vs `reply`）——请求根本到不了 CAS

客户端发 `{'correct': bool}`，而服务端 `feedback_resolve.go` 的入参结构只有：

```go
type resolveFeedbackRequest struct {
    Reply   string `json:"reply"`
    Index   int    `json:"index"`
    GroupID string `json:"group_id"`
}
```

`ShouldBindJSON` **静默忽略未知字段**，于是 `Reply` 留空 →
`composeFeedbackReply` 返回 `""` → `400 {"error":"reply is required"}`。

实测（真实路由 + 临时探针）：

```
{"correct": true}  → 400 {"error":"reply is required"}
{"reply": "准确"}   → 200 {"resolved":true,"turn_id":"t1"}
```

修法：`ChatApi.resolveFeedback` 改发 `{'reply': correct ? '准确' : '不准确'}`。
两个词都落在 `confirmtext` 的肯定/否定词表里（端点会先 `Canonicalize`），
合成出的回执是 `反馈#<token>#正确`。文案选「准确」而非「正确」是为了与
卡片按钮 label（`FeedbackRequestCard.defaultOptions`）一致。

#### 缺陷二：置灰只依赖服务端旁路事件 —— 修完键名仍可能「没反应」

卡片 `resolved` 此前**只**看 `routing_feedback` 事件（`event_reducer.dart:542`）。
而回执是**一次性 CAS**，且该事件是旁路事件：

| 场景 | 结果 |
|---|---|
| SSE 断线 / 回放窗口被穿透 | 事件永不到达 → 卡片永久显示「这次归属准确吗？」且按钮可点 |
| 用户重试 | 第二次必然 404（CAS 已消费） |

用户看到的就是「点了没反应」，且越点越坏。

修法（三处协同）：

| 位置 | 改动 |
|---|---|
| `ConversationPage.onResolveFeedback` | 签名 `void` → **`Future<void>`**。确认卡可以 fire-and-forget（服务端会在同一 turn 内回 `confirmation_resolved` 收敛），反馈没有这条回路，必须把结果交回来 |
| `ConversationPage._handleResolveFeedback` | 成功才 `_submittedFeedback.add(token)`（乐观置灰）；失败 `_showMessage` 且**保留可点** |
| 渲染 | `resolved: item.resolved \|\| _submittedFeedback.contains(item.token)`——事件到达后权威接管，永不到达时也不退化 |
| 两端 router | 去掉 `.catchError(debugPrint)`，让异常上抛给页面 |

**404 的文案单独处理**：服务端把「已过期 / 已消费 / 非本人」三者**统一返回
404**（避免存在性探针，`interactive_request.go:120`）。写成「提交失败」会让
用户反复重试一个永远不会成功的请求，故提示「这条反馈已失效，无法再作答」。

#### 为什么修复前测试全绿（三处假绿）

| 既有测试 | 它断言了什么 | 漏了什么 |
|---|---|---|
| `spb_api` 全包 | **零条** `resolveFeedback` 用例 | 路径与请求体从未被验过 |
| `apps/spb_desktop/test/router_chat_test.dart` | `containsPair('correct', true)` | 断言的正是**错误键名**，把 bug 固化成了预期 |
| `apps/spb_mobile/test/router_chat_test.dart` | `containsPair('correct', false)` | 同上 |
| `conversation_page_timeline_test.dart` | 「点击回调收到 token 与 bool」 | 只测回调被调用，不看卡片后续状态 |

#### 本轮补的用例（共 11 条）

| 层 | 用例 |
|---|---|
| `spb_api` 契约（真实 `HttpServer`） | 肯定回执 `reply='准确'` 且**不含** `correct` 键；否定回执 `reply='不准确'`；token 原样进路径；404 抛 `HttpError` |
| `spb_features` | 提交成功后**本地置灰**（显示「已反馈」、按钮 `onPressed == null`）；提交失败提示且**保留可点**；404 提示「已失效」而非「提交失败」 |
| 两端 router | 断言改为 `containsPair('reply', …)` + 显式断言不含 `correct` |

#### 反向验证（实测）

| 改坏 | 结果 |
|---|---|
| 请求体改回 `{'correct': bool}` | `spb_api` 契约 **2 条失败** |
| 去掉 `_submittedFeedback` 乐观置灰 | 「提交成功后本地置灰」**1 条失败** |
| 失败也置灰 | 「失败时保留可点」**1 条失败** |

#### 与 TTL 的关系（**别再往那个方向修**）

`AttributionFeedbackTTL` 已是 **24h**（`domain.go:35`，按 kind 分派见
`InteractiveRequestTTLForKind`），生产实测 `expires_at - created_at = 24.0h`，
2026-10-18 起生效。用户报障时 34 条请求、0 条标注——**在请求根本发不出去
的情况下，TTL 多长都拿不到数据**。

「事件不超时、等归档后自然不能改」这个提案**不成立**，三条硬依据：

1. **`pending` 行的存在本身就是「待答」语义**。`LatestPendingAttributionFeedback`
   取「本 group 最近一条 pending」作隐式锚点（IM 纯文本路径）。永不超时 = 三个月前
   的请求仍可能被一句无关短回复命中。代码为此已单独加了
   `ImplicitAttributionFeedbackWindow = 2h`，但那只是**查询侧**的窄窗。
2. **归档拦不住回执**。`requireOwnedGroup` 的 SQL 是 `WHERE id = ? AND user_id = ?`
   ——**不校验 status**，且 `feedback_resolve.go` 的 handler 根本没调它（只有
   `currentUser` + token 直查）。要做到「归档即失效」得新增一道 status 校验。
3. **`pending` 堆积会污染去重闸**。`CountPendingInteractiveRequestsByGroup`
   的语义是「同 group 不重复问」，永久 pending 会让该 group 的后续反馈永久被堵。

注意三者是**不同的量**，不该合并：`chat_events` 保留（永久，eventretention
白名单明确保 `routing_feedback_request`）/ 回执窗口（24h）/ 隐式锚点窗口（2h）。

#### 6.28.2 TTL 的实质优化：不改数值，改它的三个实现缺陷（2026-10）

上一节论证了「24h 这个数值不该动」。用户随后要求「优化 TTL」——正确的解读是
**优化 TTL 的实现**，而不是调那个数字。实测（bcc，36 行 `chat_confirmations`）
确认了三个真实缺陷，全部与数值无关：

| # | 缺陷 | 后果 |
|---|---|---|
| 1 | `HasPendingChatConfirmation` **不按 kind 过滤** | 一条 pending 的归属反馈会让该 group 在**24 小时**内建不出任何确认卡，且完全静默 |
| 2 | TTL 是**编译期常量** | 调一个数字要重新构建 + 部署整个 `go-api`；`domain.go` 注释自己早就预留了「如需运维按部署调谐，再升级到 runtimeconfig」 |
| 3 | 客户端**无从知道卡片已失效** | 请求事件 payload 不带 `expires_at`，而回执过期后服务端统一 404 → 用户点一张早已过期的卡，「点了没反应」 |

##### 缺陷 1：确认卡被反馈静默吞掉

`HasPendingChatConfirmation`（`internal/repo/sqlite/schedules.go`）是
`EnsureConfirmationCard` 的**去重闸**：有 pending 就不建新卡。而归属反馈与确认卡
**共用 `chat_confirmations` 表**，只是 kind 不同。

历史上两者 TTL 都是 10 分钟，不过滤 kind 也无大碍。24h 之后：

```
Turn A 完成 → 发归属反馈 → 一行 pending 挂 24h
Turn B 需要用户确认 → 去重闸看到 pending → 跳过
                    → 不发 confirmation_required → 用户永远看不到卡
```

两个 kind 的 pending 语义**本来就不同**：确认卡 pending = 「有一个 turn 卡在那里
等人拍板」（阻塞、必须处理）；反馈 pending = 「有个可选问卷还没填」（不答无害）。
拿后者去堵前者是**语义错位**，不只是过滤漏项。

修法：SQL 加 `AND kind <> ?`（参数 `domain.KindAttributionFeedback`）。

⚠️ 当前生产 `ARBITER_MODE` 未设置（默认 shadow → `commitConfirm` 不建卡），故
这个缺陷是**潜伏态**——一旦切 `enforce` 立刻生效。而它**没有任何日志**：
`skip, group already has pending` 看起来就像一次正常去重。

##### 缺陷 2：TTL 改为可热调（runtimeconfig）

只让**归属反馈**可覆盖，确认卡保持编译期常量——后者的寿命不是产品选择而是结构
约束（它挂在 pending turn 上，turn 的墙钟预算就是上限；调大只会让「卡还在但 turn
已经死了」变得可能）。

| 层 | 改动 |
|---|---|
| `runtimeconfig.Snapshot` | 新增 `AttributionFeedbackTTL`（`runtime.attribution_feedback_ttl_seconds`） |
| `runtimeconfig.apply` | `>= 0` 才写入——**0 是合法值**（「不覆盖，用 domain 默认」） |
| `domain.InteractiveRequestTTLForKindWithOverride` | 新函数；`override <= 0` 回落到 `InteractiveRequestTTLForKind` |
| `chatgate.IssueInteractiveRequest` | 新增 `feedbackTTLOverride time.Duration` 参数 |
| `chatpipeline.Pipeline.attributionFeedbackTTL()` | 从 `runtimeCfg.Current()` 读 |
| `runtimeCatalog` + `envValueForKey` | 登记（**漏任一处即静默失效**，见 [§6.26](testing.md) 的三处登记规则） |

⚠️ **`envValueForKey` 必须返回 domain 默认的 24h，不能走 default 分支的 0**：
页面把 0 展示给管理员会被读成「功能关闭」。这与 `runtime.gate_timeout_seconds`
曾经踩过的坑同型——**守卫精确抓到了这一处**（`TestRuntimeCatalogEnvValueResolvable`
在只加了 catalog、没加 `envValueForKey` 时立刻 FAIL）。

⚠️ **`0` 的语义是「不覆盖」而不是「立即过期」**：`Snapshot` 的零值就是 0，故
「没配这个参数」时走的就是这条路径。方向写反会让所有反馈请求在签发的同一秒失效，
现场表现是「卡片点一下就说过期」，**比不配置更糟**。

##### 缺陷 3：把有效期下发给客户端

`GET /api/chat/turn-runtime` 新增 `attribution_feedback_ttl_seconds`。客户端用
「事件 `createdAt` + TTL」自行判定失效并**置灰为「已失效」**，把 404 从主路径
降为兼容路径（旧事件 / 时钟偏差）。

| 层 | 改动 |
|---|---|
| `server/chat_runtime.go` | 响应新增字段；下发**生效值**（含管理员覆盖），不是编译期常量 |
| `spb_models.TurnRuntime` | `attributionFeedbackTTLSeconds` + `attributionFeedbackTTL`（上限 7 天，`null` = 未下发） |
| `spb_domain.FeedbackRequestItem.isExpired({ttl, now})` | 纯判据，`now` 可注入便于固定时钟 |
| `spb_domain.ChatStreamController` | 与 `_turnTimeout` 同批记下（同一次 HTTP 往返） |
| `spb_features.FeedbackRequestCard` | 新增 `expired` 参数 |
| `spb_features.ConversationPage` | `expired: item.isExpired(ttl: _feedbackTTL)` |

⚠️ **`expired` 不能折进 `resolved`**。若合并，过期卡片的标题会写成「已反馈」
——用户**没答过**，那是在说一件没发生的事。与 §5.4「没有终态事件就不写已中断」
同一取向。故卡片是三态：`已反馈` / `已失效` / `这次归属准确吗？`（图标也分开：
`task_alt` / `timer_off_outlined` / `rule`）。

⚠️ **`ttl == null` 时 `isExpired` 恒 false**（旧版后端）：把「未下发」当成
「立即过期」会让所有卡片一次性变灰，比不判定更糟。同 `TurnRuntime.clientTurnTimeout`
对 0 的处理取向。

⚠️ **`canResolve` 有意不包含有效期判定**：它拿不到 TTL。若把 TTL 折进去，就得给
getter 加参数、改所有调用点——那是一次接口变更，不是「顺手修个 bug」。故判据分成
两个：`canResolve`（token + resolved）与 `isExpired(ttl:)`，调用方两者都看。

##### 数据依据（bcc 实测，2026-10-21）

| 观测 | 值 | 说明 |
|---|---|---|
| `chat_confirmations` 总行数 | 36 | 全部是 `attribution_feedback`（无确认卡，因 Arbiter 是 shadow） |
| 按 TTL 分组 | `0.2h`×30 expired / `24.0h`×3 expired + 1 pending + **2 resolved** | 24h 生效后回执率从 **0/30** 变成 **2/6** |
| 两条 resolved 的作答耗时 | **1.8 分钟**、**13.6 分钟** | 后者超过原 10min TTL，直接佐证 24h 的必要性 |
| 单 group 一天内请求数 | 23（`fd648ced`） | 全 expired（10min 时代的产物） |
| 表占用 | 28 KB | 清理**不是**当前瓶颈，故本轮**未**加保留期 janitor |

⚠️ 第 3 行是本轮**没有**调数值的依据：数据证明 24h 是对的。故「优化 TTL」落到
实现上——修复 3 个会让它**静默失效**的缺陷，而不是再猜一个数字。

##### 新增用例（Go 7 条 + Flutter 12 条）

| 文件 | 条数 | 钉住 |
|---|---|---|
| `internal/repo/sqlite/has_pending_confirmation_test.go` | 3 | 反馈 pending **不**堵确认卡；真确认卡仍拦；已过期不算待处理 |
| `internal/chatgate/interactive_request_ttl_test.go` | +2 | 覆盖值只作用于归属反馈（确认卡仍 10min）；**0 = 回落默认**（不是立即过期） |
| `internal/server/chat_runtime_test.go` | +1 | 下发 domain 默认 24h（**不是 0**）；覆盖后下发覆盖值 |
| `packages/spb_models/test/turn_runtime_test.dart` | +6 | 解析 / 未下发为 null / 0 与负数 / 7 天截断 / 恰好 7 天 / 字符串数字 |
| `packages/spb_domain/test/feedback_request_item_test.dart` | 10 | `isExpired` 六态（超/未超/恰好/ttl=null/已 resolved/时钟偏差）+ `canResolve` 四态 |
| `packages/spb_features/test/chat/conversation_page_timeline_test.dart` | +2 | 过期置灰为「已失效」且**不**显示「已反馈」；TTL 未下发时保持可点 |

##### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| `HasPendingChatConfirmation` 去掉 `AND kind <> ?` | 1 条失败（`归属反馈的 pending 行不应让确认卡去重闸返回 true`） |
| `InteractiveRequestTTLForKindWithOverride` 忽略 override | 1 条失败（实际 86400s，期望 5400s） |
| override 误用到所有 kind | 1 条失败（确认卡 5400s，期望 600s） |
| `override > 0` 改成 `>= 0` | 1 条失败（0 时实际 600s，期望 86400s） |
| 页面 `expired: item.isExpired(...)` → `false` | 1 条失败（找不到「已失效」） |
| `isExpired` 里 `ttl == null` 改成 `return true` | **5 条失败**（全部卡片变灰） |

⚠️ 最后一项的反向验证**踩了一次自己的坑**：用 `git checkout` 还原时把
`conversation_item.dart` 的**新增代码整段冲掉了**（那是未提交的工作区改动）。
反向验证若用 `git checkout` 还原，必须确认该文件**没有未提交的新增内容**
——本轮改用 `cp` 备份/还原。

### 6.48 「多轮之后查看大块正文时向下滚动丢内容」（2026-10）

**症状**（用户报障）：聊了几轮（其中有一条很长的回复），回头翻到那条长回复的
中间继续往下滚——**那一大块正文消失了**，时间线直接跳到别的内容。

#### 根因：不是渲染问题，是**数据被裁掉了**

服务端每产出一个 token 就发一条 `transient: true` 的增量事件
（`chatexec/pigo_core.go` 的 `handleUpdate` → `flushEventTransient`，只广播
不落库）。一个长回复能产出**上千条**，而 `ChatStreamController` 的缓冲区上限
是 `maxBufferEvents = 2000`，超了就从**头部逐条**丢。

而 `EventReducer.reduce` 是**全量重算**（每次 emit 都从缓冲区重跑一遍）——
丢头部等于把归约的输入掐掉一截。三个用户可见的后果：

| 现象 | 机制 |
|---|---|
| 整轮对话消失 | 丢的那一段里含 `user_message` / `start`，该轮从 `items` 里彻底不见 |
| 回复开头被截掉 | 只丢了它的前几百条增量 |
| 气泡先塌成十几像素再一个字一个字重新长出来 | item 的 `id` 取自**首条幸存增量**的 eventId → `ValueKey(item.id)` 每来一条事件就变一次 → `AssistantMessageBubble` 的 Element 销毁重建 → `gpt_markdown` 的增量解析状态（`_engine`）全丢 → 回到「从头揭示」 |

复现实测（`spb_features` 的 scratch 用例，修复前）：一条已完结的 120 段大正文
（高度 4379.9），用户滚到 `pixels≈1886`（它中间），随后另一轮推 2100 条增量
→ 缓冲撞破 2000 → `大正文高度=-2.0`（已不在树上）、
`归约结果里还有大正文: false`。

#### 修法两道（缺一不可）

**① 紧邻同类增量在入缓冲前合并**（`_coalesceIntoTail`）。

合并条件**全部**满足才并（任一不满足就退回独立入缓冲）：

| 条件 | 为什么 |
|---|---|
| 两条都是 `isIncremental`（`transient` + `{message, thought}`） | 权威帧要**替换**而非追加，合并会篡改语义 |
| `turnId` / `eventType` / `sessionId` / `agentId` 相同 | 跨轮或跨段落合并会把两段文本拼到一起 |
| 两条 payload **都恰好一个键**，键名相同且 ∈ `{text, content, message}`，值为 `String` | 多键 payload（未来服务端可能加 `index` / `role`）合并会丢字段 → **安全降级为不合并** |
| 缓冲尾就是这两条（中间无其他事件） | 合并只对「紧邻」成立 |

合并后保留**首条**的 `eventId` / `seq` / `globalSeq` / `createdAt` / `transient`
等全部元数据，只把文本拼在 payload 里。

⚠️ **保留首条 id 是刻意的**：归约层的增量分支本来就把文本**追加**到
`currentAssistantIdx`，故合并与不合并的归约输出**逐字相同**（有用例钉住）；
而 item 的 `id` 仍等于首条增量的 eventId → **流式全程不变** → 没有
`ValueKey` 抖动、没有 Element 重建、没有 `gpt_markdown` 重新揭示。

一个 2600 条增量的回复现在只占 **1 个槽位**（修复前必然触发裁剪）。

**② 裁剪改为按轮整段丢弃**（`_turnBoundaryAtOrAfter`）。

从 `excess` 往后找第一个 `turnId` 与前一条不同的位置——那里是一轮的起点，从
它开始丢就完整丢掉了前面若干轮。**绝不切在一轮中间**。

- 向后找（而不是「就近取整」）：只会多丢、不会少丢，缓冲一定回到上限以下
  （硬保证）。
- 整个缓冲区属于同一轮时没有边界可切 → 退回逐条丢头部 + `SpbLog.warn`
  （**诚实降级**：按轮丢就等于全丢，比逐条丢更糟）。合并让这条路径变罕见
  （需要单轮 >2000 条**落库**事件）。
- 降级期间的 warn **只记一次**（`_singleTurnTrimWarned`）：单轮超限时每条新
  事件都会触发一次裁剪，每条都 warn 会一秒刷满 500 条的诊断环形缓冲
  （[§6.20](runtime-and-ops.md)），把真正的异常扫掉。

#### ⚠️ 被否决的方案：丢掉终态轮次的残留增量

考虑过「`done` 之后把该轮的 transient 增量从缓冲区里剔掉」——能进一步省槽位，
但**会改变 item id**（从首条增量的 eventId 变成权威帧的 eventId），于是轮次
结束的那一刻会 remount 一次气泡，把「塌掉再重新长」的症状重新引进来。故不做。

#### ⚠️ 已知边界（修复前就存在，本轮未动）

- **`loadOlder` 在上限处是空操作**：`_buffer.insertAll(0, page)` 之后
  `_trimBuffer()` 从头部丢——刚插进去的那页会被原样丢掉，用户看到「翻页转了
  一圈什么都没变」。修它要改翻页语义（「前插时临时提高上限」还是「翻页时暂停
  裁剪」需要产品决定），故只记录不改。
- **`_oldestLoadedGlobalSeq` 不随裁剪抬高**（既有且刻意）：否则被裁掉的事件
  会被重新拉回来再裁掉，形成抖动。
- **单轮超长时仍会截断头部**：合并只消灭「每个 token 一条事件」这个主因；
  若单轮真有 >2000 条**落库**事件（例如上万次工具调用），逐条丢头部仍会
  截断它。这是上限本身的取舍（§6.23 实测 2000 条一次归约要 1767 µs）。

#### 测试（domain 6 条 + page 2 条）

| 层 | 用例 | 钉住 |
|---|---|---|
| `spb_domain` | 2100 条增量只占 1 个槽位，且正文完整、item id 恒定 | 合并生效 + `id == inc_0` + 总长度等于全部拼接 |
| 同上 | 合并后的归约结果与「逐条独立事件」逐字相同 | 合并是**纯优化**，不得改变输出 |
| 同上 | 不同 turn / 不同事件类型 / 中间夹其他事件时不合并 | 逐条断言 `bufferedEventIds`（比总数更不容易算错） |
| 同上 | 按轮裁剪：整轮丢弃，绝不切在一轮中间 | 每轮 **137** 条（与 2000 不对齐）→ 按轮丢与逐条丢必然分道 |
| 同上 | 整个缓冲区属于同一轮时退回逐条丢头部 | 单轮降级路径 |
| 同上 | 真实事件序列：14 轮对话全部保留 | `user_message`→`start`→N 增量→权威帧→`done`，修复前只剩 `turn_4..turn_13` |
| `spb_features` | 用户正读着一大块正文时，后续流式增量不得把它挤掉 | 用户滚到中间 → 另一轮流式 2100 条 → 大正文**仍在**（数据层 + widget 层都断） |
| 同上 | 单轮流式 2100 条增量：item id 恒定、正文从第一段开始 | 修复前 `id == inc_100`、正文从「段100。」开始 |

#### ⚠️ 反向验证踩到的坑（写这类用例时必看）

**「每轮 100 条」让按轮裁剪的用例假绿。** 最初写 25 轮 × 100 条 = 2500 条
（超出 500），断言 `ids.first == 'e500'`。但 500 恰好是 100 的倍数——**逐条丢
头部 500 条**与**按轮丢 5 轮（500 条）**得到完全相同的结果。反向验证时把
`_turnBoundaryAtOrAfter` 改成 `null`（退回逐条丢），用例**仍然全绿**。

修法：每轮取 **137** 条（与 2000 上限不对齐）。20 × 137 = 2740 → 按轮丢 6 次
= 822 条（剩 1918，`ids.first == 'e822'`），而逐条丢会剩 2000 条
（`ids.first == 'e740'`）——两种实现必然分道。

这与 [§6.17](testing.md) / [§6.33](build-and-release.md) / [§6.43](sync.md) 是同一类教训：**一个会在错误实现上变绿的用例，
比没有用例更危险**。

#### 连带调整的既有用例（不是放宽断言）

| 文件 | 调整 | 为什么 |
|---|---|---|
| `chat_stream_controller_emit_test.dart` | 填充事件的 `turnId` 改为互不相同 | 2000 条同轮事件会被合并成 1 条，`bufferedEventCount == 2000` 的前置断言不成立 |
| 同上 | 新增断言「300 条增量只占 1 个槽位」 | 直接钉住合并 |
| `conversation_page_row_keys_test.dart`（§6.18） | 填充事件的 `turnId` 统一为 `turn_batch` | 该用例要构造「批量卡被裁剪拆散」——**整个缓冲区属于一轮**才走单轮降级路径（文件头新增一节说明为什么现在仍能构造出这个场景） |
| `chat_stream_controller_history_test.dart` 的 `pushMany` | 每条 `heartbeat` 用不同 `turnId` | 同轮会被按轮裁剪整段丢掉，且降级路径每条记 warn（实测刷上百行） |

### 6.50 发送的乐观回显与 pending（「发送中」）生命周期（2026-11，issue #52）

**症状**：点「发送」后到服务端响应落地之间，时间线上**什么都没有**。网络慢时
用户看到的就是「点了没反应」，于是重复点、或以为丢了又重打一遍。

`.send()` 原本是 `await _api.sendMessage(...)` 之后才注入回显——即「乐观」二字
只覆盖了「不等 SSE」，并没有覆盖「不等 HTTP 响应」。本轮把回显提前到**请求发出
之前**，并给它一个显式的 `pending` 状态。

#### 三段生命周期（`ChatStreamController.send`）

| 阶段 | 动作 | UI |
|---|---|---|
| 请求在飞 | `injectLocalUserMessage(pending: true)`，**同步**注入 | 正文半透明 + 「发送中…」+ 无复制入口 |
| 响应成功 | `_settleLocalEcho(echoId, …)` **原位转正**（关 pending、落真 turnId） | 正常气泡 + 复制入口 |
| 响应失败 / 入队 | `_removeLocalEcho(echoId)` | 气泡消失（入队时「待发送」条是另一个 UI，issue #30） |
| 权威 `user_message` 帧 | 归约层按 **turnId** 原位合并（id 换成服务端 eventId） | 不变（不产生第二个气泡） |

事件仍是 `transient: true` 且不调 `recordEventId`——**乐观回显绝不能推进 SSE
游标**，否则重连以它为 cursor 请求回放会跳过其后的权威帧（§5.4）。

#### 六个不得违反的点

**1. turnId 为空也必须转正（原缺陷）。** `SendMessageResult.turnId` 可为空：
反馈回执（`feedback_recorded`）**不建 turn**，此后不会再有权威帧。若
`_settleLocalEcho` 在 `turnId.isEmpty` 时提前 return，那条气泡会**永久**显示
「发送中」。故转正分两档：turnId 非空则换上真 turnId（可被权威帧去重）；为空则
**只关 pending**、保持无 turnId（此时无权威帧可去重，宁可不合并也不要永久转圈）。

**2. `echoId` 是精确定位键，必须唯一。** 它此前只是「本地项」的标记，现在被
`_settleLocalEcho` / `_removeLocalEcho` 用作 `indexWhere(eventId == …)` 的
定位条件。`'local-<microseconds>'` 在同一微秒内两次注入会**撞车**（outbox 批量
投递路径真实会发生），于是转正命中错误的回显。故加 `_echoSeq` 单调计数。

**3. 找不到回显时**不重新注入**。`_settleLocalEcho` 里 `idx < 0` 意味着缓冲
已不含它（切 group 清空）。此时重新注入会把旧对话的消息塞进**当前**（另一个）
对话的时间线；服务端权威帧自会把它渲染回来。

**4. pending 期间隐藏复制入口。** 内容此时可能被 outbox 改写或被失败移除，
复制只对已定稿内容有意义。同理透明度只降 alpha（0.6）、**不改写文本**——
「重发」是按文本找原输入的（§6.14）。

**5. 失败与入队都要移除回显。** 入队不是「成功」，它有自己的「待发送」条；
两边都留着就是同一条消息出现两次。

**6. 只有 `send()` 用 pending。** 两处**有意**不带：

| 路径 | 为什么不带 |
|---|---|
| `QuickCaptureUseCase.submit(echoInto:)` | 无归属入口在拿到归属 `group_id` **之前**不知道该注入哪个控制器，注入天然发生在响应之后 |
| outbox 投递成功回调 `_injectEcho` | 消息早已落库（turnId 是真的），没有「在飞」窗口 |

回填/离线缓存路径同理不会误显示：`pending` 只在客户端注入时写入，服务端事件
不带该键，归约按 `ev.payload?['pending'] == true` 解析（**只认字面 true**，
字符串 `'true'` 落回 false——宁可不显示，也不要一条已落地的消息永远转圈）。

#### 测试

| 层 | 文件 | 钉住 |
|---|---|---|
| `spb_domain` | `chat_stream_controller_send_pending_test.dart`（10 条） | 在飞渲染 / 原位转正不新增第二条 / 权威帧合并后 id 换成服务端 / turnId 为空也关 pending / 失败移除（可重试则同时入队并抛 `MessageQueuedError`）/ 不推游标 / 同微秒 id 不撞 / 在飞期间切 group 不串场 / dispose 后响应到达不抛 |
| `spb_domain` | `event_reducer_test.dart` 的 `pending 键只认字面 true` | 四种 payload 形态的解析 |
| `spb_features` | `item_widgets_test.dart`（3 条） | 「发送中」+ 无复制入口 / 常态反之 / alpha 0.6↔1.0 且文本不改写 |
| `spb_features` | `conversation_page_send_test.dart`（1 条） | **页面逐条把 `item.pending` 传给气泡**（pending 与已落地并存时各只显示一次） |

测试夹具 `_HangAdapter`（同文件内）挂起 POST、由测试手动放行。两个必须知道
的细节：

- **`waitForRequest()` 必须轮询而不是只等一个轮次**：dio 的拦截器链要走
  **三个**事件循环任务才调到 `fetch`（实测第 1、2 轮 `calls == 0`）。等一次就
  `resolve` 会作用在空队列上（`removeLast` 抛 `RangeError`），看起来像控制器
  有 bug，实为测试时序写错。
- **`sse.push` 之后必须转一个轮次再 `flushEmit()`**：broadcast 流的投递是异步
  的，同步归约看到的是**旧缓冲**（表现为「权威帧没合并」的假缺陷）。

#### 反向验证（8 项逐条实测）

| 改坏 | 失败用例数 |
|---|---|
| `_settleLocalEcho` 在 `turnId.isEmpty` 时提前 return | 1 |
| `echoId` 去掉 `_echoSeq` 后缀 | 1 |
| 失败分支不调 `_removeLocalEcho` | 2 |
| `_removeLocalEcho` 的 `removeWhere` 条件永假 | 2 |
| `send()` 注入时不带 `pending: true` | 3 |
| 归约层 `== true` 改成 `!= null` | 1 |
| 页面把 `pending` 写死 `false` | 1 |
| 气泡无条件渲染复制按钮 | 1 |

⚠️ **最后一轮反向验证抓到了用例自己的假绿**：「同微秒」那条在重构时把最直接的
`expect(id1, isNot(id2))` 删掉了，只留下间接断言（「send 的转正不影响先注入的两
条」）——而 id 碰撞时间接断言**照样绿**（send 自己的回显 id 不受影响，转正命中的
是第一条而非第三条，「两条 pending 都还在」仍然成立）。补回直接断言后破坏才变红。
这是 [§6.17](testing.md) / [§6.33](build-and-release.md) / [§6.43](sync.md) / §6.48 同一类教训：**优化用例时删掉的直接断言，往往
正是唯一有效的那条**。

#### 有意不做

- **不给 quick capture 加 pending**：见上表，那条路径拿不到归属就无处注入。
- **pending 不做超时提示**：§5.8 的看门狗计的是「turn 起跑后无进展」，而 pending
  窗口在拿到响应的那一刻结束——给它单独一条计时器会把「服务端慢但正在处理」也
  判成异常。真断线时表现是「发送中」一直转，与 §5.8 的 stale 提示是两条独立信号。
- **失败后不把文本回填输入框**：composer 的 `_submit` 先 `clear()` 是既有语义
  （见 `message_composer.dart`），本轮只保证「幽灵气泡不留」。
- **不在 pending 气泡上放「取消发送」**：取消一个在飞的 HTTP 请求需要 cancel
  token 贯通到 `ChatApi`，且服务端可能已经收下——那会产生「UI 说取消了、turn
  却建出来了」的更坏状态。
- **不持久化 pending 项**：它是「这一刻的在飞状态」，重启后既没有对应的请求在
  跑，也无从判断服务端是否已收到（与 [§6.43](sync.md)「不持久化探测结果」同一取向）。
  真正需要跨重启不丢的是**离线队列**（issue #30），那是另一条路径。

### 6.56 group 用量（token 消耗）展示：REST 权威 + SSE 增量 + 重连对账（2026-11，对齐 Go `4a05176c` / `20874489`）

上游把「这段对话花了多少 token」做成了两个面：turn 收尾发一条 `token_usage`
业务事件（持久化、可回放），加一个聚合端点
`GET /chat/groups/:id/usage-summary`。客户端据此在对话页顶部读数区拆出两行：
**Token 消耗（账单）**与**上下文窗口（水位）**——后者是既有 `context_update`
的展示，本轮补前者。

#### 语义约束（全部有上游代码依据，勿凭直觉改）

| 约束 | 依据 |
|---|---|
| `token_usage` 是持久化业务事件，**不进** timeline 渲染白名单，但带合法 `eventId` → 走通用 buffer/cursor 路径，SSE 游标照常推进 | Go broker：`EventTokenUsage` 未列入 `timelineVisible`；webapp 同样不渲染它 |
| `cached_tokens` 是 input 的子集，只括注（「输入 100（缓存 20）」）**不参与加总** | 加总即双计；webapp 同口径 |
| 总量以 REST `usage-summary` 为**权威**；SSE 到达时本地增量累加 `totals`；`by_agent` 不做本地合并（解析但暂不渲染） | webapp `use-workbench-state`：本地只给「顶部一行合计」，明细等下次 REST |
| `first_at` 提示「统计自 X 起（更早的会话无记录）」；usage 缺席不发零值事件 | Go `omitempty`：`calls==0` 时 `totals` 字段缺省、`first_at`/`last_at` 可能缺字段 |
| `calls` 增量 = **+1**（事件条数），不用 payload `calls`（那是对话框到当前值，不是增量） | 后端 `COUNT(*)`；webapp `usage + 1` 同型 |
| `total_tokens` 缺失按 0 处理 | Go 零值省略 |

#### 数据流

```
进入对话 / 切对话        → GET usage-summary（unawaited，失败静默）→ baseline
SSE token_usage 到达      → 只在 _onFrame 实时路径增量（_backfill/loadOlder 不加，REST 基线已含）
SSE 重连（connected）     → _loadUsageSummaryQuietly() 再对一次账（成功才覆盖，失败保留本地读数）
切对话                    → _resetUsageSummary（防串场）
```

三个易写错处：

1. **重连对账必须跳过「全局模式」**（`ensureConnected()` 建的列表页连接，
   `groupId == null`）：否则每次全局重连都为当前未打开的对话发一次账单请求。
   与 `refreshUsageSummary()`（页面主动刷新，要求非空 group）语义区分。
2. **基线落点带归属校验**（`_disposed || _groupId != groupId`）：切对话后晚到的
   响应不得写进新 group 的读数（竞态有专门测试，用 `_UsageGate` 拦截器门控）。
3. **本地增量只补 `firstAt`（不覆盖）与 `lastAt`（只前进）**：事件时间是真实的，
   REST 的 `first_at` 也是真实的，两者应一致；覆盖会丢「统计起点」。

#### 读数区 UI（2026-11 压缩：默认收起为一行）

`_UsageBar`（`conversation_page.dart`）渲染条件
`(_contextUsage?.hasData) || (_usageSummary?.hasData)`——只有上下文也渲染，
只有账单也渲染，两者并存时同一条 bar。**初版把「Token 消耗 / 输入输出明细 /
上下文水位」纵向堆三行，用户报「左上角统计占太多纵向空间」**——它是读数，
不该比正文更占地方。现改为：

- **收起态（默认）**：一行。`Wrap` 并排「Token 消耗 150 · 请求 3 次」与
  「上下文 50K / 200K」chip；320dp 放不下时 Wrap 自动折到第二行（行内折行，
  不是 RenderFlex overflow——**勿改回单行 Row**，突变验证过会炸）；
- **明细行（输入 / 缓存 / 输出）只在点按展开时渲染**，右侧小箭头（上下三角）
  提示可展开；整条 bar 可点（`InkWell`），无明细可展开时不吞手势；
- `first_at` Tooltip 挂在**明细行**上（收起时看不到统计起点，展开才有——
  可接受：它是低频核实信息）。

| key | 位置 | 内容 |
|---|---|---|
| `conversation-usage-tokens` | 收起态 chip | 「Token 消耗 150 · 请求 3 次」 |
| `conversation-usage-breakdown` | 展开态 | 「输入 100（缓存 20） · 输出 50」；cached=0 不括注 |
| `conversation-context-usage-tokens` / `-cost` | 收起态 chip | 上下文水位 / 费用（Go 不发射，实际不渲染） |
| `conversation-context-usage` | 整条 bar | 渲染条件与视觉基调（surfaceContainer）不变 |

大数字 K 缩写（`formatTokenCount`：60K / 131.3K）；`by_agent` 明细暂不渲染
（数据已解析，留待 UI 需要）。

> ⚠️ 测试连锁影响：凡断言明细文案（`输入 … · 输出 …`）与 `first_at`
> Tooltip 的用例，必须先 `tester.tap(bar)` 展开再断言——收起态下它们不在树上。
> 总量 chip（`conversation-usage-tokens`）不受影响，收起态即可见、SSE 增量
> 即时刷新。

#### 测试与两个实测教训

| 层 | 文件 | 覆盖 |
|---|---|---|
| models | `group_usage_test.dart`（+471 全包） | `incrementedByEvent` / `deltaFromEventPayload` / `burnedTokens` / `plus` / omitempty 容错 |
| api | `chat_api_contract_test.dart`（+41） | 真实 `HttpServer` 契约：路径无 `/api` 前缀、全 snake_case |
| domain | `chat_stream_controller_usage_test.dart`（13 条） | 基线拉取 / SSE 增量 / **重连对账** / 全局模式跳过 / 切对话重置 / 竞态丢弃 |
| features | `conversation_page_usage_test.dart`（13 条） | 渲染 / **默认收起·点开见明细·再点收起** / cached 括注 / K 缩写 / first_at Tooltip（展开态）/ 320dp 窄屏 / `wireUsageSummary: false` 不渲染 |
| 两端 router | `router_chat_test.dart` 各 +1 | 接线断言（见下） |

**教训 1：`http_mock_adapter` 的 handler 计数不可信。** 注册 `onGet(path, handler)`
时 handler 可能在**注册阶段**就被 adapter 内部触发（`RequestHandling.onRoute`），
「handler 内 `requests++`」数出来的是注册次数。domain 层的请求计数改用
`_UsageProbe extends Interceptor`，在**真实请求路径**（`onRequest`）计数并即时
resolve 响应。

**教训 2：router 层只能守「流接上了」，守不了「读数渲染出来」。**
`chatStreamControllerProvider` 是 `autoDispose.family`，进路由时控制器会被换过
一次（`_focus` 在异步间隙里先 `read`、`build` 里的 `watch` 才建立住），于是
**首次**基线响应总是落在一个已 dispose 的控制器上、被归属校验丢弃（实测：
`DBG usage ok` 后紧跟 `DBG dropped disposed=true`）。稳定断言渲染需要 harness
提供控制器注入点，目前没有。故 router 用例断言
`tester.widget<ConversationPage>(...).usageSummary != null`（漏接则读数永远不出现，
反向验证：删掉 `usageSummary: controller.usageSummary` → 两端各 1 条失败）；
渲染与增量语义由 features 层的 harness 用例覆盖（`wireUsageSummary` 开关 +
`settleBaseline` 用 `tester.runAsync` 真实等待 unawaited 基线）。

### 6.58 归属提示重构：`routing_selected` 合并进气泡，无聊原因零空间（2026-11）

**症状**：每条发出的消息下面都跟着一行「归属： fixed_reuse」。对话内发送的常态
（group 合法、原样复用）是**零信息量**的，却每个 turn 占一整行，把正文挤出视野。

#### 语义前提（全部有 Go 写端依据）

`routing_selected` payload 的三个字段（`pipeline_events.go`）：
`group_decision_reason`（原因）、`selected_group_id`（目标对话）、
`group_switched`（静默切换标记，Go 注释原文「用户未必知道消息跑到了别的对话」）。

两个关键维度**互相独立**，不能互推：

| 维度 | 说明 |
|---|---|
| reason 是否「无聊」 | `fixed_reuse` / `classify_reuse` 等 8 个复用类值 = 就落在当前（或既有）对话，零信息量；`create_new` / `fixed_new` 等 5 个新建类值 = 建了新对话 |
| 是否切换 | `classify_reuse`（复用了**另一条**相似对话）也可能伴随 `group_switched=true`——reason 无聊 ≠ 没切换 |

> 值表逐字对齐 Go 写端（`pipeline_routing.go` / `pipeline_classify.go` /
> `pipeline_events.go` 兜底），见 `routing_attribution.dart` 的文档注释，勿凭猜测增删。

#### 设计：三层分工

| 层 | 职责 |
|---|---|
| `spb_models` | `ChatEvent.routingSwitched` 访问器（读 `group_switched`） |
| `spb_domain` | ① `routing_attribution.dart`：`isRoutineRoutingReason`（8 值）+ `routingAttributionNotice`（**新建 > 切换**判定序，未知原因 fail-open 原样透传为徽标文案）；② reducer 把 `routing_selected` **合并进同 turn 的 `UserMessageItem`**（`routingReason`/`routingSwitched` 两字段，与 `agent_id` 继承同一模式），**`item.id` 不变**（不换 EventId，避免流式期间 `ValueKey` 抖动重挂） |
| `spb_features` | `UserMessageBubble` 内联徽标（labelSmall + 图标，tertiary 强调、Tooltip 带完整解释 + 原始 reason code） |

渲染决策：`routingAttributionNotice(reason, switched)` 返回 null（无聊 + 未切换）→
气泡零额外空间；否则徽标。**不另占时间线行**。

#### 三个易写错的点

1. **合并失败时的孤儿回退必须看 `switched`**：同 turn 用户气泡不在缓冲里时
   （空文本消息被跳过 / 缓冲裁剪边界），无聊孤儿**整条丢弃**，但「reason 无聊 +
   `switched=true`」的孤儿**必须保留**（静默切换是有信息量的）——故
   `RoutingNoticeItem` 带 `switched` 字段。⚠️ 页面层**不得**再判一次
   `isRoutineRoutingReason` 过滤：页面看不到 `switched`，会把这类行误杀
   （变异测试抓到：页面二次过滤 → 该场景 0 条用例失败，行为却错了）。
   **归约层是唯一守门员**。
2. **新建优先于切换**：`fixed_new` 必然伴随 `group_switched=true`，徽标应显示
   「已新建对话」（发生了什么）而非「已切换对话」（怎么发生的）。
3. **回退行 `_RoutingNotice` 文案与徽标共用同一映射**：旧文案「归属：
   `create_new`」改为「已新建对话」，未知原因仍原样透传（fail-open）。

#### 测试

| 文件 | 条数 | 钉住 |
|---|---|---|
| `spb_domain/test/routing_attribution_test.dart` | 13 | 全量 reason 表 / 优先级序 / 未知原因透传 / tooltip 内容 |
| `spb_domain/test/event_reducer_routing_test.dart` | 12 | 合并（id 不变 / agentId 继承 / 权威帧覆盖后仍保留）/ 孤儿三态 / 乱序边界（routing 先到 → 回退独立行，生产不可达：服务端同事务 user_message 在前 + 控制器按 globalSeq 排序） |
| `spb_features/test/chat/user_message_bubble_routing_test.dart` | 8 | 徽标渲染四态 / pending 隐藏 / Tooltip message 区分复制按钮的「复制」Tooltip |
| `spb_features/test/chat/conversation_page_routing_test.dart` | 5 | SSE → 归约 → 渲染端到端：fixed_reuse 全时间线零元素 / 徽标文案 / 孤儿回退 |

反向验证（逐条实测，`cp` 备份还原）：

| 改坏 | 失败 |
|---|---|
| 还原「一律产独立行」旧行为 | domain **7** + features 3 |
| 新建集合漏 `fixed_new` | **2** |
| 徽标对一切非 null reason 显示（不判无聊） | **4** |
| 合并丢 `agentId` 继承 | **1** |
| 页面二次过滤无聊孤儿 | **0**（⚠️ 假绿教训见上：这条变异暴露的是**页面实现错**而非用例缺——已改实现并补 `switched` 字段说明） |

#### 有意不做

- **不动 `routing_feedback_request`**（归属反馈卡）：那是另一条机制（用户评分），与本徽标无关。

### 6.64 时间线「数据面」快照：把「回复少了一大块」判成数据丢还是像素丢（2026-11）

#### 症状

用户报「有些对话会出现回复的大块内容消失」。此前只能猜：可能是 §6.48 的缓冲
裁剪、§6.18 / §6.50 的行路由、或 §6.51 的绘制层——三者修法完全不同，而现场
信息只有一句自然语言描述。

#### 判据（本次定死，排障按此分层）

| 现象 | 层 |
|---|---|
| 滚走再滚回**不会**恢复；对话内搜索（`searchConversationItems`）**搜不到**那段 | **数据层**（归约 `items` 里就没有） |
| 滚走再滚回**会**恢复；搜索**能**命中 | **渲染层**（§6.51 那一类） |
| 重开对话 / 换设备都没有 | **服务端**（落库或回放侧） |

第一条判据靠搜索：搜索是**对归约结果**做的，像素丢了但数据在 → 能搜到。

#### 根因（信息缺口，不是代码缺陷）

缓冲与裁剪状态全在 `ChatStreamController` 内存里，而导出报告只有「运行环境 +
最近 500 条日志」（§6.20 / §6.57）。裁剪日志本身按 30s 节流（不节流会一秒刷满
环形缓冲，见 `_recordTrim`），于是**「到底裁过没有」在报告里看不见**——报障时
无法区分「内容在客户端就没了」与「内容在、只是没画出来」。

#### 修法

1. 值对象 `TimelineDiagnostics`（`packages/spb_domain/lib/src/timeline_diagnostics.dart`）：
   缓冲条数 / 对话项数 / 助手正文总字符 / 逐轮字符（降序）/ 已加载 globalSeq 区间 /
   裁剪次数与最近一次丢留 / 是否来自缓存 / 缺口修复次数 / 游标是否存在。
   **只有数字与 id，没有正文**——报告会被贴进公开 issue。
2. **两档采集**（关键取舍）：缓冲满了之后每来一条事件就裁一次，而一次全量归约
   是 1767 µs（§6.23）——每次都采就把刚消灭的 O(n²) 请回来了。故拆开：

   | 字段 | 频率 | 代价 |
   |---|---|---|
   | 计数 / 区间（`withTrimStats`） | **每次裁剪** | O(1) |
   | 正文字符 / 逐轮明细 | 首次裁剪 + 每 30s + 每轮 `done` + 回填 + 缺口修复 | 一次归约 |

   代价是 `assistant_chars` 可能比实际值**偏大**（此后又裁掉了几轮），文档与报告
   都写明「判断是否被裁以 `trim_count` 为准，字符数只看量级」。
3. `TimelineProbe`（进程级静态）持有最近一份：导出发生在设置页，`ChatStreamController`
   是 `autoDispose.family`，此刻通常已 dispose；改成长驻只为供数据要多一条长连接
   的寿命（移动端耗电/流量），不划算。
4. 报告：`buildDiagnosticsReport(timeline:)` 渲染 `## 时间线快照`，**放在日志之前**
   （报障要回答的第一个问题是「正文在客户端就没了吗」，答案不该埋在 500 条日志里）；
   `exportDiagnosticsReport` 默认读探针。整段仍过 `redactSecrets`，且行内换行转义
   （与日志同口径）。无快照时整个小节省略——空节会被读成「采集挂了」。

#### 一个实测踩到的坑（已修）

`_backfill` 里写快照时读了一次归约，但缓冲被整段换掉后**没有置脏** → 读到的是
上一个对话的归约结果（现象：回填后快照的助手字符数恒为 0）。故把「缓冲变更 ⇒
归约失效」提到每个变更点（`_appendEvent` / `_backfill` / `_fallbackToCache` /
`loadOlder`），不再依赖后面的 `_emit()` 置脏。

#### 反向验证（`cp` 备份还原，逐条实测）

| 改坏 | 失败 |
|---|---|
| 去掉 `_patchProbeTrimStats()`（裁剪不再补计数） | **1**（`按整轮裁剪时计数逐次累加`） |
| 去掉 `_backfill` 里的 `_reductionDirty = true` | **1**（`回填完成即落一份快照`） |

#### 测试

| 文件 | 条数 | 钉住 |
|---|---|---|
| `spb_domain/test/timeline_diagnostics_test.dart` | 9 | 字段口径 / 报告小节 / 逐轮截断 / 探针覆盖与清空 |
| `spb_domain/test/chat_stream_controller_diagnostics_test.dart` | 8 | `done` 自动落快照 / 只含数字与 id / 裁剪计数与降级 / 日志节流 / 换 group 清零 / 回填基线 |
| `spb_core/test/logger_test.dart` | 5 | 小节位置在日志之前 / 无快照省略 / 换行转义 / 脱敏 |
| `spb_platform/test/diagnostics_export_test.dart` | 3 | 探针 → 报告 / 无快照省略 / 显式覆盖 |

#### 有意不做

- **不采正文或摘要**进快照（哪怕截断）：报告是公开的。
- **不在 build 路径算快照**：`timelineDiagnostics()` 是一次全量归约，只在上述低频点调。

### 6.65 断线回放缺口探测：服务端 500 条窗口外**静默**不回放（2026-11）

#### 症状

断线 / 切后台 / 换网络回来后，中间一段回复**永久**缺失（不刷新就一直在），
重开对话才恢复。与 §6.64 的数据层判据一致：搜索也搜不到。

#### 根因（服务端契约如此，本仓库不能改）

`../super_partyb/apps/go-api/internal/server/chat_stream.go`：

- `userStreamReplayLimit = 500`，`replayUserEvents` 按 **user 级**取最近 500 条
  **落库**事件，再在里面定位 cursor；
- cursor 不在窗口内 → `start < 0` → 返回 `nil` → **不回放、不报错、不发结束标记**。
  于是「超窗」与「真的没有新事件」在客户端**完全同形**；
- 回放后 `Flush()` 直接进 live 循环，**回放与实时之间没有分隔**（客户端无法从流本身
  判断「回放到此为止」）。

而客户端 `_backfill` 只在 `start` / `switchGroup` 调用，**重连不触发**，也没有
`globalSeq` 缺口检测——`spb_api` 里写的「超窗 → timeline 整段回填」在此之前
**只是注释，没有实现**（文档承诺 ≠ 实现，这次按实现补齐）。

#### 修法：探测式（服务端一行不改）

1. `SseState.connected` 的转移上 `_scheduleReplayGapProbe()`：延迟
   `replayGapProbeDelay`（默认 2s，让回放先到）；跳过 `_disposed` / `_groupId == null`
   （全局模式没有可回填的对象）/ 游标为空（首次连接）。
2. 探针拉 `groupTimeline(groupId, limit: 1)` 拿服务端该 group 的最新 `globalSeq`，
   与本地 `_maxBufferedGlobalSeq` 比。
3. **基线必须是「发请求之前」的值**（`atProbe = localMax`），响应到达后再等
   `replayGapSettle`（默认 600ms）复读一次：
   - 复读后 ≥ `serverMax` → 回放/实时已追上，**不回填**（这就是「探测跑在 SSE 前面」
     的正常情况）；
   - 复读后仍在动但还没追上 → 回放仍在推进，**重排**（最多 2 次）；
   - 复读后与基线相同且仍落后 → **判定缺口**：warn（带 `local_max_global_seq` /
     `server_max_global_seq` / `repairs`）+ `_backfill` + `_emit`，`_replayGapRepairs++`。
4. `_gapProbeTimer` 在 dispose / 换 group 时取消（不留指向已释放对象的计时器）。

#### 为什么不能「等流里出现缺口」

transient 事件 `globalSeq = 0`（不落库），回放与实时混在同一条流里，事件之间没有
连续序号保证——**流本身提供不了「中间少了」的信号**。只能另发一次 REST 问服务端
「你最新到哪了」。

#### 代价（明说）

判定缺口后走 `_backfill` 会**重建缓冲**：丢弃 `loadOlder` 拉回的更早页，滚动位置
可能跳一下。理由：缺口 > 500 条时内存里那 2000 条事件已不可信，数据正确性优先于
「不跳」。

#### 反向验证（`cp` 备份还原，逐条实测）

| 改坏 | 失败 |
|---|---|
| 去掉 `_onFrame` 里的 `_scheduleReplayGapProbe()` | **4**（`真缺口 → 整段回填` 等） |
| 基线改成「探测返回后再读一次」（真实踩过） | **1**（`回放仍在推进但一次追不上 → 重排`：实测直接跳到回填） |

#### 测试

`spb_domain/test/chat_stream_controller_gap_probe_test.dart`（8 条）：首次连接不探测 /
服务端无更新不回填 / 真缺口 → 整段回填 / 探测跑在 SSE 前面 / 重排后追上 /
本地无落库事件不探测 / 全局模式不探测 / dispose 取消挂起探测。

⚠️ 写这些用例时踩到 `http_mock_adapter` 的一个坑：`onGet(route, handler)` 的
`handler` **在注册时就被执行一次**（它只负责把响应存到 matcher 上），每次请求执行
的是它构造出的 `mockResponse`。故计数/副作用必须写进 `replyCallback` 的 data 回调里，
否则会得到「注册即计一次、页永远取第 0 页」——**那种错会让「回填根本没发生」的用例
也变绿**。

#### 与 §6.51 的边界（避免过度宣称）

本条修的是**数据层**（缺的那段本来没进归约结果）。§6.51 的绘制层取舍
（`addRepaintBoundaries: false`）**仍待设备复核**——「软件渲染下测试通过」不能
用来宣称设备 GPU 故障已修。两层判据见 §6.64 的表。

---

### 6.66 选 Agent 改为**纯本地**（对齐 webapp），不再每次点选都调 `/sessions/switch`（2026-11）

#### 问题：两个端对「换 agent」的语义不一致

webapp 自 `a1f9bcad`（2026-08-10）起把选择器改成纯本地：点选只写
`agentByGroup[groupId]`，服务端动作发生在**下一条消息**——请求体里的 `agent_id`
让 Go 的入队事务走 `ReplaceBinding`（`internal/chat/pipeline_events.go`：
`ReplaceBinding: req.AgentID != ""` → `chatbinding.Ensure`：归档该 group 的其余
owner 绑定、写一条新绑定，`session_id` 留 NULL 由 pigo 首轮自产）。

> 后续变更（2026-11-06）：服务端不再留 NULL，而是**继承旧 owner 的 `session_id`**
> （`chatbinding.Ensure` / `Bind(ResetKeepSession)`），即换 agent 只换归属与人设、
> 不断开对话。下文「上下文会断开」的描述仅适用于该日期之前的行为。
>
> 后续变更（2026-11-09）：未指定 agent、平台自动匹配把消息改派给另一个 agent 时
> 也**不再断开上下文**——服务端回退借用当前会话（turn metadata `session_fallback`，
> 归属保持粘性不建行）。客户端无感，无需任何改动。

Flutter 侧则是在点选时立刻 `POST /chat/groups/:gid/sessions/switch`，并为它加了
一个「上下文会断开」的确认弹窗。同一个服务端语义，两个客户端表现不同：webapp 的
断开会**静默**发生在下一条消息，Flutter 的断开发生在点选那一刻并要求点确认。

「两个端做同一件事有两种规则」比任何一种单独规则都糟——用户换来端用就会以为
「这个客户端出问题了」。故本轮以 webapp 为准对齐（webapp 是功能最全的参考端）。

#### 改成什么

| 动作 | 现在的客户端行为 | 服务端 |
|---|---|---|
| 点选 agent | 只改本地 `_selectedAgentId`，**不发请求、不弹确认**；AppBar 标签立刻跟着变 | 什么都不发生 |
| 点选「自动路由」 | 同上，但清成 null 并置 `_autoRouting`；标签变「自动路由」 | 什么都不发生 |
| 发消息 | `agent_id` = **有效值**（标签上那个）+ `routing.mode=manual`；有效值为 null 时不带 `agent_id`、`mode=auto` | 入队事务里重绑（见上） |
| 「清空上下文」 | **输入栏的独立按钮**（`MessageComposer.onNewSession`）：先弹确认框，确认后调 `/sessions/switch`（`force_new_session: true`），成功弹「已清空上下文」 | 立即归档 + 新绑定，`session_id` 置空 |

判据落在两处：

- 选人与清空是**两个组件**：`AgentSwitcher` 只做纯本地的选择（`selectAgent`，
  可传 null，菜单里没有任何会发请求的项）；「清空上下文」在
  `MessageComposer.onNewSession`。**不能合并**——合并后清空会退化成只改本地值，
  旧会话根本没被归档。
- 两端 router 的三态：`_selectedAgentId`（`String?`，null = 未覆盖）+ `_autoRouting`
  （bool，显式自动路由），合并成 `_effectiveAgentId`：显式自动 → null；否则本地
  选择；再否则服务端绑定。AppBar 标签、菜单勾选、发送的 `agent_id`、开新会话
  **四者同源**，否则会「标签写 A、发出去的是自动路由」。

> 为什么必须三态：webapp 的 `agentByGroup[groupId]` 就是 `undefined | null | string`
> ——`undefined`（未选）与 `null`（显式自动路由）**发出去的请求不一样**吗？
> 两者都不带 `agent_id`、都是 `mode=auto`，但标签/勾选不同：前者该显示「沿用绑定」，
> 后者该显示「自动路由」。Flutter 若用一个 `String?` 兼两者，点完「自动路由」标签
> 会回落到 `active_session` 的绑定，而消息实际按 auto 发出——界面在撒谎。

#### 代价（明说）

1. **上下文在换 agent 时不断开**（2026-11-06 起）。服务端顶替 owner 绑定时
   继承旧 `session_id`，pigo 用 `-r` 续接同一段对话，只换人设。故菜单/搜索弹层
   顶部那行说明是「选择后随下一条消息生效（沿用当前对话上下文）」，只有
   「同 Agent 开新会话」入口才会真正断开。这是 webapp 既有的事实行为；客户端
   不做单方面的二次确认——点选本身没有产生任何不可逆动作。

   ⚠️ 正因为顶部写着「沿用当前对话上下文」，**破坏性**入口必须自己把代价说清。
   2026-11 起这个责任从「菜单项标签」移到了「输入栏按钮 + 确认框」：按钮叫
   「清空上下文」，确认框正文写明「文件、交付物与任务清单都会保留；AI 将不再
   记得之前的对话内容」。标签只能塞一句短语，确认框能写两句完整的话。
2. **建议卡的 agent 标注从「一次性」变成「持久」**。两者现在共用同一个本地值
   （webapp 同样如此：`FollowUpSuggestCard` 写的也是 `agentByGroup[groupId]`）。
   副作用是点过一次建议卡之后，后续消息仍由该 agent 回答——直到用户改选或换对话。
3. **选择在换对话时清空**，不回落到「上次在这个对话里选过谁」（webapp 的
   `agentByGroup` 在本次会话内按 group 分别记忆）。Flutter 的对话页是每 group 一个
   路由，State 复用由 `didUpdateWidget` 处理；保持「换对话即回到服务端绑定」比维护
   一份跨页缓存更简单，且与「刷新后回落到 `active_session`」的行为一致。

#### 三端统一：命名、位置、确认框（2026-11）

同一个动作在三个客户端上曾有三套说法，且只有 Flutter 把它藏在 agent 菜单里：

| 端 | 改动前 | 改动后 |
|---|---|---|
| webapp | 输入栏按钮「新对话」、无确认 | 输入栏按钮「清空上下文」+ 确认框 + 成功 toast |
| 小程序 | **没有这个能力**（只能新建 group） | 补上：同一位置、同一文案、同一确认框 |
| Flutter | agent 菜单里的「同 Agent 开新会话（清空上下文）」、无确认 | 输入栏按钮「清空上下文」+ 确认框 + SnackBar |

三条判据：

1. **命名用「清空上下文」，不用「新对话/新会话」**。它保留 group（标题、交付物
   目录、任务清单、工作区文件全在），只清 pigo 的 session。而「新对话」会被读成
   「新建一个对话」——小程序 tab 栏中间那个「新建」确实是建 group，用户已经建立
   了这个预期。名字必须说清「留下什么、失去什么」。
2. **位置在输入栏，不在 AppBar/菜单**。webapp 一直就在输入栏；AppBar 在窄屏没有
   余量（issue #31 实测 320dp 溢出）。菜单项还有个结构性限制：它只能「点了立刻
   执行」，既不能确认也不能提示。
3. **先确认、后提示**。这是本端唯一不可撤销的动作，且用户对它的预期最容易错位
   （以为新建了 group，结果旧消息还在、只是模型不记得了）。确认框正文必须写明
   保留什么、失去什么；完成后给一句「已清空上下文」，否则用户会怀疑没生效。

确认框与在途禁用都在 `MessageComposer` 里（拥有按钮的那个组件），不放在两个
router：它是 UI 决策，放两处就变成两份实现、两份测试。

一处**有意**保留的不对称：webapp 画布（`WorkbenchGroupCanvas`）里的草稿节点也有
一个「清空后发送」模式，它**不**弹确认框——那里模式是用户在图节点上显式选的，且与
「发送」合并成一个动作，再确认一次就是双重确认。它与输入栏那个独立按钮不是同一个
入口，别为了「统一」给它加确认框。

#### 有意**不**做的（避免下轮又提）

- **不接 Tool Agent**（webapp 的 `agent_type=tool_agent` + `tool-agent:<name>` 虚拟
  ID）：Go 的 `switchAgent` 结构体没有 `agent_type` 字段，`chatbinding.Bind` 还会
  `GetAgent` 校验 id 存在 → 虚拟 ID 必然 404。属 §6.9 一族，前置是服务端先支持。
  补一条证据：Go 的 `sendChatToAgentRequest.AgentType`（`server/chat_stream.go:151`）
  赋值后**从未使用**——webapp 那条路径在 Go 后端根本没有接线，对齐它等于对齐一个 bug。

#### 已补：自动路由（2026-11-06）

上一版把「自动路由」判成「有意不做」，理由是「用户要换回绑定，直接在列表里选它
即可」。**这个理由站不住**：选回绑定 agent ≠ 自动路由——前者带 `agent_id` →
`mode=manual`，`resolveGroupAgent` 第 1 步直接返回它，`auto_agent` 永不参与；
后者不带 `agent_id` → `mode=auto`，服务端按消息内容匹配（可能换人）。webapp 的
首项「自动路由（AI 选择）」、小程序 `work-detail` 抽屉的 `selectedAgentId: null`
都是这个语义，故本轮补齐：菜单/弹层首行加「自动路由」，它是**唯一**能把选择清
回去的入口（`_autoRouting` 三态见上表下方）。

同时修掉一个由此暴露的**既有缺陷**：`onSend` 原本发的是原始本地值
（`_selectedAgentId`），而标签显示的是 `_effectiveAgentId`。新打开一个已有绑定的
对话（本地值仍为 null）时，标签写着「写作助手」，消息却以 `mode=auto` 发出——
服务端 `auto_agent` 可能换个人回答，而那个 agent 没有绑定行 → 拿不到 `session_id`
（见 super_partyb AGENTS.md「自动路由的代价」）。现在发的一律是有效值：
**标签写谁就发给谁**。

#### 测试

- `packages/spb_features/test/chat/agent_switcher_test.dart`：点选**不弹确认框**、
  直接回调；选当前项无回调；点「自动路由」回调 `selectAgent(null)`（小列表与搜索
  弹层两条路径都测）；菜单里**没有** `agent-new-session` 项。
- `packages/spb_features/test/chat/message_composer_test.dart`：未接线不显示入口；
  点按钮先弹确认（不直接执行）；取消 → 零请求；确认 → 执行一次；在途禁用且完成后复位。
- `apps/spb_desktop/test/router_chat_test.dart` / `apps/spb_mobile/test/router_list_test.dart`：
  点选后 `hit` 为空（无 HTTP）+ 标签变成所选 agent；再走输入栏的「清空上下文」
  按钮 + 确认框时，`sessions/switch` 的 body 是 `agentId`（camelCase，**不是**
  `agent_id`，写错 400「agentId 不能为空」）+ `force_new_session: true` + 刚选中
  的 agent（桌面端还断言取消确认 = 零请求）；桌面端额外点「自动路由」后标签回到
  「自动路由」，且下一条消息的 body **不带** `agent_id`、`routing.mode=auto`
  （「标签写谁就发给谁」的回归防线）。
