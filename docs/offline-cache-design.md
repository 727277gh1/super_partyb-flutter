# 对话数据本地缓存设计（issue #26）

> 状态：**阶段 1（设计）+ 阶段 2 切片 A/B/C（实现）已完成**
> （切片 A → issue #26，本地变更写缓存的一致性补丁 → #28；
> 切片 B timeline 只读缓存 → issue #29；切片 C 离线写队列 → issue #30）
> （纯客户端范围，Go API 零改动）
> 背景：`spb_data` 的 drift 库里只有 4 张表（同步游标 / 已同步文件 / 目录绑定 /
> 偏好），**对话数据零本地缓存**。断网启动时除同步页与设置页外全是白屏。
> 本文是 issue #26 的**阶段 1 交付物**，回答 issue 列出的 6 个问题；切片 A 的
> 实现见阶段 2。

---

## 0. 结论速览

| # | 问题 | 决策 |
|---|---|---|
| 1 | 缓存什么 | **切片 A** group 列表（存服务端原始 JSON）；**切片 B** 落库 timeline 事件；**切片 C** 离线写队列（`outbox_entries`，装**用户输入**而非缓存）。**不缓存**文件内容、不缓存 `transient` 事件 |
| 2 | 失效策略 | **不用 TTL**（到期清空 = 又白屏）。group 列表**整表替换**（表达「服务端删了」）；timeline 以 `globalSeq` **增量追加**。陈旧只做**提示**，不做清空 |
| 3 | 写路径 | **三个写点，都不在 SSE 热路径上**：`listGroups` 成功后写 group 列表；`_backfill` / `loadOlder` 成功后写 timeline；**本地变更后**（新建 / 改名 / 删除，见 §4.5）也写 group 列表。SSE 事件**不**触发缓存写 |
| 3bis | 离线写（切片 C） | ✅ **已实现**（issue #30）。客户端队列 + 持久化 `request_id` 幂等键；严格全局 FIFO；退避 2s×2ⁿ 封顶 5 min、上限 10 次；离线消息进「待发送」条**不进时间线**（避免无 turnId 的双气泡，见 §7bis.6）。与 A/B 的关键差异：**存储失败抛 `StorageError`，不静默降级**（它装的是用户输入，见 §7bis.9） |
| 4 | 冲突 | 缓存里只存落库事件（与服务端 `_backfill` **同构**），故缓存层**不存在冲突**——它是 `_backfill` 的替代数据源，不是新的真源。乐观回显由既有 `EventReducer` 处理 |
| 5 | 体积 | 每 group 事件数上限 = `maxBufferEvents`（2000）；单 payload 上限 64 KiB；总字节上限 + 按 `last_accessed_at` LRU 淘汰。**`kTextPreviewMaxChars` 不适用**（那是预览上限，见 §5.1） |
| 6 | 迁移 | 只 `createTable`，**禁止** `createAll()` 兜底；已有 v1→v2 回归防线扩展到新表；缓存是**可丢弃数据**，降级直接清表而非写 down-migration |

**依赖方向**（照抄既有 `SyncStateStore` 模式）：契约在 `spb_domain`，实现在
`spb_data`，装配在 `apps/*`。`spb_domain` **不能**依赖 `spb_data`（AGENTS.md §3）。

---

## 1. 现状与缺口

### 1.1 现有 4 张表全是「同步」的

```
SyncCursors    —— 同步游标（每状态键一行）
SyncedFiles    —— 已同步文件（etag / size / contentHash）
SyncBindings   —— 本地根目录绑定
Preferences    —— 键值偏好
```

`grep -cE 'ChatGroup|ChatTurn|ChatEvent|ConversationItem' packages/spb_data/lib/src/database.dart`
→ `0`。

### 1.2 具体表现

| 场景 | 现状 |
|---|---|
| 断网启动 | 对话列表空 → 点任何对话都是错误页 |
| 弱网（地铁/电梯） | 每次切对话都重新拉，无缓存兜底 |
| 冷启动 | 必须等网络往返才有首屏 |
| 同一对话反复进入 | 每次都重拉 timeline |

### 1.3 为什么不能靠「已有机制」兜底

- **SSE 断线重连的 cursor 回放**（`chat_stream_controller.dart` 的
  `_oldestLoadedGlobalSeq`）：它解决的是「连接断开期间的事件」，前提是**曾经
  连上过**。冷启动断网时 `_buffer` 是空的，回放无从谈起。
- **`ChatStreamController.maxBufferEvents = 2000` 的缓冲区**：纯内存，进程退出即失。
- **UFS 交付物同步**：只覆盖文件，不覆盖对话。

故必须新增持久化层。

---

## 2. 问题 1：缓存什么

### 2.1 三个切片（按价值/成本排序，**不塞进一个 PR**）

| 切片 | 内容 | 消除的症状 | 成本 |
|---|---|---|---|
| **A** | group 列表 | 断网启动白屏 | 低（单表 + 整表替换） |
| **B** | 落库 timeline 事件 | 断网看不了历史对话 | 中（事件序列 + 游标 + 体积控制） |
| **C** | 离线写队列 | 断网不能发消息 | 高（幂等 + 顺序 + 冲突） |

**先做 A**：它用最小成本消除「白屏」这个最刺眼的症状。C 的复杂度与 A 差一个
数量级（见 §7），单独排期。

### 2.2 存「服务端原始 JSON」而不是拆列

**决策：`ChatGroups` 表存 `payload TEXT`（服务端返回的 group JSON 原文）。**

理由：`ChatGroup` 有 10 个实例字段，其中 3 个是嵌套结构
（`metadata` / `active_session` / `current_goal`，见 `chat_group.dart`）。
拆列的话**服务端加一个字段就要改客户端 schema + 写迁移**——而服务端加字段是
常态（`metadata` 下已长到 `follow_up_suggest` / `habit_suggest` / `goal_gate` /
`tts` 四块）。

存 JSON 则 `ChatGroup.fromJson` 直接复用，**服务端加字段客户端零改动**。

**这不是新发明**：`ChatEvent.toJson()` 已存在，其文档就写着「序列化回 JSON
（本地缓存用）」（`chat_event.dart:886`）。本设计沿用同一做法，并需要给
`ChatGroup` 补一个 `toJson()`（目前缺失，见 §3.2）。

### 2.3 明确**不**缓存的东西

| 不缓存 | 理由 |
|---|---|
| **文件内容** | 那是 UFS 交付物同步的职责，已有 `SyncedFiles` 表 + 完整链路。两套缓存同一份内容必然漂移 |
| **`transient` 事件** | 服务端**不落库**（流式增量片段 / 状态变更通知）。缓存了也无法与服务端对账——`_backfill` 拿不回来，缓存永远「多出」这些行 |
| **本地乐观回显**（`injectLocalUserMessage`） | `eventId = 'local-<micros>'`、`transient: true`，服务端没有对应物。见 §4 |
| **诊断事件**（`Diagnostic: true`） | 默认不广播、不进时间线（AGENTS.md §5.4），缓存它们只会白占体积 |
| **`goal_updated`** | 服务端漏设 `transient` 且**不落库**（`chat_stream_controller.dart:863` 的提前 `return`）。它的真源是业务表，缓存它会污染 timeline |

---

## 3. 数据模型

### 3.1 新表（切片 A）

> **表名与 issue 验收的差异**：issue 的验收写的是
> `grep -c 'ChatGroups' packages/spb_data/lib/src/database.dart` → ≥1，而实现用的
> 是 **`CachedGroups`**。这是有意的：这张表存的是**缓存**，叫 `ChatGroups` 会
> 暗示它是 chat group 的**真源**——而本设计的核心原则正是「缓存不是真源」
> （§4bis）。等价的验收命令：
>
> ```bash
> grep -c 'CachedGroups' packages/spb_data/lib/src/database.dart   # → 3
> ```


