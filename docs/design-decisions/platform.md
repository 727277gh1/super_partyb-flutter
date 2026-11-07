# 桌面平台集成

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。平台能力层的坑：Windows 打开浏览器、文件管理器定位与下载布局、
主窗口尺寸自适应、Windows 托盘、关窗即隐藏。

> 编号（`§6.x` / `§5.x` / `[§7](build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](README.md)。

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
linux），所以这两个错误前提一直被固化着——与 [§6.21](testing.md) / [§6.26](testing.md) / [§6.33](build-and-release.md) 同一类
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
  ⚠️ 前提已部分变化：`dart:ffi` 让 Dart 侧能直接调 shell32，**定位**因此改走
  `SHOpenFolderAndSelectItems`（见 §6.75）；
  URL 打开仍保持 `rundll32`。
- **不改用 `Process.start(detached)`**：只判「能否 spawn」会丢失「命令确实失败」
  的信号，比误报失败更糟（用户会看到「什么都没发生」）。
- **不在 URL 分支做「打开了吗」的二次校验**：Windows 没有廉价可靠的探测手段
  （查默认浏览器进程、读注册表都不可靠且要额外依赖），收益不抵成本。

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
只改一端就会出现「桌面端修好了、移动端还在覆盖」——正是 [§6.17](testing.md) 接线守卫想防的
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
这正是 [§6.16](ui.md) 移动端宽屏搜索入口丢失的成因。

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
- **移动端不接定位**：注入的是 `NoopDesktopCapabilities`（[§6.10](architecture.md) 的取向：隐藏
  菜单项比「点了报错」好），但**下载布局仍与桌面端同构**——覆盖问题一样存在。

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
- **需真机验证**：本机无 `DISPLAY`（[§9](../development.md)），`xvfb-run` 下渲染不稳定，只能验证
  纯逻辑。真实缩放下的表现需在有桌面环境的机器上确认。

### 6.55 Windows 托盘：图标不显示 + 右键菜单卡死（2026-11）

用户报障两个叠加的 Windows 问题：托盘没有图标；托盘右键菜单弹出来后
「是一个卡住的列表」（点外面收不回去，看起来像应用死机）。

#### 缺陷 ①：托盘图标 —— `LoadImage` 不认 PNG

| 层 | 事实 |
|---|---|
| `tray_manager` Dart 端 | `setIcon('assets/tray_icon.png')` 会把路径拼成 `data/flutter_assets/assets/tray_icon.png` 传给平台 |
| `tray_manager` Windows 端 `SetIcon` | `LoadImage(nullptr, path, IMAGE_ICON, …, LR_LOADFROMFILE)` ——**只认 BMP 系资源**（`.bmp` / DIB 帧的 `.ico` / `.cur`），给它 PNG 返回 `NULL` HICON，`Shell_NotifyIcon` 挂着空图标 → **托盘上什么都没有** |
| 插件 `setIcon` 返回值 | **恒 `true`，不报错** → `_trayAvailable` 照样置位 → 「关窗即隐藏」照样生效 → 用户关窗后**没有任何办法唤回应用**（进程还在，图标没有，窗口没了） |

**修法**（三处协同）：

1. `tools/gen_brand_assets.py` 新增 `windows_runtime()`：生成
   `apps/spb_desktop/assets/tray_icon.ico`，**显式 `bitmap_format='bmp'`**
   ——PIL 的 ICO 默认输出是 **PNG 帧**（Pillow ≥ 9.1），PNG 帧的 `.ico`
   同样不被 `LoadImage` 认。尺寸只取 16/32（BMP 帧无压缩，256 单帧
   256 KB，而 `.ico` 整体打进二进制）。
2. `PlatformDesktopCapabilities` 新增 `trayIconAssetWindows`（默认
   `assets/tray_icon.ico`），`_initTray` 按 `HostPlatform.current()` 分流
   ——Linux/macOS 继续用同一张 64px PNG（appindicator / NSStatusItem
   都认 PNG）。
3. `apps/spb_desktop/pubspec.yaml` 声明 `assets/tray_icon.ico`。

⚠️ **运行时检测不了**：`Shell_NotifyIcon` 的 `NIM_ADD` 失败被插件内部吞掉，
Dart 侧拿不到「图标真的显示了吗」的信号。防御手段是资源本身（`.ico` 由
生成脚本落盘、`.gitattributes` 的 `*.ico binary` 禁转换），不是运行时检查。

#### 缺陷 ②：右键菜单卡死 —— `TrackPopupMenu` 前台要求

Win32 的 `TrackPopupMenu` 要求**调用窗口处于前台**，否则菜单弹出后点
外面收不回去（Raymond Chen 的经典条目；MSDN Remarks 专门写了这条）。
`tray_manager` 把修法暴露为 `popUpContextMenu(bringAppToFront:)`——该
参数**只在 Windows 实现**（README 明写），默认 `false`。我们没传，
于是 `PopUpContextMenu` 不调 `SetForegroundWindow` 直接 `TrackPopupMenu`
→ 卡死的菜单（2026-11 Windows 用户报障的原因）。

**修法**：

1. `spb_platform` 新增纯函数 `trayMenuNeedsBringToFront(HostPlatform)`
   ——Windows `true`，其余 `false`。平台判据必须可无头单测（本机无
   Windows，这条是 Windows 分支唯一自动化保障，与 `spawnSystemOpen`
   同一取向）。
2. `TrayActionTarget` 新增 `popUpTrayContextMenu()`；`PlatformDesktopCapabilities`
   实现它（带判据结果调 `tray_manager`；Linux 上 `popUpContextMenu`
   **未实现**，调用抛 `MissingPluginException` → catch 住记 debug，
   appindicator 的菜单由桌面环境自行展示）。
3. `onTrayIconRightMouseDown` 改为经 `popUpTrayContextMenu()`。

⚠️ `bringAppToFront` 在 tray_manager 0.5.3 标注了 deprecated
（"only supported on Windows and will be removed"）——但 Windows 上它
**恰恰是必需的**。显式 `// ignore: deprecated_member_use` 并注释：若将来
参数真被移除，需自写 `SetForegroundWindow`（插件 PR 或换库）。

