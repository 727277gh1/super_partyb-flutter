# 性能与内存

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。流式对话的观测手段与已确认成本项、内存审计（无界集合加界 / 解码降采样 /
batch 写入）、第二轮峰值优化（哈希下放 isolate / 交付物树懒构建 / 内存压力接线）。

> 编号（`§6.x` / `§5.x` / `[§7](build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](README.md)。

---

### 6.47 流式对话性能：观测手段与已确认的成本项（2026-10）

一次「滚动不顺 / 流式期间卡顿」的排查收口。本节记**怎么观测**、**哪些成本是
实测确认的**、**哪些已经修掉以及判据是什么**，以及**哪些看着像问题但有意不动**。

> ⚠️ **所有数字都是 build/layout 成本测量，不是真机帧率**。本机无 `DISPLAY`、
> 无真机（[§9](../development.md)），跑不出 vsync 对齐的真实帧时间。数字来自「强制重建一次 /
> 执行一次纯函数，用 `Stopwatch` 取 10 次中位数，再减去 `Text('x')` 控制组
> 基线」。它们足以比较**相对量级**（谁比谁贵 10 倍），不足以判断「这一帧
> 会不会掉」——那个只能真机 profiling。

#### 一、怎么观测

| 手段 | 位置 | 何时用 |
|---|---|---|
| `SPB_FRAME_TIMING` dart-define | `SpbEnv.frameTiming`（`spb_core/lib/src/env.dart`）→ 两端 `main.dart` 的 `installFrameTimingReporter()` | 真机/有桌面环境时看真实帧耗时 |
| `PerfProbe` 计数器 | `spb_features/lib/src/chat/perf_probe.dart` | 测试里断言**结构事实**（重建了几次、扫了几遍） |

**帧耗时默认关闭**（`bool.fromEnvironment('SPB_FRAME_TIMING', defaultValue: false)`）。
`SchedulerBinding.addTimingsCallback` 每帧回传数据并累积 `List<FrameTiming>`
——不是免费操作，只在排障时需要。与 `SpbEnv.verboseLogging` 同取向。

上报策略（`frame_timing.dart`）：满 `batchSize`（120 帧）或 `flushInterval`
（5s）**先到者**触发一次汇总。按批次而非每帧——60fps 下每帧一条 = 每秒 60 条，
8 秒冲干净 500 条环形缓冲（[§6.20](runtime-and-ops.md)），而诊断报告要的是**出事前后**的上下文。
慢帧阈值默认 **32 ms** 而非 16.7 ms：后者会把「偶尔掉一帧」也算进来，32 ms
≈ 明显掉到 30fps 以下，是用户真能感知的卡顿。

**测试侧一律用 `PerfProbe` 计数器，不写毫秒断言**：毫秒随机器、debug/release、
并发负载漂移，写进断言就是 flaky。计数器给的是与机器无关的结构事实（一次
build 扫了多少条 item、展示行缓存是否命中、几个气泡真的重建了）。

#### 二、实测成本表（2026-10，本机，debug）

| 项 | 数字 | 说明 |
|---|---|---|
| `GptMarkdown` **冷重建** | 4 段/580 字符 **68.0 ms**；20 段/2940 **202.5 ms**；60 段/8900 **441.6 ms** | 强制换 key（Element 全销毁） |
| `GptMarkdown` **暖重建** | 20 段 **16.9 ms**；60 段 **30.3 ms** | Element 复用（`didUpdateWidget` 短路） |
| 2000 items 的展示行分组 | **0.26 ms/次**（`groupFileEventsForDisplay`） | 纯函数 |
| 2000 items 的定位 id 收集 | **0.18 ms/次**（`locateIdsOfAll`） | 纯函数 |
| `_looksLikeError` | 10 KB **0.195 ms**；108 KB **0.407 ms**；1 MB **4.277 ms** | 内部 `toLowerCase()` 是全量拷贝 |
| `JsonEncoder.withIndent('  ').convert` | **4.7 µs/次** | 可忽略（但见下方「有意不做」第 3 条） |
| 缩略图请求（修复前） | 1 张卡 + 3 条**无关**流式增量 → **1 → 4 次** | 每次 build 重拉 |

**冷/暖差 4–15×** 是已测得的一项滚动成本：`ListView.builder` 的子项滚出
`cacheExtent` 即 dispose，`gpt_markdown` 的增量解析缓存（`_settled` 前缀）
随之全丢，滚回来要重解析。

#### 三、已修项与判据

| 修了什么 | 判据（回归用例钉住的事实） |
|---|---|
| **build 期线性扫描收敛** | 修复前 `_streamingItem` 被 `_staleTurnItem` / `_canCancelTurn` / `_visibleActivity` 各调一次（每次全量扫）→ 一次 build 扫 3 遍。现在 `build` 里算一次，尾向扫描遇 `turnId != streaming.turnId` 立即 `break`。后续按 items identity 缓存流式项：未变列表的两次重建扫描为 0，新列表扫描一次 |
| **`_displayRows()` 缓存** | 按 `identical(_items, _lastRowsItems)` 缓存 `groupFileEventsForDisplay` + `locateIdsOfAll`（两者看同一份 `rows`，分两次算会多一次全量扫描 + 多一个「两份不一致」的可能）。用例断言 `displayRowsComputations == 1` |
| **`_followBottom` 调度去重** | 一帧内多次推送只排一次 post-frame 回调（修复前每次 `_onItems` 各排一个，后一个动画会取消前一个）。用例断言 `followBottomCalls == 1`（修复前 5） |
| **缩略图请求去重（两层）** | ① 卡片 `didUpdateWidget` 判据从「回调 identity」改为 `file.id` / `ufsFileId` / `isDeleted`——调用方每次 build 现包闭包，identity 判据**恒真**；② 页面层 `_thumbnailMemo` 按 `ufsFileId` 记忆化 `Future<List<int>?>`（缓存 Future 而非已完成值，才能同时去重**并发**请求）。失败也缓存：404/501 通常是永久性的。⚠️ **两层各有独立用例**——只回退卡片判据时页面用例仍绿（memo 兜住） |
| **SSE 行缓冲线性化** | 旧写法 `content = content.substring(idx + 1)` 在含 k 行的分片上是 **O(k·L)**（每行把剩下大半串再拷一遍）。现在偏移游标 + `indexOf('\n', start)`，每行一次定长切片 + 末尾一次半行切片。⚠️ `indexOf` **必须带 `start`**，不带就退化回 O(k·L) |
| **Markdown 气泡常驻有界化** | 见下节 |
| **未变气泡不重建** | 见下节 |

#### 四、keep-alive：为什么必须**有界**

`AssistantMessageBubble` 改成 `StatefulWidget` + `AutomaticKeepAliveClientMixin`，
由页面按「**尾部窗口 12 条 × 正文 ≥ 400 字符**」有界常驻
（`_keepAliveMinChars` / `_keepAliveWindow`）。

| 参数 | 值 | 为什么 |
|---|---|---|
| `_keepAliveMinChars` | **400** | 短回复解析 < 1 ms，不值得付常驻成本 |
| `_keepAliveWindow` | **12** | 取「最近的」而非「最长的」：用户动作是往下读 → 往回翻一点 |

**不能无界**：`AutomaticKeepAliveClientMixin` 让子项留在树上，代价是
**Element / State / RenderObject 与 `GptMarkdown` 的解析缓存常驻内存**（后者
才是重点：增量解析的分段与已定型缓存活在该 State 里，dispose 即全丢）。
2000 条历史全常驻 = 2000 份解析结果与子树常驻。

⚠️ **不要写成「每帧仍要布局」**（曾这么写过，SDK 核实为否）：SDK 在子项离开
视口时把它从 childList 移除、放进 keep-alive 桶（`sliver_multi_box_adaptor.dart`），
而 `RenderSliverList.performLayout` 沿 `firstChild` 链遍历、
`RenderSliverMultiBoxAdaptor.paint` 也只走 `firstChild`——故**不在每帧的
布局/绘制路径上**。`visitChildren` 包含该桶，`visitChildrenForSemantics`
显式跳过。真实代价是「滚回可见时仍需一次 layout」（脱离桶重新入列）+ 常驻内存。

⚠️ **两个实测踩出来的坑**（都已写进代码注释）：

1. **mixin 的 `build` 只申请、永不释放**（只有 `updateKeepAlive()` /
   `deactivate()` 释放，而 keep-alive 生效后不会被移出树）→ 曾进过窗口的气泡
   **永久常驻**（实测 20 条长回复滚到顶部时 `mounted=20`）。故
   `didUpdateWidget` 里必须 `if (oldWidget.keepAlive != widget.keepAlive) updateKeepAlive();`。
2. **`find.textContaining` 测不出 Markdown 气泡**：`GptMarkdown` 把一段
   Markdown 渲染成**多个** `RichText`，跨段字符串拼不回来。测试改用
   `tester.widgetList<AssistantMessageBubble>()` 看 `text` 字段。

#### 五、流式期间未变气泡不重建：**先测后改**的决策记录

`SliverChildBuilderDelegate.shouldRebuild` **恒为 true**，故父级每一次
`setState` 都会重建**全部已挂载行**。而本页 `setState` 的来源里，流式增量 /
`turn_activity` 心跳 / `ttsStatus` / `_staleTurnIds` / outbox / pending 中
**大部分与「历史气泡的内容」无关**。

**先测**（用例「流式增量只重建变化的那条气泡，其余不动」，5 条已完结长气泡 +
1 条流式气泡，推一条增量）：

```
[perf] 一条流式增量后 assistantBubbleBuilds = 6（共 6 条气泡，其中 5 条内容未变）
[perf] 一条 turn_activity 心跳后 assistantBubbleBuilds = 6
```

增量 6 ≫ 1 → **实施**（任务书允许「以数据结论收口」，这里数据支持改动）。

**做法**：`_bubbleCache`（`item.id` → (指纹, widget 实例)），命中时交回**同一
实例**——`Element.updateChild` 的 `child.widget == newWidget` 分支命中
（`Widget` 未覆写 `==`，故即 `identical`），子树连 `build` 都不跑。

| 决定 | 理由 |
|---|---|
| **只缓存 `AssistantMessageItem`** | 它的渲染输入只有 3 个显式字段（`text` / `isStreaming` / `keepAlive`），指纹可穷举。其余 item 夹带页面状态（`ConfirmationItem` 读 `_resolving`、`FeedbackRequestItem` 读 `_submittedFeedback` 与 `_feedbackTTL`、`ErrorItem` 读 `_retryingTurnId`），逐项列必然漏一处，而漏掉的表现是「状态变了界面不变」 |
| 指纹含 `isStreaming` | 它是 item 字段 **× `_staleTurnIds`**（超时兜底会让 true 变 false），不是 item 自带值 |
| 指纹含 `keepAlive` | 它是 `_keepAliveIds`（窗口滑动时逐条变） |
| 链接走稳定方法入口 | 点击时读取当前回调；两端宿主重建产生的新闭包不让全部气泡缓存失效 |
| **主题/语言/文本缩放不进指纹** | 它们走 `InheritedWidget`；复用同一实例时子树的 `dependOnInheritedWidgetOfExactType` 依赖关系仍在，框架会自己标记重建 |
| `_bubbleCacheLimit = 200`，简单逐出（非 LRU） | 缓存只为「刚看过的那些」服务；维护「最近使用」要在命中路径上搬动元素，而命中路径正是要压到最便宜的那条 |
| 切对话时 `_bubbleCache.clear()` | `item.id` 是服务端事件 id，跨对话**不保证唯一**；不清可能把 A 对话的气泡交给 B 对话的同 id 项 |

**修复后**：流式增量 `1`、activity 心跳 `0`。**三个变异都被用例捕获**：绕过缓存
→ 6；指纹漏掉 `text` → 0（连该变的都不重建）；指纹漏掉 `keepAlive` → 被
keep-alive 的上界用例抓住。

#### 六、有意不做

| 项 | 为什么不做 |
|---|---|
| ~~**隐藏 / 收起工具调用**~~ | ✅ **已由 [§6.54](ui.md) 取代**（折叠而非隐藏）：连续 ≥5 条工具调用在**展示层**折成一张批卡（`ToolCallBatchRow`），批内含在飞工具时默认展开、跑完自动收起；数据层一条不少，对话内搜索照样命中批内任一成员。本条原结论「折叠态已经零成本、故无需再折」只回答了**单卡内部的**折叠，没回答**时间线上几十张卡**的噪声——那正是用户报障的点 |
| **`itemExtent` / `prototypeItem`** | 行高由 Markdown 内容决定，是**变高列表**，给不出固定 extent |
| **改 Go API 契约** | 客户端适配服务端，不是反过来（仓库硬约束）。任何「为了客户端方便而改 Go API」的提案要先证明无法在客户端解决 |
| **把 `JsonEncoder.convert` 提到 `build()` 顶部** | 看着能「早点拿到字符串」，实际会让折叠态也付转换成本（4.7 µs/次 × 条数）。`children` 是**急切求值**的列表字面量，放进 `ExpansionTile` 的 `children` 里才会随 `shouldRemoveBody` 一起被跳过 |
| **给时间线加 `RepaintBoundary`** | 普通卡片已有独立边界；正文行在 [§6.51](ui.md) 改为直接随视口重绘，避免整条超高回复复用一个绘制层 |

#### 七、已知边界

- **本机无 `DISPLAY`、无真机**：所有数字是 build/layout 成本测量，不是真机
  帧率。`xvfb-run` 下渲染不稳定，**不能**把「窗口出现了」当作渲染正确的证据。
- debug 的 build/layout 耗时不能换算成 Windows release FPS；真实 raster 与掉帧情况仍须在设备上采样。
- 缩略图已按版本令牌失效并设双上限，见 §6.72。
- 历史前插已由双向 Sliver 保持阅读位置，聚合边界变化时用可见行重定原点，见 [§6.85](chat.md)。

#### 八、两处「偶发重帧」的热点（2026-10 补）

第七节曾把 `_looksLikeError` 的 `toLowerCase()` 记为「当前不修」。复核后改判
——它是**纯函数、输入不变、却每次 build 都重算**，正是「偶发重帧」的形态。
同批还把时间线的预建范围从默认 250 **像素** 调成 1.5 屏。

##### 1. `_looksLikeError`：零分配 + 结果缓存

`ToolCallTile` 从 `StatelessWidget` 改成 `StatefulWidget`，只为缓存一个派生量
`_hasFailed`（`isComplete && _looksLikeError(output)`）。

**为什么缓存比「写快一点」更决定**：`output` 在一条工具卡的生命周期里只变一次
（未返回 → 返回），但 `SliverChildBuilderDelegate.shouldRebuild` 恒 true，
父级每次 `setState` 都重建它。缓存把成本从「每次 build」降到「每个 output 一次」。

**同时把 `toLowerCase()` 换成零分配比较**（`_startsWithAscii` / `_containsAscii`
用 `codeUnitAt(i) | 0x20` 做大小写折叠）：

| 输出大小 | 旧（`toLowerCase`） | 新（零分配） |
|---|---|---|
| 10 KB | 0.068 ms | 0.025 ms |
| 100 KB | 0.666 ms | 0.254 ms |
| 1 MB | 6.930 ms | 2.662 ms |

**语义完全不变**（这是刻意的）：前缀类（`error` / `exception`）只看开头，子串类
（`traceback` / `failed`）任意位置——与旧实现逐条对齐，含 `  error:`（前导空格
不算开头）、`tracebac`（少一字符）、中文输出等 14 个样本。

⚠️ **有意不做「只扫前 N KB」**：那会改变语义（1 MB 构建日志末尾的 `BUILD
FAILED` 就漏了），而判错会影响图标颜色。优化必须保持行为，不能靠缩窗口。

⚠️ **测试的两个坑**（都是实测踩出来的）：

1. **`isComplete` 不进 `didUpdateWidget` 判据是假绿**——用例里若 `output` 也
   一起变，`identical` 判据自己就触发重算，即使漏掉 `isComplete` 也照样绿。
   必须**复用同一个 `output` 实例**、只翻 `isComplete`。
2. **`output != null` 时 `isComplete: false` 走的是「完成」分支**（`isRunning`
   的判据是 `output == null`），不是「执行中」。那是既有行为，别在缓存用例里
   误断言。

##### 2. `scrollCacheExtent`：250px → 1.5 屏

`ListView.builder` 的默认预建范围是 **250 像素**，而本时间线的行高差异极大
（一行短消息 40px，一条长回复上千 px）。快速滚动时新行来不及预解析，Markdown
冷解析（实测 4 段 / 580 字符 **68.0 ms**）全压在**帧内**——这正是「多数帧很
轻快、每隔十几帧突然卡一下」的黏连感。

实测（本机 2026-10，debug；60 条 4 段 Markdown 气泡，60 帧 × 150px）：

| `cacheExtent` | 挂载 | 合计 | p90 | 最大 | >16.7ms |
|---|---|---|---|---|---|
| 默认 250px | 2 | 326.9 ms | 16.77 | 20.92 | **6/60** |
| `viewport(1.0)` | 3 | 277.6 ms | 16.75 | 17.91 | **6/60** |
| **`viewport(1.5)`** | **3** | **240.7 ms** | **13.07** | **15.69** | **0/60** |
| `viewport(2.0)` | 4 | 226.8 ms | 13.14 | 16.05 | 0/60 |

取 1.5 而非 2.0：两者超时帧都是 0，但 1.5 挂载更少。用 `viewport(n)` 而不是
固定像素——固定像素在矮屏上预建过多、在高屏上过少。

⚠️ **`cacheExtent` 已 `@Deprecated`**，替代是 `scrollCacheExtent`
（`ScrollCacheExtent` sealed class，SDK 的 `rendering/viewport.dart`）。它
**不在 material 库的导出面**里，故要 `import 'package:flutter/rendering.dart'
show ScrollCacheExtent;`。

⚠️ **这个值只在「单条气泡比视口矮」时有效**：一条气泡就高过视口时，
`cacheExtent` 无论多大都只能预建到相邻的那一条（实测挂载恒为 1 条，四种取值
的 p90 差异全在噪声内）。故调参前先确认场景形态。

⚠️ **守卫只能断言结构事实**（`scrollCacheExtent` 非 null、`style == viewport`、
`value >= 1.0`）：帧耗时毫秒数随机器与 debug/release 漂移，本仓库禁止毫秒断言。
改回固定小像素时没有任何**功能**测试会红——这正是这条结构守卫存在的理由。

#### 九、长对话滚动回归评审（2026-11-10）

报告中的空行有空 `eventId` 引起的 Key 冲突证据，数据未被裁剪；身份和分页修复见
[§6.85](chat.md)。以下独立成本也已通过回归测试确认并修复：

| 根因 | 修复与验证 |
|---|---|
| 自动追底的像素通知再次调用 `animateTo`，连固定目标也每帧重启 | 当前动画完成后读取最新目标；用户上滚立即退出。逐 16ms 推帧时 activity 保持同一实例，150ms 后落底；动画中新增内容仍能追到最新底部 |
| 图片/reveal/窗口缩放改变高度，未必产生像素通知 | 监听时间线自身的 `ScrollMetricsNotification`；窗口缩小 200px 后仍贴底，已上滚阅读时不改变位置 |
| 完成回复时插入 `SelectionArea`，销毁 Markdown 解析 State | 固定 `SelectionArea → SelectionContainer` 父链，只切换禁选状态；解析 State 和已定型段落实例保持不变，完成后可实际选中；恢复流式前清除选区和手柄 |
| 两端宿主每次 SSE 重建生成新的链接闭包，使气泡缓存全部失效；插件缓存 span 还会保留旧回调 | 页面与气泡均通过稳定方法读取当前回调。宿主更换闭包时历史气泡 build 为 0，点击调用新回调，设为 null 后不再执行 |
| 无关状态更新重复扫描所有行、注册 Key、查找流式项 | 派生索引随 items 缓存；列表未变时索引遍历与无流式项扫描均为 0，变更时重新计算 |
| 缩略图加载同步抛错留下无条目的版本键 | 取得 Future 后再替换版本和缓存；失败不破坏旧版本，成功时才失效 |
| data URL 超过全局缓存预算/缓存被释放后，已挂载图片重建又解码 | 图片 State 持有当前 provider；全局缓存清理后重建复用字节，换 URL 或卸载后才重载。两端内存压力回调同时释放全局 data URL 缓存 |

评审还核对了 SSE 合并归约、两端宿主接线、图片降采样、timeline 批量持久化、同步下载/
摘要和日志路径。同步写日志与逐字 fade 保持原有语义；整份下载的内存峰值仍是 §6.73
记录的边界，当前报告同步在途为 0，不能据此解释本次滚动掉帧。上述结构测试不能证明
Windows GPU/raster 的实际改善幅度；交付后需以同一长对话的设备采样复核。

### 6.59 内存审计与处置（2026-11）：无界集合加界 / 图片解码降采样 / batch 写入

本轮目标是「系统排查全仓内存相关内容并优化」。**权威对账单是
`docs/memory-audit.md`**（A1–A20 已有界核实通过 / G1a–G5 本轮修复 / K1–K6
有意保留），本节记录**方法、修复判据与折衷**——细节证据（file:line）以对账单
为准，这里不重复。

#### 方法与边界（先读这个再补充排查）

排查范围：`packages/*`（9 包）+ 两端 `apps/*/lib`。方法：grep 内存持有模式
（`Map`/`Set`/`List` 字段、缓存字段、`Image.*`、`imageCache`、`Uint8List`、
Stream/Timer 生命周期）→ 逐条读码核实有界性。**边界（诚实记录）**：本机无
`DISPLAY` 无真机（[§9](../development.md)），没有做过绝对 RSS profile——「无界」是读码确认的
**结构事实**，增长速率与用户可感知影响未量化；第三方包（gpt_markdown / drift
/ dio）内部缓存不在可核实范围。绝对内存曲线（RSS / Dart heap 分解）需
DevTools + 桌面环境，列为 openQuestion。

#### 五项修复的判据与折衷（每项均有反向验证）

| # | 修复 | 判据与折衷（诚实记录） | 验证 |
|---|---|---|---|
| G4 | **图片解码降采样 + imageCache 显式上限**（`spb_platform` `configureImageCache` / `imageDecodeCeilingFor`；两端 main 接线；缩略图/预览/头像三处 `cacheWidth`；`agent_file_card` 改持单份 `Uint8List` 去 `Uint8List.fromList` 逐帧拷贝） | 上限 32MB（`kImageCacheMaxBytes`）是**收紧**（框架默认 100MB）；预览解码上限 `kImagePreviewDecodeCeilingLogicalWidth = 1024dp` × DPR ≈ 2048px。**折衷**：InteractiveViewer 放大到 8× 时超过解码宽的部分被插值放大（「全屏清晰、极限放大略糊」）；若要高倍仍清晰需分级重解码，独立复杂度不做 | `image_cache_config_test.dart`（默认值/幂等/上限）；`agent_file_card_test` 断言 provider 是按显示尺寸的 `ResizeImage` 且字节实例 identical；**反向验证**：去 cacheWidth → ResizeImage 断言红 |
| G1 | **`ConfirmationNotifier` 判重集合加容 + 登出接线 `reset()`** | `notifiedIdsCapacity = 4096`（`LinkedHashSet` 保插入序，环形淘汰）。**折衷**：极旧卡在长会话被重放且 id 恰被淘汰时理论上重复通知一次——服务端 id 全局唯一 + 回放窗口 ≤500，概率极低；消除它只能换持久化结构，成本不匹配。`reset()` 接在两端 `signOut()`（`logout()` 之后）——**唯一允许时机**，不得接页面重建（否则 SSE 回放重复弹通知） | domain 3 条容量用例 + 两端 router 层「signOut 清空判重集合」（**接线断裂页面测试抓不到**，[§6.17](testing.md) 教训）；**反向验证**：删淘汰分支 → 容量用例红；删 desktop reset → 装配用例红 |
| G2 | **`GroupSyncThrottle` 冷却记录加容**（`maxTrackedGroups = 512`） | 被淘汰条目 `allows` 恒 true——**安全方向**：只多探测不误挡。⚠️ Dart `LinkedHashMap` **重复赋值不移动 key 位置**（与 JS Map 不同），`markTriggered` 因此「先 remove 再插入」维持「最近触发在尾部」，否则刚重触发的老 group 反先被淘汰——有测试钉住防回退 | domain 3 条（超容淘汰最旧 / 重复触发挪尾 / reset 全清）；**反向验证**：删淘汰分支红、删 remove+re-insert 红 |
| G3 | **两端 4 处 `_titles` 改共享有界 `GroupTitleCache`**（`spb_domain`，默认 512；`titleOf`/`contains`/`remember` 与裸 Map 取值语义一致） | 淘汰只导致下次预取重新拉取一次标题，**无行为风险**（miss → 「未知对话」占位）。淘汰按「最旧写入」序而非 LRU：预取天然按「最近看见」写入，几乎重合，LRU 的维护成本不值 | domain 5 条 + desktop 1 条（习惯页 router 层）+ mobile 2 条（预取命中展示 / getGroup 失败降级「未知对话」）；**反向验证**：删淘汰分支 → 容量用例红；`groupTitleOf` 改恒 null → 预取展示用例红 |
| G5 | **`SyncStateStore.save` 逐条 `await` 改 `_db.batch`**（对齐 `DriftTimelineCacheStore` 既有写法） | 同事务、`StorageError` 包装、upsert 覆盖同 relPath 语义均不变；生产 5666 文件全量替换从 N 次往返降为 1 次。不动表定义（无 build_runner 重跑） | spb_data 新增 2 条幂等/覆盖用例；**反向验证**：去掉「先删旧记录」的整体替换步骤 → 用例红 |

#### 有意保留（K1–K6，勿顺手「优化」）

- **K1 桌面侧边栏 `Offstage` 常驻**（[§6.46](ui.md)）：~130KB 固定 + 已加载交付物清单
  （5666 文件约 2.6MB），换「再展开零延迟零请求、滚动位置保留」；
- **K2 `scrollCacheExtent = viewport(1.5)`**（§6.47/[§6.51](ui.md)）：换掉帧内 Markdown
  冷解析，代价是同时挂载行变多；
- **K3 `maxBufferEvents=2000` / `_keepAliveWindow=12` / `_bubbleCacheLimit=200`**
  （§6.47/[§6.48](chat.md)）：全部经实测校准且有测试钉住契约；
- **K4 group 列表 `_groups` 无条数上限**（[§6.10](architecture.md)）：列表语义 = 用户 group 总数，
  截断会丢已加载分页；
- **K5/K6**：面板 `IndexedStack` 常驻与已 dispose 的 `ValueNotifier`（对照项，
  无泄漏）。

推翻 K1–K3 需先拿到 `SPB_FRAME_TIMING=true` 的真机慢帧数据（§6.47 的观测
手段）——本机做不了，故「结构性无界才修、实测取舍过的不动」是本轮判据。

#### 三个跨任务的一致性取向

1. **容量常量公开 + 类文档记折衷**：`notifiedIdsCapacity` / `maxTrackedGroups` /
   `GroupTitleCache.defaultCapacity` / `kImageCacheMaxBytes` 都是公开 `const`，
   文档写明「被淘汰条目退回默认行为」的安全方向论证（只多做事不出错：重新
   拉取 / 多探测一次 / 理论上重复通知一次）。
2. **淘汰语义统一为「最旧写入」**：三处都靠 `LinkedHashMap`/`LinkedHashSet`
   插入序取 `keys.first`，不走 LRU——预取/判重场景「最近写入 ≈ 最近使用」，
   LRU 的维护成本不值。**陷阱**：Dart `LinkedHashMap` 重复赋值不移动位置，
   需要「刷新即最近」语义时必须 remove+re-insert（G2 已踩）。
3. **接线断点用装配层用例自证**：`check_wiring_parity.sh` 只比对两端共享
   组件构造点参数，**不覆盖 providers / router 内部**——本轮 G1 的 `reset()`
   接线、G3 的 router 层用例都是这个失败模式的直接应用（[§6.17](testing.md) 教训）。

#### 验证

全量守卫（`check_agents_refs` / `check_agents_numbers` / `check_wiring_parity`
/ `check_silent_catches` / `check_codegen` / `check_layering` / `check_format`
/ `check_unused_deps` / `check_analysis_options` / `check_test_support_sync`
/ `check_workflow_steps` / `check_build_defines`）+ 7 个 `*_selftest.sh` 全绿；
五包测试（spb_domain / spb_api / spb_data / spb_features / spb_platform 纯 Dart
四包 + 两端 flutter test）全绿。对账单 `docs/memory-audit.md` 的 G1–G5 处置
结论已逐条落实，A1–A20 / K1–K6 与代码现状复核一致。

### 6.60 第二轮内存/峰值优化：哈希下放 isolate / 交付物树懒构建 / 内存压力接线（2026-11）

第一轮（§6.59）收口的是「结构上任意增长」的容器；第二轮（对账单
`docs/memory-audit.md` §六）换了一条判据：**峰值与主线程占用**——大文件同步
（全量 4.7 GB、单文件上限内可达 100 MB）与交付物树展开的瞬时峰值在这一层。
本轮修 **3 项**（G6 / G7 / G9），**待议 6 项**（G8 / G10 / J1–J4）只登记不动。

#### G6：SHA256 下放 isolate（`contentHashOfAsync`）

同步/上传链路在字节**全部驻留内存之后**于主线程算哈希，单份 100 MB 文件约
数百毫秒——帧预算是 16.7 ms，同步首轮会连续命中。新增
`contentHashOfAsync(List<int> bytes)`：

| 判据 | 取值 | 为什么 |
|---|---|---|
| 阈值 | > 8 KB 走 `Isolate.run`，≤ 8 KB 走同步 `contentHashOf` | isolate 启动/拷贝本身有成本，小输入反而更慢；8 KB 以下同步哈希 < 1 ms，无感知 |
| 传输 | `TransferableTypedData.fromList` | worker 侧拿**外部缓冲视图**（`materialize()` 零拷贝），不额外占 worker 的 Dart 堆。⚠️ **它不是所有权移交**：实测 `fromList` 自身就拷贝一次（`fromList` 之后改原 buffer，`materialize()` 出来的字节不受影响），故调用方**仍可**继续读 `bytes`——「移交后不可再读」是不成立的约束，已从代码注释与对账单删除。收益不在「少一次拷贝」，而在 worker 不产生堆分配 |
| 保留同步版 | `contentHashOf` 不动 | 测试与小数据路径不变；restricted 环境（`Isolate.run` 抛 `UnsupportedError`）回落同步 |
| 不上流式 | `ResponseType.stream` + chunked hash 是「彻底档」，未做 | 现状字节本就全量驻留（下载缓冲 + 写盘），isolate 化只解决「主线程冻结」这一半；流式要动 UFS 下载契约与 `FileSink`，收益/风险比不划算，登记在对账单 |

反向验证：isolate 路径改为返回错误哈希 → 3 条新用例红；还原后绿。

#### G7：交付物树 flatten + `ListView.builder`

面板原是 `ListView(children: _tree.map(_buildNode).toList())`——build 阶段把
**全部**节点 widget 一次构造完（目录节点是 `ExpansionTile`：StatefulWidget +
controller 装配），5666 文件的一帧构造 5666 个、滚出视口即弃；且每次 SSE 文件
事件 bump `reloadToken` 都全量重来。现改为：

- **可见行派生**（`_rows` getter）：只递归「展开中的目录」，折叠子树**不进行
  集合**——这才是真正的懒（`ExpansionTile` 的折叠是视觉隐藏，子树仍挂载）；
- **展开状态自持**（`_userExpansion: Map<String,bool>`，只记用户点过的目录；
  未点过的按层级取默认：顶层展开 / 深层折叠，与原 `initiallyExpanded: depth == 0` 一致）；
- **缓存双判据失效**：`identical(_rowsSource, _tree) && _rowsSourceRev == _rowsRev`。
  只比 `_tree` identity 不够——**点击目录不换树，但可见行集合变了**，须用修订号；
- 生命周期语义（三条既有测试钉住 + 两条新测试钉住）：同对话 `reloadToken`
  刷新**保留**展开状态（用户正在看的目录不能被折叠回去）；切对话**重置**
  （旧目录名可能相同但语义已不同）。

⚠️ **测试自坑（诚实记录）**：「切对话后展开状态重置」最初失败——`_file()` 夹具
的路径固定用默认 gid，切到另一 group 后 `buildArtifactTree` 剥不掉
`/workspace/groups/<新gid>/` 前缀，整棵树为空 → 用例红的是**夹具**而非实现
（红在「切对话后没有任何行」）。修夹具（`_file(..., gid: gid)`）后绿。

反向验证：退回 `ListView(children:)` → 2 条红（builder 委托结构断言 + 折叠行数）；
切对话不清展开状态 → 1 条红；toggle 去掉 `_rowsRev++` → 1 条红（点击无反应）。

与 K1（[§6.46](ui.md) 侧边栏 Offstage）不冲突：K1 保数据与滚动位置，G7 让子树里的列表
本身懒构建——两者叠加才是目标状态。

#### G9：系统内存压力接线（`installMemoryPressureHandler`）

全仓 `didHaveMemoryPressure` 零命中。移动端是最需要这条信号的端（内存最紧张），
收到压力时什么都不做直到被系统杀掉。新增
`spb_platform` 的 `installMemoryPressureHandler({onRelease})`（进程级 observer，
两端 `main.dart` 在 `configureImageCache()` 后无差别接线——桌面引擎不派发该
信号，注册后无效果，故无需平台分支）。

**框架已经做了一半（实测确认）**：`RendererBinding.handleMemoryPressure()`
会先调 `imageCache.clear()` 再遍历 observer——但 `clear()` **不清 live
images**（还有外部 listener 的图，例如正显示的预览大图）：

```
清空前: size=1 live=1
clear(): size=0 live=1        ← 框架只做到这里
clearLiveImages(): size=0 live=0  ← 本模块补的
```

「用户正盯着一张 4000×3000 预览图」恰恰是移动端最容易 OOM 的场景，故
`clearLiveImages()` 才是本模块的真实增量（`clear()` 保留为幂等防御）。
`onRelease` 留给 app 层的页面级可再生缓存。**不**清任何持久化状态（离线缓存 /
同步状态 / outbox）——那些不是「内存」，清掉丢用户数据。

⚠️ **测试假绿（实测踩过，与 [§6.17](testing.md) 同型）**：第一版测试只断言 `currentSize == 0`，
且没把条目真正放进缓存——清不清都绿。两个必要前置：① 用
`putIfAbsent + OneFrameImageStreamCompleter` 真的放条目，且**冲一轮微任务**
（completer 回调在微任务里，否则读到的是 pending 态）；② **挂外部 listener
保持 live**——不挂的话 completer 完成后 `_LiveImage` 自动释放，`liveImageCount
== 0` 恒真。修好后反向验证才有效：去掉 `clearLiveImages()` → 1 条红；去掉
`onRelease` 调用 → 3 条红。

#### 动画与日志的边界

J1（结束时 remount，#72）和 J4（追底动画重启，#75）已由 §6.47 第九节的回归
修复，流式禁选和动画时长均保留。J2（同步日志，#73）与 J3（逐字 fade，#74）保持
现有取舍；是否改变这些行为仍须依据真实设备采样。

#### G10 图片降采样 + 内存采样通道（后续四项之二，2026-11）

G10 与「拿不到绝对内存曲线」是第二轮剩下的两个**不靠猜测就能推进**的项，
已同时收口。细节与证据以对账单 `docs/memory-audit.md` §6.1 / §四 为准。

**G10：Markdown 图片走我们自己的 `imageBuilder`。** 判据不是猜测，而是插件
源码：`gpt_markdown` 1.3.0 `shared_render.dart` 的 `imageSpan` 默认分支是
`Image(image: NetworkImage(url))`——**没有** `ResizeImage`/`cacheWidth`。于是
agent 回复里一张 4000×3000 的截图就按原图解码 ≈ 48MB 位图进全局 imageCache，
而它在气泡里最多 1024dp 宽；这是全仓最后一处未降采样的 `Image`。

接管 `imageBuilder` 是**替换整个图片 widget**，不是只换 provider，故
`spb_features/lib/src/chat/markdown_image.dart` 复刻默认实现的三件事，否则
是「修了内存改了行为」：

1. 尺寸盒子 `SizedBox(width, height)`——Markdown alt 里的 `=宽x高` 是逻辑像素；
2. `fit: BoxFit.fill`——默认实现的 `imageStyle.fit ?? BoxFit.fill`（本仓库
   `_styleSheet` 未设 `ImageStyle`；**若将来设了 fit，builder 必须同步改**）；
3. loading / error 占位用插件自己的 `CustomImageLoading` / `CustomImageError`
   （深 import 自 `custom_widgets/custom_error_image.dart`，未从主入口导出——
   好处是视觉与默认路径完全一致，代价是插件挪文件时会编译期报错，不会静默）。

`data:` URL 必须自己补缓存：插件的那份（32 条 / 32MB）是**私有**的，接管
builder 就等于接管这条路径。`MemoryImage` 的相等性是字节列表**同一性**，每帧
重 `base64Decode` 会得到全新 provider（缓存永不命中，流式回复里逐帧重解码并
闪一下）。故补一份同级的 LRU（`kDataUrlMemoMaxEntries` / `kDataUrlMemoMaxBytes`）。

**折衷（诚实记录）**：只限宽不限高（限高会改图片的**显示尺寸**，那是改行为不是
优化；极端长图由 imageCache 的 32MB 上限兜底）；解码宽封顶 1024dp（`
kImageDecodeCeilingLogicalWidth`，与 G4 预览图同一取舍：超宽窗口略糊）；DPR
变化会重解码一次（`ResizeImage` 的缓存键含解码宽）。

**内存采样：把 openQuestion 变成用户机器可回收的数据。** 新增
`spb_platform` 的 `MemoryProbe`：每 60s 取 `ProcessInfo.currentRss` /
`ProcessInfo.maxRss`（OS 高水位）与 imageCache 的字节/张数/live 张数，进 12 槽
环形缓冲；`exportDiagnosticsReport` 导出那一刻**强制再采一次**，并在报告里
新增「## 内存采样」小节（排在「## 最近日志」之前——「涨到多少」是靠 500 条日志
回答不了的，同 G7 之后时间线快照的摆放理由）。

为什么不需要 `SPB_FRAME_TIMING` 那样的编译期开关：帧回调是**每帧**，本模块是
每分钟一次、6 个整数、一个有界环形缓冲；而它换来的恰恰是「用户报障时报告里
有没有内存数据」。**关键**：采样**不写日志**——一条/分钟会在 8 小时内把 500 条
环形缓冲冲干净（`FrameTimingReporter` 的批次汇总就是这个教训）。

⚠️ 读采样时的两条前提（本仓库改不到）：RSS **不会回落到基线**（Dart GC 在
「堆大小看起来合适」时不回收，而桌面端没有 OS 低内存信号；Windows 上还有
ANGLE 保留 GPU 侧数据——flutter/flutter#179834，独显比核显水位低）。故只看
**峰值（`peak=`）与斜率**，不看是否回落。仍未闭合的只剩「Dart heap 分解」与
「GPU/ANGLE 占用」两维，它们确实只能 DevTools + 真机。

#### 验证

`dart analyze` 全仓干净；12 守卫 + 自测全绿；测试：spb_domain 1141 / spb_api
495 / spb_models 471 / spb_core 150 / spb_platform 177 / spb_features 1297 /
spb_desktop 212 / spb_mobile 120 全绿（spb_domain +3 = `contentHashOfAsync`
等价性 / 已知向量 / 非 `Uint8List` 输入；spb_platform +4 = 内存压力接线；
spb_features +4 = builder 委托结构 / 折叠行不进行集合 / 同对话刷新保留 /
切对话重置）。

（以上是 G6/G7/G9 那一轮的验证。G10/G9′ 的验证在其各自的测试清单里：
G10 = `markdown_image_test.dart` 11 条；G9′ = `memory_probe_test.dart` +
`memory_probe_wiring_test.dart` + 报告小节 2–3 条，均全绿。）

### 6.72 G8 收口（缩略图有界 + 版本失效）与内存分解/高水位日志（2026-11）

前两轮的收口方式是「先有界，再谈参数」；这一轮把剩下的**正确性**缺陷修掉，
并把「内存花在哪」从猜测变成可回收的数据。

#### G8：缓存不失效是正确性问题，无界是容量问题（分开修）

issue #70 给了三条路：（a）服务端在 `agent.file.*` 里带 mtime/etag（跨仓库、
违反「Go API 一行不改」）；（b）客户端把缓存生命周期绑到文件项（覆盖写/删除
即逐出）；（c）接受现状。选 **(b)**：它零跨仓库依赖，且不引入「淘汰 ↔ 重复
请求」的新取舍点。

- **版本令牌**：`AgentFileItem.contentRevision` = `(action, modifiedAt,
  deletedAt, sizeBytes, mimeType)`。UFS 覆盖写是 `ReplaceContentAndCreateVersion`：
  **id 不变、内容变**，故键仍是 `ufsFileId`，判据换成令牌。`createdAt` 故意
  不取（归约时锚定首次出现，覆盖写不变）。
- **两处判据必须一致**：页面层 `ThumbnailMemo.resolve(id, revision, load)` 与
  卡片 `didUpdateWidget` 的「重拉」判据都用同一个令牌。只改一边会出现
  「缓存逐出了但没人来取」或「重拉了但命中旧条目」——两种都表现为「图没变」。
- **删除事件**：`agent.file.deleted` 的载荷没有 `ufsFileId`，但归约后的项保留
  创建时的 id，故 `_onItems` 按 id 逐出（只在缓存非空时扫描，避免为无图对话
  付全表扫描）。
- **容量**：`kThumbnailMemoMaxEntries = 512` / `kThumbnailMemoMaxBytes = 16MB`，
  双线取先到者，淘汰「最旧写入」（`LinkedHashMap` 插入序，与 §6.59 的两处
  缓存同一取向）。**这是安全上界，不是实测最优值**——真实峰值（条目数 / 字节数）
  由账本读数 `conversation.thumbnails` 从用户机器回收后再校准。淘汰后重新滚动
  会重新请求一次，这是「有界」的**已知代价**，不是回归。
- **单条超预算不淘汰自己**：否则一张略超 16MB 的图会陷入「每次 build 都重拉」，
  比多占几 MB 糟得多（有测试钉住）。

#### 内存分解：把「占了多少」补成「花在谁身上」

`MemoryProbe` 只有进程级数字。新增 `spb_core` 的 `MemoryLedger`：持有方在
`initState` 登记一个具名读数闭包，`dispose` 注销。

| 读数 | 持有方 | 口径 |
|---|---|---|
| `conversation.timeline` | 对话页 | 条目数 + 正文字符数 × 2（UTF-16 估算） |
| `conversation.bubbles` | 对话页 | 气泡缓存条目数 + 已解析正文字节估算 |
| `conversation.thumbnails` | 对话页 | `ThumbnailMemo` 条目数 + 已解析字节 |
| `deliverables.panel` | 交付物面板 | 清单条目 + 可见行数（字节不估） |

约束（都有测试钉住）：

1. **登记/注销必须成对**——读数闭包捕获页面 State，只登记不注销 = 用全局
   `Map` 把整页钉在内存里，观测本身成了泄漏。
2. **读数抛错不得带崩报告**：`snapshot()` 逐项兜住并写一条 `warn`
   （读数挂了本身就是要查的事）。
3. **同名项求和、阈值取最大**：两端/多页面同时挂账本时不重复计数、告警线
   也不翻倍。

报告里这些行追加在「## 内存采样」曲线之后（先看涨到多少，再看花在谁身上）；
纯账本、无采样器时也输出该小节（分解本身就是内存信息）。

#### 高水位日志：用户不导出报告时也有证据

`MemoryWatchdog` 每 5 分钟检查一次，三条触发线任一满足即写一条 `warn`：

- `imageCache ≥ 24MB`（硬上限 32MB，接近即意味着马上要淘汰/重解码）；
- RSS 相对**本次运行首条读数**增量 ≥ 256MB（RSS 不回落，故看增量不看绝对值）；
- 任一账本项越过自己声明的 `warnCount` / `warnBytes`（分解里用 `!` 标注）。

两条闸门防「用同一个读数冲掉 500 条环形缓冲」：**30 分钟冷却** +
**无显著变化不写**（RSS 未涨 10%、imageCache 未涨 20% 就跳过）。

**为什么桌面端不自动清缓存**：`imageCache.clear()` + `clearLiveImages()` 会让
正在看的图闪一下重解码，而桌面端没有 OS 低内存信号可作依据（移动端有
§6.60 的 G9）。在拿到真实机器的 `peak=` 与分解数据之前，自动清理是在拿可见
的界面抖动赌一个未知收益——本期只观测。

#### 仍未闭合（诚实记录）

- **Dart heap 分解**（按类 / external / GC 时机）与 **GPU/ANGLE 占用**仍只能
  DevTools + 真机（`flutter/flutter#179834`）；账本给的是**我们自己的**持有方，
  引擎侧那部分仍然只能从 `peak=` 反推。
