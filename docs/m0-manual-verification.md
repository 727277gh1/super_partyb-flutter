# M0 交互能力人工验证 runbook（issue #4）

> 本仓库的 M0 骨架（工作区 / 分层 / 9 packages + 2 apps / Linux release 构建 /
> 核心契约与归约）已在**无头环境**完成自动化验证。本文覆盖**自动化验证不到**的
> 交互能力——多窗口、托盘、全局快捷键、OIDC 回跳、剪贴板文件、交付物同步写盘。
>
> 相关：`AGENTS.md` §6.5（多窗口结论）、§6.8（剪贴板文件）、§6.11（托盘菜单）、
> §6.12（i18n 决策）、§8（macOS entitlements）、§9（无头验证的边界）、
> §11（已知问题）；
> `docs/rfc8252-loopback-signin.md`（桌面 OIDC）、
> `docs/mobile-oidc-deeplink.md`（移动 OIDC）。

---

## 0. 为什么需要人工验证

本机（Debian 12 LXC 容器）**无法验证任何交互行为**：

| 限制 | 影响 | 根因 |
|---|---|---|
| 无 `DISPLAY` | 无法验证点击、拖拽、焦点、托盘菜单 | 容器无 X/Wayland 会话 |
| 无 `/dev/kvm` | Android 模拟器不可用 | LXC 未透传设备节点（宿主 `kvm_amd` 已加载且 `nested=1`，CPU 有 `svm`——**只是设备节点缺失**） |
| 无 Windows / macOS | 无法出对应安装包 | Flutter 要求原生主机（见 `super_partyb#31`） |

### ⚠️ Xvfb 下的「窗口出现了」**不是**渲染正确的证据

`xvfb-run` 下渲染**不稳定**：实测同一命令有时窗口创建成功，有时停在 10x10
占位窗。因此：

```
❌ 不要用「xvfb-run 下窗口出现了」当作渲染正确的证据
✅ xvfb-run 只能证明「进程能启动并存活」（`timeout 15 ./spb_desktop` 退出码 124）
```

`Xvfb` 验证的边界与可/不可验证项，见 `AGENTS.md` §9。

---

## 1. 自动化前置门禁（本机可跑，先全绿再上人工）

在**仓库根**逐条执行。任何一条不绿都不必开始人工项——那些问题人工也复现不了
更精确的原因。