#### 顺带修的第三个同根因问题：`windowManager.setIcon` 在 Windows 上帮倒忙

`window_manager` 的 Windows `SetIcon` 同样走 `LoadImage`——PNG 读出来是
`NULL` HICON，而 `WM_SETICON(ICON_SMALL/ICON_BIG, NULL)` 会**移除** exe
资源图标（`Runner.rc` 的 `IDI_APP_ICON`，win32_window.cpp 注册窗口类时
加载）。也就是说 `_initWindowIcon` 在 Windows 上不跳过比跳过更糟：
任务栏图标从「品牌图标」退回默认 Flutter 占位。现 Windows 分支直接
`return`（exe 资源已静态覆盖窗口图标；`.ico` 资源由生成脚本同步维护）。

#### 测试与反向验证

| 用例 | 钉住 |
|---|---|
| `packages/spb_platform/test/tray_bring_to_front_test.dart`（3 条） | windows=true / linux·macos·other=false |
| `apps/spb_desktop/test/desktop_integration_test.dart` +1 | `popUpTrayContextMenu` 可从能力层到达（接线断裂时本桩层无法感知——但接口不存在时编译器会报，故钉的是「右键处理仍调它」的前提） |

反向验证：`trayMenuNeedsBringToFront` 改恒 `false` → windows 用例失败；
改全平台 `true` → linux/macos 用例失败。图标修复的最终验证需 Windows
真机（本机无，AGENTS.md [§9](../development.md)）——但 `.ico` 帧格式已由脚本与
`file` 输出逐字节确认（`MS Windows icon resource … 24 bits/pixel`，
无 PNG 帧）。

#### 有意不做

- **不换 `system_tray` / `quick_window` 等其它托盘库**：换库是更大的面，
  tray_manager 的问题两处都已定点修掉。
- **不在 Dart 侧做「图标加载成功与否」的探测**：拿不到信号（见上），
  伪造探测只会增加假绿面。
- **不给 macOS 换 `.icns` 或调整托盘图标尺寸**：macOS 路径从未报障，
  与本次两个缺陷无关。
- **不改 `setHideOnClose` 的判定**：`_trayAvailable` 的语义（图标已创建）
  在资源正确的前提下成立；误置的风险源（PNG）已在资源侧消除。

### 6.63 「关窗即隐藏」从未生效：`close` 是通知，不是拦截（2026-11）

**症状**：Windows 用户点窗口关闭按钮，应用**直接退出**，托盘里也找不到。
期望是「隐藏到托盘、进程继续跑交付物同步，可从托盘或 `Alt+Space` 唤回」。

#### 根因：`onWindowClose` 里的 `hide()` 永远晚于原生侧的销毁

