# App 内「微信一键登录」（小程序会话 → 标准 OIDC 授权码）

> 状态：**代码完成，真机未验证**（受 `#4` 阻塞：本机无 Android 设备、无 `/dev/kvm`）。
> 服务端（id-provider）已部署，客户端需重新打 APK。

## 1. 为什么需要这条路

移动端原有两条登录入口都有硬伤：

| 入口 | 问题 |
|---|---|
| 系统浏览器 SSO | 至少 3 次跳转；登录完还要等深链回跳 |
| 微信扫码 | **同机无法扫码**：用户只有这一台手机，扫不了自己屏幕上的码 |

扫码登录的设计前提是**跨设备**（PC 显示码、手机扫）。手机上要复用微信身份，
唯一可行的形态是**直接唤起小程序**：用户点一下 → 微信里确认 → 回到 App 已登录。

## 2. 链路

```
App                      IdP (id-provider)                微信
 │  ① POST /qrcode-session?scheme=1
 │────────────────────────────►  创建 scene(32 hex, TTL 5min)
 │                              调 generatescheme
 │                              ─────────────────────────►  openlink
 │  ◄── {scene, schemeUrl} ────
 │  ② 打开 weixin://dl/business/?t=…
 │─────────────────────────────────────────────────────────►  小程序启动
 │                                                             wx.login()
 │                              ③ POST /login {code, scene}
 │                              ◄───────────────────────────
 │                              完成态（内存，单次可消费）
 │  ④ GET /check/{scene} 轮询（带退避）
 │────────────────────────────►  {bound: true}（**不含凭证**）
 │  ⑤ POST /exchange {scene, client_id, redirect_uri, state, code_challenge}
 │────────────────────────────►  走 fosite 签发**标准授权码**
 │  ◄── {code, state} ─────────
 │  ⑥ POST /oauth2/token {code, code_verifier}（PKCE）
 │────────────────────────────►  access + refresh + id token
```

第 ⑤ 步是关键设计：兑换出来的是 fosite 的普通授权码，不是另一套 token 形态。
因此 refresh、吊销、`id_token` claims 与浏览器登录**完全一致**，客户端只需要
复用既有的 `OidcClient.exchangeCode`。

## 3. 三个接口

| 接口 | 作用 | 是否带凭证 |
|---|---|---|
| `POST /api/v1/bindings/mini-program/qrcode-session?scheme=1` | 创建 scene；`scheme=1` 时顺带生成可直接打开的链接 | 否 |
| `POST /api/v1/bindings/mini-program/qrcode-session?code=1` | 创建 **6 位短码**（不调任何微信 API，见「方案 C」） | 否 |
| `GET  /api/v1/bindings/mini-program/code/{code}` | 短码预览（发起方 + 剩余秒数，**不消费**） | 否 |
| `GET  /api/v1/bindings/mini-program/check/{scene}` | 轮询「用户确认了没有」 | **否**（公开接口，绝不能在这里发凭证） |
| `POST /api/v1/bindings/mini-program/exchange` | scene → OIDC 授权码（**单次消费**） | 返回 code |

`exchange` 的错误码（客户端据此给不同提示）：

| HTTP | `error` | 含义 |
|---|---|---|
| 400 | `bad_request` | 缺参数 / `state` 不足 8 字符 |
| 400 | `invalid_request` | client_id / redirect_uri / PKCE 校验失败 |
| 404 | `scene_not_found` | scene 不存在或已被使用 |
| 409 | `scene_pending` | 用户在微信里还没确认 |
| 410 | `scene_expired` | 二维码过期 |
| 503 | `unavailable` | 服务端未启用小程序登录 |

## 4. 客户端实现位置

| 层 | 文件 | 职责 |
|---|---|---|
| `spb_api` | `lib/src/miniprogram_login.dart` | 三个接口的客户端 + 错误码→中文映射 |
| `spb_mobile` | `lib/miniprogram_signin.dart` | 编排：唤起 → 轮询（退避/超时）→ 兑换 → 交落盘点 |
| `spb_features` | `lib/src/auth/login_page.dart` | 「微信一键登录」按钮（`onWeChatSignIn` 注入，桌面端不传即不显示） |
| `spb_mobile` | `lib/providers.dart` | `miniProgramLoginClientProvider` / `wechatSignInActionProvider` |

落盘点与深链回调**共用** `oidcCallbackHandlerProvider`：两条登录路径的
「换 token → 写安全存储 → 推进认证状态」行为必须一致，否则排查时要分别确认。

## 5. 几个必须记住的约束