```dart
/// 对话列表缓存：**整表替换**语义（见 §3.3）。
@DataClassName('CachedGroupRow')
class CachedGroups extends Table {
  /// group id（服务端主键）。
  TextColumn get id => text()();

  /// 归属用户。多账号切换时必须按 user_id 隔离，否则 A 账号能看到 B 的列表。
  TextColumn get userId => text()();

  /// 服务端返回的 group JSON **原文**（`ChatGroup.fromJson` 的输入）。
  TextColumn get payload => text()();

  /// 服务端 `updated_at`（原样保留，仅用于诊断/排序提示）。
  TextColumn get updatedAt => text().nullable()();

  /// 本地写入时刻。用于「离线数据，X 前更新」提示（**不是** TTL 依据，见 §3.4）。
  IntColumn get fetchedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}
```

**为什么 `userId` 必须进表**：`ChatApi.listGroups` 走的是网关注入的 `X-User-ID`，
切换账号后同一台机器上的缓存会串。加 `user_id` 列 + 查询时过滤，是唯一不依赖
「切换账号时记得清库」的做法（后者会漏——登出路径不止一条）。

### 3.2 需要补的序列化

`ChatEvent.toJson()` 已有；**`ChatGroup` 没有 `toJson()`**（`grep -c toJson
chat_group.dart` → 0）。切片 A 需要补一个，且必须满足：

- 字段名与 `fromJson` **逐字对称**（snake_case，含 `active_session` /
  `current_goal` 嵌套）；
- round-trip 有测试：`ChatGroup.fromJson(g.toJson())` 与 `g` 的关键字段一致
  （不能只测 `id`——`metadata` 的嵌套子对象最容易漏）。

### 3.3 失效策略：整表替换（问题 2）

**决策：`saveGroups(userId, List<ChatGroup>)` 是「删该 user 全部行 + 插入新行」
的单一事务。**

这是从 `SyncStateStore.save` 学到的教训——它的类文档写着：

> `save` 是**整体替换**：先删该键的全部文件记录再插入新记录。若只做 upsert 而不
> 删，远端已删除的文件会永远留在表里。

同样的陷阱在这里是：**服务端删了一个 group，逐行 upsert 的缓存会永远显示它**。
用户点进去得到 404，且没有任何机制能让它消失（`group_updated` 的删除通知只在
线时收到）。

### 3.4 为什么**不用 TTL**（问题 2 的关键论证）

TTL 的直觉是「缓存过期就清掉，保证新鲜」。但本 issue 要消除的症状**就是白屏**：

```
断网 + TTL 到期 → 缓存被清 → 又是白屏
```

即 TTL 会在最需要缓存的时候（长时间断网）**主动放弃缓存**。

**决策：缓存永不过期；陈旧只做提示。**

- 缓存行带 `fetched_at`；
- 读取时若 `now - fetched_at > staleAfter`（默认 15 分钟），UI 标注
  「离线数据 · X 前更新」并保留内容；
- **网络成功时无条件覆盖**——新鲜数据的来源是「拉到了」，不是「时间到了」。

这样「陈旧」与「不可用」被分开：陈旧是**可展示的**，不可用才是白屏。

### 3.5 切片 B 的 timeline 表（**已实现**，issue #29）

```dart
@DataClassName('CachedEventRow')
class CachedEvents extends Table {
  TextColumn get groupId => text()();
  /// 落库事件的全局序（**不是** per-turn 的 seq，见 AGENTS.md §5.7）。
  IntColumn get globalSeq => integer()();
  /// `ChatEvent.toJson()` 原文。
  TextColumn get payload => text()();
  IntColumn get cachedAt => integer()();
  /// 最近一次被读取的时刻，全库超限时按它**整 group** 淘汰（§5.3）。
  IntColumn get lastAccessedAt => integer()();

  @override
  Set<Column> get primaryKey => {groupId, globalSeq};
}
```

**主键用 `globalSeq` 而非 `eventId`**：排序与分页必须用 `globalSeq`
（AGENTS.md §5.7 的硬约束）。用 `eventId` 作主键会逼出「按 eventId 排序」的
错误写法——而 `eventId` 的字典序与时间序**无关**。

**`lastAccessedAt` 是设计时补的**（§5.2 只说「按 `last_accessed_at` 淘汰」但
初稿表结构里没有这一列）。没有它就无法实现「整 group LRU」——只能退化成
「按 `cachedAt` 淘汰最旧写入的 group」，那对**刚访问过的老 group** 是错的。

#### 与切片 A 的三点相反之处（实现时最易照抄错的地方）

| | `CachedGroups`（切片 A） | `CachedEvents`（切片 B） |
|---|---|---|
| 写入语义 | **整表替换**（`save` 先删后插） | **增量 upsert**（`insertOrReplace`） |
| 为什么 | 服务端删了 group 要能消失 | 分页只来一段，替换会丢掉别的页（用户断网只能看到最后一页） |
| 键 | `id`（+ `userId` 隔离） | `(groupId, globalSeq)` |
| 隔离列 | `userId`（同一机器换账号会串） | 无（group id 本身全局唯一） |

#### 契约（`spb_domain/lib/src/timeline_cache.dart`）

```dart
abstract interface class TimelineCacheStore {
  Future<List<ChatEvent>> load(String groupId, {int? limit});
  Future<void> save(String groupId, List<ChatEvent> events);
  Future<void> clear(String groupId);
}

/// 纯函数，实现层据此过滤（调用方无需自己筛）。
bool isCacheableEvent(ChatEvent event);
```

`isCacheableEvent` **放在领域层**而不是埋进 drift 实现：它是**正确性核心**
——把不该缓存的项写进去不会报错，只会让「断网时看到的历史」与服务端不一致。
做成纯函数才能在 `dart test` 里逐条断言，不依赖数据库。

排除五类（依据 §2.3）：`transient` / `diagnostic` / `goal_updated` /
`globalSeq == null`（本地乐观回显）/ `globalSeq <= 0`（未落库）。

`load(limit)` 取**最新的** N 条（按降序取再反转），不是「升序取前 N 条」
——后者会让用户打开对话看到**最早**的历史。

---

## 4. 问题 3：写路径

### 4.1 决策：三个写点，都不在 SSE 热路径上

| 数据 | 写点 | 不在哪写 |
|---|---|---|
| group 列表 | `ChatApi.listGroups` 返回成功后 | **不在** `group_updated` 事件上写 |
| group 列表 | **本地变更后**（新建 / 改名 / 归档 / 删除，含 SSE 的 `group_updated` 镜像）——见 §4.5 | — |
| timeline | `_backfill` / `loadOlder` 成功后 | **不在** SSE 事件到达时写 |

### 4.2 为什么 group 列表不在 `group_updated` 上写

`group_updated` 是 **Transient**（`group/group_events.go:63` 显式设了
`Transient: true`，见 `chat_stream_controller.dart` 的注释）。三个问题：

1. **断线会丢**——Transient 不落库、不回放。断线期间建的 group 在缓存里缺席，
   而缓存恰恰是为断线服务的；
2. **写放大**——列表页在全局模式运行，会收到**任何** group 的变更。每来一条
   就写一次整表，代价与「拉一次列表」相当，却只换来一条增量；
3. **信息不全**——事件载荷是 `GroupUpdate`（`op` / `groupId` / `title` /
   `status` / `metadata` / `at`），不是完整 `ChatGroup`。用它写缓存会得到
   **残缺行**：缺 `user_id`（无法按用户隔离）、`created_at`、`goal`、
   `active_session`、`current_goal`。下次读缓存时这些字段为空，UI 会显示
   假的「无 goal / 无活跃会话」——而 `ChatGroup` 的几个关键 getter
   （`currentGoalText` / `goalGateEnabled` / `ttsEnabled`）正是读这些字段。

这与 `GroupListPage` 既有做法的取向一致：它在收到 `group_updated` 后对**已加载
的行**做就地更新（`_patchLoaded`），而不是重写整个缓存。

