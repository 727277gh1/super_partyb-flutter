# IdP / 网关 OIDC 能力实测留档（PKCE 与 redirect_uri）

> 记录「IdP 是否接受自定义 scheme 的 redirect_uri」这一问题的实测结论。
>
> **实测时间**：2026-09-28 · **实测目标**：`https://app.example.com`（经网关，
> 生产入口）与 `https://app.example.com/idp`（IdP 公网路径，经网关反代）。
>
> 本文只记录**观测到的事实与命令输出摘要**，不含任何凭据值。

---

## 0. 结论速览

| 问题 | 实测结论 |
|---|---|
| 网关 `/auth/oidc/authorize` 是否可用？ | ✅ 可用，返回含授权 URL 的 JSON（HTTP 200） |
| 授权 URL 是否带 `code_challenge_method=S256`？ | ✅ **是**，PKCE(S256) 已启用 |
| 客户端能否指定自己的 `redirect_uri`？ | ❌ **不能**。网关**忽略**调用方传入的 `redirect_uri`，硬编码为配置里的 `redirect_url` |
| IdP 是否接受自定义 scheme（`partyb://oidc/callback`）？ | ❌ **不接受**，HTTP 400 `invalid_request` |
| IdP 是否接受 loopback（`http://127.0.0.1:<port>/callback`）？ | ❌ **不接受**，HTTP 400 `invalid_request` |
| 那什么能用？ | ✅ 只有**预注册的三个回调**：`https://app.example.com/auth/oidc/callback`、`https://app2.example.com/auth/oidc/callback`、`http://203.0.113.10:9000/auth/oidc/callback` |
| IdP 是否强制 PKCE？ | ❌ **不强制**（`requirePkce=false`；不带 challenge 也能拿到 302 到登录页） |
| IdP 是否强制客户端密钥？ | ✅ `client_secret_basic` / `client_secret_post`（非 public client） |

**因此选定的 redirect 形态：既不自定义 scheme，也不用 loopback。**
登录必须复用**网关托管的 OIDC 流程**，回调固定落在
`https://app.example.com/auth/oidc/callback`；会话以**网关签发的 HttpOnly Cookie**
形式存在，客户端后续请求携带该 cookie 即可（网关完成认证并注入 `X-User-ID`）。
这与原 Tauri 桌面端（`super_partyb/apps/desktop`）的生产方案一致。

---

## 1. 实测命令与输出

### 1.1 网关授权入口可用，且已启用 PKCE(S256)

```console
$ curl -sS --max-time 20 'https://app.example.com/auth/oidc/authorize?state=probe' | head -c 300
{"authorization_url":"https://app.example.com/idp/oauth2/authorize?access_type=offline\u0026client_id=client_PLACEHOLDER_0000000000000000\u0026code_challenge=ECXCshRLYxxJxpF8Et4InKrylQvtKDmQw2XllgyTDg4\u0026code_challenge_method=S256\u0026nonce=3KoA2t4ddUJaH3oGiFdJwaGCf5-ksSZmWvq0ylTW3Ok\u0026pro
```

响应头同时下发一个 `oidc_request_ctx_<state>` Cookie（`HttpOnly; Secure;
SameSite=Lax; Max-Age=1800`），内含 `state` / `nonce` / `code_verifier` /
`original_path`（base64 编码，可解码核对字段存在性；**值不打印**）。

解码该 cookie 的字段名（只输出长度，不输出值）：

```console
$ # code_verifier 长度
  code_verifier_len = 43
$ # original_path 取值随请求参数变化（见 1.4）
```

> 结论：**PKCE 由网关自己生成并托管**（`code_verifier` 存在服务端 cookie 里，
> 不返回给客户端）。客户端**不需要也不应该**自己生成 `code_verifier`。

### 1.2 网关忽略客户端传入的 redirect_uri

```console
$ curl -sS 'https://app.example.com/auth/oidc/authorize?state=probe&redirect_uri=partyb%3A%2F%2Foidc%2Fcallback' \
  | python3 -c "import sys,json,urllib.parse as u;d=json.load(sys.stdin);print('redirect_uri =',u.parse_qs(u.urlparse(d['authorization_url']).query).get('redirect_uri'))"
redirect_uri = ['https://app.example.com/auth/oidc/callback']
```

