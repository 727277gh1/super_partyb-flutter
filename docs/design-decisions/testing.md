# 测试与仓库守卫

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。覆盖率与 golden 基线、两端接线守卫、文档引用/数字守卫、生成物漂移守卫、
静默 catch 守卫、工程卫生、测试文件拆分。

共同教训：**一个会在错误实现上变绿的用例，比没有用例更危险**。

> 编号（`§6.x` / `§5.x` / `[§7](build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](README.md)。

---

### 6.13 覆盖率与 golden 测试（issue #25）

#### 覆盖率：`tools/coverage.sh`

```bash
bash tools/coverage.sh                # 全包，产物 coverage/lcov.info + 汇总表
bash tools/coverage.sh spb_domain     # 单包（调试用）
bash tools/coverage.sh --summary-only # 不跑测试，只汇总已有产物（CI summary 用）
```

**为什么需要脚本而不是直接 `flutter test --coverage`**：两种包的产物格式**不同**。

| 包类型 | 命令 | 原始产物 | 要 lcov 还得跑 |
|---|---|---|---|
| 纯 Dart（`spb_core/models/api/domain`） | `dart test --coverage` | `coverage/test/*.json` | `dart run coverage:format_coverage --lcov ...` |
| 含 UI（其余 + 两个 app） | `flutter test --coverage` | **直接就是** `coverage/lcov.info` | 不需要 |

踩过的坑：对 `flutter test` 的产物再跑一次 `format_coverage` 会报「in 目录里没有可
解析的文件」——因为 `lcov.info` 不是它的输入格式。

`format_coverage` 的 `--report-on` 必须传**绝对路径**（`$PWD/lib`）：传相对路径会让
`SF:` 前缀随工作目录变化，同一文件在合并时被算两次。

#### 生成代码被剔除（issue #38）

汇总与合并时**剔除** `*.g.dart` / `*.freezed.dart` / `*.gr.dart`——它们是构建产物
（`dart run build_runner build` 生成），没有「测试写得好不好」这个维度。

| 文件 | 对分母的影响 |
|---|---|
| `spb_data/lib/src/database.g.dart` | **1591 行 = 该包分母的 79%**（全仓唯一一个生成文件） |

剔除是**可见的**：汇总表下方打印被剔除的行数，并给出查看原始数字的命令。

```bash
# 含生成代码的原始数字（对比用）
COVERAGE_INCLUDE_GENERATED=1 bash tools/coverage.sh --summary-only
```

> 剔除后 `spb_data` 从 43.8% → **98.3%**——原先的低值几乎全是生成代码拉低的，
> 而不是「持久层缺测试」。**但 `spb_data` 的手写代码确实有真缺口**（见下），
> 故不能只靠剔除收工。

#### 两处**结构性不可达**的代码（不是测试缺口）

| 位置 | 为什么不可达 | 处理 |
|---|---|---|
| `database.dart` 的 7 个 drift 表类（列 getter / `primaryKey`） | 它们只在 `build_runner` 生成 `database.g.dart` 时被读取；运行时每个表用生成的 `$XTable` 子类（`GeneratedColumn` 覆盖了 getter）。直接调用 `SyncCursors().stateKey` 会抛 `Unsupported operation: This method should not be called at runtime` | 源码里用 `// coverage:ignore-start` / `// coverage:ignore-end` 标记（带「drift 改生成方式时必须删掉」的注释） |
| 同上，`database.g.dart` 本身 | 构建产物 | `tools/coverage.sh` 的 `*.g.dart` 过滤 |

`coverage:ignore-start/end` 由 `flutter test --coverage` 直接支持（实测：标记 240 行
表定义后 `database.dart` 的 `LF` 从 90 → 43，未覆盖行从 48 → 2）。

⚠️ **纯 Dart 包要显式传 `--check-ignore`**：`dart test --coverage` 的产物经
`coverage:format_coverage` 转 lcov 时，`coverage:ignore-line` /
`ignore-start/end` **默认被静默忽略**（`flutter test` 路径则默认认）。
`tools/coverage.sh` 的 `run_dart_pkg` 已加上这个 flag——去掉它会让
`spb_models` 的标记失效（`event_types.dart` 从 0/0 回到 0/1），而**不会报错**。

同类的「纯常量命名空间」私有构造（`EventTypes._()` /
`MiniappNotificationTemplates._()`）也是**结构上不可达**（库外不可见、库内无调用，
只用于防止实例化），同样用 `// coverage:ignore-line` 标记。

#### 当前基线（2026-10，本机实测，**已剔除生成代码**）

| 包 | 覆盖率 | 包 | 覆盖率 |
|---|---|---|---|
| `spb_data` | **98.3%** | `spb_platform` | 62.6% |
| `spb_features` | **93.5%** | `spb_mobile` | 56.7% |
| `spb_core` | **91.5%** | `spb_desktop` | 63.2% |
| `spb_domain` | 89.4% | `spb_api` | **88.5%** |
| `spb_models` | 88.0% | `spb_ui` | 73.7% |
| `spb_design` | 86.0% | **总计** | **85.7%**（≈16291/19004） |

全仓用例 **4261 条**（各包 `+N` 相加，即 `testDone` 且非 hidden；issue #48 拆分
本身 0 变化。+13 是 SSE 端到端（§6.27），+31 是零调用者端点契约（[§6.28](chat.md)），+6 是
[§6.37](auth.md) 的 `bearerToken` / `fromOidcTokens` / 两端接线回归防线，+38 是 [§6.41](platform.md) 的
定位与下载布局，+66 是 [§6.42](sync.md) 的自动同步，+50 是 [§6.43](sync.md) 的进对话按需同步，+89 是
[§6.54](ui.md) 的工具调用折叠 / 「动态」面板 / 流式进度条，+46 是 [§6.57](runtime-and-ops.md) 的文件日志 /
悬浮窗回滚顺序 / 默认同步目录，+75 是内存审计轮（[§6.59](performance.md)：无界集合容量淘汰 /
图片解码降采样 / 标题缓存 / batch 写入）。

分包含量（2026-11 实测，会漂移）：`spb_models` 471、`spb_api` 495、`spb_domain`
1138、`spb_features` 1293、`spb_data` 132、`spb_platform` 173、`spb_core` 150、
`spb_ui` 43、`spb_design` 34、`spb_desktop` 212、`spb_mobile` 120。

⚠️ **`spb_data` 的测试要用 `flutter test`，不能用 `dart test`**：它虽然也是纯
Dart 语义（drift + sqlite3），但依赖链里含 Flutter（`secure_pending_auth_store`
走 `flutter_secure_storage`），`dart test` 会报 `Dart library 'dart:ui' is not
available on this platform`。§2 里那句「`dart test` 用于纯 Dart 包」只覆盖
`spb_core` / `spb_models` / `spb_api` / `spb_domain` 这四个。

⚠️ **数用例时别用 `grep -c '"type":"testStart"'`**：它把 skipped 与
`setUp`/`tearDown` 产生的条目也算进去（实测差 100+ 条）。用
`testDone` 且 `hidden != true` 才是「真的跑过的用例数」。

⚠️ **这张表会漂移**——用上面的命令重跑，别把这里当权威数字。
⚠️ `spb_ui` 从 79.8% 掉到 73.7% **不是回归**：`copy_icon_button.dart`
（23 行）在 `spb_ui` **自己的**测试里零覆盖——它只被 `spb_features` 的
气泡测试点过，而 `coverage.sh` 是**逐包**采集的，看不到跨包调用。
这是既有缺口（要么给 `spb_ui` 补一条单测，要么接受），与 [§6.37](auth.md) 无关。
⚠️ `spb_ui` / `spb_design` 这类小包的行数会在**±1 行**内波动（Dart 覆盖率的
行归属不稳定，实测 `spb_ui` 多次重跑得到 90 或 91）。总计小数位可能随之跳 0.1，
不是回归。

> **总计从 75.7% 涨到 85.0% 不全是新增测试的功劳**：
>
> - 剔除生成代码（1591 行）抬升约 4.5 个百分点；
> - `spb_models` 50.6% → 88.0%（issue #38 补了 `Agent` / `ChatTurn` /
>   `ChatTurnSummary` / `ChatConfirmation` / `ChatInboxMessage` / `ChatSearchHit` /
>   `UfsFileEntry` / `Miniapp*` / `UserPreferences` 语义 getter / `Habit*` 的
>   round-trip 与容错用例，以及 `toString()` 诊断输出）；
> - `spb_data` 43.8% → 98.3%（补了 v1–v4 **跳版升级**、`openAppDatabaseAt` /
>   `openAppDatabaseLazy`、以及五条 `StorageError` 写失败路径）；
> - `spb_core` 85.0% → **92.4%**、`spb_platform` 52.5% → **55.3%**（issue #40
>   的诊断导出：`redactSecrets` / `buildDiagnosticsReport` / 环形缓冲 / 文件名
>   安全字符均有用例）；
> - `spb_api` 72.3% → **82.6%**（issue #41 补了 `sse_client_test.dart`，
>   `sse_client.dart` 从 **0.7% → 98.1%**；见 §6.22）。
>
> issue #38 点名的 7 个「0% 文件」（`chat_search_hit` / `chat_confirmation` /
> `chat_inbox_message` / `chat_turn` / `chat_turn_summary` / `ufs_file_entry` /
> `agent`）现在**全部 100%**，`miniapp.dart` 7.3% → 99.6%。

**剩余的低值**（`spb_platform` 55.3% / `spb_desktop` 58.8% / `spb_mobile` 54.4%）
有明确的环境原因：它们大量是**平台通道与原生代码的 Dart 侧包装**（`MethodChannel`
调用、窗口/托盘/快捷键），本机无 `DISPLAY`、无真机（见 [§9](../development.md)），widget test 只能覆盖
「未注册 channel 时的降级路径」。要抬升需要 mock 平台通道或集成测试——不是「补
单测」能解决的。

> **历史漂移记录（保留，避免重复踩）**：本表曾标「当前基线」却漂移多次（总计
> 76.6% → 76.3% → 75.7%）。曾把 `spb_data` 的低值归因为「drift 生成代码算在分母
> 里」——该判断**方向正确但不完整**：生成代码是主因（79% 分母），但剔除后仍暴露出
> 真缺口（跳版升级 / 两个 open 工厂 / 写失败路径）。**剔除 ≠ 收工**。

#### golden：只给「稳定 + 纯展示 + 改错代价高」的组件加

```bash
cd packages/spb_ui       && flutter test --update-goldens test/golden_test.dart
cd packages/spb_features && flutter test --update-goldens test/chat/golden_test.dart
```

**为什么不铺到全仓**：golden 是**维护负担**——每次有意改样式都要更新基线，且基线
PNG 占仓库体积。当前只给 5 个 `spb_ui` 组件（`ErrorBanner` / `ErrorState` /
`EmptyState` / `HintLine` / `SectionTitle`，共 8 张）与 `spb_features` 的
`SpecUiCard`（3 张）加。

**`CopyIconButton` 有意不加**：它有异步状态（复制中/已复制/复位），渲染结果依赖
计时器，基线会 flaky。它的逻辑已有单测。

#### 两条容易踩的 golden 约定

1. **字体必须显式装载**（`test/support/golden_fonts.dart`）。`flutter test` 默认用
   **Ahem**（每个字形渲染成实心方块）——基线无法人工审阅（一张全是方块的 PNG 看
   不出「按钮是不是错位了」）。装载 Roboto + MaterialIcons 后图标与拉丁字母真实渲染。
   **不装载系统字体**：本机 Debian 与 CI 的 ubuntu-latest 字体集不同 → 基线必然有
   一边失败。字体从 `FLUTTER_ROOT/bin/cache/artifacts/material_fonts/` 取，**随
   Flutter 版本锁定**（本仓锁 3.47.5），故本机与 CI 拿到逐字节相同的字体。
2. **中文基线是 tofu（空心方块）——预期行为**。SDK 不带 CJK 字体。golden 锁的是
   **布局**（位置/尺寸/间距/颜色/换行点），tofu 与真字形在这些维度上一致。看懂文案
   的断言用 `find.text`（两者分工明确）。

#### 跨包重复的测试辅助文件有守卫

Dart 的 import 只能引用包内的 `lib/`，测试辅助代码**无法**跨包 import。故
`golden_fonts.dart` 在 `spb_ui` 与 `spb_features` 各有一份，由
`tools/check_test_support_sync.sh` 保证逐字节相同（CI 已接入）。

**风险是真实的**：两份若行为不一致，本机与 CI 装载不同字体，golden 基线必然有一边
失败——而报错只说「像素不匹配」，指不到根因。

> ⚠️ 写这类守卫脚本时，变量名**不能**叫 `GROUPS`——那是 bash 的**特殊变量**（当前
> 用户的组 ID 数组）。赋值会被静默忽略，循环里拿到组 ID 而不是路径。踩过一次，
> 故这里用 `SYNC_GROUPS`。

### 6.17 两端接线一致性守卫（issue #33/#39/#42）

**脚本**：`tools/check_wiring_parity.sh` + `tools/check_wiring_parity_selftest.sh`
（CI quality job，在 Analyze 之前）。

#### 它防的是什么

`ConversationPage` 有 46 个具名参数，两端 router 各传 40+ 个。**漏接一端不会让
任何测试失败**：页面测试自己传参（接不接线它不管），两端 router 测试各管一端。
后果是用户界面上某个入口**静默消失**——移动端宽屏搜索入口就是这么丢的
（issue #33）。

源码里有 11 处注释写「两端构造点必须一致，否则一端功能缺失而测试仍绿」，
但**约定靠注释不靠工具**。故本脚本对两端共享组件构造点的具名参数做集合比对。

#### 覆盖面：3 个组件，不是 1 个（issue #42）

最初只登记了 `ConversationPage`。其余共享页面同样有单端差异且**同样没有
守卫**。现登记（2026-10 起 `SyncPage` 已并入设置页的同步标签，见 [§6.53](sync.md)，
从守卫里移除；其历史教训保留在下方）：

| 组件 | desktop 单端 | mobile 单端 |
|---|---|---|
| `ConversationPage` | `onOpenAgentFile` / `onRevealAgentFile` | `overflowItems` |
| `GroupListPage` | — | `onOpenQuickCapture` |
| `SettingsPage` | `loadLaunchAtStartup` / `setLaunchAtStartup` / `onOpenDirectory` / `onExportDiagnostics` / `showAutoSync` | `loadNotifications` / `saveNotifications` |

（`SyncPage` 行已于 2026-10 删除——它不再是独立页面，见 [§6.53](sync.md)。）

#### ⚠️ 守卫自己曾经假绿（issue #42 修掉的真实缺陷）

原实现用 `component + '('` 的**裸子串**搜索，而两端 router 里各有一个同名私有
包装：

```dart
class _SyncPage extends ConsumerWidget { ... return SyncPage(...); }
```

`_SyncPage(` 里含 `SyncPage(` 子串，取子串位置时命中的是**包装**那个**零参数**
的调用点，于是「零参数 == 零参数」被判为一致——脚本报「✅ SyncPage 接线
一致」，而桌面端实际多传了 `onOpenDirectory`。

**一个会假绿的守卫比没有守卫更危险**：它给出「已覆盖」的错觉。现修法：

1. 用 `(?<![A-Za-z0-9_])` 词边界匹配；
2. 返回**全部**调用点（调用方取并集）而不是只取第一个——只取第一个会静默
   丢掉后面的调用点，覆盖范围随重构缩小而无人察觉；
3. 新增 `check_wiring_parity_selftest.sh` 用**合成输入**钉住解析器行为
   （同名包装 / 多调用点 / 嵌套构造 / 注释与字符串噪声 / 值内逗号），
   它从守卫脚本里 **`awk` 抽出真身**再测，不是副本——守卫改了实现自测跟着变。

#### 豁免是**显式**的，不是「取交集」

每条豁免都在脚本里注明理由（`onOpenAgentFile` 类桌面能力、`overflowItems`
类窄屏载体、`loadNotifications` 类小程序额度）。

⚠️ **不要把它改成「两端取交集」**——那会把这类**有意的**产品差异也一起藏掉，
才是真的失去守卫。豁免写死在脚本里，过期（两端都传了）时脚本会报错提醒删。

#### 不检查什么

- **值**：两端传的表达式不同是正常的（`enableSearch` 就按宽度给），脚本只比对
  参数**名**是否存在，不解析值语义；
- **provider 层**：两端 `providers.dart` 有上百个同名 provider（其中以 `Provider`
  结尾的 86 个），上提到共享包是独立重构（issue #39 已登记），不在本守卫范围。

#### 补丁：override 漏挂也不在本守卫范围内——靠「可测的清单函数」（2026-11）

`main.dart` 里的 `ProviderScope(overrides: [...])` / `ProviderContainer(overrides: ...)`
是**另一条**「漏了也没人知道」的接线：provider 有合理默认值（`Noop*`），漏挂后
功能整条不执行、**零报错**。真实先例：`notificationSinkProvider` 的注释写着
「生产在 `main.dart` 覆盖为 `LocalNotificationSink`」，而两端 `main.dart` 从未
覆盖过——通知功能自上线起就没生效（根因写在 `apps/*/lib/providers.dart` 的
`notificationSinkProvider` 文档里；反向验证：删清单里的 sink 行 → 2 条红，
删 `app.dart` 的启动 `ensurePermission()` → 1 条红）。

本守卫管不到它（不看 provider 层）。做法是**把清单收敛成一个函数**：两端各一个
`buildProductionOverrides(...)`（`apps/*/lib/providers.dart`，`main.dart` 只负责挂上），
由 `apps/*/test/production_overrides_test.dart` 用
`ProviderContainer(overrides: buildProductionOverrides(...))` 断言「生产实际拿到的是
什么实现」。判据很直白：**只写在 `main.dart` 里的 override 清单，没有任何测试能
看见**。

#### 四个易写错的点（写这类脚本时）

1. **必须先把注释与字符串抹掉再解析**：`reason: 'a, b'` 里的逗号会被当成参数
   分隔符，注释里的 `ConversationPage(` 会抢到错误位置。脚本用「保持长度与
   换行」的替换（而非删除），行号才对得上。
2. **匹配要用词边界**，否则同名的私有包装（带下划线前缀的薄壳组件）会被当成
   目标——这正是 issue #42 的假绿。
3. **豁免过期要报错**：否则清单会随重构腐化，最终列出早已统一的参数。
4. **拼错参数名要单独报**：Dart 编译器会报，但脚本早一步给出「传了 X 没有的
   参数」，定位更快。

### 6.19 AGENTS.md 标识符引用守卫（issue #37）

`tools/check_agents_refs.sh`。本文档是本仓库**主要协作接口**（AI agent 与人的
共同参考），它引用的函数/字段若不存在，读者会去找一个不存在的东西。

#### 真实漂移先例（不是假想）

| 位置 | 曾引用 | 实际是 |
|---|---|---|
| [§6.15](chat.md) | `_summarize` | `searchConversationItems` 内联截取（产出 `snippet`） |
| [§6.15](chat.md) | `hasMore` | 参数名 `upperHistoryUnloaded` |
| 移动端 router 注释 | `_narrowActions` | 已改名为 `_appBarActions` |

改代码时重命名一个函数，不会有人记得回头改 AGENTS.md——除非有机器检查。

#### 只查三类（**零误报是硬指标**）

全文 backtick 标识符有 300+ 个，其中大量**合法地**不存在于 `lib/`：服务端 Go
符号（`ReplyProjector`）、webapp 组件名（`SkillPanel`）、环境变量
（`ANDROID_HOME`）、SQL 列名（`chat_decisions`）、C++ 符号（`fl_view_new`）……
无差别地查会淹没在误报里，没人会看。

故只查下面三类，实测在本仓库当前基线**逐类零误报**（规则以正则写在
`tools/check_agents_refs.sh` 里）：

| 规则 | 理由 | 实测 |
|---|---|---|
| 下划线开头的标识符 | 只可能来自本仓库 Dart（Go 导出符号首字母大写、React 组件 PascalCase） | 20 候选 / 0 误报 |
| snake_case 函数调用 | 同上 | 4 候选 / 0 误报 |
| `.dart` 文件名 | 只可能来自本仓库文件 | 22 候选 / 0 误报 |

扫描范围含 `lib/` 与 `test/`（文档会引用测试辅助/用例里的符号）。

#### 有意不查什么

- **CamelCase 标识符**：203 个候选里 34 个是**合法**的外部符号（服务端 Go
  方法、webapp 组件、宿主 API）——误报率 17%，不可用。
- **全大写常量**：15 个候选里 12 个是环境变量（`ANDROID_HOME` / `PATH`）。
- **本仓库确实没有的、需要引用的符号**：写进脚本的 `EXEMPT` 并注明来源。
  当前为空。

#### 与其他守卫的关系

十一个守卫各管一件事，**不要合并**：`check_format`（格式）、`check_layering`
（分层）、`check_test_support_sync`（重复测试辅助逐字节相同）、
`check_workflow_steps`（CI step 结构，含自测）、`check_analysis_options`（分析配置接线）、
`check_wiring_parity`（两端接线，含自测）、
`check_codegen`（生成物漂移，含自测）、
`check_unused_deps`（零引用依赖）、`check_agents_refs`（本文档引用 + tools/ 清单，含自测）、
`check_silent_catches`（静默吞异常，含自测，§6.24）、`check_agents_numbers`（本文档数字，
含自测，§6.25）。

> 自测脚本钉住的是**守卫自身**的假绿/假红风险（每个守卫的头部都列了它那几处
> 易写反的判定）。改守卫逻辑时必须同步改自测，并在 CI 里跑（均已接入）。

⚠️ **六个 `*_selftest` 是「守卫的守卫」**（截至 issue #47）：`check_wiring_parity`
曾因裸子串匹配而假绿（issue #42），`check_codegen` 的四个坑任一写错都会假绿或
假红（issue #43），`check_agents_numbers` 无标记时会静默空转（issue #46），
`check_silent_catches` 的规则写宽会淹在误报里、写窄会漏掉空体（issue #45），
`check_workflow_steps` / `check_agents_refs` 各有两处相反方向的判定（issue #47）。
会假绿的守卫比没有守卫更危险——它给出「已覆盖」的错觉。

### 6.21 生成物漂移守卫（issue #43）

**脚本**：`tools/check_codegen.sh` + `tools/check_codegen_selftest.sh`（CI
quality job，在 Analyze 之前）。

#### 它防的是什么

`packages/spb_data/lib/src/database.g.dart`（**3912 行**）是仓库里**唯一提交进
git 的生成文件**，由 `database.dart` 的 7 个 drift 表定义生成。

改了表/列定义却忘了重跑 build_runner 时：

| 门禁 | 结果 |
|---|---|
| `dart analyze --fatal-infos .` | ✅ 全绿 |
| `flutter test` | ✅ 全绿 |
| 其余 10 个守卫 | ✅ 全绿 |

因为 `.g.dart` 是 `part of`，编译器只看得到旧版本里已有的成员——**新增的列在
生成代码里不存在，但也没有任何编译错误**。直到运行时第一次查询碰到那一列才炸
（`no such column`），而报错指向 drift 内部，指不到「忘了重跑」。

与 issue #34（根 `analysis_options.yaml` 从未生效）是**同一类缺陷**：门禁覆盖
不到的地方，绿不代表对。

#### ⚠️ 四个反直觉的坑（都实测复现过；写错任一个就得到一个假绿或假红守卫）

**坑 1：不能在仓库根跑 build_runner。** 直觉上根目录跑一次就覆盖所有包，
**实测不是**：

```
$ dart run build_runner build          # 根目录
Built with build_runner/aot in 13s; wrote 0 outputs.
```

根 `pubspec.yaml` 没有 build_runner 依赖、没有 `build.yaml`、没有任何 builder
声明；`dart run` 能解析到 workspace 里的可执行文件，但「当前包」是根包，它没有
任何输入/输出 → **静默 0 输出**。于是守卫会永远报「✅ 无漂移」——正是本 issue
要消灭的那种假绿。故脚本按包执行（从生成物路径反推包目录）。

**坑 2：build_runner 的产出不是 `dart format` 的形态。** 实测：

```
$ cd packages/spb_data && dart run build_runner build
$ dart format --output=none --set-exit-if-changed lib/src/database.g.dart
Changed lib/src/database.g.dart        ← 生成物未格式化
```

差异全部是空白（`({` 后是否换行），而**提交进仓库的那份是格式化过的**。不调
format 会得到一个**永远存在的假漂移**（正确状态也红）。故比对前对生成物跑一次
`dart format`。

**坑 3：增量资产图导致守卫非幂等。** build_runner 把「已构建状态」存在
`.dart_tool/build/`，它**不看输出文件的当前内容**，只看自己的资产图。于是：

1. 守卫跑 build_runner → 生成物被就地改写（含新列）；
2. 守卫为「不改工作区」把生成物 `cp` 回提交版；
3. **下一轮**守卫再跑 → 资产图认为「已是最新」→ `wrote 0 outputs` → 生成物仍
   是旧版 → 与提交版一致 → **报 ✅**。

即同一个坏状态，第一轮报漂移、第二轮报「一致」。修法：比对前**先删掉输出**
（实测：删输出后 `wrote 28 outputs`，不删则 `wrote 0`）。这是本守卫第一版
实测踩到的坑。

**坑 4：`diff | head` + `pipefail` 会在还原文件之前中止。** `set -o pipefail`
下，`diff | head -20` 在 diff 输出**既超过 20 行、又超过管道缓冲（64KB）**时让
diff 收到 SIGPIPE，整个脚本以 141 退出——**在把生成物还原回去之前**。实测后果：
门禁报失败，却把重新生成的文件留在工作区。

⚠️ 两个条件缺一不可：只有「超过 64KB」而**只有 5 行**（单个超长行）时，head
会把它们全读完正常退出，SIGPIPE 根本不发生。故修法是落到临时文件再 head。

#### 守卫自己的测试（`check_codegen_selftest.sh`）

四个坑各自钉一条可重跑的断言，共 8 组用例（干净通过 / 检出漂移 / 幂等 /
还原 / 大 diff / 构建失败 / 调 format / 在包目录执行）。

**为什么造临时仓库而不是改真仓库**：直接改 `database.dart` 再 revert 只能在
本地手动跑，且容易忘 revert（本轮开发中真的踩到过，留下过一个
`packages/spb_data/lib/src/thing.g.dart`）。故在 `mktemp -d` 里造一个最小仓库，
用**桩 `dart`** 替换真命令。

⚠️ **桩必须模拟增量资产图**（输出已存在 → `wrote 0 outputs` 且不碰文件），
否则用例 3（非幂等）是空转——实测：桩写成「每次都写出」时，把守卫的
`rm -f "$f"` 去掉，自测仍然通过。

⚠️ **每轮用例前要 `git checkout` 回干净态**：有坑的守卫会留下脏文件，使后续
用例全部失真（实测：把守卫改回 `diff | head` 后，是「非幂等」和「未还原」两条
先炸，而用例 5 自己的断言因状态被污染不再触发，报错指向错误的原因）。

#### 反向验证（逐条实测）

| 去掉/改坏 | 自测结果 |
|---|---|
| 去掉「比对前删输出」（坑 3） | ✅ 检出（生成物不同步却报通过） |
| 去掉 `dart format`（坑 2） | ✅ 检出（未调用 format） |
| 不在包目录里跑（坑 1） | ✅ 检出（干净状态即失败） |
| 改回 `diff \| head`（坑 4） | ✅ 检出（SIGPIPE 提前退出） |
| 去掉还原 | ✅ 检出（工作区变脏 + 非幂等） |

#### 顺带清理

- `melos.yaml` 的 `gen` / `gen:watch` 原本在**仓库根**跑（坑 1 的空转），
  且带已被 build_runner 2.5+ **静默忽略**的 `--delete-conflicting-outputs`
  （`W These options have been removed and were ignored`）。现已 `cd` 进包目录
  并去掉该 flag。
- `tools/coverage.sh` 文件头原写「`database.g.dart` 占 `spb_data` 分母的 78%
  （1591/2049）」——分母已随表定义漂移为 2002（79%）。已修正并注明 1591 是
  lcov 的**可执行行数**（`LF`）而非文件行数（3912）。
- AGENTS.md [§6.2](architecture.md) 原称「`melos run gen` 对本包为空」——该说法在只有 `spb_data`
  有生成物后已不准确（应是「只跑 spb_data」），已修正。

### 6.22 SSE 传输层测试 + 一个真实的数据损坏缺陷（issue #41）

**测试**：`packages/spb_api/test/sse_client_test.dart`（31 条）。

#### 为什么之前没测

`sse_client.dart` 的 149 行里只有 **1 行**被执行（0.7%）。它是**唯一**「上层用
Fake 测 + 自己不被测」的层：四个测试文件各自 `class _FakeSseClient extends
SseClient` 并 override 掉 `connect` / `frames` / `states` / `recordEventId`，
**没有一处构造真实实例**。归约层有 881 条用例，传输层 0 条。

#### 怎么测（不碰真实网络）

用自定义 `HttpClientAdapter` 喂**受控字节流**。不用 `http_mock_adapter`：它按
URL 匹配返回整体响应，无法表达「同一响应被切成多个分片」——而那正是传输层最
容易错的地方。

两个辅助适配器：

| 适配器 | 用途 |
|---|---|
| `_ChunkAdapter` | 把响应体切成指定分片（可逐字节切） |
| `_ControllableAdapter` | 流**不自行结束**，测试手动 `push` / `addError` / `endStream` |

⚠️ `_ControllableAdapter` 每次 `fetch` 都新建一个 `StreamController`：单订阅流
只能 listen 一次，而 `resume()` / 退避重连会发起第二次连接。

#### ⚠️ 测出来的真实缺陷：分片切开的 UTF-8 被静默损坏

原实现对**每个分片**独立调 `utf8.decode(bytes, allowMalformed: true)`，注释写
「容忍分片切开的 UTF-8 多字节序列」——但 `allowMalformed` 的语义是「解不出就
替换成 U+FFFD」，**不是**「缓冲到下一个分片」。当分片边界落在汉字 3 字节序列的
中间时，两个分片各自解出 `�`，且**不可恢复**：

```
分片1: 'data: {"t":"�'      // 「中」只到了第 1 个字节
分片2: '��文"}'              // 后两个字节各自解成 U+FFFD
拼接:  'data: {"t":"���文"}' // 期望 'data: {"t":"中文"}'
```

后果：**中文回复在网络分片恰好落在汉字中间时显示成乱码**，且只在分片边界出现
——本机跑（通常一个分片装下整个响应）永远复现不了。

修法：改用 `Utf8Decoder.startChunkedConversion`（增量解码，跨分片保留不完整
序列）。每次 `_openStream` 重建 sink，新连接不得携带上一个连接的不完整字节。

#### 测试覆盖的契约

| 组 | 钉住的契约 |
|---|---|
| 分片与行缓冲 | 逐字节切分不变（含中文）、UTF-8 跨分片不损坏、CRLF、不完整行留到下次 |
| 字段解析 | 多行 data 用 `\n` 拼接、冒号后单个空格、无冒号行忽略、`id`/`retry`、`_pendingId ?? _lastEventId` 兜底 |
| 心跳注释帧 | `: heartbeat` 产生注释帧、**不得清空已累积的 data** |
| 游标续接 | 首次 connect **不带** cursor、connect 重置 lastEventId、`recordEventId` 忽略空串、resume 带上游标 |
| 状态机 | connect → connected → close → idle、流结束 → reconnecting |
| 退避与重连上限 | 指数退避 `1s,2s,4s…` 封顶、**401/403 不重连**、5xx 可重试、close 后不重连 |
| 响应体异常 | 非 DioException 被兜底、流中途 onError、响应体为 null |
| dispose | 两个流控制器都被关闭 |

#### 两个易写错的测试点

1. **`ResponseBody.fromString` 的流发完即 done** → 立刻触发 `onDone` →
   `reconnecting`。要观察稳定的 `connected` 态（或要在帧之间做动作）必须用
   `_ControllableAdapter`。
2. **`_pendingId` 不随帧清空**（符合 SSE 规范）→ 同一连接内「带 id 帧 → 不带
   id 帧」时后者从 `_pendingId` 就能拿到值，`?? _lastEventId` **走不到**。兜底
   真正生效的是「`_teardown` 清空 `_pendingId` 之后、重连的第一帧不带 id」。

#### 反向验证（逐条实测，7 项全部被检出）

| 改坏 | 失败用例数 |
|---|---|
| 去掉 `_pendingId ?? _lastEventId` 兜底 | 1 |
| 多行 data 拼接改成覆盖写 | 2 |
| 去掉 401/403 停止重连 | 1 |
| 退避改成常数 | 3 |
| 去掉心跳识别 | 3 |
| 增量解码改回逐分片 `utf8.decode` | 2 |
| 去掉 `recordEventId` 的空串守卫 | 1 |

覆盖率：`sse_client.dart` **0.7% → 98.1%**（153/156），`spb_api` 整包
72.3% → 82.6%。剩余 3 行是 `_openStream` 的 `catch (e, st)` 防御分支
（dio 会把适配器抛出的异常包成 `DioException`，该分支实际不可达）。

### 6.24 全局错误兜底与静默吞异常（issue #45）

#### 问题：诊断通道建好了，却没接上「异常」这个主来源

issue #40 实现了「导出诊断日志」（环形缓冲 + 环境信息 + 脱敏，[§6.20](runtime-and-ops.md)），但它
的**输入只有显式走 `SpbLog` 的日志**。异常若没被 `try/catch` 包住，就进不了
环形缓冲——用户导出的报告里**不会有它**。而 release 构建下未捕获的异步异常
是**静默丢弃**的（Flutter 默认只在 debug 打印），于是「应用莫名其妙没反应」
这种最需要诊断的场景恰好没有任何记录。

#### 三道防线（**不重叠**，缺一漏一类）

| 来源 | 钩子 |
|---|---|
| Flutter 框架（build/layout/paint 抛出的） | `FlutterError.onError` |
| 平台/引擎层的异步异常（未 await 的 `Future` 拒绝等） | `PlatformDispatcher.onError` |
| 当前 Zone 里的同步/异步异常（含 `main` 自身抛出的） | `runZonedGuarded` |

只装 `FlutterError.onError` 就抓不到 `Future.delayed(...).then((_) => throw ...)`
——那走的是引擎投递路径。

实现：`packages/spb_platform/lib/src/global_error_handler.dart` 的
`installGlobalErrorHandlers`，两端 `main()` 的**第一步**（早于 `SpbLog.configure`；
`SpbLog` 默认 sink 就是 `ConsoleLogSink` + info 级，故早期异常不会被丢）。

#### 三个易写错的点

1. **必须保留 `FlutterError.presentError`**（且链式调用上一个 handler）。
   debug 下的红色错误屏幕是开发体验的核心——替换掉它是「为了线上诊断牺牲
   开发效率」的坏交易。有用例钉住「上一个 handler 仍被调用」。
2. **`PlatformDispatcher.onError` 必须返回 `true`**（或沿用上一个 handler 的
   判定）。不返回 true 时某些平台会**直接终止进程**。
3. **`main` 不 `await` 它**。`runZonedGuarded` 的签名就是 `void`；写成
   `await` 会引入「body 异常已被 Zone 捕获、外层 Future 也已失败」的双重报告。

#### 为什么放 `spb_platform` 而不是 `spb_core`

`FlutterError` / `PlatformDispatcher` 来自 `package:flutter/foundation.dart`，
而 `spb_core` 是**纯 Dart 包**（§4，`check_layering.sh` 强制）。

#### 静默 catch：三处必修 + 一条守卫

`outbox.dart` 的三处 `catch (_) {}` 是**完全静默**的：

| 位置 | 失败后用户看到什么不一致 | 级别 |
|---|---|---|
| `upsert(failed)` | 重启后「已耗尽重试」的条目又回到 `pending` 继续重试 | `warn` |
| `upsert(updated)` | 退避时间没落盘 → 重启后首次投递时刻偏早 | `debug` |
| `store.delete`（终态） | 重启后条目「复活」→ 重复投递（幂等键兜底） | `debug` |
| `onConnectivityRestored` 的落盘循环 | 重启后首次投递时刻偏后 | `debug` |

都不导致数据丢失（内存态是对的），但会让「重启后的行为」与「用户看到的」
不一致，且**开发者无从知晓**。

同批补日志的还有：`sync_scope_config.decode`（坏值回退成「全部同步」是
**用户看不见**的语义变化，`warn`）、`ChatStreamController._onFrame` 的载荷
无法解析（事件被整个丢弃 → 时间线上一个缺口，`warn`）、`pendingConfirmationCount`
（角标为 0 与「确实没有待确认」视觉上无法区分，`debug`）、两端 group 标题
预取（「未知对话」占位与真名无法区分，`debug`）、`cachedUserId`（`debug`）、
`habits_page` / `pending_confirmations_page` 的非 `SpbError` 分支（SnackBar
之外无迹可寻，`error`）。

⚠️ **不得记录载荷全文**：SSE 载荷可能含用户输入，而诊断报告会被贴进公开
issue（[§6.20](runtime-and-ops.md) 的安全红线）。只记长度与类型。

#### 守卫：`tools/check_silent_catches.sh`

判定规则（两类，**269 处 catch 全部通过**）：

| 形态 | 要求 |
|---|---|
| `catch (_)` | 体内第一条语句是注释，**或**体内有 `SpbLog.` |
| `catch (e)` 但 `e` **从未被引用** | 同上（`e` 只是占位符） |

⚠️ **不要**把规则扩到「`catch (e)` 且 `e` 被引用但没记日志」——那会命中
100+ 处「捕获 → 映射成 `SpbError` → rethrow」的正常写法（如
`on DioException catch (e) { throw mapDioError(e); }`），淹没在误报里，没人会看。
这是本守卫**零误报**的关键。

用注释而非白名单：白名单会随重构腐化（文件改名后条目失效而没人清理），且
新增的静默 catch 需要「记得去加白名单」——正是本守卫想避免的「靠人记得」。

`tools/check_silent_catches_selftest.sh` 钉住 6 条：空体必报错（含**嵌套花括号
后**的空体，防止配对写错导致漏检）、带注释放行、`throw mapXxx(e)` 放行（假红
会让守卫被加进忽略列表）、`catch (e)` 未使用必报错、带 `SpbLog` 放行。

#### 反向验证（逐条实测）

去掉 `installFlutterErrorHandler` → 2 条失败；去掉 `installPlatformErrorHandler`
→ 3 条；`PlatformDispatcher` 不返回 true → 1 条；把 `FlutterError.onError`
改成**替换**而非链式 → 1 条；outbox 三处日志各去掉 → 各 1 条；
`sync_scope_config` 的 warn 去掉 → 1 条；SSE 载荷日志去掉 → 2 条；
守卫本身改坏（空体放行）→ 自测 1 条。

#### 有意不做

issue #40 的第 2 层（崩溃上报）仍**有意不做**（[§6.20](runtime-and-ops.md)）——本轮是它「不做上报」
前提下的最低成本补偿：异常至少进了用户能导出的报告。

⚠️ 全局错误处理的**可见行为**（红色屏幕、进程是否存活）需真机验证——本机
无 `DISPLAY`（[§9](../development.md)）。

### 6.25 文档数字守卫与真实标识清理（issue #46）

#### 一、数字漂移（守卫查不到的那一类）

`tools/check_agents_refs.sh`（§6.19）只查**标识符存在性**——查不到数字一致性。
实测漂移：[§6.12](runtime-and-ops.md) 写 `spb_features` 硬编码中文 **808**（实际 878）、全仓 **782**
（实际 1569）；当时另一份清单（`docs/known-issues.md`，已于 2026-11 删除，见 AGENTS.md §11）写总计
**83.4%** 而 §6.13 写 83.8%——**同一事实两处不一致**，且没有任何机制会发现它。

**为什么值得修**：[§6.12](runtime-and-ops.md) 的「重新评估条件 2」是「`spb_features` 硬编码字符串
> 1500」——文档里的「当前值」若长期不准，将来判断「是否触发重评估」时会基于
**错误基线**。

#### `tools/check_agents_numbers.sh`：容差而非精确相等

| 方案 | 问题 |
|---|---|
| 软失败（只提示） | CI 上**永远不会被看到**（没人翻绿构建的日志）——等于没查 |
| 精确相等 | 这些数字**随实现自然增长**（782→808→878）。每加一句中文文案就红一次，很快会有人删掉标记 |
| **容差（选用）** | 小漂移放行（不打扰正常开发），大漂移拦住（防文档烂到误导决策） |

默认容差 **5%**（标记可 `tolerance=` 覆盖）。依据：[§6.12](runtime-and-ops.md) 的阈值是 `> 1500` 而
当前 970——5% 的漂移（约 49 条）远不足以改变「离阈值还有多远」的判断。

**命令定义在脚本里，不在文档的标记里**：两条复现命令**自身含单引号**
（`grep -rhoP "'[^']*[\x{4e00}-\x{9fa5}][^']*'"`），塞进标记属性就得转义、属性解析会先崩。
故标记只写 `name=` 与 `value=`，命令单一定义在脚本的 `CHECKS` 表。

这带来一个额外好处：守卫**断言文档展示的命令与脚本里的逐字相同**（去空白后
比较）——于是「文档教用户跑的」与「守卫实际跑的」不可能漂移。否则用户复现出的
数字与守卫的判定会不一致，而那种不一致**极难排查**。

**为什么覆盖率总计不在检查范围内**：`coverage.sh --summary-only` 读的是已有
产物，而本守卫在 CI 的 quality job 跑（覆盖率步骤在测试之后）——要在这里查就得
重跑全部测试（约 +3 min），而那正是 `coverage.sh` 单独一步、注释里写明「不该让
它影响门禁反馈速度」的原因。§6.13 的表已有显式免责，且覆盖率是**观测**而非
决策基线。

配套 `check_agents_numbers_selftest.sh`（6 条断言）：无标记必报错（防**静默
空转**）、大漂移必报错、容差内放行、文档命令与脚本不一致必报错、未知 `name`
必报错、`tolerance=` 覆盖生效（含「同值不加 tolerance 必须被拒」的对照）。
均已接入 CI。

#### 二、真实生产标识残留

仓库有 `tools/scrub-history.sh`（开源前重写 git 历史），但**全仓文档零引用**它，
且它**假定了工作区已被清理干净**（脚本头写明「把工作区里的域名/IP 换成占位符
只影响新提交」）——而实测工作区**还没清**。顺序反了。

已清理：

| 文件:行 | 内容 | 替换为 |
|---|---|---|
| `docs/m0-manual-verification.md:416` | 生产服务器 IP | 「生产 SSH 别名，见 §部署约定」 |
| 同上 | 内部域名 `idp.atjog.com` | 「IdP 生产地址」 |
| `:92`、`:108` | 本地绝对路径 | `/path/to/super_partyb-flutter` |

并在 §3 的 `tools/` 清单下写明 `scrub-history.sh` 的**使用顺序**（`--dry-run` →
执行 → `--verify`）与关键约束：它**只重写历史**，工作区里的真实标识需**先清
干净**（即本节），否则新提交又把真实值带回来，等于白做。

⚠️ **`scrub-history.sh` 本身完全值无关**（真实值与占位符都从仓库外的映射文件
读，脚本里只出现变量名）——这是刻意的：脚本会入库、会被公开，把映射写进它就
等于**把待清理的目标集中在一处并公开**。

#### 反向验证（逐条实测）

守卫本身改坏：标记删光（空转）→ 自测 1 条失败；大漂移放行 → 1 条；容差内误报
→ 1 条；文档命令改成不同文本 → 1 条；未知 `name` 放行 → 1 条；`tolerance=`
不生效 → 1 条。数字本身：把 [§6.12](runtime-and-ops.md) 的 `value` 改回 808 → 守卫报「偏差 8.0%」。

### 6.26 工程卫生批量（issue #47）

#### 一、`.gitattributes`：`eol=lf` 而不是只写 `text=auto`

仓库同时面向 Linux / Windows / macOS（`windows/`、`macos/` 都在），CI 也在
`windows-2022` 出包。Windows 上 `core.autocrlf=true`（Git for Windows 默认）
会把 `.dart` 检出成 CRLF，而 `tools/check_format.sh` 跑 `dart format
--set-exit-if-changed`——`dart format` **会**把 CRLF 规范化成 LF，于是 Windows
开发者本地**永远**格式检查失败（或提交时被改回 LF，产生整文件 diff）。

⚠️ **只写 `* text=auto` 不够**：那只是「入库时统一成 LF」，Windows 检出时
**仍会**是 CRLF——正是 `dart format` 报错的情形。必须显式 `eol=lf`。

实测（两个受控仓库，同一份源码）：

| 配置 | `autocrlf=true` 检出后的 `.dart` |
|---|---|
| 无 `.gitattributes` | `ASCII text, with CRLF line terminators` ❌ |
| 有 `* text=auto eol=lf` | 保持 LF ✅ |

**`*.png binary` 是最不能删的一条**：12 个 golden 基线 PNG 是**逐字节比对**的，
任何行尾/编码转换都会让它们全部失败，而报错只说「像素不匹配」，指不到根因。

`database.g.dart` 用 `linguist-generated=true` 而**不是** `-diff`：后者会让
`git diff` 完全不显示它，而 `tools/check_codegen.sh` 正是靠比对生成物发现漂移的。

#### 二、依赖自动更新与 action pin

`.github/dependabot.yml`：`pub`（weekly，limit 5，`increase-if-necessary`——
不主动放宽 `pubspec.yaml` 约束）+ `github-actions`（monthly）。

⚠️ **文件头写明前提**：本仓库权威远端是 **Gitea**，若 CI 实际跑 Gitea Actions，
Dependabot 不生效（Gitea 用 Renovate）。保留仍值得：零成本、若镜像 GitHub 即刻
生效、且它本身就是升级策略的书面记录。

**第三方 action pin 到 SHA**（`git ls-remote` 实测取得）：

| action | pin |
|---|---|
| `subosito/flutter-action` | `1a449444c387b1966244ae4d4f8c696479add0b2 # v2.23.0` |
| `android-actions/setup-android` | `be39fa834029ff78f1a44aa3bb0819b8fc2bd8fd # v4.0.4` |

官方 `actions/*` 保留 `@v4`：由 GitHub 维护，且 pin SHA 后 Dependabot 仍能升。
Dependabot **认** `uses: x@<sha> # v2.23.0` 的写法，会把 SHA 与注释一并升级
——故 pin 不会让 action 变成永久不升级的死区。

#### 三、严格分析模式：三项全开（实测 107 → 0）

| 项 | 开前告警 | 分布 |
|---|---|---|
| `strict-casts` | **0** | —— |
| `strict-raw-types` | 4 | `spb_api` 1、`spb_models` 3 |
| `strict-inference` | 103 | 测试 79（16 个文件）、`lib/` 24 |

`lib/` 的 24 条里 21 条是 `_dio.get/post/patch/put/delete` 未写类型参数（dio 的
`Response<T>` 中 T 无约束，无法推断）——显式写 `_dio.get<dynamic>(...)` 即修好
（`_unwrap` 本就接受 `Response` 并取 `data`，`<dynamic>` 正是它期望的）。

79 条测试告警是 JSON 固定数据里的裸集合字面量（`'items': []` →
`'items': <dynamic>[]`，语义不变）。

⚠️ **issue 建议「先只在 `spb_core`/`spb_models` 试开」实测不必要**：三项在
`spb_core` 都是 0，在 `spb_models` 也只有 5+3。修掉 `lib/` 的 25 处 + 测试的
79 处后，三项可**全仓开**——而按包开需拆两份配置，会重新引入「根配置只对
include 了它的包生效」这个静默失效（§6.19 的 `check_analysis_options.sh`
正是为它而设）。

⚠️ **analyzer 的 `language:` 按文件生效，没有「只对 lib」这种写法**。故不要
因为「测试里 79 条太吵」就把它只开在部分目录。

`tools/check_analysis_options.sh` 新增断言：三项严格模式**必须**在根配置里
——删掉任一项，`dart analyze` 依然报「No issues found!」，没有任何 lint 会
提醒门禁少了一层。

#### 四、release notes 由 `git log` 生成（不做 CHANGELOG.md）

`.github/workflows/release.yml` 原来是一份**固定模板**，每版正文相同。现追加
`git log --oneline --no-merges <上一个 tag>..HEAD`（仓库强制 Conventional
Commits，故 `--oneline` 直接可读）。

| 方案 | 取舍 |
|---|---|
| `CHANGELOG.md` | 每版都要人工同步，忘了就腐化 |
| **`git log`（选用）** | 提交历史本就是权威记录，零维护 |

**`actions/checkout` 必须 `fetch-depth: 0` + `fetch-tags: true`**：默认 depth=1
且不带 tag，`git describe --tags` 找不到上一个 tag、`git log` 也列不出提交
——而那是**静默的**（release notes 少一段，没人会注意）。

无上一个 tag（首个发布）时退化为「列最近 50 条」而非让 release 失败——产物
已经构建完成，不该因一段正文而中止。

⚠️ **这个改动触发了一次守卫更新（好事）**：`check_workflow_steps.sh` 原本断言
「`actions/checkout` 不得有 `with`」（那是为了抓「后一个 step 的 with 错挂到
checkout 上」这一历史缺陷）。现在 checkout 确实需要 `with`，故改成**白名单**：
只允许 `fetch-depth` / `fetch-tags`。历史缺陷形态（`merge-multiple` 挂到
checkout）仍被拦住——因为它不在白名单里。

#### 五、`tools/` 清单守卫（`check_agents_refs.sh` 扩展）

§3 的 `tools/` 树是**读者找脚本的唯一入口**。新增守卫后若忘了补文档，读者根本
不知道它存在（`ls tools/` 不会被想起来）。故 `check_agents_refs.sh` 新增**反向
检查**：每个非自测（`*_selftest.sh`）的 `tools/*.sh` 都必须在 AGENTS.md 里被引用。

⚠️ **豁免的是 `*_selftest.sh`（规则，不是白名单）**：每个守卫都配一个，逐个
列进树会让树长一倍；树里已用一行注释说明它们的存在。写反豁免（要求列 selftest）
会让守卫一上线就假红、很快被删；不豁免普通脚本则守卫静默空转。

`tools/` 树本身也已补齐（原列 8 个，实际 14 个非 selftest 脚本）。

#### 新增/修改的守卫自测

| 脚本 | 断言数 | 钉住的风险 |
|---|---|---|
| `check_workflow_steps_selftest.sh` | 5 | 注释形态漏检、合法 checkout `with` 误报、别的 step 的 `with` 错挂、缺 download-artifact、残缺 step |
| `check_agents_refs_selftest.sh` | 4 | 漏列脚本、自测豁免写反、引用不存在的标识符、两个方向同时满足 |

均已接入 CI 与 melos。

#### 反向验证（逐条实测）

删 `strict-inference` → `check_analysis_options.sh` 报「未开启严格模式」（且
`dart analyze` 仍全绿，证明这正是它要拦的静默回退）；workflow 里把
`- uses: actions/download-artifact@v4` 折进注释行 → 自测 1 条失败 + 守卫报
「step 标记落在注释里」/「checkout 的 with 含意外键」；`.gitattributes` 缺失时
`autocrlf=true` 确实产出 CRLF（对照实验）。

### 6.27 测试文件拆分与「真实等待」的实测纠正（issue #48）

issue #48 有三部分。**第一部分（拆文件）成立且已完成；第二部分（「80 处真实
等待」）经实测是错的；第三部分（端到端）已完成。**

#### 一、拆分：11 个文件 → 34 个，全部 < 1500 行

**原状**（实测 `find packages/*/test apps/*/test -name '*.dart'` + `wc -l`）：

| 原文件 | 行数 | 拆成 |
|---|---|---|
| `spb_features/test/chat/conversation_page_test.dart` | 3864 | 6 + `support/conversation_page_harness.dart`(407) |
| `apps/spb_desktop/test/widget_test.dart` | 3750 | 4 + `support/desktop_harness.dart`(706) |
| `spb_domain/test/chat_stream_controller_test.dart` | 3703 | 5 + `support/chat_stream_controller_harness.dart`(313) |
| `apps/spb_mobile/test/widget_test.dart` | 3390 | 4 + `support/mobile_harness.dart`(523) |
| `spb_domain/test/event_reducer_test.dart` | 2765 | 4 |
| `spb_api/test/chat_api_test.dart` | 1966 | 4 + `support/chat_api_harness.dart` |
| `spb_features/test/habit/habits_page_test.dart` | 1536 | 3 + `support/habits_harness.dart`(257) |
| `spb_domain/test/deliverable_sync_test.dart` | 1533 | 3 + `support/deliverable_sync_harness.dart`(228) |
| `spb_domain/test/outbox_policy_test.dart` 等 3 个（原为单个 1116 行文件） | 1116 | 3 + `support/outbox_harness.dart`(121) |
| `spb_features/test/chat/group_list_page_test.dart` | 1033 | （未拆，见下） |
| `spb_features/test/settings/settings_page_test.dart` | 1363 | （未拆，见下） |

⚠️ **issue 原文只列 10 个，漏了 outbox 那个（1116 行）**——它是实测补上的。
（该文件已拆成 `outbox_policy_test.dart` / `outbox_queue_test.dart` /
`outbox_lifecycle_test.dart`，故本文档不再引用旧名。）

**两个「未拆」是有意的**：`group_list_page_test.dart`(1033) 与
`settings_page_test.dart`(1363) 都**低于 1500 行门禁**，且 `settings_page_test.dart`
的用例分在 `_themeModeTests()` / `_userPreferencesTests()` 两个**函数里**（函数内部
再 `group()`），机械按行切会把一个 group 切两半。验收标准是「< 1500 行」，两者已满足。

#### 拆分的两个 harness 模式（**纯移动，不改任何断言**）

| 模式 | 适用 | 做法 |
|---|---|---|
| ① 顶层 `late` 变量 + `setUpHarness()` | helper 在 `main()` 内、被所有用例共享 | 局部闭包提到顶层，**调用点逐字节不变** |
| ② `test/support/<name>_harness.dart` | 文件级 helper（形如下划线开头的私有 fake / mock 声明） | 私有名去下划线 → 公开（跨库不可见，必须去下划线） |

⚠️ **模式 ② 有撞名风险**：`_remote` → `remote` 会与拆分后文件里的局部变量撞名。
脚本用「去下划线后是否已在原文里作为独立标识符出现」判定，冲突则加 `Fixture` 后缀
（实测 3 例：`remoteFixture` / `permissiveFixture` / `gidFixture`）。

⚠️ **`part` / `part of` 不能用来拆测试**：`dart test` 每个文件独立加载，`part`
会让被 part 的文件不被当测试入口。故一律用 `import`。

#### 反向验证：用例名逐条比对

拆分的正确性判据不是「跑绿」（漏搬一个 group 也会绿），而是**拆分前后用例名集合
逐条一致**。脚本用 `flutter test --reporter=json` 抽 `testStart` 事件的 `name`，
排序后 `diff`：

| 包/文件 | 前 | 后 |
|---|---|---|
| `event_reducer` | 150 | 150 ✅ |
| `chat_api` | 94 | 94 ✅ |
| `chat_stream_controller` | 110 | 110 ✅ |
| `conversation_page` | 140 | 140 ✅ |
| `outbox` | 54 | 54 ✅ |
| `deliverable_sync` | 67 | 67 ✅ |
| `habits_page` | 68 | 68 ✅ |
| `spb_desktop` | 81 | 81 ✅ |
| `spb_mobile` | 68 | 68 ✅ |

全仓用例总数 **3408 → 3421**（+13 是新增的端到端用例，拆分本身 0 变化），
覆盖率 **84.6% 不变**（纯搬家）。

#### 二、「80 处真实等待」——**实测不成立**

issue #48 的判据是：

```bash
grep -rnE "await Future\.delayed\(|await tester\.pump\(const Duration\(seconds" ... | wc -l
# → 80
```

⚠️ **这条命令把两件不同的事混在一起了**：

| 形态 | 真实等待？ | 说明 |
|---|---|---|
| `await tester.pump(const Duration(seconds: 2))` | ❌ **不消耗 wall time** | Flutter 测试的**假时钟**，只是把 `FakeAsync` 的时钟往前拨 |
| `await Future.delayed(const Duration(seconds: 2))` | ✅ 真实等待 | 真的睡 2 秒 |

78 个命中**全部是前者**（`tester.pump`），即**零 wall time**。

**对照实验**（受控工程，`50 × tester.pump(const Duration(seconds: 2))`）：

```
>>> 50 × pump(2s) 真实耗时 = 8 ms
```

若是真实等待应为 100000ms。故 issue 的「80 处真实等待」是**统计口径错误**。

**真实的 wall time 只有 2.6 秒**（`Future.delayed` 且位于 `runAsync` 内或纯
`dart test` 里，逐文件累加）：

| 文件 | 真实等待 |
|---|---|
| `spb_domain/test/chat_stream_controller_emit_test.dart` | 890 ms |
| `spb_api/test/sse_client_test.dart` | 750 ms |
| `apps/spb_mobile/test/router_chat_test.dart` | 450 ms |
| 其余 8 个文件 | 534 ms |
| **合计** | **2624 ms** |

这 2.6 秒里**大部分是不可消除的**：`spb_api` 的 750ms 是「真实 `ResponseBody.stream`
需要真实事件循环推进」（该文件注释已写明，本包无 `fake_async` 依赖）；
`spb_domain` 的 890ms 是钉「`scheduleMicrotask` 合并失败 / `Timer(zero)` 成功」
这一调度差异的证据测试（见 [§6.23](chat.md)）——改成 `fakeAsync` 就测不到真实 microtask 时序。

**故 `fakeAsync` 改造的收益接近零**（最多省几秒，且会削弱 [§6.23](chat.md) 的证据力）。
`spb_features` 单包 50 秒的耗时**不是等待造成的**：是 ~1100 个 widget 测试各自的
`pumpWidget` + 布局 + golden 渲染。

> **教训**：写分析类 issue 时，「grep 计数」必须**先验证命中的是什么**。
> 把 `tester.pump(Duration)` 当成真实等待，会让一个「不做也行」的优化看起来
> 像「最该做的优化」。

#### 三、端到端（`sse_end_to_end_test.dart`，13 条）

issue #48 第三部分成立且已做。**此前没有任何测试跨过「真实 socket → 真实分片 →
真实 UTF-8 增量解码 → 真实 SSE 行解析」**——`SseClient` 自己的测试用
`DioAdapter` 造 `ResponseBody.stream`，而上层用 `FakeSseClient`。

**为什么 `DioAdapter` 掩盖了 issue #41 的缺陷**：它一次投递**完整字节数组**，
永远不会把多字节 UTF-8 字符切成两半。issue #41 修的正是「分片切开 UTF-8」
——故那条缺陷**必须**用真实 socket（`dart:io HttpServer`）才能复现。

| 用例 | 覆盖 |
|---|---|
| 基本事件流 / 多行 `data:` 拼接 / `: heartbeat` 注释 | 帧解析 |
| **UTF-8 跨分片**（切在 `E4` 后）/ **逐字节分片**（含 4 字节 emoji） | issue #41 的真实缺陷 |
| `\r\n` 分片 / 同帧逐字节分片 | 行缓冲边界 |
| `Accept: text/event-stream` 头 | CDN 缓冲语义 |
| 首次无 cursor / `resume` 带 cursor / **未 `recordEventId` 不带 cursor** | 游标契约 |
| 401 → `failed` 不重试 / 500 → 退避重连 | 错误分类 |

⚠️ **`recordEventId` 是显式调用，不是自动接管**：`_onText` 收到 `id:` 只写
`_pendingId`，只有上层调 `recordEventId` 才更新 `_lastEventId`。原因是
**Transient 事件（流式增量）的 ID 不能作 cursor**，否则重连会跳过其后的权威帧
（§5.4）。测试里有一条专门钉住「收到过 `id:` 但不调 `recordEventId` 时
`resume` 不带 cursor」，防止将来有人「顺手」把它自动化。

**为什么是纯 Dart 而不是 `integration_test/`**：本文件无 `flutter_test`、无
Flutter 引擎，`dart test` 直接跑，不需要 `DISPLAY`（本机无，[§9](../development.md)）。这**不推翻**
[§6.20](runtime-and-ops.md)「`integration_test/` 第 3 层有意不做」——那个决策针对真机 + UI 集成，
与本文件的成本/收益不同。

**反向验证**：把 `_onBytes` 的增量解码换回「每片独立 `utf8.decode`」（issue #41
修复前的行为）→ **2 条失败**（两个 UTF-8 跨分片用例），其余 11 条仍绿。

**覆盖率**：`spb_api` 82.6% 不变（`sse_client.dart` 的 98.1% 已在 #41 达成），
新增 13 条用例不改变行覆盖（走的是同一条路径，只是入口从 `DioAdapter`
换成真实 socket）。