`_hideOnClose` 机制（`bootstrap.dart` 的 `onWindowClose` → `windowManager.hide()`）
一直在，`desktop_integration.dart` 也一直在 `tray.setHideOnClose(tray.trayAvailable)`——
**唯一缺的是 `setPreventClose`**。`window_manager` 的 `close` 事件是**通知**而不是
**拦截**：三平台原生侧的顺序都是「先异步派发 `close` 事件，再看 `isPreventClose()`
决定要不要继续关闭」。

| 平台 | 原生侧代码 | 不拦截的后果 |
|---|---|---|
| Windows | `WM_CLOSE` 分支：发 `close` 事件，然后 `if (IsPreventClose()) return -1;` | 落到 `DefWindowProc` → **销毁窗口** → 消息循环退出 → 进程结束 |
| Linux | GTK `delete_event` 回调 `return plugin->_is_prevent_close;` | 返回 FALSE → GTK 销毁窗口 |
| macOS | `windowShouldClose` 发 `close` 后返回 `isPreventClose()` | 返回 true → 窗口关闭 |

事件是**异步**投递到 Dart 的，故等 `hide()` 跑到时窗口**早已销毁**：

```
修复前：点关闭 → 原生派发 close → DefWindowProc 销毁窗口 → 消息循环退出 → 进程结束
        （Dart 的 hide() 永远来不及）
修复后：点关闭 → 原生派发 close → preventClose 为真 → return -1
        → 窗口保留 → Dart 的 hide() 把它从屏幕上收起来
```

即「关窗即隐藏」**从未真正生效过**（Linux 同理，只是没人报障）。这与 [§6.21](testing.md) /
[§6.33](build-and-release.md) / [§6.37](auth.md) 是同一失败模式：**`hide()` 确实被调用了、返回值也正常，所有门禁全绿**。

#### 修法（三处，缺一不可）

| 位置 | 改动 | 为什么 |
|---|---|---|
| `PlatformDesktopCapabilities.setHideOnClose` | 记 `_hideOnClose` 之后 `await windowManager.setPreventClose(value)`，try/catch + info/warn | 让原生侧真的**不**关闭，Dart 的 `hide()` 才有意义 |
| 契约 `TrayActionTarget.setHideOnClose` | `void` → `Future<void>` | 它做的是平台通道 I/O。留 `void` 就是 fire-and-forget，签名在**承诺**它异步完成却没有交付 |
| `quit()` | `destroy()` **之前** `setPreventClose(false)` | macOS 的 `destroy()` 是 `NSApp.terminate(nil)`，AppKit 在终止序列里会逐窗口问 `windowShouldClose:`，**任一返回 NO 就取消终止** → 托盘「退出」在 macOS 上会变成死按钮 |

`desktop_integration.dart` 的调用点用 `unawaited(...)`（`_installTrayMenu` 是同步的，
失败已在能力层记 warn 并降级成「关窗即退出」）。`attach()` 发生在首帧之前，
故不存在「用户抢在通道返回前点了关闭」的竞态。

**`quit()` 仍能退出**：`destroy()` 在 Windows 是 `PostQuitMessage`（与
`is_prevent_close_` 无关）、Linux 自己先把 `_is_prevent_close` 置 false 再
`gtk_window_close`、macOS 是 `NSApp.terminate`。故拦截关闭不会把用户困住。

#### 为什么 `_hideOnClose=false` 时必须把 preventClose 也关掉

一律拦截而托盘没起来（Linux 无 appindicator、Flatpak 沙箱），用户点关闭会得到
一个「既没退出、也没有任何入口」的僵尸进程。`desktop_integration.dart` 的
`tray.setHideOnClose(tray.trayAvailable)` 这条守卫（[§6.11](architecture.md)）只有配上「preventClose
镜像该值」才完整。

#### 唤回路径（本来就有，无需新增）

| 入口 | 链路 |
|---|---|
| 托盘左键 | `onTrayIconMouseDown` → `showWindow(WindowRole.main)`（show + focus，幂等、不 toggle） |
| 托盘菜单「显示主窗口」 | `TrayActionIds.show` → 同上 |
| `Alt+Space` | `_onHotkeyPressed('quickCapture')` → `showWindow(quickCapture)` → `_navigateToRole` → `/overlay`（注册失败只 warn——`Alt+Space` 常被系统占用） |
| 托盘菜单「快速输入」 | `TrayActionIds.quickCapture` → 同上（快捷键被占用时的鼠标兜底） |

#### 关窗相关日志一律 `info`

