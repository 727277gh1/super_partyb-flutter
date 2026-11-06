# 内存审计（全仓排查）

> 本文档是「排查所有代码中内存相关内容」的**权威对账单**：逐条列出内存持有点、
> 有界性判定与处置结论。后续修复任务以本表为准；修复完成后由 AGENTS.md 新节
> 回链本表（见 AGENTS.md §6.59）。
>
> 排查范围：`packages/*`（core / models / api / domain / data / design / ui /
> platform / features）+ `apps/spb_desktop/lib` + `apps/spb_mobile/lib`。
> 排查方法：全文 grep 内存持有模式（Map/Set/List 字段、缓存字段、`Image.*`、
> `imageCache`、`Uint8List`、Stream/Timer 生命周期），再逐条读码核实有界性。
> 排查日期：2026-11-05（HEAD `9d3a5db`）。
>
> ⚠️ 边界：本机无 `DISPLAY` 无真机（AGENTS.md §9），**没有做过绝对 RSS
> profile**。「无界」是读码确认的结构事实，「实际增长速率与用户可感知影响」
> 未量化。第三方包（gpt_markdown / drift / dio）内部缓存不在本仓库可核实范围。

---

## 一、已有界（核实通过，不动）

这些机制**已有明确上界与清理时机**，本清单钉住它们的存在，防止后续任务误改。

### 数据层（spb_domain / spb_core / spb_data）

| # | 机制 | 上界 / 清理时机 | 位置 |
|---|---|---|---|
| A1 | 事件缓冲区 `maxBufferEvents`，`_trimBuffer()` 按整轮裁剪 + 紧邻增量合并 `_coalesceIntoTail`（2600 token 回复占 1 槽位） | 2000 条 | `packages/spb_domain/lib/src/chat_stream_controller.dart:142`、`:1207`、`:1109` |
| A2 | 归约结果缓存 `_cachedReduction` + 脏标记（单份缓存，非累积） | O(1) 份 | `chat_stream_controller.dart:388` 附近 |
| A3 | `switchGroup` / `dispose` 清空缓冲、activities、gate 决策、usage、`_staleTimers`、11 个 StreamController | 切对话即清 | `chat_stream_controller.dart:767` 附近、`:1769` 附近 |
| A4 | 离线 timeline 缓存三层上限（每 group 条数 / 单 payload / 全库字节，LRU 淘汰） | 2000 条 / 64KB / 64MB | `packages/spb_data/lib/src/timeline_cache_store.dart:20`–`:22`、`:172` |
| A5 | group 列表缓存整表替换（先删后插，无残留行） | 每用户一份 | `packages/spb_data/lib/src/group_cache_store.dart:64`–`:73` |
| A6 | 同步状态 `SyncStateStore.save` 同事务整体替换 | 每状态键一份 | `packages/spb_data/lib/src/sync_state_store.dart:50` 附近 |
| A7 | outbox 重试上限后转 `failed` 终态（failed 行保留属产品语义，条数=用户失败消息数） | `maxAttempts = 10` | `packages/spb_domain/lib/src/outbox.dart:28` |
| A8 | 诊断日志环形缓冲 | 500 条 | `packages/spb_core/lib/src/logger.dart:139` |
| A9 | 文件日志轮转（先删 `.maxFiles` 再后移，写前 `redactSecrets`） | 2MB × 3 份 | `packages/spb_core/lib/src/log_file_sink.dart:46`–`:47`、`:125`、`:140` |
| A10 | 文本预览上限（超限截断，不持有全文） | 200×1024 字符 | `packages/spb_domain/lib/src/file_preview.dart:112` |
| A11 | 上传走磁盘路径（MultipartFile from path），大文件不在内存里双份 | — | `packages/spb_api/lib/src/chat_api.dart:679` 附近、`packages/spb_features/lib/src/quick_capture/overlay_quick_capture_page.dart:212` 附近 |

### UI 层（spb_features / apps 两端）

