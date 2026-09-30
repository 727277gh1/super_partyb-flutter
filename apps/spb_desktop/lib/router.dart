import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_platform/spb_platform.dart';

import 'providers.dart';

/// 路由路径常量。
///
/// WHY 集中定义：`context.go(...)` 与路由表两处必须一致，散落的字符串字面量
/// 一旦有一处拼错，编译器不会报错、运行时才表现为「点了没反应」。
class SpbRoutes {
  const SpbRoutes._();

  static const home = '/';
  static const settings = '/settings';
  static const quickCapture = '/quick-capture';

  /// 全局悬浮输入窗（带附件）。
  ///
  /// 与 [quickCapture] 并存而不是取代它：两者走不同端点，返回语义不同
  /// （见 `OverlayQuickCapturePage` 的类文档）。保留旧路由是为了不破坏
  /// 已有的调试入口与移动端行为。
  static const overlay = '/overlay';

  /// 交付物同步页。
  ///
  /// 桌面端相对 webapp 的**核心差异价值**：把交付物真文件拉到磁盘上，
  /// 可用系统程序打开、可离线查看。
  static const sync = '/settings/sync';

  /// 登录页。
  ///
  /// ## 为什么用常量而不是内联字符串
  ///
  /// 路由守卫（`redirect`）与路由表必须用**同一个**字面量，否则守卫会把
  /// 用户重定向到一个不存在的路径，go_router 会抛「no routes for location」。
  static const login = '/login';

  /// 对话时间线路径。
  static String chat(String groupId) => '/chat/$groupId';

  static const chatPattern = '/chat/:groupId';

  /// 搜索页（搜消息正文，不是对话标题）。
  static const search = '/search';

  /// 跨 group 待确认收件箱。
}

/// 桌面端路由表。
///
/// ## 布局形态：不用 StatefulShellRoute
///
/// 桌面端是「列表 + 内容」两栏布局，侧边栏只是**布局**而非独立导航栈。
/// 引入 `StatefulShellRoute` 反而让「点列表项切换对话」多一层 navigator，
/// 且需要处理分支间状态同步。见 `docs/flutter-component-research.md` §1.2
/// 的采纳结论。
///
/// ## 对话页为什么走 path 参数而不是 query
///
/// `/chat/:groupId` 让 URL 可分享、可深链，也让「返回上一个对话」有历史语义。
GoRouter createDesktopRouter({Listenable? refreshListenable}) {
  return GoRouter(
    initialLocation: SpbRoutes.home,
    routes: buildDesktopRoutes(),
    redirect: buildAuthRedirect(),
    refreshListenable: refreshListenable,
  );
}

/// 未认证重定向守卫。
///
/// ## 为什么用 `redirect` 而不是在每个页面里判断
///
/// 把守卫放在路由层，意味着「未认证」这件事**只有一个判定点**。若散在各页面
/// 里判断，新增页面时总会漏掉一处，表现为「未登录也能进某个页面，然后在里面
/// 报一堆 401」。
///
/// ## 为什么要跳过 [AuthStatus.unknown]
///
/// 读取凭证是异步的（安全存储要走平台通道）。启动瞬间状态是 [AuthStatus.unknown]：
/// 此时若重定向到登录页，已登录用户会看到登录页闪一下；若放行，未登录用户
/// 会先看到主界面再被踢走。故 unknown 时**不重定向**，由 `refreshListenable`
/// 在判定完成后再次触发本守卫。
///
/// [authState] 为 null 表示**未接入认证**（如未 override provider 的旧测试）：
/// 此时一律放行，避免把「还没接认证」变成「所有人都进不去」。
GoRouterRedirect buildAuthRedirect({AuthState Function()? authState}) {
  return (context, state) {
    final auth = authState?.call() ?? _authStateFromContext(context);
    if (auth == null || auth.status == AuthStatus.unknown) return null;

    return resolveAuthRedirect(
      authenticated: auth.isAuthenticated,
      matchedLocation: state.matchedLocation,
      fromRaw: state.uri.queryParameters['from'],
      loginRoute: SpbRoutes.login,
      fallbackRoute: SpbRoutes.home,
    );
  };
}

