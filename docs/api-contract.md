# 与 Go API 的契约

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。认证模型、路由前缀、响应格式、SSE 事件契约、无归属入口、落点存储、分页、
超时兜底、双栈端点选择。**这是客户端与 `super_partyb/apps/go-api` 之间唯一
的书面契约**——改任何一处都要先确认服务端侧的真源。

> 编号（`§6.x` / `§5.x` / `[§7](design-decisions/build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](design-decisions/README.md)。

---

## 5. 与 Go API 的契约（**最重要**）

### 可视化交付偏好

`GET/PUT /me/preferences` 新增 `spec_json: bool`（自动可视化引导，缺省关）和
只读的 `spec_json_available: bool`（运维急停状态，缺失兼容为可用）。PUT 只发改动项，
`false` 是显式关闭，省略则保留原值。GET 与 PUT 都返回权威值；急停不清空个人选择。
保存后下一轮生效，所有会话共用。Go API 在有群工作区的 pigo 执行链注入 `spec_json`
reminder，Agent 按任务需要生成 `.spec.json`；Flutter 复用现有只读文件预览。

### 持久化可视化 Artifact

服务端发布开关 `VISUALIZATION_PUBLISH_ENABLED` 默认关闭。`spb_models` 已识别
`visualization.published` 并提供手写 DTO；`ChatApi`、`VisualizationItem`、独立恢复消费者与桌面/移动报告卡片均已接入。历史文件预览继续按原路径工作。

客户端使用登录身份，路由前缀为 `/chat/groups/:group_id`，不使用 Agent API Key：

| GET 路径（接在上述前缀后） | 结果 |
|---|---|
| `/visualizations?artifact_key=...&cursor=...&limit=20` | `{items,next_cursor}`，固定 created_at/id 倒序摘要，key 精确匹配，limit 1–100 |
| `/visualizations/:artifact_id` | 最新版本 DTO，仅用于列表/详情刷新 |
| `/visualizations/:artifact_id/revisions/:revision` | 不可变版本的内容 DTO，历史事件必须读取此接口 |
| `/visualization-events?after_global_seq=0&limit=100` | 独立恢复页，limit 1–200 |

跨用户或跨 group 返回 404；版本读取先鉴权再处理 `If-None-Match`，ETag 绑定
content_hash、artifact_id 和 revision，相同内容的新版本也有不同 ETag。
缓存为 `private, no-cache`，客户端缓存键至少包含用户、group、Artifact 和 revision。

SSE envelope 沿用 camelCase（`eventId/groupId/turnId/eventType/globalSeq`），payload
统一为 snake_case：

```json
{"event_version":1,"artifact_id":"viz_...","artifact_key":"sales","revision":2,"profile":"partyb.readonly","schema_version":1,"title":"销售趋势","summary":"金额单位为元"}
```

事件不带 Spec；完整 revision DTO 带以上内容字段（不含 event_version）、group_id、
turn_id、event_id、content_hash、created_at、status、spec，以及可选 data_as_of/sources。
未知 event_version/profile/schema_version 保留摘要并提示不支持，不按 v1 解析。

恢复页 `{items,through_global_seq,next_after_global_seq,has_more}` 中的 items 使用
snake_case envelope（event_id/group_id/turn_id/event_type/seq/global_seq/source/created_at/payload），
不带 user_id；当前登录身份就是读取边界。首次请求固定高水位 through_global_seq，
后续页原样携带该参数，after_global_seq 使用上一页的 next_after_global_seq。
客户端只有在成功保存本页事件后才能推进恢复游标；完成后新一轮省略 through 参数。
即使 items 为空也使用服务端返回的水位。409 `cursor_reset_required` 表示水位超出
当前服务端范围，需要从 0 重建缓存；400 `invalid_cursor` 表示参数无效。

Outbox 至少一次投递，SSE、回放和恢复页可能重复或乱序到达；按 eventId 去重、
globalSeq 排序，不能用普通 SSE 游标代替独立恢复水位。服务端目前为单进程 Broker，
多实例实时广播需增加共享总线；持久化恢复接口提供最终补齐。

独立事件集合不受普通 2000 条消息缓冲裁剪影响。水位只在当前 user/group 的内存中保存，
冷启动从零重建；切组/销毁会停止旧恢复实例。回前台、SSE 建连/重连及前台每 30 秒触发对账。
409 清理独立事件集合再重建。报告展开后才读取固定 revision，响应须匹配 group、Artifact、revision、
profile、schema_version 与 published 状态；失败保留摘要并允许重试。未知版本不请求正文。
共享样例副本位于 `packages/spb_features/test/fixtures/readonly-v1.json`，真源为 Go API Readonly v1。
本机 widget 测试不能代替移动真机、桌面窗口和线上断网验收。

### 归档结项站点

`archive_snapshot.site.environment` 明确返回 `staging` 或 `production`；旧服务端或缓存缺失时按未知处理，不根据 URL 推断公开权限。公开入口仅在 ready + staging 时出现，执行前必须确认对话摘要可公开。

`access_url` 由 PartyB 使用对外基址构造：staging 走 `/_staging/ufs_sites/{slug}/`，production 走 `/ufs_sites/{slug}/`。相对路径按 UFS origin 补全；与已配置 UFS 不同源的内网地址及非 HTTP 链接拒绝打开。系统浏览器需要独立的网关登录会话。

归档版本使用独立站点，v1 保留历史 slug，后续为 `g-{group_id}-v{version}`。重新部署返回 202/pending，由 Worker 从既有 manifest 重建；正文和历史版本保持不变。

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

**本机制不覆盖 `SPB_OIDC_ISSUER`（登录端点）**：别名表只重写 `SpbEndpoints`
里 API / UFS 两个基地址（`SpbEndpoints` 根本没有 issuer 字段）。issuer 是 OIDC
的身份命名空间（写进 token 的 `iss`、发现文档、回调白名单），**只能有一个**；
若它指向的域名在当前网络不通，登录直接失败，不会退回 API 的 host。因此部署时
要把 issuer 放在一个**本身就双栈**的域名上（A+AAAA），而不是靠客户端探测兜底。

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

#### 5.1.2 App 扫码登录（浏览器出码 → 手机 App 确认）

**这条链路是客户端直连 IdP，不走网关的 `/pba` / `/ufs`。**

| 方法 | 路径 | 认证 |
|---|---|---|
| GET | `{issuer}/api/v1/qr-login/sessions/{scene}/preview` | `Authorization: Bearer <IdP 会话 token>` |
| POST | `{issuer}/api/v1/qr-login/sessions/{scene}/confirm` | 同上 |
| POST | `{issuer}/api/v1/qr-login/sessions/{scene}/deny` | 同上 |

- 端点根由 **issuer 推导**（`QrLoginClient.endpointBase`），**不硬编码域名**：
  dever / bcc 各环境 issuer 不同，写死会静默打到错误环境；
- 深链两种形态都要认（`QrLoginUri`）：`partyb://qrlogin?scene=<scene>` 与
  `https://<host>/idp/qr/<scene>`。前者是浏览器「在本机 App 中打开」，
  后者是二维码内容本身（系统相机扫码 → App Links 接管）；
