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

# CI 用 `flutter pub get --enforce-lockfile`：lockfile 与 pubspec.yaml 不一致时
# 显式失败。改完依赖请把根 `pubspec.lock` 一起提交（它是唯一那份，**不要**加进
# `.gitignore`）——只提交 lockfile 不够，还得保证 CI 用的是它，见 issue #35。

# 静态分析（全量，含分层规则）
dart analyze .
bash tools/check_layering.sh          # 分层规则（纯 Dart 包禁止依赖 Flutter）
bash tools/check_test_support_sync.sh # 跨包重复的测试辅助文件必须逐字节相同
bash tools/check_workflow_steps.sh    # workflow 的 step 没被注释吞掉（见 issue #32）
bash tools/check_analysis_options.sh  # 成员包都引用了根 analysis_options（见 issue #34）
bash tools/check_wiring_parity.sh     # 两端对共享组件的接线一致（见 issue #33/#39/#42）
bash tools/check_unused_deps.sh       # 没有「声明但零 import」的依赖（见 issue #36）
bash tools/check_agents_refs.sh       # AGENTS.md 引用的标识符真实存在、tools/ 脚本都被列出（见 issue #37/#47）
bash tools/check_silent_catches.sh    # 静默吞异常的 catch 必须有说明或日志（见 issue #45）
bash tools/check_agents_numbers.sh    # AGENTS.md 标注了复现命令的数字不得漂移（见 issue #46）
bash tools/check_codegen.sh           # 提交进 git 的 .g.dart 与源文件一致（见 issue #43）
bash tools/check_format.sh            # dart format 门禁

# 守卫自测（每个都钉住对应守卫的假绿/假红风险；改守卫时必跑）
bash tools/check_wiring_parity_selftest.sh
bash tools/check_workflow_steps_selftest.sh
bash tools/check_codegen_selftest.sh
bash tools/check_agents_refs_selftest.sh
bash tools/check_agents_numbers_selftest.sh
bash tools/check_silent_catches_selftest.sh

# 测试
cd apps/spb_desktop && flutter test   # 桌面端
cd apps/spb_mobile  && flutter test   # 移动端
dart test                             # 纯 Dart 包（spb_core/models/api/domain）

# 覆盖率（issue #25）——逐包采集并汇总，产物 coverage/lcov.info
# 默认剔除生成代码（*.g.dart / *.freezed.dart / *.gr.dart，见 §6.13）
bash tools/coverage.sh                # 全包（约 +3 min）
bash tools/coverage.sh spb_domain     # 单包（调试用）
bash tools/coverage.sh --summary-only # 不跑测试，只汇总已有产物
COVERAGE_INCLUDE_GENERATED=1 bash tools/coverage.sh --summary-only  # 含生成代码的原始数字

# golden 基线（issue #25）——更新前先确认 diff 是你有意改的！
cd packages/spb_ui     && flutter test --update-goldens test/golden_test.dart
cd packages/spb_features && flutter test --update-goldens test/chat/golden_test.dart

# 构建
cd apps/spb_desktop && flutter build linux --release
cd apps/spb_mobile  && flutter build apk --release

# Linux 分发包（必须：把非系统依赖库打进 bundle，见 §7）
bash tools/bundle_linux_deps.sh

# 代码生成（drift：spb_data 的 database.g.dart）
#
# ⚠️ 当前**只有 spb_data** 用代码生成（drift_dev）。spb_models 是手写
# fromJson，已不再声明 freezed / json_serializable（issue #36，见 §6.2）。
#
# ⚠️ **必须 cd 进包目录**。在仓库根跑 `dart run build_runner build` 是**静默
# 空转**（根包没有 build_runner 依赖、没有 build.yaml，实测 `wrote 0 outputs`）
# ——这正是 issue #43 里 CI 守卫差点写成空转的那条命令。
#
# ⚠️ 生成物**不是** `dart format` 的形态，跑完必须格式化，否则与仓库里
# 提交的那份对不上（详见 tools/check_codegen.sh 文件头）。
cd packages/spb_data && dart run build_runner build && dart format lib && cd ../..
# 或者：melos run gen（已指向包目录）

# 格式化
dart format .
```

### Melos（可选）

```bash
dart pub global activate melos
melos run analyze      # 等价 dart analyze .
melos run layering     # 等价 bash tools/check_layering.sh
melos run gen          # build_runner（仅 spb_data；已指向包目录）
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
    # 守卫（每个 check_*.sh 都配一个 check_*_selftest.sh；自测脚本本身
    # 不在下方重复列出，避免树过长——用 `ls tools/` 看全量）
    ├── check_layering.sh           # 分层规则检查（纯 Dart 包禁依赖 Flutter）
    ├── check_workflow_steps.sh     # workflow step 结构检查（未被注释吞掉）
    ├── check_analysis_options.sh   # 静态分析配置接线检查（成员包都引用根配置）
    ├── check_wiring_parity.sh      # 两端装配层接线一致性检查
    ├── check_codegen.sh            # 生成物漂移检查（提交进 git 的 .g.dart 必须与源同步）
    ├── check_unused_deps.sh        # 「声明但零 import」依赖检查
    ├── check_agents_refs.sh        # AGENTS.md 标识符引用检查
    ├── check_agents_numbers.sh     # AGENTS.md 数字漂移检查（容差 5%）
    ├── check_silent_catches.sh     # 静默吞异常检查（空 catch 必须留痕）
    ├── check_format.sh             # dart format 门禁
    ├── check_test_support_sync.sh  # 跨包重复的测试辅助文件必须逐字节相同
    # 工具
    ├── coverage.sh                 # 逐包覆盖率采集 + 汇总表（剔除生成代码）
    ├── bundle_linux_deps.sh        # Linux 分发包依赖打包（非系统库 + RUNPATH）
    ├── reverse_verify_issue50.sh   # 双栈降级/升级的变异验证（就地改代码再还原，见 §5.1.1）
    ├── sync-to-github.sh           # 导出 HEAD 为单提交干净仓库并推 GitHub（值无关，见 §6.29）
    └── scrub-history.sh            # 开源前重写 git 历史里的真实标识（值无关，见脚本头）
