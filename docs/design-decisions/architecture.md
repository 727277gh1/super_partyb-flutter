# 架构与关键取舍

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。从 `AGENTS.md` 的 §6 拆出：SSE-only、契约手写、Riverpod、桌面能力隔离、
多窗口结论、桌面端相对 Tauri 的净损失、剪贴板文件、两端面板不对称、托盘菜单。

仓库结构（§3）与分层规则（§4）留在 [`AGENTS.md`](../../AGENTS.md)——那是读者
找目录与判据的第一站，不适合再跳一层。

> 编号（`§6.x` / `§5.x` / `[§7](build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](README.md)。

---

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
后者只拿注入进来的回调与数据（见 [§6.17](testing.md) 的接线守卫）。同理 `go_router` 也是
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

> **2026-11-13 复核：前提变了，「不做」的结论没变。** 0.6.0 起 `window_manager`
> 改由 nativeapi 驱动，其 changelog 明写 "Several windows at once, content bounds,
> title bar colours, visual effects and focusability come with it"——上面那条
> 「0.5.2 的公开 API 里根本没有创建窗口的方法」**对 0.6.x 已不成立**。
>
> 不换的理由从「做不到」收窄为「不划算」：悬浮窗真正缺的需求是**同屏**，而第二个
> 窗口要付的代价是**独立 engine / 独立 isolate**（Riverpod 容器、认证凭证、`Dio`
> 都得在第二窗口重建，见下）。nativeapi 的多窗口是否同样需要每窗独立视图/engine
> **未核实**；若同样需要，换上它并不比 `desktop_multi_window` 省事。
>
> 触发条件：真出现「悬浮窗与主窗同屏」需求时，先核实 nativeapi 多窗口的装配成本，
> 再在「`window_manager` 0.6+」与「`desktop_multi_window`」之间选（版本升级的触发
> 条件另见 issue #101）。`flutter config --enable-windowing` 在 3.47.5 仍是
> `Unavailable`；3.50 未核实。

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

1. 保存当前窗口几何与**可见性**（`getBounds` / `isVisible` / `isMinimized`）；
2. **先隐藏**，再改尺寸为主 `quickCaptureWithAttachments` 规格、
   `alwaysOnTop=true`、`skipTaskbar=true`、按鼠标所在显示器定位；
3. 导航到 `/overlay`；
4. 页面首帧把内容自然高度报上来，窗口高度贴合内容（[§6.68](platform.md)）；
5. 等一帧后 `revealOverlayMode()`：窗口一次成型地显示并聚焦。

提交或 `Esc` 后按**进入前的可见性**收尾：原本在托盘里就继续待着（前台交还
原应用），原本可见就还原尺寸并显示。见
`PlatformDesktopCapabilities.enterOverlayMode` / `revealOverlayMode` /
`exitOverlayMode` / `fitOverlayContentHeight`，以及 [§6.69](platform.md)
（为什么不是「无条件显示主窗口」）。

**已知差异**：悬浮期间主窗口被「顶替」（看不到背后的对话）。对「快速记一笔」
这个用途可接受，但若将来需要「悬浮窗与主窗同屏」，就得换 `desktop_multi_window`。

### 6.6 桌面端相对 Tauri 的净损失

| 能力 | Tauri | Flutter |
|---|---|---|
| Linux 包 | ✅ | ✅ |
| **Windows 包（本机交叉编译）** | ✅ `cargo-xwin` | ❌ **必须 Windows 主机** |
| 自动更新器 | ✅ `tauri-plugin-updater` | ❌ 需自行实现 |
| 安装包体积 | ~10 MB | ~26 MB |

Windows 交叉编译不可行的根因：`my_app.exe` 是 **MSVC 编译的 C++ runner**，Linux 无 MSVC。Flutter 官方 [issue #110585](https://github.com/flutter/flutter/issues/110585) 开放 3 年未实现。详见 [§8](build-and-release.md)。

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

### 6.10 两端 UI 面板族的不对称（**有意保留的差异**）

同一个「查看这次对话的产出」诉求，两端的载体不同：

| 面板 | 桌面端 | 移动端 |
|---|---|---|
| 交付物（`GroupDeliverablesPanel`） | 侧边栏 tab | AppBar 按钮 → `showModalBottomSheet` |
| 待办（`GroupTodosPanel`） | 侧边栏 tab | AppBar 按钮 → `showModalBottomSheet` |
| 设置（`GroupSettingsPanel`） | 侧边栏 tab | 底部弹层 |
| 任务清单 / 目标历史 | 侧边栏 tab | 底部弹层（窄屏从**溢出菜单**进，见 [§6.16](ui.md)） |
| 对话内搜索 | AppBar 图标（`enableSearch: true`） | **溢出菜单**（窄屏无余量，见 [§6.15](chat.md) / [§6.16](ui.md)） |
| 动态（`GroupActivityPanel`：当前轮次状态 + 工具调用 + gate 决策） | 侧边栏 tab（**始终可见**） | AppBar 图标（宽屏）/ 溢出菜单（窄屏）→ 底部弹层，**不含 gate 决策**（见 [§6.54](ui.md)） |

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

**「动态」面板两端都有**（此前那个只在非发布构建出现的「诊断」tab 已被它取代，
`GroupDebugPanel` 连同 `showDebugPanelProvider` 一并删除，见 [§6.54](ui.md)）。仍不对称的是
**gate 决策那一栏**：移动端不订阅 `controller.gateDecisions`（既有行为），故传
`decisions: null` → 整块不渲染、工具列表占满高度。**不能传空列表**——那会渲染一个
「还没有 gate 决策」的空态，而真相是「本端没接这条数据」，两者视觉上无法区分。

弹层与页面**共用同一份 State**，但 `showModalBottomSheet` 是**独立 route**：页面的
`setState` 不会让它重建。故 router 用 `_activityTick`（`ValueNotifier<int>`）当刷新
哨兵，四个状态回调各 bump 一次——少了它，弹层打开后就冻在第一眼看到的样子，
而「实时的当前状态」正是这个面板存在的唯一理由。

### 6.11 桌面端托盘菜单（7 项）

`apps/spb_desktop/lib/desktop_integration.dart` 的 `_installTrayMenu` 推送 7 个可点项：

| 项 | 动作 |
|---|---|
| 显示主窗口 | `showWindow(main)` |
| 快速输入（Alt+Space） | 进悬浮模式（见 §6.5） |
| 立即同步交付物 | `onSyncNow`（未注入回调时禁用） |
| 打开同步目录 | `caps.revealPath(同步目录)`（**未配置同步目录时禁用**） |
| 同步设置… | `_openSyncSettings()` → `/settings?tab=sync`（见 [§6.53](sync.md)：同步已并入设置页） |
| 设置… | `_openSettings()` → `/settings`（见下「两个设置入口为什么都要有」） |
| 退出 | `PlatformDesktopQuit.quit` |

**「打开同步目录」为什么在未配置时禁用**：此时 `revealPath` 拿到空串，文件管理器
会落到用户主目录——看起来像「功能坏了」而不是「还没配」。

**「同步设置…」为什么走 `_router.go(SpbRoutes.settingsSyncTab)` 而不是
`showWindow(settings)`**：
`WindowRole` 只有 main / settings / quickCapture，没有 sync 这个角色——同步配置
是设置页里的一个**标签**（[§6.53](sync.md)），不是独立窗口。`showWindow(settings)` 只会落到
设置页首个 tab，用户还得自己再点一次「同步」，而托盘项的标签承诺的是直达。
（守则必须看 **query**：已在同步标签时不再 `go`、已在通用标签时必须真的切
过去。⚠️ **不要**把这个守卫的理由写成「否则会清掉草稿」——实测 `go()` 到
**相同** location 时 go_router 不重建页面（见 [§6.53](sync.md) 末段）。）

**「同步设置…」与「设置…」为什么两个都要有**（2026-10 补的第二个）：

它们是**不同目标**，不是重复项：

| 项 | 目标 | 内容 |
|---|---|---|
| 同步设置… | `/settings?tab=sync` | 同步执行（立即同步 / 回传改动）+ 目录 / 范围 / 媒体开关 / 单文件上限 / 本地清理 / 自动同步 |
| 设置… | `/settings`（首个标签） | 外观 / 个人偏好 / 桌面集成 / 导出诊断日志 / 账号 |

两个入口都指向 `/settings`，只是 `tab` 参数不同——**守卫不能只比 path**：
`_openSettings` 若只比 `uri.path == SpbRoutes.settings`，会把「已在同步标签」
当成「已在设置页」，把「设置…」变成死按钮（外观 / 个人偏好依然不可达）；
`_openSyncSettings` 同理要检查 `tab == 'sync'` 才算「已经在那儿」。
两个方向各有一条 `desktop_integration_test.dart` 用例钉住：「已在同步标签时
点设置…」与「已在通用标签时触发交付物同步…」。

⚠️ **但「已在同步标签时重复触发」不能写成用例**（实测纠正）：`go()` 到
**相同** location 时 go_router 本来就不重建页面（同一 location 再 go 一次，
页面 build 次数不变；query 变了才 +1）。所以一条「重复导航会清掉草稿」
的断言是**假绿**——把守卫删掉它也照样通过。那条守卫的真实作用只是「不做
多余的导航通告」，写注释时不能拿「保草稿」当理由（与 [§6.17](testing.md) / [§6.33](build-and-release.md) 同一
教训：**一个会在错误实现上变绿的用例，比没有用例更危险**）。

⚠️ 在此之前桌面端**没有任何 UI 入口能到 `/settings` 的通用标签**：托盘只有
「同步设置…」，列表 AppBar 也没有设置图标，而 `WindowRole.settings → /settings`
的映射虽然存在、生产代码里却**无调用方**（只有测试会 `showWindow(settings)`）。
于是外观 / 个人偏好 / 导出诊断日志在界面上完全不可达，只能靠深链。

**两个「始终可用」**：「同步设置…」与「设置…」都**不**依赖 `isSyncConfigured`
——它们正是**配置入口**，禁用会让未配置的用户无法完成配置（死锁）。
**「设置…」为什么直接 `_router.go` 而不走 `caps.showWindow(settings)`**：本类已持有
router，且 `WindowRole.settings` 的映射也在本类里（`_navigateToRole`）。绕一圈回到
自己的能力层会让「从悬浮窗切到设置要还原窗口」依赖桩实现是否转发 `onShowWindow`
——测试桩不转发，断言路由的用例就会莫名其妙地红。还原窗口仍必须做（见
`_openSettings` 里的 `_exitOverlayWindow()`）。

**设置页的另一个入口在对话列表 AppBar**（`GroupListPage.onOpenSettings`，
`Icons.settings_outlined`）：桌面端各应用都把设置放在主界面标题栏，托盘是辅助
入口。

移动端**现在也接**这个参数（2026-11，[§6.115](#6115-移动端去掉底部标签栏首页入口按频率分档2026-11)）：
去掉底部标签栏之后，`≡` 菜单是设置唯一入口，`check_wiring_parity.sh` 里那条
`exempt["desktop"]` 已随之删除。

---

### 6.115 移动端去掉底部标签栏：首页入口按频率分档（2026-11）

**结论**：移动端不再是「对话 / 设置」两个底部标签，**首页就是对话列表**；
目标存在两种载体（新建 / 待确认 / 搜索常驻，其余进 `≡` 菜单），而不是一间
「设置标签」加一间「对话标签」。

#### 为什么去掉

原来设置独占一个 shell 分支（`StatefulShellRoute.indexedStack`），代价与收益
不成比例：

| 成本 | 说明 |
|---|---|
| 一整层导航栈语义 | 分支栈 / `goBranch` / `isActive` 判据 / `NavigationBar` 底部安全区，只为「切标签时保留状态」 |
| 底部常驻一条 80dp 的条 | 挤掉列表可视区，而设置一天用不到一次 |
| `check_wiring_parity.sh` 的 `exempt["desktop"]` | `onOpenSettings` 被登记成「桌面端独有」，成了**永久的单端差异** |

收益只有一条「设置页草稿在切标签后仍活着」——而该保护本来就有 `PopScope`
（§6.53「草稿保护与首屏操作」），与标签无关。

#### 扁平化后的路由形状

```
/login /lock /qr-login      （shell 外，整屏）
/                          对话列表（唯一根）
├ chat/:groupId  ├ search  ├ confirmations  ├ my-turns  ├ habits  ├ memories   ← go（同级，返回回列表）
/settings(?tab=sync) /miniapp/works /overlay                                   ← push（整屏，返回恢复列表）
```

判据是**返回语义**而不是「页面层级」：同级衍生视图用 `go`（返回键回列表），
整屏功能页用 `push`（下层列表不销毁，滚动位置与已加载分页都保留）。

#### 入口分档（频率判据）

| 层 | 判据 | 内容 |
|---|---|---|
| primary（常驻图标） | 与「当前这页在干什么」直接相关 | 新建 / 待确认（带角标）/ 搜索 |
| `≡` 菜单（窄屏） | 跨对话的衍生视图 + 应用级功能 | 工作台 / 习惯 / 记忆 / 快速对话 / 设置 |
| 宽屏常驻（≥720dp） | 同上，只是有位置直接摆 | 同上五项 |
| 本端专属常驻 | 只有这个平台需要 | 桌面「刷新」（鼠标滚不出 `RefreshIndicator` 的 overscroll） |

⚠️ 「设置频率高」是本仓库明确**否决**的直觉：§6.88.3 实测 320dp + 系统字号
2.0 时 `Text('对话')` 宽度已经是 **0**，窄屏只有 3 个常驻位。设置是改一次管
几个月的低频项，进 `≡` 菜单（窄屏路径：`≡` → 「设置」，多一步）。

#### 新建入口：FAB（＋）取代 FAB（闪电）

| 载体 | 端 | 说明 |
|---|---|---|
| FAB `＋` | 移动端 | 最高频动作放拇指可达处；同时把窄屏 AppBar 的一个图标位让给搜索 |
| AppBar `＋` | 桌面端 | 标题栏是平台惯例；窗口没有「拇指可达」，FAB 会遮住列表最后一行 |

载体由 **`GroupListPage.createInFab` 显式声明**（`apps/spb_mobile/lib/router.dart`
传 `true`，桌面端用默认 `false`），**不读 `SpbTheme.isDesktopPlatform`**：
`flutter test` 的 `defaultTargetPlatform` 恒为 android，桌面端 router 用例会跑
到移动分支，而**断言不会红**（§6.88.3 记的是同一类假绿）。改坏的表现是
「桌面端两个 ＋」或「移动端点不到建新对话」。

**快速输入（原 FAB 闪电）移到 `≡` 菜单**（`menu-group-list-quick-capture`，宽屏
为常驻 `group-list-quick-capture`）：它保住了 §6.7 的「无归属入口两端各有一条
路径」——删掉这个入口会让 `/overlay` 在移动端彻底不可达（该页与端点都还在，
用户却碰不到）。

#### 代价（认下的）

- 窄屏进设置多一步（`≡` → 设置）；宽屏不受影响（≥720dp 常驻图标）。
- 列表页不再由 shell 常驻：从对话页 `push` 设置再返回，列表**实例**仍在
  （`push` 不销毁下层），但若是 `go` 到同级页再返回，列表会重建——滚动位置
  由 `PageStorage` 与 provider 缓存兜住，不额外做状态提升。
- `settings` 的 `PopScope` 成为**唯一**草稿保护；`router_layout_test` 里
  「切标签保留草稿」那条用例随之改写为「根路由返回确认后交回宿主」。

#### 守卫与用例

| 位置 | 内容 |
|---|---|
| `tools/check_wiring_parity.sh` | 删掉 `exempt["desktop"]` 的 `onOpenSettings`（两端都接）；新增 `GroupListPage` 的 `createInFab` 归 `mobile` 单端 |
| `apps/spb_mobile/test/router_list_test.dart` | 无 `NavigationBar`、FAB ＋ 建新对话、`≡` 菜单进快速输入/设置、`push` 设置后返回回来源页 |
| `apps/spb_mobile/test/router_settings_test.dart` | 习惯 / 记忆入口都挂在首页栈下（`NavigationBar` findsNothing） |
| `packages/spb_features/test/chat/group_list_page_test.dart` | 窄屏分档（新建不在 AppBar、五项都在菜单）+ `createInFab: false` 的桌面载体反向用例 |