`SpbLog` 默认 `minLevel = info`，debug 在生产被过滤（[§6.43](sync.md) 的同一教训）。关窗是
低频操作，三条都记 info 不刷屏：`关窗行为已设置` / `关闭主窗口：隐藏到托盘…` /
`关闭主窗口：未启用隐藏到托盘，按默认行为退出`。**后者尤其重要**——原生侧一旦
销毁窗口，Dart 就再没有机会记录任何东西，那条日志是「这次关窗到底退出了没有」
的唯一线索（[§6.57](runtime-and-ops.md) 的会话标记同一取向）。

#### 测试（`window_close_test.dart`，6 条）

`PlatformDesktopCapabilities` 的构造函数只存资源路径、不碰通道，故可以**直接构造**
再 mock `MethodChannel('window_manager')`（`bootstrap.dart` 其余部分确实无法在无头
环境构造，[§6.57](runtime-and-ops.md) 同一取向）。断言的是**通道上到底发了什么**——这是唯一能钉住
「拦截是否真的打开」的观测面。

| 用例 | 钉住 |
|---|---|
| `setHideOnClose(true)` 打开 preventClose | 通道收到 `setPreventClose` 且 `isPreventClose == true` |
| `setHideOnClose(false)` 关闭 preventClose | 托盘不可用时必须允许关窗退出 |
| `onWindowClose` 启用时隐藏且不销毁 | 有 `hide`、**没有** `destroy` |
| `onWindowClose` 未启用时不做窗口操作 | 既不 `hide` 也不 `destroy`（让原生按默认行为退出） |
| 通道不可用时不抛 | 降级为「关窗即退出」，应用仍可用 |
| `quit()` 先关 preventClose 再 destroy | 两个调用的**顺序** + 参数为 false（macOS 退出） |

#### 反向验证（逐条实测）

| 改坏 | 失败用例 |
|---|---|
| 去掉 `setPreventClose(value)`（复现原缺陷） | **2**（true / false 两条） |
| 去掉 `quit()` 里的 `setPreventClose(false)` | **1**（顺序断言） |

#### 有意不做

- **不在 `onWindowClose` 里想办法赢过原生关闭**：事件是异步的，这条路**结构上**
  走不通。唯一正确的点是让原生侧别继续关闭。
- **不把 `setPreventClose` 硬编码成 true**：它必须镜像 `_hideOnClose`，否则托盘
  不可用时得到僵尸进程（见上）。
- **不做托盘左键 toggle（已显示则隐藏）**：现有语义是幂等 show（[§6.5](architecture.md) 的
  `showWindow`）。toggle 会让「双击托盘」在窗口已显示时把它收起来，而那看起来
  像「点没了」。
- **不给 Windows 做「隐藏后自动最小化到托盘气泡提示」**：需要额外通知依赖，
  而窗口从任务栏消失本身就是足够信号（`ShowWindow(SW_HIDE)` 在 Windows 上
  同时移出任务栏——这正是 hide-on-close 必须以 `trayAvailable` 为前提的原因）。

#### 已知边界

- **需 Windows 真机验证**（本机无 Windows，[§8](build-and-release.md)/[§9](../development.md)）：无头测试钉的是通道层的
  调用事实，「关窗后托盘图标在、左键能唤回」必须在有桌面环境的机器上确认。
- **`_trayAvailable` 在 Windows 上可能误置 true**：`tray_manager` 的 `setIcon`
  恒返回 true（§6.55 已记录），故图标资源形态错时 hide-on-close 仍会启用而
  图标不显示。防御手段是资源本身（`.ico` 由生成脚本落盘），不是运行时检测。

### 6.68 悬浮输入窗「一大片空白」：窗口高度按最坏情况写死 + 按钮行被 Expanded 撑开（2026-11）

**症状**：桌面端按 `Alt+Space` 唤出快速输入窗，窗口是 720×360，而内容只有
一行输入 + 一行按钮——中间和下方各留一大片空白，按钮悬在空白正中。移动端
同一页面占满全屏时，「取消/发送」也浮在屏幕中部。

#### 根因：两个独立成因叠加

| # | 层 | 事实 |
|---|---|---|
| ① | 窗口尺寸 | `WindowSpec.quickCaptureWithAttachments.height` 写死 **360**，按「附件 chip 一行 + 四行输入 + 状态/按钮行」的**最坏情况**预留。纯文本场景内容只有约 **130** → 2/3 是空白 |
| ② | 页面布局 | `overlay_quick_capture_page.dart` 的 `Expanded(child: _buildFooter(...))` 把 footer 的 `Row` 本身撑满剩余高度，而 `Row` 默认 `crossAxisAlignment.center` → 按钮行浮在剩余空间的正中，上下各一大片空白 |

