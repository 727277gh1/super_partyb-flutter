# 界面与交互

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。布局与呈现：窄屏 AppBar、品牌图标、CJK 字体、新建对话标题、AppBar 标题、
侧边栏收起、长正文绘制、工具调用折叠与「动态」面板、任务清单卡片。

> 编号（`§6.x` / `§5.x` / `[§7](build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](README.md)。

---

### 6.16 窄屏 AppBar 溢出（issue #31）

**症状**：移动端对话页在常见手机宽度下**两处** RenderFlex 溢出——AppBar 与输入区。
溢出后右侧入口被黄黑条覆盖/裁切，**用户点不到**。

**为什么此前没发现**：全部 widget test 用**默认 800dp 窗口**（比真机宽），而本机无
`DISPLAY`（AGENTS.md [§9](../development.md)）也没有真机可看。这是一个**测试环境掩盖真实布局**的典型。

#### 实测数据（`tester.view.physicalSize`，修复前）

| 宽度 | AppBar 溢出 | 输入区溢出 |
|---|---|---|
| 320dp | 66px | — |
| 360dp | 66px | 64px |
| 390dp | 36px | — |
| 412dp | 14px | — |

AppBar 曾塞 7 个常驻元素（`AgentSwitcher` + 5 个 `IconButton` + 连接指示器），
合计约 366dp。

#### 修法：按「频率 + 是否需一眼可见」分档

| 入口 | 窄屏 | 理由 |
|---|---|---|
| `AgentSwitcher` | 常驻（**<360dp 时只留图标**） | 「这段对话由谁回答」是全局属性，随时要切 |
| 交付物 / 待办 | 常驻（**带徽标**） | 回答「现在有什么在等我」，必须一眼可见 |
| 对话设置 / 任务清单 / 目标历史 | **收进溢出菜单** | 低频弹层，多一步不痛 |
| 对话内搜索 | **收进溢出菜单**（页面追加） | 同上（见 [§6.15](chat.md)）；**宽屏则摆独立图标**（issue #33，见下） |

**阈值用 `SpbBreakpoints.compact`（720dp）而不是「刚好放得下」的实测值（440dp 左右）**：
后者是**内容相关的**——`AgentSwitcher` 宽度随 agent 名字变化（实测 94.3dp，上限
140dp+），按「刚好」设阈值会在换个长名字的 agent 后又溢出。720dp 以下一律单栏窄屏，
是这类取舍的天然分界。

#### 溢出菜单为什么由 `ConversationPage` 渲染、条目由调用方给

三个低频入口的**动作**属于各端（各自持有弹层与 State），而「在本对话中搜索」的
**动作**属于页面（需要页面私有 `ScrollController` 与 `_items`）。故页面提供
`overflowItems` 插槽：调用方给条目，页面把自己的搜索项**追加在末尾**并渲染整个菜单。

⚠️ **菜单项与宽屏图标用不同的 `key`**（`menu-group-settings` vs
`open-group-settings`）：同一个 key 指向两种交互会让断言的含义随窗口宽度漂移。

#### 三条不变式

1. **窄屏不能「藏掉」功能，只能「多一步」**。菜单项禁用（`onTap == null`）而不是
   不渲染——入口消失会让用户以为「本端不支持」，置灰只说明「现在还用不了」。
2. **测试必须显式设窗口尺寸**。新增的 `对话页窄屏 AppBar（issue #31）` group 用
   `tester.view.physicalSize` 压到 320/360/390/412dp，并断言
   `tester.takeException()` 为 null（溢出会走 `FlutterError.onError`）。
   **默认 800dp 的用例不能替代它**——那正是缺陷被掩盖的原因。
3. **`compact` 只省「名字」，不省入口**。`AgentSwitcher.compact` 在 <360dp 时隐藏
   标签（名字在菜单勾选项里可见），图标本身保留——它是入口。

#### 移动端搜索入口的取向（与桌面端不同）

| | 桌面端 | 移动端窄屏（<720dp） | 移动端宽屏（≥720dp） |
|---|---|---|---|
| 搜索入口 | 独立图标（`enableSearch: true`） | **溢出菜单**（`enableSearch: false`） | **独立图标**（`enableSearch: true`） |

移动端窄屏在 720dp 以下若给搜索一个 48dp 图标，会挤压常驻项；而菜单入口在
所有窄屏档位都可用。宽屏（平板 / 折叠屏展开 / 横屏手机）则有 720dp 余量，摆
独立图标不会溢出——**两个入口必须互补覆盖**：窄屏「菜单有、图标无」，宽屏
「图标有、菜单无」。

⚠️ **曾经两档都缺**（issue #33）：`enableSearch` 恒为 `false`，而
`_overflowItems()` 在宽屏返回 `null` —— ≥720dp 下搜索**彻底不可达**。既有用例
只断言了 `_group` 系列入口，没碰搜索；本机无 `DISPLAY` 也看不出。故两端各有一条
从 **router 层**断言的用例钉住搜索入口——**页面测试自己传参，接不接线它不管**：
`apps/spb_desktop/test/router_list_test.dart` 的 `对话页 AppBar 提供对话内搜索入口`、
`apps/spb_mobile/test/router_notify_test.dart` 的 `宽屏（≥720dp）…` 与
`窄屏（<720dp）…`（两条分别钉住宽屏图标与窄屏菜单，避免「一边补上、另一边
漏掉」）。

#### 对话页 AppBar 标题用 `group.title`（不是硬编码的「对话」）

两端 router 都传 `title: _appBarTitle`（取自 `_group.title`，未就绪/为空时退回
「对话」）。**列表页**的 AppBar 也叫「对话」——对话页若同样硬编码，用户点进去后
看不出自己是否真的进了某个对话、进的是哪一个（从搜索结果 / 待确认列表跳进来
时尤其明显）。

⚠️ **两端的用例必须在 router 层断言**：`ConversationPage` 自己的测试**自己传
`title`**，所以「router 又写回硬编码」在页面测试里永远发现不了（与本节开头的
失败模式同一个）。两条用例分别见
`apps/spb_desktop/test/router_chat_test.dart` 与 `apps/spb_mobile/test/router_chat_test.dart`
的 `进入对话后 AppBar 标题是 group.title…`。

### 6.32 品牌图标：真源在 super_partyb，43 个文件由脚本生成

客户端此前用的是 **Flutter 模板的默认图标**（macOS/iOS/Android 都是那个蓝白
「F」字）。它与产品无关——装到桌面上，用户看到的不是「Super PartyB」。

品牌真源在姊妹仓库：`super_partyb/apps/webapp/src/app/icon.svg`（成蹊 logo，
1024×1024，底色 `#1a5cd7`，浅色气泡 + 镂空对勾）。本仓库不复制 SVG，而是
**由 `tools/gen_brand_assets.py` 从它渲染出全部平台图标**。

#### 为什么是脚本而不是手工导出

不是「慢」，而是**漂移**：改一次品牌色要重新导出 43 个文件，漏掉的那几个
只在真机上看图标时才会发现——而本仓库恰好验证不了 macOS / iOS / Windows
（[§9](../development.md)）。写成脚本后，改品牌 = 重跑一次。

```bash
# 1) 渲染真源 SVG（PIL 不支持 SVG，需 rsvg-convert；本机可免 sudo 装）
cd /tmp && mkdir -p rsvg && cd rsvg
apt-get download librsvg2-bin && dpkg-deb -x librsvg2-bin_*.deb root
cd /path/to/super_partyb
/tmp/rsvg/root/usr/bin/rsvg-convert -w 1024 -h 1024 \
  apps/webapp/src/app/icon.svg -o /tmp/logo-master.png

# 2) 生成全部图标（先 --dry-run 看清单）
cd /path/to/super_partyb-flutter
python3 tools/gen_brand_assets.py --master /tmp/logo-master.png \
  --svg ../super_partyb/apps/webapp/src/app/icon.svg --dry-run
python3 tools/gen_brand_assets.py --master /tmp/logo-master.png \
  --svg ../super_partyb/apps/webapp/src/app/icon.svg
```

#### 各端的形状约定（**不是随便填满**）

| 平台 | 形态 | 为什么 |
|---|---|---|
| iOS | 满幅正方形、**无 alpha** | App Store 拒绝带透明通道的 1024 图标；系统自己加圆角遮罩 |
| Android legacy | 满幅正方形 | 系统按 density 选图，不做裁切 |
| Android adaptive | 背景色 + **透明底**前景区 | API 26+ 由启动器按厂商形状裁切（见下） |
| macOS | **圆角方形 + 留白** | Big Sur 栅格：1024 画布内 824×824 圆角矩形（圆角 185），四周各留 100 |
| Windows `.ico` | 满幅多尺寸内嵌 | 资源管理器按尺寸挑帧 |
| 安装包 `.ico` | 满幅多尺寸、**BMP 帧** | ISCC 读 `SetupIconFile` 时对 PNG 压缩帧的支持未经验证（本机无 Windows/ISCC，测不了），故只写 BMP 帧；同理不含 256×256——BMP 帧不压缩，单张就 256 KB |
| 桌面运行时 | 托盘 64 / 窗口 256 | GTK 自己缩放；窗口图标会被 Alt+Tab 放大，用 64 会糊 |

#### Android 自适应图标的两个硬约束（实测踩过）

1. **启动器只显示画布中央 72dp**（108dp 的 66%），其余会被裁掉或压到相邻图标下；
2. **圆形 / squircle 遮罩会再切掉四角**。

品牌 logo 里气泡占源图 49%。第一版直接铺满 108dp 画布，气泡就等于可见区的
**74%**——圆形遮罩下贴着边（预览图确认过）。现在先提取气泡、按「气泡 = 画布的
40%」重新居中（`ADAPTIVE_LOGO_RATIO`），可见区内气泡占 60%，四周约 20% 呼吸空间。

前景区必须**透明底**：logo 里的对勾是背景色**透出来**的（浅色气泡上挖空），
不是画上去的蓝。故按亮度反解 alpha 再反预乘还原颜色（`_extract_bubble`），
边缘自然过渡；直接阈值化抠图会留一圈蓝边。背景色由
`values/colors.xml` 的 `ic_launcher_background` 提供。

#### 颜色一致性：同一品牌蓝在**三处**出现

| 位置 | 用途 |
|---|---|
| `packages/spb_ui/lib/src/spb_logo.dart` 的 `SpbLogo.brandBlue` | 应用内标志 / 降级占位 |
| `apps/spb_mobile/android/app/src/main/res/values/colors.xml` | 自适应图标背景层 |
| `apps/spb_mobile/ios/Runner/Base.lproj/LaunchScreen.storyboard` | 启动画面底色 |

不一致时对勾会变成另一种蓝（前景洞透出背景），启动画面会与首屏「闪一下」。
生成脚本从 SVG 的 `rect fill` 读品牌色，不写死。

#### 应用内标志：`SpbLogo` 随 `spb_ui` 分发

登录页首屏此前是 `Icons.shield_outlined` 占位（盾牌与产品无关）。现在是
`SpbLogo`——资源在 **`packages/spb_ui/assets/brand/logo.png`**，由本包分发。

⚠️ **不要改成各端 `assets/` 各存一份**：两份必然漂移，而标志是「一眼看出
是哪个产品」的东西，两份颜色略有差异比没有还糟（同 [§6.13](testing.md) 的
`golden_fonts.dart` 教训）。包内资源的路径必须带 `packages/<pkg>/` 前缀。

`SpbLogo` 自带 `errorBuilder` 降级（同色系方块 + 对勾）：单元测试宿主与将来
某个未打包资源的端会让 `Image.asset` 异步失败——在登录页上表现为**一片红色
错误块**，而那正是「用户进不来」的首屏。品牌是装饰，登录能力才是功能。

#### 桌面端：窗口图标要**显式**设置

Linux 上窗口图标**不会**从包内资源自动取：GTK 靠 `_NET_WM_ICON`，而 Flutter
的 Linux 嵌入层不设它（模板 `my_application.cc` 里没有 `gtk_window_set_icon`）。
结果是任务栏 / Alt+Tab 显示默认占位方块——而托盘图标是正确的，两者不一致。
故 `bootstrap.dart` 的 `_initWindowIcon` 调 `windowManager.setIcon`
（其 Linux 实现就是 `gtk_window_set_icon_from_file`）。macOS 跳过：dock 图标
来自 `.app` 里的 `AppIcon.appiconset`。

#### 启动画面