/// 认证守卫的**纯决策函数**（不碰 `BuildContext` / Riverpod）。
///
/// ## 为什么把决策抽出来单测，而不是只测路由的最终落点
///
/// 守卫本体要 `BuildContext` 与 Riverpod 容器，只能通过 widget 测试观察
/// 「最终停在哪个路由」。但 go_router 对**匹配不到任何路由**的跳转目标会
/// **静默回落**——于是「白名单校验失效，把 `https://evil.com` 放了过去」与
/// 「校验生效，回落到首页」在 widget 测试里表现得**完全一样**（实测：删掉
/// 校验后集成测试仍然全绿）。安全边界必须能被精确断言，故抽成本函数。
///
/// 返回值语义与 go_router 的 `redirect` 一致：`null` = 放行（不做重定向）。
///
/// ## 为什么回跳必须在守卫里做，而不是在登录页里 `context.go`
///
/// 登录成功那一刻 `authState` 变为 authenticated，`refreshListenable`
/// 会重跑本守卫。若这里无条件返回首页，用户会在登录页 builder 有机会执行
/// 之前就被送走——`from` 永远没机会生效（这正是修复前的状态：参数被写入
/// 却无人读取）。
///
/// 反过来把回跳放在登录页的按钮回调里同样是错的：那会与守卫竞争（两个
/// 重定向源抢同一次导航），且「已认证用户带着 `from` 直接打开 /login」
/// （刷新页面、旧书签）这条路径拿不到回跳。守卫是唯一的判定点。
///
/// ## `from` 的校验是安全边界，不是可选健壮性
///
/// `from` 来自 URL query，是**完全由用户控制的输入**。若直接拿去跳转，
/// 应用就成了开放重定向（open redirect）跳板：
///
/// - `from=https://evil.com` —— 绝对 URL，登录后直接落到钓鱼站；
/// - `from=//evil.com` —— **协议相对 URL**（RFC 3986 §4.2），解析结果同样是
///   `https://evil.com`。只判「以 `/` 开头」会把它放过去，所以必须单独挡。
///
/// 攻击面在于「用户被诱导点一个看起来是本站的链接」，登录完成后地址栏是
/// 真的外站，而用户刚在真正的本站输入过凭证——这正是钓鱼需要的信任转移。
///
/// 另外拒绝 `from == loginRoute`：那会让「已认证访问 /login」这条分支把用户
/// 重定向回 /login，go_router 检测到重定向环会抛异常；「回跳到登录页」本身
/// 也没有语义。
///
/// 非法值一律回落到 [fallbackRoute]，**静默丢弃而不是报错**：用户只是想
/// 登录，不该因为一个被篡改的参数而看到错误页。
String? resolveAuthRedirect({
  required bool authenticated,
  required String matchedLocation,
  required String? fromRaw,
  required String loginRoute,
  required String fallbackRoute,
}) {
  final goingToLogin = matchedLocation == loginRoute;

  if (!authenticated) {
    if (goingToLogin) return null;
    // 记住原本要去的页面，登录成功后回跳（go_router 的 `from` 约定）。
    return '$loginRoute?from=${Uri.encodeComponent(matchedLocation)}';
  }

  if (goingToLogin) return _safeFrom(fromRaw, loginRoute) ?? fallbackRoute;
  return null;
}

/// 校验 `from` 是否为可安全回跳的站内路径，非法返回 null。
///
/// 规则见 [resolveAuthRedirect] 的说明（开放重定向防护 + 重定向环防护）。
String? _safeFrom(String? raw, String loginRoute) {
  if (raw == null || raw.isEmpty) return null;
  if (!raw.startsWith('/')) return null;
  // `//host` 是协议相对 URL，必须挡掉。
  if (raw.startsWith('//')) return null;
  // 回跳到登录页自身会构成重定向环。
  if (raw == loginRoute) return null;
  return raw;
}

/// 从 `BuildContext` 读认证状态。
///
/// 用 `ProviderScope.containerOf(context, listen: false)` 而非在守卫签名里
/// 拿 `ref`：go_router 的 `redirect` 签名只有 `(context, state)`，没有 ref。
/// 用 `listen: false` 是必要的——守卫不在 build 阶段，依赖订阅会抛异常。
AuthState? _authStateFromContext(BuildContext context) {
  try {
    final container = ProviderScope.containerOf(context, listen: false);
    return container.read(authStateProvider);
  } catch (_) {
    // 没有 ProviderScope（如单测直接构造 GoRouter）→ 视为未接入认证。
    return null;
  }
}