```bash
# 0) Flutter SDK 需显式在 PATH（否则 dart 不在 PATH）
export PATH="$HOME/.local/opt/flutter/bin:$PATH"

# 1) 分层规则（纯 Dart 包禁止依赖 Flutter；单向依赖）
bash tools/check_layering.sh
# 期望：✅ 分层规则检查通过

# 2) 静态分析（含 info 级）
dart analyze --fatal-infos .
# 期望：No issues found!

# 3) 格式门禁
bash tools/check_format.sh
# 期望：✅ 格式检查通过

# 4) 逐包测试
#
# ⚠️ **测试命令按包类型分两组**（写错会静默少跑一半用例）：
#
#   纯 Dart 包（无 Flutter 依赖）→ `dart test`
#     spb_core / spb_models / spb_api / spb_domain
#   含 UI 的包 → `flutter test`
#     spb_data / spb_design / spb_ui / spb_platform / spb_features
#
# 实测（2026-10）：对后 5 个包跑 `dart test` 会**失败**（需要 Flutter 引擎）。
# 故**不要**把两类混在一个 `for` 循环里——那会让其中一类整体跑不起来，
# 而 `for` 循环里的失败容易被当成噪音忽略。
for p in spb_core spb_models spb_api; do
  (cd packages/$p && dart test)
done
(cd packages/spb_domain   && dart test)     # +724
for p in spb_data spb_design spb_ui spb_platform spb_features; do
  (cd packages/$p && flutter test)
done
(cd apps/spb_desktop      && flutter test)  # +139
(cd apps/spb_mobile       && flutter test)  # +91
# 期望：全部 `All tests passed!`
#
# ⚠️ spb_domain / spb_features **必须在各自目录**下跑：
# event_types_consistency_test 用相对路径读 lib/src/event_reducer.dart，
# 从仓库根跑会失败（预先存在的约束，非回归）。

# 5) Linux release 构建
cd apps/spb_desktop && flutter build linux --release
# 期望：exit 0

# 6) 分发依赖打包（把非系统库打进 bundle + 修 RUNPATH）
cd /path/to/super_partyb-flutter
bash tools/bundle_linux_deps.sh
# 期望：复制 libkeybinder-3.0.so.0 等；无错误

# 7) 自包含校验
cd apps/spb_desktop/build/linux/x64/release/bundle
LD_LIBRARY_PATH= ldd spb_desktop | grep "not found"     # 期望：无输出
for f in lib/*.so*; do patchelf --print-rpath "$f"; done # 期望：无 /home/
patchelf --print-rpath spb_desktop                       # 期望：$ORIGIN/lib

# 8) 进程能启动并存活（唯一能自动化的运行时证据）
#
# ⚠️ **必须套 `xvfb-run`**：本机无 `DISPLAY`（`AGENTS.md` §9），
# 直接跑二进制会以 **退出码 1** 失败（`Gtk-WARNING: cannot open display:`），
# 看起来像「程序坏了」而不是「环境没屏幕」。`xvfb-run` 造一个虚拟 X
# 服务器，进程才能走到主循环并存活到超时。
cd /path/to/super_partyb-flutter/apps/spb_desktop
xvfb-run -a timeout 15 ./build/linux/x64/release/bundle/spb_desktop
# 期望：退出码 124（存活到超时 = 正常）
#
# 不要因为「退出码不是 124」就去查业务代码——先确认是否忘了 `xvfb-run`。
# 另外：`xvfb-run` 下**渲染仍不可靠**（同一命令有时窗口创建成功、有时停在
# 10x10 占位窗），故它只证明「进程能启动并存活」，**不是**渲染正确的证据（见 §0）。
```

**基线计数**（2026-10 实测，供对照；数量随开发增长，只需关注「是否全绿」）：

| 包 | 用例数 | 包 | 用例数 |
|---|---|---|---|
| `spb_core` | 67 | `spb_ui` | 40 |
| `spb_models` | 433 | `spb_platform` | 79 |
| `spb_api` | 355 | `spb_features` | 1089 |
| `spb_domain` | 881 | `spb_desktop` | 144 |
| `spb_data` | 130 | `spb_mobile` | 102 |
| `spb_design` | 24 | **合计** | **3344** |

> 合计与逐包数字**必须一起更新**——本文件曾出现「正文说 199 个测试」而实际
> 已 2600+ 的漂移（issue #4 正文）。改任一处时请顺手核一遍总和。

---

## 2. 人工项清单

> 前置：在一台**有真实桌面环境**的 Linux 机器上，用 §1 构建出的
> `bundle/` 运行 `./spb_desktop`（或对应平台包）。
>
> 每项格式：**前置 / 操作 / 期望 / 失败时排查点**。

### 2.1 多窗口语义（**主窗口临时变身**，M0 头号风险）

**背景**：`window_manager` **做不到**真多窗口（`get_window()` 是
`gtk_widget_get_toplevel(view)`，一个 engine 只有一个 view；公开 API 里没有
创建窗口的方法）。当前实现是「主窗口临时变身」——按 `Alt+Space` 时保存几何、
改尺寸为主 `quickCaptureWithAttachments` 规格、置顶、居中，导航到 `/overlay`；
提交或 `Esc` 后还原。详见 `AGENTS.md` §6.5。

- **前置**：主窗口已打开且显示某个对话；`~/.pigo` 或同步目录不要求。
- **操作**：按 `Alt+Space` 进入悬浮模式；按 `Esc` 退出。
- **期望**：
  - [ ] 窗口变为 `720×360`（`WindowSpec.quickCaptureWithAttachments`，允许拖高）、
        置顶（其它窗口盖不住它）、不出现在任务栏。
  - [ ] `Esc` 后窗口几何、置顶标志、任务栏可见性**全部还原**为进入前的状态。
  - [ ] 反复进出 10 次不出现尺寸漂移（每次还原回同一个几何）。
  - [ ] **已知差异**：悬浮期间**看不到背后的对话**——主窗口被「顶替」了。
        这是单窗口约束下的有意取舍（真多窗口需换 `desktop_multi_window`，
        每个窗口是独立 isolate，Riverpod/认证/Dio 都不共享）。**看到这一点
        不是 bug**。
