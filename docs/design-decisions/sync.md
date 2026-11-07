# 交付物同步

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。UFS → 本地的单向同步：自动同步排程、进入对话的按需同步、完整判定与失败重试、
同步页并入设置页，以及迁移自 Tauri 的既有语义（**必须保持**）。

> 编号（`§6.x` / `§5.x` / `[§7](build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](README.md)。

---

### 6.42 自动同步：可配置的启动 / 周期 / 进对话按需（2026-10）

交付物同步此前只有**手动**入口（托盘「立即同步交付物」/ 设置页同步标签的按钮）。用户
得记得点，本地目录才会跟得上远端——而「本地有一份可离线打开的交付物」正是
同步这个功能的全部意义。本轮补上**可配置的自动同步**。

#### 三条入口，各自独立

| 项 | 语义 | 章节 |
|---|---|---|
| 「进入对话时按需同步」 | 打开对话时先判定该对话有没有新交付物，**有才提示**，点了只同步**这个对话** | §6.43 |
| 「启动后自动同步一次」 | 打开应用并完成登录后拉一轮 | 本节 |
| 「周期同步」 | 运行期间每隔 N 分钟拉一轮（关闭 / 15 / 30 / 60 / 180） | 本节 |

三者**相互独立**：「只在启动时同步一次」是合法且常用组合（每天开一次应用的
用户不需要周期拉取）。故
`AutoSyncConfig.isEnabled = onGroupOpen || onLaunch || isPeriodic`，
而非要求全部开启。

前两项是**定时**触发（不管有没有变化都跑一轮，引擎会算出空计划，成本是拉
一遍清单）；「进对话按需」是**事件**触发（先花一次单条查询判定，有才动）。
两者的分工见 §6.43 的「为什么两者不能互相替代」。

#### 默认全关，且这是**有数据依据**的

生产实测首次全量同步 **5666 条 / 4.7 GB**。静默替用户拉这么多不可接受（计费
网络、小容量磁盘）。故 `AutoSyncConfig.disabled` 是默认值，用户显式开启后
才排程。

#### 分层

| 层 | 内容 | 为什么在这一层 |
|---|---|---|
| `spb_domain` `sync_auto_config.dart` | `AutoSyncConfig`（`onGroupOpen` / `onLaunch` / `intervalMinutes` / `allowedIntervals` / `encode` / `decode`） | 序列化与档位钳制是**正确性核心**（错一点就静默不工作），须能无头单测 |
| `spb_domain` `auto_sync_scheduler.dart` | `AutoSyncScheduler`（`apply` / `pause` / `dispose` / `isScheduled` / `isRunning`） | 排程判据同理；注入 `run` 后可用 `fake_async` 逐条断言 |
| `spb_features` `settings_page.dart` | 「自动同步」区块（`showAutoSync` 参数） | 渲染与表单交互 |
| `apps/spb_desktop` | `autoSyncSchedulerProvider` / `reconcileAutoSyncProvider` / `app.dart` 的 `_installAutoSync` | 装配：进程生命周期 + 登录态订阅 |
| `apps/spb_mobile` | **只读写偏好，不装配排程器** | 见下「移动端为何不参与」 |

#### 五条不得违反的设计判据

**1. 自续排的一次性 `Timer`，不是 `Timer.periodic`。**

`periodic` 在回调里做异步工作时会让两轮重叠（上一轮没跑完就排下一轮）。
`DeliverableSyncUseCase` 会按 stateKey 读写同一份游标，两轮并发推进**不安全**
（可能重复下载，或跳过未下载的区间）。故用一次性 Timer，**结束后**才续排
——「本轮结束 → 距下一轮 N 分钟」。

代价（诚实记录）：长轮次（首轮全量可能跑很久）期间 `isScheduled` 为 false。
这是**正确**状态（现在确实没排着东西），不是缺陷。

**2. `pause` 必须清空已应用配置（否则第二次登录后永久失效）。**

若 `pause` 只取消计时器而保留 `_applied`，重新登录时装配层会喂一份**相同**
配置，`apply` 的幂等判定让它直接返回 → 自动同步在第二次登录后永久失效，且
没有任何征兆。有用例专门钉住（`pause 后 apply **相同**配置必须重新武装`）。

**3. `apply` 以配置相等做幂等键（否则周期被无限重置）。**

装配层有三个信号源（启动、登录态变化、保存设置）都会 reconcile。若每次都
重排计时器，用户每次切前台 / 保存设置都会把周期重置，实际间隔被无限拉长。

**4. 认证未就绪 / 无目录 / 单 group 模式 → `pause`，不武装。**

（「进对话按需」的同类门控见 §6.43，它有自己的三重门控 + 冷却闸。）

- `AuthStatus.unknown` 期间（启动读凭证那一瞬间）发起同步拿不到 token，白跑
  一轮并留下 401 日志；
- 没目录 → `_runSync` 每轮抛「请先选择同步目录」；
- 单 group 模式（`!allGroups && groupIds.isEmpty`）→ `toScope()` 每轮抛。

三者都是**每 N 分钟复现一次**的纯噪音。注意「勾选若干对话」是**可以**同步的
（`canSync` 只排除单 group 模式），别误判。

**5. `runSyncActionProvider` 必须单飞。**

自动同步引入后有三个触发源，**自动 tick 与手动触发可以重叠**。语义选择
「**复用同一个 Future**」而不是「静默跳过」：手动触发若被跳过，用户会看到
按钮点了没反应、也没有进度；复用则让等待方拿到同一份结果，UI 的 busy 态
自然一致。

#### 移动端为何不参与（但**必须**读写偏好）

移动端**不装配排程器**：后台定时器在 Android/iOS 上不可靠（系统会冻结或杀掉
进程），排一个不会响的计时器等于骗用户。故：

- `SettingsPage.showAutoSync` 为 `false` → **整段不渲染**（不是渲染成禁用、
  也不是渲染后静默不生效）。这是「不展示点了没反应的开关」的既有取向
  （[§6.10](architecture.md) 同一判据）。
- 但 `loadSyncSettingsProvider` / `saveSyncSettingsProvider` **仍原样读写**
  `sync.auto` 键。因为同一份 `SyncSettings` 会在两端之间流转：用户在桌面端
  开过「每 30 分钟」，然后到移动端只改了「同步图片」并保存——若不写回，
  桌面端的配置就被**静默清掉**了。

即：移动端「不实现」不等于「可以破坏」。

#### 两个易写错的实现细节

**1. `_tick` 里必须 `_cancelTimer()` 而不是 `_timer = null`。**

`apply` 的顺序是「先排周期，再跑启动轮」——启动轮进 `_tick` 时那个计时器
**是活的**。只把字段置 null 会丢掉引用但留下僵尸 Timer，它到期后再触发一次
`_tick`，于是「一轮」变成两轮并发。这条被 `fake_async` 用例抓到过（最初的
写法就是错的）。

**2. 间隔钳制是「就近」而不是「非法即 0」。**

0 意味着**关掉周期同步**。若某天档位集合调整，老用户存的 180 被判成「非法」
→ 静默变成「不周期」，用户会以为自动同步坏了。就近钳制至少保住「仍在自动
同步」这个意图。等距时取**较小**档位。

同理 `decode` 遇损坏值退回**全关**而不是全开：退回全开会在用户毫不知情时
持续拉取 4.7 GB，退回全关只是回到手动模式（点一次同步就发现了，代价可逆）。

#### 反向验证（14 项逐条实测）

| 改坏 | 失败用例 |
|---|---|
| `pause` 不清 `_applied` | 3（重新武装 ×2 + 从启用改全关） |
| `_tick` 不续排 | 4 |
| `_tick` 用 `_timer = null` 而非 cancel | 1 |
| `apply` 去掉幂等 | 1 |
| `SyncSettings.==` 不含 `auto` | 1 |
| `decode` 损坏时退回「全开」 | 1 |
| 非法间隔钳到 0 | 3 |
| `reconcile` 不检查认证状态 | 1 |
| `reconcile` 不检查 `canSync` | 2 |
| 保存设置后不 reconcile | 1 |
| 去掉单飞守卫 | 1 |
| 移动端不写回 `sync.auto` | 1 |
| 移动端读设置时丢掉 `auto` | 2 |
| `showAutoSync` 不生效 | 4 |

#### 与既有同步语义的关系（**未改变**）

自动同步只是**触发时机**变了，同步本身的行为完全不变（[§6.42](sync.md) 的
既有语义逐条保留）：单向 UFS → 本地、`updated_since` 游标 + etag 增量、
删除只凭 `deleted_at`、跳过 `reports/tts/**`、媒体默认不同步、单文件上限、
`{root}/{group_id}/…` 目录结构、失败项不写状态。

**不会**因为「自动」而变成双向：反向同步会触发服务端 groupsync 写入回路
（见 `docs/deliverable-upload-and-conflict.md` §0 结论速览），那是用户显式
点「回传」时才走的路径。

#### 有意不做

- **不做文件系统监听（watch 目录变化）**：远端才是真源，本地改动不回传；
  监听只会在用户手动改本地文件时触发一轮空拉取。
- **不做「同步完成后弹通知」**：已有托盘提示（`TrayTooltipController` 显示
  「同步中…」）与 `syncInFlightProvider` 的 busy 态。再加系统通知需移动端
  与桌面端各自的权限流程，收益不足。
- **不做「上次同步时间」的持久化展示**：`SyncStateStore` 里已有 per-stateKey
  的游标（含时间戳），但那是同步正确性状态，不是 UI 数据；为展示它而多读
  一次库不值得。
- **不在移动端实现前台定时器**：应用在前台时用户就在看界面，手动点一下比
  「每 15 分钟自己拉一次」更符合预期；且移动端没有托盘，同步发生与否不可见。

### 6.43 进入对话时按需同步（2026-10）：判定 → 提示条 → 用户点

> **历史实现记录**：下文的最大成功时间水位、`page_size=1` 探测和展示即冷却
> 已由 §6.52 修正。当前以完整分页清单、路径/etag 比对和成功后冷却为准。

§6.42 的两条入口都是**定时**的：到点就跑，不管有没有变化。它们缺的是
**用户的注意力落点**——「我正在看这个对话，它的交付物应该已经在本地了」。
本节补上这条**事件**触发的通路。

#### 为什么需要它：定时器解决不了「此刻」

| 场景 | 定时器 | 进对话按需 |
|---|---|---|
| 用户正在看某个对话，希望目录里有它最新的产出 | 等下一个 15 分钟 | **立刻判定** |
| 用户不在 app 里，目录要被编辑器 / 脚本读 | ✅ 唯一覆盖者 | ❌ 做不到 |
| 用户只是点开一个对话看一眼 | 与该对话无关，照跑 | 未命中则零开销 |

即：两者**不能互相替代**。定时器的不可替代价值是「人不在 app 里时目录仍
新鲜」；进对话触发解决的是「人正看着的时候还差一段」。故本轮是**新增**而
非替换。

#### 为什么是「提示条」而不是静默自动同步

判定命中后同步的是**这个对话**（`SyncSingleGroupScope`，见下），但一个活跃
对话仍可能有几百 MB 的产出。用户只是点开看看时静默启动下载，是把一次误判
变成一次等待。故提示条把决定权交回用户：

```
本对话有 12 个交付物未同步到本地          [立即同步] [×]
```

#### 定向同步：`SyncSingleGroupScope`（**两个性质缺一不可**）

「只同步这个对话」是安全的——但**前提是不得推进共享游标**。两者构成一个新
范围类型（`spb_domain` 的 `deliverable_sync.dart`）：

| 性质 | 本类 | 为什么 |
|---|---|---|
| 列举前缀收窄到 `{gid}` 子树 | ✅ | 否则「只同步这个对话」在请求层面仍是全量（5666 条元数据） |
| **不推进** `__workspace__` 游标 | ✅ | 见下 |
| 本地布局保留 `{gid}/` | ✅ | 与 workspace 模式一致；否则同一文件会落到两个位置 |
| 状态键共用 `workspaceStateKey` | ✅ | 先定向同步 A 再全范围时，A 的文件靠 etag 命中而不重下 |

**为什么「推进游标」是致命的**：`SyncGroupsScope` 与 `SyncWorkspaceScope`
共用 `workspaceStateKey`，而 `SyncState.advanceCursor` 取 `max()`。若定向同步
也推它，游标就会越过其它 group 里从未同步过的文件——它们此后再也不出现在
增量清单里（`updated_since` 过滤掉），**永久漏下载而报告显示成功**。

**为什么做成范围属性而不是调用参数**：`advancesCursor` 是 `SyncScope` 的
getter，`run` 里从 `scope.advancesCursor` 派生。做成 `run(advanceCursor:)`
参数就允许「窄列举 + 推游标」这个致命组合——而那正是上面的永久漏文件。

⚠️ **`SyncGroupScope` 与 `SyncSingleGroupScope` 不是一回事**（易混）：

| | `SyncGroupScope` | `SyncSingleGroupScope` |
|---|---|---|
| 本地布局 | `{root}/reports/a.md`（剥掉 gid） | `{root}/{gid}/reports/a.md` |
| 状态键 | `groupId`（独立） | `workspaceStateKey`（共用） |
| 推进游标 | 是 | **否** |
| 谁在用 | 程序化入口（设置页不产出） | 进对话提示条的「立即同步」 |

故判定必须读**与写入同一个状态键**（`workspaceStateKey`）：读 `gid` 那个键会
比不到东西，永远判 stale。

#### 分层

| 层 | 内容 | 为什么在这一层 |
|---|---|---|
| `spb_domain` `group_sync_probe.dart` | `groupSyncNeed`（纯判据）/ `groupSyncWatermark`（取本 group 水位）/ `latestUpdatedAtOf` / `GroupSyncThrottle`（冷却闸） | 判据错一个方向都很糟（该同步却判 upToDate = 静默失效；不该同步却判 stale = 每次点对话都跑一轮同步），须能无头测 |
| `spb_features` `sync/group_sync_hint.dart` | `GroupSyncHint`（纯展示，入参 count / onSync / onDismiss / syncing） | 无业务语义的展示组件 |
| `apps/spb_desktop` `providers.dart` | `checkGroupSyncNeedProvider`（判定 + 计数）/ `groupSyncThrottleProvider` / `runGroupSyncActionProvider`（定向同步） | 取数要 UFS 端点与同步状态，属装配层 |
| `apps/spb_desktop` `router.dart` `_ChatPage` | `_checkGroupSync` / `_syncFromHint` / `_syncCheck` | 生命周期就是「这个对话页这一次打开」 |
| `apps/spb_mobile` | **不装配**（只读写 `sync.auto` 偏好） | 与 §6.42 同一取向：移动端没有托盘反馈，且判定要额外 HTTP |

#### 判定判据：**本 group 的水位**，不是共享游标

同步引擎的语义是「**只有成功下载或 304 才 `markSynced`**」（`SyncEngine._merge`），
而 `markSynced` 记的是服务端那条的 `updated_at`。于是：

> 任何 `updated_at > 本 group 已同步水位` 的文件，都**不可能**是已成功同步的。

**水位 = 本 group 文件记录里最晚的 `updated_at`**（`groupSyncWatermark`）。

⚠️ **不能拿 `__workspace__` 游标比**（这是本节的第二处易错点）。定向同步
**不推进**游标（见上），于是「远端最晚时间 > 游标」在定向同步后会**永远成立**
——每次进对话都提示一遍，而每轮同步什么都不做。

水位则与进度同步前进：定向同步写文件记录 → 水位抬高 → 下次判定 upToDate。
两种同步方式（全范围 / 定向）都适用。

**水位函数必须区分两种布局**（`syncStateKeyFor` 决定）：workspace 布局按
「首段 == groupId」过滤，单 group 布局（键就是 groupId、落盘无 `{gid}/`
前缀）则全部条目都算。一律按首段判会让单 group 布局一条都匹配不上。

**严格大于**（等于水位说明那份文件就是抬升水位的那个）。

反向不成立（水位以下的文件也可能没同步过——首轮被体积/媒体过滤跳过的），
但那不影响本判据的用途：它是**触发条件**而非正确性条件。

#### 探测查询**必须**带 `updated_since`（否则排序退化，判定静默失效）

这是本节最隐蔽的一处，且**只在真实数据上才暴露**（2026-10 用户报「开了
按需同步，数据还是不会自动下载」）：

```go
// unified-file-service/internal/store/file.go:418
orderClause := "ORDER BY created_at DESC"
if filter.UpdatedSince != nil { orderClause = "ORDER BY updated_at DESC" }
```

即：**不带 `updated_since` 时按 `created_at` 排序**。而 agent 覆盖写既有交付物
走的是「上传新版本」（`ReplaceContentAndCreateVersion`）：`updated_at` 刷新，
`created_at` / `id` / `path` **全部不变**。生产实测 6948 个 group 文件里
**4974 个** `updated_at > created_at`。

于是 `page_size=1` 取到的是「最晚**创建**」而非「最晚**更新**」：一个三个月前
建、今天被重写的 `README.md`，在按 `created_at` 排序时排在很后面 →
`latestUpdatedAtOf` 得到早于水位的时刻 → 判 `upToDate` → **提示条永不出现**。
187 个 group 里 **56 个（30%）** 可复现（`created_at DESC` 的首条
`updated_at` 严格早于该 group 的 `MAX(updated_at)`）。

故判定与统计都**先取水位、再把它当 `updated_since` 传**。水位为空（首次同步
这个 group）时两者都不传——带任何值都会漏掉一部分历史交付物。

#### 非交付物条目要过滤（目录与机器产物都永远同步不了）

UFS 列表含两类「永远同步不了」的条目，`shouldSync` 对它们都是「跳过且**不
记录**」（不 `markSynced`、不抬水位）：

| 类别 | 例子 | 为什么同步不了 |
|---|---|---|
| 目录 | group 根、`reports/`、`assets/` | `shouldSync` 第一条就是 `if (file.isDirectory)` |
| 机器产物 | `reports/tts/**`、`.archive/**`、`_attachments/**` | `SyncSkipReason.machineGenerated` |

把它算进「最晚时间」/「未同步数」会让 group 永久 stale 且每轮同步什么都不做
——与冷却闸那条（被过滤的文件同样不 `markSynced`）是同一个模型限制的两个面。

⚠️ **机器产物这一类比目录隐蔽得多**：生产实测 **312 个 `/reports/tts/` 非目录
文件**。任何「最新变动是 TTS」的 group 都会永久 stale——提示条一直在，点同步
却什么都不同步。当时的探测辅助判据必须同时排除两类；当前由 `buildSyncPlan`
统一处理（§6.52）。

> 生产数字的复现口径（2026-10-22，bcc `/opt/unified-file-service/data/files.db`；
> 库会随部署变化，以实测为准）：
>
> ```sql
> -- 覆盖写占比
> SELECT COUNT(*) FROM files WHERE path LIKE '/workspace/groups/%'
>   AND is_directory=0 AND updated_at > created_at;
> -- 「created_at DESC 首条」早于该 group 最晚更新的 group 数（= 可复现数）
> CREATE TEMP TABLE g AS SELECT substr(path,19,instr(substr(path,19),'/')-1) AS gid,
>   created_at, updated_at FROM files
>   WHERE path LIKE '/workspace/groups/%' AND is_directory=0;
> CREATE TEMP TABLE top AS SELECT gid, updated_at FROM (
>   SELECT gid, updated_at, ROW_NUMBER() OVER
>     (PARTITION BY gid ORDER BY created_at DESC) rn FROM g) WHERE rn=1;
> CREATE TEMP TABLE mx AS SELECT gid, MAX(updated_at) maxu FROM g GROUP BY gid;
> SELECT COUNT(*) FROM mx;
> SELECT COUNT(*) FROM top JOIN mx USING(gid) WHERE top.updated_at < mx.maxu;
> ```

⚠️ **过滤目录带来一个连带约束：首次同步（无水位）时探测页大小不能是 1**。
那时服务端按 `created_at DESC`（没传 `updated_since`），而**新建的目录往往排在
最前**；`page_size=1` 恰好取到一个目录、过滤后得到 `unknown`，即使下面明明有
文件。故探测页大小按**有没有 `lower`**分档：有 `lower` 时 `1`（`updated_at DESC`
+ 已过 `updated_since`，一条即结论），无 `lower` 时 `100`（一次多花一页元数据，
只发生在该 group 首次同步）。

⚠️ **分档基准是 `lower` 而不是水位 `mine`**：决定服务端排序模式的就是「有没有
传 `updated_since`」，而 `sinceDays` 单独也能让 `lower != null` 而 `mine == null`
（见下节）。

#### 有 `lower` 时同样可能撞上非交付物（`page_size=1` 的另一半）

上一条只修了「无水位」那一半。有 `lower` 时页大小是 `1`，若那一条恰是**目录或
机器产物**，过滤后 `latest == null` → `unknown` → 提示条不出现，即使后面明明有
新文件。

这不是理论边界：目录的 `updated_at` **只在创建时设置**（UFS 不因写子文件而抬升
它），故「水位之后新建的目录」正好排在最前；而 `updated_at` 是秒级，同秒内
目录与新文件的相对顺序不确定——属真实 flakiness。

修法**保留快路径**：仅当「页大小本来就是 1」且「本页没有任何交付物」且
「`page.hasMore(...)`」时用 `pageSize: 100` 重探一次。`total == 1`（真的只有那
一条）不重探，不浪费一次请求。

否决「恒定 `pageSize: 100`」：那要改掉全部 `page_size: 1` 的查询断言与成篇
文档，而收益只是一次请求的差别。

#### 定向同步的时间下限用**本 group 水位**，不是共享游标

判定用本 group 水位（上节），同步若用共享游标，两者就不一致：提示条说「有 3 个
未同步」，用户点下去却下载 0 个，且报告显示成功。

共享游标是「整个 workspace 已同步到哪」，可能**远晚于**本 group 的进度（用户刚
把它勾进范围、或上一轮全范围同步时它被过滤）。拿它当下限会把本 group 真正缺失
的旧文件**过滤掉**。本 group 水位是更宽的下限（水位 ≤ 共享游标），故不会多漏
任何文件；重复列出的靠 etag 命中跳过，代价只是一页元数据。

故 `DeliverableSyncUseCase.run` 里 `saved` 按范围分派：`SyncSingleGroupScope`
用 `groupSyncWatermark(...).latestUpdatedAt`，其余用 `state.cursor`。

#### 时间下限：探测与同步必须**同一口径**（`sinceDays` 也要参与）

同步侧把「已保存游标 / 本 group 水位」与用户配的 `sinceDays` 取更晚者
（`effectiveCursor`）。探测侧若只看水位不看 `sinceDays`，两边就对「哪些算未同步」
得出不同结论：

```
用户设「只拉最近 30 天」，该 group 的文档全在 60 天前
  → 探测按全量数 → stale、报 N 个
  → 同步按 30 天下限列出 0 条 → 「已同步 0 个」→ 水位不前进
  → 每次进对话永久重复提示
```

故探测侧的 `lower = effectiveCursor(saved: mine, sinceDays:, nowUnix:)`，并把它
同时用作 `updatedSince`、`includeDeleted`、计数基准与页大小分档的判据。

#### 机器产物判据必须按「**group 内**路径」判（TTS 在下载侧曾漏网）

`ttsRelPrefix = 'reports/tts/'` 是**锚定开头**的（三端契约，见
`tts_audio_path.dart` 的类文档）。而 `shouldSync` 收到的 `relPath` 是**落盘**
相对路径，workspace 布局下形如 `{gid}/reports/tts/a.mp3` ——
`startsWith('reports/tts/')` 为 false。

于是**同一份文件在不同同步范围下结论相反**：

| 范围 | `relPath` | 命中 `reports/tts/`？ |
|---|---|---|
| `SyncGroupScope` | `reports/tts/a.mp3` | ✅ 跳过 |
| `SyncSingleGroupScope` / `SyncWorkspaceScope` | `{gid}/reports/tts/a.mp3` | ❌ **下载下来** |

修法：新增自由函数 `groupScopedRelativePath(ufsPath)`（只从 UFS 路径派生，与落盘
布局无关），`shouldSync` 内 `final groupRel = groupScopedRelativePath(file.path) ??
relPath;` 再判。**不改 `shouldSync` 签名**。

曾考虑 `SyncScope.groupRelativePathOf` 方法（需 `hasGroupSegment` 标志 + 四个子类
各覆写），已否决：自由函数的 API 面更小，且「过滤判据不该依赖调用方用的是哪种
范围」这条本身就要求它独立于 scope。

#### `.archive` / `_attachments` 必须按「任意层级段」排除

两个服务端机器目录：

| 段 | 产出者 |
|---|---|
| `.archive` | super_partyb `archivesnapshot` worker 直写 `workspace/groups/{gid}/.archive/v{N}/`（`manifest.json` / `snapshot.md` / `snapshot.html`），**绕过** groupsync 的排除 globs |
| `_attachments` | go-api 的附件暂存区（`CleanupOrphanAttachments(root, "_attachments", …)`，目录本身**不可删**——含活跃 turn） |

`machineGeneratedSegments = {'.archive', '_attachments'}`，**按段相等**判（不是
子串），故 `a/.archivex/b.md` 不会误伤。

⚠️ **必须客户端过滤**：UFS 的 `exclude_prefix` 只能按前缀匹配，无法表达「任意
层级」。

⚠️ 上传侧（`shouldUploadLocalFile`）**自动继承**这个排除——它本就收 group 内
路径。

#### 切换对话时在途的解析/聚焦会丢掉新一轮（`_resolveAgain`）

`_resolveUserAndFocus` 被 `initState` 与 `didUpdateWidget` 都调，而它 await 了整条
链（`currentUserIdProvider.future` → `_focus` → `_checkGroupSync`）。原先在途时
`if (_resolvingUser) return;` 直接丢弃——于是「用户在聚焦还没跑完时切到另一个
对话」会让**新的 groupId 既不被聚焦、也不被探测**，且没有任何重试点。

修法是 `do { _resolveAgain = false; … } while (_resolveAgain && mounted)`：在途
期间又有人请求时只置标志，当前这一轮结束后再跑一轮（最多多一轮，不会无限
递归）。桌面与移动端同构。

⚠️ **这一条与 `_focus` 的异常处理是一对**：`_focus` 曾与探测合在同一个
`try` 里，一次聚焦异常会把一个**无关的**探测也取消掉。现 `_focus` 单独
`try/catch` + `SpbLog.warn`，`_checkGroupSync()` 移出（并去掉无用的 `userId`
形参）。

#### 门控与判定的日志必须是 `info` 级

`SpbLog._minLevel` 默认就是 `info`，**debug 在生产被过滤**。而「用户说开了功能
但提示条从不出现」最难排查的一类恰恰在这里——所有证据都只在他本机的 debug 日志
里，而诊断报告（[§6.20](runtime-and-ops.md)）只收运行时可见的日志。

故门控早退（含 `on_group_open` / `can_sync` / `has_local_root` / `is_single_group` /
`selected_groups` 五个字段）、冷却期跳过、判定结论（`无需同步` / `有未同步交付物`）
与探测失败全部用 `SpbLog.info`。

#### 「立即同步」成功后要 `invalidate` 本地索引

同步刚往同步目录写了文件，而「打开 / 定位」的可用性来自
`deliverableLocalIndexProvider`（`FutureProvider`，读完就缓存）。不 invalidate
的话：提示条消失了，但侧边栏里那些文件**仍然显示为未同步**——用户点了「已同步
N 个」，却找不到能打开的那几个。

⚠️ **只 invalidate 本地索引、不 bump `_deliverablesReloadToken`**：远端清单没有
变（同步只写本地），bump 只会多一次无意义的 HTTP。

#### 三重门控 + 冷却闸（任一不满足就零开销）

| 门控 | 不满足时 |
|---|---|
| `auto.onGroupOpen`（默认 **false**） | 完全不探测 |
| `settings.canSync`（有目录、范围非空） | 不探测——没目录时判定必然 unknown，白跑一次 HTTP |
| 该 group 在用户勾选范围内（仅「勾选若干」模式） | 不探测——否则提示条会邀请用户下载一个他明确排除在外的对话 |
| `GroupSyncThrottle.allows(groupId)` | 不探测（见下） |

⚠️ **第三道门控不能省**：「立即同步」跑的是 `SyncSingleGroupScope`，它只按
`filter` 过滤、**不看** `scope`（那个 scope 在 `_runSyncSingleGroup` 里被有意
绕过）。故勾了 3 个对话、又点开第 4 个时，若不禁这一层，提示条会邀请用户
下载一个他明确排除在外的对话——而他会以为那是「当前对话的产出」。

**为什么必须有冷却闸**：`_merge` 只在 `_Downloaded` / `_NotModified` 时
`markSynced`；被过滤跳过（媒体 / `reports/tts/**` / 超体积）的文件**不记录**。
于是某个 group 里只要有一个 500 MB 的视频，它的 `updated_at` 就永远大于本
group 水位 → 判定长期命中 → 每次点进去都同步一轮 → 每轮什么都不做。默认冷却
10 分钟（内存态，不持久化：重启后允许再试一次是合理的）。

#### 三个易写错的地方

**1. 只在**命中**时 `markTriggered`，不在判定之前。**

若在判定前记冷却，那么「进来时没有新文件」也会把冷却期耗掉——用户之后真的
产生了新文件，再进来却不提示。有用例专门钉住
（`判定为 upToDate 时不消耗冷却期`）。

**2. 判定与触发必须分成两步。**

判定命中只意味着「有东西没同步」。直接开始拉会让用户在毫无预告的情况下看到
下载，且无法拒绝。

**3. 换同步目录时 `reset()` 节流器。**

冷却闸记的是「这个 group 刚才试过」。换了目录之后，用户打开对话时目录里
**确实**没有那些文件——但闸还挡着，于是提示条不出现、用户以为「同步坏了」。
这与 `bindLocalRoot` 里「换目录必须重置同步状态」是同一个道理。

#### 计数（只在命中时付成本）

判定用 `page_size=1` 只够回答「要不要」，不够给用户一句可读的话（「有 12 个
交付物未同步」）。故命中后再分页统计，且：

- **按同一水位过滤**：远端那一页通常既有新文件也有已同步的旧文件，全算进去
  会报虚高的数字；
- **上限 500**（`GroupSyncCheckResult.countCap`）：首次全量 5666 条，一直翻到
  tail 要发 57 次请求，而用户只需要知道「很多」。达到上限时文案写「500+」
  而不是精确的 500（那会让人以为正好 500 个）。

#### 已知限制（诚实记录）

- **被过滤掉的文件会让判定长期命中**：靠冷却闸 + 仅提示（不自动下载）压低
  代价。这不是缺陷而是模型限制（不 `markSynced` = 引擎认为「还没同步」）。
  目录与机器产物已在探测侧排除（见上节），但**用户配的过滤条件**（关掉媒体、
  单文件体积上限）仍属于这个模型限制：一个 20 MB 的 PDF 会让该 group 长期 stale。
- **本地被手动删除的文件探测不到**：判定看的是「远端有比水位新的吗」，
  而本地删除不改变远端 `updated_at`。这类情况靠同步引擎每轮的
  `presentLocally` 探测兜住（它会对 `state.files` 里每个路径 `stat` 一次）。
- **移动端不参与**：见上表。

#### 反向验证（39 项逐条实测）

| 改坏 | 失败用例数 |
|---|---|
| `groupSyncNeed` 用 `>=` 而非 `>` | 1 |
| 旧配置缺 `on_group_open` 键时回退成 true | 2 |
| `AutoSyncConfig.==` 不含 `onGroupOpen` | 1 |
| `GroupSyncThrottle.allows` 内部记录（纯查询变副作用） | 1 |
| 路由层不检查 `onGroupOpen` | 1 |
| 路由层不检查 `canSync` | 1 |
| 路由层不检查冷却 | 1（补测前为 **0**） |
| 判定 upToDate 也 `markTriggered` | 1 |
| 「忽略」按钮也触发同步 | 1 |
| 探测读 group 级状态键而非 `workspaceStateKey` | 2 |
| 统计不按游标过滤 | 1 |
| upToDate 也继续统计（漏提前 return） | 1 |
| 不判 `canSync` 就发请求 | 1 |
| 不判「该 group 是否在勾选范围内」就探测 | 1 |
| 计数上限去掉（无限翻页） | 1 |
| 设置页不渲染 `onGroupOpen` 开关 | 2 |
| 提示条把 0 写成「0 个」 | 1 |
| 提示条 `syncing` 时不禁用同步按钮 | 1 |
| 提示条 `syncing` 时不禁用关闭按钮 | 1 |
| 定向同步推进共享游标（`advancesCursor` 恒 true） | 1 |
| `SyncSingleGroupScope.relativePath` 不保留 `{gid}/` 前缀 | 1 |
| 判定读 `gid` 状态键而非 `workspaceStateKey` | 2 |
| 提示条「立即同步」走全范围 `runSyncActionProvider` | 1 |
| `groupSyncWatermark` 不区分单 group 布局 | 1 |
| `groupSyncWatermark` 用 `startsWith(groupId)` 而非首段精确比较 | 1 |
| 水位为空（有记录但无 `updated_at`）时判 stale 而非 unknown | 1 |
| 探测不传 `updated_since`（排序退化回 `created_at`） | 8 |
| 统计不传 `updated_since` | 6 |
| 目录条目计入「最晚时间」/「未同步数」 | 3 |
| 无水位时探测页大小仍为 1（恰好取到目录 → 误判 unknown） | 3 |
| 有水位时探测页撞上非交付物不扩页（`page_size=1` 的另一半） | 1 |
| 探测页大小基准回 `mine`（忽略 `sinceDays` 带来的 `lower`） | 1 |
| `sinceDays` 不参与 `lower` | 1 |
| 探测侧不排除机器产物（当前由 `buildSyncPlan` 统一处理） | 2 |
| `shouldSync` 用落盘 relPath 判机器产物（TTS 在 workspace 布局漏网） | 1 |
| `machineGeneratedSegments` 去掉 `.archive` / `_attachments` | 1 |
| `_resolveAgain` 循环去掉（在途时直接 return） | 1 |
| 「立即同步」成功后不 `invalidate` 本地索引 | 1 |
| `DeliverableSyncUseCase` 用共享游标作定向同步的时间下限 | 2 |

⚠️ 「路由层不检查冷却」这条**最初是假绿**：我的断言查的是节流器自己的状态
（`throttle.allows` 为 false），而没有验证路由层真的**调用**了它。修法是新增
一条「预置节流器 → 打开对话 → 断言一次探测都没跑」的用例。这与 [§6.17](testing.md) / [§6.33](build-and-release.md)
同一类：**只测被调用的组件、不测调用点**，接线断了也绿。

#### 有意不做

- **不做「只同步这个 group」**：硬约束，见上（会把共享游标推过其它 group）。
- **不做自动下载（静默）**：首次全量 4.7 GB，用户需要看得见、能拒绝。
- **不做「提示条里显示具体文件列表」**：侧边栏「交付物」tab 已经承担这个
  职责，提示条只需回答「有没有、多少个」。
- **不做探测结果持久化**：它是「这一刻的事实」，落盘会在下次启动时变成过期
  信息（与 §5.4 的 `schedule_created` 不带绝对时间同一取向）。

### 6.52 进入 group 的 UFS 同步：完整判定、失败重试与任务串行化

复核 §6.43 后确认：**本 group 最大成功更新时间不代表完整同步进度**。
较旧文件下载失败、同秒文件版本变化，以及第一页全是目录/机器产物，都会让
旧探测误判「无需同步」。定向同步还绕过全量同步的单飞保护，两轮读取旧状态后
整体保存会互相覆盖。

当前实现：

- 定向同步列举该 group 在用户 `sinceDays` 范围内的完整分页清单，不按文件
  最大成功时间或 workspace 游标裁剪；仍不推进共享游标。内容按路径/etag
  去重，补下历史漏项时不重下已同步版本。
- 探测同样分页读清单，复用 `buildSyncPlan` 判断路径/etag、删除和过滤条件，
  持续越过非交付物页面。最多统计 500 个待处理动作、扫描 200 页；异常分页
  明确报错。没有动作返回 `upToDate`，未配置/范围外返回 `unknown`。
- 任一下载或删除失败，`SyncEngine` 保存成功文件记录但保留本轮之前的游标，
  防止较新成功项越过旧失败项；下一轮重列后成功版本仍按 etag 跳过。
- 桌面端全量、周期和定向同步共用队列；相同范围的在途请求复用 Future，
  不同范围顺序执行。排队期间 `syncInFlightProvider` 保持 true，异常不堵队列。
- 仅展示提示不记录冷却；成功同步或用户明确忽略才冷却。部分失败/异常保留
  提示和重试入口；旧 group 的在途结果不能清掉新 group 的提示。

代价：进入 group 的检查可能读取多页元数据，不再保证一次单条查询。这是修复
「最大成功时间跳过缺失文件」所需的完整性检查，不会自动下载文件正文；用户
仍须点提示条的「立即同步」。本地手动删除文件的发现仍由实际同步的磁盘检查
负责，探测仅比较同步记录与远端版本。

回归用例：`group_sync_recovery_test.dart` 验证旧失败项重试、历史漏项恢复及用户
时间范围；`group_sync_probe_test.dart` 验证版本比对、跨页查找与过滤；
`sync_queue_test.dart` 用真实内存 drift 库和临时文件目录验证并发入口串行化；
`group_sync_wiring_test.dart` 验证提示条、失败后重试及切 group 的异步归属。

### 6.53 同步页并入设置页：两个标签（2026-10）

独立的 `/settings/sync`（`SyncPage`）与设置页（`SettingsPage`）曾有大量重复：
**目录 / 范围 / 媒体开关 / 单文件上限 / 拉取范围 / 本地清理**两边各画一份，且
两边选目录的行为还不一致（一边立即落盘、另一边走草稿）。用户要改同步配置
得知道「有两个页、改哪个都行但行为不一样」。现整合为设置页的两个标签：

| 标签 | 内容 |
|---|---|
| 通用 | 外观 / 通知订阅 / 个人偏好 / 桌面集成 / 导出诊断日志 / 账号 |
| 交付物同步 | 目录 / 范围 / 过滤与拉取范围 / 自动同步 / 本地统计与清理 / 同步执行（`SyncRunSection`：立即同步 + 脏检测 + 回传改动） |

入口全部收敛到 `/settings?tab=sync`（常量 `SpbRoutes.settingsSyncTab`）；
旧路径 `/settings/sync` 重定向（不炸历史入口 / 深链 / 托盘旧文案）。

#### 四个关键设计

**1. 一个 `ListView` + 两个 `Offstage` 区块，不是 `TabBarView`。**
两个标签各自都有不可丢的 State：同步标签的草稿与刚扫出的待回传清单，
通用标签的表单草稿。`Offstage` 只跳过绘制与命中测试，Element / State /
数据全留（与 [§6.46](ui.md) 侧边栏同一手法）。附带两个好处：

- `find.*` 默认 `skipOffstage: true`，隐藏标签里的同名 key 不会让
  `findsOneWidget` 变 `findsNWidget`——测试可以精确断言「两标签内容分开」；
- 目录卡片只画一处（`settings-pick-directory` 全页唯一）。

代价：隐藏标签的子树仍在树上（内存与布局成本，同 [§6.46](ui.md) 的量级分析），
两标签内容都会在首帧构建——设置页本就是低频页面，可接受。

**2. 「立即同步」跑的永远是**已保存**设置；草稿只能靠禁用隔离。**

两个半边缺一不可：

- **执行侧**：`runSyncActionProvider` / `_runSync` 每次都
  `loadSyncSettingsProvider()` 重读**已落盘**的设置（见 providers 里那段
  「每次都重新读设置」注释）。它**不看**页面上的草稿。
- **UI 侧**：`SyncRunSection` 拿到的 `localRoot` 是 **draft**（为了与刚选的
  目录一致、并能提示「尚未选目录」），但 `hasUnsavedChanges`（`_dirty`）
  为真时**禁用**「立即同步 / 扫描 / 回传」三个按钮并提示先保存。

少了后一半，用户会「按新目录点了同步，实际按旧目录跑」——而换目录会重置
同步状态（`bindLocalRoot`），误触发一次不可逆的状态清理。草稿与执行之间
没有灰区。

**3. 目录选择必须走 `pickDirectoryProvider`。**
桌面端 router 里曾把 `pickDirectory` 写成就地闭包
`caps.pickDirectory(title: ...)`——功能上没问题，但**绕过了 provider**，
测试 harness override 无效（tap 选目录后草稿不变、保存按钮不出现），
且对话框标题散在两处。修法：回 provider，title 兜底在 provider 内。
教训与 [§6.17](testing.md) / [§6.33](build-and-release.md) 同型：**装配层不要就地 new 依赖，注入点必须可替换**。

**4. 错误与「已保存」提示不属于任何标签。**
保存按钮在 AppBar 上、两个标签都可能触发；提示若只活在某个标签的 Offstage
里，用户切一下标签就看不到「失败了」。故两个 `_Banner` 放在所有 Offstage
外面（ListView 顶层）。

#### 托盘与路由守卫的两个对称坑

「同步设置…」与「设置…」现在都指向 `/settings`，只差 `tab` 参数。两个托盘
守卫**都不能只比 path**：

- `_openSyncSettings`：已在同步标签时重复 `go()` 会重建页面、清掉用户填到
  一半的草稿 → 比 path + `tab == 'sync'` 才跳过；
- `_openSettings`：只比 path 会把「已在同步标签」当成「已在设置页」，把
  「设置…」变成死按钮 → 比 path + `tab != 'sync'` 才跳过。

两个方向各有 `desktop_integration_test.dart` 用例钉住（含反向：从通用标签
触发必须真的导航）。

#### 移动端

移动端本就没有独立的同步路由（`/settings/sync` 只在桌面端可达），设置页
底部标签栏新增「同步」标签（`SpbRoutes.settings` 不带参数时落在首个标签，
与桌面端一致）。两端 `SettingsPage` 的接线由 `check_wiring_parity.sh` 守住
（`SyncPage` 条目已从守卫移除，`SettingsPage` 的豁免清单保持不变）。

#### 测试要点（踩过的坑）

- **设置页是长 ListView**：默认 800×600 窗口下，同步标签末尾的区块（本地
  清理 / 同步执行）屏外不构建，`tap()` 会静默未命中（不报错！）——表现为
  「草稿没变、保存按钮不出现」。要么用 `1000×2400` 高窗口，要么
  `tester.ensureVisible` 后再 tap。
- **断言 offstage 分离用 `findsNothing`**：通用标签断言
  `settings-pick-directory` 不存在、同步标签断言 `settings-sign-out` 不存在，
  防止将来有人把两标签内容合并。
- **通用标签的内容锚点**：账号区（`settings-sign-out`）只在注入
  `onSignOut` 时渲染、同步执行区块只在注入 `runSync` 时渲染——测试锚点
  要么注入桩，要么换常驻锚点（标签条本身）。
- **features 层新增「两个标签」group**（5 条：默认落点 / 内容不重叠 /
  `initialTab=sync` 首屏 / 切标签不销毁草稿 / 错误提示跨标签可见），
  路由层用例只管接线。

#### 有意不做

- **不做嵌套路由 / `StatefulShellRoute`**：两个标签共享同一份草稿状态与
  AppBar 保存按钮，拆成子路由会把状态管理劈到两处；query 参数足以表达。
- **不保留 `/settings/sync` 为独立页面**：重定向一步到位，不设过渡期。
- **不在移动端加独立的「同步」底部 tab 之外的入口**：与桌面端 AppBar 设置
  图标的既有豁免同一取向（见 [§6.17](testing.md)）。

#### 反向验证（逐条实测）

| 改坏 | 失败用例 |
|---|---|
| `hasUnsavedChanges: _dirty` 改成 `false` | router_settings「换目录后未保存时禁用立即同步」 |
| `pickDirectory` 改回就地闭包（绕过 provider） | 「选择目录后保存…」（harness override 失效） |
| `_openSettings` 只比 path | 「已在同步标签时点设置…」 |
| `_openSyncSettings` 只比 path（守卫过宽） | 「已在通用标签时触发交付物同步…」 |
| 提示 banner 挪回某个 Offstage 里 | 「错误与「已保存」提示不属于任何标签」 |
| 删掉旧路径重定向 | 「旧 /settings/sync 重定向到同步标签」（两端各 1） |
| 同步标签改回「不在该标签时从树上摘掉」 | 「切标签不销毁草稿」 |
| 把「重复触发不导航」当需求写进用例 | —（**已删**：go_router 对相同 location 不重建，断言恒绿） |

### 交付物同步的既有语义（迁移自 Tauri，**必须保持**）

- **单向**：UFS → 本地
- **增量**：`updated_since` 游标 + etag
- **感知远端删除**：只看 `deleted_at`，**不能凭条目缺席推断**
- **原子写入**：`.part` + rename
- **路径穿越防御**
- **失败项不写状态**（下轮重试）
- **「全部 group」与「选中若干」共用同一状态键 `__workspace__`**（布局相同），切换范围不会全量重拉；**换目录才重置状态**
- **选中模式只发一次全 workspace 清单**再本地过滤——单游标模型下多请求会让游标上界较低的 group **永久漏更新**
- 媒体默认不同步；跳过 `reports/tts/**`

详见 `super_partyb/apps/desktop/README.md`。