- 第三方包内部缓存（gpt_markdown / drift / dio）不在核实范围。
- 账本的 `bytes` 是估算（UTF-16 字符数、解析后字节长度），用于横向比较，
  不承诺与 DevTools 逐位一致。

#### 验证

- `spb_core`：`memory_ledger_test.dart` 9 条（注销 / 幂等 / 聚合与阈值取最大 /
  排序稳定 / 读数抛错兜底 / 越线判定 / 报告格式 / reset）。
- `spb_features`：`thumbnail_memo_test.dart` 10 条（同版本命中 / 版本逐出 /
  显式逐出 / 条目淘汰 / 字节淘汰与峰值 / 单条超预算不淘汰自己 / 迟到解析不计账 /
  失败项缓存 / 同步抛错不写状态 / clear 保留峰值）；`conversation_page_delivery_test`
  +3（覆盖写后重拉 / 删除事件逐出 / 页面销毁注销）；`agent_file_revision_test`
  5 条（domain）。
- `spb_platform`：`memory_watchdog_test.dart` 7 条（阈值 / 基线 / 冷却 / 无变化
  不写 / 分解与 `!` 标记 / 读数抛错 / 安装幂等）；`memory_probe_wiring_test` +1
  （两端都装看门狗）；`diagnostics_export_test` +2（分解行 / 纯账本小节）。
