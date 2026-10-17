# super_partyb-flutter

本仓库是 Super PartyB 的 **Flutter 多端客户端**：桌面端（Linux / Windows / macOS）+ 移动端（Android / iOS），
取代原 Tauri 薄壳桌面端，并新增独立移动 App。

> **完整开发指引见 [AGENTS.md](AGENTS.md)**（架构、分层规则、Go API 契约、构建限制、环境要求）。

---

## 下载现成的安装包

| 平台 | 获取方式 |
|---|---|
| **Windows** x64 | [Releases](../../releases) → `spb_desktop-windows-x64.zip`，解压后双击 `spb_desktop.exe`。已内置 VC++ 运行库，无需额外安装 |
| **Linux** x64 | [Releases](../../releases) → `spb_desktop-linux-x64.tar.gz` |
| **macOS** 12+（通用） | [Releases](../../releases) → `spb_desktop-macos-universal.zip`，解压后把 `spb_desktop.app` 拖进「应用程序」 |
| **Android** | [Releases](../../releases) → `spb_mobile-android.apk` |
| **iOS** | 暂不出包（需 Apple Developer 账号 $99/年 + 签名证书） |

未打 tag 时，Actions 页的 artifact 也可下载（需登录 GitHub，存 30 天）。
> macOS 是 10× 计费，其 job 只在打 tag 时跑，手动触发不产 macOS 包。

> **三个平台均未做代码签名**：Windows 会被 SmartScreen 拦下（选「更多信息 → 仍要运行」）；
macOS 是 ad-hoc 签名、未公证，首次打开需右键 → 打开，或执行
`xattr -dr com.apple.quarantine /Applications/spb_desktop.app`。
详见 **[docs/windows-release.md](docs/windows-release.md)**。

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
  --dart-define=SPB_OIDC_ISSUER=https://example.com/idp \
  --dart-define=SPB_OIDC_CLIENT_ID=client_xxxxxxxx \
  --dart-define=SPB_PREFERRED_HOSTS=api-v6.example.com=api.example.com \
  --dart-define=SPB_ENV=prod

# Linux 分发前必须打包依赖库（否则 RUNPATH 会指向构建机路径）
bash tools/bundle_linux_deps.sh
```

### 双栈端点选择（`SPB_PREFERRED_HOSTS`）

上面那组地址是**编译期默认值**，客户端要求它**一定可达**（通常是双栈 CDN
域名）。若另外有一个**仅 IPv6** 的源站域名，可用 `SPB_PREFERRED_HOSTS` 声明
别名表，客户端会在**启动时探测一次**：可达就把基地址升级过去（绕开 CDN），
不可达则保持编译期默认值。

格式是 `编译期域名=首选域名`，多对用 `;` 或 `,` 分隔（也接受 JSON 对象）：

```
SPB_PREFERRED_HOSTS="api.example.com=api-v6.example.com"
```

- **留空即完全禁用**（不发起任何探测，零开销）——不配就是原来的行为；
- 探测有 1.5s 超时，且与桌面能力初始化/深链监听**并发**，不叠加启动延迟；
- 探测失败/超时/抛异常一律视为「不可达」，**绝不影响启动**；
- 与微信小程序的逐请求 failover 不同：客户端有 socket，直接 TCP 探一次
  并把结论摊销整个会话，不需要断路器（机制说明见 `AGENTS.md` §5.1.1）。

#### 运行中降级 / 升级

升级到源站后，用户换到没有 IPv6 的网络（笔记本离开公司 WiFi、手机切到
蜂窝）时源站域名会变成黑洞。客户端因此有一条**运行中**通路，无需重启：

- **连续 3 次连接层失败** → 立即降级回编译期默认值（双栈 CDN），连接恢复；
- 之后**每 5 分钟**（冷却期）在有请求成功时重探一次源站，可达就自动升回去；
- 只统计连接层失败（超时/拒绝/DNS/TLS），**4xx/5xx 不算**——源站能回错误码
  说明网络是通的；
- 全程不重建 Dio 或 SSE 客户端（只换请求前缀与重连目标），故对话时间线不会
  因此冻结；诊断报告里 `endpoint_probe` 会显示 `downgraded` 并附带失败计数。

CI 里对应仓库 Variables `SPB_PREFERRED_HOSTS`（或手动触发时的
`host_preferred` 输入）。

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

---

## 说明

本仓库是**客户端**：不含服务端实现。它需要一个兼容的 PartyB Go API
（网关 OIDC 认证 + SSE 事件流）才能实际使用；仓库内的 `docs/` 记录了
所依赖的接口契约与实测结论。

文档中的域名、IP、`client_id` 均为占位符（`example.com` / RFC 5737 的
`203.0.113.0/24`），非真实部署值。

## 许可证

[MIT](LICENSE)