```

⚠️ **`scrub-history.sh` 的使用顺序**（`--dry-run` → 执行 → `--verify`）见脚本头。
关键约束：它**只重写 git 历史**，工作区里的真实标识需**先清干净**（见 §6.25）
——否则新提交又会把真实值带回来，等于白做。它还需要仓库外的映射文件
（`SPB_OS_MAP`，含真实值，绝不入库）。

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

---

## 6. 关键设计决策

### 6.1 实时流统一用 SSE，**禁止引入 WebSocket**

`chat_stream.go` 的 SSE 端点已具备：cursor 续接、500 条回放、3s 心跳、事件去重。**不要**为了「更实时」或「双向通信」另起 WebSocket——会造成两套事件推送链路，且服务端 broker 是按 userId 的单一订阅模型。

> 例外：小程序有 `/chat/miniapp/ws`（`miniapp_ws.go`），那是微信小程序环境的既有实现（`ws-tickets` 鉴权 + replay），**不在本仓库范围内**。

### 6.2 契约生成 vs 手写

当前**手写**（`spb_models` 镜像 Go 常量），并用测试 + code review 保证同步。

**为什么不立刻上代码生成**：Go → JSON Schema → Dart 的生成链需要先建 `cmd/contractgen`，而事件 payload 是 `map[string]any`（无强类型 schema），生成器只能生成「事件类型常量」这一薄层，收益有限。

**何时该上**：当事件类型 > 50 个，或出现「服务端改了 payload 结构但客户端静默不兼容」的实际事故时。

⚠️ **决策的落实（issue #36）**：既然决定手写，`spb_models` 就**不得**再挂着
freezed / json_serializable / build_runner / json_annotation / freezed_annotation
这五个依赖——它们从未产出文件（0 个 `@freezed` / `@JsonSerializable`，0 个
`.g.dart`），`melos run gen` 只跑 `spb_data`、对本包为空。曾出现「既没享受到
生成器的一致性保证，又承担了解析成本」的状态。现已删除，并由
`tools/check_unused_deps.sh` 守住。

⚠️ **手写的代价由 `tools/check_codegen.sh` 部分抵消**（issue #43）：它守的是
「提交进 git 的生成物与源文件同步」。当前唯一被跟踪的生成物是 `spb_data` 的
`database.g.dart`——`spb_models` 手写意味着它**没有**这层保护，契约漂移仍靠
人工比对 Go 常量（见 §5.4）。

### 6.3 状态管理：Riverpod

`flutter_riverpod` 3.x。理由：编译期安全、可测试、无需 `BuildContext`。

⚠️ 它只被**装配层**（`apps/*`）依赖，不在 `packages/spb_features` 里——
后者只拿注入进来的回调与数据（见 §6.17 的接线守卫）。同理 `go_router` 也是
装配层的。若将来要让 `spb_features` 内部直接用 Provider，需重新论证分层（它
会打破「功能模块不依赖 DI 容器」这一取向）。

### 6.4 桌面能力隔离

`spb_platform` 定义 `DesktopCapabilities` 接口，移动端注入 `NoopDesktopCapabilities`。

**所有方法静默降级**（记日志 + 返回 false/null），不抛异常。UI 用 `isSupported` 决定是否展示「托盘/全局快捷键」等设置项。

⚠️ **接口在本包，实现（与插件依赖）在 `apps/spb_desktop`（issue #36）**：
`window_manager` / `tray_manager` / `hotkey_manager` / `screen_retriever` /
`launch_at_startup` 只被 `apps/spb_desktop/lib/bootstrap.dart` 的
`PlatformDesktopCapabilities` 使用，故它们声明在**桌面端 app** 的 pubspec 里。
此前声明在 `spb_platform` 会让这些桌面插件**传递进移动端构建**（移动端注入
`NoopDesktopCapabilities`，用不到却要编译）——实测移出后移动端
`.flutter-plugins-dependencies` 不再列出它们，而桌面端仍正常注册。

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
| 语义 / 图谱搜索四项面板（`SemanticSearchPanel` / `GraphSearchDialog` / `FileEvolutionPanel` / `DecisionEvolutionPanel`） | 同上——它们正是 P2 端点族的 UI 载体。客户端已有**关键词**搜索（`ChatApi.search` / `searchMyTurns` → `SearchPage`），语义/图谱是**另一种检索方式**而非「搜索缺失」。且语义搜索的数据面为空（`chat_groups` = 0）、两个「演化」面板的数据源已停写——详见 §6.9.6 |
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
| `SemanticSearchPanel` / `GraphSearchDialog` / `FileEvolutionPanel` / `DecisionEvolutionPanel` | 聊天 | ❌ 不接（本轮） | 对应 P2 端点族。**决策依据不只「属 P2」**——还有三条生产实测：客户端搜索面已闭环（载体不同）、语义搜索的数据面为空（`chat_groups` = 0 行）、两个「演化」面板的数据源（`chat_decisions` / `file_versions` / `replies`）**在 Go 时代已停写**。⚠️ 嵌入链路本身**是通的**（`bore` 隧道 + 共享凭证），别误记为「未接嵌入服务」。详见 §6.9.6 |
| `WorkbenchGroupCanvas` | workbench | ❌ 不接 | 是**独立路由** `/workbench/[groupId]/canvas`；客户端没有 workbench 路由概念（`SpbRoutes` 只有 chat / search / settings / confirmations 等） |
| `PlanImportPanel` | workbench | ❌ 不接 | 计划导入是 goal 系统的**批量录入**入口，属 webapp 分析视图 |
| `WorkbenchNotificationCenter` | workbench | ❌ 不接 | 「系统通知 / 确认请求 / 新消息提醒」聚合器。客户端已有各自的原生载体（确认页、待处理栏、SSE 实时流），再加一个聚合层需先有产品需求 |
| `SkillPanel` | dashboard | ❌ 不接 | §6.9 已覆盖 |

**关于 `DashboardRenderer` 与 #8 的 `spec` / `dashboard` / `map`**（issue #12 决策点 1）：
这三种渲染器**不是一个决策**，不要捆绑——

| 类型 | 客户端现状 | 结论 |
|---|---|---|
| `spec` | **已有渲染器**：`SpecUiCard` + `parseSpecUi`（12 个白名单 type，消费 `spec_ui` 事件） | ✅ 已实现——文件预览复用需补一层「从任意 JSON 里提取 schema」（webapp `extractSchemaFromUnknown` 会深度下探，客户端 `parseSpecUi` 只认裸 `{root, elements}`）。已另开 issue #14 |
| `dashboard`（网格格式） | ✅ **已闭环——不做**。真实 `dashboard.spec.json` 走的是 `spec` 路径，网格格式**无已知生产者**（详见下节） | ✅ 不做 |
| `map` | ✅ **已实现**（issue #12）：`MapSpecCard`（`CustomPaint` 归一化轨迹图）+ `parseMapSchema` / `MapProjection`（`spb_domain`）。**零新依赖**——详见下节 | ✅ 已完成 |

故 issue #12 的三个决策点**已全部闭环**（`spec` / `map` 已实现，`dashboard` 网格格式
无生产者，四项检索面板有生产实测依据）。三种渲染器与两个实测真缺口的去向：

| 类型 | 去向 |
|---|---|
| `spec` | 已拆到 **issue #14**（小活，需补 schema 提取）——⚠️ 但 #14 **引入了一个回归**，见 issue #27（**已修**） |
| `auto-schedules` | 已拆到 **issue #13**（实测出的真缺口） |
| `map` | ✅ **已完成**（issue #12）：`spb_domain` 的 `parseMapSchema` / `MapProjection` + `spb_features` 的 `MapSpecCard`，接入 `agent_file_preview.dart`（`MapTextPreview` 分支）与两端 router（`openMapMarker` → 高德外链）。**零新依赖** |
| `dashboard`（网格格式） | ✅ **不做**（已闭环）。真实 `dashboard.spec.json` 走的是 `spec` 路径（客户端已支持，见 #14 / #27）；网格格式**无已知生产者**——全仓搜该形状只命中一个**测试用例**（`mapspec_test.go:84` 的负例） |

#### 6.9.4 `dashboard` / `map` 的真实成本（**核实后修正早期判断**）

`#14` 的代码注释曾写「`dashboard` / `map` 需**各自的渲染技术栈**」「`map` 需
**底图**」——**与上游实测不符**，会把小活估成引 SDK 的大活。核实结果：

| 判断 | 实测事实 | 证据 |
|---|---|---|
| 「`map` 需底图 / 渲染技术栈」 | ❌ **错**。webapp `MapSchemaRenderer.tsx` 自称「一期轻量实现：**SVG 归一化轨迹图（无底图、无高德 JS key 依赖）**」，实现是 ~25 行投影数学（经纬度 → SVG 坐标，等比缩放 + 居中）+ marker 列表 + 「在高德地图打开」外链。**没有 SDK、没有瓦片、没有密钥** | `super_partyb` `apps/webapp/src/components/features/workbench-ui/MapSchemaRenderer.tsx:6`、`buildProjection` `:43` |
| 「`dashboard` 需重型渲染组件」 | ⚠️ **要分两个渲染器**。① `DashboardRenderer.tsx`（`{type:"dashboard",components:[{type,layout}]}` 网格）只认 **3 个**类型：`stat-cards` / `table` / `chart`，共 **364 行**；② `JsonUiSchemaRenderer.tsx`（`{root,elements}`，即本客户端的 `spec`）。「重型」主要指 ②（`chart` 的 pie/bar/line/area 需图表库，webapp 用 `recharts`） | `DashboardRenderer.tsx:76/124/297`、`package.json` 的 `recharts` |
| 「`dashboard.spec.json` 是网格格式」 | ❌ **错**。上游**真实产出**的 `dashboard.spec.json` 是 **②的 `{root,elements}` 形状**（`Stack`/`Grid`/`Metric`/`Chart`/`Alert`/`Table`） | `super_partyb` `apps/miniapp/src/lib/spec-demo-fixtures.ts` 的 `realDashboardDoc`（注释自称「bcc 工作区实际产出的 dashboard.spec.json 回归基准」）；生产者是 `agent-skills` 的 `json-spec-builder`（其 SKILL.md 明写产出 `root`/`elements`） |
| 网格格式有生产者吗 | **未找到**。全仓搜 `{type:"dashboard", components:[...]}` 只命中一个**测试用例**（`mapspec_test.go:84` 的「非 map 类型」负例） | `super_partyb` `apps/go-api/internal/workers/agentfilerender/mapspec_test.go:84` |

**推论**：`dashboard` / `map` 的决策比原先设想的**轻得多**——

- `map`：**纯 SVG，零新依赖**，Flutter 用 `CustomPaint` 或 `Transform` + `Positioned` 即可；
- `dashboard`：**真实产出走的是 `spec` 路径**（客户端已识别），缺的是**白名单覆盖**
  与**未知容器下钻**，不是新渲染器。网格格式（`DashboardRenderer`）**没有已知生产者**，
  可按「不做」处理。

⚠️ 但核实同时暴露了 **issue #27**（`#14` 的回归）：真实看板虽被识别为 `spec`，
却因 `unknown` 分支不递归 `children` 而退化成一行占位符——**修 #27 比做网格
`dashboard` 渲染器更紧要**（前者影响现存真实产物，后者无生产者）。

#### 6.9.5 `map` 已落地（issue #12）：实现要点与三个「不要重做」的坑

`map` 的核实结论（§6.9.4）已兑现为代码：`spb_domain` 的 `parseMapSchema` /
`parseMapPolyline` / `MapProjection` + `spb_features` 的 `MapSpecCard`。

**分层归属**（按 §4 的判据）：解析 + 投影数学在 `spb_domain`（纯 Dart，可无
图形环境测）；`CustomPaint` 绘制在 `spb_features`。投影数学是**正确性核心**
（错一点整张图就偏），必须能在纯 Dart 测试里逐点断言。

| 要点 | 结论 | 为什么 |
|---|---|---|
| 底图 / SDK | **不做** | 上游 `MapSchemaRenderer.tsx` 自称「一期轻量实现：SVG 归一化轨迹图（无底图、无高德 JS key 依赖）」。归一化轨迹图回答「这些点在哪、相对关系如何」——正是产物要表达的。要看真地图，点一行走高德外链 |
| 坐标顺序 | polyline 是 `[经度, 纬度]` | 高德惯例；`parseMapPolyline` 同时接受字符串形态 `"lng,lat;lng,lat"`（服务端两种都写过） |
| 判定位置 | **只认顶层 `type: "map"`**，不做深度下探 | 与 webapp 一致（`normalizeMapSchema(parsed)`）。若像 `spec` 那样深度扫，「任意 JSON 里嵌了一个 `{type:"map"}` 的配置对象」会被误判成地图 |
| 空壳处理 | `markers` / `routes` 全空（或无坐标）→ `parseMapSchema` 返回 `null` | 否则预览框会变成**一张空图**——比显示原文差 |
| 缺字段 | 距离 / 耗时 / 模式标签缺失时**不显示**（不写「0 米」「未知」） | 同 §5.4 的 `schedule_created`：没有证据就不编造 |
| 外链 | `amapMarkerUrl` = `uri.amap.com/marker?position=lng,lat&name=…`，经 `AgentFilePreviewCallbacks.openMapMarker` 上抛 | URL 拼接留在**装配层**（同 `openExternal` 的既有约定）：页面只收集意图，不掌握第三方 URI 形状 |
| 无障碍 | 轨迹图是 `CustomPaint`，对屏幕阅读器**完全空白** → 必须给语义标签（「地图轨迹图，公交路线，2 个地点，1 条路线」） | 同 issue #24 对 `SpecUiCard` 进度条的判据：自绘区域必须自己说明「这是什么」 |
| 列表封顶 | 地点列表 `maxHeight: 180` + 内滚 | 对齐 webapp 的 `max-h-[180px] overflow-y-auto`。不封顶时 200 个地点会把卡片撑到几千像素——作为**内联卡片**会直接溢出（实测 50 行 = 1000px，RenderFlex overflow） |

**投影的一个有意偏离**（`MapProjection.build`）：以**数据包围盒中心**为基准施加
跨度下限，而不是 webapp 的「从 `min` 角固定」。两者在跨度**未被抬高时完全等价**
（`center - span/2 == min`），故真实多点产物逐像素一致；差别只在单点 / 极近点时
——webapp 会把单点画到视口左上角（实测 x=146, y=16 而视口 560×300），看起来像
「范围很大、点在角落」。以中心为基准后单点落在视口正中。

**反向验证**（每条修复都能被对应用例抓住，否则用例是空转）：去掉 map 分支 →
2 条失败；大小写敏感 → 1 条；去掉空壳守卫 → 1 条；去掉列表封顶 → 1 条
（`1000.0 > 180.0`）；`hasAny` 计入 `openMapMarker` → 1 条；失败静默 → 1 条。

**#27 已修**（未知容器下钻 + 保留原始 type 字符串），且修的过程中又发现并修掉
两个**既有**缺陷（都不是 #27 引入的，而是递归下钻路径的前置条件）：

- **渲染层用了扁平子树**：`_SpecElementView` 曾用 `childrenOf`（**整棵子树的
  扁平列表**）当「直接子元素」，而对每个子元素又递归一次 → 深层元素**渲染多次**
  （实测 3 层树的叶子出现 **2 次**）。改用新增的 `directChildrenOf`。
- **渲染路径无环检测**：解析层的 `visited` 只保护 `childrenOf`，**保护不到渲染
  层的递归**。`A→B→A` 两个互相引用的未知容器实测**直接栈溢出**。现在渲染层
  自带祖先集合。

**由此得出的通用规则**：解析层的安全边界（环/深度/悬空）**不自动继承**给渲染层
——只要渲染层自己递归，就必须自带同样的保护。

**有意不做的标记**：10 个面板的逐项去向 = **1 已实现**（`WorkbenchBacklogCard`，载体
不同）+ **8 有意不做**（4 个聊天面 P2 面板 + `WorkbenchGroupCanvas` /
`PlanImportPanel` / `WorkbenchNotificationCenter` + `SkillPanel`）+ **1 已闭环**
（`DashboardRenderer` 网格格式，无已知生产者，按「不做」处理）。`auto-schedules`
（issue #13）、`spec` 文件预览（issue #14）与 `map` 文件预览（issue #12）是三个
实测出的真缺口，与上述 10 项**不捆绑**。

#### 6.9.6 四项检索面板的决策依据（2026-10 生产核实）

§6.9.3 把四项检索面板（`SemanticSearchPanel` / `GraphSearchDialog` /
`FileEvolutionPanel` / `DecisionEvolutionPanel`）记为「不接（本轮）」。
决策依据**不只是「属 P2 端点族」**，还有三条 2026-10 实测出来的事实：

**1. 客户端的搜索面已经闭环（载体不同）。** 客户端有 `SearchPage`，两端已接线：

| 端点 | 客户端方法 | 语义 |
|---|---|---|
| `GET /me/turns/search?q=` | `ChatApi.searchMyTurns` | 跨 group 按**输入文本**搜轮次 |
| `GET /users/:uid/chat/search?q=` | `ChatApi.search` | 按 `input_text` / `agent_id` 搜 |
| `GET /me/turns?days=` | 同页数据源 | 列近期轮次 |

故四项里的「搜索」不是缺口，而是**另一种检索方式**（语义/图谱）。

**2. 语义搜索的数据面是空的——但原因**不是**「未接嵌入服务」。**

⚠️ 先纠正一个容易得出的**错误**结论。静态读码会以为「生产未接嵌入服务」，
但实测**嵌入链路是活的**：

| 层 | 实测（2026-10-11） |
|---|---|
| 启动日志 | `embedding_resolver:true`，且 `chatrouter` **真的调了**嵌入：`POST http://127.0.0.1:43001/v1/embeddings` |
| `43001` 端口 | `bore` 隧道（`bore server --min-port 40000 --max-port 50000`，systemd `bore.service` active）——上游是**远端**嵌入服务 |
| 凭证 | `service_name='embedding'` 的 3 个键均为 `owner_type='shared'`，`EMBEDDING_BASE_URL = http://127.0.0.1:43001/v1`，`secret_ref` / `plain_value` 均有值 |
| 连通性 | 连发 5 次 `POST /v1/embeddings` 均得 **401**（0.15–0.18s）——**服务在，只是无凭据时拒**；说明隧道通、上游在 |
| `embeddings` 表 | 4807 行（`user_message` 3629 / `turn_input` 562 / `reply` 316 / `topic` 300），最近写入 2026-10-09 |

真正的阻碍是**数据面**，而不是链路：

- `recallEntities` 先调 `resolveVisibleGroupIDs`（`misc_extra.go:901`）→ `ListVisibleGroupIDs`
  （`graph_search_manual.go:316`）的 SQL 是
  `SELECT id FROM chat_groups WHERE user_id = ? AND status = 'active'`；
- 生产 `chat_groups` = **0 行** → `groupIDs` 为空 → `recallEntities` **直接返回空
  列表**（不报 503，因为它在开头就 `if len(groupIDs) == 0 { return []semanticHit{}, nil }`）。

即：面板接上去会得到**「搜索无结果」**（而非错误），而这不是客户端的问题。

**3. 两个「演化」面板的数据源在 Go 时代已停写。** 生产库（2026-10-11）：
`chat_decisions` = **0**、`file_paths` = **0**、`file_versions` = **0**、`replies` = **0**。
`replies` 的注释已自述「在 Go 时代不再写入（`ReplyProjector` 停用）」
（`misc_extra.go` 的 `chain` 注释）。故 `DecisionEvolutionPanel` /
`FileEvolutionPanel` 即使接上也是空面板——**无数据可演化**。

**结论**：四项维持「有意不做」。若将来要做，**前置条件是服务端先恢复对应数据
链路**（`chat_groups` / `chat_decisions` / `file_versions` 的写入），而不是客户端先动。
语义搜索本身**不需要**再配嵌入凭证——它已经通了。

> ⚠️ **与 #12 无关的一个生产异常（另行跟踪）**：2026-10-11 实测 bcc
> `/opt/<app>/data/dev.db` 的 `chat_turns` / `chat_groups` / `chat_events` /
> `chat_confirmations` **全为 0**，而 2026-09-27 的备份里 `chat_turns` 有 **3559** 行。
> 该库 2026-10-10 22:54 被一份**备份覆盖**过（`dev.db.bak-before-del-baixiaosheng-
> 20261010T225140Z.db`，两者 md5 不同），而「删除百晓生」的迁移 0040 已在库中
> 记录为已执行。故当前库是一份**缺 chat_* 数据的状态**，而 `topics`（2669）/
> `user_memories`（2290）/ `embeddings`（4807）仍在。⚠️ **影响面**：`SearchPage`
> （关键词搜索）与四项语义/演化面板**都**依赖这些表，故目前均无结果——需在
> `super_partyb` 侧单独排查（本仓库代码不受影响）。

### 6.10 两端 UI 面板族的不对称（**有意保留的差异**）

同一个「查看这次对话的产出」诉求，两端的载体不同：

| 面板 | 桌面端 | 移动端 |
|---|---|---|
| 交付物（`GroupDeliverablesPanel`） | 侧边栏 tab | AppBar 按钮 → `showModalBottomSheet` |
| 待办（`GroupTodosPanel`） | 侧边栏 tab | AppBar 按钮 → `showModalBottomSheet` |
| 设置（`GroupSettingsPanel`） | 侧边栏 tab | 底部弹层 |
| 任务清单 / 目标历史 | 侧边栏 tab | 底部弹层（窄屏从**溢出菜单**进，见 §6.16） |
| 对话内搜索 | AppBar 图标（`enableSearch: true`） | **溢出菜单**（窄屏无余量，见 §6.15 / §6.16） |
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

### 6.12 i18n：**当前不做**（决策记录，issue #23）

**结论：客户端暂不接入国际化（i18n），界面文案保持硬编码中文。**

这是一个**决策**，不是缺口。本节存在的意义就是让后来者不必重新论证一遍——
若要推翻，请先读完下面「重新评估条件」并给出满足其中一条的事实。

#### 当前硬编码量（可复核）

```bash
# ⚠️ 下面的数字**会漂移**（随实现自然增长）。以命令实测为准，别把这里当权威
# 数字——与 §6.13 的覆盖率基线同一约定。`tools/check_agents_numbers.sh` 会
# 核对本节的数字（只查「标注了复现命令」的这几处，见 §6.19 的守卫清单）。

# 决策时（issue #23 创建于 f446250）的基线：782
# 当前（HEAD）量：878
cd packages/spb_features && grep -rhoP "'[^']*[\x{4e00}-\x{9fa5}][^']*'" --include=*.dart lib | wc -l
# <!-- number-check: name=spb_features_hardcoded_zh value=878 -->

# 全仓（9 个 packages + 2 个 apps 的 lib/）
# 决策时基线：约 1200（未单独记录）；当前（HEAD）量：1569
grep -rhoP "'[^']*[\x{4e00}-\x{9fa5}][^']*'" --include=*.dart packages/*/lib apps/*/lib | wc -l
# <!-- number-check: name=repo_hardcoded_zh value=1569 -->

# 是否已接入 i18n（应为空输出）
grep -rn 'AppLocalizations\|flutter_localizations\|package:intl' --include=*.dart packages/*/lib apps/*/lib
grep -rn 'localizationsDelegates\|supportedLocales' --include=*.dart apps/*/lib
```

量级分布（HEAD，字符串字面量数）：`spb_features` 878、`spb_domain` 172、
`spb_desktop` 149、`spb_models` 97、`spb_mobile` 89、`spb_platform` 67、
`spb_api` 62、`spb_data` 39、`spb_core` 8、`spb_ui` 5、`spb_design` 3。

⚠️ **`spb_core` 从 0 涨到 8 是 issue #40/#45 引入的**（诊断报告文案、错误分类
文案）——正是「为什么不做」第 1 条说的「文案有一半在纯 Dart 层」的实例：领域/
基础设施层的文案随功能增加而增长，而它们**不在 Widget 里**。

#### 为什么不做

1. **真正的成本不在 Widget 层，而在纯 Dart 层**。文案并非只出现在 `build()` 里：
   `SpbError.message`（`spb_core`）、`GoalGateStoppedItem.message`（`spb_domain`，
   reason → 中文的映射，且需与 miniapp 逐条一致）、`ConfirmationNotificationText`
   （`spb_domain`，OS 通知标题/正文）、`TextPreviewPayload` 的失败原因等都是
   **纯 Dart 生成的字符串**——这正是它们能被无头单测的原因（见 §4）。
   做 i18n 就得把这些文案改成「消息码 + 参数」，并把 locale 穿进 `spb_domain` /
   `spb_core`。那是一次**跨包重构**，不是「加几个 ARB 文件」；而把 locale 穿进去
   会让这四个纯 Dart 包第一次依赖「当前语言」这个环境态，可测性与分层约束
   （§4）都要重新论证。
2. **成本此刻并不「最便宜」**。issue #23 正文的判断是「越晚越贵」，这对
   「文案只活在 Widget 里」的项目成立；但本仓库的文案有一半在领域层，晚做的
   边际成本主要来自**领域层文案的耦合**，而那一层是稳定的（reason 枚举、错误
   分类不随 UI 迭代变化）。UI 层字符串增长快但提取机械、可增量做。
3. **无明确目标语言**。webapp 有完整的 `next-intl` 国际化（`messages/en.json` +
   `zh.json`，各约 1830 条），但那是**浏览器场景**：locale 来自 HTTP 头/URL，
   且已有双语用户。客户端是原生 App，locale 来自 OS 设置，而当前产品用户群是
   中文用户——引入 en 只会得到一个**没人验证过的英文界面**（比中文硬编码更糟：
   用户以为有英文支持，点进去发现是半成品）。
4. **局部「不引 `intl`」的三处**（`spb_domain` 的 `artifact_tree.dart` 的 locale
   排序、`goal_history_panel.dart` / `auto_schedules_panel.dart` 的固定日期格式）
   **不构成**本决策的理由——它们只是「为一种固定格式不引整套 locale 数据」的
   局部取舍，与本节的结论无关。不要拿它们当依据。

#### 重新评估条件（满足**任一条**即可重开）

| # | 条件 | 为什么是它 |
|---|---|---|
| 1 | 产品**进入非中文市场**，且有明确目标语言与验收人 | 无目标语言时引入 i18n 只会产出无人验证的翻译 |
| 2 | `spb_features` 硬编码字符串数 **> 1500**（当前 878，见上方命令） | 提取工作量翻倍，且说明 UI 文案已成规模、值得一次性上工具链 |
| 3 | 出现「**同一文案在 ≥3 处需按语境改写**」的实际需求 | 说明缺的是 message key 机制而非翻译；此时直译方案已不够用 |

#### 若将来要做（供重开时参考，**不要现在就动手**）

- 方案取舍：`flutter_localizations` + ARB（官方、`gen-l10n`、支持复数/性别）vs
  自研轻量 `Map<String, String>`。倾向官方方案，但**必须先解决第 1 条的领域层
  文案问题**（否则两套机制并存）。
- **「界面语言」与「Agent 回复语言」是两个独立维度**：后者已有
  `replyLanguage` 偏好（`user_preferences_card.dart`，`'auto'` 表示跟随输入，
  非法值服务端 400 而非静默回落）。webapp 的 `ReplyLanguagePanel` 注释专门强调过
  「两者独立，勿合并」——重开时不要顺手把它们合成一个设置。
- 分期建议：先做 UI 层（`spb_features` / `spb_ui` / `spb_design`），领域层文案
  作为独立一期（需先定「消息码 + 参数」契约）。

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
| `spb_data` | **98.3%** | `spb_platform` | 57.4% |
| `spb_features` | **93.4%** | `spb_mobile` | 54.1% |
| `spb_core` | **92.4%** | `spb_desktop` | 58.7% |
| `spb_domain` | 88.8% | `spb_api` | **87.8%** |
| `spb_models` | 88.0% | `spb_ui` | 79.8% |
| `spb_design` | 78.6% | **总计** | **85.0%**（≈15497/18226） |

全仓用例 **3452 条**（issue #48 拆分后；拆分本身 0 变化，+13 是新增的 SSE
端到端（§6.27），+31 是零调用者端点契约（§6.28））。

⚠️ **这张表会漂移**——用上面的命令重跑，别把这里当权威数字。
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
调用、窗口/托盘/快捷键），本机无 `DISPLAY`、无真机（见 §9），widget test 只能覆盖
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
  有），后者是诊断面（AGENTS.md §6.9 有意不做 `GroupDebugPanel` 于移动端）。
- **不做「高亮全部 + 上/下跳转」**（浏览器 `Ctrl+F` 那种）：需要维护「当前第几个
  命中」的游标与循环跳转，属独立交互；当前只做「列出命中 + 点一条滚过去」。
- **不做正则 / 模糊 / 拼音**：与全局搜索页的 `LIKE` 语义保持一致（AGENTS.md §6.2
  的契约同步取向）。

### 6.16 窄屏 AppBar 溢出（issue #31）

**症状**：移动端对话页在常见手机宽度下**两处** RenderFlex 溢出——AppBar 与输入区。
溢出后右侧入口被黄黑条覆盖/裁切，**用户点不到**。

**为什么此前没发现**：全部 widget test 用**默认 800dp 窗口**（比真机宽），而本机无
`DISPLAY`（AGENTS.md §9）也没有真机可看。这是一个**测试环境掩盖真实布局**的典型。

#### 实测数据（`tester.view.physicalSize`，修复前）

| 宽度 | AppBar 溢出 | 输入区溢出 |
|---|---|---|
| 320dp | 66px | — |
| 360dp | 66px | 64px |
| 390dp | 36px | — |
| 412dp | 14px | — |

AppBar 曾塞 7 个常驻元素（`AgentSwitcher` + 5 个 `IconButton` + 连接指示器），
合计约 366dp。

#### 修法：按「频率 + 是否需一眼可见」分档

| 入口 | 窄屏 | 理由 |
|---|---|---|
| `AgentSwitcher` | 常驻（**<360dp 时只留图标**） | 「这段对话由谁回答」是全局属性，随时要切 |
| 交付物 / 待办 | 常驻（**带徽标**） | 回答「现在有什么在等我」，必须一眼可见 |
| 对话设置 / 任务清单 / 目标历史 | **收进溢出菜单** | 低频弹层，多一步不痛 |
| 对话内搜索 | **收进溢出菜单**（页面追加） | 同上（见 §6.15）；**宽屏则摆独立图标**（issue #33，见下） |

**阈值用 `SpbBreakpoints.compact`（720dp）而不是「刚好放得下」的实测值（440dp 左右）**：
后者是**内容相关的**——`AgentSwitcher` 宽度随 agent 名字变化（实测 94.3dp，上限
140dp+），按「刚好」设阈值会在换个长名字的 agent 后又溢出。720dp 以下一律单栏窄屏，
是这类取舍的天然分界。

#### 溢出菜单为什么由 `ConversationPage` 渲染、条目由调用方给

三个低频入口的**动作**属于各端（各自持有弹层与 State），而「在本对话中搜索」的
**动作**属于页面（需要页面私有 `ScrollController` 与 `_items`）。故页面提供
`overflowItems` 插槽：调用方给条目，页面把自己的搜索项**追加在末尾**并渲染整个菜单。

⚠️ **菜单项与宽屏图标用不同的 `key`**（`menu-group-settings` vs
`open-group-settings`）：同一个 key 指向两种交互会让断言的含义随窗口宽度漂移。

#### 三条不变式

1. **窄屏不能「藏掉」功能，只能「多一步」**。菜单项禁用（`onTap == null`）而不是
   不渲染——入口消失会让用户以为「本端不支持」，置灰只说明「现在还用不了」。
2. **测试必须显式设窗口尺寸**。新增的 `对话页窄屏 AppBar（issue #31）` group 用
   `tester.view.physicalSize` 压到 320/360/390/412dp，并断言
   `tester.takeException()` 为 null（溢出会走 `FlutterError.onError`）。
   **默认 800dp 的用例不能替代它**——那正是缺陷被掩盖的原因。