- 守卫全绿（`dart analyze` / `dart format` / 12 个 `check_*.sh` + 自测）。

### 6.73 真机报告驱动的第三轮收口：脏检测改为 stat + 流式摘要，补上同步在途读数（2026-11）

前两轮（§6.59 / §6.60 / §6.72）都是「结构上找无界集合」与「按操作估峰值」。
这一轮换了判据：**用户机器导出的诊断报告**。它把两个静默问题一起暴露了。

#### 报告长什么样（Windows 10 LTSC，release）

```
23:13:19 内存基线 rss_mb=66.9 peak_rss_mb=66.9 image_cache_mb=0.0
23:33:19 rss=253.4MB peak=421.1MB imageCache=0.3MB(1 张)
23:43:19 WARN 内存高水位 rss_mb=498.5 peak_mb=565.3 since_start_mb=431.6
              image_cache_mb=0.3 breakdown=
23:43:28 rss=287.2MB peak=578.5MB
```

三条读数各自否掉一批猜测：`image_cache_mb=0.3` 否掉图片；`breakdown=` 为空
否掉**所有登记过的**持有方（时间线 / 缩略图 / 气泡缓存 / 清单）；498.5MB 出现
在登录成功那一分钟、9 秒后回落到 287MB —— **一次性大块分配**，不是泄漏。