②让空白**可见**：`DecoratedBox` 用 `scheme.surface` 铺满整个窗口（Scaffold 的
`transparent` 被它盖住），于是那片空白是一块实心卡片色，而不是「透明的窗口」。

#### 修法：窗口贴合内容（页面报高度 + 能力层改窗口高度）

| 位置 | 改动 |
|---|---|
| `spb_features` 页面 | 新增 `onContentHeight` 回调。接线时布局切成「卡片高度 = 内容高度」：`Column(mainAxisSize.min)` 外面套 `SingleChildScrollView`（给**无界**高度，才量得到自然高度，也才能在超过上限时滚动），由 `_ContentHeightReporter` 上报 |
| `spb_platform` | 新增 `fitOverlayWindowHeight`（向上取整 + 夹 `[kOverlayMinWindowHeight=132, kOverlayMaxWindowHeight=480]`）与 `OverlayWindowController.fitOverlayContentHeight` |
| `spb_desktop` bootstrap | 实现 `fitOverlayContentHeight`：实测「外框 − 客户区」高度差（Linux `gtk_window_resize` 是 client area，Windows `SetWindowPos` 是含标题栏的外框），加进内容高度后再夹取；按目标高度去重，避免每次上报都 `setSize` |
| `spb_desktop` router | `/overlay` 把页面的 `onContentHeight` 转给能力层（fire-and-forget，失败只影响观感） |
| `WindowSpec` | 进入时高度改为**最小值**（132），`resizable: false`——自动贴合下用户拖出来的高度会被下一次内容变化改回去，表现像「窗口自己乱跳」 |

未接线（移动端 / 主窗口内的调试入口）时保持「卡片铺满视口」的全屏布局，
但按钮行改为 `Expanded(Align(bottomCenter))` **贴底**——`Expanded` 直接包 Row
正是 ② 的来源。

#### 为什么高度要「实测外框」而不是写死标题栏高度

`window_manager.setSize` 的语义按平台分裂（见上表）。写死「标题栏约 32px」在
Linux 上就多留 32px 空白——**正是本次要修的那个观感问题**。故用同一时刻的
两个可观测量相减：`windowManager.getSize()` 与 Flutter 视图的逻辑高度
（`physicalSize / devicePixelRatio`）。Linux 上差为 0，Windows 上差就是标题栏
+ 边框；取不到合理值（> 200 或负数）时按 0 处理且不缓存，下次重测。

#### 为什么用「布局通知 + 首帧自报」而不是在每个 `setState` 处上报

内容高度会因打字换行、增删附件 chip、提示行/进度行出现、系统字体与 DPI 变化
而变。逐处手动上报必然漏一处，漏掉的表现是「窗口比内容矮，底部按钮被裁掉」
或「窗口比内容高，卡片里又出现空白」。

⚠️ `SizeChangedLayoutNotifier` **明确不在首次布局派发通知**（其源码注释：
「Don't send the initial notification」），只靠它窗口永远不会贴合。故
`_ContentHeightReporter` 在 `initState` 里另排一次 post-frame 上报。

#### 测试

| 位置 | 钉住 |
|---|---|
| `packages/spb_platform/test/overlay_window_state_test.dart` | 取整方向、上下限夹取、NaN/∞ 不产生异常窗口高度、量程可覆盖（5 条） |
| `packages/spb_features/test/quick_capture/overlay_quick_capture_page_test.dart` | 首帧就上报且报的是**内容**高度（< 400，不是 600 的视口）；加附件后上报变大；矮窗口（600×100）不溢出且仍报真实高度；未接线时按钮贴底（4 条） |
| `apps/spb_desktop/test/router_overlay_test.dart` | **从路由进入** `/overlay`，断言能力层收到合理的内容高度（页面自己的测试传自己的回调，测不到 router 漏接线） |
| `apps/spb_desktop/test/desktop_integration_test.dart` | 进入用的 spec 宽度 720（带附件规格）且高度 ≤ 下限 |

#### 反向验证（实测）