即使显式传 `redirect_uri=partyb://oidc/callback`，生成的授权 URL 里仍然是
`https://app.example.com/auth/oidc/callback`。

**代码依据**：`api-gateway/pkg/api/handlers_oidc_authorize.go` 的 `GetAuthURL`
只读取 `state` 与 `post_login_redirect`（后者用于登录后的**站内路径**回跳），
`redirect_uri` 由 `resolveOIDCRedirectURI()` 从网关配置 / `X-Forwarded-Host`
推导，**从不读取 query 参数**：

```go
authorizationURL, err := h.authManager.GetOIDCAuthorizationURL(
    requestCtx.State, requestCtx.Nonce, requestCtx.CodeVerifier,
    resolveOIDCRedirectURI(c, h.authManager))   // ← 不含 c.Query("redirect_uri")
```

`X-Forwarded-Host` 也无法把回调指向别处（网关配了固定 `redirect_url`）：

```console
$ curl -sS -H 'X-Forwarded-Host: 127.0.0.1:8765' '.../auth/oidc/authorize?state=probe' | ...
redirect_uri = ['https://app.example.com/auth/oidc/callback']

$ curl -sS -H 'X-Forwarded-Host: 203.0.113.10:9000' '.../auth/oidc/authorize?state=probe' | ...
redirect_uri = ['https://app.example.com/auth/oidc/callback']
```

### 1.3 IdP 对 redirect_uri 做**精确匹配**（自定义 scheme / loopback 都被拒）

用与网关相同的 `client_id`，直连 IdP 授权端点：

```console
$ CID=client_PLACEHOLDER_0000000000000000

# A) 已注册的网关回调 → 302（正常进入登录页）
$ curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  "https://app.example.com/idp/oauth2/authorize?response_type=code&client_id=$CID&redirect_uri=https%3A%2F%2Fapp.example.com%2Fauth%2Foidc%2Fcallback&scope=openid&state=s12345678"
HTTP 302

# B) 自定义 scheme → 400
$ curl -sS -w ' <- HTTP %{http_code}\n' \
  "https://app.example.com/idp/oauth2/authorize?response_type=code&client_id=$CID&redirect_uri=partyb%3A%2F%2Foidc%2Fcallback&scope=openid&state=s12345678"
{"error":"invalid_request","error_description":"... The 'redirect_uri' parameter does not match any of the OAuth 2.0 Client's pre-registered redirect urls."} <- HTTP 400

# C) loopback → 400
$ curl -sS -w ' <- HTTP %{http_code}\n' \
  "https://app.example.com/idp/oauth2/authorize?response_type=code&client_id=$CID&redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback&scope=openid&state=s12345678"
{"error":"invalid_request","error_description":"... The 'redirect_uri' parameter does not match any of the OAuth 2.0 Client's pre-registered redirect urls."} <- HTTP 400
```

该 client 在 IdP 库中注册的回调（`oauth_clients.redirectUris`，仅取该列）：

```console
$ ssh <deploy-host> 'sqlite3 /opt/<idp>/data/idp.db "SELECT clientId, redirectUris, isActive FROM oauth_clients;"'
client_PLACEHOLDER_0000000000000000|["http://203.0.113.10:9000/auth/oidc/callback","https://app.example.com/auth/oidc/callback","https://app2.example.com/auth/oidc/callback"]|1
client_ba4ea75c-51b8-4669-a|[]|1
```

**没有任何自定义 scheme，也没有 loopback 条目。**

> 补充：IdP 显式放行了「非 localhost 的 http redirect_uri」
> （`id-provider/go/internal/oidc/provider.go` 的 `RedirectSecureChecker`
> 恒返回 `true`，注释说明「信任已注册的 redirect_uri，fosite 后续会校验 URI
> 与注册值匹配」）。**这条放行只放宽了 scheme，没有放宽匹配**——所以
> `http://203.0.113.10:9000/...` 能过，而 `http://127.0.0.1:8765/...` 不能。

### 1.4 登录后回跳只允许**站内路径**（开放重定向防护）

`post_login_redirect`（别名 `redirect`）经 `isSafeLocalRedirectPath()` 校验：
必须是站内绝对路径，非绝对 URL、无 host、不以 `//` 或 `\` 开头。

```console
$ # 站内路径 → 保留
$ curl -sS '.../auth/oidc/authorize?state=probe&post_login_redirect=%2Fpbw%2Fzh%2Fworkbench%2F'
  original_path = '/pbw/zh/workbench/'