- **失败时排查点**：
  - 窗口不置顶 → 检查合成器是否允许 `alwaysOnTop`（Wayland 下部分合成器
    忽略 `skipTaskbar`）。
  - `Esc` 后没还原 → `PlatformDesktopCapabilities.exitOverlayMode` 是否被调用；
    `isOverlayModeActive` 是否为 true（该 getter 是唯一真相，见其文档）。
  - 尺寸漂移 → `enterOverlayMode` 是否在导航**前**完成（否则会先看到全尺寸
    主窗闪一下再缩，见 `_navigateToRole` 的注释）。

### 2.2 托盘菜单（6 项，见 `AGENTS.md` §6.11）

- **前置**：Linux 需 `libayatana-appindicator3`（§7 的系统依赖）；桌面环境
  需支持系统托盘/状态栏（GNOME 需 AppIndicator 扩展）。
- **操作**：点托盘图标展开菜单，逐项点击。
- **期望**（6 项，顺序见 `_installTrayMenu`）：
  - [ ] **显示主窗口** → 主窗口显示并置前。
  - [ ] **快速输入（Alt+Space）** → 与 §2.1 同一路径进悬浮模式。
  - [ ] **立即同步交付物** → 触发一次同步（未注入回调时应**置灰**）。
  - [ ] **打开同步目录** → 文件管理器打开配置的同步目录；
        **未配置目录时应置灰**（此时 `revealPath` 拿到空串会落到用户主目录，
        看起来像「功能坏了」而不是「还没配」）。
  - [ ] **同步设置…** → 直达 `/settings/sync` 页（**不是**设置页首个 tab）。
        该项**始终可用**（它正是配置入口，禁用会让未配置用户死锁）。
  - [ ] **退出** → 应用完整退出（先摘监听器、注销快捷键、销毁托盘图标）。
- **失败时排查点**：
  - 菜单不显示 → AppIndicator 依赖是否装上；`caps is TrayActionTarget`
    是否为真（`attach()` 按接口判能力，Noop 实现会跳过接线）。
  - 「打开同步目录」点了没反应 → 该 Linux 托盘忽略 `enabled` 字段时，
    动作内部还有一层防御（`SpbLog.warn('未注入回调')`），看日志确认。

### 2.3 `Alt+Space` 全局快捷键进出悬浮模式

- **前置**：`hotkey_manager` 依赖 `libkeybinder-3.0`（§7）。⚠️ 该组合在部分
  桌面环境**已被系统占用**（GNOME 窗口菜单、Windows 系统菜单）。
- **操作**：在**非**应用窗口获得焦点时按 `Alt+Space`；再按 `Esc`。
- **期望**：
  - [ ] 全局生效（焦点在别的程序上也能唤出悬浮输入）。
  - [ ] 与 §2.1 的进/出行为一致。
  - [ ] **冲突时**：若系统已占用该组合，注册应失败并**降级**（记日志、
        不崩溃、不影响其它功能）——确认没有「按了没反应且无任何提示」。
- **失败时排查点**：
  - 注册失败 → 换一个未被占用的组合（`HotkeyBinding` 用字符串键名，
    便于扩展），或改系统快捷键设置。
  - `libkeybinder-3.0.so.0` 加载失败 → 是否跑了 `tools/bundle_linux_deps.sh`
    （未跑会把开发机绝对路径写进 RUNPATH，见 §7）。

### 2.4 OIDC loopback 全流程（M0 阻塞项）

- **前置**：IdP 生产已注册**桌面 public client**（loopback，
  `tokenEndpointAuthMethod=none`，`requirePkce=true`）——**当前未完成**，
  见 §3。在此之前登录只能走「粘贴导入会话」降级路径。
