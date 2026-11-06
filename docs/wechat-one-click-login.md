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
+ `CFBundleURLTypes`。当前仓库既无 entitlements 也无 AASA，iOS 侧等于从零开始。

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