### 4.3 为什么 timeline 不在 SSE 事件到达时写

1. **写放大**：流式增量（`message` / `thought` 的 transient 帧）频率最高，
   而它们**本来就不该缓存**（§2.3）。真正要写的只有落库事件，而落库事件在
   服务端**本来就存着**——下次联网 `_backfill` 会重新拿到。
2. **缓存的作用是「断网时能看历史」**，而「历史」= 已落库事件 = `_backfill`
   能拿到的集合。SSE 写入只能让缓存**提前**包含它们，不增加最终覆盖面。
3. **写路径越少，一致性越好**：只有两个写点（`_backfill`/`loadOlder`）时，
   缓存内容 ≡ 「上次成功拉取的 timeline 页集合」，语义清晰。

**实现时的两点补充**（issue #29）：

- **写缓存不 `await`**：`_backfill` 成功后 `unawaited(_saveTimelineCache(...))`。
  写缓存是旁路，不应拖慢首屏渲染；实现层已静默（不抛），故不会产生
  「未捕获的异步异常」。
- **写的是完整事件对象**（不是 `_buffer` 里的全部）：`_backfill` 写刚拉到的那
  页、`loadOlder` 写刚取回的那页。这样 upsert 的语义才干净——写 `_buffer`
  会把「缓存里已有、但已被裁剪出缓冲」的事件也重写一遍（无害但无意义）。
- **有测试专门钉住「SSE 热路径不写」**：推 50 条落库事件后断言 `save` 零调用。
  把写点误挪到 `_onFrame` 是这里最容易犯的错，而它**不会让任何既有用例失败**。

**代价（要如实记录）**：会话进行中崩溃，最近几条落库事件不在缓存里。可接受
——它们是「刚发生的」，用户重连后 SSE 回放会补上。

### 4.4 写失败必须静默

缓存写失败（磁盘满 / 库损坏）**不得**影响主流程。照抄 `PreferencesStore` 的
取向：「偏好是配置而非数据，一个坏值不该让应用起不来」。缓存比偏好更弱——
它是**可丢弃的**。故 `saveGroups` 内部 catch 后记日志，**不抛**
（与 `SyncStateStore.save` 抛 `StorageError` 不同：那个状态丢了会导致文件重复
下载，是有后果的；这个丢了只是下次白屏）。

### 4.5 本地变更后必须写缓存（issue #28 补）

§4.1 原写「两个写点」，漏了**本地列表被就地修改**的那几条路径。它们不经过
`listGroups` 的成功分支，于是缓存停留在变更**之前**的状态：

| 路径 | 变更 |
|---|---|
| `_createGroup` 成功 | 插入新建的 group |
| `_insertCreated`（SSE `op=created`） | 插入回读到的权威行 |
| `_handleAction` 的 `GroupActionApplied` | 替换（改名/归档）或移除（删除） |
| `_onGroupUpdate` 的 `deleted` / `_patchLoaded`（`archived` / `active` / `title`） | 就地改状态或标题 |

**症状**：在线新建 / 改名 / 删除后，**不触发任何网络成功**就断网重启 → 缓存展示
的是变更前的旧列表（新建的消失、删掉的还在）。这比没有缓存更容易误导——用户会
以为自己建的对话丢了 / 删的没删掉。

**修法**：上述每一条路径在 `setState` 之后调用 `_saveCache()`（`_saveCache` 已是
整表替换语义，见 §3.3，故不需要新的失效策略，也不需要改 `GroupCacheStore` 契约）。

**这不与 §4.2 矛盾**：§4.2 否掉的是「**用事件载荷本身**写缓存」（`GroupUpdate`
缺 `user_id` / `created_at` / `active_session`，会写出残缺行）。本地变更路径写的
是 **`_groups` 里的完整 `ChatGroup`**（来自 `listGroups` 或 `getGroup` 的权威行），
与 §4.2 的顾虑无关。

**`_saveCache` 不得跳过空列表**：曾经有一道 `if (_groups.isEmpty) return;`，它让
「删掉最后一个对话」不更新缓存（下次断网重启那个已删除的对话仍在）。空列表是
合法状态，与契约一致——`GroupCacheStore.save` 明确写「`groups` 为空时等价于清空
该用户缓存」。

---

## 4bis. 问题 4：冲突处理

### 4bis.1 决策：缓存层**不存在冲突**

这不是「回避问题」，而是本设计的一个**结构性结论**：缓存只存落库事件，而落库
事件与服务端 `_backfill` 返回的集合**同构**——同一份数据、同一个 `globalSeq`
主键、同一个 `ChatEvent.fromJson`。

于是缓存的角色是「`_backfill` 在断网时的**替代数据源**」，不是**新的真源**。
没有第二个真源，就没有「谁的版本更新」这个判定，也就没有冲突。

**对照**：如果设计成「SSE 事件到达时写入缓存」（本设计明确否掉，见 §4.3），
那就**会**出现冲突——本地缓存包含尚未被服务端确认的流式增量，重连后需要判断
「本地这段是权威的还是服务端的」。本设计用「不写 SSE 热路径」这一步**从结构上
消除**了这类冲突，而不是事后去调和它。

### 4bis.2 三类「看起来像冲突」的情况，各自的处理

| 情况 | 为什么不是冲突 | 处理 |
|---|---|---|
| **本地乐观回显**（`injectLocalUserMessage`） | 它**不进缓存**（`transient: true` + `eventId = 'local-<micros>'`，服务端无对应物）。它只活在 `ChatStreamController._buffer` 里 | 由既有 `EventReducer` 处理：权威帧到达时替换乐观项（AGENTS.md §5.4）。缓存全程不参与 |
| **服务端删除了一条已缓存事件** | 服务端**不会**删单个事件（`chat_events` 只追加） | 无需处理。若整个 group 被删，走 §3.3 的整表替换/`clear` |
| **同一 `globalSeq` 被缓存两次** | 主键 `(groupId, globalSeq)` 保证物理上去重 | upsert（`insertOnConflictUpdate`）。这与 `SyncedFiles` 用复合主键保证「重复写入必须是覆盖」是同一手法 |

### 4bis.3 唯一需要「对账」的地方：游标边界

缓存与网络的交界处有一个**必须小心**的点：缓存的 `globalSeq` 上界与
`_backfill` 拉回的第一页可能重叠。

**处理**：`_backfill` 用**整段替换**（`_buffer..clear()..addAll(events)`，既有
行为），而不是「把缓存拼在 timeline 前面」。理由：

- 拼接会产生重复事件（重叠区），需要按 `globalSeq` 去重 + 排序；
- 更糟的是**空洞**：缓存的上界与 timeline 的下界之间若有一段缺口（断网期间
  服务端新增了事件，而本地缓存没有），拼接会让用户以为历史是连续的。

**故缓存只在「网络完全不可用」时启用**（§8.3 的回落分支），网络可用时它只是
被写入、不被读取。这样两条路径**永不同时活跃**，重叠问题不存在。

**实现时的三个补充**（issue #29）：

1. **回落有「缓冲非空则不填」的守卫**。`switchGroup` 先 `_buffer.clear()` 再
   `await _backfill`，而**SSE 连接此时仍活着**（切 group 复用同一条连接）。
   回填在途时到达的实时事件会先进缓冲；若回填随后失败并**无条件** `addAll`
   缓存，刚到的实时消息就被盖掉了——用户看到「最新一条消息凭空消失」。
   故 `_fallbackToCache` 在 `_buffer.isNotEmpty` 时直接返回。
2. **回落时会重排一次**（`cached.sort(by globalSeq)`）。契约要求实现层升序返回，
   但那是**约定**而非类型保证；归约器假定输入正序，错序**不会报错**，只会让
   历史倒序渲染。