| 改坏 | 失败用例（实测） |
|---|---|
| router 删掉 `onContentHeight` 接线（页面照旧上报，但没人转发） | `router_overlay_test` **1** 条 |
| fit 分支改回「卡片铺满视口」（`mainAxisSize.max` + 无滚动视图，即修复前的布局） | 页面 **3** 条（上报变成 576 的视口高度、加附件不再变大、矮窗口溢出）+ `router_overlay_test` **1** 条 |
| 页面恢复 `Expanded(child: footer)`（不贴底） | 页面「按钮行贴底」**1** 条 |
| 去掉 `initState` 里的首帧上报（只留 `SizeChangedLayoutNotifier`） | 页面 **3** 条 + `router_overlay_test` **1** 条 |

#### 已知边界

- **需真机验证**（本机无 `DISPLAY`，[§9](../development.md)）：`xvfb-run` 只能证明窗口能创建，
  证明不了「贴合后的高度看起来对」；Windows 的外框实测（`getSize` 与视图尺寸
  同一时刻）需在 Windows 上确认。
- **贴合发生在窗口可见之前**：进入悬浮模式时窗口是隐藏的（见本文件 §6.69），
  内容高度的首次上报与 `setSize` 都在隐藏状态下完成，`revealOverlayMode` 才让
  窗口出现——用户看不到「先小后长」。若首帧上报晚于 reveal（或上报失败），
  兜底仍是「先最小值、下一次内容变化再长高」；此时下方可能露出一条底色，故
  贴合模式下 Scaffold 用不透明 `scheme.surface`，不透出窗口原生背景。
- **上限 480 是产品判断**：超过后内容区滚动而不是继续长高——否则拖入十几个
  附件会把悬浮窗拉长到盖住半个屏幕。
- **不引入 `IntrinsicHeight`**：那能在一个布局 pass 内既「铺满视口」又「贴底」，
  但代价是额外测量与它的已知性能坑；这里用「两套布局 + 回调」换掉它。

### 6.69 悬浮窗「不打扰」：进入时先缩小再跳、退出时弹出主窗口（2026-11）

**症状**（Windows 用户报障）：

1. 按 `Alt+Space`，先看到**主窗口被缩小、跳到别处**，然后才变成快捷输入窗；
2. 记完关掉快捷窗，**原先的主窗口自己弹出来**，把正在用的应用顶掉。

第 2 点把「快捷记一笔」变成了「切换应用」——与这个功能的全部意义相反。

#### 根因：三处顺序/取舍错误，彼此独立

| # | 位置 | 事实 |
|---|---|---|
| ① | `showWindow` | 先 `windowManager.show() + focus()`，再回调 `_onShowWindow` → `_navigateToRole`。于是「全尺寸主窗口到前台」是进入悬浮模式的**第一步**（快捷键与托盘「快速输入」都走这里） |
| ② | `enterOverlayMode` | 在**可见**窗口上逐步改最小尺寸 → 尺寸 → 置顶 → 去任务栏 → 位置。每一步都立刻重绘：用户看到「缩小 → 跳位 → 被页面覆盖」三帧 |
| ③ | `exitOverlayMode` | **无条件** `show() + focus()`；而且从未快照 `isVisible`，「进入前主窗口在托盘里」这个事实根本不存在 |

#### 修法：先隐藏 → 改属性 → 导航 → 再显示；退出按「进入前的可见性」收尾

| 位置 | 改动 |
|---|---|
| `showWindow` | `quickCapture` 且**尚未**处于悬浮模式时跳过预显示（窗口由下面的 reveal 负责出现）。已在悬浮模式时仍然 show+focus——用户再按一次快捷键就是「我要看到它」 |
| `enterOverlayMode` | 快照新增 `wasVisible` / `wasMinimized`；**第一步 `hide()`**，之后所有属性改写都在隐藏状态下进行；不再 `show()` |
| `revealOverlayMode`（新） | 导航之后、**等一帧**（`addPostFrameCallback`，120ms 超时兜底）再 `show() + focus()`：窗口一次成型地出现在用户面前 |
| `exitOverlayMode({showMainWindow})` | 先 `hide()` → 还原属性 → 按进入前状态收尾：可见 → show+focus；最小化 → `minimize()`；隐藏 → **保持隐藏**。`showMainWindow: true` 用于「用户明确要求看某个页面」的路径 |

#### 为什么「不显示」就等于「把焦点还回去」

Windows 把前台窗口的隐藏当作一次激活移交：当前台窗口被隐藏时，系统激活 Z 序上的
下一个窗口——对悬浮窗来说就是用户按 `Alt+Space` 之前正在用的那个应用。Linux
（GTK + XFCE/KWin）同样把焦点退回上一个活动窗口。