3. **`compact` 只省「名字」，不省入口**。`AgentSwitcher.compact` 在 <360dp 时隐藏
   标签（名字在菜单勾选项里可见），图标本身保留——它是入口。

#### 移动端搜索入口的取向（与桌面端不同）

| | 桌面端 | 移动端窄屏（<720dp） | 移动端宽屏（≥720dp） |
|---|---|---|---|
| 搜索入口 | 独立图标（`enableSearch: true`） | **溢出菜单**（`enableSearch: false`） | **独立图标**（`enableSearch: true`） |

移动端窄屏在 720dp 以下若给搜索一个 48dp 图标，会挤压常驻项；而菜单入口在
所有窄屏档位都可用。宽屏（平板 / 折叠屏展开 / 横屏手机）则有 720dp 余量，摆
独立图标不会溢出——**两个入口必须互补覆盖**：窄屏「菜单有、图标无」，宽屏
「图标有、菜单无」。

⚠️ **曾经两档都缺**（issue #33）：`enableSearch` 恒为 `false`，而
`_overflowItems()` 在宽屏返回 `null` —— ≥720dp 下搜索**彻底不可达**。既有用例
只断言了 `_group` 系列入口，没碰搜索；本机无 `DISPLAY` 也看不出。故两端各有一条
从 **router 层**断言的用例钉住搜索入口——**页面测试自己传参，接不接线它不管**：
`apps/spb_desktop/test/router_list_test.dart` 的 `对话页 AppBar 提供对话内搜索入口`、
`apps/spb_mobile/test/router_notify_test.dart` 的 `宽屏（≥720dp）…` 与
`窄屏（<720dp）…`（两条分别钉住宽屏图标与窄屏菜单，避免「一边补上、另一边
漏掉」）。

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