| # | 机制 | 上界 / 清理时机 | 位置 |
|---|---|---|---|
| A12 | 气泡 widget 缓存 `_bubbleCache`（超限丢弃前半量） | 200 条 | `packages/spb_features/lib/src/chat/conversation_page.dart:685`、`:2207` |
| A13 | keep-alive 有界（尾部窗口 × 长度阈值） | 12 条 × ≥400 字符 | `conversation_page.dart:601`、`:617` |
| A14 | 缩略图 Future 记忆 `_thumbnailMemo` | 切对话清空 | `conversation_page.dart:764`、`:1142` |
| A15 | 展示行缓存 `_displayRows`（`identical` 判据，单份） | O(1) 份 | `conversation_page.dart:2000` 附近 |
| A16 | `RowLocateRegistry` 键注册 + `recycle(liveIds)` 回收（不许 `clear()`，§6.18） | 只留当前时间线的行 | `packages/spb_features/lib/src/chat/row_locate_registry.dart:60`、`:126` |
| A17 | `ToolCallTile._hasFailed` 派生量缓存（单份 bool） | O(1) | `packages/spb_features/lib/src/chat/tool_call_tile.dart:58` |
| A18 | 桌面端文件通知去重 `_seenFileItemIds` | 切对话重置 | `apps/spb_desktop/lib/router.dart:918`、`:1438` |
| A19 | 移动端「动态」弹层刷新哨兵 `_activityTick` | 弹层关闭即 `dispose` + 置 null | `apps/spb_mobile/lib/router.dart:1652`、`:1689` |
| A20 | 帧耗时批次（只统计不持久，超限 flush） | 120 帧 / 5s | `packages/spb_platform/lib/src/frame_timing.dart:172`–`:173` |
| A21 | 内存采样环形缓冲 `MemoryProbe._samples`（每 60s 一条，**不写日志**） | 12 条 | `packages/spb_platform/lib/src/memory_probe.dart` |
| A22 | `data:` URL 解码缓存 `_dataUrlMemo`（接管 `imageBuilder` 后补的、与插件同级的那份） | 32 条 / 32MB（LRU） | `packages/spb_features/lib/src/chat/markdown_image.dart` |

---

## 二、无界待修（本轮修复，映射到任务）

| # | 问题 | 证据（file:line） | 影响 | 处置 → 任务 |
|---|---|---|---|---|
| G1a | `ConfirmationNotifier._notifiedIds` 无界：桌面端是常驻进程，每个出现过的确认卡 id 永久驻留 | `packages/spb_domain/lib/src/confirmation_notifier.dart:81` | 长会话缓慢累积（每条一个 id 字符串，量级小但无界） | **加宽松容量上限**（淘汰最旧）→ tmw2jseq43 |
| G1b | `ConfirmationNotifier.reset()` **零生产调用方**：文档写明「切用户 / 退出登录时调用」，但两端 `signOut()` 均未接 | `confirmation_notifier.dart:188`（`reset()` 定义）；`apps/spb_desktop/lib/providers.dart:609`、`apps/spb_mobile/lib/providers.dart:592`（`signOut` 无调用） | 换用户后旧权限缓存沿用（「上次被拒」永久静默）+ 集合永不释放 | **两端 signOut 接线 reset()** → tmw2jseq43。⚠️ 只许接登出/切用户时机，不得接页面重建（否则 SSE 回放重复弹通知，providers.dart:74 文档已警告） |
| G2 | `GroupSyncThrottle._lastTriggered` 每 group 一条 `DateTime`，无淘汰；provider 非 autoDispose（有意，保持） | `packages/spb_domain/lib/src/group_sync_probe.dart:260`；`apps/spb_desktop/lib/providers.dart:1502` 附近 | 长会话访问大量 group 后累积（每条几十字节，增长慢但无界） | **加容量上限**（淘汰最旧；被淘汰条目 `allows` 恒 true，语义安全）→ tmw2jseq44 |
| G3 | 两端 router 共 **4 处** group 标题缓存 `_titles` 无界（`containsKey` 只增不删，页面 State 存续期内累积） | `apps/spb_desktop/lib/router.dart:447`、`:582`；`apps/spb_mobile/lib/router.dart:405`、`:547` | 单页驻留时长内无界（每条一个 gid→title） | **抽共享有界 GroupTitleCache**（淘汰最旧；淘汰只导致下次重新拉取标题，无行为风险）→ tmw2jseq45 |
| G4a | `Image.memory(Uint8List.fromList(_thumbnail!))`：每次 build **全量拷贝**一份缩略图字节 | `packages/spb_features/lib/src/chat/agent_file_card.dart:299` | 每帧重建路径反复拷贝（垃圾，推高峰值） | **持单份 Uint8List 字段，去拷贝** → tmw2jseq42 |
| G4b | 图片解码无降采样：全仓 `cacheWidth`/`cacheHeight`/`ResizeImage` **零命中**，`Image.memory` 按原始分辨率解码（预览大图 4000×3000 = ~48MB/张） | `packages/spb_features/lib/src/chat/agent_file_preview.dart:500`（预览原图）、`agent_file_card.dart:299`（缩略图）、`packages/spb_features/lib/src/settings/user_preferences_card.dart:942`（头像） | **100→300MB 水位的主要来源**：解码位图进全局 imageCache，默认上限内不淘汰 | **加 cacheWidth（按显示尺寸）+ 全局 imageCache 显式上限** → tmw2jseq42 |
| G5 | `SyncStateStore.save` 在事务里**逐条 await** `insertOnConflictUpdate`（5666 文件全量替换 = N 次往返） | `packages/spb_data/lib/src/sync_state_store.dart:67`–`:71` | CPU/IO 成本（非泄漏）；同仓先例 `DriftTimelineCacheStore.save` 已用 batch（`timeline_cache_store.dart:134`） | **改 batch 写入**（同事务、upsert、StorageError 包装均不变）→ tmw2jseq46 |

