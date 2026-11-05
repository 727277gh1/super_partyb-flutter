# 与 Go API 的契约

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。认证模型、路由前缀、响应格式、SSE 事件契约、无归属入口、落点存储、分页、
超时兜底、双栈端点选择。**这是客户端与 `super_partyb/apps/go-api` 之间唯一
的书面契约**——改任何一处都要先确认服务端侧的真源。

> 编号（`§6.x` / `§5.x` / `[§7](design-decisions/build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](design-decisions/README.md)。

---

## 5. 与 Go API 的契约（**最重要**）

### 5.1 认证模型

**客户端不解析 JWT、不申请 API Key。**

```
Flutter 客户端 ──(会话凭证 Cookie/OIDC token)──► api-gateway
                                                    │ OIDC 认证
                                                    ▼
                                            注入 X-User-ID
                                                    │
                                                    ▼
                                            Go API (AUTH_MODE=header)
```

- 网关前缀：`/pbw`（webapp）、`/pba`（PartyB API）、`/ufs`（文件服务）
- 客户端 `baseUrl` 只到服务根（如 `https://api.example.com/pba`），具体路径由各 API 方法拼接
- **`X-User-ID` 是网关注入的结果，客户端侧的值只用于拼 URL 路径**（`/users/:user_id/chat/*`），不得当作身份真源
- 开发态直连 Go API 时用 `AuthInterceptor.userHeaderOverride` 手工指定（`AUTH_MODE=header`）；**生产必须为 null**
- **Bearer 必须是 IdP 的 `id_token`（RS256 JWT），不能是 `access_token`**：后者是
  fosite 的不透明串（`ory_at_…`），网关的 JWT / OIDC 两个认证器都要求 compact JWS
  三段式，会直接 401。取值规则只有一处：`OidcTokens.bearerToken`
  （`idToken ?? accessToken`），落盘统一走 `StoredTokens.fromOidcTokens`。
  这是 2026-10 的真实缺陷，详见 [§6.37](design-decisions/auth.md)

配置方式（编译期注入，无运行时文件依赖）：

```bash
flutter build linux --release \
  --dart-define=SPB_API_BASE_URL=https://api.example.com/pba \
  --dart-define=SPB_UFS_BASE_URL=https://api.example.com/ufs \
  --dart-define=SPB_PREFERRED_HOSTS=api-v6.example.com=api.example.com \
  --dart-define=SPB_ENV=prod
```

见 `packages/spb_core/lib/src/env.dart`。

#### 5.1.1 双栈端点选择（IPv6 源站优先，启动探测 + 运行中降级/升级）

`SPB_API_BASE_URL` / `SPB_UFS_BASE_URL` 是**编译期默认值**，它们必须
「一定可达」（通常是双栈 CDN 域名）。若另有一个**仅 IPv6** 的源站域名，
用 `SPB_PREFERRED_HOSTS` 声明别名表，客户端**启动时探测一次**：

```
SPB_PREFERRED_HOSTS="api.example.com=api-v6.example.com"
```

| 项 | 行为 |
|---|---|
| 格式 | `编译期域名=首选域名`，多对用 `;` 或 `,` 分隔；也接受 JSON 对象（`{"a":"b"}`） |
| 留空（默认） | **完全不探测**，`SpbEndpoints.current` 恒等于编译期值（零开销） |
| 可达 | 把 api/ufs 里 host == 编译期域名的部分换成首选域名（`Uri.replace(host:)` 保留 scheme/port/path） |
| 不可达 / 超时 / 抛异常 | 保持编译期默认值 |
| 探测方式 | **真 TCP 连接**（`Socket.connect`，默认超时 1.5s）。不能只查 `NetworkInterface.list(type: IPv6)`——后者识别不出「有 IPv6 地址但路由黑洞」 |

**为什么默认用安全域名、运行期才「升级」**：配置写错或源站挂掉的最坏结果
是退回 CDN，而不是连不上；且零 CI 配置也能跑（不配 `SPB_PREFERRED_HOSTS`
即透传）。

