# super_partyb-flutter

Super PartyB 的 **Flutter 多端客户端**：桌面端（Linux / Windows / macOS）+ 移动端（Android / iOS）。

取代原 [`super_partyb`](../super_partyb) 仓库的 `apps/desktop`（Tauri 薄壳），并新增独立移动 App。

> **完整开发指引见 [AGENTS.md](AGENTS.md)**（架构、分层规则、Go API 契约、构建限制、环境要求）。

---

## 下载现成的安装包

| 平台 | 获取方式 |
|---|---|
| **Windows** x64 | [Releases](../../releases) → `spb_desktop-windows-x64.zip`，解压后双击 `spb_desktop.exe`。已内置 VC++ 运行库，无需额外安装 |
| **Linux** x64 | [Releases](../../releases) → `spb_desktop-linux-x64.tar.gz` |
| **Android** | [Releases](../../releases) → `app-release.apk` |
| **macOS / iOS** | 暂不出包（需 macOS runner，CI 按 10× 计费） |

未打 tag 时，Actions 页的 artifact 也可下载（需登录 GitHub，存 30 天）。

> Windows 包未做代码签名，首次运行会被 SmartScreen 拦下——
> 选「更多信息 → 仍要运行」。详见 **[docs/windows-release.md](docs/windows-release.md)**。

---

## 快速开始

```bash
# 依赖
flutter pub get

# 分析 + 分层检查
dart analyze .
bash tools/check_layering.sh

# 测试
cd apps/spb_desktop && flutter test
cd apps/spb_mobile  && flutter test

# 构建
cd apps/spb_desktop && flutter build linux --release
cd apps/spb_mobile  && flutter build apk --release
```

## 发布构建（注入环境地址）

客户端**不含**任何硬编码的服务地址：生产 / 测试 / 本地各出各的包，
地址在**编译期**经 `--dart-define` 注入（逐项说明见
`packages/spb_core/lib/src/env.dart`）。

```bash
flutter build linux --release \
  --dart-define=SPB_API_BASE_URL=https://api.example.com/pba \
  --dart-define=SPB_UFS_BASE_URL=https://api.example.com/ufs \
  --dart-define=SPB_WEBAPP_BASE_URL=https://example.com/pbw \
  --dart-define=SPB_OIDC_ISSUER=https://example.com/idp \
  --dart-define=SPB_OIDC_CLIENT_ID=client_xxxxxxxx \
  --dart-define=SPB_ENV=prod

# Linux 分发前必须打包依赖库（否则 RUNPATH 会指向构建机路径）
bash tools/bundle_linux_deps.sh
```

CI 里这些值来自**仓库 Variables**（Settings → Secrets and variables → Actions →
Variables），打 tag 即自动出包并挂到 Release。完整说明见
**[docs/windows-release.md](docs/windows-release.md)**。

## 结构

```
apps/spb_desktop   桌面端入口
apps/spb_mobile    移动端入口
packages/
  spb_core         基础设施（纯 Dart）
  spb_models       数据契约（纯 Dart）
  spb_api          HTTP + SSE（纯 Dart）
  spb_domain       领域逻辑（纯 Dart）
  spb_data         本地持久化（drift）
  spb_design       设计令牌
  spb_ui           通用组件
  spb_platform     平台能力抽象
  spb_features     功能模块
```

## 设计原则

1. **Go API 一行不改** —— 客户端适配服务端
2. **纯 Dart 包禁止依赖 Flutter** —— 由 `tools/check_layering.sh` 强制
3. **实时流统一 SSE** —— 禁止引入 WebSocket
4. **客户端不解析 JWT、不申请 API Key** —— 认证由网关 OIDC 完成
5. **不在客户端硬编码服务地址** —— 一律走 `--dart-define`，构建期注入