> 处置映射：tmw2jseq42 = G4a+G4b；tmw2jseq43 = G1a+G1b；tmw2jseq44 = G2；
> tmw2jseq45 = G3；tmw2jseq46 = G5。

---

## 三、有意保留（有实测取舍依据，本轮不动）

这些项**看着像问题但已有文档化的设计决策**（用内存换流畅/正确性），有测试
钉住；改动它们需要 profile 证据支持，否则就是回归。

| # | 项 | 成本（文档口径） | 为什么不动 | 依据 |
|---|---|---|---|---|
| K1 | 桌面侧边栏 `Offstage` 常驻（`_sidebarEverShown` 惰性守卫） | ~130KB 固定 + 已加载交付物清单（5666 文件约 2.6MB） | 换「再展开零延迟、零请求、滚动位置保留」；`RenderOffstage` 实测收起时释放 0 elements | AGENTS.md §6.46（`apps/spb_desktop/lib/router.dart:745`、`:1835`） |
| K2 | `scrollCacheExtent = viewport(1.5)`（+ `addRepaintBoundaries: false`，§6.51） | 同时挂载行数变多 | 换掉「帧内 Markdown 冷解析」（实测合计帧时 326.9→240.7ms）；§6.51 的整行绘制缓存移除是规避设备故障的局部规避，**待故障设备复核** | AGENTS.md §6.47 / §6.51（`conversation_page.dart:2060`、`:2090`） |
| K3 | `maxBufferEvents = 2000` / `_keepAliveWindow = 12` / `_bubbleCacheLimit = 200` | 时间线数据 + 解析缓存常驻 | 三者都经实测校准（归约 2000 条 1767µs；短回复不值得常驻），有测试钉住契约 | AGENTS.md §6.47 / §6.48 |
| K4 | `GroupListPage._groups` 无条数上限（offset 分页累积，仅 refresh 清空；另有 `_seenIds` 同步无界） | 每条一个 group 对象 | 列表语义=用户 group 总数；清空会丢「已加载的分页」，需重拉 | AGENTS.md §6.10（`packages/spb_features/lib/src/chat/group_list_page.dart:223`、`:466`） |
| K5 | `Agenda`/目标历史等面板 State（`IndexedStack` 已激活 tab 常驻挂载） | 数面板份的 State 与已加载数据 | 同 K1 的取向（切 tab 不销毁，issue #16），载体本身是设计 | AGENTS.md §6.46 |
| K6 | 移动端深链/弹层等 `ValueNotifier` 生命周期 | 已在关闭时 dispose | 已核实无泄漏（A19），列出仅作对照 | A19 |

> 若将来要在真机上 profile 并推翻 K1–K3，需要先拿到 `SPB_FRAME_TIMING=true`
> 的慢帧数据（AGENTS.md §6.47 的观测手段），并在 AGENTS.md 重新论证取舍。

---

## 四、观测手段（既有，验证时复用）