Android（`drawable*/launch_background.xml`）与 iOS（`LaunchImage.imageset` +
`LaunchScreen.storyboard`）都是「品牌蓝底 + 居中标志」。

⚠️ **不要换成 `flutter_native_splash` 之类的生成器**：那会重写
`LaunchScreen.storyboard`，而该文件同时承载 OIDC 回调的窗口配置（见
`docs/mobile-oidc-deeplink.md`）。

⚠️ **Android XML 注释里不能出现 `--`**（XML 规范禁止）：写「A -- B」这种
中文破折号转写会让 `mergeReleaseResources` 报
`The string "--" is not permitted within comments`。实测踩过一次。

### 6.38 Windows 上「门」显示畸形：主题从未指定 CJK 字体

**症状**：Windows 上「门」被画成「一个方框 + 正中一根竖」（正确字形是「框 + 左上角
一点」）。截图证据：`/home/jim/spb.png`，标题与正文各一处。

#### 根因：Flutter **没有**「用系统默认字体」这回事

`ThemeData(fontFamily: null)` 时，Flutter 按平台从 `Typography.material2021` 取一个
**写死了字体名**的 TextTheme（`packages/flutter/lib/src/material/typography.dart`）：

| 平台 | TextTheme | 写死的 fontFamily | 带 fallback 列表？ |
|---|---|---|---|
| android / fuchsia | `blackMountainView` | `Roboto` | ❌ |
| **windows** | **`blackRedmond`** | **`Segoe UI`** | ❌ |
| macOS | `blackRedwoodCity` | `.SF NS …` | ❌ |
| iOS | `blackCupertino` | `CupertinoSystem…` | ❌ |
| linux | `blackHelsinki` | `Roboto` | ✅ 6 个 |

除 Linux 外都是**纯拉丁字体**——中文字形只能靠引擎的 **last-resort 回退**。
`SpbTheme` 此前完全没设 `fontFamily`，走的就是这条路。

#### 回退到哪了：`Segoe UI` 的 FontLink 链里**日文排在简体中文前面**

