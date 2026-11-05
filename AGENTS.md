# AGENTS.md

本文件指导 Claude Code / pi 等 AI Agent 在 **super_partyb-flutter** 仓库中工作。

> **本文件每次请求都会被全文注入上下文**（它不是 wiki，是提示词）。所以这里只放
> 「现在就要遵守的判据 + 去哪找细节」：决策复盘在 `docs/design-decisions/`，
> 已知问题在 `docs/known-issues.md`，契约在 `docs/api-contract.md`。
> 体积由 `tools/check_agents_size.sh` 守着——**别把它写回成变更日志**。

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
bash tools/check_agents_refs.sh       # AGENTS.md 与 docs/ 的标识符引用真实存在、tools/ 脚本都被列出（见 issue #37/#47）
bash tools/check_silent_catches.sh    # 静默吞异常的 catch 必须有说明或日志（见 issue #45）
bash tools/check_agents_numbers.sh    # AGENTS.md 与 docs/ 标注了复现命令的数字不得漂移（见 issue #46）
bash tools/check_agents_size.sh       # AGENTS.md 体积上限（它每次请求都被全文注入）
bash tools/check_codegen.sh           # 提交进 git 的 .g.dart 与源文件一致（见 issue #43）
bash tools/check_format.sh            # dart format 门禁

# 守卫自测（每个都钉住对应守卫的假绿/假红风险；改守卫时必跑）
bash tools/check_wiring_parity_selftest.sh
bash tools/check_workflow_steps_selftest.sh
bash tools/check_codegen_selftest.sh
bash tools/check_agents_refs_selftest.sh
bash tools/check_agents_numbers_selftest.sh
bash tools/check_agents_size_selftest.sh
bash tools/check_silent_catches_selftest.sh

# 测试
cd apps/spb_desktop && flutter test   # 桌面端
cd apps/spb_mobile  && flutter test   # 移动端
dart test                             # 纯 Dart 包（spb_core/models/api/domain）
# ⚠️ `spb_data` 虽然也是纯 Dart 语义，但依赖链含 Flutter（secure storage）→
# 必须 `cd packages/spb_data && flutter test`，`dart test` 会报 dart:ui 不可用。

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
    ├── check_agents_refs.sh        # AGENTS.md 与 docs/ 的标识符引用检查
    ├── check_agents_numbers.sh     # 文档数字漂移检查（容差 5%）
    ├── check_agents_size.sh        # AGENTS.md 体积上限（防它退回成变更日志）
    ├── check_silent_catches.sh     # 静默吞异常检查（空 catch 必须留痕）
    ├── check_build_defines.sh      # 发布构建必须传 --dart-define（见 §6.33）
    ├── check_format.sh             # dart format 门禁
    ├── check_test_support_sync.sh  # 跨包重复的测试辅助文件必须逐字节相同
    # 工具
    ├── coverage.sh                 # 逐包覆盖率采集 + 汇总表（剔除生成代码）
    ├── bundle_linux_deps.sh        # Linux 分发包依赖打包（非系统库 + RUNPATH）
    ├── gen_brand_assets.py         # 从品牌 SVG 生成各端图标（含安装包图标，见 §6.32）
    ├── build_windows_installer.ps1 # 把 Windows Release 产物打成 Inno Setup 安装包（见 §6.61）
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

**全文见 [`docs/api-contract.md`](docs/api-contract.md)**（认证模型 / 路由前缀 /
响应格式 / SSE 事件契约 / 无归属入口 / 落点存储 / 分页 / 超时兜底）。
改任何契约前先确认服务端真源 `super_partyb/apps/go-api`。

> ⚠️ 代码注释里的 `AGENTS.md §5.1.1` / `§5.5` / `§5.7` 指**本节的细分小节**，
> 它们住在 `docs/api-contract.md` 的同名小节里（本文 §5 只留下面三条铁律）。

三条最容易踩的（细节在该文件里）：

