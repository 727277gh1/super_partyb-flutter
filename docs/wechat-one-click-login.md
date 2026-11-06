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

## 7. 真机验证清单（未做）

```bash
# 1. 装新 APK，点「微信一键登录」
# 2. 应看到微信小程序打开并停留在确认页
adb logcat -s flutter | grep -E "已唤起微信|scene="

# 3. 确认后回到 App，应直接进入会话列表（不出现登录页）
# 4. 若卡在「请在微信中确认…」，先看服务端：
curl -s "https://tbcc.atjog.com/idp/api/v1/bindings/mini-program/check/<scene>"

# 5. 确认 token 里拿到了 refresh_token（否则一小时后会被踢）
```

未装微信的设备：点按钮应得到「无法唤起微信，请确认已安装微信后重试」，
**不应**停在等待态。