这是根因的确切机制（Windows 字体替换配置在注册表
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink`）：

```
MEIRYO.TTC,Meiryo UI            ← 日文，排在前面
MSGOTHIC.TTC,MS UI Gothic       ← 日文
MSJH.TTC,Microsoft JhengHei UI  ← 繁体
MSYH.TTC,Microsoft YaHei UI     ← 简体（被前三个抢走）
MALGUN.TTF,Malgun Gothic        ← 韩文
SIMSUN.TTC,SimSun               ← 宋体排到第 11 位
```

于是简体中文字形优先由**日文字体**提供。「门」在日文里是「門」的简化形——
**框内一根居中的竖**；简体中文标准字形是「框 + 左上的点」。这与像素测量
完全吻合（用户截图里上笔中心精确在 50%，而 WenQuanYi 等中文标准字形上笔
偏左，实测 x=38..46 vs 横条 39..105）。

**同类现象在其它软件里反复出现**（都是同一个根因：基字体不含 CJK → 回退链
先命中日文字体）：

| 软件 | 表现 |
|---|---|
| Notepad++ #17476 | 「门」被渲染成「内」 |
| Notepad++ #16742 | 8.5 后某版本「门限」的「门」显示不对 |
| Excel / Office | Arial 单元格里「门」异常（输入框正常） |
| Sublime Text | 默认字体下「门」显示异常 |
| Ubuntu fontconfig | `64-language-selector-prefer.conf` 日文优先级高于中文 → 「门」「复」显示成日文异形 |

**排查时排除的假线索**：

- 不是字符问题：全仓扫描真繁体独有字，只命中「案」（简繁同形）；没有「闩」。
- 不是本机字体能重现的：用本机 181 个字体做 IoU 匹配，最高 0.338 且全是 Latin
  字体误配——**没有任何本地字体画得出那个形态**（本机无日文 CJK 字体），
  故只能是 Windows 侧回退所致。

⚠️ **`'sans-serif'` 在 Flutter 里不是救命稻草**：`fontFamilyFallback` 只认
**具体字体名**，CSS 的通用族名（`sans-serif` / `serif` / `monospace`）**不被解析**。
链尾那一项留着只是可读性，真正兜底的是引擎「fallback 耗尽 → 用平台默认字体」
（`TextStyle.fontFamilyFallback` 官方文档）。故测试**不**断言末位是通用族名——
那会给出「这一项在起作用」的错觉。

#### 修法：**只给 Windows** 指定字体，其余平台保持 `null`

`packages/spb_design/lib/src/fonts.dart` 的 `SpbFonts.sansFor` /
`sansFallbackFor` 只在 `TargetPlatform.windows` 返回非 null
（`Microsoft YaHei UI` + `['Microsoft YaHei', 'Segoe UI', 'sans-serif']`）。

**为什么不是「所有平台都指定」**——两个理由，第二个是实测出来的：

1. 其余平台的系统级 CJK 回退本来就正确（CoreText / fontconfig / Android 按 locale
   选 Noto CJK）。显式钉 `PingFang SC` 会让**日语用户被强制套上简体字形**。
2. ⚠️ **给全部平台配 fallback 链会让 4 张 golden 基线全红**。原因**不是**渲染
   退化，而是 `flutter test` 里 `defaultTargetPlatform` 恒为 **android** 且环境
   **没有 CJK 字体**：
   - 无 fallback 链 → 中文落到 Roboto 缺字的**细线空心 tofu**（基线原样）；
   - 有 fallback 链 → 链耗尽落到 Ahem 的**粗实心方块** → 基线全废。

   两份都是 tofu，只是画法不同。故非 Windows 配 fallback 是**零收益且制造基线
   噪音**。`test/fonts_test.dart` 有一条专门钉住这件事（比 4 张 golden 报「像素
   不匹配」更容易定位根因）。

#### ⚠️ 不要在 `flutter test` 里「验证字形」

测试环境没有 CJK 字体，**中文永远是 tofu，改成什么字体名都看不出来**。能验证的
只有结构性断言（主题里带了正确的字体名）。真实字形**必须靠目标平台手测**
（本机无 Windows，见 [§8](build-and-release.md)/[§9](../development.md)）。

`SpbTheme` 为此加了 `lightFor(platform)` / `darkFor(platform)`
（`@visibleForTesting`），生产仍走 `light()` / `dark()`。

#### 顺带统一 4 处 `fontFamily: 'monospace'` 的 CJK 兜底

`'monospace'` 不是真实字体名，是「问系统要等宽字体」——四个平台拿到的都是纯拉丁
（Windows = `Consolas`）。而**工具调用的入参/结果经常含中文**。三处原本**没有**
fallback（`tool_call_tile.dart` ×2、`group_gate_panel.dart` ×1），现统一改用
`SpbFonts.monoFallback`（`agent_file_preview.dart` 原有那条也一并收敛）。

#### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| `sansFor(windows)` 改回 `null` | `fonts_test.dart` 1 条失败 |
| 给全部平台加 fallback 链 | `spb_features` **4 张 golden 失败** + `fonts_test` 1 条失败 |
| 主字体名改成 `'Noto Sans CJK SC'`（仅 android） | golden 仍失败 2 张（证明**主字体名无关**，问题在 fallback 链） |
| 只删 `fontFamilyFallback`、保留主字体名 | golden 全绿（定位到根因） |

#### 未做

- **打包 CJK 字体子集**：能彻底摆脱对目标机器字体的依赖，但代价 5–10 MB + 全部
  golden 基线重出，且要处理字体许可。当前修法对 Windows 已够（雅黑是系统必备）。
- **接 `flutter_localizations` + `supportedLocales`**：那会改 `scriptCategory`
  （`englishLike` → `dense`）、基线从 `alphabetic` 变 `ideographic`，golden 需一并
  重出。与 [§6.12](runtime-and-ops.md)（i18n 暂不做）一致，未纳入本轮。

### 6.40 新建对话不需要输入标题（用默认占位 `新对话`）

`GroupListPage` 的「新建对话」按钮此前会弹一个输入框要求先起名字，空输入
（含全空格）时确认按钮禁用。现已去掉这个对话框：**点一下就用
`defaultGroupTitle`（`新对话`）建并直接进入该对话**。

#### 为什么

1. 建对话的**真实意图**是「开一个干净上下文继续聊」，不是「先起个名字」。
   逼用户先想名字会让最常见的动作多一步，而名字随后能在对话设置里改
   （`_RenameDialog` 仍在）。
2. **webapp 本来就是这个取向**：`use-workbench-state.ts` 的
   `createGroup(title?)` 标题可选，`WorkbenchShell.handleCreateGroup(title?)`
   在无参调用时不传 title；`ChatInputArea` 的「新对话」按钮就是直接建。
   客户端此前是**独有**的多一步。
3. 服务端 `POST /chat/groups` 对空标题**不报错**，而是兜底成「新对话组」
   （`chat.go` 的 `if title == "" { title = "新对话组" }`）——即「必须有标题」
   从来不是服务端约束，是客户端自己加的。

#### 实现要点

| 项 | 变化 |
|---|---|
| `defaultGroupTitle` | 新增公开常量（`新对话`），`_createGroup` 与测试共用同一个值 |
| 新建标题对话框（原私有类，已删除） | **删除**（连同 `group-create-dialog` / `group-create-field` / `group-create-confirm` 三个 key） |
| `onCreateGroup` 签名 | **不变**（仍收 `String title`）：装配层仍能改标题策略，页面只是不再问用户 |
| `_creating` 防重入 | 保留并新增用例：请求在飞时入口 `onPressed == null` |

#### 测试的连带改动（不是放宽断言）

删掉对话框后，三处「填标题 → pump → 点确认」的前置步骤**全部消失**（`enterText`
与随后那次 `pump` 都是为解除确认按钮禁用而存在的）。受影响的用例：

| 文件 | 改动 |
|---|---|
| `group_list_page_test.dart` | 「trim 后的标题」「空标题禁用确认」两条**删除**（被测对象已不存在）；「成功后插到最前」拆成「不弹框 + 默认标题 + 导航」与「插到最前」两条；新增「往返期间禁用入口」 |
| 两端 `router_list_test.dart` | 去掉 `enterText` + `pump` + 点确认，只留「点入口」 |

⚠️ **`adapter.onPost(..., data: {'title': '新对话'})` 的精确匹配必须保留**：它是
「标题确实发出去了」的唯一断言点——只断言导航会漏掉「回调拿了标题却没用」
（与 `createTurn` 的 `inputText` 那类缺陷同型，见 [§6.14](chat.md)）。

### 6.44 进入对话后 AppBar 显示对话名（2026-10）

**症状**：进入某个对话后，AppBar 仍显示固定的「对话」——与列表页的 AppBar
同名。用户看不出自己是否真的进去了，也看不出进的是哪一个（桌面端从搜索结果 /
待确认列表跳进来时尤其明显）。

#### 修法：两端 router 各自派生 `_appBarTitle`

`ConversationPage` 的 `title` 本来就是参数（页面不持有 `ChatGroup`，权威 group
由两端 router 的 `_loadGroup()` 拉）。故改的只是**装配层传什么**：

```dart
String get _appBarTitle {
  final title = _group?.title.trim() ?? '';
  return title.isEmpty ? '对话' : title;
}
```

两端逐字同构（桌面 `router.dart` / 移动 `router.dart`）。`_group` 已由
`GET /chat/groups/:id` 异步拉取，且 `GroupUpdate.applyTo`（rename 事件）与
`_loadGroup`（开新会话后重拉）都会刷新它，故标题会跟着改名走，无需额外订阅。

> 选 agent 本身**不**重拉 `_group`（它是纯本地选择，服务端没变，见
> [§6.66](chat.md)）；只有「同 Agent 开新会话」会改 `active_session` 才需要重拉。

#### 两个判据

| 情况 | 显示 | 为什么 |
|---|---|---|
| `_group` 未就绪 | `对话` | 空标题会让 AppBar 只剩图标（看起来像渲染坏了），且标题宽度变化会拖动右侧图标 |
| `title` 为空串 | `对话` | 服务端对空标题会兜底成「新对话组」，但本地刚建的 group 可能还没回读；空串同样不该渲染 |

#### 为什么两端必须各有一条 router 层用例

`ConversationPage` 自己的测试**自己传 `title`**——「router 又写回硬编码」在
那里永远发现不了。这是 [§6.17](testing.md) / [§6.33](build-and-release.md) / [§6.43](sync.md) 反复出现的同一失败模式：**只测
被调用的组件、不测调用点**。故两端各有一条从路由出发、断言
`find.widgetWithText(AppBar, '季度复盘')` 存在且 `'对话'` 不存在的用例。

⚠️ **既有用例的注释也一并改了**：`apps/spb_mobile/test/router_list_test.dart`
的「StatefulShellRoute：切标签后返回」原本靠「时间线的空提示」区分对话页与列表页，
理由是「两个 AppBar 都叫『对话』」——现在对话页显示的是对话名，那个理由不再
成立，故改为直接断言对话名（并补了 `/chat/groups/grp_x` 的 mock）。

#### 反向验证（实测）

把两端 `title: _appBarTitle` 改回 `title: '对话'` → 两端各 1 条失败。

### 6.46 侧边栏收起不销毁子树（滚动位置 / 选中 tab 保留，2026-10）

**症状**（用户报障）：「切换侧边栏后滚动条位置会重新置顶」。

#### 先分清两件不同的事

| 操作 | 修复前 | 原因 |
|---|---|---|
| **切换 tab**（交付物 ↔ 待办 ↔ …） | ✅ 已保留 | `ChatSidebar` 内部用 `IndexedStack`，已激活的 tab **一直挂载**（issue #16 的惰性构建只影响「从未切到过」的 tab） |
| **收起再展开整个侧边栏** | ❌ 全部丢失 | 装配层把整棵子树从树上摘掉 |

故「滚动条置顶」不是 `ChatSidebar` 的问题，是**装配层**的问题：

```dart
// 修复前 apps/spb_desktop/lib/router.dart
if (!_showSidebar) return withHint(conversation);   // ← ChatSidebar 连同所有面板被销毁
```

销毁意味着：`_ChatSidebarState._index` 重置回 0（选中的 tab 也一起丢）、
`_visited` 重置、每个面板的 `State` 与 `ScrollPosition` 全部重建 → 再展开是
一个全新的 `ListView`，`pixels` 归零。

#### 修法：`Offstage` 保留挂载，但**惰性**建首帧

```dart
if (!_sidebarEverShown) return withHint(conversation);   // 从未展开 → 根本不构建
...
Offstage(offstage: !_showSidebar, child: Row(...))       // 展开过 → 永远保留
```

`_sidebarEverShown` 在点开开关时置 true，此后不再回落。

#### 为什么必须加 `_sidebarEverShown` 这层守卫

`GroupDeliverablesPanel.initState` 会立即 `_load()` 发一次 HTTP。若无条件
`Offstage`，**每个对话页一打开就为一个用户没看过的面板付一次请求**——而
「默认折叠时不取数」是既有且有意保留的语义，`router_workbench_test.dart` 的
「默认不展开：开关存在但侧边栏不可见，未取数」钉住了它（反向验证：去掉这层
守卫 → **5 条失败**）。

这与 `ChatSidebar` 内部的 `_visited` 惰性构建是**同一取向的两层**：外层决定
「要不要建这棵树」，内层决定「建好之后要不要激活某个 tab」。

#### `Offstage` 到底省了什么、没省什么（实测）

`RenderOffstage` 的实现（`packages/flutter/lib/src/rendering/proxy_box.dart`）：

```dart
void performLayout() {
  if (offstage) {
    child?.layout(constraints);   // ← 仍然布局
  } else {
    super.performLayout();
  }
}
bool paintsChild(RenderBox child) => !offstage;              // 只跳过绘制
bool hitTest(...) => !offstage && super.hitTest(...);        // 只跳过命中
void visitChildrenForSemantics(v) { if (offstage) return; ... }  // 只跳过语义
```

**只省 paint / hitTest / 语义**，Element 树、RenderObject 树、State、已加载数据、
布局计算**全部保留**。用 2000 项列表实测（`tester.allElements` + 遍历
RenderObject 树）：

| 方案 | 展开 | 收起 | 收起时释放 |
|---|---|---|---|
| 修复前（从树里移除） | 542 elements / 202 RO | 181 / 45 | −361 / −157 |
| `Offstage` | 543 / 203 | **543 / 203** | **0 / 0** |

#### 代价（**诚实记录，别再说「不占内存」**）

| 项 | 量级 |
|---|---|
| Element 树 | ~360 个 × ~200 B ≈ **70 KB** |
| RenderObject 树 | ~157 个 × ~300–500 B ≈ **60 KB** |
| `GroupDeliverablesPanel._entries` | 每个 `UfsFileEntry` ≈ **420 B**（9 字段 + 4 个 String） |
| 同上 `_tree`（`ArtifactNode`） | 每节点 ≈ 50 B |
| 其它面板 State（`_collapsed` 等） | 几十字节 |

按文件数放大 `_entries` + 树：

| 文件数 | 占用 |
|---|---|
| 100 | 0.05 MB |
| 1000 | 0.45 MB |
| 3000 | 1.36 MB |
| **5666**（生产实测全量） | **2.57 MB** |

即「收起的侧边栏 ≈ **130 KB 固定 + 已加载的交付物清单（最多 ~2.6 MB）**」。
且 `_entries` 只在用户**确实点开过**「交付物」tab 后才存在（`_visited` 惰性）。

换来的是：再展开**零延迟、零请求、状态全在**。被否决的替代方案是「只存滚动
位置与 tab 选择」（几个 double + 一个 int），但要给 6 个面板各接
`ScrollController`/`PageStorageKey`，且 `PageStorageBucket` 在 route 层、
跨对话会串（需按 `groupId` 做 key）——工作量远大于收益。

#### 附带变化：隐藏期间也会刷新（是好事）

子树仍挂载，故 SSE 新文件事件 bump 的 `reloadToken` 仍会触发
`GroupDeliverablesPanel.didUpdateWidget` → 重新拉清单。再展开时数据已是新的，
不用等一轮加载。修复前（已销毁）这条路径不存在。

⚠️ 这条**没有**单独的测试（尝试过，需要精确构造 `agent.file.created` 事件载荷
`{action, relative_path, ufs_file_id, size, mime_type}` 与刷新时序，成本高于
收益）。它是 `Offstage` 语义的直接推论，故记在这里而不是硬凑一条脆弱用例。

#### 测试（2 条，都在 **router 层**）

| 用例 | 钉住 |
|---|---|
| `收起再展开侧边栏：滚动位置与选中的 tab 都保留` | 切到「待办」→ 收起 → 展开：仍停在「待办」（`todos-empty` 在、`deliverables-tree` 不在），且 `ufs.listCalls.length == 1`（**没有重新取数**） |
| `收起侧边栏后交付物树仍挂载（滚动位置不丢）` | 60 个文件 → 拖 -400 → 收起 → 展开：`position.pixels` 与收起前**相等** |

**为什么必须在 router 层**：`ChatSidebar` 自己的测试用 `IndexedStack` 切 tab，
那里本来就不销毁子树（已绿）。真正的缺陷在**装配层**的「收起即移除」——页面级
测试覆盖不到（与 [§6.17](testing.md) / [§6.43](sync.md) 同一失败模式：只测被调用的组件、不测调用点）。

#### 反向验证（实测）

| 改坏 | 失败用例 |
|---|---|
| 改回「收起即从树里移除」（`if (!_showSidebar) return conversation;` + `offstage: false`） | **2**（两条新用例都红） |
| 去掉 `_sidebarEverShown` 守卫（无条件 `Offstage`） | **5**（含「默认不展开…未取数」与两条「已同步则直接打开」） |

#### 已知边界

- **只在同一次对话页生命周期内保留**：`_ChatPageState` 随路由切换销毁，
  换对话再回来仍是默认收起 + 第一个 tab。跨对话记住 tab 选择是独立需求
  （需要提到 provider 层，且要考虑「上次看的 tab 在当前对话里不存在」——
  侧边栏 tab 集合是**动态**的：交付物 / 待办 / 动态 / 目标历史 / 任务清单里
  只有前三个始终存在，后两个按对话是否用得到才加）。
- **`_ChatSidebarState` 的 `initialIndex` 夹取上限有既有 bug**：
  `widget.initialIndex.clamp(0, (widget.tabs.length - 1).clamp(0, 1))` 把上限
  压到 1，`initialIndex >= 2` 无效。`chat_sidebar_test.dart` 已把它标注为
  「既有行为」，**非本节引入**，未在本轮修改（改它会影响既有 tab 索引语义，
  需单独一轮）。
- **需真机验证**：本机无 `DISPLAY`（[§9](../development.md)），只验证了 widget 树层面的状态保留，
  真实滚动手感（尤其是 `Offstage` 期间滚动条不显示、展开后位置正确）需在
  有桌面环境的机器上确认。

### 6.51 长正文滚到中途整块消失：移除正文的整行绘制缓存（待设备复核）

用户再次反馈：向上滚到长正文大约一半的位置后，整块正文消失，必须从顶部重新
往下滚才恢复。[§6.18](chat.md) 的键冲突与 [§6.48](chat.md) 的缓冲裁剪修复，不能据此认定已覆盖
这次故障。

本机无头测试中，正文数据、挂载与布局在往返滚动时均正常，**尚未复现原始
设备上的空白，也未确认 GPU 根因**。发现的可疑路径是 `ListView.builder`
默认给每条回复加 `RepaintBoundary`：几十屏高的正文会整体录制并复用绘制层。
本轮采取局部规避：

- 列表设置 `addRepaintBoundaries: false`，`AssistantMessageItem` 直接由视口绘制；
- 其他行手动加回 `RepaintBoundary`，保留普通消息、工具与文件卡的绘制隔离；
- Markdown 解析缓存、气泡实例缓存与有界 keep-alive 仍保留。

代价是滚动时正文需要随视口重绘；显示效果与真实帧耗时需在故障设备上复核，
**不能把软件渲染测试通过写成“原始故障已复现并修复”**。

`conversation_page_long_scroll_test.dart` 覆盖超过十屏的混合 Markdown，从底部
逐屏向上经过中段，检查正文完整、几何覆盖视口，并截取视口中部验证实际文字
像素。另有结构断言：正文最近的重绘边界必须是视口，普通消息仍有独立边界。
反向验证：恢复列表的默认整行边界后，结构断言失败；软件截图本身并未复现
设备 GPU 故障。

### 6.54 时间线工具调用折叠 + 「动态」面板 + 流式进度条（2026-11）

用户报障：一轮 agent 工作会产出**几十张**工具卡，正文被挤出视野。三件事一起做，
因为它们是同一个诉求的三个面，缺任一条都只能解决一半：

| 面 | 做法 | 章节 |
|---|---|---|
| **A** 时间线太吵 | 连续 ≥5 条工具调用在**展示层**折成一张批卡 | 本节一 |
| **B** 「它到底在干什么」 | 「诊断」改名「动态」、去掉发布构建门控、两端都有 | 本节二 |
| **C** 流式期间看不出进展 | 底部条报「已调用 N 个工具 · 最近 X」 | 本节三 |

#### 一、A：展示层折叠（**不动归约结果**）

`_displayRows()` 里 `groupFileEventsForDisplay(_items)` → `groupTimelineForDisplay(_items)`
（= 先按交付物分批，再按工具调用分批）。

| 判据 | 值 | 为什么 |
|---|---|---|
| 阈值 | `TOOL_CALL_BATCH_MIN_COUNT = 5` | 与交付物批同一阈值（`FILE_BATCH_MIN_COUNT`）。3 条也折会让「就调了两三次」的轮次看不出发生过什么 |
| 分组键 | **同 `turnId`**（且非空） | 跨轮合并会把「上一轮的结果」和「这一轮的开始」塞进一张卡，用户点开后分不清谁先谁后 |
| 打断条件 | 任何**非** `SingleItemRow`（交付物批卡、正文、思考、确认卡…） | 顺序是信息本身。`[5 工具][5 文件][5 工具]` 必须是 **3 行**，不是 1 行 |
| 不足阈值 | **原样返回**那 N 个 `SingleItemRow` | 不重建对象 → `identical` 缓存（`_lastRowsItems`）与既有 key 全不受影响 |
| `turnId` 为空 | 永不合并 | 空 turnId 多见于回填出来的历史项，合并后无法判断「这些是不是同一轮」 |

**为什么在展示层、不在归约层**：`ToolCallItem` 是**数据**，对话内搜索
（`searchConversationItems`）要工具名/入参/输出（[§6.15](chat.md)），`locateIdsOf` 要能给批内
任一成员定位（[§6.18](chat.md)）。一旦在归约里合成一个「批 item」，这两件事都得重新实现一遍，
而且任何按 item 计数的功能（`agentFileCount`、`toolCount`…）都会静默变少。

`ToolCallBatchRow` 放在 `agent_file_batch.dart` 而不是新文件里，因为
`TimelineDisplayRow` 是 `sealed`——它必须在同一个库里才能被穷尽匹配。

#### 折叠卡（`ToolCallBatchCard`）的三条硬约束

1. **批里有在飞的调用（`output == null` 且 `isComplete == false`）→ 默认展开**。
   那是用户唯一能看到的「它在干活」的证据，藏起来比折叠前更糟。
2. **跑完自动收起**（`hasRunning` true→false）。用的是 `ExpansibleController`，
   不是 `initiallyExpanded`：后者**只在 `initState` 读一次**（SDK 的
   `_ExpansionTileState.didUpdateWidget` 不同步它），写错了表现为「一轮跑完，
   那张卡永远摊在那里」——正是本功能要消除的噪声。
3. **用户点过之后以用户为准**（`_expanded != null` 就早退）。用户展开了正在看的
   清单，不能因为「这批刚好跑完」被自动收走。

⚠️ 程序化 `expand()/collapse()` 也会回调 `onExpansionChanged`，故必须用
`_syncingExpansion` 把「程序同步」与「用户点击」分开。少了它，一次自动收起会把
`_expanded` 写成 `false`，组件从此认为「用户自己收的」，**同一批里第 7 个工具跑起来
时不会再自动展开**（真实场景：同一轮 agent 接着调下一个工具，批的 key 取首条 id，
故组件实例不变、`hasRunning` 由 false 翻回 true）。

#### 二、B：「动态」面板（`GroupActivityPanel`）

原来的 `GroupDebugPanel` 只在 `!SpbEnv.isRelease` 时作为侧边栏 tab 出现，理由
是「工具入参与 gate 决策是内部视图」。但发布版的用户恰好最需要回答「它卡在哪一步 /
为什么自己又跑了一轮」——而这正是这个面板回答的问题。故：

| 变更 | 内容 |
|---|---|
| 改名 | 侧边栏 tab / 弹层标题「诊断」→ **动态**（它是常驻视图，不是排障工具）。⚠️ 「诊断」一词在**别处**仍在用，且含义不同，勿一并改掉：设置页的「导出诊断日志」（[§6.20](runtime-and-ops.md)）、搜索面板里 `DiagnosticNoticeItem` 的类型标签（`conversation_search_sheet.dart`） |
| 门控 | `showDebugPanelProvider` 删除（两端 `providers.dart`），tab 始终可见 |
| 内容 | 顶部固定一行**当前轮次状态** + 工具调用列表（倒序）+ gate 决策列表（桌面） |
| 载体 | 桌面：侧边栏 tab；移动：AppBar 图标（宽屏）/ 溢出菜单（窄屏）→ 底部弹层 |

**入参是原始状态，不是预计算值**：`items` / `activities` / `staleTurnIds` /
`executionStatus` / `decisions` 直接由 router 传。若让两端各自算「哪些是工具调用」
「现在是什么状态」，就会出现「页面说还在跑、面板说已结束」——与 [§6.17](testing.md) 同一失败模式，
只是发生在数据侧。状态派生因此收敛到 `turn_status.dart` 的 `deriveTurnStatusFor`，
**页面底部条与面板共用它**（[§6.17](testing.md) 的接线守卫查不到函数内部实现）。

**`decisions == null` 的语义是「本端不看这块」，不是「没有决策」**：移动端不订阅
`controller.gateDecisions`（既有行为），传 `null` → 整块不渲染、工具列表占满高度。
传空列表会渲染「还没有 gate 决策」的空态，把「没接数据」说成「没有决策」。

**移动端弹层必须自己刷新**：`showModalBottomSheet` 是**独立 route**，页面的
`setState` 不会让它重建。故 router 用 `_activityTick`（`ValueNotifier<int>`）当哨兵，
`_bumpActivitySheet()` 从 items / activities / executionStatus / staleTurnIds 四个回调
各调一次，弹层包在 `ValueListenableBuilder` 里。关掉时把 `_activityTick` 置 null 并
`dispose`（否则事件会持续写一个已无人监听、甚至已 dispose 的 notifier）。

#### 三、C：流式进度（`TurnStatusStrip`）

此前调了 8 个工具的长回复，底部**什么都没有**（正文一出现，活动指示就按既有规则
让位），用户看不出「还在干活」还是「已经停了」。

底部槽位的顺序（`conversation_page.dart`，**顺序本身就是判据**）：

```
stale 提示 → 排队/重试状态 → 「已调用 N 个工具 · 最近 X」 → 活动指示（已运行 Xs）
```

- 排队/重试优先于「在跑」：**还没起跑**比**在跑**更该被看见（用户要等的是前者）；
- 工具数优先于活动指示：它包含同样的信息加上「调了什么」，是严格更强的信号；
- stale 最优先：那时客户端已经很久没收到进展，继续报「已调用 8 个工具」就是在撒谎。

**状态派生只扫一遍尾部**：`scanTurnProgress(items, ...)` 从尾往前扫、遇到
`item.turnId != turnId` 立即 `break`（**不能**在遇到 `AssistantMessageItem` 时停——
段级权威帧会夹在工具之间）。页面与面板都调它，`PerfProbe.visitedItems` 的预算
（`<= 2n`，[§6.47](performance.md)）因此不受影响。

#### 测试（7 个文件，共 89 条新增）

| 文件 | 条数 | 钉住 |
|---|---|---|
| `packages/spb_domain/test/tool_call_batch_test.dart` | 16 | 阈值 4 vs 5/6、正文打断、跨轮不合并、空 turnId、`[5][5 文件][5]` → 3 行、成员顺序与 id、`locateIdsOf` |
| `packages/spb_features/test/chat/turn_status_test.dart` | 35 | 状态派生六态 + 单次尾部扫描 + `formatTurnElapsed` |
| `packages/spb_features/test/chat/group_activity_panel_test.dart` | 12 | 状态行、倒序工具列表、`decisions: null` vs `[]`、stale 不显示 spinner |
| `packages/spb_features/test/chat/tool_call_batch_card_test.dart` | 11 | 默认展开/收起、摘要文案、展开后逐条还原、用户意图、自动收起后再次自动展开 |
| `packages/spb_features/test/chat/conversation_page_tool_batch_test.dart` | 9 | 页面真的接了 `groupTimelineForDisplay`、搜索能命中批内成员、底部槽位优先级、`OutboxBar` 不被挤掉 |
| `apps/spb_desktop/test/router_workbench_test.dart` | +2 | 「动态」tab 始终可见、内容渲染 |
| `apps/spb_mobile/test/router_activity_test.dart` | 4 | 宽/窄屏入口、`decisions: null` 不渲染 gate 区、弹层随 SSE 更新 |

#### 反向验证（逐条实测）

| 改坏 | 失败用例 |
|---|---|
| 页面退回 `groupFileEventsForDisplay`（不折工具批） | 3（批卡 / 展开 / 搜索定位） |
| `else if (progress.toolCount > 0)` 改成 `false` | 3（含离线队列条共存） |
| 删掉排队状态槽位 | 1（「还没起跑比在跑更该看」） |
| 删掉 `didUpdateWidget` 的展开同步 | 1（「跑完的那一批会自己收回去」） |
| 删掉 `_syncingExpansion` 守卫 | 1（「自动收起之后同一批又出现执行中 → 必须再次自动展开」） |
| 删掉「用户点过就早退」判据 | 1（⭐「用户手动展开后不得被收回去」——**加固前是假绿**，见下） |
| 四条 `_bumpActivitySheet()` 全删 | 1（移动端「弹层打开后仍随 SSE 事件更新」） |

#### ⚠️ 本轮自己写出来的两处假绿（诚实记录）

1. **⭐「用户手动展开后，后续推送不得把它收回去」原版是假绿**：它只推了两次
   **内容完全相同**的批（`hasRunning` 没有翻转），于是把「用户点过就早退」那条判据
   删掉它照样通过。真正的区分点是**展开→收起的翻转**：用户展开一批已完成的卡 →
   同批又跑起一个工具 → 再跑完，这一次 `true→false` 才会因为缺判据而把用户正在看
   的清单关掉。现版本已补上这三步。
2. **移动端弹层的刷新哨兵「摘掉一条也测不出来」**：控制器每次 `_emit` 都会**重新
   推送** items / activities / executionStatus 三条流（见 `chat_stream_controller.dart`
   的 `_emit`），所以四个回调里三个同时触发。实测单独摘掉任一条都仍绿，只有四条
   全删才红。故那条用例守的是「弹层不会冻住」，**不是**某一条具体 bump——想守到
   具体某一条，得用只产生 items、不重推 activities 的路径驱动，而那在真实控制器里
   不存在，不要写那种断言。

#### 有意不做

- **不在归约层合并工具调用**：见上（搜索 / 定位 / 计数都要逐条 item）。
- **不隐藏工具调用**：折叠 ≠ 删除。展开后逐条还原，工具名、入参、输出全在
  （[§6.47](performance.md) 「隐藏工具调用」那一行已改为「由本节取代」）。
- **不按「连续同类工具名」分组**（如 5 次 `read_file` 一组）：批的语义是「这一轮
  连续做了这些事」，按名字分组会把一次构建拆成多张卡，也会让「最近」失去意义。
- **不给批卡加「全部展开/收起」**：批内每张单卡已有自己的折叠态，再套一层是两套
  状态互相覆盖。
- **不在移动端订阅 gate 决策**：那需要新增一条流 + 一块新 UI，而移动端用小屏看
  gate 明细的诉求没被提出过。`null` 的语义已明确，将来要接只需传值。
- **不做「动态」新路由**：弹层与页面共享 State（`_items` / `_activities` /
  `_executionStatus` / `_staleTurnIds`），另起路由会得到另一份并立刻漂移（[§6.10](architecture.md)
  同一取向）。

### 6.62 目标任务清单「内容被挤占」：`ListTile` → 卡片 + 动作下移（2026-11）

用户报障：桌面端侧边栏「目标」tab 里，任务内容被操作按钮挤得看不见。

#### 根因：`ListTile.trailing` 先占宽度，标题只剩余数

`ListTile` 的布局是「leading / title+subtitle / **trailing**」三区，trailing
按**固有宽度**先占位，剩下的才给标题。本面板最多 5 个行级动作
（编辑 / 状态 / 上移 / 下移 / 删除），而 `IconButton` 的点击区下限是 **48×48**
（`MaterialTapTargetSize.padded`，`visualDensity: compact` **不缩小**它——实测仍是
48×48）——合计 **240dp**。

| 容器宽度 | 标题可用宽度 | 单条高度 | 备注 |
|---|---|---|---|
| **320**（桌面侧边栏定宽） | **0** | **1008dp** | 徽标每枚各占一行 |
| 420（移动端底部弹层） | 92 | 264dp | 标题只剩两三个字 |
| 600 | 272 | 144dp | 勉强正常 |

算术：320 − 内容内边距 32 − 勾选框 48 − trailing 240 = **0**。

⚠️ **不抛异常**：`ListTile` 把标题压成 0 宽是「合法布局」，没有 RenderFlex
overflow，故门禁全绿而界面不可用——与 §6.16（窄屏 AppBar 溢出）同一类
「测试环境比真机宽」的失败模式。

#### 修法（对齐 webapp `GoalTaskEditor` 的卡片结构）

| 改动 | 内容 |
|---|---|
| 容器 | `ListTile` → `Container` 卡片：`border` 用状态色（出错 error / 阻塞 tertiary / 其余中性，完成态更淡），`SpbRadius.cardAll` |
| 标题行 | `[Checkbox(shrinkWrap+compact)] [Expanded(title, maxLines: 3)]` —— 标题独占整行 |
| 描述 / 出错原因 | 各占独立一行（`maxLines` 3~4 + 省略号）。出错原因**不能做成徽标**：它常是一整条编译错误 |
| 徽标行 | 仍是一个 `Wrap`，`task_id` / 状态 / 来源 / `已编辑` / 时间锚点**逐枚独立**（合并成 `·` 连接的一行会破坏精确文案断言） |
| 状态 | 徽标**本身就是** `PopupMenuButton` 的 `child`（点状态即改状态，对齐 webapp 的 `Select`）——比再摆一个 `more_horiz` 少 48dp，也更容易被发现 |
| 动作行 | 卡片**底部** `Align(centerRight) + Wrap`（编辑 / 上移 / 下移 / 删除）。用 `Wrap` 而非 `Row`：移动端弹层最窄约 360dp，折行比溢出好 |

修复后实测（同一 scratch harness）：

| 容器宽度 | 标题可用宽度 | 单条高度 |
|---|---|---|
| 320 + 动作全装配 | **258** | **198** |
| 320 只读 | 294 | 158 |
| 420 | 358 | 154 |
| 600 | 538 | 126 |

即 320dp 下「标题 0 宽 + 一条一屏」变成「标题 258 宽 + 一条 198 高」。

#### 守住它的用例（`goal_tasks_panel_test.dart` 新增 group，3 条）

| 用例 | 钉住 |
|---|---|
| 320dp 且动作全装配：标题仍有可用宽度，单条不撑满一屏 | `physicalSize = 320×1400` 下标题宽 > 150、tile 高 < 260、无异常 |
| 320dp：行级动作在标题**下方** | 四个动作的 `topLeft.dy >= 标题 bottom`（回到同一行就会重新把标题压到 0） |
| 状态徽标本身就是状态菜单的触发器 | 触发器内就是「进行中」那枚徽标文本（不是另一个图标按钮），点开仍有 `goal-task-status-<id>-<s>` 项 |

⚠️ **默认 800dp 窗口的既有 43 条用例发现不了这个问题**——正是它们让缺陷长期存在。
新增的三条必须显式压窗口尺寸（同 §6.16 的做法）。

#### 反向验证（逐条实测）

| 改坏 | 失败用例 |
|---|---|
| 把动作行塞回标题同一行（复现原缺陷） | **2**（标题宽度 / 动作在下方） |
| 状态改回「普通徽标 + 独立 `more_horiz` 按钮」 | **4**（含新增的状态触发器用例 + 3 条既有只读/菜单用例） |

#### 有意不做

- **不改新增任务行**（`goal-task-add-field` + `goal-task-add-button`）：它不挤列表，
  改成 webapp 的「按钮展开成输入框」会破坏多条既有用例，收益不抵。
- **不改 header**（目标文本 2 行 + 进度文本 + 进度条 + 需要人工处理的提示）：
  它不是挤压源，且 `goal-tasks-progress-*` 的文案口径被测试钉住。
- **不把徽标合并成单行 `·` 连接**：时间锚点（`开始 …` / `完成 …` / `跳过 …`）
  被精确文案断言钉住，且窄栏里合并后仍会换行，没有收益。

### 6.70 无归属输入页（移动端）：桌面键盘提示 + 返回键静默丢草稿（2026-11）

同一个页面被两种宿主复用（桌面悬浮窗 / 移动端整屏页，见 §6.7 与
[§6.68](platform.md)），由此露出三个只在移动端成立的问题：

| # | 症状 |
|---|---|
| ① | 底部状态行固定显示「Enter 提交 · Shift+Enter 换行 · Esc 清空」——手机上**没有这些键**，用户会去找 Esc |
| ② | 系统返回键/返回手势直接弹出路由，已输入的文字与附件**静默消失**。桌面端 `Esc` 是两段语义（先清空、空了才关），移动端没有等价保护 |
| ③ | `_pickFiles` 的注释写「移动端会静默返回空」，与实现矛盾（`file_selector` 在 Android/iOS 均可用，移动端 router 的注释也这么写）——注释会误导后来者给移动端「补」一个已存在的功能 |

#### 修法

| 改动 | 说明 |
|---|---|
| `showKeyboardHints`（默认 `false`） | 桌面端接线传 `true`，移动端不传。关掉时状态行返回**空占位**而不是删掉整块——这一行还承担 `Hint`（错误/警告）与上传进度 |
| `PopScope(canPop: false)` + `_handleSystemBack` | 提交中 → 内联提示「正在发送，请稍候…」；有草稿 → 弹框「丢弃 / 继续编辑」；无草稿 → 直接关 |
| `_hasDraft` 上提 | 「草稿」判据同时用于 `Esc` 两段语义与返回键确认框；各写一遍迟早不一致（表现就是某条路径静默丢内容） |
| 注释纠正 | `_pickFiles` 改成「两端都用 `file_selector`，只有拖拽是移动端没有的」 |

#### 为什么返回键「弹框」而不是照搬 `Esc` 的两段语义

手机上返回手势是**高频误触**动作：「第一次返回只是清空」会让用户以为返回无效、
再按一次才关窗；而静默丢弃则是「白打一遍」。明确的「丢弃 / 继续编辑」二选一
没有歧义。桌面端保持原语义（`Esc` 清空 → 再按关窗）：那里有真键盘，两段语义
是防「误按 Esc 想清字却关窗」。

#### 为什么确认后走 `onClose` 而不是 `Navigator.pop`

1. 桌面端要先**退出悬浮窗形态**（还原窗口几何/置顶/任务栏）再导航，那段逻辑在
   装配层，页面看不见；`onClose` 是唯一出口（与「取消」按钮同一出口）。
2. `PopScope(canPop: false)` 下再调 `Navigator.pop()` 会二次触发
   `onPopInvokedWithResult`（除非额外加「已放行」标志 + 等一帧），而走
   `onClose`（`context.go`）根本不经过 pop 流程。

#### 测试

| 位置 | 钉住 |
|---|---|
| `packages/spb_features/test/quick_capture/overlay_quick_capture_page_test.dart` | 默认不显示键盘提示；`showKeyboardHints: true` 显示；提示/进度仍显示；返回 + 有草稿 → 弹框且「确认前不关窗」；「继续编辑」草稿还在；返回 + 无草稿 → 不弹框直接关；提交中返回 → 不关窗且给出提示（7 条） |
| `apps/spb_desktop/test/router_overlay_test.dart` | 从**路由**进入后确实看得到快捷键说明（= `showKeyboardHints` 已接线） |
| `apps/spb_mobile/test/router_list_test.dart` | 从 FAB 进入后**看不到**快捷键说明 |

页面自己的测试测不到「router 忘了传参数」——它自己传两种宿主各测一遍。

#### 反向验证（逐条实测）

| 改坏 | 失败用例（实测） |
|---|---|
| 状态行不再区分宿主（永远显示键位说明） | 页面 **1** 条 + 移动端 router **1** 条 |
| `canPop: true`（恢复静默丢弃） | 页面 **4** 条 |
| 去掉提交中的拦截 | 页面 **1** 条 |
| 无草稿也弹框 | 页面 **1** 条 |
| 桌面端不传 `showKeyboardHints` | 桌面端 router **1** 条 |

#### 已知边界

- **iOS 边缘滑动返回被禁用**（`canPop: false` 时系统不启动手势）：iOS 用户只能
  点「取消」或系统返回键。要保留手势就得在确认后「先放行再 pop」，代价是
  `canPop` 时序（见上文第 2 点），当前选择是**明确性优先**。
- **`showKeyboardHints` 是宿主注入而非能力探测**：Flutter 没有「是否接了外接
  键盘」的查询（`HardwareKeyboard` 只在按键事件里可见），故带外接键盘的平板
  也看不到键位说明——这是有意的取舍（宁可少提示，也不要给手机用户看 `Esc`）。

### 6.73 对话设置面板露出 `group_id`（可选中 + 一键复制，2026-11）

`group_id` 是**唯一能把客户端现象与服务端对上号**的标识：日志（`对话历史回填完成 groupId=…`）、
导出诊断报告的「时间线快照」小节、服务端 slog 字段、UFS 工作区路径 `/workspace/groups/{gid}/`
全都用它。而它在客户端此前**任何界面都不显示**——用户报障只能口述「那个对话」，开发者要拿 id
只能去翻本地 `app.log` 或 `sync.db`。

#### 放在哪、为什么

| 候选 | 判定 |
|---|---|
| **`GroupSettingsPanel` 末尾（采用）** | 面板已持有**权威** `ChatGroup`（`group.id`）→ 不加参数、不加 provider；两端 router 现有接线直接带出，故没有 §6.17「两端接线不一致」的失败面 |
| 对话列表项的长按菜单 | 需要新回调 + 两端各接一次，且「在哪个对话里」与「列表里哪一项」是两处状态，容易复制到别 group 的 id |
| AppBar 标题长按 / 点击 | 不可发现：没有任何视觉线索，用户不会去长按标题 |
| 重开调试面板 | `GroupDebugPanel` 已删（§6.54）：为一条只读文本恢复一个面板，把删掉的东西又装回来 |

排在面板**最后**（`_ttsSection` 之后）：它是低频调试信息，不该把「目标 / 自动续跑 / 语音」这些
常用设置往下挤。`id` 为空（占位 group、事件快照缺字段）时**整节省略**——渲染一行空白加一个
「复制空串」的按钮比不渲染更糟。

#### 交互

- `SelectableText`（单行，**不**省略成 `…` 之外还保留选中能力）：只想肉眼核对前缀的人不必点按钮；
  复制走 `CopyIconButton`（`spb_ui`），写入的是**完整 `widget.group.id`** 而不是显示文本。
- `busy`（有写操作在途）时**不禁用**：复制是只读操作，与 CAS 写并发无关。

#### 测试（`group_settings_panel_test.dart` 新增 group，3 条）

| 用例 | 钉住 |
|---|---|
| 展示 `group.id` 且点击复制写入完整 id | 平台通道拦截 `Clipboard.setData`，断言参数是 `grp_1` 而非截断显示值 |
| `id` 为空时整节省略 | 滚到底后 `group-id-copy` / `group-id-value` 均 `findsNothing` |
| `busy` 时仍可复制 | `CopyIconButton` 内的 `IconButton.onPressed != null` |

⚠️ 面板是 `ListView(children:)` 而 `SliverChildListDelegate` **懒建**：新用例必须先
`scrollUntilVisible`，否则 `find.byKey` 拿到「没有元素」（`ensureVisible` 也不行，它同样要求已建）。

#### 有意不做

- **不在列表页 / AppBar 再放一份**：同一事实两处入口 = 两处状态要同步，而设置面板这一处已覆盖
  「我就在这个对话里，要拿它的 id」这个唯一真实场景。
- **不显示 `user_id` / `turn_id`**：用户侧报障场景用不到；`turn_id` 已在动态面板的工具调用里可见。

### 6.76 列表页文字偏小：`SpbType` 语义令牌 + 元数据 11px→12px（2026-11）

#### 缺陷

列表类页面（对话列表、我的回合、工作台、习惯、待确认、搜索）的**元数据行**
（相对时间、状态词、来源、所属群名）几乎全部用 `textTheme.labelSmall`——
Material 3 下它是 **11px / w500 / letterSpacing 0.5**，且这套参数是为拉丁字母
小标签设计的。侧边栏角标甚至硬编码 `fontSize: 10`（全应用最小的字放在最需要
被看见的未读数上），tab 标签也用 11px（比内容区元数据还小，主次颠倒）。

中文笔画密度高，小字号可读性衰减比拉丁字母快得多；且「结项记录生成失败」
这类带 error 语义色的**状态词**也用 11px，用户需要读懂的不只是装饰。

#### 根因链（排查时容易误判的三处）

1. **`ThemeData().textTheme` 的 fontSize 全是 null**。几何信息（字号/字重）由
   `Theme.of(context)` 在运行时经 `ThemeData.localize(theme,
   typography.geometryThemeFor(scriptCategory))` 合并 `englishLike2021` 才得出。
   测试里断言字号必须走同一条 localize 路径（见 `tokens_test.dart` 的
   `resolve()`），否则断言的是 null。
2. **`listTileTheme.dense: true` 会硬改 ListTile 字号**（`list_tile.dart` 的
   `fontSize: _isDenseLayout ? 13.0 : null`），且发生在**显式 style 之后**的
   `copyWith`——`my_turns_page` 曾给 title 显式写 `bodyMedium`（意图 14px）
   实际渲染 13px。dense 在 M3 下官方明确不建议（`list_tile.dart:501`），
   本次**未动**它（影响面全局，另立决策）。
3. **golden 不保护列表页**：4 张 spec 卡 golden 只盖 `spec_ui_card` /
   `map_spec_card`。本次唯一受影响的基线是 `map_spec_card`（画布标签 11→12）。

#### 修法：语义令牌（`SpbType`），不是逐处改字号

新增 `packages/spb_design/lib/src/type.dart`，把「某类 UI 文字该多大」收敛为
一处，页面按语义取用而非各自挑 TextTheme 槽位（挑槽位的人未必记得槽位的
实际字号）：

| 语义 | 令牌 | 实际样式 | 替换掉的 |
|---|---|---|---|
| 列表元数据行（时间/状态/来源） | `SpbType.listMeta` | `bodySmall`（12 / w400） | `labelSmall`（11） |
| 徽标 / 状态 chip / tab 标签 | `SpbType.badge` | `labelMedium`（12 / w500） | `labelSmall`（11） |
| 角标数字 | `SpbType.badgeCount` | `labelSmall` 归零 letterSpacing（11） | 硬编码 `fontSize: 10` |

下界由 `tokens_test.dart` 钉住（元数据/徽标 ≥12、角标 ≥11）；想把字改小先改
`SpbType` 并同步测试，**不要**在页面里 `copyWith(fontSize: …)`。

#### 迁移范围（列表页优先，聊天面板留待后续）

- **列表页全量迁移**：`group_list_page` / `my_turns_page` / `chat_sidebar`
  （tab + 角标）/ `search_page` / `conversation_search_sheet` /
  `pending_confirmations_page` / `habit_runs_page` / `habits_page` /
  `works_page` / `work_detail_page`。
- **硬编码清理**：`map_spec_card` 画布标签 11→12（经 golden 复核）、
  `agent_switcher` 菜单头加注释说明为何保留 12。
- **有意不改**：聊天内面板（`turn_detail_panel` / `agent_picker` /
  `group_settings_panel` 等）与设置/同步页——它们是对话流的附属 UI，
  字号层次与列表页不同，留待与 dense 决策一起统一。
  （**已完成**：实测剩余 **68 处**，不是当初估的 ~30；见 §6.78。）

#### 有意不做（→ 已由 §6.77 接手）

- ~~**不摘 `dense: true` / `VisualDensity.compact`**~~：**已做**，见 §6.77
  （密度按平台分支 + 两端摘 dense）。
- **不改 `labelSmall` 本身**：它是 Flutter 组件的默认槽位（`Badge` 等内部
  用），改主题槽位会外溢到没审计过的组件——这一条仍成立。

### 6.77 密度按平台分支：摘掉全局 `dense` + `VisualDensity` 分端（2026-11）

承接 §6.76（本文上文）：字号修完后，剩下两个全局密度设置一并收口。

#### 缺陷

`SpbTheme` 曾无条件设 `visualDensity: VisualDensity.compact` +
`listTileTheme.dense: true`，注释写「桌面端」，实际**两端共用**。后果：

1. **移动端触控目标不达标**：单行 ListTile = 56 − 8(compact) − 8(dense) = 40dp，
   低于 Material 48dp 指导线。
2. **dense 的 13px 陷阱**：M3 下 dense 把 ListTile 标题硬压到 13px
   （`list_tile.dart:925` 的 `fontSize: _isDenseLayout ? 13.0 : null`），且发生在
   **显式 style 之后的 copyWith**——`my_turns_page` 曾给 title 显式写
   `bodyMedium`（意图 14px）实际渲染 13px。这个覆盖**无法用显式样式对抗**，
   只有不设 dense。官方也明确不建议（`list_tile.dart:501`）。

#### 修法

`_build` 里按 `target` 分支（沿用 `lightFor(platform)` 的注入模式）：

| 设置 | 桌面（win/mac/linux） | 移动（android/ios/fuchsia） |
|---|---|---|
| 全局 `visualDensity` | `compact` | `standard` |
| `listTileTheme.dense` | **删除**（两端都不设） | 同左 |
| `listTileTheme.visualDensity` | `compact`（只压行高不碰字号） | null（M3 默认） |
| `listTileTheme.titleTextStyle` | `titleSmall`(14/w500) + `onSurface` | null（M3 默认 bodyLarge(16)） |

要点：

- **桌面端显式 `titleSmall` 而非靠 dense 偷字号**：裸 M3 的 ListTile 标题是
  bodyLarge(16)，对中文列表行偏大；显式钉在 14，与 §6.76 的令牌层次衔接
  （元数据 12 < 标题 14）。「以为 14 实际 13」的落差从机制上消失。
- **字号几何直接取 `Typography.material2021(...).englishLike`**：裸
  `ThemeData` 的 textTheme fontSize 为 null（几何由 `Theme.of` 经 localize
  合并，见 §6.76 根因链第 1 条），构造期拿不到现成样式，取同源几何主题。
- **移动端不设 titleTextStyle**：移动端列表标题保持 M3 默认 16px——触屏
  阅读距离更远，大一号是合理的平台差异，不是不统一。

#### 验证（几何断言钉住，`tokens_test.dart`）

- 移动端单行 ListTile 实际高度 **≥48dp**（回归到合规触控目标）；
- 桌面端单行 **<56dp** 且 ≥40（compact 真的在压行高，静默退化会被拦住）;
- 明暗两套分支一致（dark 不会漏分支）。

golden 重出 2 张（`spec_ui_follow_up_card` / `error_state_with_retry`）：
diff 图确认只是按钮胶囊高度 compact→standard 的预期变化（测试环境
`defaultTargetPlatform == android`，落移动端分支）。

#### 未验证（本机边界，§9）

- 真机观感：移动端行高变化（40→48）后一屏行数变少、桌面端列表标题
  13→14 的视觉密度，需按 `docs/` 手工验证清单在设备上复核。
- Windows/macOS 桌面分支本机只验证了主题构造与断言，未跑真机。

#### 有意不做

- **不给移动端设 `titleTextStyle`**（理由见上）。
- **不动面板内 `labelSmall`**：它们与旧 dense(13px) 语境配套，现桌面标题
  已是 14px，字号层次变化后应逐个语义判定，另立一轮。
  （**已完成**：§6.78 逐个判定并迁走全部 68 处，11px 归零。）

### 6.78 聊天面板字号收口：68 处 `labelSmall` 迁走 + 小字禁降透明 + 字号守卫（2026-11）

承接 §6.76/§6.77 留的尾巴。§6.76 当时估「聊天内面板约 30 处 `labelSmall`
留待后续」，实测是 **68 处**——估算差了一倍多，因为面板在每个文件里只占一两行
（`turn_detail_panel` 8 处、`conversation_page` 8 处、`map_spec_card` 4 处、
`overlay_quick_capture_page` 4 处、`group_gate_panel` 4 处，其余 23 个文件各 1–3 处）。

#### 缺陷

1. **68 处 11px 里，大多数不是装饰**。它们是要读懂的状态语：
   - `队列：总计 $total，你的 $user`（`conversation_page` 执行状态条）
   - `最近：$last`（上一事件）、`$parts 段`（TTS 完成段数）
   - `目标已停止：…` + 错误项正文（`goal-gate-stopped` 提示）
   - `事件可能已超出时间线窗口，或尚未落库。`（详情面板的空态说明）
   - `含 N 个已删除`（文件批次卡）、`置信度 N%`、`N 个文件`、错误说明
   `12px` 是 §6.76 定下的可读下界，11px 明显在下界之下。
2. **6 处 11px 与 `withValues(alpha: 0.7/0.75)` 叠加**。小字号 + 低对比度是
   **乘法**叠加：字号已经在下界时再降透明度，实际对比度掉到几乎读不清
   （`队列：…`、`最近：…`、`N 段`、`路由归属` 都中招）。
3. **2 处裸字号仍是字面量**：`map_spec_card` 的画布标签
   `TextStyle(fontSize: 12)`、`agent_switcher` 菜单头 `const TextStyle(fontSize: 12)`。
   根因不是懒——旧令牌 API 只返回 `TextTheme` 槽位（`SpbType.listMeta(TextTheme)`），
   而这两处拿不到 `TextTheme`：一处是 `CustomPainter` 里的 `TextPainter`（只要
   `TextStyle`），一处是 `const` 上下文。

#### 修法

`SpbType` 扩到 5 个语义 + 1 个字面常量（`packages/spb_design/lib/src/type.dart`）：

| 语义 | 令牌 | 实际样式 | 本轮用途 |
|---|---|---|---|
| 元数据 / 状态词 / 数量 / 说明 | `listMeta` | `bodySmall`（12 / w400） | 取代面板里 11px 的同类文案 |
| 徽标 / 状态 chip / 分组头 | `badge` | `labelMedium`（12 / w500） | chip、`已归档`、组头、`参数`/`结果` |
| 角标 / 计数胶囊 | `badgeCount` | `labelSmall` 零字距（11 / w500；§6.81 抬到 12） | 待处理计数胶囊 |
| 正文 | `body`（新） | `bodyMedium`（14 / w400） | 用户/助手气泡（原先直接挑槽位） |
| 块标题 | `cardTitle`（新） | `titleMedium`（16 / w500） | spec 卡、文件预览卡的标题 |
| 绘制字号 | `metaSize`（新，`double`） | 12.0 | `TextPainter` 用，与 `listMeta` 同值 |
| 等宽文字（§6.81） | `mono`（新） | `base`（默认 `listMeta`）+ `monospace` + CJK 回退 | 登录码、工具卡、文件预览 |

`body` / `cardTitle` 是**零像素变化的重命名**：原先那 5 处直接写
`textTheme.bodyMedium` / `titleMedium`，换成令牌后渲染完全一致（`spec_ui_card`
的 3 张 golden 因此不变）。价值在于「同一语义两个槽位」的挑槽位问题不再存在：
块标题 16、行标题 14、正文 14、元数据 12 这条层次由令牌与断言固定。

三条新规则写进 `SpbType` 文档，前两条由守卫检查：

1. **禁止裸字号**（`fontSize: 数字`）。绘制场景用 `fontSize: SpbType.metaSize`。
2. **`labelSmall` 必须就地说明理由**（纯装饰或受 golden 锁定的基线）。
3. **小字号不再叠加透明度**：颜色直接给 `onSurfaceVariant` /
   `onSecondaryContainer` 原色。层次靠字重（`w600`）或主题色，不靠降透明。

#### 迁移判定（68 处 → 0）

| 原位置 | 判给谁 | 依据 |
|---|---|---|
| 时间、来源、数量、费用、队列/最近/段数、错误说明、空态说明 | `listMeta` | 都是「要读懂」的正文级小字 |
| 状态 chip、分组头、`当前`、`已归档`、`参数`/`结果`、类别胶囊、置信度 | `badge` | 面积小但一眼识别，靠字重区分 |
| 待处理计数胶囊 | `badgeCount` | 纯数字，字距归零 |
| `turn_detail_panel` 的 `用户输入`、`下一步输入预览` | `badge` | 区块标签，不是元数据 |
| `map_spec_card` 的地点/路线小节头 | `badge` | 带图标的小节标签 |
| `overlay_quick_capture_page` 的状态行、快捷键说明、附件大小 | `listMeta` | 与 `HintLine`（`bodySmall`）同一档 |

同时归零的 6 处透明度：`conversation_page` 4 处（`N 段` / `队列` / `最近` /
目标停止的 `turns`）、`turn_status` 1 处（状态详情）、`pending_messages_bar`
1 处（agent 类型）。

#### 守卫（`tools/check_type_tokens.sh`，本轮新增）

没有守卫的清扫＝两周后长回来，而且**任何测试都不会红**（golden 只盖 12 张
按钮/空态/spec 卡，面板一张都没有）。守卫扫 `packages/*/lib` 与 `apps/*/lib`
（排除令牌本身所在的 `packages/spb_design/lib`）的两条规则：

| 规则 | 免死金牌 |
|---|---|
| 数字字号字面量（`fontSize: 12`） | `fontSize: SpbType.metaSize` 等非数字形态放行 |
| `labelSmall` | 该行或前两行写 `// 字号守卫豁免：<理由>`（理由必须非空） |