- **App 不接收、不解析、不存储任何 token**：登录态由浏览器与 IdP 之间流转，
  App 只回答「确认 / 不是本人」；
- `poll_secret` 只属于发起轮询的那台浏览器，App 全程不接触它。

安全要点与完整状态机见 id-provider 的 `go/docs/qr-login.md`；服务端实现在
`id-provider/go/internal/qrlogin`。

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
| `POST /chat/groups/:gid/sessions/*`（**请求体**） | **两套都收**：`bindJSONCompat` 把 camelCase 补成 snake_case 别名（嵌套数组元素由 `BindSessionItem.UnmarshalJSON` 兼容）。同一请求里**只能发一种** —— 两键并存时服务端取哪个取决于 Go map 遍历顺序 |

各自照抄服务端，映射在 `spb_models` 里做。**新增端点一律 snake_case**（服务端 tag 与全仓 REST 约定）；
`sessions/*` 两套都收是历史兼容，不是新约定——不要据此推理其他端点也收 camelCase。

#### 5.3.1 `POST /users/:uid/chat/messages` 的三种终态

同一个端点，服务端可能**建 turn**、**命中已有 turn**，或**什么都不建**。三者都可能是 2xx，
客户端必须按 `status` / 布尔字段区分，不能只看「有没有 `turn_id`」：

