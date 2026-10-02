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

import 'auth_browser.dart';

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
  static const confirmations = '/confirmations';

  /// 我的最近轮次。
  static const myTurns = '/my-turns';

  /// 小程序工作台：工作列表。
  ///
  /// 与移动端**路径逐字一致**（`/miniapp/works`）：`work.id` 就是 group id
  /// （服务端没有独立的 works 表），两端共用同一 id 空间。
  static const works = '/miniapp/works';

  /// 工作详情。
  static String work(String workId) => '/miniapp/works/$workId';
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
          path: 'my-turns',
          builder: (context, state) => const _MyTurnsPage(),
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
        // 小程序工作台：与移动端同路径。两条路由**不会互相抢匹配**
        // （`/miniapp/works` 是 2 段，`/miniapp/works/:workId` 是 3 段，
        // 段数不同），故不依赖声明顺序——移动端有回归用例守着同一结论。
        GoRoute(
          path: 'miniapp/works',
          builder: (context, state) => const _WorksPage(),
        ),
        GoRoute(
          path: 'miniapp/works/:workId',
          builder: (context, state) =>
              _WorkDetailPage(workId: state.pathParameters['workId'] ?? ''),
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
    final pendingCount = ref
        .watch(pendingConfirmationCountProvider)
        .maybeWhen(data: (n) => n, orElse: () => 0);
    return GroupListPage(
      api: api,
      // group 变更实时增量更新（新建/删除/归档/改名）。
      //
      // 列表页自己无法收到事件：它不持有 SSE 连接（连接由对话页 `start()`
      // 建立）。本 provider 用 `ensureConnected` 确保连接在，再转发变更流
      // ——详见 provider 文档。
      //
      groupUpdates: ref.watch(groupUpdatesProvider),
      onOpenGroup: (group) => context.go(SpbRoutes.chat(group.id)),
      onGroupAction: ref.watch(groupActionProvider),
      onSearch: () => context.go(SpbRoutes.search),
      onOpenConfirmations: () => context.go(SpbRoutes.confirmations),
      // 工作台（小程序 BFF 投影层）。
      //
      // 桌面端与移动端接的是同一组端点（见 `providers.dart` 的说明），
      // 故这里与移动端接线同构。用 `push` 而非 `go`：工作台是从列表**深入**
      // 的一层，返回应回到对话列表并保留滚动位置。
      onOpenWorks: () => context.push(SpbRoutes.works),
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
    );
  }
}

/// 我的最近轮次。
//
// 身份来自网关注入的 `X-User-ID`（`/me/turns` 路径里没有 user_id）。
class _MyTurnsPage extends ConsumerWidget {
  const _MyTurnsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(chatApiProvider);
    return MyTurnsPage(
      fetch: () => api.listMyTurns(),
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

  /// 侧边栏是否展开。
  bool _showSidebar = false;

  /// 交付物刷新令牌：自增 int。
  ///
  /// 由本 State 监听 controller.items：出现新的 `AgentFileItem`（agent 产出了
  /// 文件）时 bump。面板只比较令牌是否变化，不依赖 controller——故面板可在
  /// 无头环境用内存桩完整验证。
  int _deliverablesReloadToken = 0;

  /// 建议卡标注的「下一条消息由谁回答」（follow_up 的 agent_id）。
  ///
  /// 点击建议时设置，发送时经 [ConversationPage.onSend] 透传给控制器。
  /// null 表示未标注（服务端 routingMode=auto 照常走分类链）。
  String? _selectedAgentId;

  /// controller.items 的订阅（dispose 时释放）。
  StreamSubscription<List<ConversationItem>>? _itemsSub;

  /// controller.gateDecisions 的订阅（与 items 平行，见领域层说明）。
  StreamSubscription<List<GateDecision>>? _gateSub;

  /// controller.activities 的订阅（与 items 平行，见领域层说明）。
  StreamSubscription<Map<String, TurnActivitySnapshot>>? _activitiesSub;

  /// 最近一次归约出的对话项快照。
  ///
  /// ## 为什么在 State 里存一份而不是每次 build 读 controller.snapshot
  ///
  /// 待办面板（按 turn 分组）与工具调用面板都需要这份数据，而 `snapshot`
  /// 是同步 getter——在 build 里读它不会建立依赖，items 变化时**不会**触发
  /// 重建（Flutter 无法感知）。存在 State 里 + 订阅流推送时 setState，
  /// 才是正确的响应式接线。
  List<ConversationItem> _items = const [];

  /// 最近一次归约出的 gate 决策快照（同上）。
  List<GateDecision> _gateDecisions = const [];

  /// 最近一次归约出的执行中活动快照（同上，按 turnId 索引）。
  Map<String, TurnActivitySnapshot> _activities = const {};

  /// 最近一次归约出的工具调用快照（平铺、非按 turn 分组）。
  ///
  /// 诊断 tab 的「工具调用」区是平铺视图（对齐 webapp 的 WorkbenchToolCallsPanel），
  /// 不需要按 turn 分组——故直接从 `_items` 提取 ToolCallItem。
  List<ToolCallItem> _toolCalls = const [];

  /// 正在提交的确认卡行 id（供待办面板防重复点 + 显示 spinner）。
  final _resolvingConfirmations = <String>{};

  /// 正在提交归属反馈的回执 token（防重复点击）。
  final _resolvingFeedback = <String>{};

  /// 上次见过的 `AgentFileItem` id 集合：用于判定「新出现」。
  ///
  /// 以「上次见过的 id 集合」为基线，每次 items 更新里若出现不在基线的文件 id，
  /// 就 bump 令牌。比「只看 items.length 增长」更准：历史回填、去重、软删都会
  /// 让长度变化但不代表新文件。
  Set<String> _seenFileItemIds = {};

  @override
  void initState() {
    super.initState();
    // 在首帧后解析：`ref.watch` 在 initState 里不可用。
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveUserAndFocus());
  }