1. **客户端不解析 JWT、不申请 API Key**。凭证交给 `api-gateway`，它注入
   `X-User-ID`，Go API 跑 `AUTH_MODE=header`。
2. **路由前缀有四套**（`/api/*`、`/chat/*`、`/users/:user_id/chat/*`、`/me/*`），
   **不是**统一的 `/api/chat`——拼 URL 时逐个核对 api-contract.md §5.2。
3. **字段命名不统一是既有事实**：REST 用 snake_case、SSE 事件用 camelCase。
   各自照抄服务端，映射只在 `spb_models` 里做，不要「统一」。

## 6. 关键设计决策

**每条决策的完整复盘在 [`docs/design-decisions/`](docs/design-decisions/README.md)**
——按主题分 10 个文件，含「症状 → 根因 → 反直觉点 → 实测证据 → file:line」。
§6.1–§6.63 的逐条索引见该目录的 `README.md`。

**编号永久稳定**：`§6.43` 永远指同一件事，只是换了文件——代码注释、`docs/`、
`docs/` 里的 `§6.x` 引用都不会失效——按上表找到主题文件、再按编号定位小节即可
（无需逐个改写成文件路径）。

> ⚠️ **新增决策写进 `docs/design-decisions/<主题>.md`，本文件只在下表加一行。**
> `AGENTS.md` 每次请求都被全文注入，它的体积就是上下文预算
> （`tools/check_agents_size.sh` 守着这条）。

### 6.0 仍然约束写代码的硬规则

下面这些不是「历史」，是**现在**就要遵守的判据：

| 编号 | 规则 |
|---|---|
| 6.1 | 实时流统一 SSE，**禁止引入 WebSocket** |
| 6.2 | 契约**手写**（`spb_models` 镜像 Go 常量）；**不得**再挂 freezed / json_serializable / build_runner |
| 6.3 | 状态管理用 `flutter_riverpod` 3.x，不引别的 |
| 6.4 | 桌面能力一律经 `spb_platform` 抽象；移动端注入 `NoopDesktopCapabilities` |
| 6.5 | **不要尝试多窗口**——`window_manager` 做不到，只有「主窗口临时变身」悬浮窗 |
| 6.7 | 无归属入口两端**只有一条路径**：`OverlayQuickCapturePage` → enqueue |
| 6.9 | 「有意不做的管理面端点族」**是决策不是缺口**——不要补（逐项依据见 runtime-and-ops.md） |
| 6.10 | 两端 UI 面板族不对称是**有意保留**的差异，不要「统一」 |
| 6.12 | i18n **当前不做**，文案保持硬编码中文（重开阈值见 runtime-and-ops.md） |
| 6.13 | golden 只给「稳定 + 纯展示 + 改错代价高」的组件加 |
| 6.42 | 交付物同步的既有语义**必须保持**：单向 / 增量游标 / 只凭 `deleted_at` 感知远端删除 / `.part` + rename 原子写 / 路径穿越防御 / 失败项不写状态 / 全 group 与选中共用 `__workspace__` 单状态键（见 sync.md） |

### 6.1 主题索引