| 终态 | HTTP | 关键字段 | 客户端该做什么 |
|---|---|---|---|
| 新建 turn | 201 | `turn_id`、`status: "queued"` | 乐观回显转正（落 `turn_id`） |
| 幂等命中 | 201 | 同上 + `deduped: true` | 同上（服务端已按 `(user_id, request_id)` 去重） |
| 归属反馈回执 | 200 | `turn_id: ""`、`status: "feedback_recorded"` | 不建 turn、**不会**有后续轮次：回显保留原文但关掉「发送中」 |
| **群忙缓冲** | **202** | `turn_id: ""`、`status: "deferred"`、`deferred: true`、`inbox_message_id` | 回显**保持「发送中」**，等续跑那一轮吸收（见下） |

群忙缓冲（super_partyb#168 的服务端行为）：群正忙时输入进 `chat_inbox_messages(pending)`，
当前 turn 终态后由服务端**逐条续跑**建轮——**缓冲 ≠ 合并**，顺序保持。

续跑出来的那一轮，其 `user_message` 事件 payload 里带**同一个** `inbox_message_id`
（真源 `chat/inbox.go` 的 `UserMessageExtra`）。客户端据此：

- 把排队中的乐观回显**原位吸收**进该轮（先改成本地事件的 `turn_id`，归约再按 `turnId`
  与权威帧合并）——否则时间线上会出现两条（去重是按 `turnId` 的，而排队中的回显没有）；
- **不要按文本相似度对齐**：用户连发两条一样的「继续」是常态；
- 超时（默认 10 分钟）只关「发送中」，**不删气泡、不放弃吸收**（服务端把 group 归档后
  会把缓冲标 `superseded`，那一轮永远不会来）。

实现：`spb_api` 的 `SendMessageResult.deferred` / `inboxMessageId`，
`ChatStreamController` 的 `_trackDeferredEcho` / `_absorbDeferredEcho`。

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
| 超出窗口 | 返回空 → 客户端改用 timeline API 整段回填（**注意：返回空与「没有事件」不可区分**，故客户端必须主动探测，见 [§6.65](design-decisions/chat.md)） |
| 心跳 | `: heartbeat` 注释行，**不进业务事件流**，仅用于连接存活检测 |
| 去重 | 服务端用 `seen` 按 eventId 去重（订阅→快照重叠窗口） |

**`transient` 是渲染正确性的关键**（`chatbus.Event.Transient`）：

| 事件形态 | `transient` | 客户端处理 |
|---|---|---|
| 流式增量（message/thought） | `true` | **追加**到当前段落 |
| 权威帧（段级完整文本） | `false` | **替换**当前段落 |
| 工具执行开始（`tool_call` 的 `{id,name,status:"running"}`） | `true` | **就地更新**该 `(turnId, call_id)` 那一行，**不得新开行**（2026-11-18 起不落库，回放时没有它） |
| 状态变更通知（goal_updated 等） | `true` | 真源在业务表，事件只提示「数据过期」 |
| 分发阶段进度（`dispatch_stage`，**默认不发**） | `true` | 首 token前的等待分段（见 §5.4.1） |

⚠️ **快照可能晚于段落边界到达**（2026-11-18，客户端实测缺陷）：pigo 的 toolCalls
增量帧**先于**本轮 `message_end` 到达（`handleUpdate` → `emitToolCall`），而
`tool_call` 在客户端是段落边界。若实现把「替换目标」记在「当前段落」上，边界一闭合就
记不住了，快照只好另开一段——**同一段文本渲染两次**（思考块最明显；刷新后消失，因为
增量不落库，回放时只剩快照那一份）。

正确做法：增量段落要单独记一份「本段流式文本尚未被快照接管」的索引，它**不被段落
边界清掉**，只被快照消费（`EventReducer._adoptPending`）；webapp 侧对应
`mergeTurnSegment` 的「回找最近一个 streaming 段」。判据只认「索引 + 同 turn」，
**不比较文本**：增量可能被限流丢帧而短一截，快照才是段内完整文本。历史回放没有
增量，永远不会命中这条路径，故多轮思考的权威帧仍各自成段、不会互相覆盖。

#### 5.4.0.1 `tool_result` 的输出预览（`output`）

**真源**：`pi-go/internal/runtime/headless.go`（wire）→
`super_partyb/apps/go-api/internal/chatexec/pigo_core.go`（透传）。

2026-11-18 之前 `tool_execution_end` 只透 `toolCallId/toolName/isError`，三端客户端
**都已写好**读取分支（`ChatEvent.toolOutput` 读 `output`→`result`→`content`、webapp
`turns.ts` 同理）却永远读不到——详情页因此显示占位文案，而真相是「从来没保存过」。