1. **端点从 issuer 推导**（`{issuer}/api/v1/bindings/mini-program`），不硬编码域名：
   staging / 双栈（`tbcc` / `tbcc6`）下 issuer 变了端点要跟着变。
2. **`state` 至少 8 字符**：fosite 对 `state` 有最小熵要求，短了直接 400。
3. **PKCE 必填**：`flutter-client` 是 public client，服务端强制 PKCE。
4. **轮询必须有总超时**：用户唤起微信后可能直接退出。没有超时，登录页会永远
   停在「正在等待确认」——比报错更糟。
5. **失败必须清 pending auth**：否则下次深链回调会误判「有进行中的登录」。
6. **唤起失败就不轮询**：没装微信时打开链接会失败，此时继续轮询等于让用户干等。
7. **`?scheme=1` 才生成链接**：微信 API 有配额，网页端扫码不需要它。

## 6. 服务端前置（均已完成并部署）

| 前置 | 位置 |
|---|---|
| scene → 授权码兑换端点 | id-provider `7e599ef`（`internal/server/mini_program_exchange.go`） |
| URL Scheme 生成（`wxa/generatescheme`） | id-provider `e08811a` |
| `flutter-client` 注册 `partyb://oidc/callback` + `offline_access` | 生产库（2026-11-06） |
| 小程序侧「来自 App 的授权」入口 | super_partyb `apps/miniapp`（已有 `login(code, scene)`，入口/文案待补，见 super_partyb#101） |

## 7. ⛔ 生产阻塞：小程序主体未认证（2026-11-06 实测）

代码链路已通，但**微信侧账号状态**让整条路走不通。实测（生产凭证，直连微信 API）：

| 接口 | 返回 | 影响 |
|---|---|---|
| `wxa/getwxacodeunlimit` | `85412 personal entity not verified` | **网页端扫码登录也是 500**（同一个接口） |
| `wxa/generatescheme` | `85407 no scheme permission` | App 内一键登录无法唤起 |

两条都是**账号级限制**，改代码无效：微信把 URL Scheme / URL Link / 明文 Scheme
全部限定为**非个人主体**小程序（官方错误码表：`40002 暂无生成权限（个人主体小程序
无权限…）`、`85407 no scheme permission`），个人主体也无法完成微信认证。

### 已做的解耦（`dad6fd1`）

App 路径**不再生成小程序码**（`?scheme=1` → `needQR=false`）：用户同机扫不了
自己的屏幕，这张图除了多一次微信 API 调用（有配额）没有任何用处，却让会话创建
被 85412 连坐——修复前 `POST .../qrcode-session?scheme=1` 直接 500，真正需要的
URL Scheme 一次都没被尝试过。修复后：

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  'https://tbcc.atjog.com/idp/api/v1/bindings/mini-program/qrcode-session?scheme=1'
# {"success":true,"scene":"cf25...","expiresAt":"...",
#  "schemeError":"当前小程序未开通「URL Scheme 唤起」权限，无法直接打开微信，请改用 SSO 登录"}
```

网页端（跨设备扫码）仍然要图，所以 `POST .../qrcode-session`（不带 scheme）
依旧 500 —— 那是 85412，等主体问题解决才恢复。

### 方案 C：6 位短码（**零资质，已实现**）

上面两条路都要账号侧操作（企业主体认证 / 开放平台审核）。短码不需要任何微信
「打开能力」：**App 自己把 6 位码显示出来，用户打开小程序手输**。

```
① App  POST {idp}/api/v1/bindings/mini-program/qrcode-session?code=1
        → { scene:"A3F9K2", displayCode:"A3F-9K2", expiresInSeconds:300 }
        ★ 不调任何微信 API：不生成小程序码（85412）、不生成 URL Scheme（85407）
② App  界面显示 A3F-9K2 + 倒计时，同时轮询 /check/A3F9K2
③ 手机 打开小程序 → 我的 → 输入登录码 → 输入 a3f-9k2
        GET  /code/A3F9K2   → 预览「来自 203.0.113.7 · Windows · Chrome，剩余 4:00」
        POST /login {code:<wx.login>, scene:"A3F9K2"} → openid → 账号 → 写入完成态
