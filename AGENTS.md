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
    ├── check_build_defines.sh      # 发布构建必须传 --dart-define（见 §6.33）
    ├── check_format.sh             # dart format 门禁
    ├── check_test_support_sync.sh  # 跨包重复的测试辅助文件必须逐字节相同
    # 工具
    ├── coverage.sh                 # 逐包覆盖率采集 + 汇总表（剔除生成代码）
    ├── bundle_linux_deps.sh        # Linux 分发包依赖打包（非系统库 + RUNPATH）
    ├── gen_brand_assets.py         # 从品牌 SVG 生成各端图标（见 §6.32）
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
- **Bearer 必须是 IdP 的 `id_token`（RS256 JWT），不能是 `access_token`**：后者是
  fosite 的不透明串（`ory_at_…`），网关的 JWT / OIDC 两个认证器都要求 compact JWS
  三段式，会直接 401。取值规则只有一处：`OidcTokens.bearerToken`
  （`idToken ?? accessToken`），落盘统一走 `StoredTokens.fromOidcTokens`。
  这是 2026-10 的真实缺陷，详见 §6.37

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

### 6.11 桌面端托盘菜单（7 项）

`apps/spb_desktop/lib/desktop_integration.dart` 的 `_installTrayMenu` 推送 7 个可点项：

| 项 | 动作 |
|---|---|
| 显示主窗口 | `showWindow(main)` |
| 快速输入（Alt+Space） | 进悬浮模式（见 §6.5） |
| 立即同步交付物 | `onSyncNow`（未注入回调时禁用） |
| 打开同步目录 | `caps.revealPath(同步目录)`（**未配置同步目录时禁用**） |
| 同步设置… | `_openSyncSettings()` → `/settings/sync` |
| 设置… | `_openSettings()` → `/settings`（见下「两个设置入口为什么都要有」） |
| 退出 | `PlatformDesktopQuit.quit` |

**「打开同步目录」为什么在未配置时禁用**：此时 `revealPath` 拿到空串，文件管理器
会落到用户主目录——看起来像「功能坏了」而不是「还没配」。

**「同步设置…」为什么走 `SpbRouter.sync` 而不是 `showWindow(settings)`**：
`WindowRole` 只有 main / settings / quickCapture，没有 sync 这个角色——同步设置是
`/settings/sync` 这个**子页面**，不是独立窗口。`showWindow(settings)` 只会落到设置
页首个 tab，用户还得自己再点一次「同步」，而托盘项的标签承诺的是直达。

**「同步设置…」与「设置…」为什么两个都要有**（2026-10 补的第二个）：

它们是**不同目标**，不是重复项：

| 项 | 目标 | 内容 |
|---|---|---|
| 同步设置… | `/settings/sync` | 「立即同步」按钮 + 本轮结果 + 目录 |
| 设置… | `/settings` | 同步目录 / 范围 / 媒体开关 / 单文件上限 / 本地清理 / 外观 / 个人偏好 / 导出诊断日志 |

⚠️ 在此之前桌面端**没有任何 UI 入口能到 `/settings`**：托盘只有「同步设置…」
（直达子页），列表 AppBar 也没有设置图标，而 `WindowRole.settings → /settings`
的映射虽然存在、生产代码里却**无调用方**（只有测试会 `showWindow(settings)`）。
于是上表右列那些配置在界面上完全不可达，只能靠深链。

**两个「始终可用」**：「同步设置…」与「设置…」都**不**依赖 `isSyncConfigured`
——它们正是**配置入口**，禁用会让未配置的用户无法完成配置（死锁）。

**「设置…」为什么直接 `_router.go` 而不走 `caps.showWindow(settings)`**：本类已持有
router，且 `WindowRole.settings` 的映射也在本类里（`_navigateToRole`）。绕一圈回到
自己的能力层会让「从悬浮窗切到设置要还原窗口」依赖桩实现是否转发 `onShowWindow`
——测试桩不转发，断言路由的用例就会莫名其妙地红。还原窗口仍必须做（见
`_openSettings` 里的 `_exitOverlayWindow()`）。

**设置页的另一个入口在对话列表 AppBar**（`GroupListPage.onOpenSettings`，
`Icons.settings_outlined`）：桌面端各应用都把设置放在主界面标题栏，托盘是辅助
入口。移动端**不接**这个参数——那里设置是底部标签栏的一级 tab，AppBar 再放一个
就是同一目标的第二个入口，而窄屏 AppBar 已有 5 个常驻图标（§6.16 的溢出教训）。
该差异登记在 `tools/check_wiring_parity.sh` 的 `exempt["desktop"]`。

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
# 当前（HEAD）量：901
cd packages/spb_features && grep -rhoP "'[^']*[\x{4e00}-\x{9fa5}][^']*'" --include=*.dart lib | wc -l
# <!-- number-check: name=spb_features_hardcoded_zh value=901 -->

# 全仓（9 个 packages + 2 个 apps 的 lib/）
# 决策时基线：约 1200（未单独记录）；当前（HEAD）量：1630
grep -rhoP "'[^']*[\x{4e00}-\x{9fa5}][^']*'" --include=*.dart packages/*/lib apps/*/lib | wc -l
# <!-- number-check: name=repo_hardcoded_zh value=1630 -->