#### 覆盖面：4 个组件，不是 1 个（issue #42）

最初只登记了 `ConversationPage`。其余共享页面同样有单端差异且**同样没有
守卫**。现已扩到：

| 组件 | desktop 单端 | mobile 单端 |
|---|---|---|
| `ConversationPage` | `onOpenAgentFile` / `onRevealAgentFile` | `overflowItems` |
| `GroupListPage` | — | `onOpenQuickCapture` |
| `SettingsPage` | `loadLaunchAtStartup` / `setLaunchAtStartup` / `onOpenDirectory` / `onExportDiagnostics` | `loadNotifications` / `saveNotifications` |
| `SyncPage` | `onOpenDirectory` | — |

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
- **provider 层**：两端 `providers.dart` 有 88 个同名 provider，上提到共享包是
  独立重构（issue #39 已登记），不在本守卫范围。

#### 四个易写错的点（写这类脚本时）

1. **必须先把注释与字符串抹掉再解析**：`reason: 'a, b'` 里的逗号会被当成参数
   分隔符，注释里的 `ConversationPage(` 会抢到错误位置。脚本用「保持长度与
   换行」的替换（而非删除），行号才对得上。
2. **匹配要用词边界**，否则同名的私有包装（带下划线前缀的薄壳组件）会被当成
   目标——这正是 issue #42 的假绿。
3. **豁免过期要报错**：否则清单会随重构腐化，最终列出早已统一的参数。
4. **拼错参数名要单独报**：Dart 编译器会报，但脚本早一步给出「传了 X 没有的
   参数」，定位更快。

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
断言（`row_locate_registry_test.dart` 12 条、`agent_file_batch_test.dart` 新增 5 条）。

### 6.19 AGENTS.md 标识符引用守卫（issue #37）

`tools/check_agents_refs.sh`。本文档是本仓库**主要协作接口**（AI agent 与人的
共同参考），它引用的函数/字段若不存在，读者会去找一个不存在的东西。

#### 真实漂移先例（不是假想）

| 位置 | 曾引用 | 实际是 |
|---|---|---|
| §6.15 | `_summarize` | `searchConversationItems` 内联截取（产出 `snippet`） |
| §6.15 | `hasMore` | 参数名 `upperHistoryUnloaded` |
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

---

### 6.20 诊断日志导出（issue #40，**第一层已实现**）

客户端此前**没有任何远程日志通道**：`LogSink` 只有 `ConsoleLogSink`（打印到
stdout）与 `NullLogSink`（测试用）。用户报障时除了「它不工作」没有别的信息
——没有堆栈、没有版本、没有设备信息。而 §9 已列出「需真机/有桌面环境手测」
的范围（多窗口、托盘、`Alt+Space`、OIDC 回跳、交付物同步）恰好是最容易出
平台特异性问题、而本机无法验证的部分。

issue #40 给了三层。**本轮只做第一层**，后两层有意不做：

| 层 | 内容 | 状态 |
|---|---|---|
| 1 | 「导出诊断日志」入口（手动附给报障） | ✅ 已实现 |
| 2 | 崩溃上报（Sentry 自托管 / 复用 `logs-collector`） | ❌ 有意不做 |
| 3 | `integration_test/` 覆盖无头可跑的链路 | ❌ 有意不做 |

#### 链路

```
设置页「导出诊断日志」
  └─ onExportDiagnostics 回调（装配层）
       └─ exportDiagnosticsReport(capabilities)      [spb_platform]
            ├─ diagnosticsEnvironment()   ← 版本/平台/Flutter/服务地址（**非机密**）
            ├─ buildDiagnosticsReport(...) ← spb_core：环境信息 + 最近日志
            │    └─ redactSecrets(...)     ← 导出前**最后一道**脱敏
            └─ capabilities.saveDiagnostics(text, suggestedName:)
                 └─ DiagnosticsExporter.save() → 系统「另存为」→ 写文件
```

#### 分层归属（按 §4 的判据）

| 层 | 内容 | 为什么在这一层 |
|---|---|---|
| `spb_core` | 环形缓冲（`SpbLog.recentLogs`）、`LogRecord.format()`、`redactSecrets`、`buildDiagnosticsReport` | 「保留哪些、怎么渲染、怎么脱敏」是**正确性核心**，必须能在无 Flutter 引擎的环境下逐条断言 |
| `spb_platform` | `DesktopCapabilities.saveDiagnostics` + `DiagnosticsExporter` + `diagnosticsEnvironment` / `exportDiagnosticsReport` | 环境信息要 `FlutterVersion` / `appBuildName`（Flutter 侧常量，纯 Dart 包拿不到）；保存要走 `file_selector` |
| `spb_features` | `SettingsPage.onExportDiagnostics` + 入口 + 四态反馈 | 渲染与交互 |
| `apps/*` | 一行 `onExportDiagnostics: () => exportDiagnosticsReport(caps)` | 装配 |

#### 四态而非「成功/失败」二元（**最易写错**）

`DiagnosticsExportOutcome` 有四个值，因为**用户看到的反馈不同**：

| 值 | 页面反馈 | 为什么不能合并 |
|---|---|---|
| `saved` | 弹「诊断报告已导出」 | — |
| `cancelled` | **什么都不说** | 用 `bool` 会把取消当失败，用户点一下取消就看到「导出失败」，以为功能坏了 |
| `failed` | 弹「导出失败，请重试」 | 静默失败会让用户以为导出成功、去磁盘里白找一场 |
| `unsupported` | 弹「当前平台不支持」 | 与「失败」不同：一个是可以换平台，一个是该重试 |

`NoopDesktopCapabilities.saveDiagnostics` 恒返回 `unsupported`，所以**移动端
不接**（两端 router 都传同一个装配函数也不会出事）——真到了移动端，页面会
如实说「不支持」而不是「失败」。

#### 安全红线：导出文本必须已脱敏

报告会被用户贴进**公开** issue / 聊天窗口，而泄漏的凭证收不回来。两道防线：

1. **来源侧克制**：`spb_api` 的 `session_credential.dart` 明写「本函数**绝不
   记录 token 值**」；`diagnosticsEnvironment()` 只含版本/平台/地址（逐条依据
   写在函数文档里，每个值都是公开的——`client_id` 本就是公开值，`env.dart`
   已说明；发布地址来自 CI Variables，而 Variables 在公开仓库里本来就可见）。
2. **导出侧按形态掩码**：`redactSecrets` 是**最后一道**，不依赖「谁记了什么」。
   将来有人不小心把 header 打进日志，这里仍然拦住。

`redactSecrets` 掩的是：`Bearer <token>`、JWT（`eyJ…`）、已知前缀令牌
（`sk-` / `ghp_` / `xox[bpoa]-` / `AKIA`）、PEM 私钥头、URL 里的 `user:pass@`、
以及**凭据类键名**后的值（`authorization` / `access_token` / `refresh_token` /
`id_token` / `api_key` / `apikey` / `client_secret` / `password` / `passwd` /
`token` / `secret`）。