- 用**就地注释**而非白名单：与 `tools/check_silent_catches.sh` 同一条理由
  （白名单随文件改名腐化，而「记得加白名单」正是要避免的「靠人记得」）。
- **空转保护**：扫描范围内一处 `SpbType.` 调用都没有时硬失败，不报「通过」。
- 自测 8 条（`tools/check_type_tokens_selftest.sh`）：数字字面量、无理由
  `labelSmall`、带理由豁免、空理由豁免、`SpbType.metaSize`、
  注释里的 `fontSize: 10`、`spb_design` 内的定义、空转。

#### 验证

- `tokens_test.dart` 新增 4 条断言：`body` / `cardTitle` 下界、
  层次顺序（`listMeta ≤ badge < body < cardTitle`）、
  `metaSize` 与 `listMeta` 同字号（防止画布与列表差一个像素）。
- `flutter test`：`spb_features` **1428 条全过**（含 4 张 spec/map golden）、
  `spb_design` 47 条全过；`dart analyze` 干净。
- golden 重出 **1 张**（`map_spec_card.png`，11→12）：像素 diff 只落在
  y 438–492（地图下方的「地点/路线」列表区，744 个像素），轨迹图与画布标签区
  **零变化**——确认没有连带布局跳动。
- 守卫对本仓库实测：234 个文件、103 处 `SpbType` 调用、0 处裸字号、
  0 处无理由 `labelSmall`。