④ App  /exchange → fosite 授权码 → PKCE 换 token（与扫码/唤起完全同一段代码）
```

服务端见 id-provider#18（短码即 scene，确认/轮询/兑换全复用）。

**App 侧编排（`miniprogram_signin.dart`）**：两条唤起通道**运行期**不可用时
（无 OpenSDK / scheme 生成失败 / SDK 返回 85407）自动改发短码，不把用户卡在
错误上；短码通过 `onShortCode` 回调交给登录页渲染（`_ShortCodeCard`：大字号
分组码 + 倒计时 + 可长按复制）。

**为什么这条路径对 openid-only 账号特别重要**：身份锚点是 openid，全程不碰
邮箱/密码；而 `85412`/`85407` 恰恰让扫码与唤起都不可用。之前这类用户在同机
场景下**没有任何登录方式**。

| 限制 | 说明 |
|---|---|
| 必须能打开小程序 | 小程序本身要已发布/可用（体验版同样算） |
| 5 分钟有效 | 与服务端会话 TTL 一致，过期要重新发起 |
| 限流 | 创建 10 次/小时/IP + 300 次/小时全局；确认 10 次/10 分钟/IP + 200 次/10 分钟全局 |
| 反钓鱼 | 确认页必须展示发起方（IP/平台/浏览器），否则可被「自己生成码骗别人确认」 |

### 方案 D：反向登录码（**方向相反，已实现**）

方案 C 的码从 App 流向小程序；反向码从小程序流向 App：**手机上小程序已登录，
桌面/平板没有微信也唤不起小程序时，由那台已登录的机器出一个 8 位码，抄到目标
设备上直接登录**（id-provider#21）。

```
① 手机 小程序 → 我的 → 在别的设备上登录
        POST {idp}/api/v1/bindings/mini-program/handoff   （Bearer：小程序已登录）
        → { code:"AB2C3D4E", displayCode:"AB2C-3D4E", expiresInSeconds:120 }
② 电脑 App 登录页 →「或用手机小程序登录」→ 输入 AB2C-3D4E
        POST {idp}/.../handoff/redeem {scene:"AB2C-3D4E", client_id, redirect_uri,
                                       state, code_challenge, code_challenge_method}
        → { code:"<fosite 授权码>" } → PKCE 换 token（与 SSO/magic link 同一落盘点）
③ 手机 页面轮询 /handoff/recent → 显示「刚才 5.6.7.8 · Windows · Chrome 登录了你的账号」
```

**为什么它与方案 C 的安全模型完全不同**（这是实现上的关键区别，不是风格问题）：

| | 方案 C（App 出码 → 小程序确认） | 方案 D（小程序出码 → App 输码） |
|---|---|---|
| 码的性质 | **授权句柄**：光有码没用，必须有账号主人确认 | **持有即授权的凭据**：谁拿到谁能登录 |
| 码长 | 6 位（`30^6 ≈ 7.3e8`） | **8 位**（`30^8 ≈ 6.6e11`）——6 位在未认证入口 + 分布式尝试下约 2.7 天可撞中一次，8 位约 3 年 |
| TTL | 5 分钟 | **2 分钟**（用户就在两步之间） |
| 消费 | 确认后单次 | 单次 + 同用户只留一个码（出码即作废旧码） |
| 错误尝试 | 端到端限流 | 同码错 5 次即作废 + 按来源/全局限流 |
| 审计 | 无（授权句柄不值得记） | 出码/兑换都记，但**只存码的 sha256 前 12 位** |
| 事后可见性 | 无 | 出码人能看到「刚才哪台设备登录了」+ 作废入口 |

由于反向码是凭据，服务端把它与正向 `sessions/completed` **分开存储、分开展示端点**
（`/handoff/redeem` vs `/exchange`）：否则反向入口能吃掉「未确认」的正向 scene，
等于绕过「账号主人确认」这一步。

**客户端位置**：
- 出码端（小程序）：`super_partyb/apps/miniapp/src/pages/handoff/`；
- 输码端（App）：登录页「或用手机小程序登录」区域 →
  `miniProgramHandoffSignIn` → `MiniProgramLoginClient.redeemHandoffCode`；
  桌面与移动共用同一段编排（`spb_features`），平台差异只在入口文案。

**代价**：码是凭据，所以登录页必须写「2 分钟有效、只能用一次、别发给别人」，
且**不做模糊替换**（`O`→`0` 之类会把「抄错」变成「登进别人的账号」）。

### 剩下两条路（都需账号侧操作）

| 方案 | 需要什么 | 代码改动 |
|---|---|---|
| 小程序主体改为企业主体 + 微信认证 | 微信公众平台操作（认证费） | **零**——`generatescheme` 通后现有实现直接可用 |
| App 内用微信 OpenSDK `WXLaunchMiniProgram` | 微信开放平台「移动应用」appid + 该应用与小程序关联 + 用**发布签名**注册应用签名（MD5）+ 小程序原始 ID（`gh_` 开头） | 新增 `fluwx` 依赖 + `WXEntryActivity` + iOS Universal Links |

OpenSDK 这条路不受「非个人主体」限制，但需要上面 4 项账号信息才能落地。

### 方案 B 的技术细节（查证结果，2026-11-06）

**原理**：`WXLaunchMiniProgram` 是**客户端 SDK 调用**，不经过服务端 API，
所以不受 `85407` / 明文 scheme 的「非个人主体」限制。链路是：

```
App ──WXLaunchMiniProgram(userName=gh_xxx, path=pages/index/index?scene=<scene>)──► 微信小程序
小程序：wx.login() → POST /idp/api/v1/bindings/mini-program/login {code, scene}
小程序：<button open-type="launchApp" app-parameter="ok"> ──► 回到 App
App 收到 WeChatLaunchMiniProgramResponse.extMsg（= app-parameter）
App：轮询 /check/{scene} → POST /exchange → 换 token（**完全复用现有实现**）
```

**服务端零改动**：scene 由现有的 `?scheme=1`（去掉 scheme 依赖即可）创建，
确认状态走现有 `/check/{scene}`，授权码走现有 `/exchange`。OpenSDK 只替换
「怎么把 scene 带进小程序」和「怎么回来」这两步。

**Flutter 实现（fluwx 6.0.6，API 已核实）**：

```dart
final fluwx = Fluwx();
await fluwx.registerApi(appId: 'wx<移动应用appid>', universalLink: 'https://…/app/');