/// 桌面端路由表（不含 `GoRouter` 实例）。
///
/// 独立导出供测试构造自己的 `GoRouter`（测试需要指定 `initialLocation`
/// 并在 pumpWidget 前拿到实例以主动导航）。
List<RouteBase> buildDesktopRoutes() {
  return [
    GoRoute(
      path: SpbRoutes.login,
      builder: (context, state) => const _LoginPage(),
    ),
    GoRoute(
      path: SpbRoutes.home,
      builder: (context, state) => const _HomePage(),
      routes: [
        GoRoute(
          path: 'chat/:groupId',
          builder: (context, state) {
            final groupId = state.pathParameters['groupId'] ?? '';
            return _ChatPage(groupId: groupId);
          },
        ),
        GoRoute(
          path: 'search',
          builder: (context, state) => const _SearchPage(),
        ),
        GoRoute(
          path: 'confirmations',
          builder: (context, state) => const _PendingConfirmationsPage(),
        ),
        GoRoute(
        ),
        GoRoute(
          path: 'settings',
          builder: (context, state) => const _SettingsPage(),
          routes: [
            GoRoute(
              path: 'sync',
              builder: (context, state) => const _SyncPage(),
            ),
          ],
        ),
        GoRoute(
          path: 'quick-capture',
          builder: (context, state) => const _QuickCapturePage(),
        ),
        GoRoute(
          path: 'overlay',
          builder: (context, state) => const _OverlayQuickCapturePage(),
        ),
      ],
    ),
  ];
}

/// 登录页（接线到认证用例）。
class _LoginPage extends ConsumerWidget {
  const _LoginPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LoginPage(
      state: ref.watch(authStateProvider),
      onSignIn: () => ref.read(authControllerProvider).signIn(),
      // 桌面端专属：SSO 在系统浏览器完成，会话 Cookie 落在浏览器里而 Flutter
      // 进程读不到（Linux 无主流 webview 插件）。粘贴导入是登录闭环的入口。
      //
      // 移动端不注入：那边有深链回调（`auth_deeplink.dart`）把授权结果直接
      // 送回进程，不需要用户手工搬运凭证。
      onImportSession: (raw) =>
          ref.read(authControllerProvider).importSession(raw),
    );
  }
}

/// 首页：对话列表。
///
/// 管理动作（改名/归档/删除）交给 `groupActionProvider`：它把领域用例的异常
/// 翻译成用户能看懂的一句话（见 provider 说明）。页面自己只负责收集意图与
/// 把权威结果反映到列表上。
///
/// ## 新建对话为什么直接调 `api.createGroup` 而不另设 provider
///
/// `groupActionProvider` 之所以存在，是因为管理动作有**多种结果语义**
/// （应用成功 / 服务端业务拒绝），需要一个 `GroupActionResult` 来承载。新建只有
/// 一种结果：拿到 [ChatGroup] 或抛错。为它单建一个 provider 只会多一层
/// 间接调用，不会带来任何翻译能力（错误文案由页面统一展示 `e.message`）。
class _HomePage extends ConsumerWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(chatApiProvider);
    // 角标数量：拉取失败静默为 0（不阻断对话列表）。
    final pendingCount = ref.watch(pendingConfirmationCountProvider).maybeWhen(
        data: (n) => n,
        orElse: () => 0,
      );
    return GroupListPage(
      api: api,
      onOpenGroup: (group) => context.go(SpbRoutes.chat(group.id)),
      onGroupAction: ref.watch(groupActionProvider),
      onSearch: () => context.go(SpbRoutes.search),
      onOpenConfirmations: () => context.go(SpbRoutes.confirmations),
      pendingConfirmationCount: pendingCount,
      // 不需要 userId：`POST /chat/groups` 的身份来自网关注入的 `X-User-ID`
      // （服务端 `chatHandlers.userID` 优先取该头），`ChatApi.createGroup` 的
      // 请求体里根本没有 user_id 字段。
      //
      // 导航不在这个闭包里做：页面创建成功后会调 `onOpenGroup`（上方已接
      // `context.go`）——「刚建的对话」与「点击某个对话」是同一个意图，
      // 共用一条导航路径，避免两处 `context.go` 指向同一目标。
      onCreateGroup: (title) => api.createGroup(title: title),
    );
  }
}