#### 未验证（本机边界，§9）

- 真机观感：面板里 11→12 的密度变化（尤其 `turn_detail_panel` 的 chip 行、
  `map_spec_card` 的小节头）需要在设备上复核。
  （`turn_detail_panel` 后来补了两张基线，见 §6.83；`map_spec_card` 的小节头
  一直由 `map_spec_card.png` 覆盖。）
- `agent_switcher` 菜单头由 `const` 改为运行时样式后，弹层宽度随文案/字宽
  自适应——单测只断言条目存在，未测宽度。

#### 有意不做

- **不改 `labelSmall` 主题槽位本身**：Flutter 组件（`Badge` 等）内部用它，
  改槽位会外溢到没审计过的组件（§6.76 的结论仍成立）。
- **不动 `PopupMenuItem(height: 36)` 与画布 `maxWidth: 120`**：它们属于
  「固定高度 + 文字」的系统字体缩放问题（属于下一轮）。
- ~~**不做 CJK 字距/行高校正**~~：**已做**，见 §6.79（`Typography` 三套几何校正 + 12 张
  golden 重出 + 行高断言）。

### 6.79 CJK 度量校正：字距归零 + 行高 ≥1.5（2026-11）

承接 §6.78 的「不做 CJK 校正，单独立一轮」。字号已经定了（§6.76/§6.78），
这一轮只改**度量**：字距与行高。

