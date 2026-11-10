# 认证与会话

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。登录与会话的四次真实事故：登录成功却停在登录页、Bearer 取错 token、
一次断网被当成凭证失效、会话失效后不回登录页。

> 编号（`§6.x` / `§5.x` / `[§7](build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](README.md)。

---

### 6.34 会话失效 → 回登录页（`AuthInterceptor.onSessionExpired`）

**症状**：会话真的过期后，客户端弹一句「会话已失效，请重新登录」，然后**卡在
当前页面**——不会回登录页，用户只能手动进设置页点「退出登录」。

#### 根因：链路上每一段都在，唯独中间那段是断的

| 环节 | 修复前 |
|---|---|
| `AuthInterceptor.onError` | 401 → 尝试刷新 → 失败则归一化成 `AuthError` 抛给调用方。注释写着「**由上层统一监听 AuthError 并跳转登录页**」 |
| 那个「上层监听」 | **不存在**。全仓 `markUnauthenticated` 只有 3 个调用点：移动端深链登录失败 1 处 + 两端各 1 处定义。生产路径**零调用** |
| 各页面 catch 到 `AuthError` | 只翻成一句 SnackBar 文案（`_describeGroupActionError` / `_describeGoalError` / `_describeNewSessionError`…），不做导航 |
| SSE 401 | `SseClient` 置 `SseState.failed` 并推 `frames` 的 error → `ChatStreamController.errors`，而**没有任何装配层订阅它** |
| 路由守卫 | 逻辑本身是对的（`buildAuthRedirect` + `AuthRefreshNotifier`），只要 `authState` 变成 `unauthenticated` 就会重定向到 `/login?from=…` |

即：**下游（守卫）一直是好的，上游（把状态推进到未登录）根本没人做**。

#### 修法：拦截器给一个回调，装配层接到 `markUnauthenticated`

```
401 → AuthInterceptor.onSessionExpired(message)
  → authStateProvider.notifier.markUnauthenticated(message)
  → AuthRefreshNotifier.notifyListeners()（只在 status 变化时）
  → go_router 重跑 buildAuthRedirect
  → '/login?from=<当前页>'