/// 搜索页（接线到注入的搜索实现）。
///
/// 点击命中项跳转到该消息所属的对话——这是搜索的核心用途：找到「那句话」
/// 然后回到它的上下文里继续。
class _SearchPage extends ConsumerWidget {
  const _SearchPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SearchPage(
      search: ref.watch(searchChatProvider),
      onOpenHit: (hit) => context.go(SpbRoutes.chat(hit.groupId)),
    );
  }
}

/// 跨 group 待确认收件箱。
//
// 预拉取列表涉及的 group 标题（`getGroup`），拼一个 `groupId → title` 缓存供
// `groupTitleOf` 同步查询。解决确认复用既有 `resolveConfirmation`（路径带 group_id）。
class _PendingConfirmationsPage extends ConsumerStatefulWidget {
  const _PendingConfirmationsPage();

  @override
  ConsumerState<_PendingConfirmationsPage> createState() =>
      _PendingConfirmationsPageState();
}

class _PendingConfirmationsPageState
    extends ConsumerState<_PendingConfirmationsPage> {
  final _titles = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(chatApiProvider);
    return PendingConfirmationsPage(
      fetch: () async {
        final items = await api.listConfirmationsTyped(status: 'pending');
        // 预取涉及的 group 标题（缺失则静默，卡片展示「未知对话」）。
        await Future.wait(
          items.map((c) async {
            if (_titles.containsKey(c.groupId)) return;
            try {
              final g = await api.getGroup(c.groupId);
              _titles[c.groupId] = g.title;
            } on Object catch (_) {
              // 拉取失败不阻断列表渲染。
            }
          }),
        );
        // 刷新计数角标。
        ref.invalidate(pendingConfirmationCountProvider);
        return items;
      },
      groupTitleOf: (gid) => _titles[gid],
      onOpenGroup: (groupId, turnId) => context.go(SpbRoutes.chat(groupId)),
      onResolve: (c, action) async {
        await api.resolveConfirmation(c.groupId, c.id, action: action);
      },
      onOpenTurn: (groupId) => context.go(SpbRoutes.chat(groupId)),
    );
  }
}

/// 对话时间线。
///
/// 进入时把控制器聚焦到该 group（`switchGroup` 会回填 timeline）；
/// 退出时 Provider autoDispose 自动断开 SSE。
class _ChatPage extends ConsumerStatefulWidget {
  const _ChatPage({required this.groupId});

  final String groupId;

  @override
  ConsumerState<_ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<_ChatPage> {
  /// 已解析的 userId。为 null 表示 `GET /api/auth/me` 尚未返回。
  ///
  /// ## 为什么必须显式持有它（issue #2）
  ///
  /// 控制器 provider 是 `family`，构造它需要**真实的** userId。若在 userId 未就绪
  /// 时就构造，会得到连 `/users//chat/stream` 的控制器，且后续 provider 重建出
  /// 正确实例时，旧实例的 `start()` 已经跑过——新实例永远不被 start。
  /// 故 build 在 userId 就绪前只渲染加载态。
  String? _userId;

  /// 是否正在解析 userId（防重复请求：`initState` 与 `didUpdateWidget` 都可能触发）。
  bool _resolvingUser = false;

  /// 已聚焦的 `userId:groupId`，避免重复 start。
  ///
  /// ## 为什么去重键要含 userId 而非只用 groupId
  ///
  /// 只用 groupId 时，若 userId 从「未就绪」变成「已就绪」（或未来切换账号），
  /// 键不变 → 去重拦住 → **新 userId 的控制器永不被 start**（这正是 issue #2
  /// 描述的那个时序）。带上 userId 后，userId 一变就是一次新的聚焦。
  String? _focused;

  /// 已建立 SSE 连接的 userId。
  ///
  /// ## 为什么需要它（切 group 不重连）
  ///
  /// SSE 是 **user 级订阅**：同一 userId 下换 group 只需换聚焦目标，连接本身
  /// 应复用。而 `SseClient.connect()` 会把 `_lastEventId` 置 null（游标清零），
  /// 于是「切对话就重连」会**丢掉续接能力**——断线重连时无法带 cursor 回放，
  /// 只能整段重拉。
  ///
  /// 故：首次聚焦该 userId 用 `start()`（建连），此后用 `switchGroup()`
  /// （只清缓冲 + 重新回填，不重连）。
  String? _connectedUserId;

  @override
  void initState() {
    super.initState();
    // 在首帧后解析：`ref.watch` 在 initState 里不可用。
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveUserAndFocus());
  }