# 是否已接入 i18n（应为空输出）
grep -rn 'AppLocalizations\|flutter_localizations\|package:intl' --include=*.dart packages/*/lib apps/*/lib
grep -rn 'localizationsDelegates\|supportedLocales' --include=*.dart apps/*/lib
```

量级分布（HEAD，字符串字面量数）：`spb_features` 901、`spb_domain` 176、
`spb_desktop` 157、`spb_models` 97、`spb_mobile` 92、`spb_platform` 76、
`spb_api` 71、`spb_data` 39、`spb_core` 13、`spb_ui` 5、`spb_design` 3。

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
| `spb_data` | **98.3%** | `spb_platform` | 62.6% |
| `spb_features` | **93.5%** | `spb_mobile` | 56.7% |
| `spb_core` | **91.5%** | `spb_desktop` | 63.2% |
| `spb_domain` | 89.4% | `spb_api` | **88.5%** |
| `spb_models` | 88.0% | `spb_ui` | 73.7% |
| `spb_design` | 86.0% | **总计** | **85.7%**（≈16291/19004） |

全仓用例 **3765 条**（`testDone` 且非 hidden 计数；issue #48 拆分后，拆分本身
0 变化。+13 是 SSE 端到端（§6.27），+31 是零调用者端点契约（§6.28），+6 是
§6.37 的 `bearerToken` / `fromOidcTokens` / 两端接线回归防线，+38 是 §6.41 的
定位与下载布局，+66 是 §6.42 的自动同步，+50 是 §6.43 的进对话按需同步）。

⚠️ **数用例时别用 `grep -c '"type":"testStart"'`**：它把 skipped 与
`setUp`/`tearDown` 产生的条目也算进去（实测差 100+ 条）。用
`testDone` 且 `hidden != true` 才是「真的跑过的用例数」。

⚠️ **这张表会漂移**——用上面的命令重跑，别把这里当权威数字。
⚠️ `spb_ui` 从 79.8% 掉到 73.7% **不是回归**：`copy_icon_button.dart`
（23 行）在 `spb_ui` **自己的**测试里零覆盖——它只被 `spb_features` 的
气泡测试点过，而 `coverage.sh` 是**逐包**采集的，看不到跨包调用。
这是既有缺口（要么给 `spb_ui` 补一条单测，要么接受），与 §6.37 无关。
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

#### 对话页 AppBar 标题用 `group.title`（不是硬编码的「对话」）

两端 router 都传 `title: _appBarTitle`（取自 `_group.title`，未就绪/为空时退回
「对话」）。**列表页**的 AppBar 也叫「对话」——对话页若同样硬编码，用户点进去后
看不出自己是否真的进了某个对话、进的是哪一个（从搜索结果 / 待确认列表跳进来
时尤其明显）。

⚠️ **两端的用例必须在 router 层断言**：`ConversationPage` 自己的测试**自己传
`title`**，所以「router 又写回硬编码」在页面测试里永远发现不了（与本节开头的
失败模式同一个）。两条用例分别见
`apps/spb_desktop/test/router_chat_test.dart` 与 `apps/spb_mobile/test/router_chat_test.dart`
的 `进入对话后 AppBar 标题是 group.title…`。

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
断言（`row_locate_registry_test.dart` 17 条、`agent_file_batch_test.dart` 新增 5 条）。

#### ⚠️ 键的**所有权**必须与「成员定位入口」分开（一次真实事故）

上面那句「批内 5 个文件共用同一张卡、同一个定位点」曾被实现成「把同一个
`GlobalKey` 实例写给每个成员」。那是错的，用户报障是
**「对话内容一滚动就会丢失，然后继续滚动又出现」**。

| 表 | 内容 | 用途 |
|---|---|---|
| `_owned` | 行主键（`ids.first`）→ `GlobalKey` | **真正挂在 widget 上的键**，一行一个，绝不共享 |
| `_aliases` | 成员 id → 行主键**名** | 只供 `operator []` 查（批内任一成员都要能定位到那张卡） |

**为什么「共享键实例」会渲染空白**：一旦**同一段文件被拆成多行**，多行就会拿到
同一个 `GlobalKey` → Flutter 抛 `Multiple widgets used the same GlobalKey` →
**后出现的那几行渲染为空白**（滚走再滚回来又重建出来）。而 `recycle` 拦不住
——它按 id 是否在时间线上过滤，那些 id 确实还在。

拆分是真实会发生的，有两条路径：

1. **缓冲区裁剪**（`ChatStreamController._trimBuffer`，上限 `maxBufferEvents`=2000）
   从头部丢最旧事件，边界可能落在批量卡中间：7 个文件剩 4 个，不足
   `FILE_BATCH_MIN_COUNT`（5）→ 退回 4 个 `SingleItemRow`；
2. **翻页拼接**：`loadOlder` 前插的一页与缓冲区头部同 turn 同秒时会**合并**成
   批量卡；页边界若切在批中间，头部那段先以「不足阈值」落单，补上更早那一页后
   又并回批量卡。用户「滚上去、再滚下来」就能让它在两种形态间反复翻转。

故 `keyFor` 里**只有 `ids.first` 能成为键的所有者**，其余 id 只登记别名；且
`keyFor` 会把「上一帧还是主键、现在变成别名」的那个 id 从 `_owned` 里摘掉
（否则 `operator []` 按「主键优先」返回悬空键）。

#### 两个易写错的点（写测试时踩过）

1. **纯逻辑测试抓不到它**。`row_locate_registry_test.dart` 自己构造拆分状态，能
   钉住「各行拿到不同的键」，但钉不住「页面真的这样用它」。故另加页面级用例
   `conversation_page_row_keys_test.dart`（真实控制器 + 真实 `_trimBuffer`）。
2. **页面级用例必须分两阶段推事件，中间真正 `pump` 一次**。缺陷只在「页面已经
   为批量卡建好键、随后该卡被拆散」时触发；若把 2003 条一次推完再 pump，页面
   首次构建看到的**已经**是 4 个落单行，撞键根本不发生——用例会在**修复前的
   代码上变绿**（实测踩过）。

那条用例用 `executor_started`（诊断事件，进缓冲区但不产对话项、也不产
`executionStatus`）当填充物：既让裁剪逻辑与真实场景一致，又只渲染 4 行，
耗时 ~1s。换成 `user_message` 会让时间线真有 2000 行（`pumpAndSettle` 十几秒），
换成 `queue_state` 会挂出转圈的「排队中」条（`pumpAndSettle` 永不静止）。

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

### 6.28.1 归属反馈「点了没反应」：两个叠加的缺陷（2026-10）

用户报障「归属反馈卡点了没反应」。查下来是**两个独立缺陷叠加**，且都属
§6.28 同一类「零契约测试 + 错误断言把 bug 固化成预期」。

#### 缺陷一：请求体键名错（`correct` vs `reply`）——请求根本到不了 CAS

客户端发 `{'correct': bool}`，而服务端 `feedback_resolve.go` 的入参结构只有：

```go
type resolveFeedbackRequest struct {
    Reply   string `json:"reply"`
    Index   int    `json:"index"`
    GroupID string `json:"group_id"`
}
```

`ShouldBindJSON` **静默忽略未知字段**，于是 `Reply` 留空 →
`composeFeedbackReply` 返回 `""` → `400 {"error":"reply is required"}`。

实测（真实路由 + 临时探针）：

```
{"correct": true}  → 400 {"error":"reply is required"}
{"reply": "准确"}   → 200 {"resolved":true,"turn_id":"t1"}
```

修法：`ChatApi.resolveFeedback` 改发 `{'reply': correct ? '准确' : '不准确'}`。
两个词都落在 `confirmtext` 的肯定/否定词表里（端点会先 `Canonicalize`），
合成出的回执是 `反馈#<token>#正确`。文案选「准确」而非「正确」是为了与
卡片按钮 label（`FeedbackRequestCard.defaultOptions`）一致。

#### 缺陷二：置灰只依赖服务端旁路事件 —— 修完键名仍可能「没反应」

卡片 `resolved` 此前**只**看 `routing_feedback` 事件（`event_reducer.dart:542`）。
而回执是**一次性 CAS**，且该事件是旁路事件：

| 场景 | 结果 |
|---|---|
| SSE 断线 / 回放窗口被穿透 | 事件永不到达 → 卡片永久显示「这次归属准确吗？」且按钮可点 |
| 用户重试 | 第二次必然 404（CAS 已消费） |

用户看到的就是「点了没反应」，且越点越坏。

修法（三处协同）：

| 位置 | 改动 |
|---|---|
| `ConversationPage.onResolveFeedback` | 签名 `void` → **`Future<void>`**。确认卡可以 fire-and-forget（服务端会在同一 turn 内回 `confirmation_resolved` 收敛），反馈没有这条回路，必须把结果交回来 |
| `ConversationPage._handleResolveFeedback` | 成功才 `_submittedFeedback.add(token)`（乐观置灰）；失败 `_showMessage` 且**保留可点** |
| 渲染 | `resolved: item.resolved \|\| _submittedFeedback.contains(item.token)`——事件到达后权威接管，永不到达时也不退化 |
| 两端 router | 去掉 `.catchError(debugPrint)`，让异常上抛给页面 |

**404 的文案单独处理**：服务端把「已过期 / 已消费 / 非本人」三者**统一返回
404**（避免存在性探针，`interactive_request.go:120`）。写成「提交失败」会让
用户反复重试一个永远不会成功的请求，故提示「这条反馈已失效，无法再作答」。

#### 为什么修复前测试全绿（三处假绿）

| 既有测试 | 它断言了什么 | 漏了什么 |
|---|---|---|
| `spb_api` 全包 | **零条** `resolveFeedback` 用例 | 路径与请求体从未被验过 |
| `apps/spb_desktop/test/router_chat_test.dart` | `containsPair('correct', true)` | 断言的正是**错误键名**，把 bug 固化成了预期 |
| `apps/spb_mobile/test/router_chat_test.dart` | `containsPair('correct', false)` | 同上 |
| `conversation_page_timeline_test.dart` | 「点击回调收到 token 与 bool」 | 只测回调被调用，不看卡片后续状态 |

#### 本轮补的用例（共 11 条）

| 层 | 用例 |
|---|---|
| `spb_api` 契约（真实 `HttpServer`） | 肯定回执 `reply='准确'` 且**不含** `correct` 键；否定回执 `reply='不准确'`；token 原样进路径；404 抛 `HttpError` |
| `spb_features` | 提交成功后**本地置灰**（显示「已反馈」、按钮 `onPressed == null`）；提交失败提示且**保留可点**；404 提示「已失效」而非「提交失败」 |
| 两端 router | 断言改为 `containsPair('reply', …)` + 显式断言不含 `correct` |

#### 反向验证（实测）

| 改坏 | 结果 |
|---|---|
| 请求体改回 `{'correct': bool}` | `spb_api` 契约 **2 条失败** |
| 去掉 `_submittedFeedback` 乐观置灰 | 「提交成功后本地置灰」**1 条失败** |
| 失败也置灰 | 「失败时保留可点」**1 条失败** |

#### 与 TTL 的关系（**别再往那个方向修**）

`AttributionFeedbackTTL` 已是 **24h**（`domain.go:35`，按 kind 分派见
`InteractiveRequestTTLForKind`），生产实测 `expires_at - created_at = 24.0h`，
2026-10-18 起生效。用户报障时 34 条请求、0 条标注——**在请求根本发不出去
的情况下，TTL 多长都拿不到数据**。

「事件不超时、等归档后自然不能改」这个提案**不成立**，三条硬依据：

1. **`pending` 行的存在本身就是「待答」语义**。`LatestPendingAttributionFeedback`
   取「本 group 最近一条 pending」作隐式锚点（IM 纯文本路径）。永不超时 = 三个月前
   的请求仍可能被一句无关短回复命中。代码为此已单独加了
   `ImplicitAttributionFeedbackWindow = 2h`，但那只是**查询侧**的窄窗。
2. **归档拦不住回执**。`requireOwnedGroup` 的 SQL 是 `WHERE id = ? AND user_id = ?`
   ——**不校验 status**，且 `feedback_resolve.go` 的 handler 根本没调它（只有
   `currentUser` + token 直查）。要做到「归档即失效」得新增一道 status 校验。
3. **`pending` 堆积会污染去重闸**。`CountPendingInteractiveRequestsByGroup`
   的语义是「同 group 不重复问」，永久 pending 会让该 group 的后续反馈永久被堵。

注意三者是**不同的量**，不该合并：`chat_events` 保留（永久，eventretention
白名单明确保 `routing_feedback_request`）/ 回执窗口（24h）/ 隐式锚点窗口（2h）。

#### 6.28.2 TTL 的实质优化：不改数值，改它的三个实现缺陷（2026-10）

上一节论证了「24h 这个数值不该动」。用户随后要求「优化 TTL」——正确的解读是
**优化 TTL 的实现**，而不是调那个数字。实测（bcc，36 行 `chat_confirmations`）
确认了三个真实缺陷，全部与数值无关：

| # | 缺陷 | 后果 |
|---|---|---|
| 1 | `HasPendingChatConfirmation` **不按 kind 过滤** | 一条 pending 的归属反馈会让该 group 在**24 小时**内建不出任何确认卡，且完全静默 |
| 2 | TTL 是**编译期常量** | 调一个数字要重新构建 + 部署整个 `go-api`；`domain.go` 注释自己早就预留了「如需运维按部署调谐，再升级到 runtimeconfig」 |
| 3 | 客户端**无从知道卡片已失效** | 请求事件 payload 不带 `expires_at`，而回执过期后服务端统一 404 → 用户点一张早已过期的卡，「点了没反应」 |

##### 缺陷 1：确认卡被反馈静默吞掉

`HasPendingChatConfirmation`（`internal/repo/sqlite/schedules.go`）是
`EnsureConfirmationCard` 的**去重闸**：有 pending 就不建新卡。而归属反馈与确认卡
**共用 `chat_confirmations` 表**，只是 kind 不同。

历史上两者 TTL 都是 10 分钟，不过滤 kind 也无大碍。24h 之后：

```
Turn A 完成 → 发归属反馈 → 一行 pending 挂 24h
Turn B 需要用户确认 → 去重闸看到 pending → 跳过
                    → 不发 confirmation_required → 用户永远看不到卡
```

两个 kind 的 pending 语义**本来就不同**：确认卡 pending = 「有一个 turn 卡在那里
等人拍板」（阻塞、必须处理）；反馈 pending = 「有个可选问卷还没填」（不答无害）。
拿后者去堵前者是**语义错位**，不只是过滤漏项。

修法：SQL 加 `AND kind <> ?`（参数 `domain.KindAttributionFeedback`）。

⚠️ 当前生产 `ARBITER_MODE` 未设置（默认 shadow → `commitConfirm` 不建卡），故
这个缺陷是**潜伏态**——一旦切 `enforce` 立刻生效。而它**没有任何日志**：
`skip, group already has pending` 看起来就像一次正常去重。

##### 缺陷 2：TTL 改为可热调（runtimeconfig）

只让**归属反馈**可覆盖，确认卡保持编译期常量——后者的寿命不是产品选择而是结构
约束（它挂在 pending turn 上，turn 的墙钟预算就是上限；调大只会让「卡还在但 turn
已经死了」变得可能）。

| 层 | 改动 |
|---|---|
| `runtimeconfig.Snapshot` | 新增 `AttributionFeedbackTTL`（`runtime.attribution_feedback_ttl_seconds`） |
| `runtimeconfig.apply` | `>= 0` 才写入——**0 是合法值**（「不覆盖，用 domain 默认」） |
| `domain.InteractiveRequestTTLForKindWithOverride` | 新函数；`override <= 0` 回落到 `InteractiveRequestTTLForKind` |
| `chatgate.IssueInteractiveRequest` | 新增 `feedbackTTLOverride time.Duration` 参数 |
| `chatpipeline.Pipeline.attributionFeedbackTTL()` | 从 `runtimeCfg.Current()` 读 |
| `runtimeCatalog` + `envValueForKey` | 登记（**漏任一处即静默失效**，见 §6.26 的三处登记规则） |

⚠️ **`envValueForKey` 必须返回 domain 默认的 24h，不能走 default 分支的 0**：
页面把 0 展示给管理员会被读成「功能关闭」。这与 `runtime.gate_timeout_seconds`
曾经踩过的坑同型——**守卫精确抓到了这一处**（`TestRuntimeCatalogEnvValueResolvable`
在只加了 catalog、没加 `envValueForKey` 时立刻 FAIL）。

⚠️ **`0` 的语义是「不覆盖」而不是「立即过期」**：`Snapshot` 的零值就是 0，故
「没配这个参数」时走的就是这条路径。方向写反会让所有反馈请求在签发的同一秒失效，
现场表现是「卡片点一下就说过期」，**比不配置更糟**。

##### 缺陷 3：把有效期下发给客户端

`GET /api/chat/turn-runtime` 新增 `attribution_feedback_ttl_seconds`。客户端用
「事件 `createdAt` + TTL」自行判定失效并**置灰为「已失效」**，把 404 从主路径
降为兼容路径（旧事件 / 时钟偏差）。

| 层 | 改动 |
|---|---|
| `server/chat_runtime.go` | 响应新增字段；下发**生效值**（含管理员覆盖），不是编译期常量 |
| `spb_models.TurnRuntime` | `attributionFeedbackTTLSeconds` + `attributionFeedbackTTL`（上限 7 天，`null` = 未下发） |
| `spb_domain.FeedbackRequestItem.isExpired({ttl, now})` | 纯判据，`now` 可注入便于固定时钟 |
| `spb_domain.ChatStreamController` | 与 `_turnTimeout` 同批记下（同一次 HTTP 往返） |
| `spb_features.FeedbackRequestCard` | 新增 `expired` 参数 |
| `spb_features.ConversationPage` | `expired: item.isExpired(ttl: _feedbackTTL)` |

⚠️ **`expired` 不能折进 `resolved`**。若合并，过期卡片的标题会写成「已反馈」
——用户**没答过**，那是在说一件没发生的事。与 §5.4「没有终态事件就不写已中断」
同一取向。故卡片是三态：`已反馈` / `已失效` / `这次归属准确吗？`（图标也分开：
`task_alt` / `timer_off_outlined` / `rule`）。

⚠️ **`ttl == null` 时 `isExpired` 恒 false**（旧版后端）：把「未下发」当成
「立即过期」会让所有卡片一次性变灰，比不判定更糟。同 `TurnRuntime.clientTurnTimeout`
对 0 的处理取向。

⚠️ **`canResolve` 有意不包含有效期判定**：它拿不到 TTL。若把 TTL 折进去，就得给
getter 加参数、改所有调用点——那是一次接口变更，不是「顺手修个 bug」。故判据分成
两个：`canResolve`（token + resolved）与 `isExpired(ttl:)`，调用方两者都看。

##### 数据依据（bcc 实测，2026-10-21）

| 观测 | 值 | 说明 |
|---|---|---|
| `chat_confirmations` 总行数 | 36 | 全部是 `attribution_feedback`（无确认卡，因 Arbiter 是 shadow） |
| 按 TTL 分组 | `0.2h`×30 expired / `24.0h`×3 expired + 1 pending + **2 resolved** | 24h 生效后回执率从 **0/30** 变成 **2/6** |
| 两条 resolved 的作答耗时 | **1.8 分钟**、**13.6 分钟** | 后者超过原 10min TTL，直接佐证 24h 的必要性 |
| 单 group 一天内请求数 | 23（`fd648ced`） | 全 expired（10min 时代的产物） |
| 表占用 | 28 KB | 清理**不是**当前瓶颈，故本轮**未**加保留期 janitor |

⚠️ 第 3 行是本轮**没有**调数值的依据：数据证明 24h 是对的。故「优化 TTL」落到
实现上——修复 3 个会让它**静默失效**的缺陷，而不是再猜一个数字。

##### 新增用例（Go 7 条 + Flutter 12 条）

| 文件 | 条数 | 钉住 |
|---|---|---|
| `internal/repo/sqlite/has_pending_confirmation_test.go` | 3 | 反馈 pending **不**堵确认卡；真确认卡仍拦；已过期不算待处理 |
| `internal/chatgate/interactive_request_ttl_test.go` | +2 | 覆盖值只作用于归属反馈（确认卡仍 10min）；**0 = 回落默认**（不是立即过期） |
| `internal/server/chat_runtime_test.go` | +1 | 下发 domain 默认 24h（**不是 0**）；覆盖后下发覆盖值 |
| `packages/spb_models/test/turn_runtime_test.dart` | +6 | 解析 / 未下发为 null / 0 与负数 / 7 天截断 / 恰好 7 天 / 字符串数字 |
| `packages/spb_domain/test/feedback_request_item_test.dart` | 10 | `isExpired` 六态（超/未超/恰好/ttl=null/已 resolved/时钟偏差）+ `canResolve` 四态 |
| `packages/spb_features/test/chat/conversation_page_timeline_test.dart` | +2 | 过期置灰为「已失效」且**不**显示「已反馈」；TTL 未下发时保持可点 |

##### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| `HasPendingChatConfirmation` 去掉 `AND kind <> ?` | 1 条失败（`归属反馈的 pending 行不应让确认卡去重闸返回 true`） |
| `InteractiveRequestTTLForKindWithOverride` 忽略 override | 1 条失败（实际 86400s，期望 5400s） |
| override 误用到所有 kind | 1 条失败（确认卡 5400s，期望 600s） |
| `override > 0` 改成 `>= 0` | 1 条失败（0 时实际 600s，期望 86400s） |
| 页面 `expired: item.isExpired(...)` → `false` | 1 条失败（找不到「已失效」） |
| `isExpired` 里 `ttl == null` 改成 `return true` | **5 条失败**（全部卡片变灰） |

⚠️ 最后一项的反向验证**踩了一次自己的坑**：用 `git checkout` 还原时把
`conversation_item.dart` 的**新增代码整段冲掉了**（那是未提交的工作区改动）。
反向验证若用 `git checkout` 还原，必须确认该文件**没有未提交的新增内容**
——本轮改用 `cp` 备份/还原。

---

### 6.29 开源镜像同步（`tools/sync-to-github.sh`）

权威源是 **Gitea**（`git@<gitea-host>:dever/super_partyb-flutter.git`，完整历史 +
blame）。GitHub 上另有一份**公开镜像**：
**`git@github.com:727277gh1/super_partyb-flutter.git`**（`main` 分支），用 squash
方案导出：只含「恰好 HEAD 这一棵树」，一条提交。

> 镜像地址写在这里是**有意的**：它本来就是公开信息（GitHub 页面 + 提交 author
> 都可见，`727277gh1` 同时是 noreply 邮箱前缀），不写只会让下次同步的人再问一遍。
> 真正需要隐藏的是**生产部署标识**（域名 / IP / 目录 / 邮箱），那些在仓库外的
> 映射文件里。

```bash
# 三个变量都没有内置默认值以外的必需项：前两个有默认路径，第三个**必须**设。
export SPB_OS_MAP="$HOME/.config/spb-flutter/opensource-map.env"
export SPB_OS_EXTRA_RULES="$HOME/.config/spb-flutter/extra-rules.txt"
export SPB_GITHUB_REMOTE="git@github.com:727277gh1/super_partyb-flutter.git"

bash tools/sync-to-github.sh --verify    # 只校验**当前工作区**是否已干净
bash tools/sync-to-github.sh --dry-run   # 预演：导出 + 替换 + 校验，不推送
bash tools/sync-to-github.sh             # 执行（force-push）
bash tools/sync-to-github.sh --help      # 打印脚本头部的说明
```

`--verify` 与 `--dry-run` 的区别（易混）：前者查的是**工作区**（回答「我的仓库
里还有没有真实值」），后者查的是**导出的临时树**（回答「这次推送会带出什么」）。
未清理干净时 `--verify` 报残留而 `--dry-run` 也报——但只有后者会真的中止推送。

#### 可选环境变量（文档曾漏记，实测补齐）

| 变量 | 默认值 | 用途 |
|---|---|---|
| `SPB_GITHUB_REMOTE` | **无（必填）** | 目标仓库。未设时 `run` 模式直接报错退出 |
| `SPB_OS_MAP` | `$HOME/.config/spb-flutter/opensource-map.env` | 真实值 → 占位符映射 |
| `SPB_OS_EXTRA_RULES` | `$HOME/.config/spb-flutter/extra-rules.txt` | 映射表装不下的形态 |
| `SPB_GITHUB_BRANCH` | `main` | 推送到哪个分支 |
| `SPB_SYNC_COMMIT_MSG` | `chore: import super_partyb-flutter (Flutter 客户端)` | 镜像上那条提交的正文 |

⚠️ **GitHub 上那条 `chore: import super_partyb-flutter (Flutter 客户端)` 是脚本
产物，不是手写提交**。看到它不要以为是有人手工 import——它的作者信息
（`jim <727277gh1@users.noreply.github.com>`）也**继承自主仓库的 `git config`**
（脚本显式用 `git -c user.name=... -c user.email=...` 传入，避免公开仓库里出现
意外的作者信息）。

#### 它内部在 `/tmp` 里建了一个一次性仓库（退出即删）

`/tmp` 那个临时仓库不是人工建的，是脚本自己建的：

```bash
work=$(mktemp -d)          # 第 94 行
cleanup() { rm -rf "$work"; }
trap cleanup EXIT          # 第 96 行：退出时自动删除，故事后找不到
```

六个步骤（对应脚本第 215–256 行）：

| # | 动作 | 行 |
|---|---|---|
| 1 | `git archive HEAD \| tar -x -C "$work/tree"` — 只导出 HEAD 那棵树（不含 `.git` / 未跟踪 / 构建产物） | 215 |
| 2 | `apply_rules` — 按规则替换**文本**文件（`grep -I` 跳过二进制） | 218 |
| 3 | `verify_clean` — 任一真实值残留则**中止，不推送** | 221 |
| 4 | `git init -q -b "$BRANCH"` — 在临时树里建**全新孤立仓库** | 245 |
| 5 | `commit -m "$COMMIT_MSG"` — 单条提交 | 250 |
| 6 | `git push -f -u github "$BRANCH"` — force-push | 256 |

⚠️ **工作区有未提交改动时脚本只警告、不中止**（第 205–208 行）：`git archive`
只导出 HEAD，未提交的东西**不会**进镜像。想包含就先提交——否则会出现「本地
改了但 GitHub 上没变」的困惑。

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

#### 实测：镜像对应哪个 Gitea 提交（2026-10-20）

GitHub 上当时的 HEAD `8715622` 对应 Gitea 的 **`30cbbf2`**（品牌图标那次）：

```bash
git worktree add --detach /tmp/gitea-x 30cbbf2
diff -rq --exclude=.git /tmp/gitea-x /tmp/gh-clone
# → 只有 2 个文件不同，且差异全是**脱敏替换**：
#     AGENTS.md              （idp.<internal-domain> → idp.<internal-domain>，tbcc → app.example.com）
#     .github/dependabot.yml （<gitea-host> → git@<gitea-host>）
```

时间戳也对得上（Gitea `11:23:52` → GitHub `11:24:03`）。故**核对镜像是否落后**
的可靠办法不是看提交标题（每次都一样），而是逐文件 diff：

```bash
git clone --depth 1 https://github.com/727277gh1/super_partyb-flutter /tmp/gh-check
git worktree add --detach /tmp/gitea-head HEAD
diff -rq --exclude=.git /tmp/gitea-head /tmp/gh-check   # 只应有脱敏替换造成的差异
```

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

#### 四、`app2.example.com` **应该**配进 `SPB_PREFERRED_HOSTS`（含一次错误判断的纠正）

**本节最初写的是「不应配置」，结论错了。** 记录纠正过程，因为错误的推理方式
比错误本身更值得防。

**当时的错误推理**：DNS 实测显示 tbcc6 指向家宽动态地址，于是判为「不是可用
的生产端点」，并认为配置它会「制造随机故障」。DNS 事实（下列仍准确）：

| 证据 | 值 |
|---|---|
| CNAME 链 | `app2.example.com` → `qpoweiurty.atjog.com`（随机串，DDNS 特征） |
| AAAA | `2409:8a55:a20:8570:be24:11ff:fee3:581a` |
| 地址段 | `2409:8a55::/32` = 中国移动（家宽段） |
| 接口标识 | `be24:11ff:fee3:581a` = EUI-64（由网卡 MAC 推导）→ 动态地址 |
| TTL | CNAME 600s（DDNS 常用短 TTL，便于换 IP） |

**错在哪**：§5.1.1 的机制**就是为「首选端点可能不可达」设计的**，把
「地址会变」当成否决理由，等于把设计要容错的情形当成了缺陷。逐条看代码：

| 顾虑 | 代码事实 |
|---|---|
| 地址随时会变 | 旧地址变黑洞 → 3 次连接失败降级回 CDN；**下次启动重解析 DNS** 拿新地址 → 再探 → 可达则升级。自愈 |
| 证书未必匹配 | `classifyDioFailure` 把 `badCertificate` 归为 `connectivity`（`endpoint_health_interceptor.dart:63`）→ 计入降级。但**探测是纯 TCP**（`Socket.connect`，`endpoints.dart:96`）不校验证书，故证书问题只影响升级后的前几个请求 |
| 其他网络连不上 | 探测失败 → `kept` → **保持编译期地址**，与不配置**完全相同** |
| 中途切网 | 降级是**快路径**：不探测、不等冷却，连续 3 次即退回 |

**失败模式枚举**（没有任何一行比不配置更差）：

| 场景 | 结果 |
|---|---|
| 无 IPv6（多数用户） | 探测失败 → 保持 CDN |
| 有 IPv6、tbcc6 可达、证书对 | **升级到直连源站**（收益） |
| 有 IPv6、tbcc6 不可达 | 探测失败 → 保持 CDN |
| 升级后断网/换网/证书失效 | 3 次失败 → 降级 CDN，冷却后重探 |

**第二个错误**：曾说「`app.example.com` 本身已是双栈，不需要 preferred hosts」。
**双栈 ≠ 直连源站**——`app.example.com` 的 AAAA 是 EdgeOne **边缘节点**
（`240d:c010::/32`），流量仍过 CDN；`tbcc6` 是**绕过 CDN 直连源站**，两者目的
完全不同，IPv6 只是顺带的。把两件事混为一谈，就得出了「不需要配」的错误结论。

**实际配置**：

```
SPB_PREFERRED_HOSTS = app.example.com=app2.example.com
```

一条规则即可：`api` 与 `ufs` 的 host 都是 `app.example.com`，`resolveEndpoints`
在循环里对两者各调一次 `_rewriteHost`。**issuer 不受影响**（`SpbEndpoints`
无 issuer 字段），且桌面端 loopback 回调打 `127.0.0.1`，与 tbcc6 完全正交。

> ⚠️ **本机与 bcc 都无 IPv6 出口**，无法直接验证 tbcc6 可达性（check-host.net
> 的节点也只解析 A 记录，连 `ipv6.google.com` 都报 `Unknown host`）。证书由部署
> 方确认覆盖该域名。若将来 tbcc6 下线，**改/删这个 Variable 即可**，无需发版。

#### 五、GitHub Variables（公开仓库，值全部会进二进制）

| Variable | 值 |
|---|---|
| `SPB_API_BASE_URL` | `https://app.example.com/pba` |
| `SPB_UFS_BASE_URL` | `https://app.example.com/ufs` |
| `SPB_OIDC_ISSUER` | `https://app.example.com/idp` |
| `SPB_OIDC_CLIENT_ID` | public client 的 `clientId`（**公开值**，会出现在授权 URL） |
| `SPB_PREFERRED_HOSTS` | `app.example.com=app2.example.com`（见上节四） |

`--dart-define` 的值**必然编译进二进制**（在 `lib/libapp.so` 的 Dart AOT 常量区，
`strings` 可提取），故配进公开 Variables 不构成新泄露。验证方式：下载产物后
`strings -a lib/libapp.so | grep tbcc`——同时应确认旧默认值 `127.0.0.1:8000` 已消失。

`release.yml` 四个平台均接入了全部 5 个 define（windows `:174`、linux `:274`、
android `:388`、macos `:475`），config job 会逐项打印 `set` / `unset`。

⚠️ **`ci.yml` 同样必须传**（2026-10 修）：它的 `build-*` job 曾一个 define 都
没传，而产物被上传成 Actions artifact 供人下载——于是拿到的是「连 127.0.0.1」
的包，运行时报「远程计算机拒绝网络连接」。详见 §6.33。
`tools/check_build_defines.sh` 守这件事。

⚠️ **`gh` 的 fine-grained PAT 需要 `Actions: Read and write`** 才能读写 Variables：
只有 read 时 `POST /actions/variables` 报 403 `Resource not accessible by personal
access token`（`PUT` 对不存在的变量报 404，容易误判成路径错）。

---

### 6.32 品牌图标：真源在 super_partyb，41 个文件由脚本生成

客户端此前用的是 **Flutter 模板的默认图标**（macOS/iOS/Android 都是那个蓝白
「F」字）。它与产品无关——装到桌面上，用户看到的不是「Super PartyB」。

品牌真源在姊妹仓库：`super_partyb/apps/webapp/src/app/icon.svg`（成蹊 logo，
1024×1024，底色 `#1a5cd7`，浅色气泡 + 镂空对勾）。本仓库不复制 SVG，而是
**由 `tools/gen_brand_assets.py` 从它渲染出全部平台图标**。

#### 为什么是脚本而不是手工导出

不是「慢」，而是**漂移**：改一次品牌色要重新导出 36 个文件，漏掉的那几个
只在真机上看图标时才会发现——而本仓库恰好验证不了 macOS / iOS / Windows
（§9）。写成脚本后，改品牌 = 重跑一次。

```bash
# 1) 渲染真源 SVG（PIL 不支持 SVG，需 rsvg-convert；本机可免 sudo 装）
cd /tmp && mkdir -p rsvg && cd rsvg
apt-get download librsvg2-bin && dpkg-deb -x librsvg2-bin_*.deb root
cd /path/to/super_partyb
/tmp/rsvg/root/usr/bin/rsvg-convert -w 1024 -h 1024 \
  apps/webapp/src/app/icon.svg -o /tmp/logo-master.png

# 2) 生成全部图标（先 --dry-run 看清单）
cd /path/to/super_partyb-flutter
python3 tools/gen_brand_assets.py --master /tmp/logo-master.png \
  --svg ../super_partyb/apps/webapp/src/app/icon.svg --dry-run
python3 tools/gen_brand_assets.py --master /tmp/logo-master.png \
  --svg ../super_partyb/apps/webapp/src/app/icon.svg
```

#### 各端的形状约定（**不是随便填满**）

| 平台 | 形态 | 为什么 |
|---|---|---|
| iOS | 满幅正方形、**无 alpha** | App Store 拒绝带透明通道的 1024 图标；系统自己加圆角遮罩 |
| Android legacy | 满幅正方形 | 系统按 density 选图，不做裁切 |
| Android adaptive | 背景色 + **透明底**前景区 | API 26+ 由启动器按厂商形状裁切（见下） |
| macOS | **圆角方形 + 留白** | Big Sur 栅格：1024 画布内 824×824 圆角矩形（圆角 185），四周各留 100 |
| Windows `.ico` | 满幅多尺寸内嵌 | 资源管理器按尺寸挑帧 |
| 桌面运行时 | 托盘 64 / 窗口 256 | GTK 自己缩放；窗口图标会被 Alt+Tab 放大，用 64 会糊 |

#### Android 自适应图标的两个硬约束（实测踩过）

1. **启动器只显示画布中央 72dp**（108dp 的 66%），其余会被裁掉或压到相邻图标下；
2. **圆形 / squircle 遮罩会再切掉四角**。

品牌 logo 里气泡占源图 49%。第一版直接铺满 108dp 画布，气泡就等于可见区的
**74%**——圆形遮罩下贴着边（预览图确认过）。现在先提取气泡、按「气泡 = 画布的
40%」重新居中（`ADAPTIVE_LOGO_RATIO`），可见区内气泡占 60%，四周约 20% 呼吸空间。

前景区必须**透明底**：logo 里的对勾是背景色**透出来**的（浅色气泡上挖空），
不是画上去的蓝。故按亮度反解 alpha 再反预乘还原颜色（`_extract_bubble`），
边缘自然过渡；直接阈值化抠图会留一圈蓝边。背景色由
`values/colors.xml` 的 `ic_launcher_background` 提供。

#### 颜色一致性：同一品牌蓝在**三处**出现

| 位置 | 用途 |
|---|---|
| `packages/spb_ui/lib/src/spb_logo.dart` 的 `SpbLogo.brandBlue` | 应用内标志 / 降级占位 |
| `apps/spb_mobile/android/app/src/main/res/values/colors.xml` | 自适应图标背景层 |
| `apps/spb_mobile/ios/Runner/Base.lproj/LaunchScreen.storyboard` | 启动画面底色 |

不一致时对勾会变成另一种蓝（前景洞透出背景），启动画面会与首屏「闪一下」。
生成脚本从 SVG 的 `rect fill` 读品牌色，不写死。

#### 应用内标志：`SpbLogo` 随 `spb_ui` 分发

登录页首屏此前是 `Icons.shield_outlined` 占位（盾牌与产品无关）。现在是
`SpbLogo`——资源在 **`packages/spb_ui/assets/brand/logo.png`**，由本包分发。

⚠️ **不要改成各端 `assets/` 各存一份**：两份必然漂移，而标志是「一眼看出
是哪个产品」的东西，两份颜色略有差异比没有还糟（同 §6.13 的
`golden_fonts.dart` 教训）。包内资源的路径必须带 `packages/<pkg>/` 前缀。

`SpbLogo` 自带 `errorBuilder` 降级（同色系方块 + 对勾）：单元测试宿主与将来
某个未打包资源的端会让 `Image.asset` 异步失败——在登录页上表现为**一片红色
错误块**，而那正是「用户进不来」的首屏。品牌是装饰，登录能力才是功能。

#### 桌面端：窗口图标要**显式**设置

Linux 上窗口图标**不会**从包内资源自动取：GTK 靠 `_NET_WM_ICON`，而 Flutter
的 Linux 嵌入层不设它（模板 `my_application.cc` 里没有 `gtk_window_set_icon`）。
结果是任务栏 / Alt+Tab 显示默认占位方块——而托盘图标是正确的，两者不一致。
故 `bootstrap.dart` 的 `_initWindowIcon` 调 `windowManager.setIcon`
（其 Linux 实现就是 `gtk_window_set_icon_from_file`）。macOS 跳过：dock 图标
来自 `.app` 里的 `AppIcon.appiconset`。

#### 启动画面

Android（`drawable*/launch_background.xml`）与 iOS（`LaunchImage.imageset` +
`LaunchScreen.storyboard`）都是「品牌蓝底 + 居中标志」。

⚠️ **不要换成 `flutter_native_splash` 之类的生成器**：那会重写
`LaunchScreen.storyboard`，而该文件同时承载 OIDC 回调的窗口配置（见
`docs/mobile-oidc-deeplink.md`）。

⚠️ **Android XML 注释里不能出现 `--`**（XML 规范禁止）：写「A -- B」这种
中文破折号转写会让 `mergeReleaseResources` 报
`The string "--" is not permitted within comments`。实测踩过一次。

---

### 6.33 CI 产物也用 127.0.0.1：构建参数没传（2026-10 真实缺陷）

**症状**：下载 CI 构建的 Windows 包，双击运行后弹「远程计算机拒绝网络连接」
（`ECONNREFUSED`）。包能启动、界面正常、**所有请求都失败**。

**根因不是参数写错，而是根本没传**。`ci.yml` 的三个 `build-*` job 都只写了
`flutter build <platform> --release`，整文件 `dart-define` **零命中**。于是产物
用的是 `SpbEnv` 的编译期默认值：

| 常量 | 默认值 |
|---|---|
| `apiBaseUrl` | `http://127.0.0.1:8000` |
| `ufsBaseUrl` | `http://127.0.0.1:9000/ufs` |
| `oidcIssuer` | `http://127.0.0.1:3000/idp` |

