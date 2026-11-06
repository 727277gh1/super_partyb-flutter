# 移动端 OIDC 回跳：机制选定与阻塞项

> 对应工作项「移动端自定义 scheme 回跳注册与接收」。
>
> 前置实测见 [`oidc-verification.md`](./oidc-verification.md)。
> 本文记录**本任务实际做了什么**、**为什么机制与任务原文不同**、以及
> **还差什么才能真正登录**。

---

## 0. 结论速览

| 项 | 结果 |
|---|---|
| Android `<intent-filter>`（`partyb://oidc/callback`） | ✅ 已注册 |
| iOS `CFBundleURLTypes`（scheme `partyb`） | ✅ 已注册 |
| 回调接收 + 解析 + state 校验 + 换 token | ✅ 已实现并单测（21 例） |
| `flutter build apk --debug` | ✅ 构建成功 |
| **能否真的完成登录** | ⚠️ 差最后一步：IdP 侧配置 **2026-11-06 已完成**（见 §3），剩真机回跳闭环验证 |

> ✅ **2026-11-06 状态更新**：§3 的两个 IdP 侧阻塞项均已完成（scheme 回调
> 注册 + public client），authorize 端点实测 `400` → `302`。本文其余部分按
> 当时快照保留；loopback 同样不可行的实测结论（下段、§1）指
> **client 当时未注册任何可用回调**的时点，注册后两种形态都可用。

**任务原文的备选方案（loopback）同样不可行**——本次重新实测确认，
自定义 scheme 与 loopback 都被 IdP 以 `400 invalid_request` 拒绝（§1）。
因此本任务**没有**在两者之间切换，而是实现了「自定义 scheme 的目标形态」，
并把「缺什么」明确记录为跨仓库前置条件。

---

## 1. 机制实测（重新确认 T6 结论）

```console
$ CID=client_PLACEHOLDER_0000000000000000

# 自定义 scheme（本任务采用的形态）→ 400
$ curl -sS --max-time 20 -w ' <- HTTP %{http_code}\n' \
  "https://app.example.com/idp/oauth2/authorize?response_type=code&client_id=$CID&redirect_uri=partyb%3A%2F%2Foidc%2Fcallback&scope=openid&state=s12345678"
{"error":"invalid_request","error_description":"... The 'redirect_uri' parameter does not match any of the OAuth 2.0 Client's pre-registered redirect urls."} <- HTTP 400

# loopback（任务原文的备选）→ 同样 400
$ curl -sS --max-time 20 -w ' <- HTTP %{http_code}\n' \
  "https://app.example.com/idp/oauth2/authorize?response_type=code&client_id=$CID&redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback&scope=openid&state=s12345678"
{"error":"invalid_request","error_description":"... does not match any of the OAuth 2.0 Client's pre-registered redirect urls."} <- HTTP 400
```

> 说明：以上只探测授权端点（`state` 为固定假值，未完成登录），不涉及任何凭据。

**所以「改用 loopback」并不能解决问题**：IdP 对 `redirect_uri` 做精确匹配，
两种形态都不在预注册列表里。任务原文的 if/else 两条分支在这里是**同一结果**。

### 1.1 为什么不用网关托管的流程

网关 `/auth/oidc/authorize` 把 `redirect_uri` **硬编码**为自己的 `redirect_url`
（`api-gateway/pkg/api/handlers_oidc_authorize.go`，见 T6 文档 §1.2），
回调落在网关而不是本应用 → 客户端拿不到 `code`。移动端要拿 code，
**只能直连 IdP 并声明自己的回调地址**。

### 1.2 为什么不用内嵌 webview 读 Cookie（T6 建议的替代）

T6 曾建议移动端「内嵌 webview 读 cookie」。本任务未采用，理由：

1. 会话 cookie 是 `HttpOnly`（T6 §1.6），webview 侧**能否读到依平台实现而异**，
   T6 自己也把它列在「未验证」里（T6 §4.2）；
2. 即使读到，也只是把 cookie 拷进 `flutter_secure_storage`——**与自定义 scheme
   方案一样需要 IdP 侧配合**（cookie 只有在网关回调成功后才有），而 webview
   方案还多引入一个平台插件与一套「cookie 提取」的脆弱逻辑；