- **操作**：登录页 → 点登录 → 系统浏览器打开 IdP 授权页 → 完成认证 →
  浏览器回跳 `http://127.0.0.1:<随机端口>/callback`。
- **期望**：
  - [ ] 客户端 bind 一个 loopback 随机端口成功（`LoopbackRedirectServer`）。
  - [ ] 授权 URL 带 `code_challenge`（S256）与 `state`（CSRF）。
  - [ ] 回跳后 `state` 校验通过，用 `code` + `code_verifier` 换到 token。
  - [ ] 登录态落盘（`SecureTokenStore`，`flutter_secure_storage`）。
  - [ ] 重启应用后仍是登录态；过期后能刷新/重登。
- **失败时排查点**：
  - `400 invalid_request` → IdP 未注册该 `redirect_uri`（loopback 端口是
    通配的，fosite 原生支持；**client 必须存在**）。
  - 换 token 401 → client 不是 public（`token_endpoint_auth_methods_supported`
    只有 `client_secret_basic`/`post`），见 §3。
  - 回跳后无反应 → 浏览器是否真的回到了 loopback 端口（防火墙/浏览器拦截）。
  - 完整链路与设计依据见 `docs/rfc8252-loopback-signin.md`。

### 2.5 剪贴板文件粘贴（三平台原生 channel，见 `AGENTS.md` §6.8）

- **前置**：三平台原生侧**均已注册** `MethodChannel('com.atjog.spb/clipboard_files')`
  （Linux `my_application.cc` / Windows `flutter_window.cpp` /
  macOS `AppDelegate.swift`）。
- **操作**：在文件管理器里复制若干文件 → 切到应用 → 在输入区按 `Ctrl+V`。
- **期望**：
  - [ ] 文件被识别为附件 chip（不是粘贴成一串路径文本）。
  - [ ] **多文件**都能贴上（逐个 chip）。
  - [ ] 从网页复制文件（而非本地文件）时**不弹错误弹窗**——原生侧刻意不回
        error，函数静默返回空，只是不产生 chip。
  - [ ] 纯文本粘贴不受影响。
- **失败时排查点**：
  - channel 名写错 → **不会报错**，只会静默返回空（三平台原生源码顶部都有
    「写错不会报错」的注释）。逐个核对 channel 名。
  - `MissingPluginException` → channel 未注册（单元测试环境或将来新增平台），
    函数静默返回空——这是**设计如此**，不是缺陷。

### 2.6 交付物同步写用户所选目录（macOS entitlements）

- **前置**：macOS 包（`Release.entitlements` / `DebugProfile.entitlements`
  **两份均已含** `com.apple.security.files.user-selected.read-write`）。
  该键是 `file_selector` 的 macOS 要求——沙箱下访问用户所选目录。
- **操作**：设置里选一个同步目录 → 触发同步 → 确认文件真的落盘。
- **期望**：
  - [ ] 能选中目录且**写入成功**（不是「同步报写入失败」）。
  - [ ] 同步语义与 Tauri 迁移版一致（见 `AGENTS.md` §10「交付物同步的既有
        语义」）：单向 UFS→本地、`updated_since` 增量、感知 `deleted_at`
        远端删除、`.part` + rename 原子写入、路径穿越防御、失败项不写状态。
  - [ ] 「全部 group」与「选中若干」共用状态键 `__workspace__`：切换范围
        **不**全量重拉；**换目录才重置**状态。
- **失败时排查点**：
  - 「同步报写入失败」 → 极可能是 entitlements 缺该键。**debug 构建沙箱较松
    可能不暴露，只在正式包上现形**——务必用 release 包验证。
  - 路径穿越被拒 → 属预期防御（服务端返回的路径不应逃出同步目录）。

### 2.7 可访问性与键盘可达性（issue #24）

**本项无法在本机验证**（无 `DISPLAY`、无 `/dev/kvm`），必须真机/真实桌面环境。

#### 自动化已覆盖的部分（本机可跑）

```bash
export PATH="$HOME/.local/opt/flutter/bin:$PATH"
cd packages/spb_features
flutter test test/chat/accessibility_test.dart   # 期望：+6 All tests passed!
```

