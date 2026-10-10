# AGENTS.md

本文件指导 Claude Code / pi 等 AI Agent 在 **super_partyb-flutter** 仓库中工作。

> 姊妹仓库：`super_partyb`（Go API + Next.js webapp + Taro 小程序，**未公开**）。
> **本仓库只做客户端**，业务真源永远在 `super_partyb/apps/go-api`。
>
> ⚠️ 下文出现的 `super_partyb/...` 路径、`api-gateway/...`、`id-provider/...`
> 等**不在本仓库内**，仅作为契约依据的引用。本仓库可独立构建与测试，
> 不需要这些仓库在场（除下节“引用”说明的契约同步工作外）。

---

## 1. 这是什么

用 **Flutter** 实现 Super PartyB 的**桌面端 + 移动端**，取代原 `super_partyb/apps/desktop`（Tauri 薄壳），并新增独立的 iOS/Android App。

### 为什么新增而不是替换整套技术栈

Flutter 是**「加一个端」**，不是「换一套栈」。现有三端全部保留：

| 端 | 技术 | 状态 |
|---|---|---|
| webapp | Next.js 16 + React 19 | **保留**，功能最全，继续演进 |
| 微信小程序 | Taro 4 + React | **保留**，Flutter 不支持小程序，无可替代 |
| 桌面端 | ~~Tauri 2.x~~ → **Flutter** | 本仓库取代 |
| 移动 App | 无 → **Flutter** | 本仓库新增 |

**关键约束：Go API 一行不改。** 客户端适配服务端，不是反过来。任何「为了客户端方便而改 Go API」的提案，必须先证明无法在客户端解决。

### 目标平台

| 平台 | 目录 | 本机可构建 | 说明 |
|---|---|---|---|
| Linux 桌面 | `linux/` | ✅ | 主开发平台，`flutter build linux` |
| Windows 桌面 | `windows/` | ❌ | 需 Windows 主机或 CI，见 §8 |
| macOS 桌面 | `macos/` | ❌ | 需 macOS 主机 |
| Android | `android/` | ✅ | `flutter build apk` |
| iOS | `ios/` | ❌ | 需 macOS 主机 + 签名 |

---

## 2. 常用命令

```bash
# 依赖（workspace 根目录执行，所有包共享一份 lockfile）
flutter pub get

# 静态分析（全量，含分层规则）
dart analyze .
bash tools/check_layering.sh          # 分层规则（纯 Dart 包禁止依赖 Flutter）
bash tools/check_test_support_sync.sh # 跨包重复的测试辅助文件必须逐字节相同

# 测试
cd apps/spb_desktop && flutter test   # 桌面端
cd apps/spb_mobile  && flutter test   # 移动端
dart test                             # 纯 Dart 包（spb_core/models/api/domain）

# 覆盖率（issue #25）——逐包采集并汇总，产物 coverage/lcov.info
bash tools/coverage.sh                # 全包（约 +3 min）
bash tools/coverage.sh spb_domain     # 单包（调试用）
bash tools/coverage.sh --summary-only # 不跑测试，只汇总已有产物

# golden 基线（issue #25）——更新前先确认 diff 是你有意改的！
cd packages/spb_ui     && flutter test --update-goldens test/golden_test.dart
cd packages/spb_features && flutter test --update-goldens test/chat/golden_test.dart

# 构建
cd apps/spb_desktop && flutter build linux --release
cd apps/spb_mobile  && flutter build apk --release

# Linux 分发包（必须：把非系统依赖库打进 bundle，见 §7）
bash tools/bundle_linux_deps.sh

# 代码生成（freezed / json_serializable / riverpod）
dart run build_runner build --delete-conflicting-outputs

# 格式化
dart format .
```

### Melos（可选）

```bash
dart pub global activate melos
melos run analyze      # 等价 dart analyze .
melos run layering     # 等价 bash tools/check_layering.sh
melos run gen          # build_runner
```

---

## 3. 仓库结构

```
super_partyb-flutter/
├── pubspec.yaml              # workspace 根（Dart Pub Workspaces 成员声明）
├── melos.yaml                # 脚本编排
├── apps/
│   ├── spb_desktop/          # 桌面端入口（linux/windows/macos）
│   └── spb_mobile/           # 移动端入口（android/ios）
├── packages/
│   ├── spb_core/             # 基础设施（纯 Dart）
│   ├── spb_models/           # 数据契约（纯 Dart）
│   ├── spb_api/              # HTTP + SSE 传输层（纯 Dart）
│   ├── spb_domain/           # 领域逻辑（纯 Dart）
│   ├── spb_data/             # 本地持久化（drift）
│   ├── spb_design/           # 设计令牌 + 主题
│   ├── spb_ui/               # 通用组件
│   ├── spb_platform/         # 平台能力抽象
│   └── spb_features/         # 功能模块
└── tools/
    ├── check_layering.sh     # 分层规则检查
    └── bundle_linux_deps.sh  # Linux 分发包依赖打包
```

### 依赖方向（**单向，不可逆**）