#### G11：脏检测的 2× 瞬时峰

`scanLocalDirtyFiles` 对状态表里每个文件做「整份读入 → `contentHashOfAsync`
算摘要」，而后者内部的 `TransferableTypedData.fromList` **自己就拷贝一次**
（§6.60 时已实测确认，当时只当它是「worker 侧零拷贝的代价」）。于是峰值是
**2× 文件大小**；并且体积过滤排在读完**之后**——2GB 的媒体文件要读完才发现
超上限。

同步目录实测 5666 个文件 / 4.7GB：只要有一个一两百 MB 的交付物，就是
200–400MB 的瞬时峰，与报告里的 258 → 498.5MB 吻合。

处置（两处都不改语义，摘要仍是同一个 SHA256）：

- `LocalFileReader` 增加 `sizeOf`（只 stat）与 `contentDigestOf`（流式）；
  脏检测**先判体积**（超上限连读都不读），再用 `contentHashOfStream`
  （`File.openRead()` + `sha256.startChunkedConversion`，峰值 O(块)）；
- `readBytes` 保留给「上传确实要整份内容」那一步（`_handleOne`）——那里本来
  就必须持有内容，不该假装能省。

#### G12：下载路径仍然整份持有（**只补读数，未消除**）

`downloader.download()` 返回 `bytes` → `sink.write(bytes)` →
`contentHashOfAsync(bytes)`（又一份拷贝）。要真正消掉得让下载流边写边算摘要，
那会改 `FileDownloader` / `FileSink` 契约（涉及 `.part` + rename 的原子写不变量，
§6.42）。本轮只把它**变可见**：新增 `SyncInFlightBytes.hold/release` +
`registerSyncInFlightGauge`（账本项 `sync.inflight`，越线 128MB）。