客户端去连**用户自己机器的 8000 端口**——那里什么都没有。

#### 为什么所有门禁都是绿的

这是本仓库反复出现的那一类「绿不代表对」（同 §6.21 的 codegen 漂移、§6.26 的
`analysis_options` 未生效）：

| 门禁 | 结果 | 为什么抓不到 |
|---|---|---|
| `dart analyze` | ✅ | 默认值是**合法字符串**，不是错误 |
| 3400+ 用例 | ✅ | 测试注入 Fake API，不碰真实地址 |
| `flutter build windows` | ✅ | 编译成功，参数缺失不影响编译 |
| Linux 自包含检查 | ✅ | 查的是 `ldd` 与 RUNPATH，与地址无关 |

#### 为什么 `release.yml` 是对的、`ci.yml` 是错的

`release.yml` 有独立的 `config` job 解析「dispatch 输入 > 仓库 Variables >
内置默认值」，四个平台各 5 条 define 全部传了。`ci.yml` 只打算「验证能不能编译」，
却把产物**上传成 Actions artifact 供人下载**（`retention-days: 7`）。

两者的**意图**不同（验证 vs 交付），**产物却是同一种**。用户不会区分——
他看到一个能下载的 zip，就会去运行它。故现在 ci.yml 也复用同一套参数解析。

#### 守卫：`tools/check_build_defines.sh`（两道，缺一漏一类）

| 道 | 做法 | 能抓什么 |
|---|---|---|
| **静态** | 每个执行 `flutter build <p> --release` 的 job 必须在该 job 内出现 `--dart-define=SPB_API_BASE_URL` | 「没传」 |
| **动态** | AOT 快照里不得残留 `127.0.0.1:8000` | 「传了但没生效」 |

动态那条是**直接证据**，且实测可靠：传了 `--dart-define` 后，未被使用的默认值
字符串会被 **tree-shake 掉**。同一份代码实测：

```
flutter build linux --release
  → strings -a lib/libapp.so | grep -c 127.0.0.1:8000  →  1

flutter build linux --release --dart-define=SPB_API_BASE_URL=https://example.test/pba
  → 同上 → 0；grep -c example.test/pba → 1
```

故「产物含 127.0.0.1:8000」**等价于**「这个包连的是本机」。

快照位置各端不同：Linux `bundle/lib/libapp.so`、Windows `Release/data/app.so`、
Android `lib/<abi>/libapp.so`（在 APK 里，需先 `unzip`）。

#### ⚠️ 按 **job** 切块检查，不能整文件 grep

这是最容易写错的一处，也是自测用例 3 专门钉住的：`release.yml` 的 define 在
`config` job 里**解析**、在 `build` job 里**使用**——两者是分开的 job。若守卫对
整个文件 grep，就会因为「config 里出现过这个字符串」而放行一个没传的构建 job。
按 job 切块后才拦得住。

#### 只要求 api 那一个 define

不要求 UFS / OIDC 齐全：`apiBaseUrl` 是「连不上就什么都做不了」的根，其余缺失是
**功能降级**（OIDC 缺失 → 登录不可用，其余正常）。要求全部齐全会让守卫在「故意
只配 api」的场景误报，而误报的守卫很快会被加进忽略列表。

#### 自测（`check_build_defines_selftest.sh`，16 条断言）

在 `mktemp -d` 里造最小仓库、把真守卫**逐字节复制**过去执行（不是副本实现）。
钉住四处相反方向的判定：漏报（没传必须报错）/ 误报（传了必须放行）/
按 job 切块（别的 job 传了不算）/ 防空转（一个构建 job 都没有时必须报错）。

反向验证逐条实测：撤掉 `build-windows` 的 define → 报错；把守卫改回整文件 grep
→ 用例 3 失败；去掉二进制检查 → 用例 6 失败。

#### ⚠️ 本地 `.so` 的陷阱（写这类守卫时）

`cleanup` 里别写 `for d in "${arr[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done`
——空数组时 `${arr[@]:-}` 展开成空串，`[ -n "" ]` 失败让**函数返回 1**，
EXIT trap 会把整个脚本的退出码改成 1。实测现象：16 条断言全绿、最后一行打印
「自测通过」，退出码却是 1。写成 `for d in ${arr[@]+"${arr[@]}"}` 并显式
`return 0`。

#### 若将来新增出包平台

必须同时做两件事，否则复发：

1. 在该 job 内传 `--dart-define=SPB_API_BASE_URL`（`check_build_defines.sh`
   会拦）；
2. 把该平台的 AOT 快照路径加进守卫的 `SNAPSHOTS` 数组（否则二进制断言
   对它静默跳过）。

---

### 6.34 会话失效 → 回登录页（`AuthInterceptor.onSessionExpired`）

**症状**：会话真的过期后，客户端弹一句「会话已失效，请重新登录」，然后**卡在
当前页面**——不会回登录页，用户只能手动进设置页点「退出登录」。

#### 根因：链路上每一段都在，唯独中间那段是断的

| 环节 | 修复前 |
|---|---|
| `AuthInterceptor.onError` | 401 → 尝试刷新 → 失败则归一化成 `AuthError` 抛给调用方。注释写着「**由上层统一监听 AuthError 并跳转登录页**」 |
| 那个「上层监听」 | **不存在**。全仓 `markUnauthenticated` 只有 3 个调用点：移动端深链登录失败 1 处 + 两端各 1 处定义。生产路径**零调用** |
| 各页面 catch 到 `AuthError` | 只翻成一句 SnackBar 文案（`_describeGroupActionError` / `_describeGoalError` / `_describeSwitchError`…），不做导航 |
| SSE 401 | `SseClient` 置 `SseState.failed` 并推 `frames` 的 error → `ChatStreamController.errors`，而**没有任何装配层订阅它** |
| 路由守卫 | 逻辑本身是对的（`buildAuthRedirect` + `AuthRefreshNotifier`），只要 `authState` 变成 `unauthenticated` 就会重定向到 `/login?from=…` |

即：**下游（守卫）一直是好的，上游（把状态推进到未登录）根本没人做**。

#### 修法：拦截器给一个回调，装配层接到 `markUnauthenticated`

```
401 → AuthInterceptor.onSessionExpired(message)
  → authStateProvider.notifier.markUnauthenticated(message)
  → AuthRefreshNotifier.notifyListeners()（只在 status 变化时）
  → go_router 重跑 buildAuthRedirect
  → '/login?from=<当前页>'
```

`markUnauthenticated` 的既有语义正好合适：**不清凭证**（401 可能是网关侧临时
问题，清掉会让用户丢 refresh_token），只把状态置为 `unauthenticated`。

#### 五个不得违反的约束（改之前必读）

| 约束 | 为什么 |
|---|---|
| **403 绝不触发** | 403 是「已认证但无权限」。把它当登出，用户「点了一个没权限的按钮」就会被直接踢出登录 |
| **只在「刷新也失败」之后触发** | `SessionManager._doRefresh` 明确保留「临时网络故障不该让用户登出」这一取向。唯一可信的信号是「刷新过了，服务端仍然 401」 |
| **重放路径也要触发，但要带 `_retriedKey` 守卫** | 「刷新成功但重放仍 401」（账号被禁/会话被撤销）同样是确定失效。但重放请求**也经过本拦截器**，不带守卫会通知两次（实测：回调被调 2 次） |
| **回调里不导航** | 同一时刻可能有多个请求同时 401，导航副作用会打架。重定向只由路由守卫做一次 |
| **装配层用 `ref.read` 而非 `watch`** | `dioProvider` 若 watch 认证状态，每次登录/登出都会重建 Dio——而 Dio 与 SseClient 的身份被 `ChatStreamController` 与页面的 `??=` 订阅持有，重建会让时间线**静默冻结**（同 §5.1.1 的 `EndpointRewriteInterceptor` 那条） |

#### 接线点：**4 处**，不是 2 处

两端各有 `dioProvider` 与 `ufsDioProvider`，**四个都要接**：UFS 请求走的是同一个
网关会话，也会 401。只接 API 那个会让「文件预览失败」不把人带回登录页。

两端各自抽了一个私有 helper `_sessionExpiredHandler(ref)`，四个构造点共用。

#### 测试（拦截器 5 条 + 两端各 2 条）

| 层 | 用例 | 钉住 |
|---|---|---|
| `spb_api` | 401 且刷新失败 → 回调调用一次 | 该触发时触发 |
| 同上 | 刷新成功且重放成功 → **不触发** | 静默续期不该踢人 |
| 同上 | **403 → 绝不触发** | 反方向（误触发会踢掉正常无权限操作） |
| 同上 | 刷新成功但重放仍 401 → 触发一次 | 通知不随重放叠加 |
| 同上 | 未配置回调时行为不变 | 向后兼容 |
| 两端 router | 已登录时状态被推进 → 停在 `/login?from=<原页>`、登录页显示原因、`clearCount == 0` | 整条链路 + 不清凭证 |
| 两端 router | `dioProvider` 真实构造的拦截器接上了回调 | **接线漏接** |

⚠️ **第二条 router 用例为什么不能用 harness 的 dio**：`pumpApp` 把 `dioProvider`
**整体覆盖**成「挂了 `DioAdapter` 的 dio」，那个 dio 没有 `AuthInterceptor`。
在那里发 401 只能得到裸 `DioException`（实测：断言路由仍停在 `/settings`）。
故它另建一个只覆盖 `tokenStoreProvider` 的容器，让 `dioProvider` 走真实实现，
再把适配器换成「一律 401」。

#### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| `dioProvider` 去掉 `onSessionExpired` 接线 | 接线用例失败（`isUnauthenticated` 为 false） |
| `onError` 里去掉回调调用 | 拦截器 1 条失败 |
| 去掉 `_retriedKey` 守卫 | 「重放仍 401」用例失败（回调被调 2 次） |

#### 有意不做

- **不在拦截器里 `context.go('/login')`**：拦截器是传输层，不应持有导航知识；
  且多请求并发 401 会重复导航。