```

`markUnauthenticated` 的既有语义正好合适：**不清凭证**（401 可能是网关侧临时
问题，清掉会让用户丢 refresh_token），只把状态置为 `unauthenticated`。

#### 五个不得违反的约束（改之前必读）

| 约束 | 为什么 |
|---|---|
| **403 绝不触发** | 403 是「已认证但无权限」。把它当登出，用户「点了一个没权限的按钮」就会被直接踢出登录 |
| **只在「刷新也失败」之后触发** | `SessionManager._doRefresh` 明确保留「临时网络故障不该让用户登出」这一取向。唯一可信的信号是「刷新过了，服务端仍然 401」 |
| **重放路径也要触发，但要带 `_retriedKey` 守卫** | 「刷新成功但重放仍 401」（账号被禁/会话被撤销）同样是确定失效。但重放请求**也经过本拦截器**，不带守卫会通知两次（实测：回调被调 2 次） |
| **回调里不导航** | 同一时刻可能有多个请求同时 401，导航副作用会打架。重定向只由路由守卫做一次 |
| **装配层用 `ref.read` 而非 `watch`** | `dioProvider` 若 watch 认证状态，每次登录/登出都会重建 Dio——而 Dio 与 SseClient 的身份被 `ChatStreamController` 与页面的 `??=` 订阅持有，重建会让时间线**静默冻结**（同 §5.1.1 的 `EndpointRewriteInterceptor` 那条） |

#### 接线点：**4 处**，不是 2 处

两端各有 `dioProvider` 与 `ufsDioProvider`，**四个都要接**：UFS 请求走的是同一个
网关会话，也会 401。只接 API 那个会让「文件预览失败」不把人带回登录页。

两端各自抽了一个私有 helper `_sessionExpiredHandler(ref)`，四个构造点共用。

#### 测试（拦截器 5 条 + 两端各 2 条）

| 层 | 用例 | 钉住 |
|---|---|---|
| `spb_api` | 401 且刷新失败 → 回调调用一次 | 该触发时触发 |
| 同上 | 刷新成功且重放成功 → **不触发** | 静默续期不该踢人 |
| 同上 | **403 → 绝不触发** | 反方向（误触发会踢掉正常无权限操作） |
| 同上 | 刷新成功但重放仍 401 → 触发一次 | 通知不随重放叠加 |
| 同上 | 未配置回调时行为不变 | 向后兼容 |
| 两端 router | 已登录时状态被推进 → 停在 `/login?from=<原页>`、登录页显示原因、`clearCount == 0` | 整条链路 + 不清凭证 |
| 两端 router | `dioProvider` 真实构造的拦截器接上了回调 | **接线漏接** |

⚠️ **第二条 router 用例为什么不能用 harness 的 dio**：`pumpApp` 把 `dioProvider`
**整体覆盖**成「挂了 `DioAdapter` 的 dio」，那个 dio 没有 `AuthInterceptor`。
在那里发 401 只能得到裸 `DioException`（实测：断言路由仍停在 `/settings`）。
故它另建一个只覆盖 `tokenStoreProvider` 的容器，让 `dioProvider` 走真实实现，
再把适配器换成「一律 401」。

#### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| `dioProvider` 去掉 `onSessionExpired` 接线 | 接线用例失败（`isUnauthenticated` 为 false） |
| `onError` 里去掉回调调用 | 拦截器 1 条失败 |
| 去掉 `_retriedKey` 守卫 | 「重放仍 401」用例失败（回调被调 2 次） |

#### 有意不做

- **不在拦截器里 `context.go('/login')`**：拦截器是传输层，不应持有导航知识；
  且多请求并发 401 会重复导航。
- **不订阅 `ChatStreamController.errors` 做 SSE 兜底**：SSE 的 401 在绝大多数
  场景下会伴随一次普通 HTTP 401（时间线回填 / `/api/auth/me`），主路径已覆盖。
  单独做需要额外一条用例钉住「只有 SSE 在跑」的时序，收益不足以在本轮引入。

### 6.36 登录成功后停在登录页：`signIn()` 把已登录盖回 `unknown`

**症状**：点「使用 SSO 登录」，浏览器里确实登录成功、`loopbackSignIn` 也拿到了
token（安全存储里**有凭证**），但客户端仍停在 `/login`，界面显示「已发起，等待
浏览器回调」。**重启应用就正常了**——因为 `restore()` 从存储里读到了 token。

#### 根因：旧实现的收尾分支在新实现里变成数据破坏

`AuthStateNotifier.signIn()` 收尾时**无条件**写：

```dart
state = const AuthState(status: AuthStatus.unknown, message: null);
```

这条是给**旧实现**（`openGatewaySignIn`，只发起、等浏览器 Cookie 回调）留的
——那时本进程确实不知道结果。而 `2d453cf` 把桌面端换成 RFC 8252 loopback 后，
`signInAction` 变成了**同步等到 token**：

```
loopbackSignIn → 收 code → 换 token → tokenStore.write() → signedIn()
                → 状态已是 authenticated
                → signIn() 返回 null
                → signIn() 收尾写 state = unknown   ← 把 authenticated 盖掉