#### G13：观测缺口

两处，都直接导致这次排查卡住：

1. **基线被滚掉**：`MemoryProbe` 只有 12 槽（≈12 分钟），长会话里启动基线
   滚出窗口，报告最早一条已是启动后 20 分钟的 253MB——「从 66.9 涨到 253」
   这段过程完全不可见。现在基线**单独保留**，滚出窗口时报告在最前面补一行
   并标注「已滚出采样窗口」；基线还在窗口里时不重复输出。
2. **登录页上账本恒为空**：账本只在会话页与交付面板登记，于是 `breakdown=`
   为空被读成「没花在谁身上」，实际是「这一页没有任何持有方登记」。现在同步
   链路的在途字节有读数（G12），且账本为空时报告**显式写一行**「无登记项」
   ——但探针与账本都空（移动端未接线 / 单测）时整个小节仍省略，那才是「什么
   都没采集」。

#### 仍未解释的一段（诚实记录）

启动后 20 分钟 `rss 66.9 → 253.4MB`、`peak 421.1MB`，当时停在**登录页**
（会话失效，5 次 401）、窗口已隐藏到托盘，窗口内零日志。样本已被 12 槽冲掉，
G13 修好后下一份报告能看到斜率；若仍复现，只能靠 profile 模式 + DevTools 的
Dart heap 分解（本模块拿不到这一维）。