  @override
  void didUpdateWidget(_ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) _resolveUserAndFocus();
  }

  /// 先解析 userId，再聚焦到当前 group。
  Future<void> _resolveUserAndFocus() async {
    if (!mounted || _resolvingUser) return;
    _resolvingUser = true;
    try {
      // 必须先 await 到真实 id：`currentUserIdProvider` 首次读取必然 pending，
      // 直接读 `.value` 只会拿到 null（issue #2 的根因）。
      final userId = await ref.read(currentUserIdProvider.future);
      if (!mounted) return;
      setState(() => _userId = userId);
      await _focus(userId);
    } on SpbError catch (e) {
      // 取身份失败（未登录 / 网络不可达）：保持加载态并记录。
      // 不构造空 userId 的控制器——那只会发出畸形请求。
      SpbLog.warn('解析当前用户失败，对话页停留在加载态', {'error': e.toString()});
    } finally {
      _resolvingUser = false;
    }
  }

  Future<void> _focus(String userId) async {
    final key = '$userId:${widget.groupId}';
    if (!mounted || _focused == key) return;
    _focused = key;

    final controller = ref.read(chatStreamControllerProvider(userId));
    if (_connectedUserId == userId) {
      // 同一 userId 内切 group：复用已有连接（不调 connect，游标保留）。
      await controller.switchGroup(widget.groupId);
    } else {
      // 首次聚焦：建立 SSE 连接。
      await controller.start(groupId: widget.groupId);
      _connectedUserId = userId;
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = _userId;
    // userId 未就绪：不构造控制器（`family` 需要非空 id），显示加载态。
    if (userId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('对话')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final controller = ref.watch(chatStreamControllerProvider(userId));
    final api = ref.watch(chatApiProvider);

    return ConversationPage(
      controller: controller,
      title: '对话',
      // 待处理收件箱消息（可撤销）。
      //
      // 撤销需要 userId，而页面不该知道 userId 从哪来——故在这里闭包捕获
      // （本 State 已经解析出了真实 userId，见 _resolveUserAndFocus）。
      loadPending: () => api.pendingMessages(userId, groupId: widget.groupId),
      undoPending: (messageId) => api.undoMessage(userId, messageId),
      // 切换 group 时重新加载：Flutter 会复用本页 State，
      // 不靠这个键就会一直显示上一个 group 的待处理消息。
      pendingReloadKey: widget.groupId,
      // 停止生成：`POST /chat/turns/:turn_id/cancel`。
      //
      // 不需要 userId：该端点的路径里没有 user_id（与消息流端点不同），
      // 身份来自网关注入的 `X-User-ID`。
      onCancelTurn: (turnId) => api.cancelTurn(turnId),
      // 向上翻页：加载更早历史。
      //
      // 直接委托给控制器：游标（缓冲区最小 globalSeq）与去重都是**领域状态**，
      // 页面与 router 都不应该知道它。返回值 `hasMore` 由页面用来决定是否
      // 继续触发（false = 已到最早）。
      onLoadOlder: controller.loadOlder,
      // 当前对话的身份：换了 group 要重置「已到最早」的翻页标记。
      //
      // 控制器实例在切 group 时**不变**（`switchGroup` 复用同一条 SSE），
      // 且 `_ChatPage` 未带 key、State 被复用，故页面无法自行察觉切换，
      // 必须显式告知。
      historyKey: widget.groupId,
      // 手动重连：断线/重连失败时用户不必干等退避计时器。
      //
      // family 的键必须是 **userId**（provider 的键就是它，SSE 是 user 级订阅，
      // 一个 userId 一条连接）。传 groupId 会命中另一个 family 条目，创建出一个
      // **多余的、无人监听的控制器**。
      //
      // 注：写错键**不会**导致「点了没反应」——`sseClientProvider` 是跨对话共享的
      // 单例（见其文档），`reconnect()` 最终只是 `_sse.resume()`，而那个共享 client
      // 上确实有 `_path`。故错误键只是白建一个对象，不会坏功能。仍然写对，是因为
      // 「聚焦哪个 group、游标停在哪」都归控制器所有，重建一个空控制器来表达动作
      // 是错的意思表达；且一旦将来控制器不再是无状态转发（例如加了本地重试计数），
      // 这种「靠共享单例兜住」的写法就会真的出错。
      //
      // 用 `ref.read` 而非 `ref.watch`：这是**动作**不是数据依赖，用 watch 会在
      // 每次连接状态变化时重建本 widget。
      onReconnect: () =>
          ref.read(chatStreamControllerProvider(userId)).reconnect(),
      onDownloadAgentFile: (file) => _downloadAgentFile(file, userId),
      onResolveConfirmation: (groupId, confirmationId, option) {
        // 动作文案 → 服务端 action。
        //
        // 真实路径：POST /api/chat/groups/:group_id/confirmations/:id/resolve
        // （挂载点 ext_routes.go:39 的 registerConfirmRoutes + router.go 的 /api 组）。
        // 服务端 `misc.go:resolve` 绑定 `{action, comment}`，且把 action 写进
        // `resolved_action`；status 固定为 `resolved`（见 `chat_confirmations`
        // 的 CHECK 约束：pending|resolved|expired|cancelled）。
        // 故这里必须传**动作**而非 `resolved` 这类状态词。
        api
            .resolveConfirmation(
              groupId,
              confirmationId,
              action: _optionToAction(option),
            )
            .catchError((Object e) {
              // 不重抛：确认失败不应让页面崩，用户可再点一次。
              // 真正的失败提示由 ConversationPage 的 SnackBar 覆盖发送路径，
              // 确认路径此处仅记录。
              debugPrint('确认提交失败: $e');
            });
      },
    );
  }

  /// 下载 agent 文件产物到本地并反馈落地路径。
  //
  // 走 `UfsApi.download`（`GET /api/files/{file_id}/download`）。落地目录用
  // 应用支持目录下的 `downloads/agent/`——与交付物同步目录隔离（同步目录
  // 会被清理计划动，用户手动下载的不能被带上）。
  //
  // 这里的下载是「拉取 + 落盘」的最小可用实现：不弹系统文件选择框（桌面
  // 端的保存对话框需要 `desktop_drop`/原生插件，本轮不在范围内），直接落到
  // 固定目录并以 basename 命名（防御路径穿越）。
  Future<void> _downloadAgentFile(AgentFileItem file, String userId) async {
    final fileId = file.ufsFileId;
    if (fileId == null || fileId.isEmpty || file.isDeleted) return;
    final ufs = ref.read(ufsApiProvider);
    final res = await ufs.download(fileId);
    if (res.notModified || res.bytes == null || res.bytes!.isEmpty) return;
    final dir = await getApplicationSupportDirectory();
    final target = Directory(p.join(dir.path, 'downloads', 'agent'));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    final safeName = p.basename(file.fileName.isEmpty ? 'agent-file' : file.fileName);
    await File(p.join(target.path, safeName))
        .writeAsBytes(res.bytes!, flush: true);
  }

  /// 选项文案映射为服务端 action。
  ///
  /// 服务端只把 action 存进 `resolved_action`（当前无下游消费者），故映射错误
  /// 不会造成功能异常；但保留正确语义以便将来接入。
  static String _optionToAction(String option) => switch (option) {
    '继续' => 'approve',
    '取消' => 'reject',
    _ => option,
  };
}

/// 交付物同步页（接线到同步用例）。
///
/// ## 与设置页的分工
///
/// - **设置页**（`/settings`）：配置同步目录、范围、过滤、清理；
/// - **同步页**（`/settings/sync`）：只做「立即同步」并展示本轮结果。
///
/// 分开的理由：同步是**高频动作**（每次想看最新交付物就点一次），而配置是
/// 低频动作。合在一页会让用户每次同步都要滚过一堆表单。
///
/// ## 页面不依赖平台插件
///
/// 目录选择与同步执行都通过 Provider 注入（`pickDirectoryProvider` /
/// `runSyncActionProvider`），故本页在 widget test 里可以完整验证，
/// 而真实实现（`file_selector` / UFS HTTP）只在生产装配里出现。
class _SyncPage extends ConsumerWidget {
  const _SyncPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 初始目录：读数据库绑定。读取是异步的，未就绪时传 null（页面显示
    // 「尚未选择」），就绪后由 watch 触发重建。
    //
    // 用 `.value`（riverpod 3 里它是可空的，未就绪/出错时为 null）：
    // 「尚未选过目录」与「还没读出来」都表现为 null，而页面对两者的处理
    // 完全相同（显示「尚未选择」），故不需要额外区分。
    final localRoot = ref.watch(syncLocalRootProvider).value;

    return SyncPage(
      initialLocalRoot: localRoot,
      pickDirectory: ref.watch(pickDirectoryProvider),
      runSync: ref.watch(runSyncActionProvider),
          ref.read(desktopCapabilitiesProvider).revealPath(path),
      onLocalRootChanged: (root) {
        // 保存目录（换目录会在同一事务里清空同步状态，见 provider 说明）。
        ref.read(saveLocalRootActionProvider)(root).catchError((Object e) {
          SpbLog.warn('保存同步目录失败', {'error': e.toString()});
          return false;
        });
      },
    );
  }
}