| 手段 | 位置 | 用途 |
|---|---|---|
| `PerfProbe` 静态计数器（`visitedItems` / `displayRowsComputations` / `followBottomCalls` / `assistantBubbleBuilds`） | `packages/spb_features/lib/src/chat/perf_probe.dart:32` | 测试断言结构事实（重建次数 / 扫描预算） |
| `RowLocateRegistry.length` / `bufferedEventCount` / `notifiedCount` | `row_locate_registry.dart:72`、`chat_stream_controller.dart:310` 附近、`confirmation_notifier.dart:87` 附近 | 测试钩子：断言回收/清理生效 |
| `SPB_FRAME_TIMING=true` 编译期开关 | `packages/spb_core/lib/src/env.dart:120` | 真机慢帧统计进诊断报告（本机不可用） |
| 「导出诊断日志」链路（环形缓冲 + `redactSecrets`） | `packages/spb_core/lib/src/logger.dart:251` 附近、`:344` 附近 | 用户侧取证 |
| **`MemoryProbe` 内存采样**（RSS / OS 高水位 / imageCache 字节与张数与 live） | `packages/spb_platform/lib/src/memory_probe.dart`；两端 `main.dart` 接线；报告小节见 `buildDiagnosticsReport(memory:)` | **真实用户机器上的绝对内存曲线**：每 60s 一条进 12 槽环形缓冲，导出报告时带出（release 可用，不依赖 DevTools / VM service） |
| **`MemoryLedger` 内存账本**（具名读数：时间线 / 缩略图 / 气泡缓存 / 交付物清单） | `packages/spb_core/lib/src/memory_ledger.dart`；持有方（`conversation_page.dart` / `group_deliverables_panel.dart`）在 `initState` 登记、`dispose` 注销 | **回答「花在谁身上」**：曲线只能说「占了多少」，分解行才能区分引擎基线 / 图片 / 时间线 / 清单。登记必须成对，否则观测本身成了泄漏（页面测试钉住注销） |
| **`MemoryWatchdog` 高水位日志**（边沿触发 + 30 分钟冷却，带账本分解） | `packages/spb_platform/lib/src/memory_watchdog.dart`；两端 `main.dart` 接线 | **用户不导出报告时也有证据**：imageCache ≥ 24MB / RSS 增量 ≥ 256MB / 任一账本项越线时写一条 `warn`，带 `breakdown` 与 `!` 越线标记 |

### 绝对内存曲线：从 既有问题 降级为「只能远程采集」

旧版本把这一项列为 既有问题，理由是 DevTools 需要桌面环境与 profile
模式。**现已被 [MemoryProbe] 绕过**：
`ProcessInfo.currentRss` / `maxRss` 是 `dart:io` 的进程级读数，release 包里
也能拿（Windows 由运行时经 `GetProcessMemoryInfo` 提供），因此曲线由**用户
机器**产出、而不是由开发机 profile。

仍未闭合的两维（本模块拿不到，需要真机 + DevTools）：

- **Dart heap 分解**（按类、external、GC 时机）——只能 DevTools Memory view；
- **GPU / ANGLE 侧**占用（flutter/flutter#179834：Windows 上图片操作的增量
  主要来自 ANGLE 保留，独显比核显水位更低）——不在 RSS 的同一行里，
  也不在本仓库可改范围。

⚠️ 读采样时的两条前提（本仓库改不到，但会误判）：RSS **不会回落到基线**
（Dart GC 在「堆大小看起来合适」时不回收，而桌面端没有 OS 低内存信号），
故只看**峰值（`peak=`）与斜率**，不看是否回落。

---

## 六、第二轮排查（2026-11，含已修 5 项 + 待议 4 项）

第一轮（一~五节）收口于「结构上任意增长」的容器。第二轮换了一条判据：**峰值
与主线程占用**——不是「会不会无界」，而是「一次操作瞬时占多少」。大文件同步
（4.7 GB 全量，单文件上限内可达 100 MB）与长正文滚动的瞬时峰值都在这一层。

### 6.1 已修（本轮）