```

守卫 `buildAuthRedirect` 对 `unknown` 是**明确放行**的（§6.34 里那条：读凭证是
异步的，启动瞬间不能重定向）。于是状态停在 `unknown` → 守卫不重定向 → 用户
永远停在 `/login`。

**为什么重启就好**：`restore()` 走的是另一条路径（读存储 → `authenticated`），
不经过 `signIn()` 的收尾分支。这也解释了「凭证明明在，界面就是不进去」。

#### 修法：判据不是「谁先谁后」，而是「别把已登录改回未判定」

```dart
if (!state.isAuthenticated) {
  state = const AuthState(status: AuthStatus.unknown, message: null);
} else if (state.message != null) {
  state = state.copyWith(clearMessage: true);   // 只清旧错误，不动 status
}
```

`unknown` 的语义是「**还不知道**」，已经知道的事不该被它覆盖。

⚠️ **移动端一并修**，虽然它的真实流程是「只发起 → 等深链回调」（返回时确实该是
`unknown`）：回调接收器（`authDeepLinkReceiverProvider` 的 `onCode`）可能在
`signIn()` 返回**之前**就完成并调了 `signedIn()`。那时同样会被盖掉。两端共用
一条判据比「各按各的时序假设」更安全。

#### 为什么测试没抓到（**两个假绿**）

| 既有用例 | 它断言了什么 | 漏了什么 |
|---|---|---|
| `登录页点击 SSO 按钮调用注入的 signInAction` | 动作被调用 **1 次** | 完全没看状态 |
| `登录成功后守卫放行首页` | 绕过 `signIn()` 直接调 `signedIn()` | 跳过了唯一有缺陷的那段代码 |

两条都绿而缺陷在。这与 [§6.21](testing.md) / [§6.26](testing.md) / [§6.33](build-and-release.md) 同一类：**绿不代表对**。

现补的用例（两端各 1 条）从**按钮**出发、走完整链路，断言「状态是
`authenticated`」+「路由已离开 `/login`」+「登录按钮消失」。修复前红（
`isAuthenticated` 为 false），修复后绿。

#### 反向验证（实测）

把 `if (!state.isAuthenticated)` 改回无条件赋值 → 两端各 1 条失败。

### 6.37 登录成功后立刻「会话已失效」：把不透明 `access_token` 当 Bearer

**症状**：SSO 登录在浏览器里成功、`idp-go` 的 `/oauth2/token` 返回 200，但客户端
一进首页就弹「会话已失效，请重新登录」，并被踢回 `/login`。

#### 根因：IdP 的 `access_token` 是 fosite 不透明串，网关只认 RS256 JWT

两边的契约从来没对齐过：

| 侧 | 事实 |
|---|---|
| IdP（`id-provider/go/internal/oidc/provider.go:81`） | `compose.ComposeAllEnabled` → `NewOAuth2HMACStrategy`：`access_token` 是 **`ory_at_…` 不透明串**（无点号）；只有 `id_token` 由 `NewOpenIDConnectStrategy` 签成 **RS256 JWT** |
| 网关（`api-gateway/pkg/auth/`） | `jwt_authenticate.go`（JWKS + RS256）与 `oidc_auth.go`（go-oidc `verifier.Verify`）**都要求 compact JWS（三段）**；`manager.go` 只装配 JWT / OIDC / APIKey / mTLS，**没有 opaque token 的 introspect 通路** |
| 客户端（修复前） | 四处 `StoredTokens(accessToken: tokens.accessToken)`——把不透明串当 Bearer 发出去 |

于是网关日志是这两句（2026-10-20 19:55，bcc 的 `journalctl -u api-gateway`）：

```
"OIDC ID Token验证失败" error:"oidc: malformed jwt: go-jose/go-jose: compact JWS format must have three parts"
"JWT validation failed"  error:"token is malformed: token contains an invalid number of segments"
```

客户端 `AuthInterceptor` 收到 401 → 刷新也失败 → `onSessionExpired` → 路由守卫
把用户送回登录页（§6.34 那条链路，本身是对的）。

**与 `tbcc6.atjog.com` 无关**：登录走编译期 issuer（`SpbEndpoints` 没有 issuer
字段，端点升级只改 API/UFS 的 host），出问题的是登录**之后**的每个请求。

#### 修法：取值规则收敛到一处，不再让四个调用点各写一遍

```dart
// packages/spb_api/lib/src/oidc_client.dart
String get bearerToken => idToken ?? accessToken;