3. 自定义 scheme 是移动端 OIDC 的**标准做法**（RFC 8252 §7.1 明确推荐
   private-use URI scheme），一旦 IdP 注册了回调即可工作，长期更稳。

**结论：形态选自定义 scheme；阻塞点在 IdP 配置，不在客户端代码。**

---

## 2. 本任务的实现

### 2.1 平台注册（三处常量必须一致）

| 位置 | 内容 |
|---|---|
| `android/app/src/main/AndroidManifest.xml` | 自定义 scheme：`<intent-filter>` + `<data android:scheme="partyb" android:host="oidc" android:pathPrefix="/callback"/>`；claimed HTTPS：`<intent-filter android:autoVerify="true">` + `https` + `path="/idp/app/callback"`（见 §2.3） |
| `ios/Runner/Info.plist` | `CFBundleURLTypes` → `CFBundleURLSchemes` = `["partyb"]` |
| `packages/spb_api/lib/src/oidc_callback.dart` | `OidcCallbackUri`（`scheme`/`host`/`path`/`redirectUri`/`claimedHttpsRedirectUri`/`matches`/`parse`） |

> iOS 的 plist 没有 host/path 的等价声明（只能声明 scheme），
> 因此 host/path 的校验落在 Dart 侧 `OidcCallbackUri.matches()`。
>
> 三处任一不一致的表现都是「登录后应用毫无反应」而**不是报错**，极难排查——
> 故把常量集中到 `OidcCallbackUri`，并由
> `apps/spb_mobile/test/android_manifest_applinks_test.dart` 直接读
> manifest/plist 断言两边一致（改一边忘另一边 → 测试红灯）。

### 2.2 接收链路（`apps/spb_mobile/lib/auth_deeplink.dart`）

```text
DeepLinkSource（生产 = app_links 插件；测试 = 假实现）
  │ 冷启动链接 initialUri() + 运行中流 uriStream()
  ▼
AuthDeepLinkReceiver
  │ 1. OidcCallbackUri.matches() 过滤（scheme+host+path 三者全对）
  │ 2. pendingState() 取本次登录的 state + code_verifier
  │ 3. OidcCallbackUri.parse() 校验 state（防 CSRF）
  │ 4. onCode(code, pkce) → OidcClient.exchangeCode → 写 SecureTokenStore
  ▼
authStateProvider.signedIn() → 路由守卫放行
```

关键设计（每条都有对应单测）：

- **`DeepLinkSource` 抽象**：插件走平台通道（单测必然 `MissingPluginException`），
  而「解析 + 校验」才是易错部分。抽象掉来源后可无头单测 21 例。
- **冷启动链接必须单独取**：进程未运行时 Android/iOS 不往 stream 推事件，
  只放启动参数。漏掉 `initialUri()` 会让「先关掉应用再点登录链接」完全失效。
- **过滤必须比 scheme**：只看 scheme 会让 `partyb://share/evil?code=...`
  也走进 token 交换逻辑。
- **没有进行中的登录时拒绝回调**：无法校验 state 就不能排除 CSRF，
  宁可失败也不用未知来源的 code 去请求 token 端点。
- **`PendingAuthRequestStore.consume()` 一次性**：否则重放同一个回调链接
  就能反复换 token。
- **`state` 与 `code_verifier` 一起存**：分开保存会出现「校验通过但换 token
  时找不到 verifier」。
- **失败原因分流**：非本应用深链 → 静默忽略（用户点了别的链接，不该弹错）；
  本应用回调但 state 不符 / 缺 code → 上报给登录页（可能是 CSRF）。
- **同一条链接也会进 `Router`**：Flutter 引擎把外部 intent 同时推给
  `PlatformRouteInformationProvider` → go_router。`partyb://oidc/callback` 的
  path 是 `/callback`，路由表里没有 → 默认错误页（`Page Not Found` +
  `GoException: no routes for location: ...`），用户先看到一屏异常、退回首页
  才发现已登录。故 `buildAuthRedirect` 在匹配前先挡掉「带 scheme 的
  location」（已登录回首页，否则登录页等回调完成），见 `buildAuthRedirect` 的文档注释。