/// 设置页（接线到注入的设置读写与平台能力）。
///
/// ## 页面不依赖数据库 / 网络 / 平台插件
///
/// 全部通过 Provider 注入：读取/保存设置、目录选择、对话列表、本地扫描与
/// 清理。故本页在 widget test 里可以完整验证，真实实现只在生产装配里出现。
///
/// ## 为什么用 `ConsumerWidget` 就够了
///
/// 异步加载由 `SettingsPage` 自己管（它的 `initState` 里拉一次设置，加载完
/// 重建自己）。外层只做一次同步的 Provider 读取，因此不需要在这里持有状态
/// ——若在这里 `watch` 一个 FutureProvider 再重建，反而会在每次设置变化时
/// 丢掉页面内部的表单草稿。
class _SettingsPage extends ConsumerWidget {
  const _SettingsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsPage(
      loadSettings: ref.watch(loadSyncSettingsProvider),
      saveSettings: ref.watch(saveSyncSettingsProvider),
      loadGroups: ref.watch(loadSyncGroupsProvider),
      scanGroups: ref.watch(scanLocalGroupsProvider),
      executePrune: ref.watch(executePruneProvider),
      pickDirectory: () async {
        final caps = ref.read(desktopCapabilitiesProvider);
        return caps.pickDirectory(title: '选择交付物同步目录');
      },
      capabilities: ref.watch(desktopCapabilitiesProvider),
          ref.read(desktopCapabilitiesProvider).revealPath(path),
      // 配置在本页，跑同步在独立页面（见 SettingsPage.onOpenSync 说明）。
      onOpenSync: () => context.go(SpbRoutes.sync),
      // 退出登录：清凭证 → 回登录页。
      //
      // ## 显式 `go(login)` 是「双保险」，路由守卫已能兜住
      //
      // `signOut()` 把 `authState` 置为 `unauthenticated` 后，路由的
      // `refreshListenable` 会重跑守卫并把当前页重定向到登录页。实测：
      // **删掉这一行，测试依然全绿**（守卫确实会重定向）。
      //
      // 仍然保留它，是为了把「登出后去哪」这个意图写在调用点，而不是依赖
      // 守卫的实现细节（它按什么判定、在哪些页面生效）。代价是一行代码，
      // 收益是读代码时不必跳去守卫才能确认去向。`context.mounted` 检查让它在
      // 页面已被移除时安静跳过，此时守卫接手。
      //
      // 用 `context.mounted` 而非 `State.mounted`：这里是 `ConsumerWidget`
      // 的 `build` 闭包，捕获的是 `BuildContext` 而非 State。
      onSignOut: () async {
        await ref.read(authControllerProvider).signOut();
        if (context.mounted) context.go(SpbRoutes.login);
      },
      // 开机自启：桌面专属。移动端不传（注入 null → 不渲染该项）。
      loadLaunchAtStartup: () =>
          ref.read(desktopCapabilitiesProvider).isLaunchAtStartupEnabled(),
      setLaunchAtStartup: (enabled) =>
          ref.read(desktopCapabilitiesProvider).setLaunchAtStartup(enabled),
    );
  }
}