这 6 例锁住三类**屏幕阅读器读不出内容**的场景（每例都对应一个真实会读错的
情形，不是「全仓扫描 + 批量加标签」）：

| 场景 | 锁住的不变式 |
|---|---|
| `SpecUiCard` 的 progress 元素 | `label` 非空时进度条的 `semanticsLabel` 等于它；为空时**不编造**「进度」 |
| `GoalTasksPanel` 的进度条 | `semanticsLabel` 为「目标任务完成进度」——它上面那行「已完成 3/5」是**另一个**节点，屏幕阅读器不会自动关联 |
| `GroupListPage` 条目的长按/右键菜单 | 有 `onGroupAction` 时暴露 `customSemanticsActions`；为 null 时不暴露 |
| `OverlayQuickCapturePage` 附件 chip 的 ✕ | 每个 chip 的 `Semantics.label` 带**自己的**文件名 |

#### 仍需人工验证的部分（**不要用 Xvfb 结果当证据**，见 §0）

**桌面端（Linux / Windows / macOS）**

- [ ] **Tab 顺序**：从主窗口顶部开始按 `Tab`，焦点依次经过 AppBar 按钮 →
      对话列表条目 → 输入框 → 发送按钮，**不跳过**也不乱序。
- [ ] **Shift+Tab 反向**：顺序与正向相反。
- [ ] **Enter / Space 激活**：焦点在 `IconButton` / `FilledButton` 上时两者都能触发。
- [ ] **Esc 关闭**：对话框（如「新建目标」`goal-create-dialog`）、底部弹层、
      悬浮输入窗均可用 `Esc` 关闭。
- [ ] **自定义滚动区的键盘滚动**：`conversation_page.dart` 与
      `group_list_page.dart` 覆盖了 `ScrollConfiguration.dragDevices`——确认
      `PageUp/PageDown`、方向键、`Home/End` 仍能滚动（自定义 `dragDevices`
      只影响指针，理论上不影响键盘，但**需实测**）。
- [ ] **焦点可见性**：焦点在图标按钮上时有可见的焦点环（不能只有颜色变化）。
- [ ] **`Alt+Space` 悬浮窗的焦点**：进入悬浮模式后输入框自动聚焦；`Esc` 退出后
      焦点回到主窗口（见 §2.3）。

**移动端（Android / iOS）**

- [ ] **TalkBack / VoiceOver 逐项朗读**：
  - 图标按钮读出的**是 tooltip 文案**（如「对话设置」），不是「按钮」；
  - 进度条读出「目标任务完成进度，60%」（标签 + 值），不是孤零零的「60%」；
  - 附件 chip 的 ✕ 读出「移除附件 报告.pdf」，不是「按钮」。
- [ ] **触摸探索（explore by touch）**：手指扫过页面，每个可交互元素都有非空名称。
- [ ] **自定义手势不夺焦**：对话页的 `InkWell` 重连指示器（`conversation-connection-indicator`）
      在 TalkBack 下可聚焦、可双击触发。

**已知未覆盖（有意不做，见 issue #24 备注）**

- 纯装饰图标**不加** `Semantics(label: '图标')`——那类标签对用户零信息，反而
  降低可用性（屏幕阅读器会念一堆无意义的「图标」）。
- spec 卡的图表/metric 元素未逐个补语义：它们是**视觉化**呈现，语义化需要
  「读出来该是什么」的逐元素判断（如 metric 应读「标签：值」），属后续单独一轮。

#### 失败时排查点

- 「屏幕阅读器念不出某个图标按钮」 → 先查 `tooltip` 是否为 null。Flutter 会把
  `Tooltip.message` 注入语义树（`tooltip.dart` 的 `semanticsTooltip`），**没写
  tooltip 的 `IconButton` 在语义树上只有「按钮」**。
- 「语义测试找不到标签」 → 确认测试里调了 `tester.ensureSemantics()`。
  `flutter_test` 默认**关闭**语义树，不开的话断言永远落空。

### 2.8 导出诊断日志（issue #40）