### 2.3 claimed HTTPS（Android App Links）双形态

自定义 scheme 没有归属校验——任何声明了 `partyb` 的应用都能抢走回调。
claimed HTTPS 由操作系统校验域名归属（RFC 8252 §7.2 首选），因此客户端在
**保留自定义 scheme 的同时**新增一条 `autoVerify` 的 https 过滤器。

| 项 | 位置 | 内容 |
|---|---|---|
| Android 过滤器 | `AndroidManifest.xml` | `<intent-filter android:autoVerify="true">`，`https` + `tbcc.atjog.com` / `tbcc6.atjog.com` + `path="/idp/app/callback"` |
| Dart 常量 | `OidcCallbackUri.claimedHttpsPath` | `/app/callback`（拼在 issuer 的 basePath 之后） |
| Dart 判定 | `OidcCallbackUri.matches()` | 自定义 scheme **与** issuer 推导的 https 形态都认 |
| 漂移守卫 | `apps/spb_mobile/test/android_manifest_applinks_test.dart` | 直接读 manifest/plist 断言与 Dart 常量一致 |

**为什么 host 不硬编码**：回调地址永远是「issuer + `/app/callback`」，而
issuer 已由 `SPB_OIDC_ISSUER` 注入。硬编码域名会让 staging / 双栈构建悄悄
失配，而失配的表现正是最难查的那种「毫无反应」。

**为什么解析侧现在就同时认两种**：服务端开关（IdP `redirectUris` 注册 +
网关 `/.well-known` 路由）与客户端发版不同步。两种都认，切换默认值只是
改一行，不会出现「新版客户端 + 旧服务端」就登不上的窗口。

**当前默认仍是自定义 scheme**：`OidcCallbackUri.redirectUri` 未变。切换前提
是 IdP 侧把 `https://<host>/idp/app/callback` 注册进 `redirectUris`
（id-provider#8 的数据变更部分），否则 authorize 会以
`400 invalid_request` 拒绝。

**服务端前置**（跨仓库，均不在本仓库）：

1. 网关 `configs/gateway.yaml` 的 `verification_files` 返回
   `/.well-known/assetlinks.json`（`Content-Type: application/json`，
   含包名 + 签名指纹）—— api-gateway#12，代码已就绪，**未部署**；
2. IdP 注册 claimed HTTPS 回调 —— id-provider#8，代码已就绪，**未部署**；
3. 指纹必须对应**实际分发的那份 APK**：换签名密钥后不同步更新，已安装
   用户的 App Links 会静默失效。

**验证（需真机，当前被 issue #4 阻塞）**：

```bash
adb shell pm verify-app-links --re-verify com.atjog.spb.spb_mobile
adb shell pm get-app-links com.atjog.spb.spb_mobile   # 期望 verified
```

### 2.4 一处顺带修复

`apps/spb_mobile/lib/main.dart` 原先**没有 `ProviderScope`**，而
`SpbMobileApp` 是 `ConsumerStatefulWidget`——一旦有页面真正读 provider
（登录页读 `authStateProvider`）就会抛异常。本任务改为在 `main()` 里显式建
`ProviderContainer`（顺带让深链监听能在 `runApp` 前启动）并用
`UncontrolledProviderScope` 注入。

---

## 3. 阻塞项：还差什么才能真正登录

**两个前置条件都在 IdP 侧，属跨仓库的生产配置变更**（本仓库无法完成）：

