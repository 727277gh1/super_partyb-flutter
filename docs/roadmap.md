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

- [x] 普通对话附件上传（Android/桌面共享输入栏），Android 系统分享与选中文字快速对话、发送后返回来源；本地实现与自动化验证，平台范围及真机验收见 [§6.113](design-decisions/chat.md)。尚未发布。

- [x] PWA / SPBF 站内通知对齐（[#120](https://<gitea-host>/dever/super_partyb-flutter/issues/120)）：桌面/移动应用级接入、共享通知中心/前台提示、完成与失败通知、持久版本判重、跨端已读与 Go 契约样本；实现已落地，验证结果见该 issue，Windows/macOS 真机与发布仍独立验收。


- [x] OIDC 登录（自实现 PKCE + loopback，非 `flutter_appauth`）
- [x] 账号安全入口（Passkey / 双因素）：设置页跳系统浏览器打开 IdP `/dashboard/security`，客户端不做 WebAuthn ceremony（见 [§6.103](design-decisions/auth.md)；原生 passkey 评估见 id-provider#40）
- [x] 两端切账号身份与离线缓存归属失效（[issue #103](https://<gitea-host>/dever/super_partyb-flutter/issues/103)，见 [§6.90](design-decisions/auth.md)；本地修复与自动化回归）
- [x] 对话列表刷新竞态、SSE 删除后复活及归档快照丢失（[issue #104](https://<gitea-host>/dever/super_partyb-flutter/issues/104)，见 [§6.91](design-decisions/ui.md)；本地修复与自动化回归）
- [x] 页面可用性修复（[issue #105](https://<gitea-host>/dever/super_partyb-flutter/issues/105)）：聊天顶部操作分行、同步设置草稿离开保护、首屏同步入口、桌面表单限宽、侧栏换行与触控/语义补齐；本地自动化及离屏截图验证通过，真机待复核。登录非主路径折叠为 #98 的部分完成。
- [x] 对话卡片待确认计数、任务失败/阻塞摘要与当前任务名称（[issue #106](https://<gitea-host>/dever/super_partyb-flutter/issues/106)，见 [§6.89](design-decisions/ui.md)）：两端复用全局查询与列表快照，进入/返回及手动刷新时更新；完整性边界、刷新行为和大字号布局已通过本地自动化及离屏检查，真机待复核。
- [x] 桌面对话列表限宽单列、三层摘要与状态降噪，两端常显管理菜单（见 [§6.84](design-decisions/ui.md)）：本地交互/布局回归及离屏检查通过，真实窗口操作待复核。
- [x] 对话列表 + SSE 实时流（cursor 续接 / 切 group 复用连接 / 加载更早历史）
- [x] 流式回复空 ID 导致多轮正文滚动消失：已复现并修复，自动化回归通过（[issue #100](https://<gitea-host>/dever/super_partyb-flutter/issues/100)，见 [§6.85](design-decisions/chat.md)；Windows release 待设备复核）
- [x] 长对话性能评审：追底动画去重、Markdown 完成时保留解析状态、稳定链接回调、行索引缓存与图片缓存修复（见 [§6.47](design-decisions/performance.md)；本地回归通过，Windows release 待设备复核）
- [x] 已读长短消息往返滚动时总高度变化：补充按行身份保存的布局高度缓存，历史前插复用、窗口与字号变化重测（见 [§6.47 第十节](design-decisions/performance.md)；本地回归通过，Windows 实机流畅度待验证）
- [x] 上翻加载历史保持阅读位置，分页在途切组隔离旧响应（[issue #100](https://<gitea-host>/dever/super_partyb-flutter/issues/100)，见 [§6.85](design-decisions/chat.md)；本地回归通过，Windows release 待设备复核）
- [x] 对话列表卡片化 + 列数跟随宽度（移动端一列、桌面端并排 2~4 列，见 [§6.84](design-decisions/ui.md)）
- [x] SSE 传输层单测（issue #41，含测出的 UTF-8 分片损坏修复，见 [§6.22](design-decisions/testing.md)）
- [x] 消息发送 + 无归属入口（悬浮窗）
- [x] 失败 turn 重发（`ErrorItem` → 重新投递，见 [§6.14](design-decisions/chat.md)）
- [x] 首 token之前的分发进度条（[issue #114](https://<gitea-host>/dever/super_partyb-flutter/issues/114) 阶段 2，服务端见 super_partyb#181）：`dispatch_stage` 只认本端 rid、不进缓冲/游标、500ms 门槛、root 收尾即收起，见 [§6.106](design-decisions/chat.md)；本地自动化回归通过，**已真机验收**（123 开关已开、用户实测看到进度；`9ab3b54` 补了「帧到没到」的诊断日志，判读见 [§6.106.1](design-decisions/chat.md)）
- [x] 事件契约目录对拍 + 契约漂移可见出口（[issue #116](https://<gitea-host>/dever/super_partyb-flutter/issues/116) / [#117](https://<gitea-host>/dever/super_partyb-flutter/issues/117) / [#118](https://<gitea-host>/dever/super_partyb-flutter/issues/118)）：vendored `event-catalog.json` + 语义对拍（类别闭集 / timeline 全覆盖 / 控制类闭环）、未知类型不再静默（一行「未知事件」+ 每类型一次 warn），顺带修掉 `habit_pattern_recalibrated` 被丢弃的真 bug，见 [§6.107](design-decisions/chat.md)；「18 → ≤7 渲染器合并」按票面数据不成立，保持按类型分派
- [x] `error` 事件按服务端 `code` 出表现（[issue #115](https://<gitea-host>/dever/super_partyb-flutter/issues/115)，服务端 P0 见 super_partyb#182）：`code` 闭集镜像 + vendored 对拍（`tools/sync_error_codes.sh`）、正文只取 `message`、`detail` 折叠进「技术详情」、`retryable` 决定「重发」，见 [§6.105](design-decisions/chat.md)；本地自动化回归通过（含 `error_banner` golden 未变），123 真实 OOM / 限流事件待复现复核
- [x] 发送的乐观回显（请求在飞时「发送中」，issue #52，见 [§6.50](design-decisions/chat.md)）
- [x] 对话内搜索（搜已加载时间线，见 [§6.15](design-decisions/chat.md)）+ 窄屏 AppBar 溢出修复（issue #31，见 [§6.16](design-decisions/ui.md)）
- [x] 跳到会话内某一轮：`/chat/{groupId}?turn={turnId}` 深链（搜索命中 / 待确认收件箱 / 习惯执行历史 / 我的轮次四处入口都带上锚点，落位 + 高亮 + 「回到最新」，见 [§6.92](design-decisions/chat.md)）：本地自动化回归通过，真机跳变观感待复核；越界自动补页（[#108](https://<gitea-host>/dever/super_partyb-flutter/issues/108)）与 OS 层深链（[#109](https://<gitea-host>/dever/super_partyb-flutter/issues/109)）未做
- [x] 轮次导航刻度条（会话右侧竖置刻度：常驻横杠 + hover 显示各轮问题前 24 字 + 刻度列可滚 + 点击跳转；触屏改开 48dp 列表弹层、窄屏走「更多」菜单，见 [§6.94](design-decisions/chat.md)）：本地自动化回归通过（含面板淡入淡出 / 横杠伸缩的动效用例与「减少动效」降级）；hover 观感、触控板手感与真机触屏点按待复核
- [x] spec 看板：Table、六类 Chart、响应式 Stack/Grid、状态快照取值（见 [§6.9.4](design-decisions/runtime-and-ops.md)；本地回归与 golden 通过，设备效果待验收）
- [x] 交付物同步（单向拉取 + 双向回传与冲突物化）
- [x] 自动同步（启动后一次 / 周期 N 分钟，默认关闭；仅桌面端装配，见 [§6.42](design-decisions/sync.md)）
- [x] 进对话时按需同步（默认关闭；判定命中只提示、不静默下载，见 [§6.43](design-decisions/sync.md)）
- [x] 设置页（目录 / 范围 / 媒体开关 / 单文件上限 / 本地清理）
- [x] 导出诊断日志（issue #40 第一层：环形缓冲 + 环境信息 + 脱敏，见 [§6.20](design-decisions/runtime-and-ops.md)）
- [x] 本地文件日志 + 会话标记（[§6.57](design-decisions/runtime-and-ops.md)：`FileLogSink` / `MultiLogSink`，能区分「崩了」与「被关了」，日志与 `sync.db` 同根）+ 默认同步目录可见标记（「默认，可修改」）
- [x] 悬浮窗进入失败时回滚窗口属性（[§6.57](design-decisions/runtime-and-ops.md)：只回滚真的改过的、逆序、失败仍导航）
- [x] Windows「定位/打开交付物」落在默认视图（issue #97）：路径归一化 + `SHOpenFolderAndSelectItems` 原生定位，见 [§6.75](design-decisions/platform.md)（FFI 真机行为待 Windows 实测）
- [x] 同步目录未选择时的默认值（[§6.57](design-decisions/runtime-and-ops.md)：`~/Documents/Super PartyB` → 应用数据目录，仅桌面端）
- [x] 工具调用折叠 + 「动态」面板 + 流式进度条（[§6.54](design-decisions/ui.md)：展示层批卡、诊断→动态并两端可见、底部状态条报工具进度）
- [x] 对话等待提示统一为轮次状态栏：阶段互斥、工具/时长详情按需展开、重复转圈移除（见 [§6.54](design-decisions/ui.md)；本地回归与两端接线验证通过，真机待复核）
- [x] 全局错误兜底（issue #45：三道防线 + 静默 catch 守卫，见 [§6.24](design-decisions/testing.md)）
- [x] 工程卫生批量（issue #47：`.gitattributes` / Dependabot / action pin / 三项严格模式 / release notes 由 `git log` 生成 / `tools/` 清单守卫，见 [§6.26](design-decisions/testing.md)）
- [x] 移动端：BFF `/chat/miniapp/*` 接入
- [ ] 移动端 OIDC 登录闭环（IdP 侧已于 2026-11-06 注册 `partyb://oidc/callback`，剩真机回跳验证，见 `docs/mobile-oidc-deeplink.md` §3）
- [x] 微信 OpenSDK 唤起小程序（方案 B）：`spb_platform` 契约 + fluwx 桥接 + 登录页接入，服务端零改动（待开放平台 appid 与真机，见 issue #92）
- [x] App 内「微信一键登录」：小程序会话 → 标准 OIDC 授权码（客户端编排 + 服务端兑换端点 + URL Scheme 生成均已上线，剩真机验证，见 `docs/wechat-one-click-login.md`、id-provider#10、flutter#80）
- [x] 移动端 claimed HTTPS 回调（Android App Links）：`autoVerify` 过滤器（双栈两域名）+ `OidcCallbackUri.matches` 双形态 + manifest/plist 漂移守卫测试。**2026-11 默认已切到 claimed HTTPS**（`OidcCallbackUri.preferredRedirectUri`：issuer 为 https 时用 `<issuer>/app/callback`，否则退回 scheme；两个环境的 `redirectUris` 均已注册，网关 `assetlinks.json` 已补 dever 域名），剩真机验证 `pm get-app-links` 为 verified（见 `docs/mobile-oidc-deeplink.md` §2.3、`design-decisions/auth.md` §6.91）
- [x] CI 流水线（`.github/workflows/ci.yml`：quality / build-linux / build-android / build-windows）
- [x] 发布流水线（`.github/workflows/release.yml`：tag 触发四端出包 → GitHub Release）
- [x] Windows 出包（GitHub Actions `windows-2022`，见 `docs/windows-release.md`）
- [x] macOS 出包（GitHub Actions `macos-14`，ad-hoc 签名 + 通用二进制，**仅 tag 触发**）
- [x] 测试文件拆分（issue #48）：11 个 >1000 行 → 34 个，全部 < 1500 行（见 [§6.27](design-decisions/testing.md)）
- [x] SSE 端到端（issue #48）：纯 Dart `dart:io HttpServer`，13 条（见 [§6.27](design-decisions/testing.md)）
- [x] 零调用者端点契约测试（issue #49）：31 条真实 `HttpServer`，并修掉 `groupConfirmations` 缺 `/api` 的真实缺陷（见 [§6.28](design-decisions/chat.md)）
- [x] 双栈端点运行中降级/升级（issue #50）：连续 3 次连接层失败降级、冷却 5 分钟后重探升级（见 §5.1.1）
- [ ] iOS 出包（需 Apple Developer 账号 $99/年 + 签名证书，无法 ad-hoc 凑合）