- **不订阅 `ChatStreamController.errors` 做 SSE 兜底**：SSE 的 401 在绝大多数
  场景下会伴随一次普通 HTTP 401（时间线回填 / `/api/auth/me`），主路径已覆盖。
  单独做需要额外一条用例钉住「只有 SSE 在跑」的时序，收益不足以在本轮引入。

---

### 6.35 Windows 打不开浏览器：`explorer` 既吃不下带 query 的 URL，成功也返回 1

这一节记**两个**Windows 缺陷，症状都是「点登录没反应」。第二个是第一个修完
之后才暴露的——修第一个并不能让 SSO 登录真正可用。

| # | 缺陷 | 用户看到什么 | 何时发现 |
|---|---|---|---|
| ① | `explorer <带 query 的 URL>` 打开的是**文件浏览器** | 一个莫名的文件管理器窗口 + 登录页干等 | 用户报「SSO 打开的是文件浏览器」 |
| ② | `explorer` 成功也返回 **1**，被判成失败 | 弹「无法打开浏览器，请手动访问…」（浏览器其实已开） | 修 ① 之前一直掩盖着 |

#### 缺陷 ①：URL 与路径必须用不同命令

`spawnSystemOpen` 原先对 Windows **一律** spawn `explorer`：

```dart
case HostPlatform.windows:
  exe = 'explorer';   // ❌ 对带 query 的 URL 会打开文件浏览器
```

而 `explorer.exe` 只在 URL **不带 query string** 时才委托给默认浏览器。一旦带
`?a=1&b=2`，它把参数当路径去浏览（上游一致：microsoft/WSL#3832 *"Actual
result: Generic file explorer window opens"*、dotnet/runtime#108817
*"Process.Start opens explorer itself instead of URL"*）。

**为什么必然命中**：OIDC 授权 URL 有 8 个 query 参数（`response_type` /
`client_id` / `redirect_uri` / `scope` / `state` / `nonce` / `code_challenge` /
`code_challenge_method`，见 `OidcPkce.buildAuthorizeUrl`），**不可能**不带 query。
故这不是「偶发」，而是每次登录都发生。

**为什么比报错更糟**：`explorer` 对文件浏览器窗口同样返回「成功」，于是
`openInBrowser` 不抛 `PlatformError`，`loopbackSignIn` 继续 `server.wait()` 等
回调——用户看到的是「点了没反应」+ 一个空窗口，5 分钟后才超时。

修法：按**目标形态**分派，而不是只按平台分派。

```dart
case HostPlatform.windows when looksLikeUrl(target):
  exe = 'rundll32';
  args = ['url.dll,FileProtocolHandler', target];
  exitCodeIsMeaningful = false;   // 见缺陷 ② 末尾
case HostPlatform.windows:
  exe = 'explorer';
  args = [target];
```

`rundll32 url.dll,FileProtocolHandler <url>` 是 Windows 上按 URL 协议分派给
默认处理程序的正确入口，query string 原样保留。

⚠️ **URL 判定不能用 `Uri.parse(target).scheme`**：实测
`Uri.parse(r'C:\Users\me\file.md')` 得到 `scheme=c`、`path=/Users/me/file.md`，
据此判定会让**每一个** Windows 文件路径都走进 URL 分支（交给 `rundll32`）——
比原缺陷更难查。故 `looksLikeUrl` 只认 `scheme://` 形态（正则，不用 `Uri`）：
`file://` / `https://` / `partyb://` 命中；`C:\` 与 `C:/` 都不命中；
`mailto:`（单冒号）也不命中。有用例逐条钉住这三类。

#### 缺陷 ②：把「非 0 退出码」当成「没打开」

原先的判定是：

```dart
if (result.exitCode != 0) return false;   // ❌ 在 Windows 上等于「永远失败」
```

`explorer.exe` 不是「打开某个东西」的工具，它是 **shell 本身**：收到参数时把
请求转交给已运行的 explorer 实例，然后**自己立即退出**，退出码与「目标是否真的
被打开」无关。实测与上游一致：`explorer.exe <路径>` 打开了目标，退出码却是
**1**（microsoft/WSL#6565，维护者确认「退出码 1 是 Windows 应用的常态，控制台
程序成功才返回 0」）。

失败链路（每一段都在，只是判据错了）：

```
openInBrowser → spawnSystemOpenHere → spawnSystemOpen(explorer) → exitCode==1
  → return false → openInBrowser 抛 PlatformError
  → loopbackSignIn 返回 failure('无法打开浏览器，请手动访问：…')
  → 登录页显示该文案，且**放弃等待 loopback 回调**（监听器在 finally 里关掉）
```

修法：成功退出码按平台区分。

```dart
Set<int> _successExitCodes(HostPlatform platform) => switch (platform) {
  HostPlatform.windows => const {0, 1},
  HostPlatform.linux || HostPlatform.macos || HostPlatform.other => const {0},
};
```

⚠️ **不要把这条放宽到全平台**。`xdg-open` / `open` 有正常的退出码语义，把 1 也
算成功会掩盖「没有默认浏览器」等真实故障。有两条用例专门钉住这个反方向
（`linux 的退出码 1 → false` / `macos 的退出码 1 → false`）。

⚠️ **也不要放宽成「Windows 一律成功」**：`{0,1}` 之外的退出码仍是失败信号
（有用例 `windows 退出码 2 → false`）。

#### ⚠️ `rundll32` 分支**不看**退出码（缺陷 ① 的代价）

`rundll32` 的退出码**恒为 0**（上游确认：*"rundll32 does not give you any
return value, its exit code is always zero"*），即「URL 没打开」与「打开了」在
退出码上完全同形。故该分支用 `exitCodeIsMeaningful = false` **显式跳过**判定，
而不是假装 0 能说明什么（后者会把「无法判定」伪装成「已判定」）。

代价（诚实记录）：Windows 上 URL 打不开时**没有即时错误**，而是由上层超时兜底
（`auth_loopback.dart` 的 5 分钟 + 登录页的「手动访问 URL / 粘贴导入」降级路径）。
仍优于替代方案：误报失败会导致**每次登录都失败**。

⚠️ 「不看退出码」**不等于**「吞掉 spawn 失败」：可执行文件不存在仍返回 `false`
（有用例 `windows URL 的 spawn 异常仍降级为 false`），否则登录页会静静地等到
5 分钟超时。

#### 接受 `explorer` 返回 1 的代价（诚实记录）

`explorer` 返回 1 时我们**无法区分**「已交给默认程序」与「目标不存在」。可接受，
因为「打开文件 / 打开目录」两条调用链在 spawn **之前**已经探测过路径存在
（`openFile` 用 `File(path).exists()`，定位走 `revealSystemEntry` 的 `probe`），
可靠性不依赖退出码。

⚠️ **这一段曾经是错的**：当时的 `revealPath` 用 `Directory(path).exists()` 探测，
而调用方传的是**文件**——探测本身就不成立（但**仍然**返回 false，所以「不依赖
退出码」这个结论巧合地成立）。详见 §6.41。

#### 为什么测试没抓到（**两个假绿**）

| 假绿 | 成因 |
|---|---|
| 「`explorer` 成功也返回 1」从未被断言 | 假 runner 在所有「成功」用例里返回 `exitCode = 0` |
| 「URL 会被交给 `explorer`」从未被断言 | 断言只看**可执行文件名**，不区分目标形态——`windows 用 explorer` 那条用例传的是 `C:\Users\me\file.md`（路径），于是「URL 也走 explorer」这条错误行为恰好被它「验证」为正确 |

Windows 分支只能靠注入测试（本机是 Linux，`HostPlatform.current()` 的断言也写死
linux），所以这两个错误前提一直被固化着——与 §6.21 / §6.26 / §6.33 同一类
「绿不代表对」。

现补的用例：`Windows 的退出码语义` 组 5 条（路径 1 → 成功 / 0 → 成功 / 2 → 失败
/ URL 退出码 2 仍算已发起 / URL 的 spawn 异常仍 false）+ `looksLikeUrl` 组 3 条
（URL → true / 盘符路径 → false / Unix 与相对路径 → false）。

#### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| 去掉 `windows when looksLikeUrl` 分支（退回「一律 explorer」） | 2 条失败 |
| `rundll32` 分支也看退出码（去掉 `exitCodeIsMeaningful`） | 1 条失败 |
| `looksLikeUrl` 改成 `Uri.parse(target).scheme` 非空 | 5 条失败 |
| `windows => const {0, 1}` 改回 `const {0}` | 1 条失败 |
| 把 `_successExitCodes` 改成全平台 `const {0, 1}` | 2 条失败 |

#### 有意不做

- **不改用 `cmd /c start`**：多一层 shell 就多一层注入面（`Process.run` 不经过
  shell，参数按数组传递），且 `start` 的引号规则（第一个参数是窗口标题）更容易
  踩坑。`start` 还会把 URL 里的 `&` 当成命令分隔符。
- **不改用 `ShellExecuteW`**：需要平台通道（Dart 侧拿不到），与「桌面能力不引
  插件」的取向不符；`rundll32`（URL）+ `explorer`（路径）已覆盖全部调用场景。
- **不改用 `Process.start(detached)`**：只判「能否 spawn」会丢失「命令确实失败」
  的信号，比误报失败更糟（用户会看到「什么都没发生」）。
- **不在 URL 分支做「打开了吗」的二次校验**：Windows 没有廉价可靠的探测手段
  （查默认浏览器进程、读注册表都不可靠且要额外依赖），收益不抵成本。

---

### 6.36 登录成功后停在登录页：`signIn()` 把已登录盖回 `unknown`

**症状**：点「使用 SSO 登录」，浏览器里确实登录成功、`loopbackSignIn` 也拿到了
token（安全存储里**有凭证**），但客户端仍停在 `/login`，界面显示「已发起，等待
浏览器回调」。**重启应用就正常了**——因为 `restore()` 从存储里读到了 token。

#### 根因：旧实现的收尾分支在新实现里变成数据破坏

`AuthStateNotifier.signIn()` 收尾时**无条件**写：

```dart
state = const AuthState(status: AuthStatus.unknown, message: null);
```

这条是给**旧实现**（`openGatewaySignIn`，只发起、等浏览器 Cookie 回调）留的
——那时本进程确实不知道结果。而 `2d453cf` 把桌面端换成 RFC 8252 loopback 后，
`signInAction` 变成了**同步等到 token**：

```
loopbackSignIn → 收 code → 换 token → tokenStore.write() → signedIn()
                → 状态已是 authenticated
                → signIn() 返回 null
                → signIn() 收尾写 state = unknown   ← 把 authenticated 盖掉
```

守卫 `buildAuthRedirect` 对 `unknown` 是**明确放行**的（§6.34 里那条：读凭证是
异步的，启动瞬间不能重定向）。于是状态停在 `unknown` → 守卫不重定向 → 用户
永远停在 `/login`。

**为什么重启就好**：`restore()` 走的是另一条路径（读存储 → `authenticated`），
不经过 `signIn()` 的收尾分支。这也解释了「凭证明明在，界面就是不进去」。

#### 修法：判据不是「谁先谁后」，而是「别把已登录改回未判定」

```dart
if (!state.isAuthenticated) {
  state = const AuthState(status: AuthStatus.unknown, message: null);
} else if (state.message != null) {
  state = state.copyWith(clearMessage: true);   // 只清旧错误，不动 status
}
```

`unknown` 的语义是「**还不知道**」，已经知道的事不该被它覆盖。

⚠️ **移动端一并修**，虽然它的真实流程是「只发起 → 等深链回调」（返回时确实该是
`unknown`）：回调接收器（`authDeepLinkReceiverProvider` 的 `onCode`）可能在
`signIn()` 返回**之前**就完成并调了 `signedIn()`。那时同样会被盖掉。两端共用
一条判据比「各按各的时序假设」更安全。

#### 为什么测试没抓到（**两个假绿**）

| 既有用例 | 它断言了什么 | 漏了什么 |
|---|---|---|
| `登录页点击 SSO 按钮调用注入的 signInAction` | 动作被调用 **1 次** | 完全没看状态 |
| `登录成功后守卫放行首页` | 绕过 `signIn()` 直接调 `signedIn()` | 跳过了唯一有缺陷的那段代码 |

两条都绿而缺陷在。这与 §6.21 / §6.26 / §6.33 同一类：**绿不代表对**。

现补的用例（两端各 1 条）从**按钮**出发、走完整链路，断言「状态是
`authenticated`」+「路由已离开 `/login`」+「登录按钮消失」。修复前红（
`isAuthenticated` 为 false），修复后绿。

#### 反向验证（实测）

把 `if (!state.isAuthenticated)` 改回无条件赋值 → 两端各 1 条失败。

### 6.37 登录成功后立刻「会话已失效」：把不透明 `access_token` 当 Bearer

**症状**：SSO 登录在浏览器里成功、`idp-go` 的 `/oauth2/token` 返回 200，但客户端
一进首页就弹「会话已失效，请重新登录」，并被踢回 `/login`。

#### 根因：IdP 的 `access_token` 是 fosite 不透明串，网关只认 RS256 JWT

两边的契约从来没对齐过：

| 侧 | 事实 |
|---|---|
| IdP（`id-provider/go/internal/oidc/provider.go:81`） | `compose.ComposeAllEnabled` → `NewOAuth2HMACStrategy`：`access_token` 是 **`ory_at_…` 不透明串**（无点号）；只有 `id_token` 由 `NewOpenIDConnectStrategy` 签成 **RS256 JWT** |
| 网关（`api-gateway/pkg/auth/`） | `jwt_authenticate.go`（JWKS + RS256）与 `oidc_auth.go`（go-oidc `verifier.Verify`）**都要求 compact JWS（三段）**；`manager.go` 只装配 JWT / OIDC / APIKey / mTLS，**没有 opaque token 的 introspect 通路** |
| 客户端（修复前） | 四处 `StoredTokens(accessToken: tokens.accessToken)`——把不透明串当 Bearer 发出去 |

于是网关日志是这两句（2026-10-20 19:55，bcc 的 `journalctl -u api-gateway`）：

```
"OIDC ID Token验证失败" error:"oidc: malformed jwt: go-jose/go-jose: compact JWS format must have three parts"
"JWT validation failed"  error:"token is malformed: token contains an invalid number of segments"
```

客户端 `AuthInterceptor` 收到 401 → 刷新也失败 → `onSessionExpired` → 路由守卫
把用户送回登录页（§6.34 那条链路，本身是对的）。

**与 `app2.example.com` 无关**：登录走编译期 issuer（`SpbEndpoints` 没有 issuer
字段，端点升级只改 API/UFS 的 host），出问题的是登录**之后**的每个请求。

#### 修法：取值规则收敛到一处，不再让四个调用点各写一遍

```dart
// packages/spb_api/lib/src/oidc_client.dart
String get bearerToken => idToken ?? accessToken;

// packages/spb_api/lib/src/token_store.dart
factory StoredTokens.fromOidcTokens(OidcTokens tokens, {DateTime Function()? now})
```

四端（桌面 `signInAction` / `refresh`，移动 `onCode` / `refresh`）全部改用它。
**回退到 `accessToken` 只为兼容「服务端没下发 id_token」的响应**（未请求
`openid` scope），那种响应下请求仍会 401，但至少不会构造出空凭证。

刷新路径同样要取 `id_token`：fosite 的 `OpenIDConnectRefreshHandler`
（`handler/openid/flow_refresh_token.go:99`）在 scope 含 `openid` 时会
**一并重发新的 id_token**。

⚠️ `StoredTokens.accessToken` **字段名是历史包袱**，语义已是「Bearer 凭证」。
改名会牵动存储格式与全部测试，故保留字段名并在文档注释里说明。

#### 为什么是客户端改，而不是网关加 introspect

网关加 RFC 7662 introspect 会让**每个请求**多一次远程调用（且要处理缓存、
失效、IdP 不可用时的降级），而 `id_token` 本来就在客户端手里、网关也早已
支持验它。改客户端是一行取值规则。跨仓库的方案已另开 issue 跟踪（见下）。

#### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| `bearerToken` 改成 `=> accessToken` | `spb_api` 2 条失败（`oidc_client_test` + `session_manager_test`） |
| `fromOidcTokens` 改回 `tokens.accessToken` | 桌面端 1 条 + 移动端 1 条 + `spb_api` 1 条失败 |

#### ⚠️ 修复前测试是绿的（**两处假绿**）

| 既有用例 | 它断言了什么 | 漏了什么 |
|---|---|---|
| `auth_loopback_test.dart` 的 `exchangeCode` 用例 | `r.tokens!.accessToken == 'at-test'` | 断言的是 **`OidcTokens` 的原始字段**，与「落盘成什么」无关 |
| 桌面 `登录页点击 SSO 按钮调用注入的 signInAction` | 动作被调用 **1 次** | 完全不看落盘内容 |
| 移动端 `onCode` | **零覆盖**——它内联在 `authDeepLinkReceiverProvider` 的闭包里，只能从 `main.dart`（不在测试树中）走全链路触达 | 整个落盘逻辑 |

这是 §6.21 / §6.26 / §6.33 / §6.36 同一类：**绿不代表对**。

现补的用例都从**真实入口**出发、断言**落盘结果**：

| 层 | 用例 | 怎么做到可测 |
|---|---|---|
| `spb_api` | `bearerToken` 优先 `id_token` / 无 `id_token` 时回退 | 纯模型 |
| `spb_api` | `fromOidcTokens` 落盘的是 `id_token`、`expires_in` 换算成绝对时刻 | 纯模型 |
| 桌面 | `loopback 登录落盘的 Bearer 是 id_token 而不是 ory_at_ 不透明串` | 新增 `loopbackSignInProvider` 注入点，喂真实形态 token，走**真实** `signInActionProvider` 的落盘代码 |
| 移动 | `深链回调落盘的 Bearer 是 id_token 而不是 ory_at_ 不透明串` | 把内联闭包抽成 `oidcCallbackHandlerProvider`（否则零覆盖） |

两个注入点都是**为可测性而抽**，不是为功能——桌面端若替换整个
`signInAction` 就等于把被测的那一行删掉（那正是既有用例抓不到本缺陷的原因），
故 `pumpApp` 里 `loopbackSignIn` 与 `signInAction` 互斥（同时传抛
`ArgumentError`，不用 `assert`——release 下会被去掉而静默测错对象）。

---

### 6.38 Windows 上「门」显示畸形：主题从未指定 CJK 字体

**症状**：Windows 上「门」被画成「一个方框 + 正中一根竖」（正确字形是「框 + 左上角
一点」）。截图证据：`/home/jim/spb.png`，标题与正文各一处。

#### 根因：Flutter **没有**「用系统默认字体」这回事

`ThemeData(fontFamily: null)` 时，Flutter 按平台从 `Typography.material2021` 取一个
**写死了字体名**的 TextTheme（`packages/flutter/lib/src/material/typography.dart`）：

| 平台 | TextTheme | 写死的 fontFamily | 带 fallback 列表？ |
|---|---|---|---|
| android / fuchsia | `blackMountainView` | `Roboto` | ❌ |
| **windows** | **`blackRedmond`** | **`Segoe UI`** | ❌ |
| macOS | `blackRedwoodCity` | `.SF NS …` | ❌ |
| iOS | `blackCupertino` | `CupertinoSystem…` | ❌ |
| linux | `blackHelsinki` | `Roboto` | ✅ 6 个 |

除 Linux 外都是**纯拉丁字体**——中文字形只能靠引擎的 **last-resort 回退**。
`SpbTheme` 此前完全没设 `fontFamily`，走的就是这条路。

#### 回退到哪了：`Segoe UI` 的 FontLink 链里**日文排在简体中文前面**

这是根因的确切机制（Windows 字体替换配置在注册表
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink`）：