3. **回落会设历史边界**（`_oldestLoadedGlobalSeq = 缓存里最小 globalSeq`），
   于是断网时仍能向上翻页。这是**乐观**的：缓存可能不含连续的一段，翻页会拿回
   重叠或跳跃的页——但比「完全不能翻页」好，且只在断网时可见。

---

## 5. 问题 5：体积控制

### 5.1 `kTextPreviewMaxChars` **不适用**

issue 建议「`kTextPreviewMaxChars` 这类上限要同样施加于缓存」。核实后**不采纳**：

- `kTextPreviewMaxChars = 200 * 1024`（`file_preview.dart:56`），它是
  **文件预览**的截断阈值——用于「把一个大文件塞进对话框」；
- 缓存存的是**事件**，不是文件内容。一个 `agent.file.*` 事件的 payload 是
  **元数据**（路径 / 大小 / etag），几十到几百字节，远达不到 200 KiB；
- 真正可能巨大的是 `tool_call` 的 `output`（构建日志、`cat` 大文件）——
  这需要**它自己的**上限（§5.2），而不是借用文件预览的阈值。

**结论**：`kTextPreviewMaxChars` 与缓存无关。若照抄，会得到一个「200 KiB 的
单事件上限」——既过大（2000 条 × 200 KiB = 400 MiB）又语义错位。

### 5.2 实际的三层上限

| 层级 | 上限 | 依据 |
|---|---|---|
| 每 group 事件条数 | **2000** | 对齐 `ChatStreamController.maxBufferEvents`。缓存比内存缓冲区多没有意义——多出来的部分归约器根本不会用 |
| 单事件 payload | **64 KiB** | 超过则**不缓存该事件**（不是截断）。截断会产生一个「看起来完整但内容缺失」的事件，比缺席更糟——归约器会把它当权威帧 |
| 全库总字节 | **64 MiB** | 超出时按 `last_accessed_at` 升序淘汰整 group（**按 group 淘汰**，不按事件——半个 group 的历史比没有更让人困惑） |

**实现时的三个补充**（issue #29）：

- **单 payload 按 UTF-8 字节计**，不是 `String.length`。中文在 UTF-8 里占 3 字节：
  一个 25k 汉字的事件按字符数（25k）判「未超限」，实际是 75 KB。有一条用例专门
  钉住这点（500 个汉字 = 1500 字节 > 1000 上限，但 1500 字符 < 1500 判据）。
- **条数上限丢最旧**（`orderBy asc(globalSeq) limit excess`），与
  `ChatStreamController._trimBuffer` 同取向——时间线以「最新」为焦点。
- **上限是分次写入累计的**：`_trimGroup` 查的是该 group 的**总行数**，不是本次
  写入的批大小。否则每次翻一页都「没超」，缓存无界增长。

### 5.3 淘汰必须整 group

按事件淘汰会让某 group 的历史出现「中间空洞」：用户向上翻页时看到
`globalSeq` 跳跃，且无法判断是「被淘汰了」还是「服务端就没有」。
整 group 淘汰的语义是清晰的：**这个 group 没有缓存**，走网络或显示空态。

---

## 6. 问题 6：schema 迁移

### 6.1 现有版本与既有防线

`AppDatabase.schemaVersion = 2`（切片 A 升到 3、切片 B 升到 4），`onUpgrade`
只做 `addColumn` / `createTable`，并有一条明确注释：

> **不要**用 `m.createAll()` 兜底：那会重建全部表、丢用户已有的同步状态。

`database_test.dart` 已有对应的回归测试：用原始 SQL 造一个 `schemaVersion = 1`
的库、插一行数据、用当前版本打开，断言**旧数据不丢 + 新列已加**。

### 6.2 新表的迁移写法

```dart
@override
int get schemaVersion => 4;   // 2 → 3（切片 A）→ 4（切片 B）

@override
MigrationStrategy get migration => MigrationStrategy(
  onCreate: (m) => m.createAll(),
  onUpgrade: (m, from, to) async {
    if (from < 2) {
      await m.addColumn(syncedFiles, syncedFiles.contentHash);
    }
    if (from < 3) {
      await m.createTable(cachedGroups);
    }
    if (from < 4) {
      await m.createTable(cachedEvents);
    }
    // **不要** m.createAll() 兜底（既有注释已警告）。
  },
);
```

⚠️ **`from < N` 而不是 `from == N-1`**：v1 用户跳到 v4 时三个分支都得跑。写
`from == 3` 会让 v1 用户升到 v4 后**缺少 v2 的 `content_hash` 列**，而 drift
不会在升级时报错——直到某个查询碰到那一列才炸（且报错信息指不到迁移）。
有一条用例专门造 v1 库直接升到 v4，断言三样东西都在。

⚠️ **迁移测试必须直接查 `sqlite_master`**，不能通过 `store.load` 断言。缓存是
可丢弃数据，store 的失败是**静默降级**的（读失败返回空列表），于是「表不存在」
与「表存在但没有行」在 store 层**无法区分**——`expect(await store.load(...),
isEmpty)` 对「迁移漏建表」完全无效（实测：把 `from < 4` 改成 `from == 3` 后
store 层断言仍全绿）。

### 6.3 三条迁移约束

1. **只加不删**：新表用 `createTable`，新列用 `addColumn`。删表/删列需要
   `m.alterTable`（重建表），风险高且对缓存无必要。
2. **`from < N` 而非 `from == N-1`**：跳版本升级（v1 → v3）必须两个分支都跑。
   这是 drift 迁移的常见错误——写 `if (from == 2)` 会让 v1 用户升到 v3 时
   **缺少 v2 的列**。
3. **缓存表与同步表生命周期分离**：`DriftSyncStateStore.resetAll()`（「换同步
   目录」时调用）**不得**清缓存表。理由：换目录与「对话缓存」无关，清了只是
   让用户下次断网又白屏。故 `resetAll` 保持只清 `SyncedFiles` + `SyncCursors`。

### 6.4 降级：不写 down-migration

缓存是**可丢弃数据**。若将来真要支持降级（`schemaVersion` 回退），正确做法是
**清空缓存表**而不是试图把新 schema 的数据塞回旧 schema：

```dart
// 伪代码，实际 drift 的降级需 onDowngrade 或删除库文件
if (to < 3) { await m.deleteTable('cached_groups'); }
```

理由：旧版本代码读不懂新列/新表，与其做有损转换（且必然有 bug），不如让它
重新拉。这与 `SyncedFiles`（**不可**丢——丢了会全量重下）形成对照。

### 6.5 与同步状态**同库**的理由

新表放进同一个 `AppDatabase`，而不是单开一个 `cache.db`：

- **同一个打开/关闭生命周期**（`openAppDatabaseAt` / `openAppDatabaseLazy` 已
  处理了桌面端与移动端的路径差异），单开一库要复制这两套逻辑；
- **多库协调是既有的痛点**——`PreferencesStore` 的文档明确写了「偏好与状态
  必须一起更新，若两者分属不同存储就会出现中间态」。虽然缓存与同步状态**不**
  需要事务一致，但把它们放一起避免引入「两库各自迁移」的复杂度。

**代价**：缓存库损坏会连带同步状态（同文件）。但 SQLite 的页级损坏通常表现为
「某表读失败」而非整库不可用，且同步状态已有 `load` 失败 → 按首次同步处理的
兜底（`DriftSyncStateStore.load`）。

---

## 7. 切片 C（离线写队列）：为什么当初要单独排期

> ✅ **已完成**（issue #30）。设计增补见 §7bis，实现要点与验收见 §7bis.11。
> 本节保留「为什么不能与 A/B 同批」的原始论证——它解释了这个切片为何需要
> 单独一轮，也是将来类似改动的判据模板。


issue 已写明「不要把 A/B/C 塞进一个 PR」。补充具体理由：