⚠️ **不能过度掩码**。把「收到 401，会话凭证可能已失效」这种无辜文本抹掉，等于
把诊断信息删了。故键名是**白名单式列举**（不是关键词黑名单），且有专门一组
用例钉住「不误伤」（真实日志文案、路径/域名/端口、无凭据 JSON、英文句里的
`bearer` 一词）。

两个实现细节（都踩过）：

- 凭据键名里的 `\b` 让 `access_token` **不会**被 `token` 分支命中（`_` 是词字符，
  其与 `t` 之间没有词边界），故 `access_token` / `refresh_token` 必须逐个列出。
- PEM 头的正则**不能**在模式前加 `\b`（模式开头是 `-`，`\b` 要求前面是词字符
  → 永远匹配不到行首的 PEM 头）。

#### 三处「看起来能省、其实不能」的取舍

| 取舍 | 结论 | 为什么 |
|---|---|---|
| 写固定目录（应用数据目录） | ❌ | macOS 沙箱与 Linux 下都是隐藏路径，用户找不着——「导出成功但用户拿不到文件」比导出失败更糟 |
| 走剪贴板 | ❌ | 报告最多 500 条日志（上千行），粘进聊天窗口会被截断；且剪贴板是**静默**的（用户不知道复制成功没有） |
| 文件名用 `toIso8601String()` | ❌ | 它含 `:`，而 `:` 在 NTFS 上是数据流分隔符，`File.writeAsString` 会失败——**Linux 开发机一切正常、Windows 用户报导出失败**，而 CI 只跑 Linux。改用 `20261012-203045` 形态 |

#### 环形缓冲的两个不变式

- **上限 500 条，丢最旧的**。桌面端是常驻进程（关窗只隐藏到托盘），跑一周能
  产生几十万条日志；全留会让内存随运行时长线性增长——而这是用户**看不见**的
  泄漏。方向写反（丢最新）会让报告只剩启动时的日志。
- **阈值过滤在记录之前**。故报告只包含运行时**实际可见**的日志——想让报告
  带上 debug 细节，得用 `--dart-define=SPB_VERBOSE_LOG=true` 构建，而不是
  期待导出时能补回来。否则「日志里没有」会被误读成「没发生」。

`SpbLog.clearRecentLogs()` 是**测试专用**（全局单例的缓冲会跨用例累积，断言
「缓冲里有什么」之前必须先清）。

#### 有意不做：移动端导出

`file_selector` 的 `getSaveLocation` 在 **Android/iOS 上未实现**（基类抛
`UnimplementedError`）。移动端要做需引入 `share_plus` + 真机验证，属独立一轮
（同 §6.9.1「移动端打开已下载文件」的取舍）。当前移动端**不注入**
`onExportDiagnostics`，故入口不渲染。

#### 反向验证（逐条实测）

去掉 `redactSecrets` 调用 → 1 条失败；键名去掉 `access_token` → 1 条；PEM
正则加回 `\b` → 1 条；文件名改回 ISO8601 → 1 条（`:` 检测）；环形缓冲改丢
最新 → 1 条；阈值过滤移到缓冲之后 → 1 条；取消态也弹提示 → 1 条。

---

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
- AGENTS.md §6.2 原称「`melos run gen` 对本包为空」——该说法在只有 `spb_data`
  有生成物后已不准确（应是「只跑 spb_data」），已修正。

---

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

---

### 6.23 流式归约合并（issue #44）——**并纠正 issue 里的一个错误方案**

#### 问题（实测）

流式回复是逐 token 增量（`message` 的 `transient: true`）。一个长回复产生几百条
事件，而 `_emit` 原来**每条**都 `EventReducer.reduce(_buffer)` 全量重算（缓冲区
上限 2000 条）并重建整个 items 列表。

```
单次归约（2000 条）: 1767 µs
300 条增量 × 全量归约: 640 ms   ← 全在 UI 线程
```

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

---

### 6.24 全局错误兜底与静默吞异常（issue #45）

#### 问题：诊断通道建好了，却没接上「异常」这个主来源

issue #40 实现了「导出诊断日志」（环形缓冲 + 环境信息 + 脱敏，§6.20），但它
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
issue（§6.20 的安全红线）。只记长度与类型。

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

issue #40 的第 2 层（崩溃上报）仍**有意不做**（§6.20）——本轮是它「不做上报」
前提下的最低成本补偿：异常至少进了用户能导出的报告。

⚠️ 全局错误处理的**可见行为**（红色屏幕、进程是否存活）需真机验证——本机
无 `DISPLAY`（§9）。

---

### 6.25 文档数字守卫与真实标识清理（issue #46）

#### 一、数字漂移（守卫查不到的那一类）

`tools/check_agents_refs.sh`（§6.19）只查**标识符存在性**——查不到数字一致性。
实测漂移：§6.12 写 `spb_features` 硬编码中文 **808**（实际 878）、全仓 **782**
（实际 1569）；§11 写总计 **83.4%** 而 §6.13 写 83.8%（**同一文档两处不一致**）。

**为什么值得修**：§6.12 的「重新评估条件 2」是「`spb_features` 硬编码字符串
> 1500」——文档里的「当前值」若长期不准，将来判断「是否触发重评估」时会基于
**错误基线**。

#### `tools/check_agents_numbers.sh`：容差而非精确相等

| 方案 | 问题 |
|---|---|
| 软失败（只提示） | CI 上**永远不会被看到**（没人翻绿构建的日志）——等于没查 |
| 精确相等 | 这些数字**随实现自然增长**（782→808→878）。每加一句中文文案就红一次，很快会有人删掉标记 |
| **容差（选用）** | 小漂移放行（不打扰正常开发），大漂移拦住（防文档烂到误导决策） |

默认容差 **5%**（标记可 `tolerance=` 覆盖）。依据：§6.12 的阈值是 `> 1500` 而
当前 878——5% 的漂移（约 44 条）远不足以改变「离阈值还有多远」的判断。

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
| 同上 | 内部域名 `idp.<internal-domain>` | 「IdP 生产地址」 |
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
不生效 → 1 条。数字本身：把 §6.12 的 `value` 改回 808 → 守卫报「偏差 8.0%」。

---

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

---

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
这一调度差异的证据测试（见 §6.23）——改成 `fakeAsync` 就测不到真实 microtask 时序。

**故 `fakeAsync` 改造的收益接近零**（最多省几秒，且会削弱 §6.23 的证据力）。
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
Flutter 引擎，`dart test` 直接跑，不需要 `DISPLAY`（本机无，§9）。这**不推翻**
§6.20「`integration_test/` 第 3 层有意不做」——那个决策针对真机 + UI 集成，
与本文件的成本/收益不同。

**反向验证**：把 `_onBytes` 的增量解码换回「每片独立 `utf8.decode`」（issue #41
修复前的行为）→ **2 条失败**（两个 UTF-8 跨分片用例），其余 11 条仍绿。

**覆盖率**：`spb_api` 82.6% 不变（`sse_client.dart` 的 98.1% 已在 #41 达成），
新增 13 条用例不改变行覆盖（走的是同一条路径，只是入口从 `DioAdapter`
换成真实 socket）。

---

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
`req.uri.path` 的小 `Recorder`（与 §6.27 的端到端测试同一取向）。

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
在将来「已知 id 要刷新一条」的场景有用）。真正的「有意不做」是 §6.9 的**端点族**
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

### 6.29 开源镜像同步（`tools/sync-to-github.sh`）

权威源是 **Gitea**（完整历史 + blame）。GitHub 上另有一份**公开镜像**，用 squash
方案导出：只含「恰好 HEAD 这一棵树」，一条提交。

```bash
export SPB_OS_MAP="$HOME/.config/spb-flutter/opensource-map.env"
export SPB_OS_EXTRA_RULES="$HOME/.config/spb-flutter/extra-rules.txt"
export SPB_GITHUB_REMOTE="git@github.com:<owner>/<repo>.git"

bash tools/sync-to-github.sh --verify    # 只校验当前树是否已干净
bash tools/sync-to-github.sh --dry-run   # 预演：报替换处数，不推送
bash tools/sync-to-github.sh             # 执行（force-push）
```

#### 为什么是 squash 而不是重写历史

Gitea 历史含生产部署标识。把它们从**历史**里清掉需重写所有提交哈希
（`tools/scrub-history.sh`），而 Gitea 是权威源，不该为了一次镜像而改写。
`git archive HEAD` 只导出当前树，用一条新提交承载：GitHub 看到干净的现状，
Gitea 保留完整历史。

#### ⚠️ 代价（务必知晓）

| 代价 | 后果 |
|---|---|
| 历史全丢 | GitHub 上永远只有一条提交，`git blame` / `git log -p` 退化为单条；`release.yml` 的「由 `git log` 生成发布说明」在镜像上无意义 |
| 两边无共同祖先 | GitHub 那份是**孤立仓库**。**绝不**把 Gitea 合并进来或反向拉取——两个无关联历史的合并极难收拾 |
| 每次都是 force-push | GitHub 历史每次被整体替换，有人在那边开 PR 会被打断（故它只适合「只读镜像」） |

#### 为什么脚本里没有任何真实值

与 `scrub-history.sh` 同一取向：本脚本会入库、会被公开。若把「真实值 → 占位符」
的映射（或真实值的任何片段）写进脚本，同步本身就**成了泄露渠道**。故真实值与
规则**全部**来自仓库外的映射文件，脚本里只出现变量名与文件名。

规则文件是**两份**：

| 文件 | 内容 |
|---|---|
| `$SPB_OS_MAP` | 11 个 `SPB_REAL_*` 变量 + 对应 `*_PLACEHOLDER`（与 `scrub-history.sh` 共用同一份） |
| `$SPB_OS_EXTRA_RULES` | 映射表装不下的形态（`查找==>替换`），如「主机名嵌在一整条 SSH URL 里」 |

#### 两个易写错的点

1. **必须跳过二进制**。本仓库有 44 个 golden 基线 PNG，是**逐字节比对**的；
   用 `perl -i` 之类的文本工具处理会损坏文件。故一律用 `grep -I` 筛出文本文件。
2. **规则行要跳过 `#` 注释**。`extra-rules.txt` 里为可读性写了注释行；
   不跳过会把 `# 内网 Gitea 端点…` 当成「查找串」（实测踩过：产物多出无意义替换）。

#### 反向验证（实测）

- `--verify` 在未清理的树上报告残留（实测 2 条规则 / 2 个文件）；
- 脚本产物与手工推送的 GitHub HEAD **逐文件 diff 一致**（`diff -r --brief` 无输出）；
- `--dry-run` 报「替换 2 处、涉及 2 个文件」+「23 条规则全部无残留」，
  与手工流程的数字完全一致。

---

### 6.30 CI 基础镜像固定与 action 运行时升级

#### 一、`ubuntu-latest` → `ubuntu-24.04`（**必做**，否则会随机变红）

GitHub 官方公告（`actions/runner-images#14748`）：`ubuntu-latest` 自
**2026-10-19 起滚动数周**切到 Ubuntu 26.04，11-19 完成。

**为什么这条必须处理**：`ubuntu-latest` 会在某个**不可预测的时刻**翻转。
同一份代码今天绿、下周某次 push 莫名红——而且红在 `apt-get install` 或
CMake 链接阶段，报错指向系统库而不是我们的代码。

我们依赖的、Ubuntu 26 可能变化的点：

| 依赖 | 风险 |
|---|---|
| `libkeybinder-3.0-dev` / `libayatana-appindicator3-dev` | 第三方包，可能改名或消失 |
| `libglu1-mesa-dev` | 老包，历来是迁移牺牲品 |
| `patchelf` 修的 RUNPATH | glibc 换代后 loader 行为可能变 |