```
MEIRYO.TTC,Meiryo UI            ← 日文，排在前面
MSGOTHIC.TTC,MS UI Gothic       ← 日文
MSJH.TTC,Microsoft JhengHei UI  ← 繁体
MSYH.TTC,Microsoft YaHei UI     ← 简体（被前三个抢走）
MALGUN.TTF,Malgun Gothic        ← 韩文
SIMSUN.TTC,SimSun               ← 宋体排到第 11 位
```

于是简体中文字形优先由**日文字体**提供。「门」在日文里是「門」的简化形——
**框内一根居中的竖**；简体中文标准字形是「框 + 左上的点」。这与像素测量
完全吻合（用户截图里上笔中心精确在 50%，而 WenQuanYi 等中文标准字形上笔
偏左，实测 x=38..46 vs 横条 39..105）。

**同类现象在其它软件里反复出现**（都是同一个根因：基字体不含 CJK → 回退链
先命中日文字体）：

| 软件 | 表现 |
|---|---|
| Notepad++ #17476 | 「门」被渲染成「内」 |
| Notepad++ #16742 | 8.5 后某版本「门限」的「门」显示不对 |
| Excel / Office | Arial 单元格里「门」异常（输入框正常） |
| Sublime Text | 默认字体下「门」显示异常 |
| Ubuntu fontconfig | `64-language-selector-prefer.conf` 日文优先级高于中文 → 「门」「复」显示成日文异形 |

**排查时排除的假线索**：

- 不是字符问题：全仓扫描真繁体独有字，只命中「案」（简繁同形）；没有「闩」。
- 不是本机字体能重现的：用本机 181 个字体做 IoU 匹配，最高 0.338 且全是 Latin
  字体误配——**没有任何本地字体画得出那个形态**（本机无日文 CJK 字体），
  故只能是 Windows 侧回退所致。

⚠️ **`'sans-serif'` 在 Flutter 里不是救命稻草**：`fontFamilyFallback` 只认
**具体字体名**，CSS 的通用族名（`sans-serif` / `serif` / `monospace`）**不被解析**。
链尾那一项留着只是可读性，真正兜底的是引擎「fallback 耗尽 → 用平台默认字体」
（`TextStyle.fontFamilyFallback` 官方文档）。故测试**不**断言末位是通用族名——
那会给出「这一项在起作用」的错觉。

#### 修法：**只给 Windows** 指定字体，其余平台保持 `null`

`packages/spb_design/lib/src/fonts.dart` 的 `SpbFonts.sansFor` /
`sansFallbackFor` 只在 `TargetPlatform.windows` 返回非 null
（`Microsoft YaHei UI` + `['Microsoft YaHei', 'Segoe UI', 'sans-serif']`）。

**为什么不是「所有平台都指定」**——两个理由，第二个是实测出来的：

1. 其余平台的系统级 CJK 回退本来就正确（CoreText / fontconfig / Android 按 locale
   选 Noto CJK）。显式钉 `PingFang SC` 会让**日语用户被强制套上简体字形**。
2. ⚠️ **给全部平台配 fallback 链会让 4 张 golden 基线全红**。原因**不是**渲染
   退化，而是 `flutter test` 里 `defaultTargetPlatform` 恒为 **android** 且环境
   **没有 CJK 字体**：
   - 无 fallback 链 → 中文落到 Roboto 缺字的**细线空心 tofu**（基线原样）；
   - 有 fallback 链 → 链耗尽落到 Ahem 的**粗实心方块** → 基线全废。

   两份都是 tofu，只是画法不同。故非 Windows 配 fallback 是**零收益且制造基线
   噪音**。`test/fonts_test.dart` 有一条专门钉住这件事（比 4 张 golden 报「像素
   不匹配」更容易定位根因）。

#### ⚠️ 不要在 `flutter test` 里「验证字形」

测试环境没有 CJK 字体，**中文永远是 tofu，改成什么字体名都看不出来**。能验证的
只有结构性断言（主题里带了正确的字体名）。真实字形**必须靠目标平台手测**
（本机无 Windows，见 §8/§9）。

`SpbTheme` 为此加了 `lightFor(platform)` / `darkFor(platform)`
（`@visibleForTesting`），生产仍走 `light()` / `dark()`。

#### 顺带统一 4 处 `fontFamily: 'monospace'` 的 CJK 兜底

`'monospace'` 不是真实字体名，是「问系统要等宽字体」——四个平台拿到的都是纯拉丁
（Windows = `Consolas`）。而**工具调用的入参/结果经常含中文**。三处原本**没有**
fallback（`tool_call_tile.dart` ×2、`group_gate_panel.dart` ×1），现统一改用
`SpbFonts.monoFallback`（`agent_file_preview.dart` 原有那条也一并收敛）。

#### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| `sansFor(windows)` 改回 `null` | `fonts_test.dart` 1 条失败 |
| 给全部平台加 fallback 链 | `spb_features` **4 张 golden 失败** + `fonts_test` 1 条失败 |
| 主字体名改成 `'Noto Sans CJK SC'`（仅 android） | golden 仍失败 2 张（证明**主字体名无关**，问题在 fallback 链） |
| 只删 `fontFamilyFallback`、保留主字体名 | golden 全绿（定位到根因） |

#### 未做

- **打包 CJK 字体子集**：能彻底摆脱对目标机器字体的依赖，但代价 5–10 MB + 全部
  golden 基线重出，且要处理字体许可。当前修法对 Windows 已够（雅黑是系统必备）。
- **接 `flutter_localizations` + `supportedLocales`**：那会改 `scriptCategory`
  （`englishLike` → `dense`）、基线从 `alphabetic` 变 `ideographic`，golden 需一并
  重出。与 §6.12（i18n 暂不做）一致，未纳入本轮。

---

### 6.39 放置一段时间后被登出、关闭重开又正常：一次断网被当成「凭证失效」

**症状**：应用放一段时间（笔记本合盖 / 切网）后，第一次操作弹「会话已失效，
请重新登录」并跳回登录页。而**关掉重开就一切正常**——凭证一直在安全存储里。

#### 根因：刷新失败的两种含义被合并成了一种

`SessionManager.currentAccessToken()` 曾是这样：

```dart
final refreshed = await refresh();   // 失败（无论为什么）都返回 null
return refreshed?.accessToken;       // → null
```

而 `_doRefresh()` 用 `catch (e) { return null; }` 把**所有**失败折叠成 null：断网、
超时、IdP 503、`invalid_grant` 全长得一样。于是：

```
休眠唤醒 → 刷新因连接层失败返回 null
  → 请求不带 Authorization（匿名）→ 必然 401
  → 拦截器再刷一次 → 又失败 → onUnauthorized 返回 false
  → onSessionExpired → 回登录页
```

`markUnauthenticated` **不清凭证**（§6.34 的有意设计），所以重开应用后
`restore()` 读到完好的 refresh_token、网络栈也是干净的 → 刷新成功。这正是
「重启就好」的来源，也是本缺陷的确认证据。

#### 修法：三态结论 + 「让服务端判定」

`spb_api` 的 `token_store.dart` 新增 `TokenRefreshStatus`（`refreshed` /
`rejected` / `transient`）与 `TokenRefreshOutcome`。判据是**「这个失败是否携带
了关于凭证有效性的信息」**——网络层错误从不携带。

| 结论 | 触发 | 处置 |
|---|---|---|
| `refreshed` | 拿到新凭证并已落盘 | 继续 |
| `rejected` | 无 refresh_token / `invalid_grant` / 4xx | 回登录页 |
| `transient` | `NetworkError` / `ParseError` / 5xx / 未知 | **保留登录态** |

两处协同才修好：

| 位置 | 改动 |
|---|---|
| `SessionManager.currentAccessToken` | `transient` 时返回**旧 token**（而不是 null）。发匿名请求等于替服务端提前判了「已失效」；拿旧 token 再试，让唯一有权限判定的角色回答 |
| `AuthInterceptor.onError` | 拿到 `transient` 时**不调** `onSessionExpired`，也不重放（重放必然失败），把原 401 归一化为 `AuthError` 抛给页面提示「网络异常」 |

#### ⚠️ 必须下探 `AuthError.cause`（最易写错的一处）

`OidcClient._tokenRequest` 对**任何**非 2xx 都抛
`AuthError(message, cause: HttpError(status))`——最外层永远是 `AuthError`，
`statusCode` 字段是 null（它只描述「登录失败」），真正的状态码在 `cause` 里。

只按最外层类型判的话，`AuthError → rejected` 会把「IdP 回了 503」也当成「凭证
被作废」——那是同一缺陷的另一条路径（IdP 重启期间所有用户被登出）。故
`_statusOf` 对 `AuthError` 显式下探 `cause`。

#### 三处接口取向

| 项 | 决定 | 理由 |
|---|---|---|
| 保留 `onUnauthorized`（旧布尔回调） | 保留，`onUnauthorizedOutcome` 优先 | 既有测试与第三方接线不受影响；旧回调无能力表达 transient（`false` 一律当 `rejected`），这本身就是它被替换的原因 |
| `refresh()` 仍返回 `StoredTokens?` | 保留为 `refreshWithOutcome()` 的薄包装 | 6 处既有调用点与测试依赖它；新代码一律用带三态的那个 |
| 未知错误 | `transient` | 把未知错误当「凭证失效」会随机把人登出。保守方向必须偏向「保留登录态」 |

#### 反向验证（逐条实测）

| 改坏 | 失败用例数 |
|---|---|
| `currentAccessToken` 的 transient 分支返回 null（修复前行为） | 1（`暂时性失败时返回**旧** token`） |
| 拦截器去掉 `if (outcome.isTransient)` 守卫 | 2 |
| `AuthError` 一律 `rejected`（不看 `cause`） | 1 |
| `rejected` 时不调 `onSessionExpired`（反方向） | 2 |
| `NetworkError` 分类改成 `rejected` | 2 |

#### 新增用例（`session_manager_test.dart` +21 条）

| group | 钉住 |
|---|---|
| 刷新失败的三态分类 | 9 种错误形态的归类（含 `AuthError(cause: HttpError(5xx))` 这个真实链路形态、`ParseError`、非 `SpbError`） |
| `currentAccessToken` 的取信策略 | transient 返回旧 token / rejected 返回 null / 成功返回新 token / 未过期不刷新 / 临时失败不 clear |
| 拦截器 transient 不登出 | transient → 不调回调、不重放、`calls == 1`；rejected → 调一次；新回调优先于旧回调 |

#### 有意不做

- **不在 `AuthInterceptor` 里自动重试**：transient 之后立刻重试会在真断网时
  变成一个紧凑的失败循环。重试权属于用户操作与 `OutboxQueue`。
- **不做全局「网络恢复后自动重试」**：那需要订阅连通性事件，而 §5.1.1 已明确
  「有默认路由 ≠ 服务端可达」——`connectivity_plus` 给不出可信信号。下一次
  用户操作会自己刷新成功。

---

### 6.40 新建对话不需要输入标题（用默认占位 `新对话`）

`GroupListPage` 的「新建对话」按钮此前会弹一个输入框要求先起名字，空输入
（含全空格）时确认按钮禁用。现已去掉这个对话框：**点一下就用
`defaultGroupTitle`（`新对话`）建并直接进入该对话**。

#### 为什么

1. 建对话的**真实意图**是「开一个干净上下文继续聊」，不是「先起个名字」。
   逼用户先想名字会让最常见的动作多一步，而名字随后能在对话设置里改
   （`_RenameDialog` 仍在）。
2. **webapp 本来就是这个取向**：`use-workbench-state.ts` 的
   `createGroup(title?)` 标题可选，`WorkbenchShell.handleCreateGroup(title?)`
   在无参调用时不传 title；`ChatInputArea` 的「新对话」按钮就是直接建。
   客户端此前是**独有**的多一步。
3. 服务端 `POST /chat/groups` 对空标题**不报错**，而是兜底成「新对话组」
   （`chat.go` 的 `if title == "" { title = "新对话组" }`）——即「必须有标题」
   从来不是服务端约束，是客户端自己加的。

#### 实现要点

| 项 | 变化 |
|---|---|
| `defaultGroupTitle` | 新增公开常量（`新对话`），`_createGroup` 与测试共用同一个值 |
| 新建标题对话框（原私有类，已删除） | **删除**（连同 `group-create-dialog` / `group-create-field` / `group-create-confirm` 三个 key） |
| `onCreateGroup` 签名 | **不变**（仍收 `String title`）：装配层仍能改标题策略，页面只是不再问用户 |
| `_creating` 防重入 | 保留并新增用例：请求在飞时入口 `onPressed == null` |

#### 测试的连带改动（不是放宽断言）

删掉对话框后，三处「填标题 → pump → 点确认」的前置步骤**全部消失**（`enterText`
与随后那次 `pump` 都是为解除确认按钮禁用而存在的）。受影响的用例：

| 文件 | 改动 |
|---|---|
| `group_list_page_test.dart` | 「trim 后的标题」「空标题禁用确认」两条**删除**（被测对象已不存在）；「成功后插到最前」拆成「不弹框 + 默认标题 + 导航」与「插到最前」两条；新增「往返期间禁用入口」 |
| 两端 `router_list_test.dart` | 去掉 `enterText` + `pump` + 点确认，只留「点入口」 |

⚠️ **`adapter.onPost(..., data: {'title': '新对话'})` 的精确匹配必须保留**：它是
「标题确实发出去了」的唯一断言点——只断言导航会漏掉「回调拿了标题却没用」
（与 `createTurn` 的 `inputText` 那类缺陷同型，见 §6.14）。

---

### 6.41 「在文件管理器中定位」全平台失效 + 下载平铺覆盖（2026-10）

Windows 用户报「在文件管理器中定位已下载的文档，总是失败」。查下来是**三个
独立缺陷**叠加，且**没有一个会报错**——用户只看到「点了没反应」或「无法定位文件」。

#### 缺陷 ①：`revealPath` 用目录校验挡掉了所有文件

`DesktopCapabilities.revealPath` 的文档写的是「在系统文件管理器中打开本地**目录**」
（`desktop_capabilities.dart:179`），实现按此用 `Directory(path).exists()` 校验。
而**两个真实调用点传的都是文件路径**：

| 调用点 | 传什么 |
|---|---|
| `router.dart` 的 `_revealAgentFile`（时间线卡片） | `_ensureAgentFileLocal` 刚写下的**文件** |
| `providers.dart` 的 `revealDeliverableProvider`（交付物面板） | 同步/下载得到的**文件** |

实测（`dart run`）：

```
File('/tmp/revtest/a.txt').exists()      = true
Directory('/tmp/revtest/a.txt').exists() = false   ← 恒 false
Directory('/tmp/revtest').exists()       = true
```

即：**在校验处就返回了，根本没 spawn 任何进程**。与平台无关——Linux/macOS 同样
失效，只是 Windows 用户先报上来。

#### 缺陷 ②：Windows 上「定位」被实现成了「打开」

即使放行，`spawnSystemOpen` 的 Windows 分支是 `explorer <path>` = **用默认程序
打开它**（Word/编辑器弹出来，或无关联时什么都不发生），不是「在资源管理器里选中」。
正确命令是 `explorer /select,<path>`。

三个平台三种命令，一个都不能混：

| 目标 | Windows | macOS | Linux |
|---|---|---|---|
| 打开目录 | `explorer <dir>` | `open <dir>` | `xdg-open <dir>` |
| **选中文件** | **`explorer /select,<file>`** | **`open -R <file>`** | `xdg-open <parentDir>`（无选中概念） |

⚠️ `/select,<path>` 必须是**一个**参数：`['/select,', path]` 会让 explorer 把
`/select,` 当成要打开的路径（explorer 的参数解析不走标准 CRT）。

#### 缺陷 ③：下载平铺，同名文件互相覆盖

两条手动下载链路的落盘位置都是**平铺**的：

| 链路 | 修复前 | 修复后 |
|---|---|---|
| 时间线内联卡 | `downloads/agent/<文件名>` | `downloads/agent/{groupId}/<group 内相对路径>` |
| 交付物面板 | `downloads/deliverables/<文件名>` | `downloads/deliverables/{groupId}/<group 内相对路径>` |
| 交付物同步（本来对） | `{用户选目录}/{gid}/reports/a.md` | 不变 |

后果三条：**互相覆盖**（每个 group 都有自己的 `README.md`）、**丢目录结构**
（`reports/a.md` 压成 `a.md`，与面板显示的树形路径不一致，用户按面板去找必然
找不到）、**分不清归属**（磁盘上没有信息说明文件属于哪个对话）。

#### 修法

| 层 | 改动 |
|---|---|
| `spb_platform` `system_open.dart` | 新增 `spawnSystemReveal`（三平台命令见上表）+ `revealSystemEntry`（按 `FileSystemEntityType` 分流：目录 → 打开、文件 → 选中、`notFound` → false）+ 可注入的 `EntityTypeProbe` |
| `spb_domain` `local_download_path.dart` | 新增纯函数 `deliverableDownloadRelPath` / `agentFileDownloadRelPath`：`{groupId}/<相对路径>`，逐段过 `isValidPathSegment` |
| `apps/*` `providers.dart` / `router.dart` | 四条下载链路改用上面两个函数（桌面 + 移动**同构**） |
| `bootstrap.dart` `revealPath` | 一行转发给 `revealSystemEntryHere`（分流逻辑放在 `spb_platform`，因为 `bootstrap.dart` 依赖 window_manager 等插件、测试里构造不起来） |