| 维度 | 切片 A | 切片 C |
|---|---|---|
| 一致性模型 | 整表替换（幂等） | 顺序 + 幂等 + 因果 |
| 失败处理 | 静默丢弃（可重拉） | 必须重试且不能重复投递 |
| 冲突 | 无 | 本地队列 vs 服务端已产生的 turn |
| 服务端依赖 | 无 | 需要 `request_id` 幂等键的语义保证 |

**可参考的既有语义**：`/me/quick-capture/enqueue` 已是「异步投递、无 `group_id`
返回」的模型（AGENTS.md §6.7）。但那条链路是**服务端**做的排队，客户端只需
「投递成功即完成」。C 要在客户端排队，得自己实现顺序、重试与去重——工作量
差一个数量级。

**做 C 时第一条验证的**：`POST /users/:uid/chat/messages` 的 `request_id`
是否真正幂等（重复投递同一 `request_id` 是否只建一个 turn）。这需要读 Go 侧
实现确认，**不能假设**。→ 已核实（issue #30 实现前）：

| 位置 | 事实 |
|---|---|
| `super_partyb/apps/go-api/internal/server/chat_stream.go:49,187` | 请求体字段 `request_id` 透传到 enqueue |
| `.../internal/chat/enqueue.go:265-270` | 命中 `GetChatTurnByRequestID` 则**返回既有 turn**（不新建） |
| `.../internal/chat/enqueue.go:325-330` | 竞态兜底：插入冲突时再查一次 |
| `.../internal/chat/enqueue_test.go:553` | 去重范围是 `(user_id, request_id)`（**不是**全局 `request_id`） |
| `.../internal/chat/enqueue_test.go:578` | 不带 `request_id` 则**每次都新建**（故客户端必须自己带上） |

结论：幂等成立，且客户端必须自己持久化 `request_id`（服务端不会替你补）。

---

## 7bis. 切片 C 的设计增补（issue #30）

> 本节是 issue #30 要求的「实现前先出设计增补」。§7 只回答了「为什么单独排期」，
> 本节回答「怎么做」。

### 7bis.1 队列表结构

```dart
@DataClassName('OutboxRow')
class OutboxEntries extends Table {
  /// **就是 request_id 本身**（幂等键与主键合一，见 §7bis.3）。
  TextColumn get id => text()();
  TextColumn get userId => text()();
  /// null = 无归属入口（服务端分类链判定，同 §6.7）。
  TextColumn get groupId => text().nullable()();
  TextColumn get agentId => text().nullable()();
  TextColumn get input => text()();
  TextColumn get routingMode => text()();
  /// 入队时刻（毫秒 epoch），**FIFO 排序依据**。
  IntColumn get createdAt => integer()();
  /// 已尝试投递次数（含首次）。
  IntColumn get attempts => integer()();
  /// 下次可尝试的时刻（毫秒 epoch）。退避算出。
  IntColumn get nextAttemptAt => integer()();
  /// 最近一次失败原因（诊断用，UI 可展示）。
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
```

**为什么 `id` 就是 `request_id`**：两者一一对应，分开存会引入「哪个是真键」的
问题；合并后「重试复用同一 `request_id`」在结构上不可能写错。

**为什么没有 `status` 列**：状态由 `attempts` / `nextAttemptAt` / `lastError`
三者**派生**（见 §7bis.2 的状态机），不另存一份。多一个可写字段就多一处
「派生值与存储值不一致」的机会。

### 7bis.2 状态机（派生，不落库）

| 状态 | 判据 | 允许的操作 |
|---|---|---|
| `pending` | `attempts == 0` | 投递 / 取消 |
| `retrying` | `attempts > 0 && attempts < maxAttempts` | 投递（到 `nextAttemptAt` 后）/ 取消 |
| `failed` | `attempts >= maxAttempts` | **手动重试**（重置 attempts）/ 删除 |
| （投递中） | 内存态，不在表里 | **不允许取消**（见 §7bis.5） |

### 7bis.3 幂等：`request_id` 由队列层生成并持久化

```dart
// 入队时生成一次，此后每次重试都用同一个。
final id = _uuid.v4();
```

服务端语义已核实（issue #30 正文）：`enqueue.go:265` 用
`GetChatTurnByRequestID` 查重、命中则**复用既有 turn**；`:325` 是并发兜底；
幂等键作用域是 **(user_id, request_id)**（`enqueue_test.go:553`）；未提供时
保持「每次新建」（`:578`）。

故客户端可以放心地「投递失败 → 带同一 `request_id` 重试」。

### 7bis.4 重试策略

```
退避：base 2s × 2^(attempts-1)，封顶 5 min，加 ±20% 抖动
上限：10 次（跨约 25 分钟）—— 超过则标 failed，**不自动删除**
```

**为什么加抖动**：多个客户端同时恢复网络时，固定退避会让请求在同一毫秒撞上
服务端。抖动把它们错开。

**为什么超限后不自动删除**：那是**用户输入的文本**，不是可丢弃数据。自动删除
等于「用户打了字、我们弄丢了、还不告诉他」。改为标 `failed` + UI 提示 + 手动
重试/删除。

**哪些错误可重试**（`OutboxRetryPolicy.isRetryable`）：

| 错误 | 可重试 | 理由 |
|---|---|---|
| `NetworkError(retryable: true)` | ✅ | 连接超时 / DNS / TLS——网络恢复后就好了 |
| `HttpError` 5xx | ✅ | 服务端故障，重试是正确响应 |
| `HttpError` 429 | ✅ | 限流，退避后重试 |
| `HttpError` 408 | ✅ | 请求超时 |
| `NetworkError(retryable: false)` | ❌ | 明确不可重试（如 TLS 证书错误） |
| `HttpError` 4xx（其余） | ❌ | 400/404/409/422 重试无用（请求本身有问题） |
| `HttpError` 401/403 | ❌ | 需重新登录，重试只会一直 401 |
| `ParseError` | ❌ | 契约漂移，重试无用——应尽快暴露 |
| `AuthError` / `ValidationError` / `StorageError` | ❌ | 同上 |

终态错误**立即移出队列**并把错误上抛给 UI（不是静默丢弃：用户要知道
「这条没发出去，原因是 X」）。

### 7bis.5 顺序保证：严格全局 FIFO + 队首阻塞

**只投递队首**。队首失败（可重试）就**停下**，不跳过它去投后面的。

**为什么不在 group 之间做轮转**：失败模式是「断网」，它平等地影响所有 group
——那时什么都投不出去，轮转没有收益。而一旦是**终态**错误（400），队首会被
立即移出，队列自动前进。故「队首阻塞」的持续时间上界 = 网络中断时长，而那段
时间里本来也投不出任何东西。**全局 FIFO 在正确性与实现复杂度上都更优。**

**为什么顺序本身是硬要求**：两条消息调换顺序会改变语义（「帮我改这个」
「算了别改了」）。客户端不得重排用户消息。

**`failed` 的条目被跳过**（不算阻塞）：它的重试权在用户手里，不该挡住后面的。

### 7bis.6 与 SSE 乐观回显的对账（**本切片最关键的决策**）

#### 离线期间：进「待发送」条，**不进时间线**

| | 进时间线（`_buffer`） | 进待发送条（本设计） |
|---|---|---|
| 需要 turnId 吗 | 需要——归约器**按 turnId 去重** | 不需要 |
| 没有 turnId 的后果 | 服务端 `user_message` 到达后**渲染两个气泡**（AGENTS.md 已记载这个取舍） | 无此问题 |
| 被 `maxBufferEvents` 裁剪 | 会（2000 条上限） | 不会 |
| 需要改 `EventReducer` 吗 | 需要（加「待发送」态） | 不需要 |

即：**离线消息进「待发送」条，与既有 `PendingMessagesBar` 同型**
（那条栏的语义正是「消息还没被服务端处理」，此处是同一语义的客户端侧版本）。
这样本切片**完全不触碰 `EventReducer`**，把风险限制在队列本身。

#### 投递成功时：移出队列 + 用**服务端返回的 turnId** 注入乐观回显

