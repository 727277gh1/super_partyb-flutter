# AGENTS.md

本文件指导 Claude Code / pi 等 AI Agent 在 **super_partyb-flutter** 仓库中工作。

> 姊妹仓库：[`super_partyb`](../super_partyb)（Go API + Next.js webapp + Taro 小程序）。
> **本仓库只做客户端**，业务真源永远在 `super_partyb/apps/go-api`。

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

# 测试
cd apps/spb_desktop && flutter test   # 桌面端
cd apps/spb_mobile  && flutter test   # 移动端
dart test                             # 纯 Dart 包（spb_core/models/api/domain）

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

### 6.7 无归属入口：两条路径（quick-capture vs enqueue）

桌面端有两类「没有对话 UI 的入口」，**走不同端点，返回语义不同**：

| | `QuickCapturePage` | `OverlayQuickCapturePage` |
|---|---|---|
| 端点 | `POST /me/quick-capture` | `POST /me/quick-capture/enqueue` |
| 附件 | ❌ | ✅ |
| 返回 | **同步**返回归属 `group_id`（可导航） | **异步**投递，只有 `{id, provider}` |
| 落点 | `router_preferences` | 同左（worker 消费后写） |
| 路由 | `/quick-capture` | `/overlay` |

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

### 6.8 剪贴板文件粘贴（待实现）

`readClipboardFiles()`（`spb_platform/lib/src/overlay_files.dart`）已定义契约与降级路径，
但**各平台的原生侧尚未实现**（`MethodChannel('com.atjog.spb/clipboard_files')`）。

- 当前行为：channel 未注册 → `MissingPluginException` → 静默返回空（**不影响文本粘贴**）。
- 缺失影响：用户截图后无法直接 `Ctrl+V` 到悬浮窗，需先存盘再拖入。
- 实现位置：`apps/spb_desktop/{linux,windows,macos}/` 的原生侧。

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

且 macOS runner 在 GitHub Actions 上**按 10× 计费倍数**，成本显著。优先级最低。

### CI 成本参考（私有仓库 Free 计划 2,000 Linux 分钟/月）

| 平台 | 配额倍数 | 单次构建 | 月 20 次 |
|---|---|---|---|
| Linux | 1× | ~7 min | 140（7%） |
| Android | 1× | ~15 min | 300（15%） |
| Windows | **2×** | ~12 min | 500（25%） |
| macOS | **10×** | ~16 min | **3,200（160% ← 必超额）** |

**结论：Linux + Android + Windows 三端全在免费额度内（约 47%）。macOS 是唯一会花钱的。**

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
- [x] 剪贴板文件读取的原生实现（Linux `clipboard_files` channel，见 §6.7）

### M1+：功能实现（**大部分已完成**）

- [x] OIDC 登录（自实现 PKCE + loopback，非 `flutter_appauth`）
- [x] 对话列表 + SSE 实时流（cursor 续接 / 切 group 复用连接 / 加载更早历史）
- [x] 消息发送 + 无归属入口（悬浮窗）
- [x] 交付物同步（单向拉取 + 双向回传与冲突物化）
- [x] 设置页（目录 / 范围 / 媒体开关 / 单文件上限 / 本地清理）
- [x] 移动端：BFF `/chat/miniapp/*` 接入
- [ ] 移动端 OIDC 登录闭环（需 IdP 注册 `partyb://oidc/callback`，见 `docs/mobile-oidc-deeplink.md`）
- [x] CI 流水线（`.github/workflows/ci.yml`：quality / build-linux / build-android / build-windows）
- [x] 发布流水线（`.github/workflows/release.yml`：tag 触发三端出包 → GitHub Release）
- [x] Windows 出包（GitHub Actions `windows-2022`，见 `docs/windows-release.md`）
- [ ] macOS 出包（需 macOS runner，10× 计费，暂不做，见 §8）

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
| macOS 出包需 macOS runner（10× 计费） | 待决策 | §8、`super_partyb` issue #31 |
| Windows 包无代码签名，每次运行弹 SmartScreen | 已知限制 | `docs/windows-release.md` §4 |
| ~~多窗口可行性~~ | ✅ `window_manager` 做不到，改用主窗口临时变身 | §6.5 |
| ~~剪贴板文件粘贴无原生实现~~ | ✅ Linux 原生 channel 已实现 | §6.7 |
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