#### 缺陷

M3 的字距/行高是**拉丁文**的度量，中文一直在穿这身不合身的衣服：

| 槽位 | M3（拉丁） | 中文实际需要 |
|---|---|---|
| `bodySmall`(12) | `letterSpacing 0.4` / `height 1.33`（16px） | 字距 0；行高 ≈18px |
| `bodyMedium`(14) | `ls 0.25` / `height 1.43`（20px） | 字距 0；行高 ≈21px |
| `labelMedium`(12) | `ls 0.5` / `height 1.33` | 字距 0；行高 ≈18px |
| `labelLarge`/`titleSmall`(14) | `ls 0.1` / `height 1.43` | 字距 0；行高 ≈21px |

0.4px 在 12px 上是 **3%** 的额外字距——中文是等宽方块字，字距不需要「补」，
补了就是密排正文发虚；而 12px 只给 16px 行高，对笔画密度远高于拉丁的中文
明显偏挤（没有 ascender/descender 的天然节奏可借）。

此前唯一的特例是 `SpbType.badgeCount`（在实例上把字距归零，§6.76），
其余 200+ 处中文都在用拉丁 tracking。

#### 为什么以前没修（根因链）

1. **几何的真源是 `Typography` 的三套 `geometryTheme`**，不是 `ThemeData.textTheme`
   （后者的 `fontSize` 构造期为 null，见 §6.76 根因链第 1 条）。页面按槽位取名
   `labelSmall`/`bodySmall` 时，看到的是「槽位」而不是「0.5 / 1.45」，
   没人会去查字距——这正是 §6.76 里解释过的同一个盲点。