故**不需要**去抢焦点：既不调 `window_manager.blur()`（它的实现是「Z 序下一个可见
窗口」，与系统自己做的事重合，还可能选中一个不相干的窗口），也不需要引 `win32` 的
`SetForegroundWindow`（它有前台锁限制，在窗口已隐藏后常被系统拒绝）。

#### 单窗口模型下做不到的事（别把它当缺口）

**「可见、能打字、但不激活本进程」做不到。** 键盘输入只会送到前台窗口，
`WS_EX_NOACTIVATE` 那种「不抢焦点的悬浮窗」只能显示不能输入。真要那样只能换
`desktop_multi_window`——已否决（[§6.5](architecture.md)：每个窗口是独立 isolate，
Riverpod / Dio / 认证状态都不共享，等于重做一遍装配）。

所以这里的目标是**观感上的不打扰**：不给用户看中间态、退出后不留痕迹。

#### 测试

| 位置 | 钉住 |
|---|---|
| `apps/spb_desktop/test/overlay_window_mode_test.dart` | 通道级（mock `window_manager` + `screen_retriever`）：`hide` 早于任何改尺寸/位置；进入阶段**不** `show`；reveal 才 show+focus；退出四态（托盘→保持隐藏、可见→show、最小化→minimize、`showMainWindow:true`→强制 show）；`showWindow(quickCapture)` 未进入时不预显示、已进入时仍 show（11 条） |
| `apps/spb_desktop/test/desktop_integration_test.dart` | 接线级：**先导航后显示**（时间线断言）；`leaveOverlay` 传 `showMainWindow: false`；切到设置传 `true` |

#### 反向验证（实测）

| 改坏 | 失败用例（实测） |
|---|---|
| `showWindow` 恢复无条件预显示 | 通道级 **1** 条 |
| 进入时不 `hide()`（在可见窗口上改属性） | 通道级 **1** 条 |
| 退出恢复无条件 `show()+focus()` | 通道级 **2** 条（托盘/最小化） |
| router 删掉 `revealOverlayMode` 调用 | 接线级 **1** 条 |
| reveal 挪到导航**之前** | 接线级 **1** 条 |
| 切页面退出不传 `showMainWindow: true` | 接线级 **1** 条 |

#### 已知边界

- **需真机验证**（本机无 Windows/`DISPLAY`）：①「先隐藏再显示」后，用户是否真的
  看不到中间态；② 退出后焦点是否回到原应用。诊断线索：日志
  `退出悬浮输入窗模式 {restore: show|minimize|stay_hidden, was_visible: …}`。
- **隐藏窗口上是否照常产帧**属引擎/窗口系统细节（Windows 通常照常），故 reveal 前
  等一帧有 120ms 超时兜底：押死「等帧」的风险是窗口永不出现，那比「一帧旧内容」
  严重得多。
- **失败路径仍然会显示窗口**：`enterOverlayMode` 失败时 `_rollbackOverlay()` 无条件
  `show()`。理由是「按了快捷键什么都没发生」比「意外弹出主窗口」更难排查；
  进入失败本身已是异常路径。
- **进入前最小化**的状态还原用 `minimize()`（不经过 `show()`），若某平台对隐藏窗口
  的 `minimize()` 无效果，结果是「窗口留在托盘里」——仍然是「不打扰」的方向。

### 6.75 Windows「定位/打开交付物」落在默认视图：explorer 不吃混合分隔符（issue #97，2026-11）

**症状**：Windows 上交付物面板 / 时间线文件卡的「在文件管理器中定位」每次
都打开**此电脑**，「用默认程序打开」每次落到**文档**目录。Linux/macOS 正常，
且全程无任何报错提示。

#### 根因：explorer 的兜底行为 × 混合分隔符路径

explorer.exe 收到**无法解析**的参数时不报错，直接打开它的默认视图——
`/select,…` 解析不了 → 此电脑；普通路径解析不了 → 文档。而它的退出码
成功失败都是 0/1 难分（§6.35），
客户端把 `{0,1}` 都判成功——所以「失败」在客户端侧完全不可见。

为什么参数解析不了：Windows 上交付物路径**必然**是混合分隔符：

| 链路 | 拼法 |
|---|---|
| 下载 | `p.join(支持目录, rel)`，`rel` 来自 `deliverableDownloadRelPath`（`gidA/reports/spec.md`）——`p.join` 只补**段间**分隔符，不转换段内部 |
| 同步索引 | 打开侧 `p.join(root, rel)`；落盘侧 `resolveWithinRoot` 也是 `/` 拼接 |