故 7 处 `runs-on: ubuntu-latest` 全部钉为 `ubuntu-24.04`（LTS，官方明确仍可用）。
**固定版本才能让 CI 结果可复现**——与「锁 Flutter 3.47.5」同一取向。

> 等 Ubuntu 26 生态稳定、或我们主动验证过依赖齐全，再改成 `ubuntu-26.04`
> （**不是**改回 `ubuntu-latest`：那会再次把不确定性引回来）。

#### 二、action 运行时 node20 → node24

GitHub 用 `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` 强制 node20 的 action 跑在
node24 上，故**功能正常、只是警告**。但这是临时兜底，某天移除后 node20
action 会直接失败。

升级时选了**每个 action 首次支持 node24 的最低版本**（最小变更原则，
避免顺带引入无关 breaking）：

| action | 旧 | 新 | 选择依据 |
|---|---|---|---|
| `actions/checkout` | v4 | **v5** | v5 是首个 node24；v6/v7 的 breaking 只涉 `pull_request_target`（本仓零使用） |
| `actions/upload-artifact` | v4 | **v6** | v6 是首个**默认** node24（v5 仅预备支持、默认仍 node20） |
| `actions/download-artifact` | v4 | **v7** | v7 是首个 node24；**特意避开 v8**——v8 把 digest 不匹配从「警告」改为「直接失败」（新的破坏性默认值） |
| `actions/setup-java` | v4 | **v6** | 官方已明确「v1–v4 deprecated」，该直接升 v6；我们用 `distribution`+`java-version`，未碰 v5/v6 改名的 `jdkFile`/GPG 选项 |
| `android-actions/setup-android` | v3.2.2 | **v4.0.4** | v4.0.4 changelog 正是「Fix for removed tools package」 |
| `subosito/flutter-action` | v2.23.0 | **不变** | 它是 `using: composite`，**不跑 Node**，无需升级 |

#### 三、顺带删掉 `packages: platform-tools` 补丁

上一轮为绕过「`tools` 包被 cmdline-tools 16 移除」加的 `packages: platform-tools`
已可删：`setup-android@v4` 的 `action.yml` 里 `packages` **默认值就是**
`platform-tools`，即 v4 内置了这个修复。

#### 四、守卫不能绑死 action 主版本号

`check_workflow_steps.sh` 原本断言 `'actions/download-artifact@v4' not in uses`。
升到 v7 后它会误报。

**改法**：断言 `any(u.startswith('actions/download-artifact@v'))`。这里要守的是
「release job 有下载步骤」这个**结构事实**，不是某个具体版本。

> 绑死版本的守卫很快会被加进忽略列表——而误报的守卫比没有守卫更危险
> （§6.17 的同一教训）。

#### 反向验证（实测）

- 两个 workflow 的 YAML 语法：`yaml.safe_load` 通过；
- `check_workflow_steps` + 自测（5 条）全绿——证明版本断言改宽后仍能
  抓住「download-artifact 被注释吞掉」那个历史缺陷形态；
- `check_agents_refs` / `check_format` 通过；
- 全仓 `uses:` 无残留 `@v4`（`grep -c` 为 0）。

---

### 6.31 生产部署接线：public client、release.yml 的两个缺陷、tbcc6 判定

把客户端接到 `app.example.com` 的过程中查出四件事，其中**两个是 release.yml
的真实缺陷**（CI 绿不代表 release 绿——两条 workflow 的构建步骤从未对齐过）。

#### 一、桌面端 OIDC client 必须是 **public + loopback**

生产 IdP 的 `flutter-client` 初始配置有两处不对，逐一有代码依据：

| 字段 | 错值 | 正确值 | 依据 |
|---|---|---|---|
| `tokenEndpointAuthMethod` | `client_secret_basic` | **`none`** | 客户端**从不下发 secret**：`env.dart` 无 `SPB_OIDC_CLIENT_SECRET`，所有调用点都是 `OidcConfig.fromEnv()` 无参（`providers.dart:160`、`auth_browser.dart:42`），`oidc_client.dart:427` 仅 secret 非空才加 `Basic` 头；`auth_loopback.dart:77` 还会**主动拒绝**带 secret 的配置 |
| `redirectUris` | 两个 https 网关回调 | **`["http://127.0.0.1/callback"]`** | 见下 |

**注册值的四条硬约束**（fosite v0.49.0 `authorize_helper.go:117` 的
`isMatchingAsLoopback`）：

```go
if requested.Scheme == "http" &&
    isLoopbackAddress(requested.Hostname()) &&
    registered.Hostname() == requested.Hostname() &&
    // The port is skipped here - see codedoc above!
    registered.Path == requested.Path &&
    registered.RawQuery == requested.RawQuery {
```

1. **scheme 必须 `http`**（不是 https）；
2. **hostname 必须是字面 `127.0.0.1`**——`registered.Hostname() == requested.Hostname()`
   是字面比较，注册成 `localhost` 时客户端发 `127.0.0.1` → 精确匹配与 loopback
   匹配**双双失败**；
3. **path 必须 `/callback`**（`LoopbackRedirectServer.defaultPath`）；
4. **不能带端口**——端口被显式跳过比对（源码注释原文 `The port is skipped here`）。

且 `redirectUris` 的值与 `env.dart:101` 的 `SPB_OIDC_REDIRECT_URI` 默认值
**逐字相同**（运行时由 `auth_loopback.dart:103` 的 `copyWithRedirectUri` 覆盖为
随机端口，故注册值必须是不带端口的那个）。

**PKCE 不可关闭**：`provider.go:63` 硬编码 `EnforcePKCEForPublicClients: true`，
与可配的 `EnforcePKCE`（`cfg.RequirePKCE`）是**两个不同开关**。故 `requirePkce`
字段对 public client 不产生实际差异，但仍应写 `true`（如实反映 + 防将来改为
confidential 时静默降级）。

**活体验证**（直接打生产 authorize 端点，比查库更有说服力）：

| 发送的 `redirect_uri` | 期望 | 实测 |
|---|---|---|
| `http://127.0.0.1:8347/callback`（随机端口） | 通过 | **302 → 登录页** ✅ |
| `http://127.0.0.1/callback` | 通过 | **302 → 登录页** ✅ |
| `http://localhost:8347/callback` | 拒绝 | 400 `invalid_request` ✅ |
| `https://evil.example.com/callback` | 拒绝 | 400 `invalid_request` ✅ |

⚠️ **IdP 的 admin API 不认 API key**：`adminRoute`（`server.go:495`）只挂
`adminauth.Middleware`（`adminauth.go:23`）——`idp_access_token` Cookie 或
`Authorization: Bearer` + 角色含 `admin`/`super_admin`。`serviceauth`
（X-App-ID/X-App-Secret）只挂在 wechat/feishu/dingtalk/ilink binding 路由上；
`applications` 表的 `apiKeyEnabled/apiKeyConfig` 是**应用自身**的属性，与
admin clients 无关。另：`oidc/provider.go:364` 的 `RegisterClient`（RFC 7591
动态注册风格）**无任何 HTTP 路由与调用方，是死代码**。

#### 二、`release.yml` 的 linux job 缺 4 个依赖（真实缺陷）

ci.yml 装了 8 个包，release.yml 只有 5 个——**两条 workflow 的依赖清单从未对齐**。
缺的四个都会让构建**直接失败**（不是功能降级）：

| 缺失包 | 谁需要 | 后果 |
|---|---|---|
| `libsecret-1-dev` | `flutter_secure_storage_linux` | CMake `REQUIRED`，构建即失败 |
| `libkeybinder-3.0-dev` | `hotkey_manager_linux` | 同上（AGENTS.md §7 已记） |
| `libayatana-appindicator3-dev` | `tray_manager` | 同上 |
| `patchelf` | `bundle_linux_deps.sh` | 修 RUNPATH 失败 → 分发即挂 |

⚠️ **第一个失败掩盖了第二个**：修好依赖后才走到 RUNPATH 检查，才暴露下一个缺陷。

#### 三、`release.yml` 的 RUNPATH 检查是**假红**（真实缺陷）

```bash
if find lib -name '*.so*' -exec sh -c 'patchelf --print-rpath "$1" | grep -q /home/' _ {} \; ; then
  echo "❌ RUNPATH 仍指向构建机 /home 路径"; exit 1
fi
```

`find` **不看** `-exec` 的退出码，遍历完即返回 0 → `if` 恒为真 → **恒报错**。
于是 linux job 在「构建成功 + 依赖打包成功」后仍判失败。

这与 §6.30 之前修过的 ci.yml 同一条检查是**同一个 bug**——当时只修了 ci.yml，
release.yml 漏改。**改这类检查时必须全仓 grep 同型模式**（本次复查：只剩注释里
的说明文字，无其他实例）。正确写法是先收集命中项再判空：

```bash
bad=$(find lib -name '*.so*' -exec sh -c \
  'patchelf --print-rpath "$1" | grep -q /home/ && echo "$1"' _ {} \;)
[ -n "$bad" ] && { echo "❌ $bad"; exit 1; }
```

#### 四、`app2.example.com` **不应**配进 `SPB_PREFERRED_HOSTS`

曾考虑用 §5.1.1 的双栈机制把 api/ufs 升到 `tbcc6`。DNS 实测证明它**不是可用的
生产端点**：

| 证据 | 值 |
|---|---|
| CNAME 链 | `app2.example.com` → `qpoweiurty.atjog.com`（随机串，DDNS 特征） |
| AAAA | `2409:8a55:a20:8570:be24:11ff:fee3:581a` |
| 地址段 | `2409:8a55::/32` = **中国移动**（家宽段，非机房） |
| 接口标识 | `be24:11ff:fee3:581a` = **EUI-64**（由网卡 MAC 推导）→ 动态地址 |
| TTL | CNAME 600s（DDNS 常用短 TTL，便于换 IP） |

对照 `app.example.com` → `app.example.com.eo.dnse0.com` → `240d:c010::/32`
（腾讯 EdgeOne CDN），**本身已是双栈**——无需 `SPB_PREFERRED_HOSTS` 就能走 IPv6。

**结论**：配 tbcc6 只会让「中国移动 IPv6 + 恰好解析到当前地址」的极少数用户绕到
一台家宽机器，而地址随时会变、证书未必匹配、其他网络一律连不上。这是「看起来
优化、实际制造随机故障」。

> ⚠️ **本机与 bcc 都无 IPv6 出口**，无法直接验证 tbcc6 可达性；check-host.net
> 的节点也只解析 A 记录（连 `ipv6.google.com` 都报 `Unknown host`），故此判定
> 基于 DNS 特征而非连通性实测。若将来要启用，**必须**先在有 IPv6 的机器上确认
> `https://app2.example.com/pba/healthz` 返回 200 且证书 SAN 覆盖该域名。

#### 五、GitHub Variables（公开仓库，值全部会进二进制）

| Variable | 值 |
|---|---|
| `SPB_API_BASE_URL` | `https://app.example.com/pba` |
| `SPB_UFS_BASE_URL` | `https://app.example.com/ufs` |
| `SPB_OIDC_ISSUER` | `https://app.example.com/idp` |
| `SPB_OIDC_CLIENT_ID` | public client 的 `clientId`（**公开值**，会出现在授权 URL） |

`--dart-define` 的值**必然编译进二进制**（在 `lib/libapp.so` 的 Dart AOT 常量区，
`strings` 可提取），故配进公开 Variables 不构成新泄露。验证方式：下载产物后
`strings -a lib/libapp.so | grep tbcc`——同时应确认旧默认值 `127.0.0.1:8000` 已消失。