| payload 键 | 含义 |
|---|---|
| `id` / `name` | 调用标识（与 `tool_call` 同键，客户端按 `(turnId, call_id)` 合并） |
| `status` | `completed` / `failed` |
| `error` | 仅失败时为 `true` |
| `output` | **文本预览**，≤4KB，head+tail 截断，截断处带 `[truncated N bytes]` 标记；凭证形态已被服务端替换为 `[REDACTED]` |
| `bytes` | **原始**文本长度（不是预览长度）；同时是服务端日志的虚拟字段 |
| `truncated` | 预览被截过（`true` 时才出现） |

三条约束：

1. **只取 text 块**：image 块的 `data` 是 base64，一次截图能把事件撑到 MB 级，故不进事件流；
2. **空输出不产生字段**：客户端按「字段缺失」走占位文案，空串会渲染成空框；
3. **失败也带 output**：stderr 是唯一能解释「为什么失败」的东西；
4. **写库前已打码**（`internal/secretmask`，与会话摘要同一份规则）：厂商 token
   前缀、JWT、`Bearer`、PEM 私钥块、DSN 口令、`KEY=value` 里像密钥的键，都被替换成
   `[REDACTED]`。客户端**不需要**再做一次，也**不要**把 `[REDACTED]` 当异常展示——
   它是刻意为之，`bytes` 仍是原始长度。

客户端不需要任何改动（读取分支早就在），只需注意：`output` 缺失有三种成因——
事件早于 2026-11-18、结果被分页窗口甩出去、结果只有图片块——详情页统一显示
「（无工具输出记录）」，**不得**说成「加载中」（历史快照里不可能还在跑）。

#### 5.4.1 `dispatch_stage`：首 token之前的分发进度（issue #86 / #181 / #114）

**真源**：`super_partyb/apps/go-api/internal/dispatch/{wire.go,stages.go}`。
**镜像**：`packages/spb_domain/lib/src/dispatch_stage.dart`（`DispatchStageFrame` /
`DispatchStageTracker` / `DispatchStageLabels`）。

**服务端默认关闭**：按 `SPB_DISPATCH_EVENTS=1` 才发（无消费方时开着只是徒增扇出）。
关闭时客户端**零行为变化**——这条流永远不会有值，进度条不出现，也没有额外请求。

payload 分三种形态，靠 `phase` 区分（同一个事件类型发多条帧）：

| 形态 | `phase` | 键 |
|---|---|---|
| 段开始 | `start` | `request_id` `name` `start_ms` [`budget_ms`] |
| 段结束 | `end` | 上述 + `end_ms` `status` [`reason`] |
| root 开始 | `start` + `name=dispatch` | 同上（root 刻意不带 `budget_ms`） |
| root 收尾 | `end` + `name=dispatch` | 上述 + `elapsed_ms` [`unattributed_ms`] [`critical`] [`dropped`] |

**全部 Transient**（不落库、不回放、无有效 eventId），`group_id` / `turn_id` 恒为空
——它发生在建 turn、定 group **之前**。故：

- **归因只认 `request_id`**：SSE 是 user 级订阅，别的设备 / 小程序 BFF / habit 续跑
  的分发帧都会出现在同一条连接上。客户端只认自己 `send()` 生成的 rid（
  `ChatStreamController._inFlightRequestIds`），其余一律丢。
- **不进缓冲、不推游标**：`_onFrame` 显式分流 + `return`。放进缓冲会让归约白算
  一遍（对它没有 case），推进游标会让断线回放以「不存在的 eventId」定位。
- **`status ∈ ok|skip|deadline|error`**；`skip` 表示该段因预算/开关没跑（不是 0ms 跑完）。
- **`start`/`end` 必须配对**才有意义（「现在在做什么」= 最后一条未收尾的 `start`）；
  同名段可重复（编码重试），迟到/缺失 `start` 的 `end` 记 orphan 但不改当前段。

**段名闭集**（`DispatchStageLabels` 与 `dispatch.KnownStages()` 对拍）：
`classify.prepare` / `classify.gate` / `classify.llm` / `feedback.judge` / `enqueue` /
`reminder.prepare(/<n>)` / `router.auto_agent` / `router.query_encode` /
`embedding.encode`。**未知段名兜底「正在处理」**，服务端新增段不会让进度条变空白。

