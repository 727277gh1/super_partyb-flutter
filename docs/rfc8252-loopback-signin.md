# 桌面端登录：RFC 8252 §7.3 loopback 授权码流程

> 状态：已实现（客户端 + IdP 侧），待生产注册 public client。
> 替代此前的「网关托管 OIDC + 粘贴导入会话」方案。
> 相关：`docs/oidc-verification.md`（旧方案的实测依据）、
> `docs/mobile-oidc-deeplink.md`（移动端，同一思路的自定义 scheme 变体）。

---

## 0. 为什么换方案

旧方案（见 `docs/oidc-verification.md`）走网关托管流程，会话 Cookie 落在
**浏览器**里；Linux 桌面无 webview 插件，客户端读不到 Cookie，只能让用户手工
粘贴会话。登录**无法自动闭环**。

RFC 8252 §7.3 为桌面操作系统指定了正解：

> Native apps that are able to open a port on the loopback network interface
> without needing special permissions (typically, those on desktop operating
> systems) can use the loopback interface to receive the OAuth redirect.
> Loopback redirect URIs use the "http" scheme and are constructed with the
> loopback IP literal and **whatever port the client is listening on**.

即：客户端自己 bind `127.0.0.1:<随机端口>` 接收回调，不依赖浏览器 Cookie，
也不需要内嵌 webview。**这是本次实现采用的方案。**

---

## 1. 完整链路

```text
桌面客户端
  │ ① bind 127.0.0.1:<随机端口>（LoopbackRedirectServer，纯 Dart HttpServer）
  │ ② 生成 state（CSRF）+ PKCE(S256)（RFC 7636）
  │ ③ 拼授权 URL 直连 IdP：
  │    GET {issuer}/oauth2/authorize
  │        ?response_type=code&client_id=<public-client>
  │        &redirect_uri=http://127.0.0.1:<port>/callback
  │        &scope=openid profile email offline_access
  │        &state=<rand>&nonce=<rand>
  │        &code_challenge=<S256>&code_challenge_method=S256
  │ ④ xdg-open → 系统浏览器（RFC 8252 §8.12：必须用外部用户代理）
  ▼
IdP 登录页 → 用户登录 → 302 回 http://127.0.0.1:<port>/callback?code=...&state=...
  │ ⑤ 本地监听器取出回调 URL → 关停（一次性）
  │ ⑥ state 校验（防 CSRF）
  │ ⑦ POST {issuer}/oauth2/token
  │      grant_type=authorization_code&code=...&client_id=<public-client>
  │      &redirect_uri=<同一个>&code_verifier=<明文 verifier>
  │      （public client：**不带** client_secret）
  ▼
  │ ⑧ 落 SecureTokenStore → AuthStateNotifier.signedIn() → 路由守卫放行
  ▼
后续请求：Authorization: Bearer <id_token> → 网关 JWT 认证器（JWKS 验 RS256）
```

## 2. 为什么必须直连 IdP（不能走网关 `/auth/oidc/authorize`）

网关的 `GetAuthURL`（`api-gateway/pkg/api/handlers_oidc_authorize.go`）**从不
读取调用方的 `redirect_uri`**——回调地址由 `resolveOIDCRedirectURI()` 从网关
配置推导。因此走网关的话，code 永远只落在网关回调，客户端拿不到。

RFC 8252 流程要求客户端**自己接收回调**，故授权请求必须直连 IdP 的
`/oauth2/authorize`（经网关 `/idp/*` 反代，路由 `skip_auth: true`）。

## 3. 为什么必须用 public client

IdP 的 token 端点要求 `client_secret_basic` / `client_secret_post`
（`oauth_clients.tokenEndpointAuthMethod`）。桌面客户端**无法安全保存密钥**
（RFC 8252 §8.5：分发给多个安装的密钥不能当作机密）。故需要注册一个
**public client**：