await fluwx.open(target: MiniProgram(
  username: 'gh_xxxxxxxxxxxx',                    // 小程序**原始 ID**，不是 appid
  path: 'pages/index/index?scene=$scene',          // 带参路径
  miniProgramType: WXMiniProgramType.release,      // 联调用 .trial
));

fluwx.addSubscriber((r) {
  if (r is WeChatLaunchMiniProgramResponse) {
    // r.extMsg == 小程序 <button open-type="launchApp" app-parameter="…">
  }
});
// 冷启动（App 被小程序拉回）：先 attemptToResumeMsgFromWx()，再 getExtMsg()
```

**Android 必做**：在开放平台移动应用里登记 **包名 + 发布签名 MD5**。debug 签名
不被识别（`errCode = -1`），联调要么登记 debug 签名，要么用 release 签名装包。
fluwx ≥4 自带 `WXEntryActivity`，无需手写。

**iOS 必做**：Universal Link（Associated Domains）+ `LSApplicationQueriesSchemes`
+ `CFBundleURLTypes`。这三项已在仓库内落地（见下节），但**未经任何构建验证**
（本机无 Xcode / macOS），且仍缺两项外部前提（AASA 与 `wx<AppID>` scheme）。

#### iOS 平台配置（2026-11-06 落地，未构建验证）

| 位置 | 内容 | 作用 |
|---|---|---|
| `ios/Runner/Runner.entitlements` | `applinks:tbcc.atjog.com`、`applinks:tbcc6.atjog.com` | 微信 Universal Link + OIDC claimed HTTPS 回调（issue #77 的 iOS 半边） |
| `ios/Runner.xcodeproj/project.pbxproj` | 三个构建配置均 `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` | 只挂 Debug 是最常见的漏法：本地正常、Release 包上线后静默失效 |
| `ios/Runner/Info.plist` | `LSApplicationQueriesSchemes` = `weixin` / `weixinULAPI` / `weixinURLParamsAPI` / `wechat` | 缺 `weixin` → `isWeChatInstalled` 恒 false；缺 `weixinULAPI` → 「唤起成功但回不来」 |

**不需要改 `AppDelegate.swift`**：fluwx 6.x 自带 scene 生命周期转发
（`scene:openURLContexts:` / `scene:continueUserActivity:`），本工程用的是
`FlutterSceneDelegate`，插件注册后即可收到回调。

**仍缺的两项（都不在客户端仓库内）**：

1. **`wx<HostAppID>` 回跳 scheme**：AppID 来自开放平台审核结果，且
   `--dart-define` 只注入 Dart 侧、不会替换 Info.plist 变量，所以只能拿到
   AppID 后人工补进 `CFBundleURLTypes`（plist 里有注释写明补法）。漏了它的
   后果是「小程序确认后不会被拉回前台」——轮询仍在跑，登录最终仍会完成，
   只是体验降级。
2. **AASA 文件**：`https://tbcc.atjog.com/.well-known/apple-app-site-association`
   （无 `.json` 后缀、`Content-Type: application/json`），`appID` 形如
   `<TeamID>.com.atjog.spb.spbMobile`。由 api-gateway 提供，见 api-gateway#12 /
   id-provider#8。**未签名/模拟器不校验**，所以本机无法验证这一项。