$ # 自定义 scheme → 丢弃（置空）
$ curl -sS '.../auth/oidc/authorize?state=probe&post_login_redirect=partyb%3A%2F%2Foidc%2Fcallback'
  original_path = ''

$ # 外部绝对 URL → 丢弃
$ curl -sS '.../auth/oidc/authorize?state=probe&post_login_redirect=https%3A%2F%2Fevil.example%2Fx'
  original_path = ''
```

**因此不能借 `post_login_redirect` 把用户送回自定义 scheme。**

### 1.5 未认证时网关的行为：浏览器 → 302 跳登录；API 客户端 → 401

```console
# 无 cookie、普通 curl（API 语义）→ 401 JSON
$ curl -sS -o /tmp/nc.txt -w 'HTTP %{http_code} location=%{redirect_url}\n' 'https://app.example.com/pba/chat/groups?limit=1'
HTTP 401 location=
{"error":"authentication failed","message":"Invalid or missing authentication credentials"}

# 带假 cookie → 同样 401
$ curl -sS -o /tmp/fc.txt -w 'HTTP %{http_code}\n' -H 'Cookie: access_token=bogus; id_token=bogus' 'https://app.example.com/pba/chat/groups?limit=1'
HTTP 401
{"error":"authentication failed","message":"Invalid or missing authentication credentials"}

# 浏览器语义（Accept: text/html）→ 302 到 IdP 授权端点（带 S256 challenge）
$ curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -H 'Accept: text/html,application/xhtml+xml' 'https://app.example.com/pbw/zh/workbench/'
HTTP 302
location=https://app.example.com/idp/oauth2/authorize?...&code_challenge_method=S256&...&redirect_uri=https%3A%2F%2Fapp.example.com%2Fauth%2Foidc%2Fcallback&...
```

判定逻辑见 `api-gateway/pkg/middleware/auth_failure.go` 的
`shouldRedirectToOIDC()`：`auth_mode=browser` 或（默认模式下 `isBrowserRequest`）
才 302，否则 401 JSON。

### 1.6 会话 Cookie 的名字与作用域（客户端需要知道的部分）

网关回调成功后由 `setAuthTokenCookies()`（`api-gateway/pkg/api/handlers_oidc_helpers.go`）
下发，全部 `HttpOnly=true`：

| Cookie | 有效期 | 说明 |
|---|---|---|
| `access_token` | 3600s | 网关鉴权实际使用的凭据 |
| `id_token` | 3600s | OIDC ID Token |
| `refresh_token` | 7 天 | 仅当 IdP 返回 refresh_token 时下发 |

- `Domain` 取自 `X-Forwarded-Host`（生产为 `app.example.com`，即**网关域名**，
  不是 IdP 域名）；
- 网关侧读取顺序见 `api-gateway/pkg/middleware/auth_cookie.go`
  （先 `id_token`，失效再用 `refresh_token`）。

### 1.7 IdP 的 PKCE 强制与客户端类型

```console
$ curl -sS 'https://app.example.com/idp/.well-known/openid-configuration'
{"issuer":"https://app.example.com/idp",
 "authorization_endpoint":".../idp/oauth2/authorize",
 "token_endpoint":".../idp/oauth2/token",
 "token_endpoint_auth_methods_supported":["client_secret_basic","client_secret_post"],
 "grant_types_supported":["authorization_code","refresh_token","client_credentials"],
 "response_types_supported":["code","id_token","code id_token"], ...}
```

- **PKCE 非强制**：`oauth_clients.requirePkce=false`，且实测「不带
  `code_challenge`」「`code_challenge_method=plain`」「`code_challenge` 非
  base64url」三种请求**都返回 302**（fosite 此时对 `plain` 也放行）。
  → 客户端**不能依赖** IdP 强制 PKCE 来保证安全；好在我们根本不经手 PKCE
  （见 §2）。
- **不是 public client**：token 端点要求 `client_secret_basic` 或
  `client_secret_post`。→ 客户端即使拿到 authorization code，**没有
  client_secret 也换不到 token**。这从另一侧堵死了「客户端自己走授权码流程」。

---

## 2. 据此选定的实现形态

### 2.1 选定：复用网关托管的会话（Cookie 转发）

```text
Flutter 客户端
  │ 1. 打开系统浏览器 / webview 访问
  │    https://app.example.com/auth/oidc/authorize?state=<rand>&post_login_redirect=<站内路径>
  │       （不带 redirect_uri —— 带了也会被忽略）
  ▼