// packages/spb_api/lib/src/token_store.dart
factory StoredTokens.fromOidcTokens(OidcTokens tokens, {DateTime Function()? now})
```

四端（桌面 `signInAction` / `refresh`，移动 `onCode` / `refresh`）全部改用它。
**回退到 `accessToken` 只为兼容「服务端没下发 id_token」的响应**（未请求
`openid` scope），那种响应下请求仍会 401，但至少不会构造出空凭证。

刷新路径同样要取 `id_token`：fosite 的 `OpenIDConnectRefreshHandler`
（`handler/openid/flow_refresh_token.go:99`）在 scope 含 `openid` 时会
**一并重发新的 id_token**。

⚠️ `StoredTokens.accessToken` **字段名是历史包袱**，语义已是「Bearer 凭证」。
改名会牵动存储格式与全部测试，故保留字段名并在文档注释里说明。

#### 为什么是客户端改，而不是网关加 introspect

网关加 RFC 7662 introspect 会让**每个请求**多一次远程调用（且要处理缓存、
失效、IdP 不可用时的降级），而 `id_token` 本来就在客户端手里、网关也早已
支持验它。改客户端是一行取值规则。跨仓库的方案已另开 issue 跟踪（见下）。

#### 反向验证（逐条实测）

| 改坏 | 结果 |
|---|---|
| `bearerToken` 改成 `=> accessToken` | `spb_api` 2 条失败（`oidc_client_test` + `session_manager_test`） |
| `fromOidcTokens` 改回 `tokens.accessToken` | 桌面端 1 条 + 移动端 1 条 + `spb_api` 1 条失败 |

#### ⚠️ 修复前测试是绿的（**两处假绿**）

| 既有用例 | 它断言了什么 | 漏了什么 |
|---|---|---|
| `auth_loopback_test.dart` 的 `exchangeCode` 用例 | `r.tokens!.accessToken == 'at-test'` | 断言的是 **`OidcTokens` 的原始字段**，与「落盘成什么」无关 |
| 桌面 `登录页点击 SSO 按钮调用注入的 signInAction` | 动作被调用 **1 次** | 完全不看落盘内容 |
| 移动端 `onCode` | **零覆盖**——它内联在 `authDeepLinkReceiverProvider` 的闭包里，只能从 `main.dart`（不在测试树中）走全链路触达 | 整个落盘逻辑 |

这是 [§6.21](testing.md) / [§6.26](testing.md) / [§6.33](build-and-release.md) / §6.36 同一类：**绿不代表对**。

现补的用例都从**真实入口**出发、断言**落盘结果**：

| 层 | 用例 | 怎么做到可测 |
|---|---|---|
| `spb_api` | `bearerToken` 优先 `id_token` / 无 `id_token` 时回退 | 纯模型 |
| `spb_api` | `fromOidcTokens` 落盘的是 `id_token`、`expires_in` 换算成绝对时刻 | 纯模型 |
| 桌面 | `loopback 登录落盘的 Bearer 是 id_token 而不是 ory_at_ 不透明串` | 新增 `loopbackSignInProvider` 注入点，喂真实形态 token，走**真实** `signInActionProvider` 的落盘代码 |
| 移动 | `深链回调落盘的 Bearer 是 id_token 而不是 ory_at_ 不透明串` | 把内联闭包抽成 `oidcCallbackHandlerProvider`（否则零覆盖） |

两个注入点都是**为可测性而抽**，不是为功能——桌面端若替换整个
`signInAction` 就等于把被测的那一行删掉（那正是既有用例抓不到本缺陷的原因），
故 `pumpApp` 里 `loopbackSignIn` 与 `signInAction` 互斥（同时传抛
`ArgumentError`，不用 `assert`——release 下会被去掉而静默测错对象）。

### 6.39 放置一段时间后被登出、关闭重开又正常：一次断网被当成「凭证失效」

**症状**：应用放一段时间（笔记本合盖 / 切网）后，第一次操作弹「会话已失效，
请重新登录」并跳回登录页。而**关掉重开就一切正常**——凭证一直在安全存储里。

#### 根因：刷新失败的两种含义被合并成了一种

`SessionManager.currentAccessToken()` 曾是这样：

```dart
final refreshed = await refresh();   // 失败（无论为什么）都返回 null
return refreshed?.accessToken;       // → null
```

而 `_doRefresh()` 用 `catch (e) { return null; }` 把**所有**失败折叠成 null：断网、
超时、IdP 503、`invalid_grant` 全长得一样。于是：

```
休眠唤醒 → 刷新因连接层失败返回 null
  → 请求不带 Authorization（匿名）→ 必然 401
  → 拦截器再刷一次 → 又失败 → onUnauthorized 返回 false
  → onSessionExpired → 回登录页