| 主题 | 文件 | 覆盖 |
|---|---|---|
| 架构与关键取舍 | [`architecture.md`](docs/design-decisions/architecture.md) | §6.1 §6.2 §6.3 §6.4 §6.5 §6.6 §6.8 §6.10 §6.11 |
| 对话与流式 | [`chat.md`](docs/design-decisions/chat.md) | §6.7 §6.14 §6.15 §6.18 §6.23 §6.28 §6.28.1 §6.48 §6.50 §6.56 §6.58 |
| 交付物同步 | [`sync.md`](docs/design-decisions/sync.md) | §6.42 §6.43 §6.52 §6.53 + 交付物同步的既有语义 |
| 认证与会话 | [`auth.md`](docs/design-decisions/auth.md) | §6.34 §6.36 §6.37 §6.39 |
| 桌面平台集成 | [`platform.md`](docs/design-decisions/platform.md) | §6.35 §6.41 §6.45 §6.55 §6.63 |
| 界面与交互 | [`ui.md`](docs/design-decisions/ui.md) | §6.16 §6.32 §6.38 §6.40 §6.44 §6.46 §6.51 §6.54 §6.62 |
| 测试与仓库守卫 | [`testing.md`](docs/design-decisions/testing.md) | §6.13 §6.17 §6.19 §6.21 §6.22 §6.24 §6.25 §6.26 §6.27 |
| 构建、分发与发布 | [`build-and-release.md`](docs/design-decisions/build-and-release.md) | §6.29 §6.30 §6.31 §6.33 §6.61 §7 §8 |
| 产品边界与可运维性 | [`runtime-and-ops.md`](docs/design-decisions/runtime-and-ops.md) | §6.9 §6.12 §6.20 §6.49 §6.57 |
| 性能与内存 | [`performance.md`](docs/design-decisions/performance.md) | §6.47 §6.59 §6.60 |

## 7. Linux 桌面端系统依赖（**分发必读**）

见 [`docs/design-decisions/build-and-release.md`](docs/design-decisions/build-and-release.md) 的 §7。

要点：`libkeybinder-3.0-dev` / `libayatana-appindicator3-dev` / `libsecret-1-dev`
**不是默认安装项**；发分发包前**必须**跑 `tools/bundle_linux_deps.sh`——非系统库
若装在非标准前缀，构建产物会把那个绝对路径写进 RUNPATH，结果「开发机能跑、
分发即挂」。

## 8. 构建平台限制

| 平台 | 本机（Linux）可构建 | 在哪出包 | 限制 |
|---|---|---|---|
| Linux | ✅ | 本地 / CI | 需 GTK 开发库 + `bundle_linux_deps.sh` |
| Windows | ❌ | GitHub `windows-2022` | `my_app.exe` 是 MSVC 编译的 C++ runner，Linux 无 MSVC |
| macOS | ❌ | GitHub `macos-14`（**仅 tag**，10× 计费） | ad-hoc 签名，未公证，首次打开需绕过 Gatekeeper |
| Android | ✅ | 本地 / CI | 模拟器不可用（`/dev/kvm` 未透传） |
| iOS | ❌ | 未出包 | 需 Apple Developer 账号（$99/年） |

三个 Windows 坑（VC++ 运行库不在产物里 / 锁 `windows-2022` 而非 `latest` /
MSIX 沙箱内崩溃）与 macOS 必须用 `ditto` 打包的要求，见
[`build-and-release.md`](docs/design-decisions/build-and-release.md) 的 §8。

## 9. 开发环境

见 [`docs/development.md`](docs/development.md)。本机是 **Debian 12 LXC 容器**：
无 `/dev/kvm`、无 Windows/macOS 主机、无真机——「无头测试能证明什么、
不能证明什么」在那里写清了。

## 10. 待办与里程碑

见 [`docs/roadmap.md`](docs/roadmap.md)（勾选状态是**事实记录**，不是计划）。
仍未闭合的两项：移动端 OIDC 登录闭环（需 IdP 注册 `partyb://oidc/callback`）、
iOS 出包（需 Apple Developer 账号）。

## 11. 已知问题

**全部条目（含 60 余条已修的根因、修法与反向验证）见
[`docs/known-issues.md`](docs/known-issues.md)。** 下面只留**当前仍未修 /
待决策 / 有意不做**的：

