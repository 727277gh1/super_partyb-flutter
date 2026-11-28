# 设计决策索引（§6）

`AGENTS.md` 的 §6「关键设计决策」按主题拆到本目录。**编号全局稳定**：`§6.43`
永远指同一件事，只是换了文件——这样代码注释、脚本、CI 里的引用不会随拆分失效。

> **新增决策写在这里，不要写回 `AGENTS.md`。** 那个文件每次请求都被全文注入
> 上下文，它的体积就是预算（`tools/check_agents_size.sh` 守着）。本目录按需读取。

主题与小节索引统一在本文件维护；新增主题文件需在下表添加相对链接，
`tools/check_agents_size.sh` 检查是否漏项。

读之前先看 [`AGENTS.md`](../../AGENTS.md) 的 §3（结构）与 §4（分层规则）：
那些是「代码该放哪」的判据，不需要再跳一层。

| 主题 | 文件 | 包含 |
|---|---|---|
| [架构与关键取舍](architecture.md) | `architecture.md` | §6.1 §6.2 §6.3 §6.4 §6.5 §6.6 §6.8 §6.10 §6.11 §6.115 §6.120 |
| [对话与流式](chat.md) | `chat.md` | §6.7 §6.14 §6.15 §6.18 §6.23 §6.28 §6.28.1 §6.48 §6.50 §6.56 §6.58 §6.64 §6.65 §6.66 §6.85 §6.86 §6.92 §6.94 §6.105 §6.106 §6.107 §6.108 §6.110 |
| [交付物同步](sync.md) | `sync.md` | §6.42 §6.43 §6.52 §6.53 |
| [认证与会话](auth.md) | `auth.md` | §6.34 §6.36 §6.37 §6.39 §6.67 §6.71 §6.90 §6.91 §6.97 §6.98 §6.100 §6.103 §6.104 |
| [桌面平台集成](platform.md) | `platform.md` | §6.35 §6.41 §6.45 §6.55 §6.63 §6.68 §6.69 §6.75 §6.117 |
| [界面与交互](ui.md) | `ui.md` | §6.16 §6.32 §6.38 §6.40 §6.44 §6.46 §6.51 §6.54 §6.62 §6.70 §6.76 §6.77 §6.78 §6.79 §6.80 §6.81 §6.82 §6.83 §6.88 §6.89 §6.91 §6.118 §6.119 |
| [测试与仓库守卫](testing.md) | `testing.md` | §6.13 §6.17 §6.19 §6.21 §6.22 §6.24 §6.25 §6.26 §6.27 |
| [构建、分发与发布](build-and-release.md) | `build-and-release.md` | §6.29 §6.30 §6.31 §6.33 §6.61 §6.87 §6.93 §6.101 §7 §8 |
| [产品边界与可运维性](runtime-and-ops.md) | `runtime-and-ops.md` | §6.9 §6.12 §6.20 §6.49 §6.57 §6.99 §6.102 §6.109 §6.111 |
| [性能与内存](performance.md) | `performance.md` | §6.47 §6.59 §6.60 §6.72 §6.73 §6.74 §6.96 |

## 全部小节