**客户端的用法**：`ChatStreamController.dispatchProgress` → `DispatchProgressBar`
（输入框之上的细条）。它只回答「现在在做什么 + 已等待多久」，
**过了 500ms 才显示**（生产 root median 6ms / p90 27ms，按「有帧就出条」等于每次
发送都闪一条）；`root` 收尾帧或请求返回即收起，等待交回
`TurnStatusStrip`（队列/执行）。

**它不是权威状态**：断线就没了，重连也不补齐（Transient 无回放语义）。故不参与任何
终态判断——「这一轮结束没有」仍只看时间线。

`routing_selected.stages` 是同一批段的**落库投影**（历史回看用），两者不可互相替代：
帧是实时的、无 turn；投影是持久的、挂在 turn 上。

**「同一 turn 全部 `message` 事件拼接即完整回复」**（`final_message` 已废弃，迁移 0010 清空历史）。归约实现见 `packages/spb_domain/lib/src/event_reducer.dart`。

#### 5.4.1b 本客户端不认识的事件类型（契约漂移的出口）

**真源**：服务端目录 `super_partyb/apps/go-api/docs/event-catalog.json`
（vendored 在 `packages/spb_models/fixtures/`，刷新脚本 `tools/sync_event_catalog.sh`，
流程见同目录 `README.md`）。

分流是**按类型**的（17 个 `ConversationItem` 渲染器），类别（7 值闭集）只用于对拍与
未来统计（服务端自己就把 62 条里的 50 条归为 `event`）。于是「服务端新增了时间线事件」
在客户端只有两种结局：

| 情形 | 出口 |
|---|---|
| 不认识 ∧ **落库** ∧ 不像控制事件 | 一行弱化文本「未知事件：`<type>`（×N）（客户端可能需要升级）」，按 `(turnId, eventType)` 合并计数、**不透传 payload** |
| 增量帧 / 服务端标 `diagnostic` / 登记在 `EventTypes.diagnosticOnly`（12 个） | 静默（只记日志） |

判据实现是 `EventTypes.shouldSurfaceUnknown`，理由见
[§6.107](design-decisions/chat.md)（控制类若也渲染，每次执行都会多几行噪声——
比静默丢帧更糟）。日志侧每个未知类型只 `warn` 一次（上限 32 个类型），故
logs-collector 里它是**一条带类型名的信号**而不是一片噪声。

**对服务端的期待**：新增时间线事件时把它写进目录的 `timeline: true`——本仓的
`test/event_catalog_test.dart` 会在下次同步时红，带上类型名。

#### 5.4.1c `follow_up_suggested` 与正文的**顺序**（2026-11-18 起）

**真源**：`super_partyb/apps/go-api/internal/chatexec/pigo_followup.go`（注入约定）+
`internal/chatgate/followup_suggest.go`（wire format）。背景与现场见 super_partyb
`apps/go-api/docs/2026-11-18-followup-suggest-ordering.md`。

服务端把「后续提问建议」改成 **正文之前**发布（旧约定「正文先写、建议最后」在 tool-loop
里不可执行，会让模型把正文重写一遍，同一 turn 落两份完整答案）。后果对客户端是**一条
硬约束**：

> `follow_up_suggested` 的 `seq` 可能**小于**同 turn 的正文 `message` 帧。
> 建议卡永远属于 turn 尾部，**不能按 `seq` 就地渲染**。

本仓实现：`EventReducer._pinFollowUpsToTurnEnd`——同一 turn 内非建议项保持原相对顺序，
建议项整体后移到该 turn 末尾（不删内容、重放幂等）。webapp / 小程序是 FAB + Sheet
（不内联在时间线里），不受影响；**新增内联渲染方时必须做同样的钉尾处理**。

#### 5.4.2 `error` 事件的 payload（`code` 闭集 + `message`/`detail` 分工）

**真源**：`super_partyb/apps/go-api/internal/chatbus/error_payload.go` 的
`ErrorPayload`（唯一构造入口）与 `ErrorCodes()`；导出清单
`apps/go-api/docs/error-codes.json`（`{code, default_message, retryable}`）。
**镜像**：`packages/spb_domain/lib/src/error_code.dart` 的 `ErrorCodes`，
fixture 在 `packages/spb_domain/test/fixtures/error_codes.json`
（`bash tools/sync_error_codes.sh` 刷新，`test/error_code_test.dart` 对拍）。

```json
{
  "code": "upstream_rate_limited",
  "message": "模型服务限流，稍后重试",
  "content": "模型服务限流，稍后重试",
  "detail": "transport: upstream 429"
}
```