守卫：`apps/spb_mobile/test/ios_platform_config_test.dart` 断言
entitlements 与 Android manifest 声明**同一组**域名、三个构建配置都挂了
entitlements、微信 scheme 白名单齐全；注入了 `SPB_WECHAT_OPEN_APP_ID` 时
还会要求 plist 里已补上该 scheme（把人工步骤变成红灯）。

### 方案 B 的客户端实现（已完成，issue #92）

| 层 | 文件 | 职责 |
|---|---|---|
| `spb_platform` | `lib/src/wechat_launcher.dart` | `WeChatMiniProgramLaunchConfig`（配置与**形态校验**）、`WeChatOpenSdk` 桥接契约、`OpenSdkMiniProgramLauncher`（判定顺序与文案）、`NoopWeChatMiniProgramLauncher` |
| `spb_mobile` | `lib/wechat_open_sdk.dart` | `FluwxOpenSdk`（fluwx 6.0.6 桥接）+ `createWeChatMiniProgramLauncher()` |
| `spb_mobile` | `lib/miniprogram_signin.dart` | `launchViaSdk` 优先；走 SDK 时**不再请求 schemeUrl** |
| `spb_core` | `lib/src/env.dart` | `SPB_WECHAT_OPEN_APP_ID` / `SPB_WECHAT_MINIPROGRAM_USERNAME` / `SPB_WECHAT_UNIVERSAL_LINK` |

配置注入（审核通过后）：

```bash
flutter build apk --release \
  --dart-define=SPB_WECHAT_OPEN_APP_ID=wx<移动应用appid> \
  --dart-define=SPB_WECHAT_MINIPROGRAM_USERNAME=gh_<小程序原始ID>
```

未注入时判定「不可用」并**说明原因**（缺 appid / 缺原始 ID / 前缀不像），登录页
回落到 URL Scheme 路径——不会出现「点了没反应」。

几个刻意的取舍：

- **插件放在 App，不放 `spb_platform`**：`spb_platform` 声明插件会让桌面端构建也
  编译它（issue #36 的教训）。`spb_platform` 只留契约，逻辑可无插件单测。
- **形态校验**：`openAppId` 必须以 `wx` 开头、`userName` 必须以 `gh_` 开头。最常见
  的错误就是把小程序 appid 填进移动应用 AppID（两者都是 `wx` 开头），填错时微信
  只回 `bad param`，排查会绕很远。
- **注册幂等且失败不缓存**：`registerApi` 只调一次，失败下次重试（时序/插件未就绪
  不该永久失效）。
- **先判 `isWeChatInstalled`**：不判的话 OpenSDK 静默失败，用户只看到「点了没反应」。
- **不接 `extMsg` 回调**：回到 App 后继续轮询 `/check/{scene}` 即可，多一条通道就
  多一处会分叉的实现。

**未做**：iOS 的构建与真机验证（配置已落地，见上表；缺 Xcode/macOS）；
真机验证（需 HostAppID + release 签名装包）。

**最大风险不在代码，在开放平台审核**：移动应用需要「官网或应用市场下载链接 +
类目」，且主体信息需与开放平台认证主体一致。本 App 目前没有应用市场上架，
个人主体审核这一关可能过不了——**建议先确认能否过审，再决定是否投入实现**。

顺带修掉的两个「看不见」问题：

1. **失败原因原本被吞掉**：handler 只回 `{"error":"internal_error"}`，微信的
   errcode 完全不入日志——线上只能靠猜。现在 `http.go` 记录真实原因
   （`error` 字段带 errcode 与 errmsg）。
2. **`expire_type` 配错**：`expire_type: 1` 是「失效间隔（天）」，配 `expire_time`
   会被微信拒为 `85401 time limit between 1min and 30days`。短时效链接必须
   `expire_type: 0`（绝对时间点）。已有测试锁定该配对。

## 8. 真机验证清单（未做）

```bash
# 1. 装新 APK，点「微信一键登录」
# 2. 应看到微信小程序打开并停留在确认页
adb logcat -s flutter | grep -E "已唤起微信|scene="

# 3. 确认后回到 App，应直接进入会话列表（不出现登录页）
# 4. 若卡在「请在微信中确认…」，先看服务端：
curl -s "https://tbcc.atjog.com/idp/api/v1/bindings/mini-program/check/<scene>"

# 5. 确认 token 里拿到了 refresh_token（否则一小时后会被踢）
```

> ⚠️ 先解决 §7 的主体认证，否则上面第 1 步就会失败（`schemeError`/500）。

未装微信的设备：点按钮应得到「无法唤起微信，请确认已安装微信后重试」，
**不应**停在等待态。