```

`markUnauthenticated` **不清凭证**（§6.34 的有意设计），所以重开应用后
`restore()` 读到完好的 refresh_token、网络栈也是干净的 → 刷新成功。这正是
「重启就好」的来源，也是本缺陷的确认证据。

#### 修法：三态结论 + 「让服务端判定」

`spb_api` 的 `token_store.dart` 新增 `TokenRefreshStatus`（`refreshed` /
`rejected` / `transient`）与 `TokenRefreshOutcome`。判据是**「这个失败是否携带
了关于凭证有效性的信息」**——网络层错误从不携带。

| 结论 | 触发 | 处置 |
|---|---|---|
| `refreshed` | 拿到新凭证并已落盘 | 继续 |
| `rejected` | 无 refresh_token / `invalid_grant` / 4xx | 回登录页 |
| `transient` | `NetworkError` / `ParseError` / 5xx / 未知 | **保留登录态** |

两处协同才修好：

| 位置 | 改动 |
|---|---|
| `SessionManager.currentAccessToken` | `transient` 时返回**旧 token**（而不是 null）。发匿名请求等于替服务端提前判了「已失效」；拿旧 token 再试，让唯一有权限判定的角色回答 |
| `AuthInterceptor.onError` | 拿到 `transient` 时**不调** `onSessionExpired`，也不重放（重放必然失败），把原 401 归一化为 `AuthError` 抛给页面提示「网络异常」 |

#### ⚠️ 必须下探 `AuthError.cause`（最易写错的一处）

`OidcClient._tokenRequest` 对**任何**非 2xx 都抛
`AuthError(message, cause: HttpError(status))`——最外层永远是 `AuthError`，
`statusCode` 字段是 null（它只描述「登录失败」），真正的状态码在 `cause` 里。

只按最外层类型判的话，`AuthError → rejected` 会把「IdP 回了 503」也当成「凭证
被作废」——那是同一缺陷的另一条路径（IdP 重启期间所有用户被登出）。故
`_statusOf` 对 `AuthError` 显式下探 `cause`。

#### 三处接口取向

| 项 | 决定 | 理由 |
|---|---|---|
| 保留 `onUnauthorized`（旧布尔回调） | 保留，`onUnauthorizedOutcome` 优先 | 既有测试与第三方接线不受影响；旧回调无能力表达 transient（`false` 一律当 `rejected`），这本身就是它被替换的原因 |
| `refresh()` 仍返回 `StoredTokens?` | 保留为 `refreshWithOutcome()` 的薄包装 | 6 处既有调用点与测试依赖它；新代码一律用带三态的那个 |
| 未知错误 | `transient` | 把未知错误当「凭证失效」会随机把人登出。保守方向必须偏向「保留登录态」 |

#### 反向验证（逐条实测）

| 改坏 | 失败用例数 |
|---|---|
| `currentAccessToken` 的 transient 分支返回 null（修复前行为） | 1（`暂时性失败时返回**旧** token`） |
| 拦截器去掉 `if (outcome.isTransient)` 守卫 | 2 |
| `AuthError` 一律 `rejected`（不看 `cause`） | 1 |
| `rejected` 时不调 `onSessionExpired`（反方向） | 2 |
| `NetworkError` 分类改成 `rejected` | 2 |

#### 新增用例（`session_manager_test.dart` +21 条）

| group | 钉住 |
|---|---|
| 刷新失败的三态分类 | 9 种错误形态的归类（含 `AuthError(cause: HttpError(5xx))` 这个真实链路形态、`ParseError`、非 `SpbError`） |
| `currentAccessToken` 的取信策略 | transient 返回旧 token / rejected 返回 null / 成功返回新 token / 未过期不刷新 / 临时失败不 clear |
| 拦截器 transient 不登出 | transient → 不调回调、不重放、`calls == 1`；rejected → 调一次；新回调优先于旧回调 |

#### 有意不做

- **不在 `AuthInterceptor` 里自动重试**：transient 之后立刻重试会在真断网时
  变成一个紧凑的失败循环。重试权属于用户操作与 `OutboxQueue`。
- **不做全局「网络恢复后自动重试」**：那需要订阅连通性事件，而 §5.1.1 已明确
  「有默认路由 ≠ 服务端可达」——`connectivity_plus` 给不出可信信号。下一次
  用户操作会自己刷新成功。

### 6.67 邮箱 magic link 登录（issue #81，2026-11）

服务端实现位于 id-provider 仓库 `go/internal/magiclink/`。这里记客户端取向，但把链路写全——否则「为什么客户端要轮询」没有上下文。

#### 为什么加这条路

两条既有入口都有摩擦：

| 入口 | 摩擦 |
|------|------|
| 系统浏览器 SSO | 移动端至少 3 次跳转；桌面端最后一步要靠「粘贴导入会话」 |
| 微信一键 | 要求安装微信，且受开放平台审核与资质约束 |
| **邮箱 magic link** | 只需要一个能收信的邮箱 |

对「没装微信、又嫌 SSO 跳转麻烦」的用户，这是目前唯一成立的路径。

#### 链路

```
客户端                                IdP
  │  POST /api/v1/auth/magic-link      │
  │  {email}                           │  不管邮箱是否存在都 202
  │ ─────────────────────────────────► │  存在 → 发信；不存在 → 静默受理
  │  ◄───────────── {requestId}        │
  │  onSent() → UI 切「已发送，请查收」 │
  │                                    │
  │                        （用户点邮件链接 → IdP 落地页 → 点「确认登录」）
  │                                    │
  │  GET  .../check?request_id=…       │  只回 pending|confirmed|expired
  │ ─────────────────────────────────► │  不带任何凭证
  │  ◄───────────── {status}           │
  │                                    │
  │  POST .../exchange                 │  单次消费
  │  {request_id, client_id,           │  校验 client/redirect_uri/PKCE
  │   redirect_uri, state,             │  → fosite 签发**标准授权码**
  │   code_challenge, …}               │
  │  ◄───────────── {code}             │
  │                                    │
  │  POST /oauth2/token (PKCE)         │  与浏览器登录同一个端点
  │ ─────────────────────────────────► │
  │  ◄──── access/refresh/id_token     │