#### 为什么分流放在 `spb_platform` 而不是 `bootstrap.dart`

「目录就打开、文件就选中」是**正确性核心**（写反会让「定位」变成「用默认程序
打开」），必须能在无桌面环境的 CI 里逐条断言。`bootstrap.dart` 的
`PlatformDesktopCapabilities` 要 `window_manager`/`tray_manager` 才能构造，而
`revealSystemEntry` 只需注入 `platform` + `runner` + `probe` 三个参数。

#### 为什么口径放在 `spb_domain` 而不是两个 app 各写一份

这是**同一份**计算被抄了三遍（桌面 router / 桌面 providers / 移动两处）。
只改一端就会出现「桌面端修好了、移动端还在覆盖」——正是 §6.17 接线守卫想防的
那类漂移，而它**查不到函数内部实现**。故收敛成纯函数（可无头单测）。

#### 路径穿越防御（两段的来源都是服务端可控输入）

- `UfsFileEntry.path` 是服务端物化的（`/workspace/groups/{gid}/reports/a.md/`，
  **文件也带尾斜杠**——不剥会得到空文件名）；
- `AgentFileItem.relativePath` 是事件载荷。

两者逐段过 `isValidPathSegment`（空段 / `.` / `..` / `\` / NUL 一律拒绝）。
**非法时退化为单文件名而不是报错**：文件还是能拿到，只是没有目录结构；报错会让
「点下载」在一个路径异常的文件上永久失败。退化后仍写在下载目录内——
**不会**逃到目标目录之外。

⚠️ `groupId` 也要校验：它是 `widget.groupId`（路由参数），直接拼进去时含 `../`
就能把整个下载目录指到别处。

#### 测试（17 + 12 + 1 + 1 条）

| 层 | 条数 | 钉住 |
|---|---|---|
| `spb_domain` `local_download_path_test.dart` | 16 | groupId 段 / 保留子目录 / 尾斜杠 / 穿越退化 / 非交付物路径 / 两端同名文件落不同目录 |
| `spb_platform` `system_open_test.dart` | 12 | `/select,` 是单参数 / macOS `-R` / Linux 父目录 / 尾斜杠剥离 / 相对路径不 spawn / 退出码语义 / spawn 异常降级 |
| 同上（`revealSystemEntry`） | 7 | 文件 → 选中、目录 → 打开、`notFound` → 不 spawn、空路径、探测异常、真实 `realEntityType` 接线 |
| `apps/spb_desktop` `router_workbench_test.dart` | 1 | 从**真实 router** 点「在文件管理器中定位」，断言 `caps.revealedPaths` 收到文件的绝对路径 |

⚠️ **最后一条为什么必须打真实 router**：页面测试自己传参（接不接线它不管）——
这正是 §6.16 移动端宽屏搜索入口丢失的成因。

#### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| `revealSystemEntry` 对文件也调 `spawnSystemOpen` | 2 条失败 |
| `/select,` 拆成两个参数 | 1 条失败 |
| `deliverableDownloadRelPath` 去掉 groupId 段（退回平铺） | 3 条失败 |
| `agentFileDownloadRelPath` 去掉段级校验 | 1 条失败 |
| Linux 分支不剥尾斜杠 | 1 条失败 |

#### 有意不做

- **不合并 `openFile` 与 `revealPath`**：接口文档明确拒绝合并（会抹掉调用方的
  意图）；两者校验与命令都不同。
- **不在 Windows 上做「打开了吗」的二次校验**：`explorer /select,` 的退出码同样
  不可靠（见 §6.35），且没有廉价可靠的探测手段。
- **不改用保存对话框**：需要额外平台插件与权限面，而「下载」本身只需要一个
  稳定路径。
- **移动端不接定位**：注入的是 `NoopDesktopCapabilities`（§6.10 的取向：隐藏
  菜单项比「点了报错」好），但**下载布局仍与桌面端同构**——覆盖问题一样存在。

---

### 6.42 自动同步：可配置的启动 / 周期 / 进对话按需（2026-10）

交付物同步此前只有**手动**入口（托盘「立即同步交付物」/ 同步页按钮）。用户
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
  （§6.10 同一判据）。
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

自动同步只是**触发时机**变了，同步本身的行为完全不变（AGENTS.md §10 的
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

---

### 6.43 进入对话时按需同步（2026-10）：判定 → 提示条 → 用户点

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
却什么都不同步。故探测侧的 `_isDeliverableEntry` **必须**同时排除两类。

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
里，而诊断报告（§6.20）只收运行时可见的日志。

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
| 探测侧 `_isDeliverableEntry` 不排除机器产物 | 2 |
| `shouldSync` 用落盘 relPath 判机器产物（TTS 在 workspace 布局漏网） | 1 |
| `machineGeneratedSegments` 去掉 `.archive` / `_attachments` | 1 |
| `_resolveAgain` 循环去掉（在途时直接 return） | 1 |
| 「立即同步」成功后不 `invalidate` 本地索引 | 1 |
| `DeliverableSyncUseCase` 用共享游标作定向同步的时间下限 | 2 |

⚠️ 「路由层不检查冷却」这条**最初是假绿**：我的断言查的是节流器自己的状态
（`throttle.allows` 为 false），而没有验证路由层真的**调用**了它。修法是新增
一条「预置节流器 → 打开对话 → 断言一次探测都没跑」的用例。这与 §6.17 / §6.33
同一类：**只测被调用的组件、不测调用点**，接线断了也绿。

#### 有意不做

- **不做「只同步这个 group」**：硬约束，见上（会把共享游标推过其它 group）。
- **不做自动下载（静默）**：首次全量 4.7 GB，用户需要看得见、能拒绝。
- **不做「提示条里显示具体文件列表」**：侧边栏「交付物」tab 已经承担这个
  职责，提示条只需回答「有没有、多少个」。
- **不做探测结果持久化**：它是「这一刻的事实」，落盘会在下次启动时变成过期
  信息（与 §5.4 的 `schedule_created` 不带绝对时间同一取向）。

---

### 6.44 进入对话后 AppBar 显示对话名（2026-10）

**症状**：进入某个对话后，AppBar 仍显示固定的「对话」——与列表页的 AppBar
同名。用户看不出自己是否真的进去了，也看不出进的是哪一个（桌面端从搜索结果 /
待确认列表跳进来时尤其明显）。

#### 修法：两端 router 各自派生 `_appBarTitle`

`ConversationPage` 的 `title` 本来就是参数（页面不持有 `ChatGroup`，权威 group
由两端 router 的 `_loadGroup()` 拉）。故改的只是**装配层传什么**：

```dart
String get _appBarTitle {
  final title = _group?.title.trim() ?? '';
  return title.isEmpty ? '对话' : title;
}
```

两端逐字同构（桌面 `router.dart` / 移动 `router.dart`）。`_group` 已由
`GET /chat/groups/:id` 异步拉取，且 `GroupUpdate.applyTo`（rename 事件）与
`_loadGroup`（切换 agent 后重拉）都会刷新它，故标题会跟着改名走，无需额外订阅。

#### 两个判据

| 情况 | 显示 | 为什么 |
|---|---|---|
| `_group` 未就绪 | `对话` | 空标题会让 AppBar 只剩图标（看起来像渲染坏了），且标题宽度变化会拖动右侧图标 |
| `title` 为空串 | `对话` | 服务端对空标题会兜底成「新对话组」，但本地刚建的 group 可能还没回读；空串同样不该渲染 |

#### 为什么两端必须各有一条 router 层用例

`ConversationPage` 自己的测试**自己传 `title`**——「router 又写回硬编码」在
那里永远发现不了。这是 §6.17 / §6.33 / §6.43 反复出现的同一失败模式：**只测
被调用的组件、不测调用点**。故两端各有一条从路由出发、断言
`find.widgetWithText(AppBar, '季度复盘')` 存在且 `'对话'` 不存在的用例。

⚠️ **既有用例的注释也一并改了**：`apps/spb_mobile/test/router_list_test.dart`
的「StatefulShellRoute：切标签后返回」原本靠「时间线的空提示」区分对话页与列表页，
理由是「两个 AppBar 都叫『对话』」——现在对话页显示的是对话名，那个理由不再
成立，故改为直接断言对话名（并补了 `/chat/groups/grp_x` 的 mock）。

#### 反向验证（实测）

把两端 `title: _appBarTitle` 改回 `title: '对话'` → 两端各 1 条失败。

---

### 6.45 主窗口尺寸按屏幕工作区自适应（2026-10）

**症状**：1080p 的 14 寸笔记本上打开应用，窗口上下都超出屏幕——标题栏跑到
屏幕外，**既不能拖动也不能点最大化**。

#### 根因：硬编码的是**逻辑像素**，与 DPI 缩放无关

`WindowSpec.main` 是 `1180×800` 的**逻辑像素**。1080p 在 Windows 上默认
125%~150% 缩放，逻辑屏高只有 864 / 720：

| 系统缩放 | 逻辑屏高 | 工作区高 | 800 高窗口居中后的 y |
|---|---|---|---|
| 100% | 1080 | 1040 | 120 ✅ |
| 125% | 864 | 824 | 12 ⚠️ 贴顶 |
| **150%** | **720** | **680** | **−60 ❌ 标题栏出屏** |
| 175% | 617 | 577 | −111 ❌ |

负的 y = 标题栏（可拖拽区 + 最大化/关闭按钮）在屏幕外。用户没有别的办法把它
挪回来——那是窗口唯一可拖拽的地方。

#### ⚠️ **不是「没考虑任务栏」**

这个方向的猜测值得记下来，因为它会把人引向错误修法。`window_manager.center()`
用的就是 `visibleSize`（**已排除任务栏与系统栏**）：

| 平台 | `visibleSize` 来源 |
|---|---|
| Windows | `MONITORINFO.rcWork`（`screen_retriever_windows_plugin.cpp`） |
| Linux | `gdk_monitor_get_workarea`（`screen_retriever_linux_plugin.cc`） |
| macOS | `NSScreen.visibleFrame`（`ScreenRetrieverMacosPlugin.swift`） |

缺陷纯粹是「**窗口比工作区还高**」——居中公式 `(workH - winH)/2` 在
`winH > workH` 时自然给负数。任务栏只是让工作区又少了约 40 逻辑像素，
把本来「刚好贴顶」变成「明确出屏」。

#### 修法：按工作区比例收缩，两端夹紧

`spb_platform` 新增 `MainWindowSize`（纯逻辑，可无头单测）：

```dart
MainWindowSize.fromDisplay(visibleSize: …, fullSize: …)  // 优先工作区
  → compute(workWidth, workHeight, minWidth, minHeight)
      width  = clamp(workW * 0.85, cap: 1180, floor: minWidth)
      height = clamp(workH * 0.85, cap: 800,  floor: minHeight)