结果形如 `C:\...\deliverables\gidA/reports/spec.md`。`dart:io` / Win32
文件 API 对 `/` 宽容 → **存在性校验全部通过**，spawn 照常发生；explorer
的命令行解析不宽容 → 打开默认视图。

#### 缺陷二：`/select,` 的引号位置 argv 表达不出来

路径含空格时，正确形态是 `/select,"C:\a b\f.md"`（引号只包路径）；
而 `Process.run` 会把**整个 argv** 加引号 → `"/select,C:\a b\f.md"`。
Dart 不提供原始命令行注入，argv 方式无解。

#### 修法（两层）

| 层 | 改动 |
|---|---|
| `spb_platform` `system_open.dart` | 新增纯函数 `normalizeWindowsPath`（分隔符统一 / 折叠 / 词法解析 `.`·`..`，对齐 Win32 的钳根行为）；`spawnSystemOpen` / `spawnSystemReveal` 的 Windows 分支 spawn 前一律归一化，**归一化失败放弃 spawn**（返回 false 而不是把原串递给 explorer） |
| `spb_platform` `windows_reveal.dart`（新增） | Windows 定位首选原生 `SHOpenFolderAndSelectItems`（经 `dart:ffi`，`Shell32RevealBackend`）：直接吃 PIDL，没有命令行解析层，空格与分隔符歧义都不存在；失败/不可用回退 `explorer /select,<归一化路径>` |

定位的降级链：**原生成功 → 返回；原生失败/不可用 → `explorer /select,`**。
打开（目录 / 默认程序）继续用 `explorer <归一化路径>`——普通路径参数整体加
引号恰好就是正确形态，不需要原生 API。

#### 为什么引 FFI（之前 §6.35 说「不改用 ShellExecuteW」）

§6.35 当时的前提是「ShellExecuteW 需要平台通道，Dart 侧拿不到」——`dart:ffi`
让这个前提不再成立。但结论只更新一半：**定位**改用原生 API（argv 确实无解），
**打开**保持 `rundll32`（URL）+ `explorer`（路径）——那条链路在真机验证过
（§6.35），且归一化后已无歧义，换 `ShellExecuteW` 收益不抵验证成本。

#### 测试与验证边界

| 用例 | 钉住 |
|---|---|
| `normalizeWindowsPath`（9 条） | 混合→原生 / 全 `/` / 折叠 / `.`·`..` 词法解析+钳根 / 根与尾分隔符 / UNC 保留 / null 拒收集 |
| `spawnSystemOpen` Windows（3 条） | 归一化后 spawn / 归一化失败不 spawn / URL 分支不做分隔符替换 |
| `spawnSystemReveal` Windows（6 条） | 原生优先且收到归一化路径 / 原生 false → 回退 / 原生抛异常 → 回退 / 归一化失败两头都不调 / 默认后端是真实实现 / linux·macos 不调后端 |
| `revealSystemEntry`（1 条） | 后端注入从能力层透传到定位 |

⚠️ **验证边界（诚实记录）**：本机无 Windows（[§9](../development.md)）。
归一化与降级链全部可无头单测；`SHOpenFolderAndSelectItems` 的真机行为
（COM 初始化路径、真机 HRESULT）只有 Windows 用户能确认——FFI 绑定按
MSDN 签名手写，真机报障先看日志里的 `hr=0x...` 字段。

#### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| `spawnSystemOpen` Windows 分支去掉归一化 | 「打开：混合分隔符」用例失败 |
| `normalizeWindowsPath` 对归一化不了的输入返回原串 | 「打开：归一化不了」失败 |
| `spawnSystemReveal` 不先试原生后端 | 「定位：首选原生 API」失败 |
| 原生失败不回退命令行 | 「原生返回 false → 回退」失败 |
| URL 分支也做分隔符替换 | 「URL 分支不受归一化影响」失败 |
| 默认后端改成 `null` 就跳过 | 「默认后端是真实实现」失败 |

#### 有意不做

- **不替换 URL 打开链路**（`rundll32`）：§6.35 真机验证过，见上。
- **不给「打开」换 `ShellExecuteW`**：归一化后已无歧义，真机验证成本 > 收益。
- **不让 `normalizeWindowsPath` 返回「尽力归一化的原串」**：归一化不了的输入
  递给 explorer 就是缺陷形态本身；显式失败（提示「无法定位」）好于静默打开
  错误窗口。
