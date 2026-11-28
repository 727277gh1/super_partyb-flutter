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

**与 `dever6.atjog.com` 无关**：登录走编译期 issuer（`SpbEndpoints` 没有 issuer
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

API/SSE 与 IdP 后台请求禁止 HTTP redirect，不能让其他 origin 的响应代替认证服务返回结果。小程序轮询的 `X-Poll-Secret` 不受 Dart 对标准 Authorization 的跳转清理保护，必须在请求层关闭跳转；自定义 Dio 也遵守相同限制，且不修改其共享配置。普通 API 保留 304 缓存命中，IdP 仅解析 2xx 登录结果；系统浏览器的交互式授权跳转不受影响。真实 HTTP 回归见 `credential_redirect_test.dart`。

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

### 6.91 五条快捷登录的安全复核：反向码回显、移动端撤掉粘贴导入、回调优先 claimed HTTPS（2026-11）

对移动端（`apps/spb_mobile`）当时可用的六条入口做了一次逐条复核，结论是
「服务端的码/密钥生成与限流没问题，问题在**会话交接的信任假设**与**文档承诺
与实现不一致**」。四处改动：

**1. 反向登录码：兑换前必须回显「将登录为 <账号>」。**

反向码（小程序出码 → 目标设备输码）与正向短码的安全性质不同：正向码是授权
句柄（必须账号主人在微信里确认），反向码是**持有即授权的凭据**。于是有一条
社工链——攻击者出码发给受害者（「输入这个码把数据搬过去」），受害者输码后
**自己的 App 登进了攻击者的账号**，之后写的笔记、上传的文件、对话全归攻击者，
而受害者毫无察觉。出码侧的「刚才被谁登录」回显只保护出码人，救不了受害者。

服务端加 `POST {idp}/api/v1/bindings/mini-program/handoff/preview`（只读、不
消费码、独立限流 20 次/10 分钟 + 全局 400），回 `account.name` 与剩余秒数。
客户端在兑换（不可逆、码单次消费）之前弹确认框；用户取消则码不被消费。
`LoginPage.onHandoffPreview` 为 null 时保持旧行为（旧 IdP 没有该端点也能登录）。

**2. 移动端撤掉「粘贴导入会话」。**

这条路径是把浏览器 `id_token`（长期 JWT）手抄进 App，当初是桌面端补丁
（Linux 读不到浏览器 Cookie）。移动端有深链回调，它的存在只增加两类风险：
剪贴板（Android 前台 App 可静默读）、钓鱼（照「客服」指示粘一个 token 就是
登进攻击者账号）。移动端另有微信一键/短码、邮箱、反向码、深链四条路径。
`AuthStateNotifier.importSession` 保留（桌面端与测试用它播种会话）。

**3. 移动端 OIDC 回调优先 claimed HTTPS。**

自定义 scheme 没有归属校验，任何装了 `partyb` scheme 的 App 都能抢走回调。
当前 PKCE（public client，verifier 在 Keystore，IdP 强制
`EnforcePKCEForPublicClients`）保证「抢到 code 也换不到 token」，所以影响是
登录 DoS 而非接管——但这层保障完全依赖「PKCE 不被关掉」。新增
`OidcCallbackUri.preferredRedirectUri()`：issuer 是 https 时用
`<issuer>/app/callback`，否则退回 `partyb://oidc/callback`（本地
`http://127.0.0.1:3000/idp` 下 claimed HTTPS 不是可注册形态）。
两个环境的移动端 client 都已注册两种形态，`api-gateway` 的
`/.well-known/assetlinks.json` 补上 dever 域名。判错方向的代价是多一次点击
（IdP 落地页有「打开 App」按钮），不是登不进去。

**4. 文档与实现对齐：删掉「反向码错 5 次作废」。**

`handoff.go` 文件头曾把「同一个码错 5 次即作废」列为防护项，`countHandoffWrongAttempt`
也写了——但它在生产代码里**从未被调用**（只有测试调用它），兑换路径没有任何
attempts 分支，`ErrHandoffTooManyAttempts` 是不可达分支。真相是：兑换只校验码
本身，码不存在时无从归属计数器，那种计数只能挡「盯住一个已知码穷举」，而那种
攻击本来没有意义。盲猜的防线是 8 位长度 + 限流。已删除死代码与失真注释，并把
「本文件没有做的防护」写进文件头，避免下一次复核再被误导。