```

`apps/spb_desktop/lib/bootstrap.dart` 的 `applyWindowSpec` 改为先取显示器
再算尺寸，取不到（无 DISPLAY / 平台未实现）时退回 spec 的静态值。

| 判据 | 取值 | 为什么 |
|---|---|---|
| 占工作区比例 | **0.85** | 四周留一圈桌面可见，用户一眼看出「这是个窗口」而非最大化态；贴满时标题栏正好顶到屏幕上沿，反而不好拖 |
| 宽度上限 | 1180（= spec 原值） | 大屏上继续变宽只会降低可读性 |
| 高度上限 | 800（= spec 原值） | 同上 |
| 下限 | `spec.minWidth/minHeight` | 它们是为**布局**定的（低于它页面溢出）。小屏上宁可让窗口略高于工作区（窗口管理器自己钳制），也不让布局坏掉 |
| 先 cap 后 floor | `_clampSize` | 顺序反了会让 500 高的工作区得到 800（又出屏） |

#### 为什么判据收在 `spb_platform` 而不是 `bootstrap.dart`

`PlatformDesktopCapabilities` 要 `window_manager`/`tray_manager` 才能构造，
**测试里造不出来**，那里的逻辑无法在无头 CI 验证（§6.41 的先例：`revealPath`
的目录/文件分流正是因为这一点才被挪进 `spb_platform`）。故连「工作区优先还是
整屏优先」这个选择也一起挪过去——bootstrap 只剩一行转发。

#### 测试（25 条）

`packages/spb_platform/test/main_window_size_test.dart`。判据**不是**「等于某个
数」，而是**结果必须放得进工作区**（除非工作区小到连 min 都放不下）：

| group | 钉住 |
|---|---|
| 7 种常见工作区（含 1080p @100/125/**150**/175%、1440p、4K@200%、超宽） | 算出的尺寸都不超出工作区 |
| 具体取值 | 150% 得 600（不再是 800）、4K 封顶 1180×800、中等屏按比例 |
| 显示器信息缺失（0 / 负数 / 单边为 0） | 退回规格值，**不算出 0×0** |
| 小屏（640 / 500 高） | 兜底到 `minHeight` 而非继续缩 |
| `fromDisplay` 工作区优先 | 有 `visibleSize` 时忽略 `size`；缺失时回退；零尺寸也走降级 |
| 常量 | `fillRatio ∈ (0,1]`、上限不小于 spec |

#### 反向验证（实测）

| 改坏 | 失败用例数 |
|---|---|
| `compute` 改回「直接返回 1180×800」（改前行为） | **7** |
| `fromDisplay` 改成 `fullSize ?? visibleSize`（整屏优先） | **2** |

#### 已知边界

- **只对主窗口生效**：`applyWindowSpec` 本就只接受 `WindowRole.main`（单窗口
  模型下对 settings/quickCapture 调用会改变主窗口尺寸，见该方法的注释）。
  悬浮窗的定位另有 `QuickCapturePlacement`（按鼠标所在显示器）。
- **多显示器只取主显示器**：`getPrimaryDisplay()`。窗口不在主屏时的二次定位
  属独立需求（用户拖动后本就会记住位置）。
- **不改 `WindowSpec.main` 的静态值**：它是「显示器信息拿不到」时的降级值，
  也是 `MainWindowSize` 的上限来源。改它会让大屏也变小。
- **需真机验证**：本机无 `DISPLAY`（§9），`xvfb-run` 下渲染不稳定，只能验证
  纯逻辑。真实缩放下的表现需在有桌面环境的机器上确认。

### 6.46 侧边栏收起不销毁子树（滚动位置 / 选中 tab 保留，2026-10）

**症状**（用户报障）：「切换侧边栏后滚动条位置会重新置顶」。

#### 先分清两件不同的事

| 操作 | 修复前 | 原因 |
|---|---|---|
| **切换 tab**（交付物 ↔ 待办 ↔ …） | ✅ 已保留 | `ChatSidebar` 内部用 `IndexedStack`，已激活的 tab **一直挂载**（issue #16 的惰性构建只影响「从未切到过」的 tab） |
| **收起再展开整个侧边栏** | ❌ 全部丢失 | 装配层把整棵子树从树上摘掉 |

故「滚动条置顶」不是 `ChatSidebar` 的问题，是**装配层**的问题：

```dart
// 修复前 apps/spb_desktop/lib/router.dart
if (!_showSidebar) return withHint(conversation);   // ← ChatSidebar 连同所有面板被销毁
```

销毁意味着：`_ChatSidebarState._index` 重置回 0（选中的 tab 也一起丢）、
`_visited` 重置、每个面板的 `State` 与 `ScrollPosition` 全部重建 → 再展开是
一个全新的 `ListView`，`pixels` 归零。

#### 修法：`Offstage` 保留挂载，但**惰性**建首帧

```dart
if (!_sidebarEverShown) return withHint(conversation);   // 从未展开 → 根本不构建
...
Offstage(offstage: !_showSidebar, child: Row(...))       // 展开过 → 永远保留
```

`_sidebarEverShown` 在点开开关时置 true，此后不再回落。

#### 为什么必须加 `_sidebarEverShown` 这层守卫

`GroupDeliverablesPanel.initState` 会立即 `_load()` 发一次 HTTP。若无条件
`Offstage`，**每个对话页一打开就为一个用户没看过的面板付一次请求**——而
「默认折叠时不取数」是既有且有意保留的语义，`router_workbench_test.dart` 的
「默认不展开：开关存在但侧边栏不可见，未取数」钉住了它（反向验证：去掉这层
守卫 → **5 条失败**）。

这与 `ChatSidebar` 内部的 `_visited` 惰性构建是**同一取向的两层**：外层决定
「要不要建这棵树」，内层决定「建好之后要不要激活某个 tab」。

#### `Offstage` 到底省了什么、没省什么（实测）

`RenderOffstage` 的实现（`packages/flutter/lib/src/rendering/proxy_box.dart`）：

```dart
void performLayout() {
  if (offstage) {
    child?.layout(constraints);   // ← 仍然布局
  } else {
    super.performLayout();
  }
}
bool paintsChild(RenderBox child) => !offstage;              // 只跳过绘制
bool hitTest(...) => !offstage && super.hitTest(...);        // 只跳过命中
void visitChildrenForSemantics(v) { if (offstage) return; ... }  // 只跳过语义
```

**只省 paint / hitTest / 语义**，Element 树、RenderObject 树、State、已加载数据、
布局计算**全部保留**。用 2000 项列表实测（`tester.allElements` + 遍历
RenderObject 树）：

| 方案 | 展开 | 收起 | 收起时释放 |
|---|---|---|---|
| 修复前（从树里移除） | 542 elements / 202 RO | 181 / 45 | −361 / −157 |
| `Offstage` | 543 / 203 | **543 / 203** | **0 / 0** |

#### 代价（**诚实记录，别再说「不占内存」**）

| 项 | 量级 |
|---|---|
| Element 树 | ~360 个 × ~200 B ≈ **70 KB** |
| RenderObject 树 | ~157 个 × ~300–500 B ≈ **60 KB** |
| `GroupDeliverablesPanel._entries` | 每个 `UfsFileEntry` ≈ **420 B**（9 字段 + 4 个 String） |
| 同上 `_tree`（`ArtifactNode`） | 每节点 ≈ 50 B |
| 其它面板 State（`_collapsed` 等） | 几十字节 |

按文件数放大 `_entries` + 树：

| 文件数 | 占用 |
|---|---|
| 100 | 0.05 MB |
| 1000 | 0.45 MB |
| 3000 | 1.36 MB |
| **5666**（生产实测全量） | **2.57 MB** |

即「收起的侧边栏 ≈ **130 KB 固定 + 已加载的交付物清单（最多 ~2.6 MB）**」。
且 `_entries` 只在用户**确实点开过**「交付物」tab 后才存在（`_visited` 惰性）。

换来的是：再展开**零延迟、零请求、状态全在**。被否决的替代方案是「只存滚动
位置与 tab 选择」（几个 double + 一个 int），但要给 6 个面板各接
`ScrollController`/`PageStorageKey`，且 `PageStorageBucket` 在 route 层、
跨对话会串（需按 `groupId` 做 key）——工作量远大于收益。

#### 附带变化：隐藏期间也会刷新（是好事）

子树仍挂载，故 SSE 新文件事件 bump 的 `reloadToken` 仍会触发
`GroupDeliverablesPanel.didUpdateWidget` → 重新拉清单。再展开时数据已是新的，
不用等一轮加载。修复前（已销毁）这条路径不存在。

⚠️ 这条**没有**单独的测试（尝试过，需要精确构造 `agent.file.created` 事件载荷
`{action, relative_path, ufs_file_id, size, mime_type}` 与刷新时序，成本高于
收益）。它是 `Offstage` 语义的直接推论，故记在这里而不是硬凑一条脆弱用例。

#### 测试（2 条，都在 **router 层**）

| 用例 | 钉住 |
|---|---|
| `收起再展开侧边栏：滚动位置与选中的 tab 都保留` | 切到「待办」→ 收起 → 展开：仍停在「待办」（`todos-empty` 在、`deliverables-tree` 不在），且 `ufs.listCalls.length == 1`（**没有重新取数**） |
| `收起侧边栏后交付物树仍挂载（滚动位置不丢）` | 60 个文件 → 拖 -400 → 收起 → 展开：`position.pixels` 与收起前**相等** |

**为什么必须在 router 层**：`ChatSidebar` 自己的测试用 `IndexedStack` 切 tab，
那里本来就不销毁子树（已绿）。真正的缺陷在**装配层**的「收起即移除」——页面级
测试覆盖不到（与 §6.17 / §6.43 同一失败模式：只测被调用的组件、不测调用点）。

#### 反向验证（实测）

| 改坏 | 失败用例 |
|---|---|
| 改回「收起即从树里移除」（`if (!_showSidebar) return conversation;` + `offstage: false`） | **2**（两条新用例都红） |
| 去掉 `_sidebarEverShown` 守卫（无条件 `Offstage`） | **5**（含「默认不展开…未取数」与两条「已同步则直接打开」） |

#### 已知边界

- **只在同一次对话页生命周期内保留**：`_ChatPageState` 随路由切换销毁，
  换对话再回来仍是默认收起 + 第一个 tab。跨对话记住 tab 选择是独立需求
  （需要提到 provider 层，且要考虑「上次看的 tab 在当前对话里不存在」，
  例如 `showDebugPanelProvider` 关闭时「诊断」tab 不存在）。
- **`_ChatSidebarState` 的 `initialIndex` 夹取上限有既有 bug**：
  `widget.initialIndex.clamp(0, (widget.tabs.length - 1).clamp(0, 1))` 把上限
  压到 1，`initialIndex >= 2` 无效。`chat_sidebar_test.dart` 已把它标注为
  「既有行为」，**非本节引入**，未在本轮修改（改它会影响既有 tab 索引语义，
  需单独一轮）。
- **需真机验证**：本机无 `DISPLAY`（§9），只验证了 widget 树层面的状态保留，
  真实滚动手感（尤其是 `Offstage` 期间滚动条不显示、展开后位置正确）需在
  有桌面环境的机器上确认。

### 6.47 流式对话性能：观测手段与已确认的成本项（2026-10）

一次「滚动不顺 / 流式期间卡顿」的排查收口。本节记**怎么观测**、**哪些成本是
实测确认的**、**哪些已经修掉以及判据是什么**，以及**哪些看着像问题但有意不动**。

> ⚠️ **所有数字都是 build/layout 成本测量，不是真机帧率**。本机无 `DISPLAY`、
> 无真机（§9），跑不出 vsync 对齐的真实帧时间。数字来自「强制重建一次 /
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
8 秒冲干净 500 条环形缓冲（§6.20），而诊断报告要的是**出事前后**的上下文。
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

**冷/暖差 4–15×** 是「滚动不顺」的主因：`ListView.builder` 的子项滚出
`cacheExtent` 即 dispose，`gpt_markdown` 的增量解析缓存（`_settled` 前缀）
随之全丢，滚回来要重解析。

#### 三、已修项与判据

| 修了什么 | 判据（回归用例钉住的事实） |
|---|---|
| **build 期线性扫描收敛** | 修复前 `_streamingItem` 被 `_staleTurnItem` / `_canCancelTurn` / `_visibleActivity` 各调一次（每次全量扫）→ 一次 build 扫 3 遍。现在 `build` 里算一次，尾向扫描遇 `turnId != streaming.turnId` 立即 `break`。用例断言 `PerfProbe.visitedItems <= 2 * n`（修复前实测 1200 > 400） |
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
| **只缓存 `AssistantMessageItem`** | 它的渲染输入只有 4 个显式字段（`text` / `isStreaming` / `keepAlive` / `onLinkTap`），指纹可穷举。其余 item 夹带页面状态（`ConfirmationItem` 读 `_resolving`、`FeedbackRequestItem` 读 `_submittedFeedback` 与 `_feedbackTTL`、`ErrorItem` 读 `_retryingTurnId`），逐项列必然漏一处，而漏掉的表现是「状态变了界面不变」 |
| 指纹含 `isStreaming` | 它是 item 字段 **× `_staleTurnIds`**（超时兜底会让 true 变 false），不是 item 自带值 |
| 指纹含 `keepAlive` | 它是 `_keepAliveIds`（窗口滑动时逐条变） |
| 指纹含 `onLinkTap` | 装配层换回调时不换新实例就会走旧逻辑 |
| **主题/语言/文本缩放不进指纹** | 它们走 `InheritedWidget`；复用同一实例时子树的 `dependOnInheritedWidgetOfExactType` 依赖关系仍在，框架会自己标记重建 |
| `_bubbleCacheLimit = 200`，简单逐出（非 LRU） | 缓存只为「刚看过的那些」服务；维护「最近使用」要在命中路径上搬动元素，而命中路径正是要压到最便宜的那条 |
| 切对话时 `_bubbleCache.clear()` | `item.id` 是服务端事件 id，跨对话**不保证唯一**；不清可能把 A 对话的气泡交给 B 对话的同 id 项 |

**修复后**：流式增量 `1`、activity 心跳 `0`。**三个变异都被用例捕获**：绕过缓存
→ 6；指纹漏掉 `text` → 0（连该变的都不重建）；指纹漏掉 `keepAlive` → 被
keep-alive 的上界用例抓住。

#### 六、有意不做

| 项 | 为什么不做 |
|---|---|
| **隐藏 / 收起工具调用** | 折叠态**已经**近乎零成本：`Expansible` 的 `shouldRemoveBody = closed && !widget.maintainState` → `child: shouldRemoveBody ? null : result`，折叠时 `children` 完全不构造（`ExpansionTile.maintainState` 默认 false）。而隐藏会丢信息，且**对话内搜索依赖工具名 + 参数 + 输出**（§6.15）。该行为已由守卫用例钉住（`item_widgets_test.dart` 的「折叠态不构造参数与结果」） |
| **`itemExtent` / `prototypeItem`** | 行高由 Markdown 内容决定，是**变高列表**，给不出固定 extent |
| **改 Go API 契约** | 客户端适配服务端，不是反过来（仓库硬约束）。任何「为了客户端方便而改 Go API」的提案要先证明无法在客户端解决 |
| **把 `JsonEncoder.convert` 提到 `build()` 顶部** | 看着能「早点拿到字符串」，实际会让折叠态也付转换成本（4.7 µs/次 × 条数）。`children` 是**急切求值**的列表字面量，放进 `ExpansionTile` 的 `children` 里才会随 `shouldRemoveBody` 一起被跳过 |
| **给时间线加 `RepaintBoundary`** | 子项默认已带（`SliverChildBuilderDelegate.addRepaintBoundaries = true`） |

#### 七、已知边界

- **本机无 `DISPLAY`、无真机**：所有数字是 build/layout 成本测量，不是真机
  帧率。`xvfb-run` 下渲染不稳定，**不能**把「窗口出现了」当作渲染正确的证据。
- **release AOT 通常比 debug JIT 快 5–10×**：60 段 Markdown 的 441.6 ms 在
  release 下估计 50–90 ms，仍超 16.7 ms 预算——但这个换算**没有实测**，故
  §五 的取舍（缓存哪些、窗口多大）应在有桌面环境的机器上用
  `SPB_FRAME_TIMING` 复核一次。
- ~~`_looksLikeError` 的 `toLowerCase()` 是全量拷贝~~ → **已修**，见 §八。
- **`_thumbnailMemo` 的键只有 `ufsFileId`**：同一路径被新版本覆盖时**不失效**
  （服务端事件不带 mtime），会继续展示旧缩略图直到切对话。
- **翻页 `loadOlder` 前插不补偿滚动位置**（既有行为）；`maxScrollExtent` 是
  惰性估算，会跨若干帧逐步修正。

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

---


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
- [x] 自动同步（启动后一次 / 周期 N 分钟，默认关闭；仅桌面端装配，见 §6.42）
- [x] 进对话时按需同步（默认关闭；判定命中只提示、不静默下载，见 §6.43）
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
| `.github/workflows/ci.yml` | **验证**：analyze / format / 12 个守卫 + 7 个自测 / test / 能否构建 | push main + PR | Actions 7 天 |
| `.github/workflows/release.yml` | **交付**：三端出包 + 建 Release | `v*` tag + 手动 | Release 长期 / Actions 30 天 |

⚠️ **两条流水线的产物都会被人下载运行**。`ci.yml` 名义上是「验证能否构建」，
但 artifact 在 Actions 页 7 天内可下载——用户不会区分它和 release 的包。故两边
必须传同一套构建参数（§6.33）。

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
| ~~归属反馈 TTL 的三个实现缺陷（确认卡被静默吞掉 / 不可热调 / 客户端不知道已失效）~~ | ✅ 已修（§6.28.2）：**数值本身经数据验证是对的**（24h 下回执率从 0/30 变成 2/6，实测作答耗时 1.8min 与 13.6min，后者超过原 10min TTL），故「优化 TTL」落到实现上。① `HasPendingChatConfirmation` 不按 kind 过滤——一条 pending 反馈会让该 group **24 小时**内建不出任何确认卡，且完全静默（两个 kind 的 pending 语义本就不同：确认卡阻塞待拍板 / 反馈是可选问卷）。② TTL 从编译期常量改为 `runtime.attribution_feedback_ttl_seconds`（**只让归属反馈可覆盖**，确认卡仍 10min——它挂在 pending turn 上，调大只会让「卡还在但 turn 已死」变得可能）。③ `GET /api/chat/turn-runtime` 新增 `attribution_feedback_ttl_seconds`，客户端用「事件 createdAt + TTL」自行判失效并置灰为「已失效」，把 404 从主路径降为兼容路径。⚠️ 三处易写错：`envValueForKey` 必须返回 24h 而非 0（页面会读成「功能关闭」——守卫精确抓到了这一处）；`0` 是「不覆盖」不是「立即过期」（Snapshot 零值就走这条）；`expired` 不能折进 `resolved`（否则把没答过的卡写成「已反馈」）。Go +7 条 / Flutter +12 条用例，6 项反向验证逐条实测 | §6.28.2 |
| ~~归属反馈卡「点了没反应」~~ | ✅ 已修（§6.28.1）：**两个叠加的缺陷**。① `ChatApi.resolveFeedback` 发 `{'correct': bool}`，而服务端入参只有 `reply`/`index`/`group_id`（`ShouldBindJSON` 静默忽略未知字段 → `Reply` 空 → `400 reply is required`）。实测：`{"correct":true}` → 400，`{"reply":"准确"}` → 200。改发 `{'reply': correct ? '准确' : '不准确'}`。② 即使请求成功，卡片置灰**只**看 `routing_feedback` 事件（旁路事件，SSE 断线时永不到达），而回执是一次性 CAS——用户重试必然 404，越点越坏。故 `onResolveFeedback` 签名 `void` → `Future<void>`，成功才本地置灰（`_submittedFeedback`）、失败提示且保留可点，404 单独提示「已失效」。⚠️ 修复前三处**假绿**：`spb_api` 零条 `resolveFeedback` 用例；两端 router 测试断言的正是**错误键名** `containsPair('correct', …)`，把 bug 固化成了预期；页面用例只看回调被调用不看卡片后续状态。新增 11 条用例（含真实 `HttpServer` 契约），3 项反向验证逐条实测 | §6.28.1 |
| 窄屏 AppBar / 输入区 RenderFlex 溢出（320–412dp） | ✅ 已修（issue #31）：按频率分档 + 溢出菜单 + `AgentSwitcher.compact`；新增窄屏回归用例（`physicalSize` 压到 320/360/390/412dp） | issue #31、§6.16 |
| ~~对话内搜索（搜 agent 回复）缺失~~ | ✅ 已实现：本地搜已加载时间线，面板顶部在 `upperHistoryUnloaded` 时告知边界 | §6.15 |
| ~~进入对话后 AppBar 仍显示固定的「对话」（与列表页同名，看不出进了哪个对话）~~ | ✅ 已修（§6.44）：两端 router 的 `ConversationPage(title:)` 改传 `_appBarTitle`（取自 `_group.title`，未就绪/空串时退回「对话」）。`_group` 已由 `_loadGroup` 与 `GroupUpdate.applyTo`（rename 事件）刷新，故改名后标题跟着走。⚠️ 两端各补一条 **router 层**用例（`ConversationPage` 自己的测试自己传 `title`，发现不了「router 写回硬编码」——§6.17/§6.33/§6.43 同一失败模式）；另把 `router_list_test.dart` 里「两个 AppBar 都叫『对话』」的旧注释与区分手段一并修正。反向验证：改回硬编码 → 两端各 1 条失败 | §6.44 |
| ~~1080p 14 寸笔记本上主窗口比屏幕还高，标题栏出屏 → 不能拖动、不能点最大化~~ | ✅ 已修（§6.45）：根因**不是「没考虑任务栏」**——`window_manager.center()` 用的就是 `visibleSize`（Windows `rcWork` / Linux `gdk_monitor_get_workarea` / macOS `visibleFrame`），三平台都已排除任务栏。缺陷是 `WindowSpec.main` 的 **1180×800 是硬编码逻辑像素**：1080p 在 Windows 上默认 125%~150% 缩放，逻辑工作区只有 824/680 高，800 高的窗口居中后 y 为 **−60**，标题栏（唯一可拖拽区 + 最大化按钮）跑到屏幕外。修法：`spb_platform` 新增 `MainWindowSize`（按工作区 0.85 收缩、上限 1180×800、下限 `spec.min*`、**先 cap 后 floor**），`applyWindowSpec` 先取显示器工作区再算尺寸，取不到时退回 spec 静态值。判据收在 `spb_platform` 而非 `bootstrap.dart`（后者要 `window_manager` 才能构造、测试里造不出来，§6.41 同一取向），故连「工作区优先还是整屏优先」也可测。25 条用例；反向验证：`compute` 改回硬编码 → 7 条失败，`fromDisplay` 改成整屏优先 → 2 条失败 | §6.45 |
| ~~桌面端侧边栏收起再展开后滚动条置顶、选中的 tab 重置~~ | ✅ 已修（§6.46）：**先分清两件事**——切 tab 本来就保留（`ChatSidebar` 用 `IndexedStack`，已激活的 tab 一直挂载）；真正丢状态的是**收起再展开**：装配层 `if (!_showSidebar) return conversation;` 把整棵子树从树里摘掉，`_ChatSidebarState._index`（选中的 tab）、`_visited`、各面板 `State` 与 `ScrollPosition` 全部销毁，再展开是全新的 `ListView` → `pixels` 归零。修法是 `Offstage` 保留挂载 + `_sidebarEverShown` 惰性守卫（`GroupDeliverablesPanel.initState` 会立即发 HTTP，无条件 `Offstage` 会让每个对话页一打开就为用户没看过的面板付一次请求——「默认折叠不取数」是既有语义，有测试钉住）。⚠️ **实测纠正一个错误认知**：`RenderOffstage.performLayout` 在 offstage 时**仍会 layout 子树**，只跳过 paint/hitTest/语义——Element/RenderObject/State/已加载数据/布局计算**全部保留**，实测收起时释放 **0 elements / 0 RO**（修复前是 −361 / −157）。代价是收起时仍占 **~130 KB 固定 + 已加载交付物清单（5666 文件约 2.6 MB）**，换再展开零延迟零请求。反向验证：改回移除 → 2 条失败；去掉惰性守卫 → 5 条失败 | §6.46 |
| ~~移动端宽屏（≥720dp）对话内搜索入口不可达~~ | ✅ 已修（issue #33）：宽屏 `enableSearch: true` 摆独立图标，窄屏仍走溢出菜单；两端 router 层各有用例钉住 | issue #33、§6.16 |
| ~~macOS 交付物同步写用户所选目录需 `user-selected.read-write` entitlement~~ | ✅ 已修复（commit `2f5d778`，两份 entitlements 均已含该键） | §8 |
| ~~多窗口可行性~~ | ✅ `window_manager` 做不到，改用主窗口临时变身 | §6.5 |
| ~~剪贴板文件粘贴无原生实现~~ | ✅ 三平台原生 channel 均已实现（Linux/Windows/macOS） | §6.8 |
| ~~CI 产物用 127.0.0.1，用户报「远程计算机拒绝网络连接」~~ | ✅ 已修（§6.33）：`ci.yml` 的三个 `build-*` job 此前**一个 `--dart-define` 都没传**（整文件零命中），产物用 `SpbEnv` 默认值 `http://127.0.0.1:8000`。现在与 `release.yml` 共用同一套 `config` job（Variables → 内置默认值），五个 define 全传。新增 `tools/check_build_defines.sh`（静态按 job 切块断言 + 动态 grep AOT 快照里是否残留默认地址——传了 define 后默认值会被 tree-shake，实测可靠）+ 16 条自测；CI 在 quality 与 build-* 两处各跑一次 | §6.33 |
| ~~Windows 上「门」显示成「方框 + 正中一根竖」~~ | ✅ 已修（§6.38）：根因**不是字符写错**，而是 `SpbTheme` 从未设 `fontFamily`。Flutter **没有**「用系统默认字体」——`ThemeData(fontFamily: null)` 时按平台取 `Typography.material2021` 里**写死字体名**的 TextTheme（Windows = `blackRedmond` = `Segoe UI`，纯拉丁、**零 fallback 列表**，而 Linux 的 `blackHelsinki` 有 6 个）。中文字形只能靠引擎的 last-resort 回退，取决于目标机器装了什么（日文 Yu Gothic / 繁体 JhengHei / 畸形字体）。修法：`SpbFonts.sansFor` **只给 Windows** 返回 `Microsoft YaHei UI` + `['Microsoft YaHei','Segoe UI','sans-serif']`，其余平台**有意留 null**（它们的 CoreText/fontconfig/Android 按 locale 匹配已正确，钉死 `PingFang SC` 会让日语用户被迫用简体字形）。⚠️ 踩过的坑：**给全部平台配 fallback 链会让 4 张 golden 全红**——不是渲染退化，而是 `flutter test` 里平台恒为 android 且**没有 CJK 字体**，中文从「Roboto 缺字的细线空心 tofu」变成「链耗尽落到 Ahem 的粗实心方块」，两份都是 tofu 只是画法不同。故非 Windows 配 fallback 是零收益且制造基线噪音，`fonts_test.dart` 有专门一条钉住。顺带统一 4 处 `fontFamily: 'monospace'` 的 CJK 兜底（`SpbFonts.monoFallback`，其中 3 处原本**没有** fallback，而工具入参经常含中文）。⚠️ **无法在 `flutter test` 里验证字形**（永远是 tofu），只能做结构性断言；真实字形需 Windows 手测（本机无，见 §8/§9） | §6.38 |
| ~~各端用的是 Flutter 模板默认图标（蓝白「F」）~~ | ✅ 已换成 super_partyb 的品牌 logo（成蹊）：41 个文件由 `tools/gen_brand_assets.py` 从真源 SVG 生成，含 macOS 圆角栅格 / iOS 无 alpha / Android 自适应（背景+透明前景区）/ Windows ico / 桌面托盘+窗口 / 应用内 `SpbLogo`；登录页首屏从 `Icons.shield_outlined` 换成品牌标志；Android/iOS 启动画面也换成「品牌蓝 + 居中标志」 | §6.32 |
| ~~Windows 客户端无法打开浏览器（弹「无法打开浏览器，请手动访问…」，而浏览器其实已经打开）~~ | ✅ 已修（§6.35）：两个独立的 Windows 缺陷。① **URL 与路径必须用不同命令**——原先一律 `explorer`，而 `explorer <带 query 的 URL>` 打开的是**文件浏览器**（microsoft/WSL#3832），而 OIDC 授权 URL 必然带 8 个 query 参数，故每次 SSO 登录都会「成功」地打开一个空窗口、客户端继续等 loopback 回调。现 URL → `rundll32 url.dll,FileProtocolHandler`，路径 → `explorer`；`looksLikeUrl` 只认 `scheme://`（**不能**用 `Uri.parse().scheme`——它把 `C:\Users\me` 解成 `scheme=c`，会让每个 Windows 路径都走 URL 分支）。② **`explorer` 成功也返回 1**（microsoft/WSL#6565），原先按「非 0 即失败」判定 → 每次成功打开都被判失败。现 Windows 成功集合为 `{0,1}`，其余平台仍 `{0}`；`rundll32` 分支的退出码恒为 0，故用 `exitCodeIsMeaningful = false` **显式跳过**判定（代价：URL 打不开时靠上层 5 分钟超时兜底，不再有即时错误）。共 8 条新用例 + 5 项反向验证逐条实测。⚠️ 修复前测试有**两个假绿**：假 runner 一律返回 `exitCode = 0`；`windows 用 explorer` 那条用例传的是**路径**，于是「URL 也走 explorer」这条错误行为恰好被它「验证」为正确 | §6.35 |
| ~~登录成功后**立刻**提示「会话已失效」并被踢回登录页（Windows 用户报障）~~ | ✅ 已修（§6.37）：客户端把 IdP 的 `access_token` 当 Bearer 发给网关，而那是 **fosite 不透明串**（`ory_at_…`，无点号）。网关的 `jwt_authenticate.go`（JWKS+RS256）与 `oidc_auth.go`（go-oidc compact JWS）**都要求三段式**，分别报「token contains an invalid number of segments」/「compact JWS format must have three parts」→ 登录刚完成就 401 → `onSessionExpired` 踢人。修法：`OidcTokens.bearerToken`（`idToken ?? accessToken`）+ `StoredTokens.fromOidcTokens` 单点转换，四端（两端登录 + 两端刷新）全部改用它。**与 `app2.example.com` 无关**（登录走编译期 issuer，端点升级只改 API/UFS host）。⚠️ 修复前测试全绿：既有用例只断言 `OidcTokens` 原始字段或动作调用次数，而移动端 `onCode` **零覆盖**（内联在 provider 闭包里，只能从 `main.dart` 触达）——故另加了两个注入点（`loopbackSignInProvider` / `oidcCallbackHandlerProvider`）让落盘逻辑可测 | §6.37 |
| ~~登录成功后客户端仍停在登录页（重启就好）~~ | ✅ 已修（§6.36）：`AuthStateNotifier.signIn()` 收尾**无条件**写 `state = unknown`，那是给旧实现（`openGatewaySignIn` 只发起、等浏览器 Cookie 回调）留的分支。而 `2d453cf` 换成 RFC 8252 loopback 后 `signInAction` 是**同步等到 token** 的——它在内部落盘并调 `signedIn()`，返回时状态已是 `authenticated`，随后被这条无条件赋值盖回 `unknown`。守卫对 `unknown` 明确放行（§6.34 的启动期语义），于是**永远停在 `/login`**，而凭证其实已在安全存储里（重启走 `restore()` 就正常，这也是「为什么重启就好」）。现判据改为「**别把已登录改回未判定**」（`if (!state.isAuthenticated)`），两端一并修（移动端回调接收器可能在 `signIn()` 返回前就完成）。两端各补 1 条从按钮出发的端到端用例；⚠️ 修复前测试有**两个假绿**——一条只断言「动作被调用 1 次」不看状态，另一条绕过 `signIn()` 直接调 `signedIn()` | §6.36 |
| ~~放置一段时间后被登出、关闭重开又正常~~ | ✅ 已修（§6.39）：`SessionManager` 曾把**所有**刷新失败折叠成 `null`（断网、超时、IdP 503、`invalid_grant` 全长得一样），而 `currentAccessToken()` 返回 null 会让拦截器发出**匿名**请求——那必然 401，而那个 401 又被当成「会话失效」把人登出。凭证其实完好，所以重开应用（新进程网络栈干净）就正常。修法：新增三态 `TokenRefreshStatus`（`refreshed` / `rejected` / `transient`），判据是「这个失败是否携带关于凭证有效性的信息」——网络层错误从不携带。① `currentAccessToken` 在 transient 时返回**旧 token**（交给服务端判定，而不是替它提前判「已失效」）；② 拦截器拿到 transient 时**不调** `onSessionExpired`、不重放，只把 401 归一化为 `AuthError` 让页面提示网络异常。⚠️ **最易写错的一处**：`OidcClient._tokenRequest` 对任何非 2xx 都抛 `AuthError(cause: HttpError(status))`，只按最外层类型判会把「IdP 回了 503」也当成「凭证作废」——必须下探 `cause`。旧布尔回调 `onUnauthorized` 保留（新回调优先，`false` 一律当 rejected），`refresh()` 保留为 `refreshWithOutcome()` 的薄包装以兼容 6 处既有调用点。新增 21 条用例，5 项反向验证逐条实测 | §6.39 |
| ~~「在文件管理器中定位」全平台失效（Windows 用户报「总是定位不到已下载的文档」）~~ | ✅ 已修（§6.41）：**三个独立缺陷叠加**，且都不报错。① `revealPath` 文档写的是「打开本地**目录**」，实现按此用 `Directory(path).exists()` 校验——而**两个真实调用点传的都是文件路径**，实测 `Directory('/tmp/a.txt').exists() == false` 恒成立，于是在 spawn **之前**就返回了（与平台无关，Linux/macOS 同样失效）。② 即使放行，Windows 上 spawn 的是 `explorer <path>` = **用默认程序打开**，不是选中；正确命令是 `explorer /select,<path>`（且必须是**一个**参数，拆成 `['/select,', path]` 会被 explorer 当成要打开的路径）。macOS 对应 `open -R`，Linux 退化为 `xdg-open <父目录>`（无选中概念）。③ **下载平铺**：两条手动链路都写到 `downloads/{agent,deliverables}/<文件名>`，不同 group 的同名文件互相覆盖、目录结构被压平、磁盘上分不清归属。修法：`spb_platform` 新增 `spawnSystemReveal` + `revealSystemEntry`（按 `FileSystemEntityType` 分流，可注入 probe 以便无头测试）；`spb_domain` 新增纯函数 `deliverableDownloadRelPath` / `agentFileDownloadRelPath`（`{groupId}/<相对路径>`，逐段过 `isValidPathSegment`，非法时退化为单文件名而非报错），**四条下载链路（桌面 2 + 移动 2）共用同一口径**。共 36 条用例（领域 16 + 平台 19 + 装配 1），5 项反向验证逐条实测 | §6.41 |
| ~~交付物同步只能手动点（用户问「PC 端能不能自动下载 / 同步」）~~ | ✅ 已实现（§6.42）：新增 `AutoSyncConfig`（`onLaunch` + `intervalMinutes`，档位 关闭/15/30/60/180）与 `AutoSyncScheduler`（**纯 Dart + `fake_async` 可测**，放 `spb_domain`）。两条入口**相互独立**（「只在启动时同步一次」是合法组合）。**默认全关**——生产实测首次全量 5666 条 / 4.7 GB，静默替用户拉这么多不可接受。排程用**自续排的一次性 `Timer`** 而非 `periodic`：`periodic` 会在上一轮未跑完时叠加触发，而游标并发推进不安全；代价是长轮次期间 `isScheduled == false`（正确状态）。三条易写错的判据：① `pause()` 必须清空已应用配置，否则重新登录后 `apply(同一配置)` 被幂等吞掉 → 自动同步永久失效；② `apply` 以配置相等做幂等键，否则三个信号源反复喂同一份配置会把周期无限重置；③ `_tick` 必须 `_cancelTimer()` 而不是 `_timer = null`（`apply` 是「先排周期再跑启动轮」，启动轮进 `_tick` 时计时器是活的 → 僵尸 Timer → 一轮变两轮，被用例抓到过）。`runSyncActionProvider` 加**单飞**（语义选「复用同一 Future」而非「静默跳过」，否则手动触发点了没反应）。移动端**不装配排程器**（后台定时器在 Android/iOS 不可靠）→ `showAutoSync: false` 整段不渲染（不渲染禁用态），但**仍读写 `sync.auto`**——同一份 `SyncSettings` 两端流转，不写回会静默清掉桌面端配置。共 48 条用例（领域 39 + 设置页 8 + 装配 7 + 移动端持久化 4 …），**14 项反向验证逐条实测** | §6.42 |
| ~~定时自动同步解决不了「用户此刻正看着这个对话」~~ | ✅ 已实现（§6.43）：新增第三条入口「进入对话时按需同步」（`AutoSyncConfig.onGroupOpen`，**默认关**）。判定只需**一次** `page_size=1` 查询，且命中的是**本 group 已同步水位**（`groupSyncWatermark` = 该 group 文件记录里最晚的 `updated_at`），**不是** `__workspace__` 游标——定向同步不推进游标，拿它比会永远判 stale（每进一次对话提示一遍却什么也不做）。**判定命中只提示、不静默下载**。点击「立即同步」跑 `SyncSingleGroupScope`：列举前缀收窄到 `{gid}` 子树、本地保留 `{gid}/` 布局、状态键共用 `workspaceStateKey`（先定向再全范围时靠 etag 命中不重下），**但不推进共享游标**（否则会越过其它 group 未同步的文件 → `updated_since` 永久过滤 → 漏下载而报告成功）。`advancesCursor` 是 `SyncScope` 的 getter 而非 `run()` 参数——做成参数就允许「窄列举 + 推游标」这个致命组合。三重门控（`onGroupOpen` / `canSync` / 冷却闸）+ `GroupSyncThrottle`（默认 10 分钟，内存态）：被过滤的文件不 `markSynced` → 判定长期命中。计数上限 500（命中后才分页统计、按同一水位过滤、超过显示「500+」）。提示条包在 `ConversationPage` **外面**（`withHint` 闭包）——避免给 46 参数的页面再加一条要写进 `check_wiring_parity.sh` 豁免的参数。共 58 条用例（领域 32 + 装配 10 + 提示条 16），**26 项反向验证逐条实测**（其中「路由层不检查冷却」与「点提示条跑的是定向还是全范围」最初都是**假绿**：前者只查了节流器状态、后者只看「同步跑了一次」而两者都返回 `SyncReport`） | §6.43 |
| ~~进入从未同步过的 group 时提示条不出现 / 同步不下来（用户报障）~~ | ✅ 已修（§6.43 的六个叠加缺陷）：① **`sinceDays` 未参与探测**——同步侧用 `effectiveCursor(水位, sinceDays)` 作时间下限，探测侧只看水位 → 设了「只拉最近 30 天」时探测按全量数得 stale、同步列出 0 条 → 每次进对话永久重复提示。现 `lower = effectiveCursor(...)` 同时用于 `updatedSince` / `includeDeleted` / 计数 / 页大小分档。② **`page_size=1` 撞上非交付物**——有水位时只拉一条，若那一条恰是目录或机器产物则过滤成 `unknown`，提示条不出现（目录 `updated_at` 只在创建时设置，故「水位之后新建的目录」正好排最前，且秒级同秒排序不确定 → 真实 flakiness）。现仅当「页大小本来就是 1」且「本页无交付物」且 `hasMore` 时用 `pageSize: 100` 重探一次。③ **探测侧不排除机器产物**——`reports/tts/**`（生产实测 **312 个**）、`.archive/**`、`_attachments/**` 都是「跳过且不 `markSynced`」，算进最晚时间会让该 group 永久 stale。`_isDeliverableEntry` 现按 `groupScopedRelativePath` 判。④ **TTS 排除在下载侧漏网**——`ttsRelPrefix` 锚定开头（三端契约），而 `SyncSingleGroupScope` / `SyncWorkspaceScope` 的 relPath 是 `{gid}/reports/tts/a.mp3` → `startsWith` 为 false → 语音被拖到本地。现 `shouldSync` 内先经新增的 `groupScopedRelativePath(file.path)` 剥掉 `{gid}` 段再判（**不改签名**；否决 `SyncScope.groupRelativePathOf` 方案——过滤判据不该依赖调用方用的是哪种范围）。⑤ **`.archive` / `_attachments` 未排除**——`archivesnapshot` worker 直写 UFS、绕过 groupsync 的 globs；UFS 的 `exclude_prefix` 只能按前缀，故必须客户端按「任意层级段」过滤（`machineGeneratedSegments`，按段相等不误伤 `.archivex`）。⑥ **切对话时在途的解析/聚焦丢掉新一轮**——`if (_resolvingUser) return;` 让「聚焦没跑完就切走」的新 groupId 既不被聚焦也不被探测，无重试点。现 `do/while + _resolveAgain`（最多多一轮，两端同构），并把 `_focus` 从探测的 `try` 里拆出（一次聚焦异常不该取消一个无关的探测）。另：门控/判定/探测失败日志从 `debug` 升 **`info`**（`SpbLog._minLevel` 默认 info，debug 生产被过滤 → 「开了功能但没反应」完全不可见）；「立即同步」成功后 `invalidate(deliverableLocalIndexProvider)`（否则提示条消失了但侧边栏仍显示未同步，用户找不到刚同步下来的文件）。共 10 条新用例（领域 3 + 探测 5 + 接线 2），**8 项反向验证逐条实测**。⚠️ 排障中另修掉一个**测试污染真库**的缺陷：`group_sync_probe_test` 的容器原先不 override `appDatabaseProvider`，`preferencesStoreProvider` 会打开真实的 `~/.local/share/super_partyb/sync.db` 并永久写入 `sync.since_days=1`，导致后续用例连锁失败 | §6.43 |