| 键 | 语义 | 客户端怎么用 |
|---|---|---|
| `code` | 闭集错误码（服务端保证恒有；未知值归一 `internal_error`） | 分派**表现**（图标 / 分类徽标 / 是否给「重发」）；未知 code 一律 fail-open |
| `message` | **一句话人话**（空则服务端回落该 code 的兜底句） | 正文，唯一文案来源。**客户端不抄文案表** |
| `content` | 过渡期兼容键，**逐字等于 `message`** | 旧消费者；三端迁到 `message` 后服务端删除 |
| `detail` | 原始诊断串（`transport: upstream 429` / `responses invoke: …`） | **不进正文**：含英文诊断、路径、命令 → 只在「技术详情」展开/详情页展示 |

闭集（8 个，顺序即清单顺序）：`oom_kill` / `upstream_rate_limited` /
`upstream_error` / `timeout_inactivity` / `timeout_hard` / `turn_stalled` /
`turn_interrupted` / `internal_error`。

`turn_interrupted` 是**重启回填**专用：服务端进程退出（部署重启 / 崩溃 / 被强杀）
会把在跑的 turn 一起带走，启动后为遗留的 `running` turn 补发一条
`{"code":"turn_interrupted","message":"…","backfilled":true,"turn_status":"failed"}`，
紧接一条 `done`。它是今天唯一覆盖「turn 变 `failed` 却没有任何终态事件」这条
路径的 code（super_partyb#184），生产已实测出现（2026-11-16，3 例）。

`retryable` 的真源是服务端 `chatbus.Retryable(code)`：限流 / 上游错误 / 两档超时 /
挂死 / 重启中断 → true；`oom_kill` 与 `internal_error` → false（同样输入 + 同样上限必然再崩、
兜底码提示找管理员）。客户端镜像它，**未知 code 走 fail-open**
（`ErrorCodeTraits.failOpen`：可重发、无徽标、通用图标）——历史事件
（#182 之前只写 `content`）与未来服务端先发的新 code 都走这一格，绝不因客户端
没跟上而收掉「重发」。

新增错误语义一律**复用 `error` + 新 code**，不新增事件类型：小程序的渲染层是
fail-closed 白名单，新类型要等微信审核才可见（`super_partyb#183` 同一判据）。

> 两个**不要**：① 不要把 `session_handoff_stage` / `session_handoff_bridge` 当错误
> 渲染（前者是进度、后者 `failed` 是降级，用户照样拿到回复，红字会误导成
> 「换 agent 失败」）；② 不要按 `error_type` / `friendly_message` 这类 Python 时代
> 的遗留键分派（Go 从不写，读到的永远是死分支）。
>
> 归约输出：`ErrorItem` 带 `message` / `code` / `detail` / `isRecoverable`
> （`isRecoverable` 由 `ErrorCodes.traits(code).retryable` 派生，见
> `event_reducer.dart` 的 `EventTypes.error` 分支）。

**cursor 只记录落库事件的 ID**——Transient 事件无有效 ID（`globalSeq` 为 0），用它作游标会跳过其后的权威帧。
增量帧的 `eventId` 为空、`seq` 也为 0，**不能直接用作列表 Key**；归约层为正文与
思考段落生成稳定的本地展示标识，不写回事件，也不用于 SSE 游标（见 §6.85）。

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

**#123 新增字段（2026-11-14）**：`schedule_created` payload 增加布尔
`timeout_resume`（true = 本轮是「带断点进度的超时续跑」，输入已含上一轮进度摘要，
不是从头重来）；`goal_gate_decision` payload 在超时轮增加
`timeout_resume` / `task_timeout_streak` / `task_timeout_max`（`source` 取
`task_timeout`）；`goal_gate_stopped`
的 `reason` 可能取新值 `task_timeout`（任务级超时熔断）。全部是**加法**，旧客户端
按未知键忽略即可。

**任务重试端点（#123 解封入口）**：`POST /chat/goals/:goal_id/tasks/:task_id/retry`，
body 可选 `{"error_reason": "..."}`（人工备注）。仅 `blocked` / `error_stopped`
任务可调（其余 409 `task_not_blocked`）；成功返回 `{task, progress}`，效果 =
任务回 `pending` + 清 goal_gate 超时连击 + 恢复因 `task_timeout` 暂停的 gate。

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
| `spb_features` `conversation_page.dart` | 停光标 + `TurnStatusStrip` 的 stalled 状态 |

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