| 问题 | 状态 | 参考 |
|---|---|---|
| Android 模拟器不可用（`/dev/kvm` 未透传） | 待决策 | `super_partyb` issue #30 |
| macOS 包未签名/未公证，首次打开需绕过 Gatekeeper | 已知限制（免签名分发） | [§8](docs/design-decisions/build-and-release.md) |
| iOS 出包需 Apple Developer 账号 | 待决策 | [§8](docs/design-decisions/build-and-release.md)、`super_partyb` issue #31 |
| Windows 包无代码签名，每次运行弹 SmartScreen | 已知限制 | `docs/windows-release.md` §4 |
| 四项检索面板未接（语义 / 图谱 / 文件演化 / 决策演化） | **有意不做**（issue #12）。语义搜索的**嵌入链路是通的**，但数据面为空（`chat_groups` = 0 行）；两个「演化」面板的数据源在 Go 时代已停写——**前置条件是服务端先恢复数据写入** | issue #12、§6.9.6 |
| 离线缓存切片 C 的「反向验证为 0」 | ⚠️ **唯一一条**（诚实记录）：`drain` 进度哨兵——正确代码上不可达，属 **fail-safe**（拦「将来有人改坏 `_nextSendable`」，把挂死变成记 error + 中断）。另两条初版缺口（store `delete`/`clear` 静默降级、`onConnectivityRestored` 不碰 `failed`）**已补测** | `docs/offline-cache-design.md` §7bis.11 |
| ⚠️ bcc `partyb-go-api` 的 `chat_turns` / `chat_groups` / `chat_events` 全为 0（2026-10-11 实测） | **待排查**（属 `super_partyb` 侧，不在本仓库）。2026-09-27 备份有 `chat_turns` 3559 行，而现库是一份缺 `chat_*` 数据的状态；`topics` / `user_memories` / `embeddings` 仍在 | §6.9.6 末尾注 |
| TTS 语音**只展示状态、不播放**（无音频播放插件） | **有意不做**：音频文件由交付物同步拉到本地，`TtsStatus` 只回答「播报到哪一步 / 为什么失败」，不持有可播放句柄。⚠️ 曾被 §11 引用、拆分时漏搬，2026-11 补回 | `packages/spb_domain/lib/src/tts_status.dart` |
| `sqlite3_flutter_libs` 零 Dart import 但**不能删** | **有意保留**：它是原生插件（把 `libsqlite3.so` 打进 Android/iOS 包），drift 移动端运行时需要；已写进 `check_unused_deps.sh` 的显式豁免。实测 apk 含 `lib/{arm64-v8a,armeabi-v7a,x86_64}/libsqlite3.so` | issue #36、§6.4 |
| 两端 `providers.dart` 上百个同名 provider 未上提共享包 | **有意不做（本轮）**：属独立重构，且平台相关装配需留在各 app；当前只把「接线一致性」做了自动守卫（§6.17） | issue #39 |
| 契约同步靠人工 | 可接受 | [§6.2](docs/design-decisions/architecture.md) |

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
| **设计决策全文（§6.x / §7 / §8）** | `docs/design-decisions/`（索引：`README.md`） |
| **已知问题全表（含已修项的根因与判据）** | `docs/known-issues.md` |
| **Go API 契约（§5）** | `docs/api-contract.md` |
| 开发环境与无头验证边界（§9） | `docs/development.md` |
| 待办与里程碑（§10） | `docs/roadmap.md` |
| Windows 下载与出包 | `docs/windows-release.md` |
| 交付物回传（本地改动 → agent） | `docs/deliverable-upload-and-conflict.md` |
| 对话数据本地缓存（issue #26 设计） | `docs/offline-cache-design.md` |
| 内存审计对账单 | `docs/memory-audit.md` |
| 手工验证清单（含 §2.7 可访问性） | `docs/m0-manual-verification.md` |
| Go API 契约与业务逻辑 | `super_partyb/AGENTS.md` |
| Tauri 桌面端（迁移来源） | `super_partyb/apps/desktop/README.md` |
| 微信小程序（BFF 可复用） | `super_partyb/apps/miniapp/README.md` |
| SSE 服务端实现 | `super_partyb/apps/go-api/internal/server/chat_stream.go` |
| 事件类型真源 | `super_partyb/apps/go-api/internal/chatbus/broker.go` |
| Flutter 官方 Windows 构建 | https://docs.flutter.dev/platform-integration/windows/building |
| Flutter 官方 Windows 分发 | https://docs.flutter.dev/deployment/windows |
