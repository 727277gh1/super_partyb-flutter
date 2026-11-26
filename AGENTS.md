# AGENTS.md

本文件指导 Claude Code / pi 等 AI Agent 在 **super_partyb-flutter** 仓库中工作。

**仅在用户明确要求修改本文件时才能编辑。** 实现功能、修复 bug、补文档或新增判据，
以及 Agent 自行生成的计划、验收项，都不构成修改授权；这些任务按下文指针维护普通文档。

> 本文件只维护当前协作边界、必要命令和文档入口。体积由 `tools/check_agents_size.sh` 限制在 20 KiB 内，连同上级与子目录规则不超过 32 KiB。

> 姊妹仓库 `super_partyb`（Go API + Next.js webapp + Taro 小程序，**未公开**）：**本仓库只做
> 客户端**，业务真源永远是 `super_partyb/apps/go-api`。下文出现的 `super_partyb/...`、
> `api-gateway/...` 等路径**不在本仓库内**，仅作契约依据；本仓库可独立构建与测试。

---

## 1. 这是什么

用 **Flutter** 实现 Super PartyB 的**桌面端 + 移动端**（取代原 Tauri 薄壳，新增 iOS/Android App）。
这是**「加一个端」**不是换栈：webapp（Next.js）与小程序（Taro）全部保留，功能最全的仍是 webapp。

**关键约束：Go API 一行不改。** 客户端适配服务端，不是反过来；「为客户端方便改 Go API」
的提案必须先证明无法在客户端解决。平台与出包能力 → §8。

---

## 2. 常用命令

从 workspace 根执行；依赖使用根 `pubspec.lock`，升级按 [开发指南](docs/development.md) 核对 Flutter 版本与锁定依赖。

```bash
flutter pub get
dart analyze .
dart format .
(cd apps/spb_desktop && flutter test)
(cd apps/spb_mobile && flutter test)
(cd packages/spb_data && flutter test)
(set -e; for f in tools/check_*.sh; do bash "$f"; done)
```

纯 Dart 包在各自目录运行 `dart test`。构建、覆盖率、golden 和 drift 生成流程见开发指南；修改守卫脚本时运行对应 selftest，更新 golden 前检查 diff。

## 3. 仓库结构

`apps/spb_desktop`（linux/windows/macos）与 `apps/spb_mobile`（android/ios）**只做装配**
（DI / 路由 / 入口）；`packages/` 九个包：`spb_core` `spb_models` `spb_api` `spb_domain`
`spb_data` `spb_design` `spb_ui` `spb_platform` `spb_features`（职责见 §4 的表与「依赖方向」）。

`tools/` 的守卫与工具清单见 [`tools/README.md`](tools/README.md)。新增脚本只维护该清单。

### 依赖方向（**单向，不可逆**）

实际依赖 = 各包 `pubspec.yaml` 的 `dependencies`（新增边之前先想清楚层）：

```
apps/*        → 只做装配（DI/路由/入口），可依赖任意 packages/*
spb_features  → spb_data · spb_ui · spb_platform · spb_domain · spb_api · spb_models · spb_core · spb_design
spb_data      → spb_domain · spb_api · spb_models · spb_core
spb_domain    → spb_api · spb_models · spb_core
spb_api       → spb_models · spb_core
spb_platform  → spb_domain · spb_core
spb_ui        → spb_design
spb_design / spb_models / spb_core → 无包内依赖
```

**禁止**：反向边（`spb_domain` → `spb_data`/`spb_ui`/`spb_features`）、`spb_api` → `spb_domain`
（成环）、任何 `packages/*` → `apps/*`。前两条由 `tools/check_layering.sh` 守，第三条靠 code review。

---

## 4. 分层规则（**编译器强制**）

`spb_core` / `spb_models` / `spb_api` / `spb_domain` **禁止 import `package:flutter/*`**——
它们的正确性核心逻辑（归约 / SSE 解析 / 契约）必须能在无 Flutter 引擎的 CI 里跑纯单测。
强制手段：pubspec 不声明 flutter + `tools/check_layering.sh` + CI 独立 job。

**平台差异一律走 `spb_platform` 接口**，不要在纯 Dart 包里写 `Platform.isAndroid` 分支；
`spb_core/env.dart` 的 `SpbEnv.isDesktop` 是唯一例外（`dart:io`，不依赖 Flutter）。

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

完整复盘在 [`docs/design-decisions/`](docs/design-decisions/README.md)（§6.x 逐条索引见该目录 `README.md`）。
**编号永久稳定**：`§6.43` 永远指同一件事，只是换了文件——代码、`tools/`、`docs/` 里大量 `§6.x`
引用因此不失效：按该索引找到主题文件、再按编号定位小节即可。