2. **三套几何按 locale 的 `scriptCategory` 选**（`englishLike` / `dense` / `tall`），
   任何在页面级或单一几何上的修补，中文 locale（落 `dense`）都不生效。
3. **动它必然重出全部 12 张 golden**，而 §6.77 的行高断言（移动端 ListTile
   ≥48dp / 桌面 ≤56dp）与行高耦合，需要一起复核。

#### 修法

`SpbTheme` 里新增 `_cjkTypography` / `_cjkTextTheme` / `_cjkStyle`
（`packages/spb_design/lib/src/theme.dart`），在 `Typography` 层做一次校正：

| 规则 | 值 |
|---|---|
| `letterSpacing` | **0**（仅 `bodyLarge`/`bodyMedium`/`bodySmall`/`labelLarge`/`labelMedium`/`titleSmall`/`titleMedium`） |
| `height` | **max(原值, 1.5)**（同一批槽位；`bodyLarge`/`titleMedium` 原就是 1.50，不变） |
| 三套几何 | `englishLike` / `dense` / `tall` **一起**校正（只改一套 = 测试绿、中文真机无效） |

要点：

- **`labelSmall` 一字不改**：它是 Flutter 组件（`Badge` 等）的内部槽位，
  改它会外溢到没审计过的组件（§6.76 的结论仍成立）。11px 角标数字的字距
  仍由 `SpbType.badgeCount` 在实例上归零。
- **`headline*` / `display*` / `titleLarge` 不动**：它们是短的单行标题
  （空态标题、登录短码），行高对可读性没有收益，动它只会扩大 golden 面。
- **为什么改 `Typography` 而不是 `ThemeData.textTheme`**：两处都能生效
  （`ThemeData.localize` 的 `merge` 以 `baseTheme.textTheme` 的非空字段为先），
  但 `typography` 是三套几何的唯一真源，且本类的
  `listTileTheme.titleTextStyle` 也直接读 `typography.englishLike`——各写一遍
  必然漂移。
- **`Typography` 用 `defaultTargetPlatform` 而不是注入的 `target`**：
  `Typography` 除了几何还携带**平台字体回退链**（Linux 是 `blackHelsinki`
  的 Ubuntu/Adwaita/Cantarell…）。测试环境 `defaultTargetPlatform == android`，
  若按注入的 linux 取，golden 会在本机渲染出与 CI 不同的字形
  （`fonts_test.dart` 有一条专门钉住这件事，本轮一度被它抓住）。

#### 验证

`tokens_test.dart` 新增 4 条断言：

- 五个语义令牌一律零字距；
- 正文（`bodySmall`/`bodyMedium`/`labelMedium`/`titleSmall`）行高 ≥1.5×字号；
- `labelSmall` 与 SDK 原始几何**逐字段相同**（把「有意不改」变成机器可查的）；
- `dense` / `tall` 两套几何同样被校正。

12 张 golden 重出，逐张统计（diff% / 内容高度变化 / 差异是否只在文字区）：

| 基线 | diff | 内容高度 | 差异性质 |
|---|---|---|---|
| `spec_ui_goal_card` | 4.74% | +8px | 4 行正文各 +2px，卡片整体居中上移 |
| `spec_ui_unknown_type` | 4.62% | +5px | 同上 |
| `map_spec_card` | 3.11% | +11px | 地图卡内各行 +2px，画布随之上移（画布本身逐像素相同） |
| `spec_ui_follow_up_card` | 1.40% | +2px | 标题/说明行高 |
| `hint_line_kinds` | 1.60% | +4px | 三行提示各 +1–2px |
| `error_banner_*` | 1.11–1.15% | 0 | 单行文字字距归零（宽度略收） |
| `empty_state_*` | 0.30–0.82% | 0 | 同上 |
| `error_state_*` | 0.13–0.56% | 0–1px | 同上 |
| `section_title` | 0.33% | 0 | 同上 |

全部差异的 bbox 都紧贴文字区域（没有边框/背景/图元变化），且**没有一条
overflow 报错**（`RenderFlex overflowed` 在 widget 测试里是硬失败）。

测试：`spb_design` 51 条、`spb_ui` 43 条、`spb_features` **1428 条**、
`spb_platform` 281 条、`spb_mobile` 全过。`apps/spb_desktop` 有 13 条
`router_workbench_test` 失败——经 `git stash` 对照确认**改动前就存在**
（本机环境问题，与本轮无关）。

#### 未验证（本机边界，§9）

- 真机观感：中文密排在 12→18px 行高后的实际密度、桌面列表行高变大后的
  一屏行数，需在设备上复核。
- Windows / macOS 的平台字体回退链未在本机跑（测试只跑 android 目标）。

#### 有意不做

- **不改任何字号**：这一轮只动度量；字号仍由 §6.76/§6.78 的令牌与下界管。
- **不做「中文 12px、数字 11px」这类按字符类型分流**：Flutter 的
  `TextStyle` 不按字符分类，按脚本分流要靠手写 fallback 字体族，代价远超收益。
- **不引入 `TextScaler` 策略**：系统字体缩放是下一轮（`PopupMenuItem(height: 36)`、
  `maxLines: 1`、画布 `TextPainter` 不跟随缩放都在那里）。

### 6.80 系统字体缩放（a11y）：决定**不** clamp，画布文本跟随缩放（2026-11）

§6.79 之后字号与度量都定了，剩下的问题不再是「多大」，而是
**用户把系统字号调大之后会怎样**。

#### 议题（两个，性质完全不同）

| # | 议题 | 性质 |
|---|---|---|
| 1 | `map_spec_card` 画布上的地点标签是 `TextPainter` 手绘的，字号固定 12px | **真缺陷**：卡片其余文字跟着系统字号放大，地图标签不动（视觉不一致 + 放大字号的用户仍读不到） |
| 2 | 要不要在 `MaterialApp.builder` 里把 `textScaler` clamp 到 1.3「顺手修溢出」 | **决策题**：先量清楚有没有溢出，再决定 |

#### 先量，再改（第 2 题的数据）

用真实长度文案（长标题 + 长输入 + 多段回复 + 长路径工具调用）在对话页测
1.0 / 1.3 / 2.0 三个倍率：**三个倍率下都没有任何 overflow**。
再静态扫「固定高度 + 文字」的组合（`SizedBox`/`Container`/`ConstrainedBox`
窗口内同时出现 `height:` 与 `Text(`）：`spb_ui` + `spb_features` 仅 8 处候选，
且基本都是纯间距 `SizedBox`，没有「固定高度去装文字」的坏点。

结论：本仓的布局是 **intrinsic sizing** 为主（面板、气泡、胶囊都不写死高度），
2.0 倍也容得下。

#### 决定：**不** clamp `textScaler`

- clamp 等于**静默吞掉**系统无障碍设置：用户把字号调到 2.0 是有理由的，
  我们改成 1.3 就是「你说要大，我偏只给一点点」，且**没有任何提示**。
- 代价是不对称的：溢出（黄黑斜纹）是**看得见**的 bug，偷偷限幅是**看不见**的
  bug；后者更难被发现、更难被投诉到。
- 溢出风险已经实测为 0。若将来真的出现溢出，正解是把那个固定高度改成
  `minHeight` / intrinsic（`PopupMenuItem.height` 本身就是 `minHeight` 语义，
  见 `packages/flutter/lib/src/material/popup_menu.dart` 的
  `BoxConstraints(minHeight: widget.height)`），而不是削字号。
- 因此 `apps/*/lib/app.dart` 的 `MaterialApp.router` **不加** `builder`：
  缩放策略就是「跟随系统，不干预」。

#### 修法（第 1 题）

`_MapPainter` 增加 `required this.textScaler`（在 `build` 里取
`MediaQuery.textScalerOf(context)`），传给 `TextPainter(textScaler: …)`，
并纳入 `shouldRepaint` 的比较（少了这一条，改字号不会重绘）。
`layout(maxWidth: 120)` 保持不变：放大后标签会更早触发省略号——这正是
「辅助信息让位给可读性」的预期行为（完整标题由下方列表承载）。

#### 守卫

| 守卫 | 钉住什么 |
|---|---|
| `packages/spb_features/test/chat/text_scale_test.dart` | 1.3 / 2.0 倍下对话页无 `FlutterError`（溢出是硬失败），且助手回复仍渲染 |
| 同上第三条用例 | **2.0 倍下正文渲染高度 ≈2×**（`moreOrLessEquals(2.0, epsilon: 0.15)`）——专门防「有人为了修溢出在 `builder` 里 clamp」：那种改法让溢出消失、无障碍也消失，**现有测试一条都不会红** |
| `goldens/map_spec_card_scale2.png` | 2.0 倍下画布标签确实放大。变异测试：去掉 `textScaler` → 该基线红（990px / 0.22%） |

#### 写这类测试的三个坑（都踩过）

1. **默认测试画布是 800×600**（`tester.view.physicalSize`）。2.0 倍时先撞天花板的是
   **画布**而不是组件——本用例第一版就报 `Column` 溢出 19px，差点误判成卡片的 bug。
2. **对话页有常驻动画**（流式指示器），`pumpAndSettle` **必然**超时；用两次
   `tester.pump(Duration(milliseconds: 200))`。