| 字段 | 值 |
|---|---|
| `tokenEndpointAuthMethod` | `none` |
| `clientSecret` | 空串（`oidc.Client.IsPublic()` 以「密钥列为空」判定） |
| `redirectUris` | `["http://127.0.0.1/callback"]`（**不含端口**，见下） |
| `grantTypes` | `["authorization_code","refresh_token"]` |
| `scopes` | `["openid","profile","email","offline_access"]` |
| `requirePkce` | `true` |

安全由 **PKCE 强制**保证：IdP 侧 `EnforcePKCEForPublicClients: true`
（RFC 8252 §4 要求 public client 必须用 PKCE）。

## 4. 端口为什么可以通配

fosite v0.49.0 原生支持 RFC 8252 §7.3 的动态端口
（`authorize_helper.go` 的 `isMatchingAsLoopback`）：注册
`http://127.0.0.1/callback`（无端口）后，**任意端口的回调都被接受**——
比较 scheme + hostname + path + query，**跳过端口**。

因此客户端每次登录 bind 随机端口即可，无需为每个端口预注册。

⚠️ 两个易错点：

- **必须用 `127.0.0.1` 字面量，不能用 `localhost`**：RFC 8252 §7.3 明确
  「use of localhost is NOT RECOMMENDED」（可能解析到非回环地址），且
  fosite 的匹配是「注册值与请求值 Hostname 相等」——用 `localhost` 注册就
  只能收 `localhost` 回调，两种拼写不能混用。
- **注册值不能带端口**：带了就变成精确匹配，通配失效。

## 5. 为什么换到的 token 能过网关

网关的认证器按优先级依次尝试，**JWT 认证器优先于 OIDC 认证器**：

- `JWT`（`pkg/auth/jwt_authenticate.go`）：用 IdP 的 JWKS
  （`auth.jwt.jwks_url: http://127.0.0.1:3000/idp/.well-known/jwks.json`）
  验 RS256 签名，**不校验 audience**，`UserID` 取 `user_id` 缺失时回落 `sub`；
- IdP 签发的 ID Token 正是 RS256 + 含 `sub`。

故 `Authorization: Bearer <id_token>` 直接通过。**网关无需任何改动。**

> 注：若将来启用了 aud 校验，需把桌面端 client_id 加入白名单。当前不校验，
> 故本次不改网关。

## 6. 改动清单

### 客户端（`super_partyb-flutter`）

| 文件 | 内容 |
|---|---|
| `packages/spb_api/lib/src/loopback_redirect_server.dart` | 新增：loopback 监听器（随机端口、一次性、超时、state 由调用方校验）+ `LoopbackCallbackUri` |
| `packages/spb_api/lib/spb_api.dart` | 导出上述 |
| `apps/spb_desktop/lib/auth_loopback.dart` | 新增：`loopbackSignIn` 编排（监听→开浏览器→收回调→换 token） |
| `apps/spb_desktop/lib/providers.dart` | `signInActionProvider` 改为 loopback（含落盘 + 推进状态） |
| `packages/spb_core/lib/src/env.dart` | `oidcRedirectUri` 默认值改为 `http://127.0.0.1/callback` |
| `packages/spb_features/lib/src/auth/login_page.dart` | 文案与文档对齐 loopback 流程；粘贴导入降级为兑底路径 |
| `apps/spb_desktop/lib/auth_browser.dart` | 保留（`xdg-open`）；`openGatewaySignIn` 保留供降级/调试 |

### IdP（`id-provider`）