| 编号 | 标题 | 文件 |
|---|---|---|
| §6.1 | 实时流统一用 SSE，**禁止引入 WebSocket** | [`architecture.md`](architecture.md) |
| §6.2 | 契约生成 vs 手写 | [`architecture.md`](architecture.md) |
| §6.3 | 状态管理：Riverpod | [`architecture.md`](architecture.md) |
| §6.4 | 桌面能力隔离 | [`architecture.md`](architecture.md) |
| §6.5 | 多窗口：`window_manager` 不行，但可另选插件（M0 结论） | [`architecture.md`](architecture.md) |
| §6.6 | 桌面端相对 Tauri 的净损失 | [`architecture.md`](architecture.md) |
| §6.7 | 无归属入口：两端统一走 enqueue | [`chat.md`](chat.md) |
| §6.8 | 剪贴板文件粘贴（**三平台均已实现**） | [`architecture.md`](architecture.md) |
| §6.9 | 有意不做的管理面端点族（**是决策，不是缺口**） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.10 | 两端 UI 面板族的不对称（**有意保留的差异**） | [`architecture.md`](architecture.md) |
| §6.11 | 桌面端托盘菜单（7 项） | [`architecture.md`](architecture.md) |
| §6.12 | i18n：**当前不做**（决策记录，issue #23） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.13 | 覆盖率与 golden 测试（issue #25） | [`testing.md`](testing.md) |
| §6.14 | 失败 turn 的重发（`ErrorItem` → 重新投递） | [`chat.md`](chat.md) |
| §6.15 | 对话内搜索（搜已加载的时间线，**非**服务端检索） | [`chat.md`](chat.md) |
| §6.16 | 窄屏 AppBar 溢出（issue #31） | [`ui.md`](ui.md) |
| §6.17 | 两端接线一致性守卫（issue #33/#39/#42） | [`testing.md`](testing.md) |
| §6.18 | `_rowKeys` 的注册与回收（issue #39） | [`chat.md`](chat.md) |
| §6.19 | AGENTS.md 标识符引用守卫（issue #37） | [`testing.md`](testing.md) |
| §6.20 | 诊断日志导出（issue #40，**第一层已实现**） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.21 | 生成物漂移守卫（issue #43） | [`testing.md`](testing.md) |
| §6.22 | SSE 传输层测试 + 一个真实的数据损坏缺陷（issue #41） | [`testing.md`](testing.md) |
| §6.23 | 流式归约合并（issue #44）——**并纠正 issue 里的一个错误方案** | [`chat.md`](chat.md) |
| §6.24 | 全局错误兜底与静默吞异常（issue #45） | [`testing.md`](testing.md) |
| §6.25 | 文档数字守卫与真实标识清理（issue #46） | [`testing.md`](testing.md) |
| §6.26 | 工程卫生批量（issue #47） | [`testing.md`](testing.md) |
| §6.27 | 测试文件拆分与「真实等待」的实测纠正（issue #48） | [`testing.md`](testing.md) |
| §6.28 | 零调用者端点的契约测试——**并查出第二个同类缺陷**（issue #49） | [`chat.md`](chat.md) |
| §6.28.1 | 归属反馈「点了没反应」：两个叠加的缺陷（2026-10） | [`chat.md`](chat.md) |
| §6.29 | 开源镜像同步（`tools/sync-to-github.sh`） | [`build-and-release.md`](build-and-release.md) |
| §6.30 | CI 基础镜像固定与 action 运行时升级 | [`build-and-release.md`](build-and-release.md) |
| §6.31 | 生产部署接线：public client、release.yml 的两个缺陷、tbcc6 判定 | [`build-and-release.md`](build-and-release.md) |
| §6.32 | 品牌图标：真源在 super_partyb，43 个文件由脚本生成 | [`ui.md`](ui.md) |
| §6.33 | CI 产物也用 127.0.0.1：构建参数没传（2026-10 真实缺陷） | [`build-and-release.md`](build-and-release.md) |
| §6.34 | 会话失效 → 回登录页（`AuthInterceptor.onSessionExpired`） | [`auth.md`](auth.md) |
| §6.35 | Windows 打不开浏览器：`explorer` 既吃不下带 query 的 URL，成功也返回 1 | [`platform.md`](platform.md) |
| §6.36 | 登录成功后停在登录页：`signIn()` 把已登录盖回 `unknown` | [`auth.md`](auth.md) |
| §6.37 | 登录成功后立刻「会话已失效」：把不透明 `access_token` 当 Bearer | [`auth.md`](auth.md) |
| §6.38 | Windows 上「门」显示畸形：主题从未指定 CJK 字体 | [`ui.md`](ui.md) |
| §6.39 | 放置一段时间后被登出、关闭重开又正常：一次断网被当成「凭证失效」 | [`auth.md`](auth.md) |
| §6.40 | 新建对话不需要输入标题（用默认占位 `新对话`） | [`ui.md`](ui.md) |
| §6.41 | 「在文件管理器中定位」全平台失效 + 下载平铺覆盖（2026-10） | [`platform.md`](platform.md) |
| §6.42 | 自动同步：可配置的启动 / 周期 / 进对话按需（2026-10） | [`sync.md`](sync.md) |
| §6.43 | 进入对话时按需同步（2026-10）：判定 → 提示条 → 用户点 | [`sync.md`](sync.md) |
| §6.44 | 进入对话后 AppBar 显示对话名（2026-10） | [`ui.md`](ui.md) |
| §6.45 | 主窗口尺寸按屏幕工作区自适应（2026-10） | [`platform.md`](platform.md) |
| §6.46 | 侧边栏收起不销毁子树（滚动位置 / 选中 tab 保留，2026-10） | [`ui.md`](ui.md) |
| §6.47 | 流式对话性能：观测手段与已确认的成本项（2026-10） | [`performance.md`](performance.md) |
| §6.48 | 「多轮之后查看大块正文时向下滚动丢内容」（2026-10） | [`chat.md`](chat.md) |
| §6.49 | 同步 partyb 的 reminder 准入重构：群级开关 → 个人运行时开关（2026-11） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.50 | 发送的乐观回显与 pending（「发送中」）生命周期（2026-11，issue #52） | [`chat.md`](chat.md) |
| §6.51 | 长正文滚到中途整块消失：移除正文的整行绘制缓存（待设备复核） | [`ui.md`](ui.md) |
| §6.52 | 进入 group 的 UFS 同步：完整判定、失败重试与任务串行化 | [`sync.md`](sync.md) |
| §6.53 | 同步页并入设置页：两个标签（2026-10） | [`sync.md`](sync.md) |
| §6.54 | 时间线工具调用折叠 + 「动态」面板 + 流式进度条（2026-11） | [`ui.md`](ui.md) |
| §6.55 | Windows 托盘：图标不显示 + 右键菜单卡死（2026-11） | [`platform.md`](platform.md) |
| §6.56 | group 用量（token 消耗）展示：REST 权威 + SSE 增量 + 重连对账（2026-11，对齐 Go `4a05176c` / `20874489`） | [`chat.md`](chat.md) |
| §6.57 | 桌面端可诊断性：本地文件日志 + 会话标记 + 悬浮窗失败回滚（2026-11） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.99 | 通知统一消费站内事实：PWA/SPBF 类型、已读、版本判重与展示对齐（2026-11，issue #120） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.58 | 归属提示重构：`routing_selected` 合并进气泡，无聊原因零空间（2026-11） | [`chat.md`](chat.md) |
| §6.59 | 内存审计与处置（2026-11）：无界集合加界 / 图片解码降采样 / batch 写入 | [`performance.md`](performance.md) |
| §6.60 | 第二轮内存/峰值优化：哈希下放 isolate / 交付物树懒构建 / 内存压力接线（2026-11） | [`performance.md`](performance.md) |
| §6.61 | Windows 分发：zip 之外再发 Inno Setup 安装包（2026-11） | [`build-and-release.md`](build-and-release.md) |
| §6.62 | 目标任务清单「内容被挤占」：`ListTile` → 卡片 + 动作下移（2026-11） | [`ui.md`](ui.md) |
| §6.70 | 移动端无归属输入页：桌面键盘提示 + 返回键静默丢草稿（2026-11） | [`ui.md`](ui.md) |
| §6.63 | 「关窗即隐藏」从未生效：`close` 是通知，不是拦截（2026-11） | [`platform.md`](platform.md) |
| §6.64 | 时间线「数据面」快照：把「回复少了一大块」判成数据丢还是像素丢（2026-11） | [`chat.md`](chat.md) |
| §6.65 | 断线回放缺口探测：服务端 500 条窗口外**静默**不回放（2026-11） | [`chat.md`](chat.md) |
| §6.66 | 选 Agent 改为**纯本地**（对齐 webapp）：点选不发请求，下一条消息带 `agent_id`（2026-11） | [`chat.md`](chat.md) |
| §6.67 | 邮箱 magic link 登录：轮询确认 + 兑换标准授权码（2026-11） | [`auth.md`](auth.md) |
| §6.68 | 悬浮输入窗「一大片空白」：窗口高度写死 + 按钮行被 `Expanded` 撑开（2026-11） | [`platform.md`](platform.md) |
| §6.69 | 悬浮窗「不打扰」：进入先缩小再跳、退出弹出主窗口抢焦点（2026-11） | [`platform.md`](platform.md) |
| §6.71 | 生物识别门禁：`AuthStatus.locked` + 回前台重锁 + 五态失败分支（2026-11） | [`auth.md`](auth.md) |
| §6.72 | G8 收口（缩略图有界 + 版本失效）与内存分解/高水位日志（2026-11） | [`performance.md`](performance.md) |
| §6.73 | 真机报告驱动的第三轮：脏检测改 stat + 流式摘要，补同步在途读数（2026-11） | [`performance.md`](performance.md) |
| §6.74 | 渲染帧数（fps/光栅耗时）进内存采样：把「CPU 为什么高」变成一行读数（2026-11） | [`performance.md`](performance.md) |
| §6.75 | Windows「定位/打开交付物」落在默认视图：explorer 不吃混合分隔符（2026-11） | [`platform.md`](platform.md) |
| §6.76 | 列表页文字偏小：`SpbType` 语义令牌 + 元数据 11px→12px（2026-11） | [`ui.md`](ui.md) |
| §6.77 | 密度按平台分支：摘掉全局 `dense` + `VisualDensity` 分端（2026-11） | [`ui.md`](ui.md) |
| §6.78 | 聊天面板字号收口：68 处 `labelSmall` 迁走 + 小字禁降透明 + 字号守卫（2026-11） | [`ui.md`](ui.md) |
| §6.79 | CJK 度量校正：字距归零 + 行高 ≥1.5，12 张 golden 重出（2026-11） | [`ui.md`](ui.md) |
| §6.80 §6.81 §6.82 §6.83 | 系统字体缩放：决定不 clamp，画布文本跟随缩放（2026-11） | [`ui.md`](ui.md) |
| §6.84 | 对话列表布局：桌面限宽单列与三层摘要、移动端卡片（2026-11） | [`ui.md`](ui.md) |
| §6.88 | 多端可用性三缺口：安全区 / 触控目标 / 窄屏 AppBar 入口（2026-11） | [`ui.md`](ui.md) |
| §6.89 | 对话列表：agent 名称映射（服务端无 agent_name）+ 状态徽标（2026-11） | [`ui.md`](ui.md) |
| §6.85 | 「对话中途丢块、滚动才回来」在 release 包里可判定：行主键自检 + 整段替换丢弃量（2026-11） | [`chat.md`](chat.md) |
| §6.86 | 切对话先闪上一个对话的内容：清缓冲没作废归约缓存、也没推「已清空」（2026-11） | [`chat.md`](chat.md) |
| §6.87 | 升级安装卡在「正在关闭应用」：关窗即隐藏把 Restart Manager 的 `WM_CLOSE` 拦下了（2026-11） | [`build-and-release.md`](build-and-release.md) |
| §6.90 | 切换账号时失效身份与缓存归属（issue #103） | [`auth.md`](auth.md) |
| §6.91 | 对话列表刷新与 SSE 异步一致性（issue #104） | [`ui.md`](ui.md) |
| §6.92 | 跳到会话内某一轮：`/chat/{groupId}?turn={turnId}` 深链（2026-11） | [`chat.md`](chat.md) |
| §6.93 | dependabot 的 pub PR 永远红：`flutter_test` 的精确 pin 把 analyzer 家族钉死（2026-11） | [`build-and-release.md`](build-and-release.md) |
| §6.94 | 轮次导航刻度条：右侧竖置「齿轮」（2026-11） | [`chat.md`](chat.md) |
| §6.95 | Android 签名：调试密钥入库，让 CI 与各开发机签出同一签名（2026-11） | [`build-and-release.md`](build-and-release.md) |
| §6.96 | 远端桌面（RDP）里「卡两下再跳」：桌面去全窗过渡 + 远端会话关动效 + 三项环境读数；**传输层（RDP 编码/带宽/RTT）未排除**，附分流判据表（2026-11，issue #110） | [`performance.md`](performance.md) |
| §6.97 | Passkeys 是 IdP + 浏览器侧能力，客户端零改动；RP ID 改 `dever.atjog.com`（2026-11，issue #82） | [`auth.md`](auth.md) |
| §6.98 | 微信开放平台 App 授权登录：不做，小程序短码已覆盖目标（2026-11，issue #83） | [`auth.md`](auth.md) |
| §6.100 | 登录页收纳与「打开微信」按钮：裸 `weixin://` 只拉宿主、未装微信不渲染、桌面端不接；短码进行中其余入口收起并留退路（2026-11，issue #98） | [`auth.md`](auth.md) |
| §6.101 | 依赖锁定与升级触发条件：`window_manager` 0.5.2 / `flutter_local_notifications` 22.3.1 为什么锁、何时升（2026-11，issue #101/#102） | [`build-and-release.md`](build-and-release.md) |
| §6.102 | 移动端后台无远程推送：客户端只做「回到前台对账」，推送本身在服务端（2026-11，issue #88） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.103 | 账号安全入口跳浏览器：客户端不做 passkey 注册（2026-11，id-provider#12 客户端侧） | [`auth.md`](auth.md) |
| §6.104 | App 内相机扫码：`QrScanner` 契约在 `spb_platform`、插件只在移动端、桌面端不渲染；扫码只登成浏览器侧 IdP 会话（2026-11） | [`auth.md`](auth.md) |
| §6.105 | `error` 事件按服务端 `code` 出表现：闭集镜像 + fail-open、文案只在服务端、`detail` 折叠（2026-11，issue #115 / super_partyb#182） | [`chat.md`](chat.md) |
| §6.106 | 首 token之前的空窗：`dispatch_stage` 进度条、500ms 门槛、只认本端 rid（2026-11，issue #114 / super_partyb#181） | [`chat.md`](chat.md) |
| §6.107 | 事件目录 vendored 对拍（类别/时间线/控制类）；契约漂移的出口 = 一行「未知事件」+ 每类型一次 warn（2026-11，issue #116 / #117 / #118 / super_partyb#183） | [`chat.md`](chat.md) |
| §6.108 | 交付物预览：`external` 按小程序 `preview_mode` 分三通道（HTML/SVG→一次性 ticket、图片/音视频/PDF→媒体签名 URL、Office/未知→旧预览页），415/403/5xx 回落；客户端只渲 text/image（2026-11） | [`chat.md`](chat.md) |
| §6.109 | 通知验证压成三步：Linux 用进程内假 daemon 跑**真**插件（无 GUI 可测），Windows/macOS 靠 App 内「通知自检」；四步失败点分别记录（2026-11，issue #90） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.110 | 交付物预览改用独立页面（root Navigator 压一层 MaterialPageRoute）：系统返回/AppBar 返回/✕ 三个出口同源，都只弹这一层、对话不出栈；正文限宽 980。图片两段式（先 256 缩略图占位、原图到位替换）与开页前预览域 TCP 预检（不通回落旧预览页）（2026-11） | [`chat.md`](chat.md) |
| §6.111 | 移动端后台检查（`WorkManager`）：定位是「尽力而为」的兜底而非推送（15 分钟下限 / Doze / force-stop 都在）；必补三件事（跨 engine 判重、凭证与通知联动、稳定通知 id）；设置页给出「跑没跑」三态读数；刻意不做开关（2026-11，issue #88） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.112 | Windows 通知初始化：`InitializationSettings.windows` 必填（缺了插件抛 `ArgumentError`，被 catch 吞成「装配/平台通道问题」）；GUID 写死、AUMID 对齐 Runner.rc、设置抽成可测 getter、失败日志走 `SpbLog`；非 MSIX 下 `cancel()` 是空操作（2026-11） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.113 | 普通对话附件与 Android 全局快速对话：系统分享、选中文字、临时 Activity 返回来源（2026-11） | [`chat.md`](chat.md) |
| §6.114 | release 的资源压缩会删掉只被 Dart 字符串引用的 `ic_notification`：debug 包通知正常、CI 包一律抛 `invalid_icon`；修法 = `res/raw/keep.xml` 的 `tools:keep` + 产物级守卫（2026-11） | [`build-and-release.md`](build-and-release.md) |
| §6.115 | 移动端去掉底部标签栏：首页入口按频率分档（primary / `≡` / 本端专属），新建入口由 `createInFab` 显式声明载体（FAB ＋ vs 桌面 AppBar ＋），快速输入移进菜单以保住 §6.7（2026-11） | [`architecture.md`](architecture.md) |
| §6.116 | 用户记忆接入：`/api/memories` 的 `requireScope` 只约束 API Key，登录态可用 → 从 §6.9「管理面」移出；页面对齐 webapp（筛选/分桶/编辑/归档/恢复），不做手动新建（2026-11） | [`runtime-and-ops.md`](runtime-and-ops.md) |
| §6.117 | 点通知落在对话列表而不是那个 group：`showWindow` 的导航（`main → /`）晚于 payload 那次 `go`，把它顶掉；修法 = `DesktopCapabilities.revealWindow`（只提前台不换页面）+ 两端「点击 → 落到该 group」守卫（2026-11） | [`platform.md`](platform.md) |
| §6.118 | 多端可用性批（#126–#131 / #133）：状态面有界/无界高度、错误文案归一（`SpbError.toString()` 是日志形态）、12px 不叠 alpha 的守卫规则 3 与 `outline` 非文字角色、触控目标 ≥48dp 与可读名称、气泡宽度量容器、长路径/未知状态补弹性；附回归覆盖归属表与变异验证（2026-11） | [`ui.md`](ui.md) |
| §6.119 | 模态载体与动效策略（#132）：桌面 dialog / 移动 sheet 判据走主题注入、`popped` ≠ `completed` 的退场时序更正、`SpbMotion`（`animateTo` 不接受零时长故改用 `jumpTo`）、copyFeedback/超时/防抖不归零、按帧采样验证「瞬时到达 vs 仍在途中」（2026-11） | [`ui.md`](ui.md) |
| §6.120 | 两端工作概览首页，复用对话列表、待确认查询与按工作加载的交付物 | [`architecture.md`](architecture.md#6120-两端工作概览首页) |