| # | 问题 | 证据（file:line） | 影响 | 处置 |
|---|---|---|---|---|
| G6 | `contentHashOf` 在**主线程**对下载/上传的整份字节算 SHA256（`List<int>` 已全部驻留内存后同步计算） | `packages/spb_domain/lib/src/sync_state.dart`（`contentHashOf` / 新增 `contentHashOfAsync`）；调用点 `deliverable_sync.dart`（下载后判重）、`deliverable_upload.dart`（上传前比对 baseline） | 单个 100 MB 文件 = 主线程冻结约数百毫秒（帧预算 16.7 ms）；同步首轮会连续命中 | **新增 `contentHashOfAsync`**：> 8 KB 走 `Isolate.run` + `TransferableTypedData`（worker 侧拿外部缓冲视图，不额外占 worker 的 Dart 堆；⚠️ `fromList` 自身会拷贝一次——实测确认，非所有权移交），≤ 8 KB 仍走同步路径（isolate 启动成本更高）。同步版 `contentHashOf` 保留（测试与小数据与异步版的回退路径） |
| G7 | 交付物面板用 `ListView(children: _tree.map(...))`：build 阶段一次性构造**全部**节点 widget | `packages/spb_features/lib/src/chat/group_deliverables_panel.dart`（`_rows` getter + `ListView.builder`） | 5666 文件全量同步后，打开「交付物」tab 的一帧构造 5666 个 widget（目录节点是 `ExpansionTile`：StatefulWidget + controller），绝大部分滚出视口即丢弃；且每次 SSE 文件事件 bump `reloadToken` 都会重来一遍 | **flatten + `ListView.builder`**：可见行由「展开中的目录」递归派生（`_rows`），折叠的子树**不进行集合**（真正的懒，而非仅视觉隐藏）；展开状态由面板自持（`_userExpansion`，只记用户点过的目录）；缓存按 `(_tree identity, 展开修订号)` 双判据失效。行为对齐：顶层默认展开 / 深层默认折叠 / 点击折叠展开 / 同对话刷新保留 / 切对话重置 |
| G10 | `GptMarkdown` 的 `imageBuilder` **未传**：Markdown 图片走插件默认 builder（`Image(image: NetworkImage(url))`），绕过 `cacheWidth` 降采样 | `packages/spb_features/lib/src/chat/assistant_message_bubble.dart`（`GptMarkdown(...)`）；插件 1.3.4 `shared_render.dart` 的 `imageSpan` 默认分支 | 一张 4000×3000 的截图 ≈ 48MB 位图进 imageCache，而它在气泡里最多 1024dp 宽 | **新增 `markdownImageBuilder`**（`spb_features/lib/src/chat/markdown_image.dart`）：`ResizeImage` 按「声明宽或视口宽 × DPR」封顶 `kImageDecodeCeilingLogicalWidth`（1024dp）；复刻默认实现的尺寸盒子 / `BoxFit.fill` / loading+error 占位；`data:` URL 补一份 32 条/32MB 的字节 LRU（插件那份是私有的，接管 builder 就等于接管了这条路径） |
| G9 | 全仓 `didHaveMemoryPressure` **零命中**：系统内存压力信号没有任何接收方 | `packages/spb_platform/lib/src/memory_pressure.dart`（新增）；两端 `main.dart` 接线 | 移动端是最需要这条信号的端（内存最紧张），收到压力时什么都不做，直到被系统杀掉 | **新增 `installMemoryPressureHandler`**：`WidgetsBindingObserver.didHaveMemoryPressure` → `imageCache.clear()` + `imageCache.clearLiveImages()` + app 层 `onRelease`。⚠️ 实测确认框架的 `RendererBinding.handleMemoryPressure()` **已经** `clear()`，但**不**清 live images（还有 listener 的图，例如正显示的预览大图）——`clearLiveImages()` 才是本模块独有的增量。故测试必须钉住 `liveImageCount`，只钉 `currentSize` 会是假绿 |
| G8 | 会话页 `_thumbnailMemo` **无界**；键只有 `ufsFileId`，同路径新版本覆盖（id 不变、内容变）时不失效 | `packages/spb_features/lib/src/chat/conversation_page.dart`（缓存）；`agent_file_card.dart`（重拉判据） | 桌面端主窗口常驻，单对话滚过上千张图即累计数十 MB；覆盖写后旧缩略图一直显示到切对话 | **抽出 `ThumbnailMemo`**（`spb_features/lib/src/chat/thumbnail_memo.dart`）：条目数/字节数双上限（512 / 16MB，淘汰最旧写入）+ **版本令牌** `AgentFileItem.contentRevision`（`action`/`modifiedAt`/`deletedAt`/`sizeBytes`/`mimeType`）——令牌变了就逐出重拉，不依赖服务端带 mtime；删除事件按 id 逐出。**上限是安全上界不是实测最优值**，真机峰值由 `conversation.thumbnails` 账本读数回收后再校准（issue #70） |