/// 悬浮输入窗页面。
///
/// 生产环境的真实悬浮窗是**独立窗口**（`WindowSpec.quickCapture`）；
/// 此路由用于在无多窗口能力时（或作为主窗口内的调试入口）渲染同一页面。
class _QuickCapturePage extends ConsumerWidget {
  const _QuickCapturePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useCase = ref.watch(quickCaptureUseCaseProvider);

    return QuickCapturePage(
      submit: (input) => useCase.submit(input: input),
      onQueued: (outcome) {
        // 无归属入口提交成功后导航到服务端判定的对话。
        //
        // 注意**不回显**（不传 echoInto）：本页只是悬浮窗，没有可见的对话；
        // 回显要到目标对话页由 `_focus` 的 timeline 回填完成。
        if (context.mounted) context.go(SpbRoutes.chat(outcome.groupId));
      },
      onCancel: () {
        // 独立窗口下应关窗；主窗口内的调试入口则退回列表。
        if (context.mounted) context.go(SpbRoutes.home);
      },
    );
  }
}

/// 退出悬浮窗形态（若当前处于该形态）。
///
/// 见 `_OverlayQuickCapturePage` 的说明：能力接口自己持有唯一真相
/// （`isOverlayModeActive`），故这里无需在 UI 侧另存状态。
void _exitOverlayWindow(WidgetRef ref) {
  final caps = ref.read(desktopCapabilitiesProvider);
  if (caps is OverlayWindowController) {
    final overlay = caps as OverlayWindowController;
    if (overlay.isOverlayModeActive) {
      // 不 await：调用方正在关窗导航，等待会让界面卡住一帧；
      // 还原失败已在能力层内部记日志。
      unawaited(overlay.exitOverlayMode());
    }
  }
}

