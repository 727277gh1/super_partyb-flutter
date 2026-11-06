# 待办与里程碑

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。M0 / M1+ 的完成情况与仍缺的项。勾选状态是**事实记录**，不是计划。

> 编号（`§6.x` / `§5.x` / `[§7](design-decisions/build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](design-decisions/README.md)。

---

## 10. 待办与里程碑

### M0：骨架验证（**已完成**）

- [x] 工作区搭建（Pub Workspaces + melos）
- [x] 分层骨架（9 packages + 2 apps）
- [x] `dart analyze` 全绿
- [x] Linux release 构建成功（26 MB，自包含）
- [x] 核心代码：错误类型 / 日志 / 契约模型 / SSE 客户端 / 事件归约
- [x] ~~多窗口可行性~~ → `window_manager` **做不到**；改用「主窗口临时变身」（见 [§6.5](design-decisions/architecture.md)）
- [x] 托盘 + 全局快捷键（`bootstrap.dart` 已接 `window_manager`/`tray_manager`/`hotkey_manager`）
- [x] **OIDC 登录打通**（桌面端 RFC 8252 §7.3 loopback 授权码流程，见 `docs/rfc8252-loopback-signin.md`；粘贴导入为降级路径）
- [x] 剪贴板文件读取的原生实现（Linux/Windows/macOS 三平台 `clipboard_files` channel，见 [§6.8](design-decisions/architecture.md)）

### M1+：功能实现（**大部分已完成**）

- [x] OIDC 登录（自实现 PKCE + loopback，非 `flutter_appauth`）
- [x] 对话列表 + SSE 实时流（cursor 续接 / 切 group 复用连接 / 加载更早历史）
- [x] SSE 传输层单测（issue #41，含测出的 UTF-8 分片损坏修复，见 [§6.22](design-decisions/testing.md)）
- [x] 消息发送 + 无归属入口（悬浮窗）
- [x] 失败 turn 重发（`ErrorItem` → 重新投递，见 [§6.14](design-decisions/chat.md)）
- [x] 发送的乐观回显（请求在飞时「发送中」，issue #52，见 [§6.50](design-decisions/chat.md)）
- [x] 对话内搜索（搜已加载时间线，见 [§6.15](design-decisions/chat.md)）+ 窄屏 AppBar 溢出修复（issue #31，见 [§6.16](design-decisions/ui.md)）
- [x] 交付物同步（单向拉取 + 双向回传与冲突物化）
- [x] 自动同步（启动后一次 / 周期 N 分钟，默认关闭；仅桌面端装配，见 [§6.42](design-decisions/sync.md)）
- [x] 进对话时按需同步（默认关闭；判定命中只提示、不静默下载，见 [§6.43](design-decisions/sync.md)）
- [x] 设置页（目录 / 范围 / 媒体开关 / 单文件上限 / 本地清理）
- [x] 导出诊断日志（issue #40 第一层：环形缓冲 + 环境信息 + 脱敏，见 [§6.20](design-decisions/runtime-and-ops.md)）
- [x] 本地文件日志 + 会话标记（[§6.57](design-decisions/runtime-and-ops.md)：`FileLogSink` / `MultiLogSink`，能区分「崩了」与「被关了」，日志与 `sync.db` 同根）+ 默认同步目录可见标记（「默认，可修改」）
- [x] 悬浮窗进入失败时回滚窗口属性（[§6.57](design-decisions/runtime-and-ops.md)：只回滚真的改过的、逆序、失败仍导航）
- [x] 同步目录未选择时的默认值（[§6.57](design-decisions/runtime-and-ops.md)：`~/Documents/Super PartyB` → 应用数据目录，仅桌面端）
- [x] 工具调用折叠 + 「动态」面板 + 流式进度条（[§6.54](design-decisions/ui.md)：展示层批卡、诊断→动态并两端可见、底部状态条报工具进度）
- [x] 全局错误兜底（issue #45：三道防线 + 静默 catch 守卫，见 [§6.24](design-decisions/testing.md)）
- [x] 工程卫生批量（issue #47：`.gitattributes` / Dependabot / action pin / 三项严格模式 / release notes 由 `git log` 生成 / `tools/` 清单守卫，见 [§6.26](design-decisions/testing.md)）
- [x] 移动端：BFF `/chat/miniapp/*` 接入
- [ ] 移动端 OIDC 登录闭环（IdP 侧已于 2026-11-06 注册 `partyb://oidc/callback`，剩真机回跳验证，见 `docs/mobile-oidc-deeplink.md` §3）
- [x] CI 流水线（`.github/workflows/ci.yml`：quality / build-linux / build-android / build-windows）
- [x] 发布流水线（`.github/workflows/release.yml`：tag 触发四端出包 → GitHub Release）
- [x] Windows 出包（GitHub Actions `windows-2022`，见 `docs/windows-release.md`）
- [x] macOS 出包（GitHub Actions `macos-14`，ad-hoc 签名 + 通用二进制，**仅 tag 触发**）
- [x] 测试文件拆分（issue #48）：11 个 >1000 行 → 34 个，全部 < 1500 行（见 [§6.27](design-decisions/testing.md)）
- [x] SSE 端到端（issue #48）：纯 Dart `dart:io HttpServer`，13 条（见 [§6.27](design-decisions/testing.md)）
- [x] 零调用者端点契约测试（issue #49）：31 条真实 `HttpServer`，并修掉 `groupConfirmations` 缺 `/api` 的真实缺陷（见 [§6.28](design-decisions/chat.md)）
- [x] 双栈端点运行中降级/升级（issue #50）：连续 3 次连接层失败降级、冷却 5 分钟后重探升级（见 §5.1.1）
- [ ] iOS 出包（需 Apple Developer 账号 $99/年 + 签名证书，无法 ad-hoc 凑合）