- **前置**：桌面端（Linux / Windows / macOS）。移动端**有意不接**（`file_selector`
  的 `getSaveLocation` 在 Android/iOS 上未实现，见 `AGENTS.md` §6.20）。
- **操作**：设置页 → 「导出诊断日志」→ 在「另存为」里选一个可写目录 → 打开
  导出的 `spb-diagnostics-<时间戳>.txt`。
- **期望**：
  - [ ] 弹出系统「另存为」对话框，默认文件名形如
        `spb-diagnostics-20261012-203045.txt`（**含 `:` 则 Windows 会失败**）。
  - [ ] 取消对话框时**不弹任何提示**（取消不是失败）。
  - [ ] 导出成功时弹「诊断报告已导出」。
  - [ ] 报告含「运行环境」（版本 / 平台 / Flutter / 服务地址）与「最近日志」。
  - [ ] 报告**不含**任何 `Bearer …` / JWT（`eyJ…`）/ `sk-…` / `ghp_…` /
        `api_key=…` / `password=…`——这是硬红线（会被贴进公开 issue）。
  - [ ] 日志条目**每条一行**（堆栈里的换行被转义为字面量 `\n`）。
- **失败时排查点**：
  - 「另存为对话框弹不出来」 → 无 `DISPLAY` / 缺 GTK 端口。属**预期内**降级
    （弹「导出失败」而非崩），不要当缺陷。
  - 「Windows 上报导出失败」 → 先查文件名是否含 `:`。
  - 「报告里日志很少」 → 阈值过滤在**记录之前**：默认 `minLevel=info` 且
    上限 500 条。要 debug 细节需 `--dart-define=SPB_VERBOSE_LOG=true` 重建，
    而不是期待导出时能补回来（见 `AGENTS.md` §6.20）。

---

## 3. 阻塞条件（跨仓生产配置，本仓无法完成）

以下两项在 **IdP（`id-provider`）侧**，属生产配置变更，**本仓库无法闭合**：

### 3.1 桌面端 public client（loopback）

需在 IdP 新增一个**桌面专用 public client**：

- `redirectUris` 含 loopback（`http://127.0.0.1:<任意端口>/callback`，
  fosite 原生支持端口通配）；
- `token_endpoint_auth_method = none`（public client，客户端无 `client_secret`）；
- `requirePkce = true`（客户端已发 S256 challenge，但不靠服务端兜底）。

在此之前桌面登录只能走「粘贴导入会话」降级路径。

### 3.2 移动端 public client（`partyb://oidc/callback`）

Android `<intent-filter>` 与 iOS `CFBundleURLTypes` **已注册**（
`docs/mobile-oidc-deeplink.md` §0），回调接收/解析/state 校验/换 token
**已实现并单测**（21 例）。但**仍不能真正登录**，缺两个 IdP 侧配置：

1. 把 `partyb://oidc/callback` 加进该 client 的 `oauth_clients.redirectUris`
   （当前只有三个网关回调）；
2. 新建一个 **public client**（`token_endpoint_auth_method=none`）+ 强制 PKCE。

> IdP Go 版已支持 public client（`oauthclient.Create` 接受
> `tokenEndpointAuthMethod=none`，`oidc.Client.GetTokenEndpointAuthMethod`
> 读真实列值）并强制 public client 使用 PKCE（`EnforcePKCEForPublicClients`）。
> 故**只差注册这一步**。

### 3.3 其它环境阻塞

| 项 | 状态 | 参考 |
|---|---|---|
| Android 模拟器不可用（`/dev/kvm` 未透传） | 待决策 | `super_partyb#30` |
| Windows / macOS 出包需原生主机 | 已知限制 | `AGENTS.md` §8 |
| iOS 出包需 Apple Developer 账号（$99/年） | 待决策 | `super_partyb#31` |

---

## 3.4 阻塞条件的**核实记录**（issue #4，逐条对代码/上游核实）

issue #4 的正文写于 M0 阶段，其中**三处已过时**。下表是逐条核实的结果——避免
后来者照着过时的描述去排查一个不存在的问题。