⚠️ **`gh` 的 fine-grained PAT 需要 `Actions: Read and write`** 才能读写 Variables：
只有 read 时 `POST /actions/variables` 报 403 `Resource not accessible by personal
access token`（`PUT` 对不存在的变量报 404，容易误判成路径错）。

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
- [x] SSE 传输层单测（issue #41，含测出的 UTF-8 分片损坏修复，见 §6.22）
- [x] 消息发送 + 无归属入口（悬浮窗）
- [x] 失败 turn 重发（`ErrorItem` → 重新投递，见 §6.14）
- [x] 对话内搜索（搜已加载时间线，见 §6.15）+ 窄屏 AppBar 溢出修复（issue #31，见 §6.16）
- [x] 交付物同步（单向拉取 + 双向回传与冲突物化）
- [x] 设置页（目录 / 范围 / 媒体开关 / 单文件上限 / 本地清理）
- [x] 导出诊断日志（issue #40 第一层：环形缓冲 + 环境信息 + 脱敏，见 §6.20）
- [x] 全局错误兜底（issue #45：三道防线 + 静默 catch 守卫，见 §6.24）
- [x] 工程卫生批量（issue #47：`.gitattributes` / Dependabot / action pin / 三项严格模式 / release notes 由 `git log` 生成 / `tools/` 清单守卫，见 §6.26）
- [x] 移动端：BFF `/chat/miniapp/*` 接入
- [ ] 移动端 OIDC 登录闭环（需 IdP 注册 `partyb://oidc/callback`，见 `docs/mobile-oidc-deeplink.md`）
- [x] CI 流水线（`.github/workflows/ci.yml`：quality / build-linux / build-android / build-windows）
- [x] 发布流水线（`.github/workflows/release.yml`：tag 触发四端出包 → GitHub Release）
- [x] Windows 出包（GitHub Actions `windows-2022`，见 `docs/windows-release.md`）
- [x] macOS 出包（GitHub Actions `macos-14`，ad-hoc 签名 + 通用二进制，**仅 tag 触发**）
- [x] 测试文件拆分（issue #48）：11 个 >1000 行 → 34 个，全部 < 1500 行（见 §6.27）
- [x] SSE 端到端（issue #48）：纯 Dart `dart:io HttpServer`，13 条（见 §6.27）
- [x] 零调用者端点契约测试（issue #49）：31 条真实 `HttpServer`，并修掉 `groupConfirmations` 缺 `/api` 的真实缺陷（见 §6.28）
- [x] 双栈端点运行中降级/升级（issue #50）：连续 3 次连接层失败降级、冷却 5 分钟后重探升级（见 §5.1.1）
- [ ] iOS 出包（需 Apple Developer 账号 $99/年 + 签名证书，无法 ad-hoc 凑合）

### CI / 发布流水线速查