/// 全局悬浮输入窗（带附件）。
///
/// 生产环境的真实悬浮窗是**独立窗口**（`WindowSpec.quickCapture`）；
/// 此路由用于在无多窗口能力时（或作为主窗口内的调试入口）渲染同一页面。
///
/// ## 为什么用 enqueue 而非 quick-capture
///
/// 只有 enqueue 支持附件（附件的「落用户级暂存区 → 建 turn 时搬进 workspace」
/// 这条链路只存在于 MQ 渠道）。纯文本场景两者等价，但同一入口不应因有无附件
/// 而改变返回语义，故统一走 enqueue。
///
/// ## 为什么提交成功后不导航
///
/// enqueue 是异步投递（worker 消费后才建 turn），本页拿不到 groupId。
/// 结果由主窗口订阅 SSE 呈现——用户可以在主窗口看到新对话出现。
class _OverlayQuickCapturePage extends ConsumerWidget {
  const _OverlayQuickCapturePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useCase = ref.watch(quickCaptureEnqueueUseCaseProvider);

    return OverlayQuickCapturePage(
      submit: ({required input, required attachments, onUploadProgress}) =>
          useCase.submit(
            input: input,
            attachments: attachments,
            onUploadProgress: onUploadProgress,
          ),
      dragDrop: ref.watch(dragDropCapabilityProvider),
      onClose: () {
        // ## 为什么这里直接调能力接口，而不是经 DesktopIntegration
        //
        // 悬浮模式把窗口改成了 720×360 置顶（见 `OverlayWindowController`）。
        // 这条路径（Esc 清空后关窗 / 提交成功）**不经过** `showWindow`，故不会
        // 被 DesktopIntegration 自动还原——不还原的话窗口会一直保持悬浮尺寸
        // 置顶，用户回到主界面后窗口再也放不大。
        //
        // 走能力接口而非 DesktopIntegration 的原因：后者由 `app.dart` 创建，
        // 而本文件被 `app.dart` import——互相引用会形成 import 环。能力接口
        // 本就通过 Provider 可达，且 `isOverlayModeActive` 是唯一真相，
        // 重复调用安全（未进入时是空操作）。
        _exitOverlayWindow(ref);
        if (context.mounted) context.go(SpbRoutes.home);
      },
    );
  }
}