**为什么是启动时探一次、而不是逐请求 failover**：客户端有 socket，可以
直接 TCP 探测并记下结论，整个会话摊销一次；小程序没有 socket（只能发
HTTP），才需要逐请求 failover + 断路器 + 环形日志（见
`super_partyb/docs/miniapp-dualstack-failover-design.md`）。故**不要**把
小程序那套搬过来——那是另一层需求，不是这里的缺失。

**实现位置**（改之前先读）：

| 层 | 内容 |
|---|---|
| `spb_core` `endpoints.dart` | `SpbEndpoints`（`current` / `changes` / `resolveAndUpdate` / `resolveEndpoints` / `downgrade` / `reprobeForUpgrade`）、`EndpointGuard`、`parsePreferredHosts`、`defaultEndpointProbe`、`resolveEndpointsAtStartup`（**启动用包装，吞异常**） |
| 两端 `main.dart` | `Future.wait([bootstrap…, resolveEndpointsAtStartup()])`——探测与桌面能力/深链监听**并发**，延迟被隐藏；随后记 `chosenHost` / `probeOutcome` |
| 消费点 | 一律读 `SpbEndpoints.current`（**不要**再直接读 `SpbEnv.apiBaseUrl`）；两端的 `dioProvider` / `ufsDioProvider` / `sseClientProvider` / UFS 预览 URL / 诊断报告均如此。Dio 侧经 `EndpointRewriteInterceptor` **逐请求**读取，故降级无需重建实例 |

#### 运行中降级 / 升级（issue #50，**不对称迟滞**）

启动探测只解决「开机时有没有 IPv6」。用户带着笔记本在「有 IPv6 的 WiFi」与
「只有 IPv4 的热点」之间移动时，升级后的源站域名会变成**黑洞**——连接超时、
SSE 反复重连失败，而客户端此前只能重启。故补一条运行中通路：

| 方向 | 触发条件 | 动作 |
|---|---|---|
| **降级**（快） | 连续 **3** 次**连接层**失败（`EndpointGuard.failureThreshold`） | 立即把基地址退回编译期值，结论记为 `EndpointProbeOutcome.downgraded` |
| **升级**（慢） | 处于 `downgraded` / `kept` 态，且距上次切换/探测 ≥ **5 分钟**，且重探成功 | 基地址回到 preferred 域名 |
| 成功响应 | 任意一次 | 清零连续失败计数；未升级时按冷却期触发一次重探 |

**为什么降级不做探测、升级才做**：降级的触发信号本身就是「连不上」，再探一次
只是把用户等待延长一个超时；而退回编译期地址（双栈 CDN）的代价极小。反过来，
**错误升级 = 彻底连不上**，必须拿到「preferred 真的可达」的证据。

**为什么只数连接层失败**：`badResponse`（4xx/5xx）恰恰说明 host 是通的，把它
计入会让「服务端一次 500」把用户从源站踢回 CDN。判定用 `DioExceptionType`
而非错误文本（见 `classifyDioFailure`）。

**为什么用请求失败作信号而不是 `connectivity_plus`**：与 `outbox` 同一取向
——「有默认路由」不等于「服务端可达」；且移动端 WiFi↔蜂窝切换时系统事件
未必及时。

**实现要点（改之前必读）**：