```
投递成功 → 拿到 SendMessageResult{turnId, groupId}
        → 移出队列表
        → controller.injectLocalUserMessage(input, groupId, turnId: turnId)
```

此时 turnId 是**真的**，故服务端随后的 `user_message` 事件会**原位合并**
（`event_reducer.dart` 的 `_indexOfUserMessage`），不会出现两个气泡。

于是消息「从待发送条移动到时间线」——位置跳了一下，但语义是干净的：
**队列里的东西还不是对话的一部分**，投递成功才是。

**若条目在投递过程中被取消**（不可能——§7bis.5 禁止投递中取消），或行已不在
表里（用户已删除），则不注入回显：服务端的 SSE 事件仍会照常渲染它。这是
诚实的——消息**确实**送达了。

### 7bis.7 投递触发时机

| 触发 | 说明 |
|---|---|
| 入队后立即试一次 | 若 `send` 失败只是偶发（不是真断网），这一次就成功了 |
| 定时器（退避） | 队首失败后按 `nextAttemptAt` 排一次 |
| **SSE 状态变为 `connected`** | 网络恢复的**最强信号**——比轮询准确，且不额外耗电 |
| 手动「重试」 | 用户点按钮 |

### 7bis.8 取消：只允许「未投递中」

`cancel(id)` 在条目正被投递时返回 `false`（拒绝），UI 保持该条目直到请求
resolve。**不**做「标记取消 + 忽略结果」：那会留下「用户以为取消了，服务端
却建了 turn」的静默不一致——而服务端**没有**删除 turn 的端点可用来补救。

### 7bis.9 存储失败的处理（与切片 A/B 相反）

切片 A/B 是**可丢弃数据**：写失败静默降级。队列**不是**——它装的是用户输入。
故 `OutboxStore.save` 失败时**抛 `StorageError`**（同 `SyncStateStore`），
`submit` 把它上抛给 UI。

降级行为是**旧行为**：写不进队列 → 发送失败提示（修复前的表现）。这比
「假装排队成功、其实什么都没存」好——后者会让用户以为消息发出去了。

### 7bis.10 装配

| 位置 | 内容 |
|---|---|
| `spb_domain/lib/src/outbox.dart` | `OutboxEntry` / `OutboxStore` 契约 / `OutboxRetryPolicy` / `OutboxQueue` |
| `spb_data/lib/src/outbox_store.dart` | `DriftOutboxStore` + `OutboxEntries` 表（schemaVersion 4 → 5） |
| `apps/*/lib/providers.dart` | `outboxStoreProvider` + `outboxQueueProvider`（**非** `autoDispose`——见下） |
| `spb_domain/.../chat_stream_controller.dart` | 可选 `outbox`；`send` 在**可重试失败**时入队；订阅 `delivered` 注入回显 |
| `spb_features/.../outbox_bar.dart` | 「待发送」条（列出 / 取消 / 手动重试 / 删除） |
| `spb_core/lib/src/errors.dart` | `MessageQueuedError` / `MessageDeliveryFailedError`（`SpbError` 是 sealed，子类必须同库） |

⚠️ **`outboxQueueProvider` 不能是 `autoDispose`**：`chatStreamControllerProvider`
是 `autoDispose.family`（离开对话页即释放），而队列的重试定时器**必须活过页面
生命周期**——否则用户发完消息切走，消息就永远卡在队列里没人投递。

方向是单向的：**控制器依赖队列**（`send` 失败时入队）；队列**不**依赖控制器
（投递成功只推自己的 `delivered` 流，控制器订阅它）。故无循环依赖。

⚠️ **`outboxQueueProvider` 还必须在 App 启动时预热**（`apps/*/lib/app.dart`
的 `initState` 里 `ref.read`）：Riverpod 的 provider 是**惰性**的，而该 provider
的构造里挂着「按 userId 恢复队列」的 `ref.listen`。若只在对话页里读，则
「断网发一条 → 关掉对话页 → 重启 App」后队列不会被恢复，消息要等用户再次打开
某个对话才可能被重试（甚至永不重试）。

---

### 7bis.11 实现要点与验收（issue #30）

**新增/改动**：

| 位置 | 内容 |
|---|---|
| `spb_core/.../errors.dart` | `MessageQueuedError`（已排队，**不是**失败）、`MessageDeliveryFailedError`（投递最终失败） |
| `spb_domain/lib/src/outbox.dart` | 契约 + 队列实现（约 24 KB，含大量「为什么」注释） |
| `spb_data/lib/src/outbox_store.dart` | `DriftOutboxStore`（**失败抛 `StorageError`**） |
| `spb_data/.../database.dart` | `OutboxEntries` 表（PK `id`；含 `maxAttempts` 列）；schemaVersion 4 → 5 |
| `spb_domain/.../chat_stream_controller.dart` | `send` 入队 + `_bindOutbox`（订阅 `delivered` / `failures`）+ SSE `connected` → `onConnectivityRestored` |
| `spb_features/.../outbox_bar.dart` | 「待发送」条（空队列不占空间；最多渲染 3 条 + 「还有 N 条…」） |
| `spb_features/.../conversation_page.dart` | `outboxEntries`/`outboxSnapshot`/三个回调；`MessageQueuedError` 的**独立**提示分支 |
| `apps/*/lib/providers.dart` | `outboxStoreProvider` + `outboxQueueProvider`（非 autoDispose） |
| `apps/*/lib/app.dart` | `initState` 预热队列 |

**验收用例（共 93 条：`spb_data` 17 + `spb_domain` 50 + `spb_domain` 接线 9 +
`spb_features` 12 + 两端装配各 2 + `spb_data` 迁移 3）**：

| 层 | 覆盖 |
|---|---|
| `spb_data` | 全字段 round-trip；`null` 往返（含「null 覆盖非 null」）；幂等 upsert；FIFO 排序；多账号隔离；delete/clear；**库关闭后读写抛 `StorageError`**；v4→v5 与 v1→v5 跳版迁移 |
| `spb_domain`（策略） | 指数退避逐档；封顶 5 min；`attempts<=0` 退化；抖动落在 ±20% 且确实在变；`isRetryable` 全类型表（含 408/429/5xx/4xx/401/`NetworkError(retryable:false)`） |
| `spb_domain`（条目） | 状态派生四态；`clearLastError`；`toRequestFields` 的 `request_id` 映射与 `group_id` 缺席 |
| `spb_domain`（队列） | submit 三分支（立即投递 / 入队 / 入队也失败）；终态错误不入队；重试复用同一 `request_id`；严格 FIFO + 队首阻塞；退避窗口内不投；`failed` 被跳过；重试用尽保留条目并上报；终态失败移除并上报；投递成功推 `delivered`；cancel/retryNow/remove；**删除失败回滚内存**；`onConnectivityRestored` 提前退避但不碰 `failed`；load 恢复/失败不抛/换账号替换；并发 drain 不重复投递；dispose 后 no-op；`entries` 推全量快照；**drain 不缩短时必须中断** |
| `spb_domain`（接线） | 可重试错误入队并抛 `MessageQueuedError`；**入队不注入乐观回显**；终态错误不入队；未注入队列时行为不变；投递成功用服务端 turnId 注入；**别的对话不注入**；SSE `connected` 触发重试；终态失败推 `MessageDeliveryFailedError`；dispose 退订 |
| `spb_features` | 未注入不渲染；空队列不占空间；展示文本与计数；流推送更新；失败态换色 + 原因；取消/重试/丢弃三个回调；超 3 条折叠；`MessageQueuedError` → 「已加入待发送」而**非**「发送失败」；普通错误仍提示「发送失败」 |
| `apps/spb_desktop` / `apps/spb_mobile` | 各 2 条：`outboxStoreProvider` 真的用注入的 `AppDatabase`；`outboxQueueProvider.isAutoDispose == false`。**两端各测一份**——否则「一端接错 db」在另一端测试里看不见 |

