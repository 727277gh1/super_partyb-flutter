# super_partyb-flutter

Super PartyB 的 **Flutter 多端客户端**：桌面端（Linux / Windows / macOS）+ 移动端（Android / iOS）。

取代原 [`super_partyb`](../super_partyb) 仓库的 `apps/desktop`（Tauri 薄壳），并新增独立移动 App。

> **完整开发指引见 [AGENTS.md](AGENTS.md)**（架构、分层规则、Go API 契约、构建限制、环境要求）。

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

```bash
flutter build linux --release \
  --dart-define=SPB_API_BASE_URL=https://api.example.com/pba \
  --dart-define=SPB_UFS_BASE_URL=https://api.example.com/ufs \
  --dart-define=SPB_ENV=prod

# Linux 分发前必须打包依赖库
bash tools/bundle_linux_deps.sh
```

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