| 文件 | 职责 | 触发 | 产物保留 |
|---|---|---|---|
| `.github/workflows/ci.yml` | **验证**：analyze / format / 11 个守卫 + 6 个自测 / test / 能否构建 | push main + PR | Actions 7 天 |
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
| ~~窄屏 AppBar / 输入区 RenderFlex 溢出（320–412dp）~~ | ✅ 已修（issue #31）：按频率分档 + 溢出菜单 + `AgentSwitcher.compact`；新增窄屏回归用例（`physicalSize` 压到 320/360/390/412dp） | issue #31、§6.16 |
| ~~对话内搜索（搜 agent 回复）缺失~~ | ✅ 已实现：本地搜已加载时间线，面板顶部在 `upperHistoryUnloaded` 时告知边界 | §6.15 |
| ~~移动端宽屏（≥720dp）对话内搜索入口不可达~~ | ✅ 已修（issue #33）：宽屏 `enableSearch: true` 摆独立图标，窄屏仍走溢出菜单；两端 router 层各有用例钉住 | issue #33、§6.16 |
| ~~macOS 交付物同步写用户所选目录需 `user-selected.read-write` entitlement~~ | ✅ 已修复（commit `2f5d778`，两份 entitlements 均已含该键） | §8 |
| ~~多窗口可行性~~ | ✅ `window_manager` 做不到，改用主窗口临时变身 | §6.5 |
| ~~剪贴板文件粘贴无原生实现~~ | ✅ 三平台原生 channel 均已实现（Linux/Windows/macOS） | §6.8 |
| ~~IdP 是否支持 PKCE + 自定义 scheme~~ | ✅ 已改为 loopback 方案；IdP 支持 PKCE，loopback 端口通配由 fosite 原生支持 | `docs/rfc8252-loopback-signin.md` |
| ~~IdP 生产未注册桌面 public client~~ | ✅ **已解决（2026-10）**：生产 IdP 注册了 `flutter-client`（`tokenEndpointAuthMethod='none'` + `redirectUris=["http://127.0.0.1/callback"]`，PKCE 强制）。活体验证：随机端口的 loopback 回调得 302，`localhost`/外部域名得 400。⚠️ 注册值必须用**字面** `127.0.0.1`（fosite `isMatchingAsLoopback` 对 hostname 做字面比较）且**不带端口**（端口被跳过比对） | `docs/rfc8252-loopback-signin.md` §7、§6.31 |
| ~~`#14` 回归：未知容器不递归 `children`~~ | ✅ 已修（issue #27）：未知容器下钻 + 占位符打印原始 type；**顺带修掉两个既有缺陷**——渲染层用扁平子树导致重复渲染（叶子 ×2）、渲染路径无环检测导致 `A→B→A` 栈溢出 | issue #27、§6.9.4 |
| ~~`map` spec 文件预览未实现~~ | ✅ 已实现（issue #12）：`MapSpecCard` + `parseMapSchema` / `MapProjection`（零新依赖），接入预览框与两端 router | issue #12、§6.9.5 |
| ~~`dashboard` 网格格式渲染器未实现~~ | ✅ 已闭环（issue #12）：按「不做」处理——真实 `dashboard.spec.json` 走的是 `spec` 路径（已支持），网格格式**无已知生产者** | issue #12、§6.9.3 |
| 四项检索面板未接（语义 / 图谱 / 文件演化 / 决策演化） | **有意不做**（issue #12）。语义搜索的**嵌入链路是通的**，但数据面为空（`chat_groups` = 0 行）；两个「演化」面板的数据源在 Go 时代已停写——**前置条件是服务端先恢复数据写入** | issue #12、§6.9.6 |
| ~~对话列表缓存：本地变更（新建/改名/删除）后不写缓存~~ | ✅ 已修（issue #28）：5 条本地变更路径补 `_saveCache()`，并去掉 `_saveCache` 的空列表跳过（删掉最后一个对话后缓存不更新的成因） | issue #28、`docs/offline-cache-design.md` §4.5 |
| ~~离线缓存切片 B（timeline 只读缓存）~~ | ✅ 已实现（issue #29）：`CachedEvents` 表（`(groupId, globalSeq)` 主键）+ `TimelineCacheStore` 契约 + `DriftTimelineCacheStore`（三层上限）+ 控制器两个写点（`_backfill`/`loadOlder`）与一个读点（回落，带「缓冲非空则不填」守卫）+ 对话页 `_OfflineTimelineNotice`。共 50 条用例，24 项反向验证逐条实测 | issue #29、`docs/offline-cache-design.md` §3.5/§8.6 |
| ~~离线缓存切片 C（离线写队列）~~ | ✅ 已实现（issue #30）：`OutboxEntries` 表（schemaVersion 4→5，`request_id` 即主键）+ `OutboxQueue`（严格 FIFO / 队首阻塞 / 退避 2s×2ⁿ 封顶 5 min / 上限 10 次 / `request_id` 幂等）+ 控制器 `send` 入队与 `delivered` 回显注入 + 「待发送」条（取消/重试/丢弃）+ 两端 `outboxQueueProvider`（**非** autoDispose，App 启动预热）。共 93 条用例。⚠️ 与 A/B 相反：**存储失败抛 `StorageError` 不静默降级**（装的是用户输入） | issue #30、`docs/offline-cache-design.md` §7bis |
| 离线缓存切片 C 的「反向验证为 0」 | ⚠️ **唯一一条**（诚实记录）：`drain` 进度哨兵——正确代码上不可达，属 **fail-safe**（拦「将来有人改坏 `_nextSendable`」，把挂死变成记 error + 中断）。另两条初版缺口（store `delete`/`clear` 静默降级、`onConnectivityRestored` 不碰 `failed`）**已补测** | `docs/offline-cache-design.md` §7bis.11 |
| ⚠️ bcc `partyb-go-api` 的 `chat_turns` / `chat_groups` / `chat_events` 全为 0（2026-10-11 实测） | **待排查**（属 `super_partyb` 侧，不在本仓库）。2026-09-27 备份有 `chat_turns` 3559 行，而现库是一份缺 `chat_*` 数据的状态；`topics` / `user_memories` / `embeddings` 仍在 | §6.9.6 末尾注 |
| ~~两端装配层接线无守卫（漏接一端而测试仍绿）~~ | ✅ 已修（issue #39）：`tools/check_wiring_parity.sh` 比对两端 `ConversationPage(` 具名参数，差异必须命中显式豁免（`onOpenAgentFile`/`onRevealAgentFile` 仅桌面、`overflowItems` 仅移动）；接入 CI | issue #39、§6.17 |
| ~~接线守卫只覆盖 1 个组件 + 守卫自身假绿~~ | ✅ 已修（issue #42）：覆盖面扩到 `ConversationPage` / `GroupListPage` / `SettingsPage` / `SyncPage`（差异逐条写进豁免并注明理由）；**修掉守卫自身的假绿**——裸子串匹配命中了 `_SyncPage(` 私有包装（零参数被当成「两端一致」），改用词边界 + 返回全部调用点取并集；新增 `tools/check_wiring_parity_selftest.sh`（7 组合成输入，`awk` 抽真身而非副本）钉住解析器行为 | issue #42、§6.17 |
| ~~`database.g.dart` 无生成物漂移守卫~~ | ✅ 已修（issue #43）：新增 `tools/check_codegen.sh`（CI quality job）+ `tools/check_codegen_selftest.sh`（8 组用例）。守卫涉及**四个反直觉的坑**：① 根目录跑 build_runner 是静默空转（`wrote 0 outputs`）→ 必须按包执行；② 生成物不是 `dart format` 形态 → 比对前必须 format；③ build_runner 增量资产图使守卫**非幂等**（第一轮报漂移、第二轮报一致）→ 比对前先删输出；④ `diff \| head` + `pipefail` 会 SIGPIPE 中止在还原之前 → 落临时文件再 head。顺带清理 `melos.yaml` 的空转 + 已失效 flag、`coverage.sh` 的漂移分母、AGENTS.md §6.2 的过时说法 | issue #43、§6.21 |
| ~~对话页 `_rowKeys` 只注册不回收（跨 group 累积）~~ | ✅ 已修（issue #39）：抽 `RowLocateRegistry`（注册 + 按「当前行 id 集合」回收，**不** `clear()` 重建）+ 领域层唯一口径 `locateIdsOf` / `locateIdsOfAll`；17 条用例，3 项反向验证逐条实测 | issue #39、§6.18 |
| ~~多个包声明了「全仓零 import」的依赖~~ | ✅ 已修（issue #36）：删 20 个零引用依赖（spb_core 的 meta/collection；spb_models 的 freezed/json_serializable 全家桶；spb_api 的 http_parser/meta；spb_domain 的 collection；spb_data 的 path_provider/path/shared_preferences；spb_features 的 flutter_riverpod/go_router/spb_data），桌面插件从 spb_platform **下移到 apps/spb_desktop**；新增 `tools/check_unused_deps.sh` 守防复发 | issue #36、§6.2/§6.4 |
| `sqlite3_flutter_libs` 零 Dart import 但**不能删** | **有意保留**：它是原生插件（把 `libsqlite3.so` 打进 Android/iOS 包），drift 移动端运行时需要；已写进 `check_unused_deps.sh` 的显式豁免。实测 apk 含 `lib/{arm64-v8a,armeabi-v7a,x86_64}/libsqlite3.so` | issue #36、§6.4 |
| 两端 `providers.dart` 88 个同名 provider 未上提共享包 | **有意不做（本轮）**：属独立重构，且平台相关装配需留在各 app；当前只把「接线一致性」做了自动守卫（§6.17） | issue #39 |
| ~~超长文件（`conversation_page.dart` 2587 行 / 测试文件 3845 行等）~~ | ✅ **测试文件已拆**（issue #48）：11 个 >1000 行的测试文件 → 34 个（全部 < 1500 行），按 group 边界拆 + `test/support/*_harness.dart` 共享夹具；**纯移动、0 断言变化**（用例名逐条 diff 一致：150/94/110/140/54/67/68/81/68）。**`conversation_page.dart` 本身（2587 行）仍未拆**——那是产品代码重构，与测试拆分不同批 | issue #48、§6.27 |
| ~~issue #48「80 处真实等待，只有 1 个文件用 `fakeAsync`」~~ | ⚠️ **实测不成立**（已纠正）：78 个命中全是 `tester.pump(Duration)`——Flutter 的**假时钟**，零 wall time（对照实验：`50 × pump(2s)` = **8ms**）。真实等待全仓只有 **2.6 秒**，且大部分不可消除（真实 `ResponseBody.stream` 需真实事件循环；§6.23 的调度证据测试需真实 microtask 时序）。故 `fakeAsync` 改造**收益接近零**，未做 | issue #48、§6.27 |
| ~~无任何测试跨过真实 HTTP + 真实 SSE 字节流~~ | ✅ 已补（issue #48 第三部分）：`packages/spb_api/test/sse_end_to_end_test.dart`（13 条，纯 Dart `dart:io HttpServer`）。覆盖 UTF-8 跨分片（issue #41 的真实缺陷，`DioAdapter` 因一次投递完整字节而**永远复现不到**）、`\r\n` 分片、逐字节分片、cursor 契约、401/500 分类。**反向验证**：改回「每片独立 `utf8.decode`」→ 2 条失败 | issue #48、§6.27 |
| ~~`groupConfirmations` 拼错路径（缺 `/api` 前缀，必然 404）~~ | ✅ **已修**（issue #49，本轮查出的真实缺陷）：客户端拼 `/chat/groups/:id/confirmations`，而服务端注册的是 `/api/chat/groups/:group_id/confirmations`（`ext_routes.go:40` + `router.go:168` 的 `apiv1 := r.Group("/api")`）。该方法此前零生产调用者，缺陷潜伏（与 §6.14 的 `createTurn` 同一模式）。⚠️ webapp 也拼错路径，属上游缺陷 | issue #49、§6.28 |
| ~~`chat_api.dart` 覆盖率 66.9%，多个零调用者端点无契约测试~~ | ✅ 已补（issue #49）：`chat_api_contract_test.dart`（31 条，**真实 `HttpServer`**——`DioAdapter` 测不出路径缺陷）。覆盖 group CRUD / timeline / turns / confirmations / sendMessage。`chat_api.dart` 66.9% → **85.8%**，`spb_api` 82.6% → **87.8%**（用例 386 → 430）。**反向验证** 6 项逐条实测（含 `groupConfirmations` 缺 `/api`、`patchGroup` 发全量键、`sendMessage` 无条件发 `group_id`） | issue #49、§6.28 |
| ~~双栈端点只降不升（切网后需重启才能回到 IPv6 源站）~~ | ✅ 已修（issue #50）：`EndpointGuard` 不对称迟滞——连续 3 次**连接层**失败立即降级回编译期地址，冷却 5 分钟后在有请求成功时重探，可达即升回源站。只数连接层失败（4xx/5xx 不算）；`EndpointProbeOutcome.downgraded` 与 `kept` 区分开；全程不重建 Dio/SSE（`EndpointRewriteInterceptor` 逐请求重读 + `SseClient.switchBaseUrl` 换 host），故对话时间线不会冻结。顺带修掉 `SseClient.resume()` 不重置退避计数（手动重连只能赌一次）。共 40 条用例，19 项反向验证逐条实测（`tools/reverse_verify_issue50.sh`） | issue #50、§5.1.1 |
| 契约同步靠人工 | 可接受 | §6.2 |
| ~~客户端无崩溃上报与远程日志通道（只能靠用户口头描述）~~ | ✅ **第一层已实现**（issue #40）：设置页「导出诊断日志」→ 环境信息（版本/平台/Flutter/服务地址，**非机密**）+ `SpbLog` 环形缓冲（最近 500 条）→ 系统「另存为」。导出前过 `redactSecrets`（Bearer/JWT/已知前缀令牌/PEM/`user:pass@`/凭据类键名）；四态反馈（已导出/取消/失败/不支持），取消不弹提示。**第 2、3 层（崩溃上报、`integration_test/`）有意不做** | issue #40、§6.20 |
| ~~无全局错误处理（异常进不了诊断报告）+ outbox 三处静默吞异常~~ | ✅ 已修（issue #45）：`spb_platform` 新增 `installGlobalErrorHandlers`（`FlutterError.onError` + `PlatformDispatcher.onError` + `runZonedGuarded` **三道防线**，两端 `main()` 第一步装配），异常第一次能进「导出诊断日志」；`outbox.dart` 三处 `catch (_) {}` 补日志（`upsert(failed)` 用 warn），另补 `sync_scope_config` / SSE 载荷丢弃 / 角标 / 标题预取 / habits / confirmations 六处；新增 `tools/check_silent_catches.sh`（269 处 catch 零误报）+ 6 条自测断言 | issue #45、§6.24 |
| ~~覆盖率低且 `spb_data` 数字失真~~ | ✅ 已修（issue #38）：`tools/coverage.sh` 剔除生成代码（`*.g.dart` 等，可见、可用 `COVERAGE_INCLUDE_GENERATED=1` 看原始值）；`database.dart` 的 7 个 drift 表类标 `coverage:ignore-start/end`（运行时不可达）；补 `spb_models` 契约/容错用例与 `spb_data` 的跳版升级、两个 open 工厂、五条 `StorageError` 写失败路径。总计 75.7% → **83.4%**（**这是 #38 当时的数字**；当前总计见 §6.13 的表，别把它当现值），`spb_data` 43.8% → **98.3%**，`spb_models` 50.6% → **85.2%**（当时；#41/#45 后为 88.0%） | issue #38、§6.13 |
| ~~SseClient 传输层 0.7% 无测试（上层全用 Fake）~~ | ✅ 已修（issue #41）：新增 `packages/spb_api/test/sse_client_test.dart`（31 条），`sse_client.dart` **0.7% → 98.1%**、`spb_api` 72.3% → **82.6%**。**顺带测出一个真实缺陷**：分片边界落在汉字 UTF-8 序列中间时，逐分片 `utf8.decode(allowMalformed: true)` 会把「中文」损坏成「���文」且不可恢复（`allowMalformed` 是「解不出替换成 U+FFFD」，不是「缓冲到下一分片」）；已改用 `Utf8Decoder.startChunkedConversion` 增量解码。7 项反向验证逐条实测 | issue #41、§6.22 |
| ~~每条 SSE 事件触发全量归约（长回复流式期间卡顿）~~ | ✅ 已修（issue #44）：`_emit` 把归约合并到一个**事件循环任务**，同一批 N 条增量只归约一次。实测 300 条增量（缓冲区 2000）**640 ms → 19 ms**。⚠️ **issue 建议的 `scheduleMicrotask` 方案实测不成立**——broadcast stream 把 N 次同步 `add` 投递成 N 个独立 microtask，microtask 排的 flush 会夹在每个事件之间（实测 5 条 → 5 次归约）；只有 `Timer` 能跨过整批。`touchedTurnId` 相应改为 `Set`（一批可含多个 turn）；新增 `_reductionDirty` 脏标记保证同步读不拿旧缓存。12 条用例 + 5 项反向验证 | issue #44、§6.23 |
| ~~AGENTS.md 与代码漂移~~ | ✅ 已修（issue #37）：删 §6.9.6 末尾**逐字重复**的生产异常段、删 §7 前的多余 `---`、§6.15 的 `_summarize`→`searchConversationItems` 与 `hasMore`→`upperHistoryUnloaded`、移动端 router 的 `_narrowActions`→`_appBarActions`、桌面端 router 4 处「与桌面端」→「与移动端」；新增 `tools/check_agents_refs.sh`（只查下划线成员/snake_case 调用/`.dart` 文件名三类，零误报）守防复发 | issue #37、§6.19 |
| ~~AGENTS.md 数字漂移 + 真实生产标识残留~~ | ✅ 已修（issue #46）：§6.12 的 808→**878**、782→**1569**、量级分布全部重测；§11 的 83.4% 标注为「#38 当时的数字」（与 §6.13 不再自相矛盾）；新增 `tools/check_agents_numbers.sh`（**容差 5%**：小漂移放行、大漂移拦住；命令单一定义在脚本里并**断言文档展示的命令与之逐字相同**）+ 6 条自测断言。清理 `docs/m0-manual-verification.md` 的生产 IP / 内部域名 / 本地绝对路径，并在 §3 写明 `scrub-history.sh` 的使用顺序（它只重写历史，工作区需**先清干净**） | issue #46、§6.25 |
| ~~无 `.gitattributes`（Windows `autocrlf` 下 `dart format` 必红）/ 无依赖自动更新 / 第三方 action 浮动 tag / 严格模式未开 / 无变更记录 / `tools/` 清单不完整~~ | ✅ 已修（issue #47）：`.gitattributes` 用 `* text=auto eol=lf`（只写 `text=auto` 在 Windows 上仍检出 CRLF，实测对照）+ 二进制规则（**12 个 golden PNG 逐字节比对**，不能做任何转换）；`.github/dependabot.yml`（pub weekly + actions monthly，文件头注明权威远端是 Gitea）；第三方 action pin SHA（`subosito/flutter-action@1a44944` / `android-actions/setup-android@9fc6c4e`），官方 `actions/*` 保留 `@v4`；**三项严格模式全开**（实测 107 → 0，`strict-inference` 的 103 条含 79 条测试 JSON 固定数据）；release notes 改为 `git log <上一个 tag>..HEAD` 生成（需 checkout `fetch-depth: 0`）；`tools/` 树补齐至 14 个非自测脚本并由 `check_agents_refs.sh` **反向守卫**（新增 `check_agents_refs_selftest.sh` 4 条、`check_workflow_steps_selftest.sh` 5 条） | issue #47、§6.26 |

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
| 交付物回传（本地改动 → agent） | `docs/deliverable-upload-and-conflict.md` |
| 对话数据本地缓存（issue #26 设计） | `docs/offline-cache-design.md` |
| 手工验证清单（含 §2.7 可访问性） | `docs/m0-manual-verification.md` |
| Go API 契约与业务逻辑 | `super_partyb/AGENTS.md` |
| Tauri 桌面端（迁移来源） | `super_partyb/apps/desktop/README.md` |
| 微信小程序（BFF 可复用） | `super_partyb/apps/miniapp/README.md` |
| SSE 服务端实现 | `super_partyb/apps/go-api/internal/server/chat_stream.go` |
| 事件类型真源 | `super_partyb/apps/go-api/internal/chatbus/broker.go` |
| Flutter 官方 Windows 构建 | https://docs.flutter.dev/platform-integration/windows/building |
| Flutter 官方 Windows 分发 | https://docs.flutter.dev/deployment/windows |