```

客户端代码：

- `packages/spb_api/lib/src/magic_link.dart` — HTTP 客户端（`MagicLinkClient`）；
- `packages/spb_features/lib/src/auth/magic_link_signin.dart` — 编排（发信 →
  轮询 → 兑换 → 交给落盘点）；
- `packages/spb_features/lib/src/auth/login_page.dart` — 登录页入口
  （`onEmailSignIn`，为 null 时不展示）；
- 落盘点复用各端既有的「code → token → 安全存储 → 已登录」实现
  （移动端 `oidcCallbackHandlerProvider`，桌面端同名 Provider）。

#### 为什么兑换出的是「标准授权码」

服务端不另发一套凭证，而是让 magic link 走 fosite 的授权码流程。好处是
refresh / 吊销 / `id_token` 语义与浏览器登录**完全一致**：客户端只需要一个
落盘点，不需要为登录方式分叉。

代价是必须提供 `client_id` / `redirect_uri` / PKCE，且三者必须与 IdP 注册值
一致——不一致时 IdP 返回 `invalid_request`，客户端翻译成「客户端配置与 IdP
注册不一致」而不是笼统的「登录失败」。

#### 刻意做的几个选择

**GET 落地页不消费令牌，要 POST 确认。**
邮件安全扫描器会预取链接；GET 直接消费会让用户点进去时链接已失效。落地页
因此是一个带「确认登录」按钮的表单。

**轮询端点不带凭证，兑换端点单次消费。**
把发凭证的动作放在高频的公开轮询端点上，等于开一个发 token 的口子。

**响应与邮箱是否存在无关。**
否则这个端点就是账号枚举工具。客户端因此**不能**说「邮件已发送」，只能说
「如果该邮箱已注册，你会收到…」（`login_page.dart` 的文案与测试都钉住了这点）。

**客户端轮询有退避 + 总超时。**
10 分钟窗口内固定 2 秒轮询是 ~300 次请求，退避后降到 ~80。超时必须有：
用户走开后登录页不能永远停在「请在邮件中确认」。

**桌面端不做 redirect。**
确认发生在浏览器里的 IdP 落地页，客户端只轮询结果，所以**不需要**监听
loopback 端口。这也意味着 magic link 在桌面端不依赖「浏览器能把 code 交回
进程」这条脆弱链路（Linux 无主流 webview 插件的历史问题，见
`docs/rfc8252-loopback-signin.md`）。

#### 浏览器半边：登录页的「用邮件登录」（IdP，2026-11）

App 侧 magic link 只帮得到 App；而两端点「使用 SSO 登录」打开的是 IdP 登录页，
在那里仍然只有密码。所以浏览器这半边单独实现了（id-provider `8f9c4b6`）：

```
登录页（底部 aux 链接）→ GET /idp/login/email?redirect_uri=…   输入邮箱
  → POST /api/v1/auth/magic-link/browser  {email, redirect_uri}  发信
  → 邮件链接 → 落地页点「确认登录」
  → 在该浏览器签发 idp_access_token cookie，303 回 redirect_uri
  → /oauth2/authorize 认出会话 → 302 客户端 redirect_uri?code=…
```

三个关键取舍：

- **`returnTo` 存在服务端 entry 里，不进 URL**：确认后跳哪由服务端决定，
  请求参数里没有任何可篡改的目标；写入时白名单校验（只允许站内相对路径，
  挡 `//host`、CRLF、`javascript:`）。
- **确认即建会话**（与 App 流程相反）：浏览器流程要的就是「在这个浏览器登录」，
  否则 303 回授权端点会因为没有会话又被踢回登录页。App 流程仍然不设 cookie，
  登录态只经 requestID + PKCE 兑换回发起的那台设备。
- **两套文案共用一个链接**：落地页按 entry 里有没有 `returnTo` 切换文案
  （「在这个浏览器登录」/「请回到应用」），而不是区分两套令牌。

客户端侧只加了一行提示（登录页 SSO 按钮下方），因为入口在浏览器里，App 内
没有可点的东西——这条路径的实现主体在 IdP。

#### 登录页信息层级（issue #98 / #105，2026-11）

邮箱、登录码和导入会话收纳到默认折叠的「其他登录方式」，展开/收起保留输入与错误。
手机突出微信入口，桌面突出 SSO，另一入口用次级颜色；桌面微信说明明确需要在手机
小程序输入本机码。邮箱、登录码和导入失败显示在对应字段旁，外部认证错误仍在页顶部。
登录行为与认证契约不变；#98 的「打开微信」能力不属于这次改动。

#### 部署前提

1. **邮件渠道可用**：id-provider 的 `internal/mailer` 必须配置好（否则端点
   返回 `service_unavailable`，客户端提示「服务端暂时无法发送登录邮件」）。