3. **助手回复走 markdown（RichText）**，`find.textContaining` 必须带
   `findRichText: true`，否则「找不到」被误读成「放大后没渲染」。

#### 未验证（本机边界，§9）

- iOS / Android 真机的系统最大字号档（本机无真机）；
- 桌面端：Linux 不上报 OS 缩放（恒 1.0），Windows / macOS 的上报行为未在本机跑。

#### 有意不做

- **不 clamp**（见「决定」）；
- **不做应用内「字号设置」项**：系统已有该设置，再加一个就是双重缩放，
  且要自己维护一整套倍率 → 令牌映射；
- **不给所有 `maxLines: 1` 补 `ellipsis`**：18 处里 16 处已有；剩下两处是
  `TextField`（单行输入靠滚动，不裁剪）与等长的对话 ID（`SelectableText`
  本身不支持 `overflow`），改了没有收益。

### 6.81 等宽文字令牌 `SpbType.mono` + 角标数字 11→12（2026-11）

§6.78 之后还剩两块「同样的东西写了好几遍」的地方。

#### 缺陷

1. **等宽样式 6 处各写一遍**：`login_page`(2)、`agent_file_preview`、
   `tool_call_tile`(2)、`group_gate_panel`。其中 4 处手写了
   `fontFamilyFallback: SpbFonts.monoFallback`，**`login_page` 的两处漏了**。
   码本身是字母数字，暂时没暴露；但下一个人把这段样式复制给「含中文的输入预览」
   就会中招——中文落到引擎的隐式回退，字形不可控（`SpbFonts` 类文档）。
   根因是**一个语义需要写两行**（`fontFamily` + `fontFamilyFallback`），
   复制粘贴必然漏掉一半。
2. **角标数字是全仓唯一低于可读下界的字号**：`badgeCount` 取 `labelSmall`
   的 11px，而它恰好用在「最需要被看见」的未读数上（§6.76 的原始缺陷就是
   侧边栏硬编码 `fontSize: 10` 的角标）。§6.78 之后其他令牌都 ≥12，11 成了独苗。

#### 修法

| 令牌 | 定义 | 调用点 |
|---|---|---|
| `SpbType.mono(TextTheme, {TextStyle? base})` | `(base ?? listMeta)` + `fontFamily: 'monospace'` + `fontFamilyFallback: SpbFonts.monoFallback` | 登录码输入（`base: bodyLarge`）、短码大图（`base: headlineMedium`，另带 w700/字距 6）、工具卡标题（`base: labelLarge`）、工具入参预览、文件内容预览、gate 预览 |
| `SpbType.badgeCount(TextTheme)` | `labelSmall?.copyWith(letterSpacing: 0, fontSize: metaSize)` | 侧边栏未读数、待办计数胶囊 |

- `mono` 把「两行必须一起写」压成一个令牌：漏 fallback 的写法从此不存在
  （想漏得先绕开令牌）。
- `badgeCount` 11 → 12（`w500` 不变）：与 `badge` 同字号，区分靠字重与
  `Badge` 自身的强调色底。

#### 守卫

- `tokens_test.dart`：`mono` 的 `fontFamily == 'monospace'` **且**
  `fontFamilyFallback == SpbFonts.monoFallback`（把「一起写」变成机器可查）；
  `base` 可替换时字号跟随 `base`；`badgeCount` 由 `>= 11`
  改为 `== SpbType.metaSize`（11 不再是例外）。
- `tools/check_type_tokens.sh` 继续拦新增的裸 `fontSize:`（`mono` 内部自己
  不写字号，只取 `base`）。

#### 未验证 / 有意不做

- 三个平台的等宽字形未在本机核对（Linux DejaVu Sans Mono / Windows Consolas /
  macOS Menlo）：golden 里中文是 tofu，等宽只影响拉丁与数字宽度，而这三套
  fallback 链的定义已在 §6.76 的 `SpbFonts` 讨论里。
- **不做「等宽 + 大写 + 字距」的组合令牌**：只有登录短码一处需要，再包一层
  只会让令牌表变长。
- **不动 `labelSmall` 槽位本身**（Flutter `Badge` 内部在用，§6.76 的结论），
  抬字号是在 `badgeCount` 的实例上做的。

### 6.82 移动端正文 14 → 15（触屏一档，层次不破）（2026-11）

§6.77 已经确立了「移动端字号可以大一号」的取向（移动端列表标题保持 M3 默认
16，桌面端显式钉 14），但**正文**当时没跟着走：`SpbType.body` 两端都是 14。

#### 缺陷

移动端正文（对话气泡、卡片说明段落）与桌面端一样是 14px。但两端的阅读条件
差别很大：

| | 桌面端 | 移动端 |
|---|---|---|
| 视距 | ~55–70cm | ~25–35cm（且手指常遮住部分屏幕） |
| 同屏文字 | 大量列表 + 侧栏 | 单列窄屏，正文是主内容 |
| 现有对照 | 令牌层次 12 / 14 / 16 | 列表标题已是 16、正文仍是 14 → **移动端「正文」比「列表标题」小两档** |

于是移动端出现一个不对称：**标题 16、正文 14**，但移动端用户读的主要内容恰恰
是正文。§6.77 的「大一号」只落到了列表标题上。

#### 修法

只在 `SpbTheme._cjkTypography` 里给 **`bodyMedium`** 加一档，且只在移动端：

```dart
// theme.dart：mobile = !desktop（desktop 来自 _build 的 target，与 §6.77 同一判据）
bodyMedium: _cjkStyle(g.bodyMedium, mobile: mobile)   // 14 → 15
static const double _mobileBodyBump = 1.0;
```

为什么是 **15 而不是 16**：

- 16 会与 `cardTitle`（`titleMedium`）**持平**，`tokens_test` 钉住的
  「元数据 ≤ 徽标 < 正文 < 块标题」层次断掉；
- 16 也与移动端列表标题（M3 默认 `bodyLarge`）持平，列表行与正文失去区分；
- 15 是「大一号」最小的可感知增量（+7%），CJK 在 15px × 1.5 行高下清晰。

只动这一个槽位，其余一律不动：

| 槽位 | 移动端 | 为什么不动 |
|---|---|---|
| `bodySmall`（`listMeta`） | 12 | 12 是可读下界（§6.76），元数据不该跟着长大——它会挤掉正文空间 |
| `labelMedium`（`badge`） | 12 | chip / 状态词面积受限，变大就是换行 |
| `titleSmall` / `titleMedium` | 14 / 16 | 桌面 14 / 移动 16 的既有层次（§6.77） |
| `labelSmall` | 11 | Flutter `Badge` 内部槽位，不动（§6.76） |

**没有新增平台分支**：复用 `_build` 里已有的 `desktop`（来自显式
`platform` 参数，测试可注入），故 `lightFor(TargetPlatform.linux)` 拿 14、
`lightFor(TargetPlatform.android)` 拿 15，两端都能断言。

#### 验证

- `tokens_test.dart` 新增：`SpbType.body(android) == 15`、`body(linux) == 14`、
  两端 `cardTitle == 16`、`listMeta == 12` 且 **12 < 15**（层次断言在移动端也成立）。
- 13 张 golden 里 **7 张**跟着变（其余 6 张不变——`spb_features` 的 spec 卡与
  地图卡用的是 `listMeta`/`badge`/`cardTitle`，不含正文）：

| 基线 | diff | 内容高度 | 差异性质 |
|---|---|---|---|
| `error_state_with_retry` | 1.26% | +1px | 14→15 单行正文 + 按钮内文字 |
| `error_banner_light` / `_dark` | 1.27% / 1.35% | 0 | 单行文字变宽，胶囊内边距吸收 |
| `empty_state_with_icon` | 0.56% | 0 | 副标题一行 |
| `empty_state_no_icon` | 0.91% | 0 | 同上 |
| `error_state_no_retry` | 0.61% | 0 | 同上 |
| `section_title` | 0.45% | 0 | 标题下的说明行（`labelLarge` 未动，仍按原样） |

全部 bbox 紧贴文字、无边框/背景变化、无 `RenderFlex overflowed`。

- 全套：`spb_design` 54、`spb_ui` 43、`spb_features` 1432、`spb_mobile` 159 全过；
  `apps/spb_desktop` 仍是那 13 条**改动前就有**的 `router_workbench` 失败。

#### 未验证（本机边界，§9）

- 真机观感：移动端一屏行数（正文行高 15×1.5=22.5）与气泡高度变化；
- iOS 上 `defaultTargetPlatform` 是否也落移动端分支（代码是按
  「非 windows/macOS/linux」判定，iOS 落移动端，但本机无 iOS 构建）。

#### 有意不做

- **不只给「移动端对话页」加**：令牌是全局语义，写在页面里就会漏（§6.76 的同一教训）。
- **不跟着抬 `bodySmall`/`labelMedium`**：元数据与 chip 的约束是**宽度**，不是
  阅读距离；抬它们只会让 chip 换行、列表更挤。
- **不同时改移动端 `cardTitle`**：16 已经是移动端能接受的上限（再大就把
  卡片标题变成「标题栏」），正文 15 与它 1px 之差靠字重（w400 vs w500）区分。

### 6.83 面板 golden：把字号改动的「密度落点」锁起来（2026-11）

§6.78/§6.79/§6.82 三次改动合起来动了全仓的字号与度量，但**面板一张基线都没有**
（§6.78 的「未验证」里就写着这句）。这一轮补两张。

#### 为什么现在补、补在哪

§6.13 的 golden 判据是「**稳定 + 纯展示 + 改错代价高**」。`TurnDetailPanel`
三条都满足：

| 判据 | `TurnDetailPanel` |
|---|---|
| 稳定 | 输入是**已落库事件**（`TurnDetail`），无 SSE 增量、无 `DateTime.now()`（时间戳走绝对格式） |
| 纯展示 | 无平台能力依赖（文件类回调不注入时不渲染菜单项） |
| 改错代价高 | 它是排障视图：「挤成一团」比「功能坏」更难被发现——用户只会觉得「这页面好乱」 |

对照组是 `ConversationPage`：它依赖大量回调与 Riverpod 状态（§6.13 的既有结论），
构造成本远超收益，故**不**给它加 golden。

两张基线各锁一件事：

| 基线 | 锁什么 |
|---|---|
| `turn_detail_panel_full.png`（480×720） | meta chips（`badge`）+ 用户输入块 + `事件流（N）` + 四个事件卡（thought / tool_call（失败）/ error / markdown 回复）的**整条密度链** |
| `turn_detail_panel_empty.png`（480×320） | §6.78 修掉的那两行空态文案（`事件可能已超出时间线窗口，或尚未落库。` 曾是 11px） |

#### 变异测试（证明基线真的会红）

| 变异 | 结果 |
|---|---|
| 把空态那行从 `SpbType.listMeta` 退回 `textTheme.labelSmall`（11px） | `turn_detail_panel_empty` 红：0.57% / 870px |
| 把 `_mobileBodyBump` 从 1.0 改成 0.0（正文 15→14，§6.82 回退） | 两张都红：full **9.78%** / 33808px，empty 2.86% |

第二次尤其说明问题：正文改 1px 就会让整面板重排 10% 的像素——这正是「无基线时
没人会发现」的那类改动。

#### 写这类基线踩到的三个坑

1. **`MaterialApp.home` 拿到的是紧约束**：宿主必须 `Center` 包一层，否则
   `SizedBox(width: 480)` 被忽略、基线变成整屏尺寸，而且「窄屏下文案例怎么
   折行」根本没被测到（第一版基线是 600×900，diff 里内容横跨 600px 才发现）。
2. **`ListView` 不会因为内容过高而报错**（它滚动），故宿主高度要给足；
   面板在 480 宽下内容高约 500，720 有富余。
3. **markdown 里的代码片段落到 Ahem**：`RobotoMono` 未装载，反引号内的拉丁
   渲染成实心方块。这是**确定性**的（SDK 版本锁死），但它只影响宽度观感，
   **不要**据此判断字形（§6.13 的 `golden_fonts.dart` 教训同源）。

#### 未验证

- 真机观感（本机无 `DISPLAY`/真机，基线只能证明「布局与密度没被改坏」）。

#### 有意不做

- **不给 `ConversationPage` 加 golden**（成本/收益，见上）；
- **不逐面板铺开**：面板基线数量与维护成本线性相关，只挑「字密度最集中、
  改错最难发现」的那一张。`group_gate_panel` / `turn_status` 等仍由行为单测覆盖。