#### 验证

- `spb_domain`：`sync_hash_stream_test.dart` 6 条（空输入 / 已知向量 `"abc"` /
  跨块等价 / 1 字节块等价 / 与 `contentHashOfAsync` 一致 / 流中途抛错上抛）；
  `sync_memory_test.dart` 6 条（hold/release 累加 / release 多时归零 / 0 与负数
  不计数 / 登记后进快照 / 越线标记 / 清零后不越线）；`deliverable_upload_test`
  +4（超上限**连摘要都不算** / 内容一致只走 stat + 流式摘要、`readBytes` 零调用 /
  摘要失败记失败不算脏 / stat 失败记失败）。
- `spb_platform`：`file_sink_test` +10（`sizeOf` 含 0 字节 / 不存在抛
  `PlatformError` / 逃逸与软链拒读；`contentDigestOf` 与整份哈希逐字相等 /
  跨块等价 / 0 字节 / 不存在 / 逃逸 / 软链）；`memory_probe_test` +3（基线在
  窗口内不重复 / 滚出后补行并标注 / 基线只记首条）。
- 全仓 `dart analyze` 干净；`dart format` 无 diff；12 个守卫 + 自测全绿；
  `spb_domain` 1194 / `spb_platform` 252 / `spb_desktop` 243 / `spb_mobile` 159
  全绿。