| 位置 | 作用 | 易写错处 |
|---|---|---|
| `spb_core` `endpoints.dart` `EndpointGuard` | 计数 + 冷却 + 重探仲裁（纯逻辑，可无头单测） | `recordSuccess` 也要触发重探（否则启动即 `kept` 的场景永远升不上去）；且必须有**独立于切换时刻**的探测节流 `_lastProbeAt`，否则 `kept` 态下每个请求都探一次 |
| 同上 `SpbEndpoints.reprobeForUpgrade` | 重探，**只在升级成功时写回** | 不能复用 `resolveAndUpdate`——它探测失败会写 `kept`，把 `downgraded` 盖掉，恢复循环静默终止 |
| 同上 `SpbEndpoints.changes` | broadcast 流，**基地址真的变了**才发 | 别改成 `kept → downgraded` 也发：地址没变，重建连接无意义 |
| `spb_api` `EndpointHealthInterceptor` | 把 Dio 成败喂给 guard | **必须排在错误映射拦截器之前**——dio 在某拦截器 `reject()` 后不再调下游 `onError`，排在后面则连接失败永不计数 |
| `spb_api` `EndpointRewriteInterceptor` | 每次请求重读 `SpbEndpoints.current` | **不要**改成「降级时 invalidate `dioProvider`」：Dio 与 SseClient 的身份被 `ChatStreamController` 持有，而页面订阅是 `_itemsSub ??=`（只绑一次），重建会让时间线**静默冻结** |
| `spb_api` `SseClient.switchBaseUrl` | 换 host 并重建连接 | 必须**清游标**（`_lastEventId = null`）：源站与 CDN 可能是不同后端实例，旧 eventId 回放会跳事件；且 `_closedByUser` 时不得复活连接 |
| `SseClient.resume()` | 手动重连 | 顺带修正：**必须重置 `_retryCount`**，否则退避耗尽后手动重连只能赌一次 |

**诊断可见性**：`EndpointProbeOutcome.downgraded` 与 `kept` 的基地址相同但语义
不同（前者「本来在源站，因网络变化退回」，后者「从来就没通过」）。诊断报告
另带 `endpoint_consecutive_failures` / `endpoint_upgrade_pending`——`downgraded`
且**无**挂起重探，说明恢复循环断了（真正的异常）。

**已知边界**（有意不做）：不持久化上次结论、**不切 OIDC issuer**（授权走系统
浏览器协议栈，token 交换走 CDN 也通）、探测端口仍取自编译期 host（别名表只
换 host，不能表达「不同端口」）。

### 5.2 路由前缀（易踩坑）

Go API 有**四套**前缀，**不是** `/api/chat`：

| 前缀 | 内容 | 注册位置 |
|---|---|---|
| `/api/*` | CRUD：agents / habits / api-keys / skills / router-preferences | `internal/server/ext_routes.go` |
| `/chat/*` | 聊天：groups / turns / confirmations / feedback | `internal/server/chat.go` |
| `/users/:user_id/chat/*` | 用户消息流 + **SSE** | `internal/server/chat_stream.go` |
| `/me/*` | 跨 group 用户级端点：turns / habits / preferences | `internal/server/router.go` |

> ⚠️ `/api/*` 下**并非全部**都有客户端实现：`api-keys` / `variables` /
> `memories` / `skills` / `router-preferences` 属管理面，客户端**有意不做**，
> 见 [§6.9](design-decisions/runtime-and-ops.md)。

### 5.3 响应格式

Go API 返回**裸 JSON**（如 `{items: [...]}`），**不是** Python 时代的 `{success, data, error}` 包装。

- 列表端点 → `{items: [...]}`，客户端用 `unwrapItems()` 适配
- 单对象端点 → 直接返回对象
- 错误 → `{error: "..."}` + 非 2xx 状态码

**字段命名不统一是既有事实**，不要试图纠正：

| 端点 | 命名风格 |
|---|---|
| `GET /chat/groups` | **snake_case**（`user_id` / `created_at` / `active_session`） |
| SSE 事件 | **camelCase**（`eventId` / `eventType` / `globalSeq`） |

各自照抄服务端，映射在 `spb_models` 里做。

### 5.4 SSE 事件契约

**真源**：`super_partyb/apps/go-api/internal/chatbus/broker.go` 的 `Event*` 常量。
**镜像**：`packages/spb_models/lib/src/event_types.dart` 的 `EventTypes`。

⚠️ **新增/改名事件必须两边同步**，否则客户端静默丢弃。

端点：`GET /users/:user_id/chat/stream?cursor=<eventId>`

格式（`internal/server/chat_stream.go`）：

```
event: <type>
data: <json>

: heartbeat          ← 每 3s 一次（防 CDN 15s 超时返回 524）
```