新增决策写进 `docs/design-decisions/<主题>.md`，主题与小节索引只维护该目录的 `README.md`；
进展与状态写 `docs/roadmap.md` 与 issue 跟踪器。

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
| 6.12 | i18n **当前不做**，文案保持硬编码中文（重开阈值见设计决策索引） |
| 6.13 | golden 只给「稳定 + 纯展示 + 改错代价高」的组件加 |
| 6.42 | 交付物同步的既有语义**必须保持**：单向 / 增量游标 / 只凭 `deleted_at` 感知远端删除 / `.part` + rename 原子写 / 路径穿越防御 / 失败项不写状态 / 全 group 与选中共用 `__workspace__` 单状态键（见 sync.md） |
| 6.66 | 选 Agent 是**纯本地**的（对齐 webapp）：点选不发请求、不弹确认，`agent_id` 随下一条消息发出；`/sessions/switch` 只给「同 Agent 开新会话」（见 chat.md） |
| 6.70 | 无归属输入页：系统返回键**有草稿必须确认**（`PopScope(canPop:false)` + 走宿主的 `onClose`）；键位说明只在 `showKeyboardHints` 时显示（桌面端传 true）（见 ui.md） |
| 6.104 | App 内相机扫码：相机是 `spb_platform` 的 `QrScanner` 契约（插件实现只在 `apps/spb_mobile`），解释/文案只有一份（`scanQrLoginCode`）；**两个入口**（登录页=未登录、设置页=已登录），**桌面端不渲染**；扫码只登成浏览器侧 IdP 会话，桌面端靠 loopback 免密（见 auth.md） |

## 7. Linux 桌面端系统依赖（**分发必读**）

`libkeybinder-3.0-dev` / `libayatana-appindicator3-dev` / `libsecret-1-dev` **不是默认安装项**；
发分发包前**必须**跑 `tools/bundle_linux_deps.sh`（否则非系统库的绝对路径进 RUNPATH，
「开发机能跑、分发即挂」）。清单见 [`build-and-release.md`](docs/design-decisions/build-and-release.md) §7。

## 8. 构建平台限制

正式产物只由 GitHub Actions 构建发布；本地构建用于调试验证。平台与签名限制见 [构建与发布](docs/design-decisions/build-and-release.md)，本机能力见 [开发环境](docs/development.md)。

## 9. 开发环境

工具链、模拟器与无头验证边界维护在开发指南；GUI 行为须用有桌面环境或真机验证，不能以进程存活替代交互验证。

## 10. 待办与里程碑

任务进展与待验证项维护在 [roadmap](docs/roadmap.md) 和对应 issue。

## 11. 问题与功能边界

未修问题维护在 issue 跟踪器；长期有效的决策维护在 `docs/design-decisions/` 对应主题，局部实现原因写源码注释。不把已修问题清单或任务验收记录追加到本文件。

下面只留**有意不做**的（环境限制见 §8）：

| 不做什么 | 依据 |
|---|---|
| TTS 只展示状态、**不播放**（无音频播放插件） | 音频由交付物同步拉到本地（`packages/spb_domain/lib/src/tts_status.dart`） |
| **不删** `sqlite3_flutter_libs`（零 Dart import） | 原生插件，drift 移动端运行时需要；已在 `tools/check_unused_deps.sh` 豁免 |
| **不接**四项检索面板（语义 / 图谱 / 两个「演化」） | 数据面为空 / 数据源在 Go 时代已停写，前置是服务端先恢复写入（§6.9.6） |
| **不上提**两端 `providers.dart` 的百个同名 provider | 独立重构；装配留各 app，一致性由 §6.17 守卫 |
| **不扩大**通知事件范围：除确认卡（及其撤销）外一律不发（回复完成 / 轮次失败 / 同步失败 / 后台任务），托盘 `unreadCount` 恒 0 | 混渠道会把用户训练成忽略所有通知；移动端后台无推送、前台只处理确认卡。判据与重评估触发见 [§6.99](docs/design-decisions/runtime-and-ops.md) |

## 12. 提交约定

Conventional Commits，scope 用包名或平台：

```
feat(api): 实现 SSE 断线续接
fix(domain): 权威帧未替换累积增量
docs: 补充 Windows 构建限制
```

**不要**提交：
- `build/`、`.dart_tool/`、`*.g.dart`（生成物）— 见 `.gitignore`
- `--dart-define` 的生产密钥（走 CI secrets）
- `apps/*/android/key.properties`、`*.jks`、`*.keystore`

提交前遵守文件开头的修改授权规则；根因写 `docs/design-decisions/` 对应 §6.x，
状态写 `docs/roadmap.md` 与 issue。

---

## 13. 相关文档

| 文档 | 位置 |
|---|---|
| 设计决策全文（§6.x / §7 / §8） | `docs/design-decisions/`（索引 `README.md`） |
| 未修项与历史修复讨论 | issue 跟踪器：`<gitea-host>/dever/super_partyb-flutter/issues`（`type/` + `priority/` + `area/` 标签） |
| Go API 契约（§5）与事件类型真源 | `docs/api-contract.md`（真源：`super_partyb/apps/go-api/internal/chatbus/broker.go`） |
| 开发环境与无头验证边界（§9） | `docs/development.md` |
| 待办与里程碑（§10） | `docs/roadmap.md` |
| 其余（Windows 出包 / 交付物回传 / 离线缓存设计 / 内存审计 / 手工验证清单 / OIDC 与双栈） | `docs/`（`ls docs/`） |