2. **client 已注册**：public client（`token_endpoint_auth_method=none`）且
   `redirect_uri` 与客户端一致——移动端 `partyb://oidc/callback`，桌面端
   `http://127.0.0.1/callback`。
3. 服务端可调参数（环境变量）：`MAGIC_LINK_TOKEN_TTL`（默认 10m）、
   `MAGIC_LINK_SEND_INTERVAL`（默认 60s，同邮箱发信间隔）。

#### 已知限制

- **邮件进垃圾箱等于登录失败**：文案里给出了「改用 SSO」的提示，但客户端
  拿不到「信是否被投递」的信息；
- **多端串话**：在手机请求、在电脑点链接，会话会建立在你点开链接的那一端
  （客户端轮询到 `confirmed` 才兑换，故不会建立到错误设备上）；落地页仍显示
  「确认登录」以避免误点；
- **暂不减 `onImportSession`**：issue 原先设想 magic link 落地后删除桌面端的
  粘贴导入。本轮保留它——邮件可达性本身就是这条路径的失败模式（见上一条），
  在没有「邮件不可用时的替代确认」之前，删掉用户唯一的手工兜底并不划算，
  等 magic link 在真机/生产跑过一轮再决定。

### 6.71 生物识别门禁：把「每次都得走微信」降为「第一次走微信」（issue #94，2026-11）

#### 问题

「下次打开还要扫码」是移动端登录最影响体感的一段，但它其实是两件事：

| | 需要什么 | 多久一次 |
|---|---|---|
| **登录** | IdP 认账的凭据（微信 / 邮箱 / 短码 / 密码） | 第一次、换设备 |
| **日常进入** | 证明「这台手机的持有者还是同一个人」 | 每次打开 |

后者根本不需要出现在 SSO 页——refresh token 早就在 Keychain / Keystore 里。
缺的只是一道门禁：在此之前，**任何拿到已解锁手机的人打开 App 就能看到全部
对话**（启动即 `restore()`，无任何本机验证）。

#### 状态机：新增 `AuthStatus.locked`

不能复用「未认证」：未认证的下一步是「去 IdP 换新凭证」，locked 的下一步是
「在本机验一下」——混用会把锁屏页渲染成登录页，用户看到的正是想消除的
「扫码 / 邮箱登录」，还会以为登录态丢了。也不能当成「已认证」：那样内容直接
可见，门禁等于没有。

故 `AuthStatus` 增加第三个终态 `locked`，路由守卫把非 `/lock` 的访问送去
`/lock?from=<原目标>`（`from` 复用登录页那套白名单校验，挡绝对 URL 与
`//host`）。外部深链（`partyb://…`）同样先过 `/lock`——否则从通知点进来就能
绕过门禁。

#### 三条判定，各自有理由

1. **冷启动**：先 `TokenStore.read()`（只读本地，**不发请求**）判断有没有凭证，
   有才上锁。顺序很重要：先 `restore()` 会在 token 过期时触发**网络刷新**，
   等于先替拿到手机的人把凭证换了，再谈上锁。
2. **回前台**：`windowFocusedProvider` 由 false 变 true 时，离开时长超过宽限期
   才重新上锁（默认 30 秒）。只挡冷启动会被「切后台再切回来」绕过；但不设
   宽限期又会让「看一眼通知就回来」也弹 Face ID，用户会直接关掉这个功能。
   判据抽成 `spb_platform` 的纯函数 `shouldLockOnResume`（`enabled` /
   `authenticated` / `backgrounded` / `gracePeriod` 四条，可无头单测）。
3. **开关默认关**：这是需要用户同意的功能，开启意味着每次冷启动都有系统验证框；
   默认打开会让「只想看消息」的用户觉得被拦。改默认值只需改
   `BiometricLockPolicy.enabledByDefault`。

#### 失败分支：不把用户关在门外

`local_auth` 3.x 抛 `LocalAuthException`（14 种错误码），必须归一成五种结果，
因为每种对应**不同**的下一步：

| 结果 | 含义 | 界面 |
|---|---|---|
| `success` | 通过 | 恢复会话 |
| `failed` | 指纹不匹配 | 可重试 |
| `canceled` | 用户 / 系统取消 | 提示「需要验证后继续」，**不报红** |
| `lockedOut` | 平台锁定（连续失败过多） | 只剩「重新登录」 |
| `unavailable` | 没硬件 / 没录入 / 插件缺失 | 只剩「重新登录」，并说明原因 |

`lockedOut` / `unavailable` 时**不自动清凭证**：那会在「指纹传感器临时不可用」
时销毁刚登录的会话，代价远大于让用户自己点一次「重新登录」。所谓「失败次数
上限后强制走完整登录」由界面呈现——隐藏「解锁」、把「重新登录」升为主按钮。