**关键机制：**

| 机制 | 说明 |
|---|---|
| `cursor` 回放 | 传最后收到的 `eventId`，服务端回放其后**落库**的事件，上限 **500** 条 |
| 超出窗口 | 返回空 → 客户端改用 timeline API 整段回填 |
| 心跳 | `: heartbeat` 注释行，**不进业务事件流**，仅用于连接存活检测 |
| 去重 | 服务端用 `seen` 按 eventId 去重（订阅→快照重叠窗口） |

**`transient` 是渲染正确性的关键**（`chatbus.Event.Transient`）：

| 事件形态 | `transient` | 客户端处理 |
|---|---|---|
| 流式增量（message/thought） | `true` | **追加**到当前段落 |
| 权威帧（段级完整文本） | `false` | **替换**当前段落 |
| 状态变更通知（goal_updated 等） | `true` | 真源在业务表，事件只提示「数据过期」 |

**「同一 turn 全部 `message` 事件拼接即完整回复」**（`final_message` 已废弃，迁移 0010 清空历史）。归约实现见 `packages/spb_domain/lib/src/event_reducer.dart`。

**cursor 只记录落库事件的 ID**——Transient 事件无有效 ID（`globalSeq` 为 0），用它作游标会跳过其后的权威帧。

**`schedule_created` 已进时间线**（`EventTypes.timelineVisible` + 归约器显式 case + `_ScheduleCreatedNotice`）。

它与 `goal_gate_stopped` 是**一对**：前者说「即将继续」，后者说「已停止」。用户
看到界面静止时需要知道是「它过一会儿会自己接着跑」还是「它已经停了」——只渲染
其中一个都会让人误判当前状态。

payload 只有 `{schedule_id, reason, status, delay_seconds, source,
auto_turn_count, max_auto_turns}`（唯一产出点 `chatgate/goal_gate.go`），
**没有绝对时间**（`scheduled_at` / `next_run_at` / `run_at` 一个都不发）。这是
有意的：绝对时刻在 cursor 回放 / 历史回填时会变成过期信息，而相对秒数在回放时
仍可读（「当时说 30 秒后继续」）。故客户端文案是「将在 30 秒后自动继续
（第 2/5 轮）」，`delay_seconds` 缺失时退化为「已排入下一轮自动继续」，
**不编造秒数**。

⚠️ **`executor_started` / `executor_completed` / `gate_evaluated` /
`gate_completed` / `gate_error` 是 `Diagnostic: true` 事件，设计上不进时间线**
（`chatbus.Event.Diagnostic`）。它们默认只落库不广播（由运行时配置
`runtime.diagnostics_*` 控制），语义是「服务端内部排障」而非用户可读的对话内容
——**不要把它们当成缺失的渲染分支去补**。

### 5.5 无归属入口（**桌面端悬浮窗的核心语义**）

`POST /users/:user_id/chat/messages` 的 `group_id` **可省略**。省略时服务端跑完整分类链判定归属，响应里的 `group_id` 是判定结果。

这与 MQ inbound（微信 iLink）**语义完全相同**：都是「没有对话 UI 的入口」。

桌面端 `Alt+Space` 悬浮输入窗**必须不带 `group_id`**，提交后按响应里的 `group_id` 导航到对应对话。

```dart
// ✅ 正确：不带 group_id，由服务端判定归属
final r = await api.sendMessage(userId, input: text);
navigateTo(r.groupId);

// ❌ 错误：带上「上次落点」会绕过分类链
await api.sendMessage(userId, input: text, groupId: lastGroupId);
```

### 5.6 落点存储（**不要写 `chat_access_entries`**）

记录「上次落点的 group」必须存 `router_preferences` 的 `user.desktop_last_group_id`。

⚠️ **`chat_access_entries` 有第二个消费者**：`RecentOutboundChannel`（按 `last_used_at DESC` 取一条）决定 agent.file 推到哪个 IM 渠道。插一行 `channel='desktop'` 会让钉钉用户的文件推送落到 mq-server 的 default 分支（iLink），**把文件推给不相关的微信**。