  @override
  void dispose() {
    _itemsSub?.cancel();
    _gateSub?.cancel();
    _activitiesSub?.cancel();
    super.dispose();
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
    // 聚焦新 group 时重置「见过的文件 id」基线：切对话不应把旧对话里看到的
    // 文件当作「新出现」去刷新新对话的面板。
    _seenFileItemIds = {};
    if (_itemsSub == null) {
      // 只订阅一次（controller 是 user 级单例，切 group 复用同一实例）：
      // 监听 items 流，出现新的 AgentFileItem 时 bump 交付物刷新令牌。
      _itemsSub = controller.items.listen(_onItemsChanged);
      // 立即同步一次当前快照，避免错过订阅前已存在的文件。
      _onItemsChanged(controller.snapshot);
    }
    if (_gateSub == null) {
      // gate 决策走独立流（见领域层 GateDecision 类文档）。
      _gateSub = controller.gateDecisions.listen(_onGateDecisionsChanged);
      _onGateDecisionsChanged(controller.gateDecisionsSnapshot);
    }
    if (_activitiesSub == null) {
      // 执行中活动快照走独立流（见 TurnActivitySnapshot 类文档）。
      // 与 gate 同取向：先订阅再同步一次快照，避免错过订阅前已到达的事件。
      _activitiesSub = controller.activities.listen(_onActivitiesChanged);
      _onActivitiesChanged(controller.activitiesSnapshot);
    }
    if (_connectedUserId == userId || controller.isConnected) {
      // 同一 userId 内切 group：复用已有连接（不调 connect，游标保留）。
      await controller.switchGroup(widget.groupId);
      _connectedUserId = userId;
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

    // 桌面端：对话页 + 可折叠侧边栏（交付物 / 待办 / 诊断）。移动端
    // （spb_mobile）不传 actions 也不包 Row，保持原样（见 AGENTS.md §6.4）。
    final conversation = ConversationPage(
      controller: controller,
      title: '对话',
      // 侧边栏开关（仅桌面端渲染本页）。
      actions: [
        IconButton(
          key: const ValueKey('toggle-deliverables'),
          icon: Icon(
            _showSidebar ? Icons.view_sidebar : Icons.view_sidebar_outlined,
          ),
          tooltip: _showSidebar ? '隐藏侧边栏' : '显示侧边栏',
          onPressed: () => setState(() => _showSidebar = !_showSidebar),
        ),
      ],
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
      // 「立即发送」：把服务端缓冲区里 pending 的消息立即合并成 turn。
      //
      // 用带类型的 flush：服务端在「多条 pending 且未指定策略」时返回
      // **HTTP 200 + confirmation_required**（什么都没提交），返回 void 的
      // 版本会把这种待确认当成成功（见 `flushMessagesProvider`）。
      onFlush: () => ref.read(flushMessagesProvider)(widget.groupId),
      // 执行中活动指示（turn_activity）：长 turn 的静默期给用户可见进展。
      //
      // 传「流 + 首帧快照」两份：快照是同步初值（避免事件在订阅前已到达时
      // 要等下一次心跳才出现），流是后续增量。
      activities: controller.activities,
      activitiesSnapshot: _activities,
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
      // 打开 Markdown 回复里的链接。
      //
      // 走与 OIDC 登录同一个入口（`openInBrowser`，Linux 用 `xdg-open`），
      // 不另引 `url_launcher`——理由见 `auth_browser.dart` 的注释。
      // 失败只记日志：链接点不开不该弹错误打断阅读。
      onOpenLink: (url, _) => unawaited(
        openInBrowser(url)
            .catchError((Object e) => SpbLog.warn('打开链接失败', {'error': '$e'})),
      ),
      onResolveConfirmation: _resolveConfirmation,
      onResolveFeedback: _resolveFeedback,
      // 建议卡选中的 agent 随消息透传；未选中时为 null（与默认路径等价）。
      // 之所以自建 onSend 而非用默认 controller.send：默认路径没有地方带 agentId。
      onSend: (text) => ref
          .read(chatStreamControllerProvider(userId))
          .send(input: text, agentId: _selectedAgentId),
      // spec 卡动作：copy_text 已由页面内部回填输入框（_draft 通道），
      // 这里只需处理 send_next_input（直接发送）。goal_gate 的 spec 无动作，
      // 此分支当前不会命中，保留是为了服务端新增动作类型时老客户端仍能工作。
      onSpecAction: (action) {
        if (action.type == SpecUiActionType.sendNextInput &&
            action.nextInput.isNotEmpty) {
          unawaited(
            ref
                .read(chatStreamControllerProvider(userId))
                .send(input: action.nextInput, agentId: _selectedAgentId)
                .then((_) => null)
                .catchError((Object e) {
                  debugPrint('spec 动作发送失败: $e');
                  return null;
                }),
          );
        }
      },
      // 建议卡标注了 agent_id：记住它，下一条消息（含回填后用户改过再发的）
      // 由这个 agent 回答。对齐 webapp FollowUpSuggestCard 的「先切人再追加」。
      onSelectAgent: (agentId) => setState(() => _selectedAgentId = agentId),
    );

    if (!_showSidebar) return conversation;

    // 待办面板按 turn 聚合待确认卡。groupItemsByTurn 是纯函数（领域层），
    // 分组逻辑与侧边栏渲染解耦。
    final turns = groupItemsByTurn(_items);

    return Row(
      children: [
        Expanded(child: conversation),
        // 侧边栏宽度固定：交付物树/待办列表都是窄列表，定宽比自适应更可预测
        // （自适应会随文件名长度抽动，阅读时很干扰）。
        const VerticalDivider(width: 1, thickness: 1),
        SizedBox(
          width: 320,
          child: ChatSidebar(
            onClose: () => setState(() => _showSidebar = false),
            tabs: [
              ChatSidebarTab(
                label: '交付物',
                icon: Icons.folder_outlined,
                content: GroupDeliverablesPanel(
                  // groupId 变化时面板自行清空本地路径并重拉（见其类文档）。
                  groupId: widget.groupId,
                  // tab 标签已显示「交付物」，面板内不再重复标题（仅保留刷新按钮 +
                  // 文件计数这个工具条），避免与 tab 标签在视觉上紧邻重复。
                  title: '',
                  // 用 provider 取数：注入的是**不带参数的取数函数**，
                  // groupId 已由面板自己传入。
                  loadFiles: () => ref.read(
                    groupDeliverablesProvider(widget.groupId).future,
                  ),
                  onDownload: (file) =>
                      ref.read(downloadDeliverableProvider)(file),
                  onOpen: (path) => ref.read(openDeliverableProvider)(path),
                  onReveal: (path) => ref.read(revealDeliverableProvider)(path),
                  // 已同步到本地目录的交付物直接可打开（不必先在本面板下载）。
                  //
                  // 用 `watch` 而不是 `read`：索引是异步加载的（FutureProvider），
                  // watch 让「加载完成」触发本页重建，菜单项从禁用变为可用；
                  // read 会永远拿到第一次构建时那个「尚未加载」的版本。
                  resolveLocalPath: ref.watch(
                    resolveLocalDeliverableProvider(widget.groupId),
                  ),
                  // SSE 推送新文件时 bump（见 _onItemsChanged）。
                  reloadToken: _deliverablesReloadToken,
                ),
              ),
              ChatSidebarTab(
                label: '待办',
                icon: Icons.checklist_outlined,
                // 徽标 = 未解决确认卡数量（用户一眼看出有多少事要处理）。
                badge: turns.fold(
                  0,
                  (sum, t) => sum + t.pendingConfirmations.length,
                ),
                content: GroupTodosPanel(
                  turns: turns,
                  onResolveConfirmation: _resolveConfirmation,
                  resolvingIds: _resolvingConfirmations,
                  // 切 group 时清空折叠状态（旧对话的展开位置对新对话无意义）。
                  reloadKey: widget.groupId,
                  // tab 标签已命名「待办」，不重复面板标题。
                  showHeader: false,
                ),
              ),
              ChatSidebarTab(
                label: '诊断',
                icon: Icons.insights_outlined,
                content: GroupDebugPanel(
                  toolCalls: _toolCalls,
                  decisions: _gateDecisions,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 提交确认卡选择（内联卡与待办面板共用）。
  ///
  /// ## 为什么要记 busy 集合
  ///
  /// 同一张卡在两处可点（时间线内联 + 侧边栏待办）。若只靠按钮自身禁用，
  /// 两处的 busy 状态互不相知，用户可以在侧边栏点一下、又回时间线再点一下。
  /// busy 集合按 confirmationId 去重，两处共享。
  ///
  /// 动作文案 → 服务端 action 的映射见 [_optionToAction]。
  void _resolveConfirmation(
    String groupId,
    String confirmationId,
    String option,
  ) {
    if (_resolvingConfirmations.contains(confirmationId)) return;
    setState(() => _resolvingConfirmations.add(confirmationId));
    // 动作文案 → 服务端 action。
    //
    // 真实路径：POST /api/chat/groups/:group_id/confirmations/:id/resolve
    // （挂载点 ext_routes.go:39 的 registerConfirmRoutes + router.go 的 /api 组）。
    // 服务端 `misc.go:resolve` 绑定 `{action, comment}`，且把 action 写进
    // `resolved_action`；status 固定为 `resolved`（见 `chat_confirmations`
    // 的 CHECK 约束：pending|resolved|expired|cancelled）。
    // 故这里必须传**动作**而非 `resolved` 这类状态词。
    ref
        .read(chatApiProvider)
        .resolveConfirmation(
          groupId,
          confirmationId,
          action: _optionToAction(option),
        )
        .whenComplete(() {
          // 成功与失败都解锁：失败时应允许重试（不重抛、不弹错误打断阅读，
          // 与内联路径的既有行为一致）。
          if (mounted) {
            setState(() => _resolvingConfirmations.remove(confirmationId));
          }
        })
        .catchError((Object e) {
          debugPrint('确认提交失败: $e');
        });
  }

  /// 提交归属反馈（「这条消息归到这个对话对吗」）。
  ///
  /// 与 [_resolveConfirmation] 同构：成功与失败都解锁，失败允许重试。
  /// busy 集合按 token 去重——页面内 busy 已有一层，这里是第二层（
  /// 与 [_resolvingConfirmations] 同样防止「两处可点」时的重复提交）。
  void _resolveFeedback(String token, bool correct) {
    if (_resolvingFeedback.contains(token)) return;
    setState(() => _resolvingFeedback.add(token));
    ref
        .read(chatApiProvider)
        .resolveFeedback(token, correct: correct)
        .whenComplete(() {
          if (mounted) {
            setState(() => _resolvingFeedback.remove(token));
          }
        })
        .catchError((Object e) {
          debugPrint('归属反馈提交失败: $e');
        });
  }

  /// 监听 controller.gateDecisions：更新诊断面板数据。
  void _onGateDecisionsChanged(List<GateDecision> decisions) {
    if (!mounted) return;
    setState(() => _gateDecisions = decisions);
  }

  /// 监听 controller.activities：驱动对话页的空窗期进度指示。
  void _onActivitiesChanged(Map<String, TurnActivitySnapshot> activities) {
    if (!mounted) return;
    setState(() => _activities = activities);
  }

  /// 监听 controller.items：更新待办面板数据，并在出现新的 `AgentFileItem`
  /// 时 bump 交付物刷新令牌。
  ///
  /// ## 为什么用「见过 id 集合」而不是 items.length
  ///
  /// 长度增长不代表有新文件：向上翻历史回填会让长度增加，去重会减少，
  /// 软删会让文件消失。以「上次见过的文件 id」为基线，只在新 id 出现时刷新。
  ///
  /// ## 为什么只 bump 令牌，不直接调 provider
  ///
  /// 面板可能未展开（`groupDeliverablesProvider` 是 autoDispose，无人监听时
  /// 本就不该取数）。bump 令牌是无副作用的；展开后首帧会拉到最新。
  void _onItemsChanged(List<ConversationItem> items) {
    final ids = <String>{};
    for (final item in items) {
      if (item is AgentFileItem && !item.isDeleted) {
        final id = item.ufsFileId;
        if (id != null && id.isNotEmpty) ids.add(id);
      }
    }
    // 首次建立基线：不 bump（避免刚打开页面就多拉一次——首帧本就要拉）。
    final isFirstSync = _seenFileItemIds.isEmpty;
    final hasNew = ids.difference(_seenFileItemIds).isNotEmpty;
    _seenFileItemIds = ids;

    if (!mounted) return;
    // 同一次 setState 里同时更新待办面板的数据与交付物刷新令牌：
    // items 流推送时两者都要变，分开 setState 会多一次重建。
    setState(() {
      _items = items;
      _toolCalls = items.whereType<ToolCallItem>().toList(growable: false);
      if (!isFirstSync && hasNew) _deliverablesReloadToken++;
    });
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
    final safeName = p.basename(
      file.fileName.isEmpty ? 'agent-file' : file.fileName,
    );
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
      // 回传是显式逐文件动作（自动同步仍单向，见 SyncPage 文档）。
      scanDirtyFiles: ref.watch(scanDirtyFilesActionProvider),
      uploadChanges: ref.watch(uploadChangesActionProvider),
      onOpenDirectory: (path) =>
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
      onOpenDirectory: (path) =>
          ref.read(desktopCapabilitiesProvider).revealPath(path),
      // 外观：选中即保存（不走 draft，见 SaveThemeMode 的说明）。
      loadThemeMode: ref.watch(loadThemeModeProvider),
      saveThemeMode: ref.watch(saveThemeModeProvider),
      onOpenMyTurns: () => context.go(SpbRoutes.myTurns),
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
      // 路由预览（服务端当前只返回**兜底默认 agent**，且响应里没有 group_id；
      // 页面文案已如实标注，见 `QuickCapturePage._previewLine`）。
      previewRouting: ref.watch(previewRoutingProvider),
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

/// 工作列表页（小程序工作台）。
///
/// 与移动端 `_WorksPage` 同构（端点与页面组件都共用）：workId 就是 group id。
class _WorksPage extends ConsumerWidget {
  const _WorksPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return WorksPage(
      loadWorks: ref.watch(loadMiniappWorksProvider),
      onOpenWork: (work) => context.push(SpbRoutes.work(work.id)),
      // 新建后直接进详情：新工作的标题是占位符「新会话」，列表里一堆同名条目
      // 看不出哪个是自己刚建的；进详情才能看到状态与进度。
      //
      // 导航放在装配层（与 `onOpenWork` 同一约定）：本页拿到的是 `workId`
      // 而非完整的 `MiniappWork`，页面内部造不出来。
      onCreateWork: () async {
        final workId = await ref.read(createMiniappWorkProvider)();
        if (context.mounted) context.push(SpbRoutes.work(workId));
        return workId;
      },
    );
  }
}

/// 工作详情页。
///
/// ## 为什么用 `family(workId)` 而不是在页面内部取
///
/// 十个注入点全部依赖 workId，若在页面内部从路由读，页面就得知道路由——那是
/// app 装配层的事。用 family 把它变成构造参数，页面保持纯注入（可测）。
///
/// 用 `context.push` 而非 `go`：详情是从列表**深入**的一层，返回应回到列表
/// 并保留滚动位置。
class _WorkDetailPage extends ConsumerWidget {
  const _WorkDetailPage({required this.workId});

  final String workId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return WorkDetailPage(
      loadDetail: ref.watch(loadMiniappWorkDetailProvider(workId)),
      loadEvents: ref.watch(loadMiniappWorkEventsProvider(workId)),
      loadArtifacts: ref.watch(loadMiniappArtifactsProvider(workId)),
      downloadArtifact: ref.watch(downloadMiniappArtifactProvider(workId)),
      saveArtifact: ref.watch(saveMiniappArtifactProvider),
      sendMessage: ref.watch(sendMiniappMessageProvider(workId)),
      complete: ref.watch(completeMiniappWorkProvider(workId)),
      stop: ref.watch(stopMiniappWorkProvider(workId)),
      resolveConfirmation: ref.watch(resolveMiniappConfirmationProvider),
      onUploadFile: ref.watch(uploadMiniappFileProvider(workId)),
    );
  }
}