```
                    ┌──────────────────┐
                    │   apps/*         │  ← 只做「装配」：DI、路由、入口
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  spb_features    │  ← 功能模块（chat/works/settings/sync）
                    └────────┬─────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
┌───────▼──────┐   ┌─────────▼────────┐   ┌───────▼────────┐
│  spb_data    │   │    spb_ui        │   │  spb_platform  │
│  (drift)     │   │  (组件)          │   │  (平台能力)     │
└───────┬──────┘   └─────────┬────────┘   └───────┬────────┘
        │                    │                    │
        │            ┌───────▼────────┐           │
        │            │  spb_design    │           │
        │            │  (令牌/主题)    │           │
        │            └────────────────┘           │
        │                                         │
        └────────────┬────────────────────────────┘
                     │
            ┌────────▼─────────┐
            │  spb_domain      │  ← 领域逻辑（纯 Dart）
            └────────┬─────────┘
                     │
            ┌────────▼─────────┐
            │    spb_api       │  ← HTTP/SSE 传输（纯 Dart）
            └────────┬─────────┘
                     │
            ┌────────▼─────────┐
            │  spb_models      │  ← 数据契约（纯 Dart）
            └────────┬─────────┘
                     │
            ┌────────▼─────────┐
            │   spb_core       │  ← 基础设施（纯 Dart）
            └──────────────────┘
```

**禁止**：
- `spb_domain` → `spb_data` / `spb_ui` / `spb_features`（反向）
- `spb_api` → `spb_domain`（会形成循环）
- 任何 `packages/*` → `apps/*`

`tools/check_layering.sh` 会检查前两条；第三条靠 code review。

---

## 4. 分层规则（**编译器强制**）

### 纯 Dart 包：`spb_core` / `spb_models` / `spb_api` / `spb_domain`

**这四个包禁止 import `package:flutter/*`。**

**为什么**：它们承载「对话归约」「SSE 解析」「契约模型」这些**正确性核心**逻辑。一旦依赖 Flutter，就只能用 `flutter test`（需 Flutter 引擎）来测，无法在无图形环境的 CI 里快速跑纯逻辑单测。

强制手段：
1. `pubspec.yaml` 不声明 `flutter` 依赖；
2. `tools/check_layering.sh` grep 源码中的 `import 'package:flutter/`；
3. CI 里作为独立 job 运行。

**平台差异一律走 `spb_platform` 的接口**，不要在纯 Dart 包里写 `Platform.isAndroid` 分支。`spb_core/env.dart` 里的 `SpbEnv.isDesktop` 是唯一例外（用 `dart:io Platform`，不依赖 Flutter）。

### 判断某个类该放哪一层

| 问题 | 层 |
|---|---|
| 涉及「颜色/间距/字体」？ | `spb_design` |
| 是「按钮/对话框」等无业务语义组件？ | `spb_ui` |
| 是「HTTP 请求/SSE 解析」？ | `spb_api` |
| 是「事件归约/状态机/用例」？ | `spb_domain` |
| 是「本地数据库/缓存」？ | `spb_data` |
| 是「窗口/托盘/快捷键/文件选择」？ | `spb_platform` |
| 是「聊天页/设置页」？ | `spb_features` |
| 是「DI 装配/入口 main」？ | `apps/*` |

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

配置方式（编译期注入，无运行时文件依赖）：

```bash
flutter build linux --release \
  --dart-define=SPB_API_BASE_URL=https://api.example.com/pba \
  --dart-define=SPB_UFS_BASE_URL=https://api.example.com/ufs \
  --dart-define=SPB_ENV=prod
```

见 `packages/spb_core/lib/src/env.dart`。

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
> 见 §6.9。

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
  故 `_syncStaleWatch` 收 `touchedTurnId`，只重排触发者的到期时刻。
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

---

## 6. 关键设计决策

### 6.1 实时流统一用 SSE，**禁止引入 WebSocket**

`chat_stream.go` 的 SSE 端点已具备：cursor 续接、500 条回放、3s 心跳、事件去重。**不要**为了「更实时」或「双向通信」另起 WebSocket——会造成两套事件推送链路，且服务端 broker 是按 userId 的单一订阅模型。

> 例外：小程序有 `/chat/miniapp/ws`（`miniapp_ws.go`），那是微信小程序环境的既有实现（`ws-tickets` 鉴权 + replay），**不在本仓库范围内**。

### 6.2 契约生成 vs 手写

当前**手写**（`spb_models` 镜像 Go 常量），并用测试 + code review 保证同步。

**为什么不立刻上代码生成**：Go → JSON Schema → Dart 的生成链需要先建 `cmd/contractgen`，而事件 payload 是 `map[string]any`（无强类型 schema），生成器只能生成「事件类型常量」这一薄层，收益有限。

**何时该上**：当事件类型 > 50 个，或出现「服务端改了 payload 结构但客户端静默不兼容」的实际事故时。

### 6.3 状态管理：Riverpod

`flutter_riverpod` 3.x。理由：编译期安全、可测试、无需 `BuildContext`。

### 6.4 桌面能力隔离

`spb_platform` 定义 `DesktopCapabilities` 接口，移动端注入 `NoopDesktopCapabilities`。

**所有方法静默降级**（记日志 + 返回 false/null），不抛异常。UI 用 `isSupported` 决定是否展示「托盘/全局快捷键」等设置项。

### 6.5 多窗口：`window_manager` 不行，但可另选插件（M0 结论）

桌面端原计划 3 窗口：主窗 + 设置窗 + `Alt+Space` 悬浮输入窗。

#### ❌ `window_manager` 做不到多窗口

1. 该插件 0.5.2 的**公开 API 里没有任何创建窗口的方法**——`setSize`/`setAlwaysOnTop`/
   `show`/`hide` 全部作用于唯一窗口。
2. Linux 原生侧 `window_manager_plugin.cc:32` 的 `get_window()` 实现是
   `gtk_widget_get_toplevel(view)`：从一个 `FlView` 反查其顶层 `GtkWindow`。
   **一个 engine 只有一个 view，故只能有一个窗口。**