### 5.7 分页

两套约定，客户端必须都支持：

| 类型 | 参数 | 响应 | 用例 |
|---|---|---|---|
| offset | `?limit=&offset=` | `{items: [...]}` | `GET /chat/groups` |
| 游标 | `?before_global_seq=` | `{items: [...], next_cursor}` | `GET /chat/groups/:id/timeline` |

timeline 还有**旧游标** `before_time` + `before_seq`（兼容保留）。**客户端一律用新游标** `before_global_seq`——两套混用会导致分页错乱（见 `chat.go` 中 `groupTimeline` 的注释）。

排序与分页**必须用 `globalSeq`**，而非 `seq`（per-turn，每 turn 从 1 重来）或 `createdAt`（仅毫秒精度）。

### 5.8 超时兜底（**客户端看门狗，派生信号不改归约**）

流式标记（`isStreaming`）只有两条清除路径：`done` 与 `start`。一旦 `done` 丢失
（turn worker 崩溃、长断线、回放窗口被打穿），UI 会**永久**停在流式态：光标
不停闪、取消按钮永久可点（点下去得到 409 `turn not cancellable`）。

客户端因此维护一条「距最后一条事件」的看门狗，把**长时间无进展**的 turn 集合
推给 UI。阈值**不硬编码**，从 `GET /api/chat/turn-runtime` 的
`client_turn_timeout_seconds` 取（服务端可配，生产 600s）；解析失败/为 0 时退化
为 `TurnRuntime.fallback`（5 分钟，对齐 Go env 默认值）。

| 位置 | 职责 |
|---|---|
| `spb_models` `turn_runtime.dart` | 契约 + 阈值防御（`0`/负数 → 不可用，上限 24h） |
| `spb_api` `ChatApi.turnRuntime()` | 只读拉取 |
| `spb_domain` `EventReducer.inFlightTurnIds` | 纯查询：哪些 turn 仍在进行中（**流式标记**判据，实时路径） |
| `spb_domain` `EventReducer.lastTurnRunState` / `lastTurnMayBeRunning` / `lastRunningTurnId` | 纯查询：**结构推断**判据（回填路径，见下方「B1b 的修法」） |
| `spb_domain` `ReductionResult.terminalTurnIds` | 归约时记录的终态 turn（`done` / `error` 不产出 item，只能这样派生） |
| `spb_domain` `ChatStreamController` | per-turn 一次性计时器 + `staleTurnIds` 流 |
| `spb_features` `conversation_page.dart` | 停光标 + `_StaleTurnNotice` 提示条 |

#### 不改归约结果（**别退回「强制封段」**）

曾经的设计是给 `reduce` 加 `sealedTurnIds` 强制封段，被否决，两个真实缺陷：

1. **重复气泡**：封段后 `isStreaming=false`，若 turn 仍在跑、增量帧恢复到达，
   归约器从头重建 `currentAssistantIdx` 会**新建**一个 `AssistantMessageItem`
   ——一个 turn 两个气泡；
2. **撒谎**：`_sealStreaming` 会把未配对工具调用写成 `isComplete: true,
   output: '(无输出)'`，而 turn 仍在后台跑时这属编造。

故 `reduce` 签名不变，stale 只是**派生提示信号**。webapp 的做法同型（不动
timeline，只派生 lifecycle）。

#### 三条不得违反的不变式

1. **取消按钮保持可点**。stale 只说明客户端没再收到进展，turn 可能真在跑，而
   取消是用户此时唯一的出路。禁用会让用户彻底失去出路。
2. **计时器必须在控制器、不能放页面**。`turn_activity` 是「执行器还活着」的
   直接证据，但它**不进 `items`**（走 activities 通道）。页面只看得见 items，
   据此计时会把「只有工具心跳、尚无正文」的长 turn 误判成卡死——而这恰是
   `turn_activity` 存在的意义。