### 6.2 待议（有证据，但需要产品取舍或真机数据）

| # | 项 | 证据（file:line） | 为什么这轮不动 | 已登记 issue |
|---|---|---|---|
| J1 | `isStreaming` 翻转导致气泡**整棵 remount**：`child: isStreaming ? md : SelectionArea(child: md)`，`SelectionArea` 引入/移除使子树换父节点，`gpt_markdown` 的增量解析状态全丢 | `assistant_message_bubble.dart`（同处） | 影响是「回复完成瞬间」的一次重解析（不是持续卡顿）。修法要么常驻 `SelectionArea`（流式期间可选文本的语义变化），要么给 `md` 加 `GlobalKey` 保 Element——两者都有取舍，需产品确认「流式期间是否允许选中文本」 #72 |
| J2 | `FileLogSink` 每条日志**同步写盘**（`writeAsBytesSync`，§6.57 有意如此） | `packages/spb_core/lib/src/log_file_sink.dart` | 这是 §6.57 明确记录的取舍：异步缓冲会在崩溃时丢最后一段，而「崩溃后仍能读到」正是该 sink 存在的唯一理由。真要优化应先降日志量，而不是改写法治 #73 |
| J3 | 流式 fade 逐字动画（`charactersPerSecond: 600`） | `assistant_message_bubble.dart`（`GptMarkdown(animation: fade, ...)`） | 逐字揭示是**产品表达**而非性能缺陷；关掉会让长回复「一坨文字突然出现」。若要控成本，方向是「大回复降级为一次性显示」，须产品决定 #74 |
| J4 | `_followBottom` 的 `animateTo` 在每批事件各重启一次（§6.47 已把**调度**去重为一次，但动画本身仍被打断重来） | `packages/spb_features/lib/src/chat/conversation_page.dart`（`_followBottom`） | 与 §6.47 修的不是同一处：那里修的是「一帧排多个 post-frame 回调」，这里是「动画被新事件打断后从当前位置继续」——实际观感受滚动距离与事件频率影响，需真机确认是否可感知 #75 |
> 6 条待议项曾开 issue 讨论（#70 G8 / #71 G10 / #72 J1 / #73 J2 / #74 J3 / #75 J4），
> 后续进展以 issue 为准，本表不再更新。其中 **G10 与 G8 已修**（G10 的处置依据是
> 插件 1.3.4 源码——不再「猜」默认 builder 是否自带降采样；G8 的处置依据是
> 「版本令牌 + 双上限」，**不依赖**真机峰值——上限只是安全上界，校准靠
> `conversation.thumbnails` 账本读数回收），故待议降为 **4 条**（J1–J4）。
>
> J1–J4 是**卡顿**方向。四类的共同前提是：
> 本机无 `DISPLAY`、无真机（AGENTS.md §9），拿不到 `SPB_FRAME_TIMING` 的慢帧
> 数据——**没有实测数据就调参，是把 K1–K3 那类已论证的取舍推翻重来**。

### 6.3 与 §三（有意保留）的边界

G7 与 K1 **不冲突**：K1 说的是「侧边栏收起时不销毁子树」（保留已加载数据与
滚动位置，用 ~130KB + 清单换零延迟），G7 说的是「子树里的列表本身要懒构建」
（用 `ListView.builder` 少构造几千个 widget）。两者叠加才是目标状态：数据留着、
widget 按需建。

---

## 五、结论摘要

- 第一轮：结构上无界的点共 **7 条**（G1a/G1b/G2/G3/G4a/G4b/G5），全部映射到
  任务 tmw2jseq42–tmw2jseq46，**均已修复**；
- 第一轮：已有界且核实通过 **20 条**（A1–A20），无需改动；
- 第一轮：有意保留 **6 条**（K1–K6），均有 AGENTS.md 实测依据，本轮明确不动。
- 第二轮（峰值/主线程口径）：已修 **5 条**（G6 哈希 isolate / G7 树 builder /
  G8 缩略图有界+版本令牌 / G9 内存压力 / G10 Markdown 图片降采样），待议
  **4 条**（J1–J4）均仍**缺少真机或产品取舍依据**，不以猜测改动（#72–#75
  开着；#70 G8 与 #71 G10 已结）。