| 文件 | 内容 |
|---|---|
| `go/internal/oidc/store.go` | `Client` 增加 `TokenEndpointAuthMethod` 列；`GetClient`/`CreateClient` 读写它；`GetTokenEndpointAuthMethod` 读真实值（空串回落 basic）；`RegisterClient` 支持 public client |
| `go/internal/oidc/provider.go` | 开启 `EnforcePKCEForPublicClients`；注释说明 loopback 通配由 fosite 负责 |
| `go/internal/oauthclient/oauthclient.go` | `Create` 支持 `tokenEndpointAuthMethod=none`（密钥列存空串而非哈希） |
| `go/internal/oidc/loopback_test.go` | 新增：动态端口通配、错误 host 拒绝、public client PKCE 全流程、缺 PKCE 被拒、机密客户端不受影响 |
| `go/internal/oauthclient/oauthclient_test.go` | 新增：public client 创建（密钥列为空） |

## 7. 生产启用步骤

### 7.1 IdP 侧注册 public client

经 IdP admin API（`POST /idp/api/clients`，需 admin 凭据）：

```json
{
  "name": "PartyB Desktop (loopback)",
  "redirectUris": ["http://127.0.0.1/callback"],
  "grantTypes": ["authorization_code", "refresh_token"],
  "responseTypes": ["code"],
  "scopes": ["openid", "profile", "email", "offline_access"],
  "tokenEndpointAuthMethod": "none",
  "requirePkce": true
}
```

记录返回的 `clientId`（**public client 无 secret**）。

### 7.2 构建时注入 clientId

```bash
flutter build linux --release \
  --dart-define=SPB_API_BASE_URL=https://api.example.com/pba \
  --dart-define=SPB_UFS_BASE_URL=https://api.example.com/ufs \
  --dart-define=SPB_OIDC_ISSUER=https://app.example.com/idp \
  --dart-define=SPB_OIDC_CLIENT_ID=<上一步的 clientId> \
  --dart-define=SPB_ENV=prod
```

⚠️ **不要**注入 `SPB_OIDC_REDIRECT_URI`：桌面端运行时用
`copyWithRedirectUri` 覆盖为带随机端口的地址，编译期值只是「不含端口的
注册值」。

### 7.3 部署 IdP 二进制

```bash
cd id-provider/go && make build && bash scripts/deploy-<host>.sh
```

> IdP 侧改动**不需要数据库迁移**：`oauth_clients.tokenEndpointAuthMethod`
> 列在 `001_init` 就已存在，本次只是让 Go 代码开始读它。

## 8. 安全边界（逐条对照 RFC 8252）

| 要求 | 实现 |
|---|---|
| §8.12 必须用外部用户代理，禁止内嵌 webview | 系统浏览器（`xdg-open`） |
| §7.3 只监听回环接口 | `HttpServer.bind(InternetAddress.loopbackIPv4, 0)` |
| §7.3 随机端口 | `port: 0` 由内核分配 |
| §4 强制 PKCE | IdP `EnforcePKCEForPublicClients: true`；客户端 S256 |
| §8.5 不把密钥分发给客户端 | public client（无 secret） |
| state 防 CSRF | 回调 state 比对，不匹配即拒绝且**不换 token** |
| 一次性回调 | 收到即关停；超时自动关停 |
| token 不进 URL | token 只经 token 端点的 POST 响应；浏览器页不显示任何参数 |

## 9. 已知限制

- **IdP 侧 public client 尚未在生产注册**：未注册前 `loopbackSignIn` 会在
  授权阶段收到 IdP 的 `400 invalid_request`。此时**粘贴导入会话仍是可用降级**
  （登录页保留该入口）。
- **移动端仍走自定义 scheme**（`partyb://oidc/callback`），需要 IdP 单独注册
  该回调——移动端没有 loopback 监听能力（Android/iOS 沙箱）。本次未改移动端。
- **Linux 无 GUI 环境无法端到端手测**：`docs/` 已记录本机限制；自动化测试覆盖
  到「假浏览器 + 真 loopback 监听 + 假 token 端点」全链路，真实浏览器登录需
  在有桌面环境的机器上验证。
- **IdP 登录页回跳**：若用户在 IdP 处未登录，授权端点会 302 到
  `/idp/login?redirect_uri=...`，登录后回到原授权请求——这条路径沿用既有实现，
  未改动。