开关开着但设备不可用（删了指纹、换设备、插件缺失）时**放行到已登录**并记日志：
门禁读不到就锁死等于永久锁死用户。

#### 安全边界（必须写清）

`local_auth` 是**应用层自锁**，token 本身没有绑定生物识别 ACL
（`flutter_secure_storage` v9 不暴露 `kSecAccessControlBiometryCurrentSet`）：

- 挡住「捡到已解锁手机的人」：**有效**；
- 挡住「越狱 / root 后读应用沙盒」：**无效**。

硬件级绑定要自建带生物识别 ACL 的 Keychain / Keystore 条目（iOS
`SecAccessControlCreateWithFlags` + `.biometryCurrentSet`，Android
`setUserAuthenticationRequired` + `BiometricPrompt`），属可选后续。
真正的硬件因子是 Passkey（id-provider#12）。

#### 分层与接线

- `spb_platform/src/biometric_gate.dart`：**只有契约**
  （`BiometricGate` / `BiometricAvailability` / `BiometricAuthOutcome` /
  `BiometricLockPolicy` / `shouldLockOnResume`）与「永不通过」的空实现。
  与 `wechat_launcher.dart` 同一取舍：本包不 import 插件，桌面端构建不会被
  拖进移动端依赖。
- `apps/spb_mobile/lib/biometric_gate.dart`：`local_auth` 的桥接，唯一一处
  异常码映射。**漏挂 `buildProductionOverrides()` 那一行**的表现是「设置页
  开关打开后永远提示设备不可用」——门禁静默失效，故默认实现是「永不通过」
  而不是「假装通过」。
- `spb_features/src/auth/lock_page.dart`：锁屏页，回调驱动（`onUnlock` /
  `onUseSignIn`），无插件依赖，可 widget 测试五条分支。
- 平台配置：iOS `NSFaceIDUsageDescription`（缺了 Face ID 直接失败，
  错误只在 Xcode 控制台可见）；Android `MainActivity` 必须继承
  `FlutterFragmentActivity`（`local_auth` 走 androidx `BiometricFragment`，
  用 `FlutterActivity` 会在运行时类转换失败）。`USE_BIOMETRIC` 权限由插件
  manifest 合并进来，不需要手写。

#### 前置依赖

id-provider#5（fosite 会话落到 SQLite）：在此之前 `idp-go` 每次重启都会作废
所有 refresh token，门禁做完也只是把「重登」从每天变成每次部署后。

#### 已知限制

- 本机无法真机验证：`local_auth` 的平台通道、Face ID 权限、Android
  `BiometricPrompt` 都只能真机确认；本轮的防线是「异常码 → 五态」的单测 +
  真实实现只在 `buildProductionOverrides()` 里出现一次；
- 默认关意味着大部分用户不会自己打开（可在设置页「安全」区块开启，副标题
  写明触发时机与宽限期）。


### 6.90 切换账号时失效身份与缓存归属（issue #103）

`currentUserProvider` 曾只依赖长命的 `chatApiProvider`，而
`cachedUserIdProvider` 命中本地值后不再读网络。A 退出、B 登录后，两端仍使用
A 的 userId 拼 `/users/:user_id/chat/*`，离线列表也可能取到 A 的数据。

两端装配用独立的 `sessionRevisionProvider` 使每次确认凭证后重新查询
`/api/auth/me`，同为 authenticated 的凭证替换也生效。登出与会话失效停止返回
旧身份；未登录错误不自动重试，派生 userId 的重试交给上游身份请求。

新增数据层 `SessionIdentityCache` 管理 `auth.cached_user_id`：

- 新凭证落盘前等待清理完成；清理失败就拒绝替换凭证，避免重启后新凭证配旧归属。
- 清理立即禁止旧归属读写，保存与清理串行，响应携带会话代际，挡住迟到响应及
  已经开始的旧写入。新会话经 `/me` 确认后再恢复本地归属。
- 同一会话冷启动保留归属，身份请求在途或离线时无需等待网络即可读缓存；
  联网成功后更新归属。AsyncValue 刷新期间保留的旧 data 不作为新身份使用。
- 登出时即使缓存清理失败，也继续清除凭证；旧账号的列表数据仍按 userId 隔离，
  不删除未发送消息或同步状态。

回归覆盖两端 A→B、失效后重登、新账号离线、旧请求晚到、同会话离线恢复，
以及清理失败时禁止换凭证但允许登出；数据层覆盖旧代际拒写与在途写入/清理顺序。