3. `windowManager.getId()` 存在但**无配套 `createWindow`**：它是给 Flutter 未来多窗口
   API 预留的，当前无法用于「再开一个窗」。
4. Flutter 官方多窗口（`flutter config --enable-windowing`）在 3.47.5 仍是
   `(Not set) (Unavailable)`。

#### ✅ 真多窗口存在（但本仓库当前不用）

`desktop_multi_window` **有真实的 Linux 实现**：`linux/multi_window_manager.cc:102`
直接 `fl_view_new` + 独立 `FlDartProject`，每个窗口是**独立 engine**。

未采用它的原因（成本，不是能力）：

- 需额外的 Dart 入口点（`fl_dart_project_set_dart_entrypoint_arguments` 传入的
  `"multi_window"`），`main()` 要按窗口类型分支；
- **每个窗口是独立 isolate**，Riverpod 容器、认证状态、`Dio` 客户端都不共享——
  悬浮窗得自己恢复凭证、自建 API 客户端；
- 插件 0.3.1 直接操作 `GtkWindow` 并手动断开 engine 的 delete-event 信号
  （见 `multi_window_manager.cc` 的 `g_signal_handler_disconnect`），对
  Flutter 引擎版本较敏感。

#### 当前方案：主窗口「临时变身」悬浮窗

在**单窗口**约束下拿到真正的置顶悬浮输入：按 `Alt+Space` 时

1. 保存当前窗口几何（`getBounds`）；
2. 改尺寸为主 `quickCaptureWithAttachments` 规格、`alwaysOnTop=true`、
   `skipTaskbar=true`、居中；
3. 导航到 `/overlay`。

提交或 `Esc` 后恢复几何与窗口标志，回到主界面。见
`PlatformDesktopCapabilities.enterOverlayMode` / `exitOverlayMode`。

**已知差异**：悬浮期间主窗口被「顶替」（看不到背后的对话）。对「快速记一笔」
这个用途可接受，但若将来需要「悬浮窗与主窗同屏」，就得换 `desktop_multi_window`。

### 6.6 桌面端相对 Tauri 的净损失

| 能力 | Tauri | Flutter |
|---|---|---|
| Linux 包 | ✅ | ✅ |
| **Windows 包（本机交叉编译）** | ✅ `cargo-xwin` | ❌ **必须 Windows 主机** |
| 自动更新器 | ✅ `tauri-plugin-updater` | ❌ 需自行实现 |
| 安装包体积 | ~10 MB | ~26 MB |