### 3.4.1 issue 正文过时之处

| issue #4 正文的说法 | 核实结果 | 证据 |
|---|---|---|
| 「199 个测试」 | **已过时**：当前 **3344**（见 §1 的逐包数字与合计） | 逐包 `flutter test` / `dart test` |
| 「`sessionTokenProvider` 恒返回 `null`，即未接 OIDC」 | **已过时**：它返回 `manager.currentAccessToken`（`SessionManager`），OIDC 已接通 | `apps/spb_desktop/lib/providers.dart` 的 `sessionTokenProvider` |
| 「确认卡『同意/拒绝』当前实现路径有误，见 #1，修好前此项必然失败」 | **#1 已 closed**：路径现为 `POST /api/chat/groups/:gid/confirmations/:cid/resolve`（含 `group_id`，体键 `action`），有 4 例单测 | `packages/spb_api/lib/src/chat_api.dart:1053`、`test/chat_api_test.dart` 的 `resolveConfirmation` 组 |
| 「多窗口」作为「M0 头号风险，需验证主窗+设置窗+悬浮窗能否同时存在」 | **已重新决策**：`window_manager` **做不到**多窗口（一个 engine 一个 view），改为「主窗口临时变身」单窗方案。验证项已相应改写（见 §2.1） | `AGENTS.md` §6.5 |
| 「IdP 是否支持 PKCE / 是否允许自定义 scheme」 | **已定论**：IdP 支持 PKCE；**自定义 scheme 与 loopback 都被拒**（`400 invalid_request`），故走 RFC 8252 §7.3 loopback + 待注册 public client | `docs/rfc8252-loopback-signin.md`、`packages/spb_api/lib/src/oidc_client.dart:28` |

> 结论：issue #4 的**清单仍然有效**（本机确实无 `DISPLAY` / 无 `/dev/kvm`），
> 但它的「现状描述」不能直接引用。以本文件 §2 的清单为准。

### 3.4.2 阻塞条件的**当前**核实状态

| 阻塞项 | 核实方式 | 结果 |
|---|---|---|
| 桌面 public client（loopback） | 上游 issue `dever/id-provider#6` 状态 | **仍 open** → 阻塞成立 |
| `token_endpoint_auth_methods_supported` 缺 `none` | 读 `id-provider/go/internal/oidc/provider.go:233` | **确认缺**：只有 `client_secret_basic` / `client_secret_post` → 阻塞成立 |
| 移动端 deeplink client | 同上（`id-provider#6` 待办 2） | **仍 open** → 阻塞成立 |
| 生产 IdP 是否已注册该 client | `ssh <deploy-host>` + 查 `oauth_clients` 表 | ⚠️ **本次无法核实**：容器到 `bcc`（生产 SSH 别名，见 AGENTS.md §部署约定）**连接超时**，IdP 生产地址亦不可达（`000`）。故「已注册/未注册」只能依据 `id-provider#6` 的 open 状态推断 |

⚠️ **上表最后一行的不确定性必须如实传递**：本容器网络到生产不可达，故「生产
是否已注册」是**推断**（依据上游 issue 仍 open），不是**实测**。人工验证时请先
按 §2.4 直接试一次登录——若成功，说明 `id-provider#6` 已完成（届时关闭它）。

### 3.4.3 本机**无法**核实的原因（环境限制的精确表述）

| 想核实的东西 | 为什么本机做不到 |
|---|---|
| 生产 `oauth_clients` 表内容 | 容器到 `bcc` SSH 超时、IdP 域名不可达（本次实测） |
| 任何渲染/交互 | 无 `DISPLAY`（`AGENTS.md` §9） |
| Android 真机行为 | 无 `/dev/kvm`（模拟器不可用）、无连接的真机 |
| Windows / macOS 包 | Flutter 要求原生主机（`AGENTS.md` §8） |

---

## 4. 验证结果记录

人工验证完成后，请在本节追加一行（便于 issue #4 收口时对照）：

| 日期 | 平台/桌面环境 | 结果 | 备注 |
|---|---|---|---|
| — | — | — | 待填 |