网关 → IdP 登录页 → 用户登录 → 302 回 https://app.example.com/auth/oidc/callback
  │ 2. 网关换 token、下发 HttpOnly Cookie，再 302 回 post_login_redirect 指定的站内路径
  ▼
Flutter 客户端
  │ 3. 取得 access_token / id_token cookie，后续请求带上
  ▼
网关 /pba/* → OIDC 校验 → 注入 X-User-ID → Go API
```

理由（按重要性）：

1. **唯一被服务端允许的路径**：IdP 只认三个预注册回调，且网关硬编码回调地址。
   任何「客户端自定义 scheme / loopback」方案都需要先改 IdP 的 client 注册
   （`oauth_clients.redirectUris`，走 IdP admin API `/idp/api/clients`），
   属于**跨仓库改动 + 生产配置变更**，超出本仓库范围，也与 AGENTS.md
   「Go API 一行不改」的约束相冲突。
2. **不需要解析 JWT、不需要 API Key**：与 AGENTS.md §5.1 的认证模型完全一致
   （客户端只带会话凭据，`X-User-ID` 是网关注入的结果）。
3. **有生产先例**：原 Tauri 桌面端就是这么做的
   （`super_partyb/apps/desktop/src-tauri/src/sync/auth.rs`：转发 webview 的
   session cookie 给网关，明确不解析 JWT、不做 token 刷新）。
4. **不引入第二个会话所有者**：会话由网关维护，客户端只是转发者。若客户端
   自己走 PKCE 流程，就会与网关的会话状态分叉。

### 2.2 客户端侧的具体要求

| 项 | 要求 |
|---|---|
| `redirect_uri` | **不要传**（网关忽略）。传了只会误导后人以为它生效 |
| `post_login_redirect` | 可选，仅**站内绝对路径**（如 `/`）；传非站内值会被静默丢弃 |
| PKCE | **不需要自己生成** `code_verifier`（网关生成并存在 `oidc_request_ctx_*` cookie 里） |
| token 获取 | 从 Cookie 取 `access_token`（主）/ `id_token` / `refresh_token` |
| 会话 cookie 名 | `access_token`、`id_token`、`refresh_token`（见 §1.6） |
| Cookie 域 | 网关域（生产 `app.example.com`），**不是** IdP 域 |
| 401 处理 | 映射为「未认证」错误并引导重新登录；**不要**尝试自行刷新（网关负责） |

### 2.3 各平台取 Cookie 的可行手段（**含一处 Linux 硬约束**）

| 平台 | 手段 | 状态 |
|---|---|---|
| Android / iOS | 内嵌 webview（`webview_flutter` / `flutter_inappwebview`）读 cookie | ✅ 可行 |
| Windows / macOS | 同上（`webview_flutter` 支持 macos；`flutter_inappwebview` 支持 windows/macos） | ✅ 可行 |
| **Linux 桌面** | **无主流 Flutter webview 插件** | ⚠️ **受限，见下** |

实测插件平台支持（`pub.dev` API）：

```console
$ curl -sS 'https://pub.dev/api/packages/flutter_inappwebview' | ...
version: 6.1.5
platforms: ['android', 'ios', 'macos', 'web', 'windows']      # ← 无 linux

$ curl -sS 'https://pub.dev/api/packages/webview_flutter' | ...
version: 4.14.1
platforms: ['android', 'ios', 'macos']                        # ← 无 linux
```

→ **Linux 桌面端不能靠内嵌 webview 拿 cookie。** 可行替代：

1. **`url_launcher` 打开系统浏览器**完成登录（本机 pub cache 已有
   `url_launcher-6.3.2`，且支持 `url_launcher_linux-3.2.2`），
   然后由用户把 cookie 粘贴/导入；
2. 或让用户在设置里填「从浏览器导入 cookie」；
3. 或后续把「Linux 登录」单独立项（例如与 AGW 协商一个 `X-Forwarded-Host`
   对齐的 loopback 回调，需要**先注册新 client 或新增 redirect_uri**）。

> ⚠️ 这一条会影响 OIDC 客户端 / 登录页 / 移动端回跳的实现形态，但
> **本任务只负责留档与结论**，不在本轮做实现决策。

---

## 3. 对后续任务的影响

| 任务 | 影响 |
|---|---|
| OIDC 客户端（纯 Dart） | 本仓**不需要**完整的 PKCE 授权码交换（客户端拿不到 `client_secret`，IdP 也不强制 PKCE）。该任务应改为「**构造授权 URL + 接收会话凭据**」的薄客户端；纯 Dart 部分可测的是 URL 构造与 cookie/凭据解析 |
| token 存储 | 存的是**会话 cookie**（`access_token` 等），不是自签 token；401 仍应映射为 `AuthError` |
| 登录页 | 两端形态不同：移动/Windows/macOS 可用内嵌 webview；**Linux 桌面需系统浏览器 + cookie 导入** |
| 移动端自定义 scheme 回跳 | **不可行**（IdP 拒绝自定义 scheme）。该任务应改为「用内嵌 webview 直接读 cookie」；如坚持要 scheme 回跳，必须先注册 IdP client（跨仓库） |
| UFS 客户端 | 请求带会话 cookie 走网关 `/ufs/*`（与原 Tauri 一致），不做本地 token 刷新 |

---

## 4. 未验证 / 需人工确认的部分

以下需要**有桌面环境 + 真实账号**的机器才能闭环（本机无 DISPLAY，归 issue #4）：

1. 网关 `HandleCallback` 成功后，`access_token` cookie 是否确实按
   `Domain=app.example.com` 下发（本次只验证了 `oidc_request_ctx_*` cookie 的
   下发，未走完整个登录）；
2. 内嵌 webview 能否读到 HttpOnly 的 `access_token`（各平台行为不同：
   `webview_flutter` 在 Android/iOS 有 `CookieManager`，但**HttpOnly 可见性
   依实现而异**）；
3. Linux 桌面端「系统浏览器登录 + cookie 导入」的 UX 是否可接受；
4. `refresh_token` 是否真的下发（依赖 IdP 侧该 client 是否授予
   `offline_access` 并返回 refresh_token）。

---

## 5. 复现清单

```bash
# 1) 网关授权入口（PKCE 已启用）
curl -sS --max-time 20 'https://app.example.com/auth/oidc/authorize?state=probe' | head -c 300

# 2) 网关忽略客户端 redirect_uri
curl -sS --max-time 20 'https://app.example.com/auth/oidc/authorize?state=probe&redirect_uri=partyb%3A%2F%2Foidc%2Fcallback'

# 3) IdP 精确匹配 redirect_uri（自定义 scheme / loopback 均 400）
CID=client_PLACEHOLDER_0000000000000000
curl -sS --max-time 20 -w ' <- HTTP %{http_code}\n' \
  "https://app.example.com/idp/oauth2/authorize?response_type=code&client_id=$CID&redirect_uri=partyb%3A%2F%2Foidc%2Fcallback&scope=openid&state=s12345678"
curl -sS --max-time 20 -w ' <- HTTP %{http_code}\n' \
  "https://app.example.com/idp/oauth2/authorize?response_type=code&client_id=$CID&redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback&scope=openid&state=s12345678"

# 4) 已注册回调正常（302）
curl -sS --max-time 20 -o /dev/null -w 'HTTP %{http_code}\n' \
  "https://app.example.com/idp/oauth2/authorize?response_type=code&client_id=$CID&redirect_uri=https%3A%2F%2Fapp.example.com%2Fauth%2Foidc%2Fcallback&scope=openid&state=s12345678"

# 5) 未认证：API 语义 401 / 浏览器语义 302
curl -sS --max-time 20 -o /dev/null -w 'HTTP %{http_code}\n' 'https://app.example.com/pba/chat/groups?limit=1'
curl -sS --max-time 20 -o /dev/null -w 'HTTP %{http_code}\n' -H 'Accept: text/html' 'https://app.example.com/pbw/zh/workbench/'

# 6) IdP 发现的 token 端点认证方式
curl -sS --max-time 20 'https://app.example.com/idp/.well-known/openid-configuration'
```

> 说明：步骤 3/4 只做了**授权端点**探测（`state` 为固定假值，未完成登录），
> 因此不涉及任何凭据；`client_secret` 未使用，也不在本文档中记录。