1. **注册回调地址**：把 `partyb://oidc/callback` 加进该 client 的
   `oauth_clients.redirectUris`。**✅ 2026-11-06 完成**（生产库
   `json_insert` 幂等追加，先备份再改）：
   ```console
   $ ssh <deploy-host> 'sqlite3 /opt/<idp>/data/idp.db "SELECT clientId, redirectUris FROM oauth_clients;"'
   client_45f10bfb-0170-4815-b|["http://127.0.0.1/callback","partyb://oidc/callback"]|1
   ```
   反向验证：带 PKCE 的 authorize 请求从 `400 invalid_request` 变为
   **`302` → `/idp/login?redirect_uri=...`**（未登录时的预期跳转；登录完成
   后 302 到 `partyb://oidc/callback?code=...`，由 App 的 intent-filter 接住）。
   custom scheme 能通过 fosite 校验是因为 IdP Go 版的 `RedirectSecureChecker`
   显式信任预注册值；fosite 对非 loopback 的 `redirect_uri` 做**精确匹配**
   （`authorize_helper.go` 的 `isMatchingRedirectURI`，端口通配仅限
   loopback），必须逐字符一致。
2. **需要一个 public client**。—— **✅ 2026-10 已满足**：生产注册了
   `flutter-client`（`tokenEndpointAuthMethod='none'` + 强制 PKCE），见
   `docs/rfc8252-loopback-signin.md` §7。

> 实际采用：未另建 client——桌面与移动共用 `flutter-client`（都是
> public client + PKCE），只是多注册一条自定义 scheme 回调；与网关用的
> 机密 client 仍然隔离。
>
> **2026-09-30 更新**：IdP Go 版已支持 public client（`oauthclient.Create`
> 接受 `tokenEndpointAuthMethod=none`，`oidc.Client.GetTokenEndpointAuthMethod`
> 读真实列值）并强制 public client 使用 PKCE（`EnforcePKCEForPublicClients`）。
> 桌面端已按此实现 RFC 8252 §7.3 loopback 流程（见
> `docs/rfc8252-loopback-signin.md`）。移动端与桌面端共用
> `flutter-client`，用同一套 `OidcClient.exchangeCode` 闭环。

### 3.1 已知的次要不一致（不阻塞，但要记住）

~~`PendingAuthRequestStore` 当前是内存实现~~ → **已改为加密持久化**
（`spb_data` 的 `SecurePendingAuthStore`，走 `flutter_secure_storage`，
单键 JSON，带 10 分钟 TTL；接口上移至 `spb_api`，与 `TokenStore` 同构）。
授权流程把用户带到外部浏览器，应用可能在此期间被系统回收（Android 低内存
常见）；此前内存实现在重启后丢失 `state`/`code_verifier`，表现为「登录后
应用毫无反应」，持久化后回调仍能完成 state 校验与换 token。

---

## 4. 本任务**未**做的部分（避免误读）

- ~~未改 IdP 的 `oauth_clients`~~ → **2026-11-06 已在 IdP 生产库**给
  `flutter-client` 追加 `partyb://oidc/callback`（纯数据变更：`json_insert`
  幂等追加，先 `sqlite3 .backup` 再改；客户端仓库与服务端代码均一行未改）；
- ❌ 未实现内嵌 webview 方案（理由见 §1.2）；
- ~~未做跨进程重启的 `PendingAuthRequest` 持久化~~ → 已实现（见 §3.1）；
- ❌ 未验证真机回跳（本机无 Android 模拟器 `/dev/kvm`、无 iOS 构建环境，
  归 issue #4）。

## 5. 验证命令

```bash
export PATH="$HOME/.local/opt/flutter/bin:$PATH"

# 平台注册
grep -rn 'android:scheme' apps/spb_mobile/android/app/src/main/AndroidManifest.xml
grep -n 'CFBundleURLTypes' apps/spb_mobile/ios/Runner/Info.plist

# 回调接收逻辑（纯逻辑单测，无需设备）
cd apps/spb_mobile && flutter test

# 构建
cd apps/spb_mobile && flutter build apk --debug

# IdP 侧回调已注册（期望 302 到 /idp/login；400 = 未注册；
# state/nonce/challenge 均为假值，只探测授权端点，不涉及凭据）
CID=client_45f10bfb-0170-4815-b
curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' \
  "https://app.example.com/idp/oauth2/authorize?response_type=code&client_id=$CID&redirect_uri=partyb%3A%2F%2Foidc%2Fcallback&scope=openid+profile+email+offline_access&state=s12345678&nonce=n12345678&code_challenge=XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX&code_challenge_method=S256"
```