| ~~会话失效后**不会**回登录页（用户卡在当前页面，只能手动进设置页点「退出登录」）~~ | ✅ 已修（§6.34）：根因是链路的**中段**断了——`AuthInterceptor` 只把 401 归一化成 `AuthError` 抛给调用方（注释写着「由上层统一监听并跳登录页」），而那个「上层监听」**根本不存在**（`markUnauthenticated` 生产路径零调用）；各页面拿到 `AuthError` 只翻成一句 SnackBar 文案。新增 `AuthInterceptor.onSessionExpired`，装配层在**两端各 2 处**（`dioProvider` + `ufsDioProvider`，共 4 处）接到 `markUnauthenticated`，由路由守卫做唯一一次重定向到 `/login?from=…`。**403 绝不触发**（无权限不是会话失效）、**只在刷新也失败后触发**、重放路径带 `_retriedKey` 守卫防通知两次、**不清凭证**（保住 refresh_token）。共 9 条用例（拦截器 5 + 两端各 2），3 项反向验证逐条实测 | §6.34 |
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
| ~~**对话内容一滚动就丢失，再滚又出现**（用户报障）~~ | ✅ 已修：`RowLocateRegistry.keyFor` 把批量卡的**每个成员**都写成同一个 `GlobalKey` 实例。一旦同一段文件被拆成多行（缓冲区裁剪切进批中间 / 翻页拼接使批先落单后合并），多行就撞同一个 `GlobalKey` → Flutter 抛 `Multiple widgets used the same GlobalKey` → **后出现的那几行渲染为空白**（release 下那条校验不跑，用户只看到空白）。修法：`_owned`（行主键 → 键，一行一个）与 `_aliases`（成员 id → 行主键名，仅查询用）分开，只有 `ids.first` 能成为键的所有者。⚠️ **纯逻辑测试抓不到它**（它自己构造拆分状态），另加页面级用例 `conversation_page_row_keys_test.dart`：真实控制器 + 真实 `_trimBuffer`，且**必须分两阶段推事件、中间真正 pump 一次**——否则页面首次构建看到的已是 4 个落单行，用例会在修复前的代码上变绿 | §6.18 |
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