回归覆盖：服务层（预览不消费、预览后仍可兑换、过期/未知码语义）、HTTP 层
（回显账号名、重复预览、已兑换 404）、客户端（`previewHandoffCode` 成功/错误
映射）、登录页（确认框先于兑换、取消不消费、预览失败不弹框、未注入时旧行为）、
移动端路由（不渲染粘贴导入入口）。

### 6.97 Passkeys 是 IdP + 浏览器侧能力，客户端零改动（issue #82 收口，2026-11）

**结论**：WebAuthn 的 ceremony 只能跑在**浏览器上下文**（或系统 passkey provider）里，
本仓（Flutter 客户端）在推荐档位下**没有代码要做**。`spbf#82` 因此并入实现单
[`id-provider#12`](https://<gitea-host>/dever/id-provider/issues/12) 并关闭。

判据不是"谁方便"，而是绑定机制：**assertion 的签名绑在 RP ID 上，而 RP ID 由浏览器
按页面 origin 计算**（`https://dever.atjog.com` → `rpId=dever.atjog.com`）。客户端自己
算不出这个绑定，只能靠关联域文件让操作系统代验——因此一旦按 §6.91 的「登录一律走
外部用户代理」执行，ceremony 天然落在 IdP 登录页上。

客户端真正要付的只有**已经付过的那一项**：能打开系统浏览器、并接回 claimed HTTPS
回调（`#77` 已交付：`assetlinks.json` 为 `handle_all_urls`、`api-gateway#12` 补了
`/.well-known` 路由）。

| 档位 | 谁实现 | 对本仓意味着什么 |
|---|---|---|
| ② `ASWebAuthenticationSession` / Custom Tabs 打开 IdP 登录页（**默认选它**） | IdP（登录页 + 表 + 两个 ceremony 端点） | 零改动 |
| ① 原生（`ASAuthorization` / Credential Manager 取 assertion） | 客户端 + IdP | 需 AASA `webcredentials` / assetlinks `get_login_creds` 关联域已验证；iOS 侧卡 [`spbf#111`](https://<gitea-host>/dever/super_partyb-flutter/issues/111)（Apple 付费账号）→ **现阶段不选** |
| ③ 内嵌 WebView | — | 禁止（§6.91） |

**RP ID / origin 修正**：实现单里写的 `app.example.com` + 双栈 `tbcc6` 已过期——生产目标
域名是 `dever.atjog.com`（`*6` 域名全线不可用，见仓库根 `AGENTS.md`），origin 只注册
`dever.atjog.com` 一个。WebAuthn 要求安全上下文，`http://localhost` 是唯一例外
（RP ID 只能是 `localhost`，**不能**用 IP 或内网域名替代）。

**与 #94 的边界**：`#94` 的本地生物识别门禁是**客户端**能力（给已有会话解锁，§6.71），
与 passkey 无关；`id-provider#12` 也明确写了不要拿 passkey 去"给已有 token 加锁"。

**验收可做性**：验收项「桌面 + 移动各注册一枚」是人工真机项，此前卡在无真机；2026-11-13
起 Windows 与 Android 真机均可用（`spbf#4` 因此关闭），该条不再阻塞。

### 6.98 微信开放平台 App 授权登录：不做，小程序短码已覆盖（issue #83 收口，2026-11）

**结论**：不做微信开放平台 App 授权登录（OpenSDK / `wechat_open` provider）。目标本身
（"App 里零输入地走微信身份"）已由**三条零资质路径**交付，B 方案（开放平台）买来的
只剩"少一次切 App"，代价是资质 + 审核 + 两套 provider + App Store 4.8 连带。

已交付的零资质路径（都在本仓有对应实现）：

| 路径 | 确认者 | 服务端 | 客户端 |
|---|---|---|---|
| 小程序会话换码（`#80`） | 微信 openid | `id-provider#10`（`internal/miniprogramqrcode` 的 `MiniProgramLogin`） | `spb_api/lib/src/miniprogram_login.dart` |
| **短码确认**（复用同一 scene 机制） | 微信 openid | `id-provider#18`（`CreateShortCodeSession` / `...Opts`） | `spb_features/lib/src/auth/login_page.dart` 的短码回退（倒计时、失效、流程结束清屏）+ `super_partyb#103` 的「输入登录码」页 |
| 浏览器出码 → 已登录 App 确认（§6.91） | 本家 IdP 会话 | `internal/qrlogin` | `spb_api/lib/src/qr_login.dart` + `qr_login_page.dart` |

即：**"复用小程序短码"不是 B 的临时替代，而是 B 的目标达成方式**。短码路径不依赖任何
资质（无 300 元/年认证、无包名/签名 MD5 登记、无 Universal Links 前置（后者卡 `#111`））。

**成本对照（B 方案为何不划算）**：

- 开放平台开发者资质认证 **300 元/年**（每次申请都收费，与是否通过无关）；
- 在线申请 + 缴费后 **15 个工作日**展开认证，通过后还要在「接口信息」里单独申请「微信登录」权限；
- 移动应用登记要包名 + 签名 MD5（Android）与 Bundle ID + Universal Links（iOS）；
- 服务端要新增 `wechat_open` provider 并做 **unionid 合并**（`id-provider#13`）——否则同一个人在小程序与 App 会是两个 IdP 账号；现有扫码路径还会自动建号，等于放大开放注册面。

**连带项也消失**：短码路径的账号仍由本家 IdP 建立（密码 / 邮箱 magic link / 短码 /
passkey），没有"第三方/社交登录建立主账号"，所以 **App Store 4.8 不触发**，
`#84`（Sign in with Apple）不需要。

**现状的 unionid 合并不必做**：只有小程序一条微信身份，不存在"同一人两个微信身份"的
数据问题；`wechat_open` 上线才需要它。

**重新评估触发条件**（与 `#85` 第 7 条同源）：

1. 小程序侧方案因体验或资质被否决（例如小程序主体认证失效、短码转化被证明不可用）；
2. 需要面向微信生态外的自然流量做拉新（对外投放、非内部用户）。

⚠️ 触发条件一出现，必须**与 `#84`（Sign in with Apple）同一批**上线——4.8 是硬约束，
不能分批。

#### 与「暂不做清单」的关系（2026-11-13 复核）

`#85` 曾把「独立生物识别解锁（`local_auth` 门禁）」列为**不做**，理由是「secure
storage 已被系统保护、再叠一层只增摩擦，真正的价值形态是 Passkeys」。`#94` 落地后
这条与本 §6.71 直接矛盾——已处理的写法是：清单里就地改成「**已做**（`#94`）」并保留
原结论，另把**仍然不做**的那一档写清：

- 仍然不做：**硬件级绑定**（token 与生物识别 ACL 绑定），即「越狱 / root 后读沙盒
  也挡得住」那一层；
- 不在本条：Passkeys（把生物识别变成 **IdP 认证因子**）归 `id-provider#12`；
- 两者都别和本门禁混用：本门禁是**应用层自锁**，安全边界见上文「安全边界」段。

同一条纪律适用于任何清单：**被实现的条目要就地改状态，不要留在"不做"里**。

### 6.100 登录页收纳与「打开微信」按钮（issue #98，2026-11）

#### 1. `weixin://` 只拉到「微信宿主」，不深链进小程序

短码这条动线里，用户必须自己完成的一步是**切到微信**（Android 还要先退出本
App）。加一个「打开微信」按钮只解决这一步：

- 用的是**裸 `weixin://`**，不是加密 URL Scheme / URL Link / `WXLaunchMiniProgram`
  ——后三者都受小程序主体资质约束（个人主体 `85407`），那是 `idp#17`；
- 按钮文案下的说明写死「只把微信带到前台；进小程序与输码仍由你完成」，避免
  用户以为点一下就直接登录；
- **未安装微信时按钮不渲染**（`canOpenWeChatHost` 走 `canLaunchUrl` 语义）：
  死链按钮比缺按钮更费用户；唤起失败（返回 false）时错误条写清「手动切到微信
  并搜索『成蹊』输入上面的码」，不静默；
- 平台前置**已满足**：Android 的 `<queries><package android:name="com.tencent.mm"/>`
  随 `#92`（OpenSDK）落地，iOS 的 `LSApplicationQueriesSchemes` 里 `weixin`
  是 fluwx 时代就有的——本次**没有改任何 manifest/plist**；
- 桌面端**不接**：这条短码的下一跳是「手机上的微信小程序」，桌面版微信里没有
  它，把用户从登录窗口扔进另一个桌面窗口还会丢掉本机显示的码。

能力由装配层注入（`LoginPage.openWeChatHost` / `canOpenWeChatHost`，移动端
`router.dart` 用 `url_launcher` 实现）；`spb_features` 不 import 任何插件。

#### 2. 短码进行中，其余入口全部收起

`login_page.dart` 的顺序感此前是「5 个区块纵向堆叠，320dp 高的小窗首屏只看到码
卡」。现在的规则：

| 状态 | 页面 |
|---|---|
| **有短码进行中** | 只有码卡（+「打开微信」+ 详细动线文案）+ 一条退路按钮 |
| 无进行中流程 | 微信一键 / SSO 展开；邮箱、登录码、导入会话收进一个 `ExpansionTile`（`maintainState: true`，收起不丢已填内容） |

**为什么必须留一条退路**（`login-short-code-switch` → `_clearShortCode`）：码过期
后卡片会停在「已过期，请重新发起」，此时公众号/小程序不可用、或不想等的用户若
没有退路，就被锁在同一页直到重开 App。文案写明「改用其他登录方式（这段登录码
作废）」——诚实的地方在于：**UI 还原不等于取消轮询**，`miniProgramSignIn` 的
Future 在 app 层持有、这里取消不了，码本身仍由服务端 TTL 吃掉；若那之后用户在
微信里确认，登录仍可能完成（同一个账号，不会有串号风险）。

#### 3. 文案跟着状态走

「去哪找小程序」的详细动线（`打开微信 → 搜索或「发现 → 小程序」进入「成蹊」→
「我的 → 输入登录码」`）从微信按钮下方**搬进了码卡内部**：短码进行中其余入口
收起，这段文案挂在被收起的按钮下面等于没人看得到。

#### 验证

`packages/spb_features/test/auth/login_page_test.dart`：

- 短码卡组 +5：装了微信出现按钮且点击调用一次 / `canLaunch=false` 不渲染 /
  未注入不渲染（桌面端）/ 唤起失败写错误条且带小程序名 / 码过期后按钮消失；
- 收纳组 +1：短码进行中 SSO、其他登录方式、微信按钮都收起，点退路按钮后恢复；
- 既有「编排层回调短码」用例仍断言卡片里能读到「输入登录码」与小程序名。

`spb_features` 1614 项、桌面端 266 项、移动端 191 项、`dart analyze .` 全绿。

### 6.103 账号安全入口跳浏览器：客户端不做 passkey 注册（id-provider#12 客户端侧，2026-11）

**结论**：设置页「账号」区新增「账号安全（Passkey）」入口，点击**用系统浏览器**
打开 IdP 的 `/dashboard/security`；**客户端不实现** WebAuthn ceremony，也不请求
passkey 管理 API。

#### 1. 为什么是浏览器

passkey 的信任根是 **RP 域名**（生产 `dever.atjog.com`）。浏览器里 `origin` 天然
就是它，`navigator.credentials` 一次调用就能完成注册/断言。App 内直连平台原生
API（Android Credential Manager / iOS `ASAuthorizationPlatformPublicKeyCredentialProvider`）
则额外要求：

| 前提 | Android | iOS |
|---|---|---|
| 域名归属证明 | `https://dever.atjog.com/.well-known/assetlinks.json`，含**签名证书 SHA-256** | `apple-app-site-association` + associated domains entitlement + **Apple 团队 ID** |
| 客户端 data 的 origin | 变成 `android:apk-key-hash:<证书哈希>`（opaque origin），服务端必须显式放行 | 仍是 `https://dever.atjog.com`（无需改动） |
| 其他 | 签名 key 轮换要同步 DAL 与服务端白名单 | 无 Apple 账号 → 连 entitlement 都签不出来（§8：iOS 未出包） |

也就是说：原生路径的成本不在客户端代码，而在**域名归属 + 服务端 origin 白名单 +
签名证书三方同步**，且 iOS 侧当前完全阻塞。在这些前提齐备前，硬做一个入口只会
得到「点了没反应」。

> 实测（2026-11）：`https://dever.atjog.com/.well-known/assetlinks.json` **已经存在**
> ——那是 Android App Links（`handle_all_urls`，同一份签名证书指纹）留下的。
> 所以 Android 侧真正缺的只有两件事：① 该文件补一条
> `delegate_permission/common.get_web_credentials` 关系；② IdP 的 origin 白名单
> 放行 `android:apk-key-hash:k0lD6oiYUOruZg_3KG7lUZdh5R6uCjNkKq2KwLpWeWQ`
> （由现有指纹的 32 字节直接 base64url 得来，不需要新证书）。
> iOS 侧 `apple-app-site-association` 仍是 404，且无 Apple 账号签不出
> associated domains，故原生路径在 iOS 上**从零开始**。

前置清单与分期见 [id-provider#40](https://<gitea-host>/dever/id-provider/issues/40)（`priority/p3`、不排期）。

#### 2. 分工：页面只收集意图

`SettingsPage.onOpenAccountSecurity` 是 `Future<bool> Function()?`——页面不拼 URL、
不碰平台能力（与 `onOpenMyTurns` 同一分工）。URL 由
`SpbEnv.accountSecurityUrlFrom(issuer)`（`spb_core`，纯 Dart 可单测）拼出，两端
装配层负责真正的跳转：

| 端 | 实现 | 为什么 |
|---|---|---|
| 桌面 | `openAccountSecurityPage`（`auth_browser.dart`）→ `openInBrowser` | 与 OIDC 登录、Markdown 链接共用 `spawnSystemOpen` 三平台分派，不引 `url_launcher` |
| 移动 | `_openAccountSecurityPage`（`router.dart`）→ `launchUrl(externalApplication)` | 移动端本就用 `url_launcher`；**必须**是外部浏览器，WebView 里没有平台认证器 |

失败一律给可见提示（「无法打开浏览器，请在浏览器中手动访问账号安全页」）：这个
入口的唯一动作就是「跳出去」，静默失败等于用户以为按钮坏了。

#### 3. 验证

- `packages/spb_core/test/account_security_url_test.dart`：basePath 保留、结尾斜杠
  吃掉（不拼出 `//dashboard`）、端口、空 issuer → null、相对地址 → null；
- `packages/spb_features/test/settings/settings_page_test.dart`：未注入不渲染 /
  注入后展示且文案写明「在浏览器中」/ 点击触发一次 / 返回 false 与抛异常都提示；
- `dart analyze .`、全部 `tools/check_*.sh`、`spb_features` 1619 项、桌面端 266 项、
  移动端 193 项、四个纯 Dart 包全绿。

### 6.104 App 内相机扫码：「扫一扫」只扫别人的码（2026-11）

**结论**：移动端登录页新增「扫一扫」入口（`login-scan-button`），相机扫到
`{issuer}/qr/<scene>`（或 `partyb://qrlogin?scene=`）后**与深链完全同路**：投进
`qrLoginSceneProvider`，由 `app.dart` 统一跳 `/qr-login` 确认页。桌面端不注入
（`NoopQrScanner.isSupported == false` → 入口不渲染）。

#### 1. 为什么相机是 `spb_platform` 的契约，而不是登录页里的插件调用

`mobile_scanner` 只有 Android/iOS/macOS 实现，而登录页在 `spb_features` 里、
两端共用。直接 import 插件会重演 §6.4 的老问题（分层被破坏后编译仍通过，
「纯 Dart 可无头单测」的能力静默丢失）。故：

| 层 | 放什么 |
|---|---|
| `spb_platform` | `QrScanner`（`isSupported` / `problem` / `scan(context)`）+ `NoopQrScanner`，**零插件** |
| `apps/spb_mobile` | `createQrScanner()` + `MobileQrScanner` + `QrScannerPage`（整屏相机页） |
| `apps/spb_desktop` | 不注入，默认 null（入口不出现） |
| `spb_features` | 只调回调：`onScanQr()` 拿文本 → `QrLoginUri.parseScannedText` 判语义 → `onQrScanned(scene)` 交给路由 |

`scan()` 收 `BuildContext`：相机预览必须是整屏页面，而「打开页面」只能由持有
调用点上下文的调用方发起——实现里自己找 Navigator 就得引入全局 `navigatorKey`
（本仓库没有，也不为这一处引）。

#### 2. 为什么「解释」放在登录页，而不是相机实现里

相机只产文本，不知道什么是登录码（那是认证域知识，住在 `spb_api`）。把它留在
页面侧的好处是：**相机实现只依赖插件**，而这段判断能用假回调在无插件的 widget
test 里完整驱动（`login_page_test.dart` 的「扫一扫」组：命中 / 自定义 scheme /
取消 / 扫到别的码 / 抛异常 / 加载态各一条）。

`parseScannedText` 用 `Uri.tryParse` 而不是 `Uri.parse`：相机扫出的东西不受控
（付款码、别人的小程序码、随手贴的文字），`parse` 遇到非法端口会抛
`FormatException`，那条异常冒到登录页会把「扫错了码」显示成「程序出错」。

#### 3. 权限与平台

- Android：`CAMERA` + `uses-feature android.hardware.camera required=false`。
  插件自身的 manifest 已贡献同样的两行，App 的 manifest 显式再写一遍是**为了
  `required=false` 与可见性**：没有相机的设备仍要能装（微信一键/登录码是替代
  路径），而 release 包「点了没反应」时排查第一眼看的就是这个文件。
- iOS：`NSCameraUsageDescription` 必须自己加——缺它相机**起不来**且没有系统
  弹窗；用户拒绝一次后只能去系统设置里放开（`mobile_scanner` 不会二次弹）。
- Android 侧解码用 bundled ML Kit 模型（APK 因此变大）；改成
  `dev.steenbakker.mobile_scanner.useUnbundled=true` 可依赖 Play Services 动态
 下载模型，代价是没 Play Services 的设备扫不了。

#### 4. 为什么扫的是「别人的码」

同机场景用户扫不了自己的屏幕（那是「微信一键」的职责）。「扫一扫」的正当用途
是**跨设备**：PC 浏览器上 `/idp/login` 的「App 扫码」tab 出码（
`POST {issuer}/api/v1/qr-login/sessions` → `openUrl` / `deepLink` / `qrImage`），
手机扫 → 手机（已登录）确认 → 浏览器轮询拿到 cookie。

> ⚠️ 若改用**系统相机**扫同一个码，链路先经 App Links：`https://<host>/idp/qr/<scene>`
> 要求 `/.well-known/assetlinks.json` 里的签名指纹与**实际安装的那份 APK**一致。
> 生产该文件里是 2026-10-20 release APK 的指纹（`93:49:43:…`），而 CI 与本地出的是
> 仓库 `debug.keystore` 签名（`10:89:AC:…`）——不匹配时落地页会先打开浏览器，
> 再靠 `partyb://qrlogin?scene=` 兜一跳。**App 内扫码不走 App Links**，因此不受
> 该指纹约束。

#### 5. 已登录用户从哪里扫：同一个能力，两个入口

「手机已登好、要把另一台设备也登进去」是**已登录**状态下的需求，而登录页只在
**未登录**时出现——只把入口放在登录页，这个场景永远进不去（用户会把「找不到
扫一扫」理解成「这 App 不支持」）。故两个入口共用同一份相机能力与同一份解释：

| 入口 | 何时可见 | 扫到码之后 |
|---|---|---|
| 登录页「其他登录方式 → 扫一扫登录」（`login-scan-button`） | 未登录 | `onQrScanned` → 深链同一落点 `/qr-login?scene=` |
| 设置页「账号 → 扫一扫登录其他设备」（`settings-scan-qr-login`） | 已登录 | `context.push('/qr-login?scene=…')`：一次性插入，确认后 `maybePop()` 回设置页 |

两处都调 `scanQrLoginCode`（`spb_features/lib/src/auth/qr_scan.dart`）：相机只产
原始文本，解释成 scene、判定「是不是本应用的码」只做一次，文案也只有一份
（`qrScanOutcomeMessage`）——否则会演变成「设置页能扫、登录页说不是登录码」。

**登录页那条是「先登录、再自动回确认页」**，不是死路：未登录时把
`/qr-login?scene=…` 交给守卫，守卫改写成 `/login?from=<确认页>`，登录成功后再
回跳。两个坑都是靠这条链路才能走通，因此写在这里：

1. **`from` 必须带 query**。守卫原先用 `matchedLocation`（path-only）拼 `from`，
   于是 `scene` 在登录往返中丢失 → 落到 `/qr-login`（空 scene）→ 确认页报
   「扫码登录链接不完整」，而浏览器那边一直等到二维码过期。现在两端守卫都取
   完整 location（`targetLocation` 参数，`_targetLocation(Uri)`），顺带修好了
   `/settings?tab=sync` 这类带查询参数页面的回跳；
2. **扫完必须有可见反馈**（`login-scan-hint`，文案「已读到登录码，登录后会自动
   回到确认页」）。守卫把地址改写成登录页时页面看起来没变，用户会以为扫失败
   又去扫一次——这一点在真机上尤其明显（相机页已经关掉了，屏幕上什么都没动）。

回归测试：`apps/spb_mobile/test/router_qr_scan_test.dart`（真实登录页 + mini
router：停在登录页 / 提示可见 / `from` 含 scene / 登录后到达确认页），
两端 `router_redirect_test.dart` 的「from 必须带上 query」组。

设置页的回调形态与 `onOpenAccountSecurity` 一致（`Future<String?> Function()?`
+ `void Function(String)?`，不注入即不渲染），因此**桌面端不出现这一行**：
`mobile_scanner` 在 Linux 没有实现，桌面端自己的登录走浏览器 loopback，
不需要（也没有）「扫另一台设备的码」这条路。

#### 6. 「其他端」到底能登成什么

扫码只解决**浏览器侧**的登录态（`idp_access_token` cookie，`Path=/`）。这条
cookie 是 IdP 的会话凭证，`/oauth2/authorize` 认它（
`id-provider/go/internal/oidc/provider.go` 的 `authenticatedUserID`：
Bearer > cookie > 拒绝 `X-User-ID`）。因此「其他端」的实际覆盖是：

| 其他端 | 扫码之后发生什么 |
|---|---|
| 浏览器（webapp `/pbw/*`、IdP 后台 `/idp/dashboard`） | 轮询命中 `confirmed` → 种 cookie → 页面跳回 `redirect_uri`；AGW 保护的路由再走一遍 OIDC 时**免密**（AGW 自己那套 `access_token`/`id_token` cookie 由 `/auth/oidc/callback` 下发） |
| 桌面端 App（SPBF，RFC 8252 loopback） | 浏览器里的 `authorize` 请求带上刚种下的 cookie → 直接发授权码 → 回环拿到 code → 桌面端登录。**无需密码**，这是扫码真正省下的那一步 |
| 移动端 App（另一台手机） | 扫码那一侧就是 App 自己；另一台手机装的是同一个 App，同样走登录页 / 设置页入口 |

要注意的边界：

- **扫码不会把身份给 App**：App 只做「确认」，token 始终在浏览器与 IdP 之间
  流转（见 `spb_api` 的 `QrLoginClient` 文档）；
- **App 必须已登录才能确认**（`requireUser` 只认 Bearer / cookie / 可信网关
  头）。所以「先扫码再登录」是不可用的顺序：设置页入口只在有会话时可用，
  登录页入口扫完会进确认页，而确认页在无会话时只会得到 401 提示；
- **身份换不掉**：确认用的是当前账号，用户若想「用 A 账号登 B 浏览器」必须先
  在本机切换账号。