Windows 交叉编译不可行的根因：`my_app.exe` 是 **MSVC 编译的 C++ runner**，Linux 无 MSVC。Flutter 官方 [issue #110585](https://github.com/flutter/flutter/issues/110585) 开放 3 年未实现。详见 §8。

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

### 6.8 剪贴板文件粘贴（**三平台均已实现**）

`readClipboardFiles()`（`spb_platform/lib/src/overlay_files.dart`）走
`MethodChannel('com.atjog.spb/clipboard_files')`，各平台原生侧**均已注册**：

| 平台 | 实现位置 |
|---|---|
| Linux | `apps/spb_desktop/linux/runner/my_application.cc` |
| Windows | `apps/spb_desktop/windows/runner/flutter_window.cpp` |
| macOS | `apps/spb_desktop/macos/Runner/AppDelegate.swift` |

降级路径仍在：channel 未注册（如单元测试环境、或将来新增未实现平台）时
抛 `MissingPluginException`，函数**静默返回空**——不影响文本粘贴。
原生侧刻意不回 error，避免用户从网页复制文件时看到报错弹窗。

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
| 对话页附件 / `file_context` | Go 的 `sendChatToAgentRequest`（`chat_stream.go:46`）只有 `agent_id` / `input` / `request_id` / `group_id` / `agent_type` / `options` / `routing`，**没有**附件字段。带附件的无归属入口走 `/me/quick-capture/enqueue`（见 §6.7），不是对话页。受「Go API 一行不改」约束，补齐需服务端先加字段。 |
| 移动端打开已下载文件 | 移动端注入 `NoopDesktopCapabilities`，`openFile` / `revealPath` 恒 false。要真正打开需引入 `open_filex` / `share_plus` + Android FileProvider 配置 + 真机验证（模拟器在本机不可用，见 §9）。当前退化为「只读浏览 + 下载」。 |
| 桌面端「通知订阅」区块 | 该区块（`NotificationSubscriptionsCard`）的语义是**微信小程序订阅消息额度**（`miniapp_subscriptions` 表 + `wx.requestSubscribeMessage` 的配额消耗模型）。桌面端没有小程序运行环境，展示它无法兑现；故只在移动端装配（`settings_page.dart` 按 `loadNotifications` 是否注入决定展示）。是否给桌面端一个只读「额度查看」视图需产品确认。 |
| P2 端点族：`fork` / `canvas` / `plan-import` / `decisions` / `file-evolution` / `semantic-search` | 本轮范围外。它们是**考古 / 分析 / 分叉**类能力（`chat_ext.go` 的 `POST /turns/:turn_id/fork`、`GET /groups/:group_id/canvas`、`POST /groups/:group_id/plan/import`；`ext_routes.go:530` 的 `/groups/:group_id/decisions`；`misc_extra.go:649` 的 `file-evolution` 与 `:650` 的 `semantic-search`），承载点是 webapp 的分析视图。留待后续轮次。 |
| 语义 / 图谱搜索四项面板（`SemanticSearchPanel` / `GraphSearchDialog` / `FileEvolutionPanel` / `DecisionEvolutionPanel`） | 同上——它们正是 P2 端点族的 UI 载体。客户端已有**关键词**搜索（`ChatApi.search` → `SearchPage`），语义/图谱是**另一种检索方式**而非「搜索缺失」。详见 §6.9.3 |
| `SkillPanel`（`dashboard/agents/[id]/chat`） | 属管理面，已被 §6.9 的 `/api/skills` 一行覆盖，无需重复实现 |

#### 6.9.2 未接端点族的逐项依据（issue #11 收口）

上表把「不接」的端点族并排列出。本节记**逐项依据**——尤其有两项，issue #11
的原始判断与实测不符，照抄会把错误的理由固化下来。

| 项 | 结论 | 实测依据 |
|---|---|---|
| `tool-agents` 族的 `listToolsets` | ❌ 不接 | 仅 `dashboard/agents/create` 与 `agents/[id]/edit` 使用——确属**管理面** |
| `tool-agents` 族的 `invoke` / `invoke/stream` | ❌ 不接 | **全仓零调用者**（webapp 自己也没接）——服务端为将来留的接口 |
| `tool-agents` 族的 `listToolAgents` | ⚠️ **不是**「只在 dashboard」 | 它喂给 `ChatInputArea`（`chat/[groupId]/page.tsx:638`），选中后经 `setToolAgentForGroup` + `startNewConversation` 以 `agent_type=tool_agent` 发起会话。**这是聊天面行为**，只是客户端已有 `AgentSwitcher`（`/api/agents` + `sessions/switch`）覆盖了「换 agent」这一诉求，且 `switchGroupAgent` / `sendMessage` 都不发 `agent_type`——补齐需两端都动，故本轮不接 |
| `inbox-messages` | ❌ 不接 | webapp 唯一消费者是 `workbench/[groupId]/debug/page.tsx`（排障），与 §6.10「移动端不接诊断面板」同取向。客户端已有**用户级** `PendingMessagesBar`（`/users/:uid/chat/messages/pending`），覆盖了「我的消息还卡着吗」这个真实诉求 |
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
| `WorkbenchBacklogCard` | workbench | ✅ **已实现（载体不同）** | 客户端 `PendingMessagesBar` 消费 `/users/:uid/chat/messages/pending`，同样做「pending 收件箱 + 单条撤销 + 批量合并发送」（webapp 的 `use-pending-messages.ts` 是同一个共享 hook 语义）。它在对话页输入区上方，不在侧边栏——与 §6.10 的载体差异同一取向 |
| `SemanticSearchPanel` / `GraphSearchDialog` / `FileEvolutionPanel` / `DecisionEvolutionPanel` | 聊天 | ❌ 不接（本轮） | 对应 P2 端点族，已登记。**语义搜索是四项里最可行的一项**（端点 `semantic-search` 已在用且被 webapp 命令菜单复用），但仍属新检索面，需单独排期 |
| `WorkbenchGroupCanvas` | workbench | ❌ 不接 | 是**独立路由** `/workbench/[groupId]/canvas`；客户端没有 workbench 路由概念（`SpbRoutes` 只有 chat / search / settings / confirmations 等） |
| `PlanImportPanel` | workbench | ❌ 不接 | 计划导入是 goal 系统的**批量录入**入口，属 webapp 分析视图 |
| `WorkbenchNotificationCenter` | workbench | ❌ 不接 | 「系统通知 / 确认请求 / 新消息提醒」聚合器。客户端已有各自的原生载体（确认页、待处理栏、SSE 实时流），再加一个聚合层需先有产品需求 |
| `SkillPanel` | dashboard | ❌ 不接 | §6.9 已覆盖 |

**关于 `DashboardRenderer` 与 #8 的 `spec` / `dashboard` / `map`**（issue #12 决策点 1）：
这三种渲染器**不是一个决策**，不要捆绑——

| 类型 | 客户端现状 | 结论 |
|---|---|---|
| `spec` | **已有渲染器**：`SpecUiCard` + `parseSpecUi`（12 个白名单 type，消费 `spec_ui` 事件） | 文件预览复用它是**可行的**，但需补一层「从任意 JSON 里提取 schema」（webapp `extractSchemaFromUnknown` 会深度下探，客户端 `parseSpecUi` 只认裸 `{root, elements}`）。属**小活**，已另开 issue #14 |
| `dashboard` | 无渲染器（webapp `DashboardRenderer` 508 行，`{type:"dashboard",components:[...]}` 形状，与 `{root,elements}` **不兼容**） | ⚠️ **待决策** |
| `map` | 无渲染器（webapp `normalizeMapSchema`，`type:"map"` + 坐标） | ⚠️ **待决策** |

故 issue #12 的决策点 1 应缩小为「**是否引入 dashboard / map 渲染器**」（`spec` 已有
基础，不需与它捆绑）。三种渲染器与两个实测真缺口的去向：

| 类型 | 去向 |
|---|---|
| `spec` | 已拆到 **issue #14**（小活，需补 schema 提取） |
| `auto-schedules` | 已拆到 **issue #13**（实测出的真缺口） |
| `dashboard` / `map` | **唯一待决策项**。产品确认前 **issue #12 保持 open** 承载该决策；若确认要做，再另开独立 issue 落地（届时关闭 #12） |

**有意不做的标记**：10 个面板的逐项去向 = **1 已实现**（`WorkbenchBacklogCard`，载体
不同）+ **8 有意不做**（4 个聊天面 P2 面板 + `WorkbenchGroupCanvas` /
`PlanImportPanel` / `WorkbenchNotificationCenter` + `SkillPanel`）+ **1 待决策**
（`DashboardRenderer`，与 #8 的 `map` 同一决策）。`auto-schedules`（issue #13）与
`spec` 文件预览（issue #14）是两个实测出的真缺口，与上述 10 项**不捆绑**。

### 6.10 两端 UI 面板族的不对称（**有意保留的差异**）

同一个「查看这次对话的产出」诉求，两端的载体不同：

| 面板 | 桌面端 | 移动端 |
|---|---|---|
| 交付物（`GroupDeliverablesPanel`） | 侧边栏 tab | AppBar 按钮 → `showModalBottomSheet` |
| 待办（`GroupTodosPanel`） | 侧边栏 tab | AppBar 按钮 → `showModalBottomSheet` |
| 设置（`GroupSettingsPanel`） | 侧边栏 tab | 底部弹层 |
| 任务清单 / 目标历史 | 侧边栏 tab | 底部弹层 |
| **诊断（`GroupDebugPanel`：工具调用 + gate 决策）** | 侧边栏 tab | **无** |

桌面端有侧边栏这个载体（宽屏常驻），移动端没有——小屏放不下常驻侧栏，故移动端
一律走「AppBar 按钮 + 底部弹层」。

**为什么移动端用 `showModalBottomSheet` 而不是新路由**（见
`apps/spb_mobile/lib/router.dart` 的 `_open*` 系列）：

1. **State 共享**：新路由会得到**另一个 `_ChatPage` 实例**，`_group` /
   `_resolvingConfirmations` / 刷新令牌都不共享。设置弹层尤其明显——写成功后
   回写的是那个实例的 `_group`，关掉弹层回到对话页又变回旧值。
2. **busy 态一致**：待办弹层里提交确认卡，时间线内联卡的 busy 态必须同步
   （同一个 `_resolvingConfirmations` 集合）。

**为什么移动端只接 `onDownload`，不接 `onOpen` / `onReveal` / `resolveLocalPath`**：
移动端注入的是 `NoopDesktopCapabilities`，`openFile` / `revealPath` 恒返回 false。
接上会让用户点「打开」得到「无法打开文件」——比不展示该项更让人困惑（面板在回调
为 null 时不渲染对应菜单项）。`resolveLocalPath` 查的是**同步目录**索引，而弹层
回答的是「这个对话产出了什么」（远端），两者用途不同。

**仍不对称：诊断面板**（`GroupDebugPanel`：工具调用 + gate 决策）**目前仅桌面端，
属有意保留**。它是内部排障视图（含工具入参与 gate 决策明细），发布包下由
`showDebugPanelProvider` 关闭；移动端的小屏不适合承载这类高密度内部视图。
`apps/spb_mobile/lib/providers.dart` 里仍定义了同名 `showDebugPanelProvider`，只为
两端 `providers.dart` 同构（避免「某个 provider 只在一端存在」成为下次接线的意外），
当前**无消费方**。

### 6.11 桌面端托盘菜单（6 项）

`apps/spb_desktop/lib/desktop_integration.dart` 的 `_installTrayMenu` 推送 6 个可点项：

| 项 | 动作 |
|---|---|
| 显示主窗口 | `showWindow(main)` |
| 快速输入（Alt+Space） | 进悬浮模式（见 §6.5） |
| 立即同步交付物 | `onSyncNow`（未注入回调时禁用） |
| 打开同步目录 | `caps.revealPath(同步目录)`（**未配置同步目录时禁用**） |
| 同步设置… | `SpbRouter.go(SpbRoutes.sync)` |
| 退出 | `PlatformDesktopQuit.quit` |

**「打开同步目录」为什么在未配置时禁用**：此时 `revealPath` 拿到空串，文件管理器
会落到用户主目录——看起来像「功能坏了」而不是「还没配」。

**「同步设置…」为什么走 `SpbRouter.sync` 而不是 `showWindow(settings)`**：
`WindowRole` 只有 main / settings / quickCapture，没有 sync 这个角色——同步设置是
`/settings/sync` 这个**子页面**，不是独立窗口。`showWindow(settings)` 只会落到设置
页首个 tab，用户还得自己再点一次「同步」，而托盘项的标签承诺的是直达。

**「同步设置…」为什么始终可用**：它正是**配置入口**，禁用会让未配置的用户无法
完成配置（死锁）。

---

## 7. Linux 桌面端系统依赖（**分发必读**）

### 编译期依赖

```bash
# 基础（Debian/Ubuntu）
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libglu1-mesa-dev

# 插件依赖
sudo apt install libkeybinder-3.0-dev          # hotkey_manager
sudo apt install libayatana-appindicator3-dev  # tray_manager
sudo apt install libsecret-1-dev               # flutter_secure_storage
```

**`libkeybinder-3.0-dev` 不是默认安装项**，缺它时报：

```
CMake Error at flutter/ephemeral/.plugin_symlinks/hotkey_manager_linux/linux/CMakeLists.txt:49 (message):
  The `hotkey_manager` package requires keybinder-3.0.
```

**免 sudo 安装路径**（本仓库惯例 `~/.local/opt`）：

```bash
cd /tmp && mkdir kb && cd kb
apt-get download libkeybinder-3.0-dev libkeybinder-3.0-0
for f in *.deb; do dpkg-deb -x "$f" root/; done
PREFIX="$HOME/.local/opt/keybinder"
mkdir -p "$PREFIX/lib/pkgconfig"
cp root/usr/lib/x86_64-linux-gnu/libkeybinder-3.0.so.0.0.0 "$PREFIX/"
cp -r root/usr/include "$PREFIX/"
cd "$PREFIX" && ln -sf libkeybinder-3.0.so.0.0.0 libkeybinder-3.0.so && ln -sf libkeybinder-3.0.so.0.0.0 libkeybinder-3.0.so.0
sed -e "s|^prefix=.*|prefix=$PREFIX|" -e "s|^libdir=.*|libdir=\${prefix}|" \
    -e "s|^includedir=.*|includedir=\${prefix}/include/keybinder-3.0|" \
    /tmp/kb/root/usr/lib/x86_64-linux-gnu/pkgconfig/keybinder-3.0.pc > "$PREFIX/lib/pkgconfig/keybinder-3.0.pc"

export PKG_CONFIG_PATH="$HOME/.local/opt/keybinder/lib/pkgconfig:$PKG_CONFIG_PATH"
```

### 分发：**必须**跑 `bundle_linux_deps.sh`

```bash
cd apps/spb_desktop && flutter build linux --release
cd ../.. && bash tools/bundle_linux_deps.sh
```

**为什么必须**：`libkeybinder-3.0.so.0` 若装在非标准前缀，构建产物会把该**绝对路径写进 RUNPATH**，结果「开发机能跑、分发即挂」。

脚本做两件事：
1. 把非系统库复制进 `bundle/lib/`；
2. 用 `patchelf` 修正 RUNPATH。

⚠️ **RUNPATH 修正的关键细节**：主程序在 `bundle/`，插件在 `bundle/lib/`，**两者 `$ORIGIN` 不同**：

| 目标 | 正确 RUNPATH | 错误写法 |
|---|---|---|
| `bundle/spb_desktop` | `$ORIGIN/lib` | `$ORIGIN` |
| `bundle/lib/*.so` | `$ORIGIN` | `$ORIGIN/lib` ← 指向不存在的 `bundle/lib/lib`，加载器回退到开发机绝对路径 |

`patchelf` 不在 Debian 默认安装项，同样可走 `apt-get download patchelf` + `dpkg-deb -x` 到 `~/.local/bin`。

### 验证分发包自包含

```bash
cd apps/spb_desktop/build/linux/x64/release/bundle
LD_LIBRARY_PATH= ldd spb_desktop | grep "not found"     # 应无输出
for f in lib/*.so*; do patchelf --print-rpath "$f"; done # 不应出现 /home/
```

---

## 8. 构建平台限制

### Windows：**本机（Linux）无法构建**

```console
$ flutter build windows
"build windows" only supported on Windows hosts.
```

根因：`my_app.exe` 是 MSVC 编译的 C++ runner，Flutter 的 `windows/runner/` 就是这套 CMake + C++ 源码。Linux 无 MSVC。

Flutter 检查的硬性依赖（`packages/flutter_tools/lib/src/windows/visual_studio.dart`）：

```dart
static const _requiredWorkloads = <String>[
  'Microsoft.VisualStudio.Workload.NativeDesktop',  // 或关系，命中其一即可
  'Microsoft.VisualStudio.Workload.VCTools',
];
// 必需组件
'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'   // MSVC x64/x86 build tools
'Microsoft.VisualStudio.Component.VC.CMake.Project'   // C++ CMake tools
```

**GitHub `windows-latest` runner 全部预装**（已逐条比对 [runner-images Windows2025 清单](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md)）：VS2022 Enterprise + NativeDesktop 工作负载 + Windows SDK + CMake + VSWhere + **Inno Setup 6.7.1**，**只差 Flutter SDK**。

最小 CI job：

```yaml
windows:
  runs-on: windows-latest
  steps:
    - uses: actions/checkout@v4
    - uses: subosito/flutter-action@v2
      with: { flutter-version: '3.47.5', channel: stable, cache: true }
    - run: flutter config --enable-windows-desktop
    - run: flutter pub get
    - run: flutter build windows --release
    - name: Bundle VC++ runtime      # ← 见下「坑 1」
      shell: pwsh
      run: |
        $vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
        $crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT" -Directory | Sort-Object Name -Descending | Select-Object -First 1
        Copy-Item "$($crt.FullName)\*.dll" build\windows\x64\runner\Release\
    - uses: actions/upload-artifact@v4
      with: { name: windows-release, path: build/windows/x64/runner/Release/ }
```

**三个坑**：

1. **VC++ 运行库不在产物里**：`Release/` 只有 `flutter_windows.dll` / `my_app.exe` / `data/`，**没有** `msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`。目标机未装 [VC++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist) 会**直接闪退且报错不友好**。必须手动拷贝（上面的 pwsh 步骤）。
2. **`windows-latest` 正迁往 VS 2026**：Flutter 3.47.5 已适配（`cmakeGenerator` 有 `'Visual Studio 18 2026'` 分支）。要可复现就锁 `runs-on: windows-2022`。
3. **MSIX 沙箱内崩溃**：`flutter_windows.dll` 在 MSIX 沙箱内崩溃（`INVALID_POINTER_READ` @ `FlutterWindowsViewController::engine`），**同样产物直接跑不崩**。且薄壳类应用需声明 `internetClientServer` / `runFullTrust` 能力，否则网络调用 hang。**建议先用 zip / Inno Setup 分发，暂不碰 MSIX。**

### macOS / iOS：需 macOS 主机

macOS runner 在 GitHub Actions 上**按 10× 计费倍数**，成本显著（见下节）。

#### macOS 出包（已在 `release.yml` 实现，仅 tag 触发）

不需要 Apple Developer 账号：Flutter 的 macOS 模板在 project 级设了
`CODE_SIGN_IDENTITY = "-"`（**ad-hoc 签名**）。Apple Silicon **强制要求**
二进制至少被 ad-hoc 签过，故不能像 iOS 那样「完全跳过签名」。

两个易踩的点：

1. **打包必须用 `ditto`，不能用 `zip`**。`.app` 是目录，内含符号链接
   （Frameworks 里大量使用）与可执行位；`zip` 会把符号链接存成普通文件、
   丢掉权限位，解压后签名校验失败、app 启动即崩。
2. **Release 默认产出 universal（arm64 + x86_64）**，无需显式指定 `ARCHS`。

代价：产物未用 Developer ID 签名也未公证，用户首次打开被 Gatekeeper
拦下，需右键→打开，或 `xattr -dr com.apple.quarantine <app>`。

#### ✅ 已修复：macOS 交付物同步写用户所选目录

`Release.entitlements` / `DebugProfile.entitlements` **两份都已包含**：

```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

（修复于 commit `2f5d778`。此前两份 entitlements 均缺该键。）

**为什么必须有这一项**（别删，删了就回退）：`file_selector` 的 macOS README
明确要求它（沙箱下访问用户所选目录）。交付物同步会用 `LocalFileSink` 向用户
选定的同步目录写文件，**缺这一项沙箱会拒绝**，表现为「同步报写入失败」。
debug 构建沙箱较松可能不暴露，**只在正式包上现形**——与上面
`network.client` 的陷阱同型。

改动这两份文件后请顺手核对本段，避免再次出现「代码已修、文档说没修」的漂移。

### iOS：必须 Apple Developer 账号

无法像 macOS 那样 ad-hoc 凑合——需 $99/年账号 + 签名证书 + 描述文件。

### CI 成本参考（私有仓库 Free 计划 2,000 Linux 分钟/月）

| 平台 | 配额倍数 | 单次构建 | 月 20 次 |
|---|---|---|---|
| Linux | 1× | ~7 min | 140（7%） |
| Android | 1× | ~15 min | 300（15%） |
| Windows | **2×** | ~12 min | 500（25%） |
| macOS | **10×** | ~16 min | **3,200（160% ← 必超额）** |

**结论：Linux + Android + Windows 三端全在免费额度内（约 47%）。macOS 是唯一会花钱的。**

发布流水线据此做了限制：macOS job **只在 tag 触发时跑**（见 `.github/workflows/release.yml`），
PR 与手动触发均不跑——避免日常开发白烧 10× 额度。

---

## 9. 开发环境

### 本机（Debian 12, LXC 容器）

| 项 | 值 |
|---|---|
| Flutter | 3.47.5 stable（Dart 3.13.4） |
| 安装位置 | `~/.local/opt/flutter` |
| Android SDK | `~/.local/share/android-sdk`（build-tools 35/36、platforms 35/36、NDK r28c） |
| `~/.zshenv` | `PATH` / `PUB_CACHE` / `JAVA_HOME` / `ANDROID_HOME` |

```bash
export PATH="$HOME/.local/opt/flutter/bin:$HOME/.local/bin:$PATH"
export PUB_CACHE="$HOME/.local/share/pub-cache"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export ANDROID_HOME="$HOME/.local/share/android-sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
```

### 已知环境限制

| 限制 | 影响 | 说明 |
|---|---|---|
| **无 `/dev/kvm`** | Android 模拟器**不可用** | LXC 容器未透传。宿主 `kvm_amd` 已加载且 `nested=1`，CPU 有 `svm`——**只是设备节点缺失**。修复需在 PVE 宿主 LXC 配置加 `lxc.cgroup2.devices.allow: c 10:232 rwm` + `lxc.mount.entry` |
| **无 `DISPLAY`** | GUI 交互**无法验证** | 可用 `xvfb-run` 验证「进程能启动、窗口能创建」，但**无法验证交互**（点击、拖拽、悬浮窗焦点） |
| 无 Windows/macOS | 无法出对应包 | 见 §8 |

### 无头验证的边界

`xvfb-run` 下**渲染不稳定**（实测同一命令有时窗口创建成功，有时停在 10x10 占位窗）。**不要把「Xvfb 下窗口出现了」当作渲染正确的证据**。

可可靠验证的：
- ✅ `dart analyze` 无问题
- ✅ `flutter test` 通过
- ✅ `flutter build linux --release` 成功
- ✅ `ldd` 无缺失动态库
- ✅ 进程能启动并存活（`timeout 15 ./spb_desktop` 退出码 124 = 正常）
- ✅ Impeller 初始化（日志 `Using the Impeller rendering backend`）

**需真机/有桌面环境手测**：多窗口、托盘、`Alt+Space`、OIDC 登录回跳、交付物同步。

---

## 10. 待办与里程碑

### M0：骨架验证（**已完成**）

- [x] 工作区搭建（Pub Workspaces + melos）
- [x] 分层骨架（9 packages + 2 apps）
- [x] `dart analyze` 全绿
- [x] Linux release 构建成功（26 MB，自包含）
- [x] 核心代码：错误类型 / 日志 / 契约模型 / SSE 客户端 / 事件归约
- [x] ~~多窗口可行性~~ → `window_manager` **做不到**；改用「主窗口临时变身」（见 §6.5）
- [x] 托盘 + 全局快捷键（`bootstrap.dart` 已接 `window_manager`/`tray_manager`/`hotkey_manager`）
- [x] **OIDC 登录打通**（桌面端 RFC 8252 §7.3 loopback 授权码流程，见 `docs/rfc8252-loopback-signin.md`；粘贴导入为降级路径）
- [x] 剪贴板文件读取的原生实现（Linux/Windows/macOS 三平台 `clipboard_files` channel，见 §6.8）

### M1+：功能实现（**大部分已完成**）

- [x] OIDC 登录（自实现 PKCE + loopback，非 `flutter_appauth`）
- [x] 对话列表 + SSE 实时流（cursor 续接 / 切 group 复用连接 / 加载更早历史）
- [x] 消息发送 + 无归属入口（悬浮窗）
- [x] 交付物同步（单向拉取 + 双向回传与冲突物化）
- [x] 设置页（目录 / 范围 / 媒体开关 / 单文件上限 / 本地清理）
- [x] 移动端：BFF `/chat/miniapp/*` 接入
- [ ] 移动端 OIDC 登录闭环（需 IdP 注册 `partyb://oidc/callback`，见 `docs/mobile-oidc-deeplink.md`）
- [x] CI 流水线（`.github/workflows/ci.yml`：quality / build-linux / build-android / build-windows）
- [x] 发布流水线（`.github/workflows/release.yml`：tag 触发四端出包 → GitHub Release）
- [x] Windows 出包（GitHub Actions `windows-2022`，见 `docs/windows-release.md`）
- [x] macOS 出包（GitHub Actions `macos-14`，ad-hoc 签名 + 通用二进制，**仅 tag 触发**）
- [ ] iOS 出包（需 Apple Developer 账号 $99/年 + 签名证书，无法 ad-hoc 凑合）

### CI / 发布流水线速查

| 文件 | 职责 | 触发 | 产物保留 |
|---|---|---|---|
| `.github/workflows/ci.yml` | **验证**：analyze / format / layering / test / 能否构建 | push main + PR | Actions 7 天 |
| `.github/workflows/release.yml` | **交付**：三端出包 + 建 Release | `v*` tag + 手动 | Release 长期 / Actions 30 天 |

发布构建的地址参数（API/UFS/webapp/OIDC）由仓库 **Variables** 提供
（Settings → Secrets and variables → Actions → Variables），优先级：
`workflow_dispatch` 输入 > Variables > `SpbEnv` 内置默认值。

> ⚠️ **公开仓库里 Variables 是全局可见的**（与 Secrets 不同）。
> 不要把内网主机名或未公开域名填进去；不宜公开的地址改用 dispatch 输入。

Android 正式签名走 **Secrets**（`ANDROID_KEYSTORE_BASE64` / `ANDROID_STORE_PASSWORD` /
`ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD`）；未配置时回退 debug 签名并打印警告。

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

---

## 11. 已知问题

| 问题 | 状态 | 参考 |
|---|---|---|
| Android 模拟器不可用（`/dev/kvm` 未透传） | 待决策 | `super_partyb` issue #30 |
| macOS 包未签名/未公证，首次打开需绕过 Gatekeeper | 已知限制（免签名分发） | §8 |
| iOS 出包需 Apple Developer 账号 | 待决策 | §8、`super_partyb` issue #31 |
| Windows 包无代码签名，每次运行弹 SmartScreen | 已知限制 | `docs/windows-release.md` §4 |
| ~~macOS 交付物同步写用户所选目录需 `user-selected.read-write` entitlement~~ | ✅ 已修复（commit `2f5d778`，两份 entitlements 均已含该键） | §8 |
| ~~多窗口可行性~~ | ✅ `window_manager` 做不到，改用主窗口临时变身 | §6.5 |
| ~~剪贴板文件粘贴无原生实现~~ | ✅ 三平台原生 channel 均已实现（Linux/Windows/macOS） | §6.8 |
| ~~IdP 是否支持 PKCE + 自定义 scheme~~ | ✅ 已改为 loopback 方案；IdP 支持 PKCE，loopback 端口通配由 fosite 原生支持 | `docs/rfc8252-loopback-signin.md` |
| IdP 生产未注册桌面 public client | **当前登录阻塞项**（粘贴导入可降级） | `docs/rfc8252-loopback-signin.md` §7 |
| 契约同步靠人工 | 可接受 | §6.2 |

---

## 12. 提交约定

Conventional Commits，scope 用包名或平台：

```
feat(api): 实现 SSE 断线续接
fix(domain): 权威帧未替换累积增量
chore(desktop): 补充 keybinder 分发依赖
docs: 补充 Windows 构建限制
```

**不要**提交：
- `build/`、`.dart_tool/`、`*.g.dart`（生成物）— 见 `.gitignore`
- `--dart-define` 的生产密钥（走 CI secrets）
- `apps/*/android/key.properties`、`*.jks`、`*.keystore`

---

## 13. 相关文档

| 文档 | 位置 |
|---|---|
| Windows 下载与出包 | `docs/windows-release.md` |
| Go API 契约与业务逻辑 | `super_partyb/AGENTS.md` |
| Tauri 桌面端（迁移来源） | `super_partyb/apps/desktop/README.md` |
| 微信小程序（BFF 可复用） | `super_partyb/apps/miniapp/README.md` |
| SSE 服务端实现 | `super_partyb/apps/go-api/internal/server/chat_stream.go` |
| 事件类型真源 | `super_partyb/apps/go-api/internal/chatbus/broker.go` |
| Flutter 官方 Windows 构建 | https://docs.flutter.dev/platform-integration/windows/building |
| Flutter 官方 Windows 分发 | https://docs.flutter.dev/deployment/windows |