3. **心跳（SSE 注释帧）不续期**。`_onFrame` 对 `frame.isComment` 提前 return；
   若让心跳续期，「worker 崩溃但连接正常」这一主场景下兜底永不触发。

#### 两个实现细节（易写错）

- **per-turn 计时器，不是一个共享的**：共享的话，别的 turn 的活动会把本 turn
  的到期时刻也推后——已卡死的 turn 会因「旁边那个还在跑」而永不被判 stale。
  故 `_syncStaleWatch` 收 `touchedTurnIds`（**集合**，issue #44 起归约被合并，
  一批里可能有多个触发者），只重排触发者的到期时刻。
- **`inFlightTurnIds` 必须包含未完成的 `ToolCallItem`**：长工具（构建/下载/
  检索）期间既无正文也无思考，只有一条 `tool_call`。

#### 边界（**有意不做**）

- **stale 不是终态**：不写库、不改 `items`、不禁用取消。文案只说「可能仍在
  后台运行，或已中断」——不写「已中断」（没有终态事件就没有证据）、不写
  「正在重试」（客户端不跟踪重试）。
- **不自动重拉 timeline 自愈**：`_backfill` 会 `clear()` 丢本地乐观回显，且
  解决不了「服务端根本没发 `done`」这一主因。
- **B1b（相邻独立缺口）**：~~重开对话时服务端仍在跑 → 回填只有权威帧、无流式
  项 → 既不显示流式态也不武装看门狗（**既有行为**）。修它需把
  `inFlightTurnIds` 换成 webapp 的「最后一个 turn 有 agent 事件且无终态」，
  影响面更大，留单独一轮。~~ → **已修复**（issue #9）。修法**不是**改
  `inFlightTurnIds`，而是与它平行新增结构推断查询（见下）。

#### B1b 的修法（issue #9，**不改 `reduce` 签名**）

B1b 的判据不能是「流式标记」，因为 `done` **不产出任何 item**——实测一个已完成的
turn 与一个回填出来仍在跑的 turn，归约结果**完全一致**
（都是 `[UserMessageItem, AssistantMessageItem(isStreaming:false)]`）。故终态必须
在遍历事件时顺手记录，作为 `ReductionResult.terminalTurnIds` 派生出来（与
`activities` / `executionStatus` 同一「附加字段」取向，`reduce` 只收事件、签名不变）。

在此之上新增纯查询（与 `inFlightTurnIds` 平行）：

| 查询 | 判据 | 用途 |
|---|---|---|
| `EventReducer.lastTurnRunState(items, {terminalTurnIds})` | 最后一个非空 turnId（跳过 `router` 伪 turn）→ 终态 / agent 侧项 / 仅用户项 / 无 | 四态 `idle` / `preparing` / `streaming` / `terminal`（对齐 webapp `deriveStreamLifecycle`） |
| `EventReducer.lastTurnMayBeRunning(...)` | 上者为 `streaming` 或 `preparing` | 看门狗「是否需要兜底」 |
| `EventReducer.lastRunningTurnId(...)` | 上者为真时的那个 turnId | 武装**那一个**计时器 |

`ChatStreamController._syncStaleWatch` / `_markTurnStale` 把判据扩为
「`inFlightTurnIds` ∪ `lastRunningTurnId`」，故实时路径（B1）与回填路径（B1b）
共用同一条看门狗。

**为什么只取「最后一个 turn」**：同 group 的 turn 排队串行执行，取最后一个即可回答
「现在是不是还在跑」；若遍历所有 turn，一个很久以前丢过 `done` 的 turn 会把当前对话
**永远**判成运行中。

**为什么 `preparing` 也算**：它是「用户消息已落库、agent 还没产出」的排队/起跑空窗期，
服务端可能已崩且永远不会发 `done`——恰是最需要兜底的情形。

**调用方注意**：`lastTurnRunState` 等查询的 `terminalTurnIds` 参数**不可省**（生产路径）。
省略时终态信息丢失，会把所有历史 turn 判成可能在跑（有一条测试专门钉住这个陷阱）。