---

### 6.74 渲染帧数进内存采样：把「CPU 为什么高」变成报告里的一行（2026-11）

#### 背景

第三轮真机回访（`docs/memory-audit.md` §4.5）的读数里，RSS 470MB 平台期与
`peak 897MB` 和**同步、图片、登录页全部无关**（在途 0B、`imageCache` 0 张、
无 401），而用户同时报「CPU 一直很高」。两者很可能是同一件事，但当时报告里
**没有任何渲染维度的读数**，只能猜。

两种可能的原因要用两个数字分开：

| 读数 | 含义 | 判读 |
|---|---|---|
| 每秒帧数 | 引擎是不是**一直在出帧** | ≈60 → 常驻动画/每帧重建；≈0 → CPU 在别处 |
| 平均光栅耗时 | 光栅化**画得贵不贵** | 十几 ms 以上 → 更像软件光栅化（WARP）或过度绘制 |

#### 做法

- 新增 `spb_platform/lib/src/frame_activity.dart`：`FrameActivityCounter`
  数帧（`addPostFrameCallback` 自续排，**必定**每帧触发）+ 累加光栅耗时
  （`addTimingsCallback`）。
- `MemoryProbe` 采样行尾部追加 `fps=59.6 raster=7.3ms`，与 RSS 同一行、同一
  时间戳——拆成两个小节就得靠人对时间。
- 由 `installMemoryProbe()` 自动接线（两端 `main()` 无需改动）；注入
  `probe` 的测试路径不接线。

#### 三条取舍

1. **帧数不用 `FrameTiming` 数**：timings 在部分平台/构建不提供，用它计数会
   把「没收到 timings」误读成「没出帧」——两个完全不同的结论。故帧数走
   post-frame 回调，光栅耗时走 timings，且**拿不到时报告里不写 `raster=`**
   （缺席 ≠ 0ms）。
2. **窗口为 0 的采样不写 `fps`**：首条采样没有间隔可算，写 `fps=0.0` 会被读成
   「这一分钟一帧都没画」。
3. **保留一位小数**：1 分钟窗口里 3576 帧 = 59.6fps，取整会把「满速」与
   「掉到 50」显示成同一个值。

#### 验证

`frame_activity_test.dart` 7 条（取走即清零 / 窗口重置 / 未出帧不除零 /
3576 帧=59.6 / 多帧光栅取均值 / 安装幂等 / post-frame 真回调计帧）；
`memory_probe_test.dart` +4（接线后有 `fps` 与 `raster` / 窗口为 0 不写 /
未接线保持原格式 / 无 timings 时不写 `raster=`）。