**反向验证（每条去掉对应代码即失败，逐条实测过）**：

| 去掉什么 | 失败用例数 |
|---|---|
| `delayFor` 用 `pow(2.0, …)`（改回 `pow(2, …)`） | 1 |
| `status` 用 `maxAttempts`（改回 `defaultMaxAttempts`） | 1 |
| `_attempt` 用 `entry.maxAttempts`（改用 `_policy.maxAttempts`） | 1 |
| `drain` 的进度哨兵 | 0（fail-safe，见下） |
| `_nextSendable` 跳过 `failed` | 1（且**实测挂死到超时**，故加了哨兵） |
| store 的 `Value(null)`（改 `Value.absent()`） | 1 |
| store 的 `load` 抛 `StorageError`（改返回 `[]`） | 2 |
| store 的 `delete` 抛 `StorageError`（改静默） | 1 |
| store 的 `clear` 抛 `StorageError`（改静默） | 1 |
| store 的 `maxAttempts` 持久化（改写死 10） | 1 |
| 迁移 `from < 5`（改 `from == 4`） | 1 |
| `cancel` 的失败回滚 | 1 |
| 终态失败的上报 | 1 |
| 重试用尽时保留条目（改成删除） | 1 |
| `onConnectivityRestored` 不碰 `failed` | 1 |
| 控制器 `send` 的入队分支 | 1 |
| 控制器入队时**不**注入回显 | 1 |
| 控制器的 group 过滤 | 1 |
| 控制器的 `onConnectivityRestored` 钩子 | 1 |
| 控制器的 `failures` 订阅 | 1 |
| 对话页的 outbox 条渲染 | 8 |
| 对话页的 `_subscribeOutbox()` | 8 |
| 对话页 3 条封顶 | 1 |
| 对话页 `onSend` 也走错误处置 | 2 |
| `outboxStoreProvider` 用注入的 db | 1 |
| `outboxQueueProvider` 非 autoDispose | 2（两端各 1） |

**一条「反向验证为 0」的诚实记录**（不留假绿）：

**`drain` 进度哨兵**：正确代码上不可达（`failed` 被跳过 → 循环立刻 break），
故无用例能抓住它。它是 **fail-safe**：真正拦的是「将来有人改坏
`_nextSendable`」——那会让整个测试文件挂到超时（实测过），哨兵把「挂死」
变成「记 error + 中断」。保留它是因为挂死的代价远高于一个不可达分支。

**另两条缺口已在本轮补上**（初版留了缺口，补的过程本身有方法论价值）：

| 缺口 | 初版为何抓不住 | 修法 |
|---|---|---|
| store 的 `delete`/`clear` 静默降级 | 只测了 `load`/`upsert` 的失败路径，`delete`/`clear` 没测 | 补两条「库关闭后 delete/clear 抛 `StorageError`」用例。**用户可见后果是实的**：删不掉的条目会被 `drain` 反复投递，静默吞掉异常会让调用方以为「已丢弃」，重启后又回来 |
| `onConnectivityRestored` 不碰 `failed` | 断言的是「投递顺序为空」——去掉 `continue` 后条目被提前到 `now`，但 `drain` 随后仍跳过 `failed` 条目，**顺序观测不到差异** | 改为断言 `queue.snapshot.single.nextAttemptAt` **未变**。教训：断言要落在**被改动的那一行直接影响的可见状态**上，而不是它下游的间接后果（下游可能被别的逻辑掩盖） |

**另外两个「实现时发现、非本切片引入」的既有缺陷**（已一并修掉）：

- **`pow(2, n)` 整数溢出**：`dart:math` 的 `pow` 在「整数底 + 非负整数指数」
  时返回 **int**，而 Dart 的 int 是定长 64 位——`pow(2, 99)` **静默回绕成 0**。
  结果是 `delayFor` 返回**零延迟** → `_scheduleRetry` 立刻重投 → **忙循环打
  服务端**。修法：底数写 `2.0`。
- **`OutboxEntry.status` 硬编码 `defaultMaxAttempts`**：任何自定义
  `maxAttempts` 的策略都会让条目**永远到不了** `failed`，`_nextSendable` 也就
  永不跳过它 → 无限重试。修法：把上限**快照在条目上**（`maxAttempts` 列），
  让 `status` 与 `_attempt` 同源。

---

## 8. 切片 A 的实现要点（阶段 2 的规格）

### 8.1 契约（`spb_domain`）

```dart
/// 对话列表缓存（**可丢弃**数据：读失败一律降级为「无缓存」）。
abstract interface class GroupCacheStore {
  /// 读该用户的缓存列表；无缓存返回空列表（**不抛异常**）。
  Future<List<ChatGroup>> load(String userId);

  /// **整表替换**该用户的缓存（见 §3.3）。
  Future<void> save(String userId, List<ChatGroup> groups);

  /// 清空该用户缓存（登出时调用；**不**影响同步状态）。
  Future<void> clear(String userId);
}
```

**为什么 `load` 返回 `List<ChatGroup>` 而不是带 `fetchedAt` 的包装**：陈旧提示
需要 `fetchedAt`，但把它塞进返回值会让**所有**调用点都要处理它，而多数调用点
（如「点进对话再返回」）不关心。故 `fetchedAt` 由实现层的
`Future<DateTime?> lastFetchedAt(String userId)` 单独暴露，只有列表页的兜底
分支去读。

### 8.2 装配（`apps/*`）

- `groupCacheStoreProvider`（桌面/移动各一个，同 `syncStateStoreProvider` 模式）；
- `GroupListPage` 接**可选** `cache` 参数（同 `groupUpdates` 的可选注入取向：
  为 null 时不缓存/不回落，页面单测不必造库）。

### 8.2bis userId 必须先本地持久化（实现时发现的**前置条件**）

设计初稿假设「userId 由调用方传入」，但实现时发现这不足以让回落生效：

`currentUserIdProvider` 内部是 `chatApi.me()`——一次 `GET /api/auth/me`
**网络请求**。而缓存要解决的正是在**断网冷启动**时展示列表，那时这个请求必然
失败 → userId 拿不到 → 缓存无法定位自己的行 → **回落失效**。

即：**不解决 userId 的离线可得性，整个切片 A 在目标场景下等于没做。**

故新增 `cachedUserIdProvider`（两端各一份），语义是「先本地、后网络」：

| 场景 | 结果 |
|---|---|
| 在线 | 本地命中，零额外请求（成功拿到时顺带写回本地） |
| 断网冷启动 | 本地命中 → 缓存可用 ✅ |
| 首次启动（本地无值）且断网 | 返回 null → 不回落（无行可查，无更优解） |

用偏好表（`PreferencesStore`）存，键 `auth.cached_user_id`。**不存 token**
（那是 `SecureTokenStore` 的职责，明文落盘等于交出登录态）——只存 userId 这个
非敏感标识。

### 8.3 回落逻辑（**关键**）

```
_loadMore():
  try:
    page = await api.listGroups(...)
    cache?.save(userId, _groups + page)      ← 成功时覆盖
    ...
  on SpbError catch (e):
    if (_groups.isEmpty && cache != null):
      cached = await cache.load(userId)      ← 只在**首次加载失败**时回落
      if (cached.isNotEmpty):
        _groups = cached; _fromCache = true  ← 展示缓存 + 陈旧提示
        return                               ← 不设 _error（不是错误页）
    _error = e
```

**三个必须遵守的点**：

1. **只在 `_groups.isEmpty` 时回落**：已有数据时回落会**覆盖用户刚看到的
   内容**（例如「加载更多」失败，回落会把整页缓存塞进来、丢掉滚动位置）。
2. **回落成功时不设 `_error`**：显示错误页会盖掉刚拿到的缓存内容。改为置
   `_fromCache = true`，由 UI 渲染「离线数据 · X 前更新」提示条。
3. **`_fromCache` 在下一次网络成功时必须清除**，否则提示条永久残留。

### 8.4 验收（issue 原文）

- `grep -c 'CachedGroups' packages/spb_data/lib/src/database.dart` → ≥1；
- `cd packages/spb_data && dart test` → 新表 CRUD + **「旧库升级后现有 4 张表
  数据不丢」**（扩展既有 v1 测试到 v3）；
- `flutter test packages/spb_features/test/chat/group_list_page_test.dart` →
  新增「网络失败时回落缓存并展示（不显示错误页）」；
- 反向验证：禁用回落 → 该用例失败；
- 门禁：`dart analyze --fatal-infos .` + `bash tools/check_layering.sh`。

### 8.5 一致性验收（issue #28 补）

§8.4 只验证了「网络失败 → 回落」。本地变更路径的写入需要**另一组**用例：

| 用例 | 反向验证（去掉对应 `_saveCache()` 即失败） |
|---|---|
| 新建对话后缓存含新对话 | ✓ |
| SSE `op=created` 后缓存含新对话 | ✓ |
| SSE `op=deleted` 后缓存不含被删项 | ✓ |
| SSE `op=title` 后缓存是新标题 | ✓ |
| 管理动作（改名）后缓存是新标题 | ✓ |
| 管理动作（删除）后缓存为空 | ✓ |
| 未注入 cache 时本地变更不报错 | （保护用例，不依赖修复） |

### 8.6 切片 B 的实现要点与验收（issue #29）

**装配**（与切片 A 同构）：

| 位置 | 内容 |
|---|---|
| `spb_domain/lib/src/timeline_cache.dart` | `TimelineCacheStore` 契约 + `isCacheableEvent` 纯函数 |
| `spb_data/lib/src/timeline_cache_store.dart` | `DriftTimelineCacheStore`（三层上限、upsert、静默降级） |
| `apps/{spb_desktop,spb_mobile}/lib/providers.dart` | `timelineCacheStoreProvider` + 注入 `chatStreamControllerProvider` |
| `spb_domain/.../chat_stream_controller.dart` | 构造参数 `TimelineCacheStore? timelineCache`；写点 `_backfill`/`loadOlder`；读点 `_fallbackToCache`；新流 `timelineFromCache` |
| `spb_features/.../conversation_page.dart` | `_OfflineTimelineNotice` 提示条（订阅 + **初值取快照**） |

**验收用例（共 50 条：`spb_data` 31 + `spb_domain` 15 + `spb_features` 4）**：

| 层 | 覆盖 |
|---|---|
| `spb_data` | `isCacheableEvent` 五类排除；round-trip / 升序 / `limit` 取最新 / upsert / 增量 / clear / 隔离；三层上限各自淘汰；坏行跳过；UTF-8 字节计；表缺失静默；v3→v4 与 v1→v4 跳版迁移 |
| `spb_domain` | 两个写点各一条；**SSE 热路径不写**；回落渲染 + 标记 + 流推送 + 去重；网络成功清除标记；切 group 复位；翻页游标来自缓存；缓冲非空守卫；乱序重排；`loadOlder` 失败不读缓存；未注入缓存不报错 |
| `spb_features` | 有缓存 → 渲染历史 + 提示条（非空态）；无缓存 → 空态且**无**提示条；网络成功 → 无提示条；**回落之后挂载**也能看到提示条（初值取快照） |

**反向验证（每条去掉对应代码即失败，逐条实测过）**：

| 去掉什么 | 失败用例数 |
|---|---|
| `load` 的 `orderBy asc(globalSeq)` | 6 |
| `limit` 取最新（改回升序取前 N） | 1 |
| `insertOrReplace`（改 `insert`） | 1 |
| 单 payload 上限检查 | 3 |
| 单 payload 按字节（改按字符） | 1 |
| `_trimGroup`（每 group 条数上限） | 3 |
| `_evictIfOversized`（全库字节上限） | 3 |
| 整 group 淘汰（改成逐条淘汰） | 3 |
| 坏行跳过（改成整份返回空） | 2 |
| `isCacheableEvent` 的 `goal_updated` 排除 | 2 |
| `_backfill` 写缓存 | 1 |
| `loadOlder` 写缓存 | 1 |
| `_fallbackToCache`（读缓存） | 5 |
| `_setFromCache(false)`（网络成功清除标记） | 1 |
| `switchGroup` 里的 `_setFromCache(false)` | 1 |
| 回落前的 `_buffer.isNotEmpty` 守卫 | 1 |
| 回落的 `cached.sort(...)` | 1 |
| 回落设历史边界 | 1 |
| `_fromCacheController.add(...)`（只改字段不推流） | 1 |
| `_setFromCache` 的去重 | 1 |
| 迁移 `from < 4`（改 `from == 3`） | 1 |
| 对话页 `_OfflineTimelineNotice` 渲染 | 2 |
| 对话页初值取快照（写死 false） | 2 |
| 对话页 `_subscribeTimelineCache()` | 2 |

---

## 9. 与既有机制的边界

| 机制 | 关系 |
|---|---|
| `ChatStreamController._buffer`（内存 2000 条） | 缓存是它的**持久化投影**。条数上限对齐（§5.2），避免「缓存里有用不上的数据」 |
| SSE cursor 回放（`_oldestLoadedGlobalSeq`） | **互补**：回放管「在线时断线」，缓存管「冷启动断网」 |
| `EventReducer` | **不感知缓存**。缓存提供的事件经 `_backfill` 同一路径进入 `_buffer`，归约逻辑零改动 |
| `SyncedFiles`（UFS 交付物） | **无关**：一个存对话事件，一个存文件 |
| `PreferencesStore` | 同库不同表。偏好是「配置」（读失败给默认值），缓存是「可丢弃数据」（读失败给空） |
| `GroupCacheStore`（切片 A） | 同一个 `AppDatabase`，但**写入语义相反**（整表替换 vs 增量 upsert）。两者互不读写对方的表 |
| 对话页的空态（`EmptyState`） | **互补**：缓存命中时**不**渲染空态（否则「本来有历史但看不到」）；无缓存时才退化为空态 |

---

## 10. 明确**不做**的事

- **不做双向同步**：缓存只从服务端流向本地。客户端不把缓存写回服务端。
- **不做全文检索**：缓存不建 FTS 索引。需要检索时走服务端已有的搜索端点（`ChatApi.searchMyTurns` →
  `GET /me/turns/search`，或 `GET /users/:uid/chat/search`）。
- **不做「缓存即真源」**：任何网络成功的响应都**无条件覆盖**缓存，缓存永不
  参与「哪个版本更新」的判定。
- **不缓存权限/身份**：`X-User-ID` 是网关注入的结果（AGENTS.md §5.1），
  客户端侧的值只用于拼 URL 路径与**隔离缓存行**，不是身份真源。
- **不改 Go API**：本设计全程纯客户端。

---

## 11. 相关文档

| 文档 | 关系 |
|---|---|
| `AGENTS.md` §5.7 | 排序/分页必须用 `globalSeq`（§3.5 的依据） |
| `AGENTS.md` §5.4 | `transient` 语义（§2.3 的依据） |
| `AGENTS.md` §6.7 | 无归属入口的异步投递（切片 C 的参考语义） |
| issue #28 | 本地变更后写缓存（§4.5 的补丁） |
| issue #29 | 切片 B（timeline 只读缓存）——**已实现**，实现要点见 §3.5 / §4.3 / §4bis.3 / §5.2 / §6.2 / §8.6 |
| issue #30 | 切片 C（离线写队列）——**已实现**，见 §7bis |
| `docs/deliverable-upload-and-conflict.md` | 交付物同步的完整设计（与本设计**无关**，但同样的「先设计后实现」流程） |
| `packages/spb_data/lib/src/database.dart` | 现有 schema 与迁移策略 |
| `packages/spb_domain/lib/src/sync_state.dart` | `SyncStateStore` 契约（本设计的模板） |
