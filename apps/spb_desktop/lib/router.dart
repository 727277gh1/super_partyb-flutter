import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';
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

  /// 全局悬浮输入窗（带附件）。
  ///
  /// ## 为什么只有这一条（曾经的 `/quick-capture` 已删）
  ///
  /// 旧路由走 `POST /me/quick-capture`（同步、返回 groupId、**无附件**），
  /// 而本路由走 `POST /me/quick-capture/enqueue`（异步、带附件）。两者的
  /// 差别只在「有无附件」：纯文本场景行为等价，故同一入口不需要两个页面
  /// ——保留一个功能更弱的反而会让用户选了它之后发现贴不了图。
  ///
  /// 旧路由的类注释自称「主窗口内的调试入口」，但全仓并无任何导航调用点
  /// （`Alt+Space` 与托盘「快速输入」都指向本路由）。保留一条不可达且功能
  /// 更弱的重复页面只会让下一个人以为它有用户。
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

  /// 习惯管理（规则列表 + 执行历史）。
  static const habits = '/habits';

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
          path: 'habits',
          builder: (context, state) => const _HabitsPage(),
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
      onOpenHabits: () => context.push(SpbRoutes.habits),
      // 全局设置页（同步目录 / 范围 / 过滤 / 外观 / 个人偏好 / 诊断导出）。
      //
      // ## 为什么必须在这里给入口
      //
      // 桌面端此前**没有**任何 UI 入口能到 `/settings`：托盘只有「同步设置…」
      // （直达 `/settings/sync`），列表 AppBar 没有设置图标。结果是同步目录、
      // 范围、媒体开关、本地清理、外观、个人偏好、导出诊断日志**在界面上不可达**。
      // `WindowRole.settings → /settings` 的映射虽然存在，但生产代码里没有
      // 任何地方调 `showWindow(WindowRole.settings)`（只有测试会）。
      //
      // 用 `go` 而非 `push`：`/settings` 是**同级**顶层页面（对话列表 ↔ 设置），
      // 不是从列表「深入」的一层（`onOpenWorks` / `onOpenHabits` 才是深入）。
      onOpenSettings: () => context.go(SpbRoutes.settings),
      pendingConfirmationCount: pendingCount,
      // 对话列表缓存（issue #26 切片 A）：断网冷启动时回落展示已缓存的列表，
      // 而不是白屏。
      //
      // ## 为什么 userId 用 `cachedUserIdProvider`（本地优先）而不是
      // `currentUserIdProvider`
      //
      // 后者内部是 `chatApi.me()`——一次**网络请求**。断网时它必然失败，userId
      // 拿不到，缓存就无法定位自己的行 → 回落失效（而那正是本功能要覆盖的场景）。
      // `cachedUserIdProvider` 先读本地持久化副本，离线也能命中。
      //
      // 首次启动（本地无值）且断网时它返回 null，此时 `cache`/`userId` 不同时
      // 有效，页面静默不启用缓存——无行可查，也没有更优解。
      cache: ref.watch(groupCacheStoreProvider),
      userId: ref.watch(cachedUserIdProvider).value,
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
            } on Object catch (e) {
              // 拉取失败不阻断列表渲染（卡片展示「未知对话」）。
              //
              // 记 debug（issue #45）：「未知对话」这个占位与「对话真叫这个
              // 名字」无法区分，且用户会以为数据丢了。
              SpbLog.debug('待确认卡片预取对话标题失败', {
                'group_id': c.groupId,
                'error': e.toString(),
              });
            }
          }),
        );
        // 刷新计数角标。
        //
        // ## 为什么 invalidate 被依赖者而不是 count
        //
        // `pendingConfirmationCountProvider` 是
        // `await ref.watch(pendingConfirmationsProvider.future)` 的派生值。
        // 只 invalidate count 时它重建后读到的仍是**被缓存的**
        // `pendingConfirmationsProvider` 结果——角标不会变（本行原先正是
        // 这个失效调用）。invalidate 被依赖者，count 会因 watch 依赖自动重算。
        ref.invalidate(pendingConfirmationsProvider);
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
      // 透传页面上的筛选条件（days/source/status/groupId → 服务端 query）。
      fetch: ({days, status, source, groupId}) => api.listMyTurns(
        days: days,
        status: status,
        source: source,
        groupId: groupId,
      ),
      // 关键词搜索（issue #18）。与 fetch 分开注入：两个端点的参数集不相交，
      // 合并会让「搜索时也把筛选条件发下去」变成容易顺手写出的 bug，而服务端
      // 会静默忽略它们。
      search: (query) => api.searchMyTurns(query: query),
      // 点击一行 → 弹轮次详情（issue #19）。
      //
      // 不再只是 `context.go(chat(groupId))`：那样只能跳到对话列表，
      // 用户看不到「这一轮到底发生了什么」。turnId 现在会传进来，
      // 故可以直接拉详情。
      onOpenTurn: (groupId, turnId) =>
          _showTurnDetail(context, ref, groupId, turnId),
    );
  }

  /// 弹「轮次详情」对话框。
  ///
  /// ## 为什么用对话框（桌面端）而不是底部弹层
  ///
  /// 与 AGENTS.md §6.10 的两端载体约定一致：桌面端有宽屏空间，对话框能一次
  /// 展示更多事件；移动端走底部弹层（见 `spb_mobile` 的同名方法）。
  Future<void> _showTurnDetail(
    BuildContext context,
    WidgetRef ref,
    String groupId,
    String turnId,
  ) async {
    final loader = ref.read(loadTurnDetailProvider);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('turn-detail-dialog'),
        contentPadding: EdgeInsets.zero,
        // 固定尺寸：详情是长列表，随内容撑开会让对话框抖到超出屏幕。
        content: SizedBox(
          width: 560,
          height: MediaQuery.sizeOf(dialogContext).height * 0.75,
          child: TurnDetailSheet(
            groupId: groupId,
            turnId: turnId,
            load: loader.call,
            // 不注入文件回调：下载 / 打开 / 预览的实现是 `_ChatPageState` 的
            // 私有方法（`_ensureAgentFileLocal` 等），从本页取不到；把它们
            // 提成 provider 属独立重构，不在本 issue 范围。未注入时
            // `AgentFileCard` 只渲染文件信息、不渲染菜单项（其既有约定）。
          ),
        ),
      ),
    );
  }
}

/// 习惯管理页。
///
/// ## 为什么列表/历史用 provider 而写操作用 `ref.read`
///
/// 两个 `FutureProvider`（[habitsProvider] / [habitRunsProvider]）只作**首拉**
/// 缓存，页面的 `loadHabits` / `loadRuns` 回调在刷新时重新调 API——若直接返回
/// provider 的缓存值，用户点「刷新」看不到新数据（服务端刚被另一端改过）。
///
/// 写操作后不 invalidate provider：页面自己会重新拉（`_load`），invalidate 会
/// 额外触发一次无谓重建。
class _HabitsPage extends ConsumerStatefulWidget {
  const _HabitsPage();

  @override
  ConsumerState<_HabitsPage> createState() => _HabitsPageState();
}

class _HabitsPageState extends ConsumerState<_HabitsPage> {
  /// groupId → title 缓存（`/api/habits/runs` 只给 id，标题要自己查）。
  final _titles = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(habitApiProvider);
    return HabitsPage(
      loadHabits: () => api.listHabits(),
      loadRuns: (filter) async {
        // 服务端 `GET /api/habits/runs?days=&trigger_reason=` 直接筛选，
        // 且响应带 `daily_budget`（今日已用/上限）。
        final result = await api.listAllRunsWithBudget(
          days: filter.days,
          triggerReason: filter.reason?.wire,
        );
        final runs = result.items;
        // 预取涉及的 group 标题（缺失则静默，列表不展示标题）。
        //
        // 与 `_PendingConfirmationsPageState` 同策略：只查缺的、不重复查。
        await Future.wait(
          runs.map((r) async {
            final gid = r.deliveryGroupId ?? r.originGroupId;
            if (gid.isEmpty || _titles.containsKey(gid)) return;
            try {
              final g = await ref.read(chatApiProvider).getGroup(gid);
              _titles[gid] = g.title;
            } on Object catch (e) {
              // 标题查不到不该让整个列表失败（展示「未知对话」）。
              SpbLog.debug('运行记录预取对话标题失败', {
                'group_id': gid,
                'error': e.toString(),
              });
            }
          }),
        );
        return result;
      },
      groupTitleOf: (gid) => _titles[gid],
      // 写操作统一走 `HabitApi`。异常由 `HabitsPage` 接住并翻成提示
      // （409 → 「状态已变化」），故这里不做 try/catch。
      onTrigger: (h) => api.triggerHabit(h.id),
      onPause: (h) => api.pauseHabit(h.id),
      onResume: (h) async => api.resumeHabit(h.id),
      onArchive: (h) => api.archiveHabit(h.id),
      onCreate: (draft) async {
        final r = await api.createHabit(
          topicKey: draft.topicKey,
          acceptanceLevel: draft.acceptanceLevel,
          triggerConfig: draft.triggerConfig,
        );
        return r.patternId;
      },
      // 习惯执行产生的对话就是普通对话，直接跳过去（同 `_MyTurnsPage`）。
      onOpenTurn: (groupId, _) => context.go(SpbRoutes.chat(groupId)),
      // ---------- 编辑 + 按规则查记录 ----------
      //
      // 两者都只发改动字段 / 只查单条规则，见 `HabitPatch` 与 `HabitRunsPage`
      // 的类文档。
      onEdit: (h, patch) => api.patchHabit(
        h.id,
        topicKey: patch.topicKey,
        acceptanceLevel: patch.acceptanceLevel,
        triggerConfig: patch.triggerConfig,
        preferredAgentId: patch.preferredAgentId,
      ),
      loadHabitRuns: (patternId) => api.listHabitRuns(patternId),
      // ---------- 建议收件箱 ----------
      //
      // 与卡片上的接受/忽略/稍后同一套端点（`/api/chat/habit-suggestions`）。
      // 页面不持有 `HabitApi`（分层约定），故这里把三个方法传进去。
      loadSuggestions: (filter) => api.listSuggestions(filter: filter),
      resolveSuggestion: (s, action, {snooze}) => api
          .resolveSuggestion(
            s.id,
            action: action,
            // 时刻由 `HabitSnoozeOption.until` 算（UTC RFC3339）——服务端解析
            // 失败会**静默**回退冷却时长，格式错了用户只能发现「时间不对」。
            snoozeUntil: snooze?.until(DateTime.now()),
          )
          .then((_) {}),
      unresolveSuggestion: api.unresolveSuggestion,
      loadInsights: (days) => api.habitInsights(days: days),
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

  /// 当前对话的权威 ChatGroup（设置 tab 的目标文本与三个开关的真源）。
  ///
  /// 由 `GET /chat/groups/:id` 取得，写操作成功后用其响应覆盖（见
  /// [GroupSettingsUseCase] 的说明：写端点只回布尔，权威状态必须回读）。
  ChatGroup? _group;

  /// 拉取 group 失败的原因（可直接展示）。
  ///
  /// ## 为什么需要显式错误态而不是「永远转圈」
  ///
  /// 加载失败时若仍渲染进度指示器，用户看到的是**永不结束的转圈**——既不知道
  /// 出了问题，也没法重试。且无限动画会让 `pumpAndSettle` 永不收敛（测试里
  /// 表现为超时，真实环境里表现为耗电的持续重绘）。
  String? _groupError;

  /// 设置写操作是否在途（面板用它禁用全部控件，防并发提交把 CAS 打成 409）。
  bool _settingsBusy = false;

  /// agent 切换是否在途。
  ///
  /// 切换会归档旧绑定 + 写新绑定，是**非幂等**的（并发切换会把绑定顺序打乱，
  /// 最后落库的未必是用户最后选的那个）。故在途时禁用入口。
  bool _switchingAgent = false;

  /// 交付物刷新令牌：自增 int。
  ///
  /// 由本 State 监听 controller.items：出现新的 `AgentFileItem`（agent 产出了
  /// 文件）时 bump。面板只比较令牌是否变化，不依赖 controller——故面板可在
  /// 无头环境用内存桩完整验证。
  int _deliverablesReloadToken = 0;

  /// 进入本对话时探测到的同步需求（null = 未探测 / 已忽略）。
  ///
  /// ## 为什么由本 State 持有而不是 provider
  ///
  /// 它的生命周期就是「这个对话页这一次打开」：切 group 要重新探测、忽略
  /// 之后要消失。做成 provider 反而要处理「哪个 group 的哪次结果」的失效
  /// 问题，而 State 天然随页面/groupId 变化。
  GroupSyncCheckResult? _syncCheck;

  /// 探测是否在途（防重复：`didUpdateWidget` 与登录态变化都可能触发）。
  bool _checkingSync = false;

  /// 用户点了「立即同步」且正在进行。
  bool _syncingFromHint = false;

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

  /// controller.contextUsage 的订阅（与 activities 平行，见领域层说明）。
  StreamSubscription<ContextUsage?>? _contextUsageSub;

  /// 最近一次归约出的上下文用量快照（同上）。
  ///
  /// 为 null 表示尚无可用用量数据（服务端未发射或载荷无法解析），
  /// 页面据此隐藏用量区。
  ContextUsage? _contextUsage;

  /// controller.executionStatus 的订阅（queue_state / retry_scheduled）。
  StreamSubscription<ExecutionStatus?>? _executionStatusSub;

  /// 最近一次归约出的等待/重试状态；null 表示当前无等待。
  ExecutionStatus? _executionStatus;

  /// controller.ttsStatus 的订阅（tts_started / tts_completed / tts_failed）。
  StreamSubscription<TtsStatus?>? _ttsStatusSub;

  /// controller.staleTurnIds 的订阅（超时兜底：长时间无进展的 turn）。
  ///
  /// 判据（「距最后一次事件」）与计时都在控制器里：它看得见 `turn_activity`
  /// 这类**不进 items** 的续期信号。本页只消费结果，不自建计时。
  StreamSubscription<Set<String>>? _staleTurnIdsSub;

  /// 最近一次超时集合（同上，存在 State 里才能触发重建）。
  Set<String> _staleTurnIds = const {};

  /// controller.goalUpdates 的订阅（goal_updated）。
  ///
  /// 事件携带与 `GET /goals/current` 同构的完整快照，故直接套进 _group
  /// 即可，无需再发一次 HTTP（见 GoalUpdate 类文档）。
  StreamSubscription<GoalUpdate>? _goalUpdatesSub;

  /// controller.groupUpdates 的订阅（本页只关心 metadata 变更）。
  ///
  /// ## 为什么对话页也要订阅（列表页已经在用了）
  ///
  /// `group_metadata_updated` 是 Goal Gate **后台**自动停用时的唯一通知：
  /// 服务端改了 `chat_groups.metadata`（`markGoalGateCompleted` 写
  /// `gate["enabled"] = false`），但没有任何 HTTP 响应回到客户端。
  /// 不消费它，设置面板会继续显示「自动实现目标：开」——事实性错误。
  ///
  /// 列表页虽也收到该事件，但 `GroupListPage._onGroupUpdate` 对
  /// `GroupUpdateOp.metadata` 是**刻意忽略**的（它只渲染标题与状态，
  /// metadata 的开关在对话页/设置面板编辑）。故本页必须自己订阅。
  StreamSubscription<GroupUpdate>? _groupUpdatesSub;

  /// 最近一次归约出的播报状态；null 表示本群未开语音/尚无事件。
  TtsStatus? _ttsStatus;

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

  /// 上次见过的确认卡身份集合：用于判定「待确认集合是否变了」。
  ///
  /// 元素形如 `'<confirmation_id>:<resolved>'`——把 `resolved` 也编进身份，
  /// 因为「一张卡被解决」同样是待确认集合的变化（角标要减 1）。只比较
  /// `confirmation_id` 会漏掉这条路径。
  ///
  /// ## 为什么是可空（null 表示「从未同步」）而不是空集合
  ///
  /// 用 `isEmpty` 判定首次同步有个错：**一个本来就没有确认卡的对话**，
  /// 首次同步后集合仍是空的，于是第二张卡真的到来时也会被当成「首次」而跳过
  /// 刷新。null 把「没同步过」与「同步过且为空」区分开。
  Set<String>? _seenConfirmationIds;

  /// 已加载 group 的 groupId（防重复拉取）。
  bool _loadingGroup = false;

  @override
  void initState() {
    super.initState();
    // 在首帧后解析：`ref.watch` 在 initState 里不可用。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveUserAndFocus();
      _loadGroup();
    });
  }

  @override
  void dispose() {
    _itemsSub?.cancel();
    _gateSub?.cancel();
    _activitiesSub?.cancel();
    _contextUsageSub?.cancel();
    _executionStatusSub?.cancel();
    _ttsStatusSub?.cancel();
    _staleTurnIdsSub?.cancel();
    _goalUpdatesSub?.cancel();
    _groupUpdatesSub?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(_ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      // 先置空再拉：不置空会让新对话的设置 tab 短暂显示上一个对话的目标与开关
      // （State 被 Flutter 复用，_group 不会自动失效）。
      _group = null;
      _groupError = null;
      // 上一个对话的同步提示对新对话无意义（它说的是那个 group 的文件）。
      _syncCheck = null;
      _resolveUserAndFocus();
      _loadGroup();
    }
  }

  /// 把本对话切到另一个 agent（含「同 Agent 开新会话」）。
  ///
  /// ## 为什么切换后要重拉 group **并**刷新时间线
  ///
  /// - 重拉 group：`activeSession.agentId` 变了，AppBar 的标签要跟着变；
  /// - 刷新时间线：服务端会归档旧 binding，新 binding 的 `session_id` 是
  ///   lazy 的（下一轮 turn 才回填）。虽然历史消息仍属于这个 group（时间线
  ///   不会少内容），但重拉能保证「下一轮回复来自新 agent」这一事实有最新
  ///   的服务端状态兜底，而不是靠本地推断。
  ///
  /// 失败弹 SnackBar：切换是用户主动发起且带确认的动作，失败必须告知——
  /// 静默失败会让用户以为切好了，接着发消息却发现回复还来自旧 agent。
  Future<GroupAgentSwitchResult> _switchAgent(
    String agentId, {
    required bool forceNewSession,
  }) async {
    if (_switchingAgent) {
      throw const ValidationError('切换正在进行中，请稍候');
    }
    setState(() => _switchingAgent = true);
    try {
      final result = await ref
          .read(agentsApiProvider)
          .switchGroupAgent(
            widget.groupId,
            agentId: agentId,
            forceNewSession: forceNewSession,
          );
      if (!mounted) return result;
      await _loadGroup();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(forceNewSession ? '已开始新会话' : '已切换 Agent')),
          );
      }
      return result;
    } on SpbError catch (e) {
      SpbLog.warn('切换 Agent 失败', {
        'groupId': widget.groupId,
        'agentId': agentId,
        'error': e.toString(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(_describeSwitchError(e))));
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _switchingAgent = false);
    }
  }

  /// 把切换失败翻成用户能看懂的一句话。
  ///
  /// `HttpError.message` 恒为 `"HTTP 400"`，服务端文案在 `body` 里
  /// （见 `AgentsApi._unwrap`），故必须从 body 提取。
  static String _describeSwitchError(SpbError e) {
    if (e is HttpError) {
      final body = e.body ?? '';
      // 404 = agent 已被删除（列表可能是在它删除前拉的）。
      if (e.isNotFound) return '这个 Agent 已不存在，请重新打开列表选择';
      if (body.contains('agentId')) return '切换失败：Agent 参数无效';
      if (e.statusCode == 401) return '登录已过期，请重新登录';
      return '切换失败（HTTP ${e.statusCode}）';
    }
    if (e is NetworkError) return '网络连接失败，请检查网络后重试';
    return e.message;
  }

  /// 拉取当前 group 的权威状态（设置 tab 的初始值）。
  ///
  /// 失败不阻断对话页（聊天与设置是两件事），但必须**如实报错**：设置 tab
  /// 显示重试入口，而不是一个永不结束的转圈。
  Future<void> _loadGroup() async {
    if (!mounted || _loadingGroup) return;
    _loadingGroup = true;
    try {
      final group = await ref.read(chatApiProvider).getGroup(widget.groupId);
      if (mounted) {
        setState(() {
          _group = group;
          _groupError = null;
        });
      }
    } on SpbError catch (e) {
      SpbLog.warn('读取对话设置失败', {
        'groupId': widget.groupId,
        'error': e.toString(),
      });
      if (mounted) setState(() => _groupError = describeGroupSettingsError(e));
    } finally {
      _loadingGroup = false;
    }
  }

  /// 执行一个设置写操作：成功后用返回的权威 group 覆盖本地。
  ///
  /// ## 为什么 busy 是一个全局布尔而不是按动作区分
  ///
  /// 这几个设置都写同一个 `metadata`（goal_gate / follow_up_suggest / tts 共处
  /// 一个 JSON 列），服务端用乐观锁（CAS）写入。两个并发写会让其中一个拿到
  /// 409。故同一时刻只允许一个设置在途——粒度再细也不能让它们并行。
  Future<void> _runSetting(Future<ChatGroup> Function() action) async {
    if (_settingsBusy) return;
    setState(() => _settingsBusy = true);
    try {
      final updated = await action();
      if (mounted) setState(() => _group = updated);
    } on GroupSettingsFailure catch (e) {
      _showSettingsError(e.message);
    } on SpbError catch (e) {
      // 纵深防御：[GroupSettingsUseCase] 已把 SpbError 翻成
      // [GroupSettingsFailure]，漏到这里说明翻译层自己出了问题。
      SpbLog.warn('设置失败（未经翻译）', {'error': e.toString()});
      _showSettingsError('设置失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  void _showSettingsError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ==================== 任务清单（任务 tab）====================

  /// 当前 goal 快照（无 goal 或 `current_goal` 缺失时为空快照）。
  ///
  /// ## 为什么从 `_group.currentGoal` 取而不是单独发一次 HTTP
  ///
  /// `_group` 的 `current_goal` 由 `GET /chat/groups/:id` 首次填充，此后由
  /// `goal_updated` SSE 事件实时覆盖（见 [_onGoalUpdated]）。它携带的
  /// goal/tasks/progress 由与 `GET /goals/current` **完全相同**的 DTO 函数
  /// 生成（Go `goalToDTO`/`taskToDTO`/`progressFromTasks`），故是权威且最新的。
  /// 另发一次请求只会拿到同一份数据，还可能与 SSE 竞争。
  GoalSnapshot get _goalSnapshot =>
      GoalSnapshot.fromJson(_group?.currentGoal ?? const {});

  /// 当前 goal 的行 id（任务端点的路径参数）。无 goal 时为空串。
  String get _goalId => _goalSnapshot.goal?.id ?? '';

  /// 任务 tab 的徽标：未完成任务数（`skipped` 也算完成，见 [GoalTaskStatus]）。
  int get _unfinishedTaskCount {
    final tasks = _goalSnapshot.tasks;
    if (tasks.isEmpty) return 0;
    return tasks.where((t) => !t.isCompleted).length;
  }

  /// 执行一个任务写操作，成功后重新拉取 group 以拿到权威快照。
  ///
  /// ## 为什么是 write → re-read 而不是用响应体直接改本地
  ///
  /// 各写端点的响应形状不一致：`setTaskStatus` 回 `{task, progress}`、
  /// `reorder` 回 `{items}`、`deleteTask` 回 `{deleted}`、`resetForExpand` 回
  /// 被删/保留清单。逐个写本地归一化逻辑会与 `goal_updated` 事件路径产生
  /// 两套真相。统一回读 `getGroup` 与设置面板同一约定（写端点只回局部状态，
  /// 权威状态必须回读），也顺带让「任务」与「设置」两个 tab 拿到同一份
  /// `_group` 对象。
  ///
  /// ## 为什么复用 `_settingsBusy`
  ///
  /// 与设置写入共享一个 busy 位：两者都会触发 `_group` 替换，并发会让面板在
  /// 中途看到不一致的快照（且都会重写 metadata / 任务表）。粒度过细没有收益。
  ///
  /// ## [requireGoal]：目标历史面板必须能跳过 `_goalId` 校验
  ///
  /// 任务类写操作都以 `_goalId` 为路径参数，无 goal 时路径会拼成空串
  /// （服务端 404），故默认拦在客户端。
  ///
  /// 但**切回历史目标恰恰发生在「当前没有目标」时**：用户先清除了目标
  /// （`ChatApi.setGroupGoal` 置 archived），`_goalId` 变空，此时历史面板的
  /// 「切回」是唯一的恢复入口。若也拦，就形成了一个死局——有历史但回不去。
  /// 故历史面板显式传 `requireGoal: false`。
  Future<void> _runGoalWrite(
    Future<void> Function() action, {
    bool requireGoal = true,
  }) async {
    if (_settingsBusy) return;
    if (requireGoal && _goalId.isEmpty) {
      _showSettingsError('当前对话没有目标，无法操作任务');
      return;
    }
    setState(() => _settingsBusy = true);
    try {
      await action();
      // 回读权威状态（同时刷新 goal / tasks / progress）。
      await _loadGroup();
    } on SpbError catch (e) {
      SpbLog.warn('任务操作失败', {
        'groupId': widget.groupId,
        'goalId': _goalId,
        'error': e.toString(),
      });
      _showSettingsError(_describeGoalError(e));
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  /// 头部刷新按钮：只重拉 group，不执行写操作。
  Future<void> _reloadGoalTasks() async {
    if (_settingsBusy) return;
    setState(() => _settingsBusy = true);
    try {
      await _loadGroup();
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  /// 把任务写操作的错误翻成用户能看懂的一句话。
  ///
  /// `SpbError.message` 是给开发者看的（`HttpError` 的消息就是 `"HTTP 409"`），
  /// 直接展示等于没说。服务端在 `{error: "..."}` 里给了具体原因（如
  /// `task_id 已存在: TASK-001`），优先用它。
  String _describeGoalError(SpbError e) {
    if (e is HttpError) {
      return switch (e.statusCode) {
        404 => '任务或目标不存在（可能已被删除），已刷新列表',
        409 => '任务编号已存在，请换一个标题后重试',
        400 => '请求被拒绝：${e.message}',
        _ => '操作失败（HTTP ${e.statusCode}），请稍后重试',
      };
    }
    if (e is AuthError) return '登录已失效，请重新登录';
    return '操作失败，请稍后重试';
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
      // 探测放在聚焦之后：先让时间线连上（用户立刻看到内容），再在后台问
      // 「有没有交付物没同步」。反过来会让打开对话多等一次 HTTP 往返。
      await _checkGroupSync(userId);
    } on SpbError catch (e) {
      // 取身份失败（未登录 / 网络不可达）：保持加载态并记录。
      // 不构造空 userId 的控制器——那只会发出畸形请求。
      SpbLog.warn('解析当前用户失败，对话页停留在加载态', {'error': e.toString()});
    } finally {
      _resolvingUser = false;
    }
  }

  /// 进入对话时判定「本对话有没有未同步到本地目录的交付物」。
  ///
  /// ## 为什么在这里（而不是 ConversationPage 里）
  ///
  /// 页面（`spb_features`）不掌握「游标 / updated_at / 同步目录」这些概念，
  /// 与它不掌握归约逻辑同一取向。判定与触发都是装配层的事，页面只渲染
  /// 一个纯展示组件 [GroupSyncHint]。
  ///
  /// ## 三重门控（任一不满足就不探测）
  ///
  /// 1. **用户开了这个开关**（`auto.onGroupOpen`，默认关）——不探测即零开销；
  /// 2. **已配置可同步**（有目录、范围非空）——没目录时判定必然 unknown，
  ///    探测只是白跑一次 HTTP；
  /// 3. **冷却期未到**——见 [GroupSyncThrottle]（被过滤掉的文件不抬水位，
  ///    会让判定长期命中）。
  ///
  /// ## 为什么判定与同步分两步
  ///
  /// 判定命中只意味着「有东西没同步」。直接开始拉会让用户在毫无预告的情况下
  /// 看到下载。故先显示提示条，由用户点「立即同步」。
  Future<void> _checkGroupSync(String userId) async {
    if (!mounted || _checkingSync) return;
    _checkingSync = true;
    final groupId = widget.groupId;
    try {
      final settings = await ref.read(loadSyncSettingsProvider)();
      if (!mounted) return;
      if (!settings.auto.onGroupOpen || !settings.canSync) return;

      final throttle = ref.read(groupSyncThrottleProvider);
      if (!throttle.allows(groupId)) {
        SpbLog.debug('进入对话触发同步仍在冷却期，跳过', {'group': groupId});
        return;
      }

      final result = await ref.read(checkGroupSyncNeedProvider)(groupId);
      if (!mounted) return;
      // 判定期间用户可能已切走（异步返回）：只接受仍指向当前对话的结果，
      // 否则会把上一个对话的提示条画在新对话上。
      if (widget.groupId != groupId) return;
      if (!result.isStale) {
        setState(() => _syncCheck = null);
        return;
      }
      // 只在**即将展示**时记冷却：判定为 upToDate 不该消耗掉冷却期，
      // 否则用户下次进来时真的有新文件了却不提示。
      throttle.markTriggered(groupId);
      setState(() => _syncCheck = result);
    } on SpbError catch (e) {
      // 探测失败不影响对话：静默降级（提示条不出现），只记日志。
      // 用户仍可手动同步——那条路径的失败有明确反馈。
      SpbLog.debug('进入对话时探测同步需求失败', {'error': e.toString()});
    } finally {
      _checkingSync = false;
    }
  }

  /// 用户在提示条上点了「立即同步」。
  ///
  /// 只同步**这个 group**（[SyncSingleGroupScope]）：列举前缀收窄到它的子树，
  /// 且**不推进** workspace 共享游标——故不会让其它 group 里未同步的文件
  /// 被 `updated_since` 永久过滤掉（见 `SyncSingleGroupScope` 的文档）。
  Future<void> _syncFromHint() async {
    if (_syncingFromHint) return;
    final groupId = widget.groupId;
    setState(() => _syncingFromHint = true);
    try {
      final report = await ref.read(runGroupSyncActionProvider)(groupId);
      if (!mounted) return;
      setState(() => _syncCheck = null);
      _showSettingsError(
        report.failed.isEmpty
            ? '已同步 ${report.downloaded} 个交付物'
            : '已同步 ${report.downloaded} 个，${report.failed.length} 个失败',
      );
    } on SpbError catch (e) {
      if (!mounted) return;
      _showSettingsError(e.message);
    } finally {
      if (mounted) setState(() => _syncingFromHint = false);
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
    // 同理重置确认卡基线（见该字段文档：null = 从未同步）。
    _seenConfirmationIds = null;
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
    if (_contextUsageSub == null) {
      // 上下文用量走独立流（见 ContextUsage 类文档）。与 activities 同取向：
      // 先订阅再同步一次快照，避免错过订阅前已到达的事件。
      _contextUsageSub = controller.contextUsage.listen(_onContextUsageChanged);
      _onContextUsageChanged(controller.contextUsageSnapshot);
    }
    if (_executionStatusSub == null) {
      // 等待/重试状态走独立流（见 ExecutionStatus 类文档）。
      _executionStatusSub = controller.executionStatus.listen(
        _onExecutionStatusChanged,
      );
      _onExecutionStatusChanged(controller.executionStatusSnapshot);
    }
    if (_ttsStatusSub == null) {
      // 语音播报状态走独立流（见 TtsStatus 类文档）。
      _ttsStatusSub = controller.ttsStatus.listen(_onTtsStatusChanged);
      _onTtsStatusChanged(controller.ttsStatusSnapshot);
      if (_staleTurnIdsSub == null) {
        // 超时兜底集合走独立流（见 ChatStreamController.staleTurnIds）。
        // 与 activities 同取向：先订阅再同步一次快照。
        _staleTurnIdsSub = controller.staleTurnIds.listen(
          _onStaleTurnIdsChanged,
        );
        _onStaleTurnIdsChanged(controller.staleTurnIdsSnapshot);
      }
    }
    // 目标变更通知走独立流（见 GoalUpdate 类文档）。
    //
    // ⚠️ 该事件在服务端漏设 Transient（见 GoalUpdate 的类文档），
    // 控制器已按事件类型把它挡在游标推进之外——此处只消费快照。
    _goalUpdatesSub ??= controller.goalUpdates.listen(_onGoalUpdated);
    // group 变更通知走独立流。本页只处理 metadata 分支（见 _onGroupMetadataChanged）。
    _groupUpdatesSub ??= controller.groupUpdates.listen(
      _onGroupMetadataChanged,
    );
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

  /// AppBar 标题：进入对话后显示**对话名**（[ChatGroup.title]）。
  ///
  /// ## 为什么不是固定的「对话」
  ///
  /// 列表页的 AppBar 已经叫「对话」。若对话页也叫「对话」，用户点进去后
  /// 完全看不出自己是否真的进入了某个对话，也看不出进的是哪一个——尤其
  /// 桌面端从搜索结果 / 待确认列表跳进来时。
  ///
  /// ## 为什么未就绪时退回「对话」而不是空串
  ///
  /// `_group` 由 `GET /chat/groups/:id` 异步拉取。空标题会让 AppBar 只剩
  /// 图标，看起来像渲染坏了；而标题宽度变化会拖动右侧图标（与「停止按钮
  /// 选禁用而非隐藏」同一取舍：AppBar 布局要稳定）。
  String get _appBarTitle {
    final title = _group?.title.trim() ?? '';
    return title.isEmpty ? '对话' : title;
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
      title: _appBarTitle,
      // 侧边栏开关（仅桌面端渲染本页）。
      actions: [
        // Agent 切换：
        //
        // 放在 AppBar 而非侧边栏 tab：它是「这段对话由谁回答」的全局属性，
        // 用户在对话过程中随时可能要换，不该先展开侧边栏再切 tab。
        //
        // `_group` 未就绪时 `currentAgentId` 为 null，入口会显示「未绑定」——
        // 这与真实状态（尚未拉取）不符，但切换本身仍可用（服务端以 agentId
        // 为准），且比隐藏入口让用户以为「本端不支持切 agent」要好。
        AgentSwitcher(
          loadAgents: ref.watch(loadAgentsProvider),
          switchAgent: (agentId, {forceNewSession = false}) =>
              _switchAgent(agentId, forceNewSession: forceNewSession),
          currentAgentId: _group?.activeSession?.agentId,
          busy: _switchingAgent,
        ),
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
      // 返回 FlushResult：服务端在「多条 pending 且未指定策略」时返回
      // **HTTP 200 + confirmation_required**（什么都没提交），组件层据此弹
      // 策略选择（选项来自服务端的 `options`，不硬编码）。
      onFlush: ref.read(flushMessagesProvider(widget.groupId)),
      onFlushWithStrategy: ref.read(flushWithStrategyProvider(widget.groupId)),
      // 执行中活动指示（turn_activity）：长 turn 的静默期给用户可见进展。
      //
      // 传「流 + 首帧快照」两份：快照是同步初值（避免事件在订阅前已到达时
      // 要等下一次心跳才出现），流是后续增量。
      activities: controller.activities,
      activitiesSnapshot: _activities,
      // 上下文用量（context_update）：贴时间线顶部的诊断读数。
      // 与移动端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      contextUsage: controller.contextUsage,
      contextUsageSnapshot: _contextUsage,
      // 等待/重试提示（queue_state / retry_scheduled）：与活动指示共用槽位。
      // 与移动端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      executionStatus: controller.executionStatus,
      executionStatusSnapshot: _executionStatus,
      // 语音播报状态（tts_*）：只做状态展示，不引入播放（AGENTS.md §11）。
      // 与移动端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      ttsStatus: controller.ttsStatus,
      ttsStatusSnapshot: _ttsStatus,
      // 超时兜底（长时间无进展）：停掉流式光标 + 提示条，但**不禁用**取消。
      // 与移动端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      staleTurnIds: controller.staleTurnIds,
      staleTurnIdsSnapshot: _staleTurnIds,
      // 离线写队列（issue #30）：断网时用户发的消息进「待发送」条而不是
      // 时间线——入队时还没有 turnId，而归约器按 turnId 去重，无 turnId 的
      // 本地项会在服务端 `user_message` 到达后渲染成两个气泡。
      //
      // 队列由 `outboxQueueProvider`（**非** autoDispose）持有：重试计时器
      // 必须活得比本页久，否则「断网发一条 → 退出对话 → 网络恢复」后消息
      // 永远不会被重试。
      outboxEntries: ref.watch(outboxQueueProvider).entries,
      outboxSnapshot: ref.watch(outboxQueueProvider).snapshot,
      onCancelOutbox: (id) => ref.read(outboxQueueProvider).cancel(id),
      onRetryOutbox: (id) => ref.read(outboxQueueProvider).retryNow(id),
      onRemoveOutbox: (id) => ref.read(outboxQueueProvider).remove(id),
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
      // 图片类交付物在时间线内联显示缩略图。走 `UfsApi.thumbnail`（默认 256，
      // 服务端合法档位之一）。未注入时卡片退化为图标——见
      // `ConversationPage.onLoadThumbnailAgentFile`。
      //
      // 失败/501 由 `UfsApi.thumbnail` 归一为 null，卡片侧再退化为图标；
      // 这里不再包一层 try/catch（抛出的都是真异常，卡片自己会接住并记日志）。
      onLoadThumbnailAgentFile: (file) => _loadAgentFileThumbnail(file),
      // 打开 / 定位**本地副本**。桌面端注入真实平台能力（`xdg-open` / `open`
      // / `explorer`，见 `bootstrap.dart` 的 `PlatformDesktopCapabilities`）。
      //
      // ⚠️ 移动端**有意不装配**这两个回调：它注入的是
      // `NoopDesktopCapabilities`，`openFile` / `revealPath` 恒 false，接上只会
      // 让用户点「打开」得到「无法打开文件」。回调为 null 时卡片不渲染菜单项
      // ——这正是 issue #6 要求的「菜单不出现，而不是出现后失败」。
      onOpenAgentFile: (file) => _openAgentFile(file),
      onRevealAgentFile: (file) => _revealAgentFile(file),
      // 文件预览（text / image / external 三类）。取数与「打开本地副本」
      // 走**不同**的链路：
      // - `loadBytes` 取**原始字节**（text 解码 / image 渲染），复用
      //   `UfsApi.download`，**不落盘**（预览是看内容，不是拿文件）；
      // - `openExternal` 拼 UFS 预览页 URL 并交给系统浏览器。
      //
      // 两者都不复用 `_ensureAgentFileLocal`：那条链路会写盘（为了给
      // `xdg-open` 一个真实路径），而预览不应该在用户只是「看一眼」时
      // 往磁盘上留副本。
      onPreviewAgentFile: AgentFilePreviewCallbacks(
        loadBytes: _loadAgentFileBytes,
        openExternal: _openAgentFileExternal,
        // map spec 的地点行：跳高德（`uri.amap.com`，第三方链接）。
        // 与 `openExternal` 分开：后者拼的是**本服务**的 UFS 预览页，
        // 前者是外部地图服务（见 `OpenMapMarker` 的文档）。
        openMapMarker: _openMapMarker,
      ),
      // 打开 Markdown 回复里的链接。
      //
      // 走与 OIDC 登录同一个入口（`openInBrowser`，三平台分派在
      // `spb_platform` 的 `spawnSystemOpen`），不另引 `url_launcher`
      // ——理由见 `auth_browser.dart` 的注释。
      // 失败只记日志：链接点不开不该弹错误打断阅读。
      onOpenLink: (url, _) => unawaited(
        openInBrowser(url)
            .catchError((Object e) => SpbLog.warn('打开链接失败', {'error': '$e'})),
      ),
      onResolveConfirmation: _resolveConfirmation,
      onResolveFeedback: _resolveFeedback,
      onAcceptHabit: _acceptHabit,
      onEditAndAcceptHabit: _editAndAcceptHabit,
      onDismissHabit: _dismissHabit,
      onSnoozeHabit: _snoozeHabit,
      // 建议卡选中的 agent 随消息透传；未选中时为 null（与默认路径等价）。
      // 之所以自建 onSend 而非用默认 controller.send：默认路径没有地方带 agentId。
      onSend: (text) => ref
          .read(chatStreamControllerProvider(userId))
          .send(input: text, agentId: _selectedAgentId),
      // 失败 turn 的重发：锁定**原 group + 原 agent**，`routingMode: manual`
      // 避免再次触发归属歧义确认。
      //
      // ## 为什么换一个新的 `request_id`
      //
      // `send` 不传 `requestId` 时服务端每次新建 turn。若沿用失败那轮的 id，
      // 服务端按 `(user_id, request_id)` 幂等命中会直接返回**那个已失败的
      // turn**，等于什么都没做（webapp `ChatMessageList.tsx:313` 的注释专门
      // 记了这一点）。故这里不传 requestId，由服务端生成。
      onRetryTurn: (text, agentId) => ref
          .read(chatStreamControllerProvider(userId))
          .send(
            input: text,
            groupId: widget.groupId,
            agentId: agentId ?? _selectedAgentId,
            routingMode: 'manual',
          )
          .then((_) => null),
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
      // 对话内搜索（搜的是**已加载的时间线**，含 agent 回复）。
      //
      // ## 为什么显式打开
      //
      // `ConversationPage.enableSearch` 默认 `false`：移动端 AppBar 在窄屏
      // 没有余量（issue #31），故不能默认开。桌面端有宽屏余量，显式打开。
      //
      // 忘了这一行**不会让任何页面测试失败**（页面测试自己传参），只会让
      // 用户界面上入口静默消失——`apps/spb_desktop/test/widget_test.dart`
      // 有一条从 router 层断言的用例专门钉住它。
      enableSearch: true,
    );

    // 「本对话有交付物未同步」提示条。
    //
    // ## 为什么包在对话页**外面**而不是塞进 ConversationPage
    //
    // 1. 语义上它属于**装配层**：判定要读同步游标与用户配置，而页面不掌握
    //    这些概念（见 `_checkGroupSync`）。
    // 2. 实际好处：`ConversationPage` 已有 46 个构造参数，且两端接线由
    //    `tools/check_wiring_parity.sh` 逐参数比对。加一个「只有桌面端会传」
    //    的参数就得再往守卫的豁免清单里加一条，而豁免清单每多一条，守卫能
    //    发现真实差异的能力就少一分。
    //
    // 位置选在 Scaffold **之上**（整页顶部）：它是关于「这个对话的产出」
    // 的整页级提示，不是某一轮 turn 的状态——故与 `ConversationPage` 内部
    // 那些状态条（活动 / 等待 / 离线）不在同一层级。
    final check = _syncCheck;
    Widget withHint(Widget child) {
      if (check == null) return child;
      return Column(
        children: [
          Material(
            // 提示条自带背景色，但外层 Material 提供 Scaffold 之上的
            // elevation/裁剪上下文（否则 Material 3 的 tint 会叠到页面底色上）。
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: SafeArea(
              bottom: false,
              child: GroupSyncHint(
                pendingCount: check.pendingCount,
                syncing: _syncingFromHint,
                onSync: _syncingFromHint ? null : () => _syncFromHint(),
                onDismiss: _syncingFromHint
                    ? null
                    : () => setState(() => _syncCheck = null),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      );
    }

    if (!_showSidebar) return withHint(conversation);

    // 待办面板按 turn 聚合待确认卡。groupItemsByTurn 是纯函数（领域层），
    // 分组逻辑与侧边栏渲染解耦。
    final turns = groupItemsByTurn(_items);

    return withHint(
      Row(
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
                    onReveal: (path) =>
                        ref.read(revealDeliverableProvider)(path),
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
                  label: '设置',
                  icon: Icons.tune,
                  content: _group == null
                      // 权威状态未就绪：不能渲染面板——面板的每个控件都要读
                      // metadata（键缺失会被当成「全部关闭」），先渲染会显示一个
                      // 假的「全关」状态，用户可能在加载完成前就去点它。
                      ? GroupSettingsLoading(
                          error: _groupError,
                          onRetry: _loadGroup,
                        )
                      : GroupSettingsPanel(
                          group: _group!,
                          busy: _settingsBusy,
                          // tab 标签已命名「设置」，不重复面板标题。
                          showHeader: false,
                          // 每个回调都只带**变化的那一个键**，由
                          // GroupSettingsUseCase 补一次 getGroup 拿权威状态
                          // （写端点只回布尔）。
                          onSaveGoal: (text) => _runSetting(
                            () => ref
                                .read(groupSettingsUseCaseProvider)
                                .saveGoal(widget.groupId, text),
                          ),
                          onToggleGoalGate: (enabled) => _runSetting(
                            () => ref
                                .read(groupSettingsUseCaseProvider)
                                .toggleGoalGate(widget.groupId, enabled),
                          ),
                          onSaveMaxAutoTurns: (turns) => _runSetting(
                            () => ref
                                .read(groupSettingsUseCaseProvider)
                                .saveMaxAutoTurns(widget.groupId, turns),
                          ),
                          onToggleFollowUpSuggest: (enabled) => _runSetting(
                            () => ref
                                .read(groupSettingsUseCaseProvider)
                                .toggleFollowUpSuggest(widget.groupId, enabled),
                          ),
                          onToggleHabitSuggest: (enabled) => _runSetting(
                            () => ref
                                .read(groupSettingsUseCaseProvider)
                                .toggleHabitSuggest(widget.groupId, enabled),
                          ),
                          onSaveTts:
                              ({
                                enabled,
                                narrateThinking,
                                narrationMode,
                                fileSummary,
                              }) => _runSetting(
                                () => ref
                                    .read(groupSettingsUseCaseProvider)
                                    .saveTts(
                                      widget.groupId,
                                      enabled: enabled,
                                      narrateThinking: narrateThinking,
                                      narrationMode: narrationMode,
                                      fileSummary: fileSummary,
                                    ),
                              ),
                        ),
                ),
                ChatSidebarTab(
                  label: '目标',
                  icon: Icons.history,
                  content: GoalHistoryPanel(
                    // 历史列表是**独立端点**（`GET /chat/groups/:id/goals`），
                    // 与 `_group.currentGoal` 快照不同源。故不用 `_group`，
                    // 由面板自己拉；写完后它也会自己回读（见面板的 `_run`）。
                    load: () =>
                        ref.read(goalApiProvider).listGoals(widget.groupId),
                    currentGoalId: _goalId.isEmpty ? null : _goalId,
                    busy: _settingsBusy,
                    // tab 标签已命名「目标」，不重复面板标题。
                    showHeader: false,
                    // 切对话时重拉（Flutter 会复用面板 State）。
                    reloadToken: widget.groupId,
                    onSwitch: (goalId) => _runGoalWrite(
                      // 切回必须允许「当前无目标」——那正是它存在的场景。
                      () => ref
                          .read(goalApiProvider)
                          .switchGoal(widget.groupId, goalId),
                      requireGoal: false,
                    ),
                    onSetStatus: (goalId, status) => _runGoalWrite(
                      // 同上：给一个无当前目标的对话归档旧目标，是清理历史的
                      // 正常用法。
                      () => ref
                          .read(goalApiProvider)
                          .updateGoalStatus(goalId, status),
                      requireGoal: false,
                    ),
                    // 新建目标（issue #17）。`requireGoal: false`：正是**没有**
                    // 当前目标时才最需要它。
                    //
                    // `tasksSource: manual` 必须显式传：它决定重新展开时能否
                    // 覆盖任务清单，`manual` = 人工创建，LLM 展开不会覆盖。
                    onCreate: (goalText) => _runGoalWrite(
                      () => ref
                          .read(goalApiProvider)
                          .createGoal(
                            widget.groupId,
                            goalText: goalText,
                            tasksSource: GoalTasksSource.manual,
                          ),
                      requireGoal: false,
                    ),
                  ),
                ),
                ChatSidebarTab(
                  label: '任务',
                  icon: Icons.flag_outlined,
                  // 徽标 = 未完成任务数（用户一眼看出还剩几件事）。
                  badge: _unfinishedTaskCount,
                  content: GoalTasksPanel(
                    // 快照来自 `_group.currentGoal`，而它由 `goal_updated` SSE
                    // 事件实时刷新（见 `_onGoalUpdated`）——本面板不自己轮询。
                    snapshot: _goalSnapshot,
                    decisions: _gateDecisions,
                    busy: _settingsBusy,
                    // tab 标签已命名「任务」，不重复面板标题。
                    showHeader: false,
                    // 切对话时清掉新增框里的半截草稿。
                    reloadToken: widget.groupId,
                    onReload: _reloadGoalTasks,
                    onSetStatus: (taskId, status) => _runGoalWrite(
                      () => ref
                          .read(goalApiProvider)
                          .setTaskStatus(_goalId, taskId, status),
                    ),
                    onCreate: ({required title, description}) => _runGoalWrite(
                      () => ref
                          .read(goalApiProvider)
                          .createTask(
                            _goalId,
                            title: title,
                            description: description,
                            // ⚠️ 必须显式传 manual：服务端只在 origin != 'llm' 时
                            // 把 tasks_source 置为 manual，否则人工新增的任务会在
                            // 下次 LLM 展开时被当作可覆盖项删掉。
                            origin: GoalTaskOrigin.manual,
                          ),
                    ),
                    // 编辑任务标题/描述。
                    //
                    // ⚠️ 服务端语义：`''` = 清除、`null` = 不改。面板已把
                    // 输入框的当前值（含空串）显式传下来，故这里**不能**再用
                    // `?? ` 或条件判断把它转回 null——那会把「用户清空描述」
                    // 变成「不修改描述」。
                    onUpdateTask: (taskId, {title, description}) =>
                        _runGoalWrite(
                          () => ref
                              .read(goalApiProvider)
                              .updateTask(
                                _goalId,
                                taskId,
                                title: title,
                                description: description,
                              ),
                        ),
                    onDelete: (taskId) => _runGoalWrite(
                      () =>
                          ref.read(goalApiProvider).deleteTask(_goalId, taskId),
                    ),
                    onReorder: (taskIds) => _runGoalWrite(
                      () => ref
                          .read(goalApiProvider)
                          .reorderTasks(_goalId, taskIds),
                    ),
                    onResetForExpand: () => _runGoalWrite(
                      () => ref.read(goalApiProvider).resetForExpand(_goalId),
                    ),
                  ),
                ),
                // 续跑 tab：查看 / 停用 Goal Gate 自动续跑排程。
                //
                // ## 为什么与「任务」分开而不是并入
                //
                // 「任务」是当前目标的任务清单（`chat_goal_tasks`），本 tab 是
                // **到点自动接着跑**的排程（`chat_turn_schedules`）。前者回答
                // 「还剩什么事」，后者回答「它接下来还要自己跑几次、怎么叫停」
                // ——不同实体、不同端点、不同时间方向（将来时 vs 现在时）。
                ChatSidebarTab(
                  label: '续跑',
                  icon: Icons.schedule_outlined,
                  content: AutoSchedulesPanel(
                    // 列表是独立端点（`GET /api/chat/groups/:id/auto-schedules`），
                    // 与 `_group` 快照不同源。用例内部会先取 `_group` 的
                    // activeSession.agentId，再本地按 group 过滤（见其类文档）。
                    load: () => ref
                        .read(autoSchedulesUseCaseProvider)
                        .load(widget.groupId),
                    onStopAll: () async =>
                        (await ref
                                .read(autoSchedulesUseCaseProvider)
                                .stopAll(widget.groupId))
                            .items,
                    // tab 标签已命名「续跑」，不重复面板标题。
                    showHeader: false,
                    // 切对话时重拉（Flutter 会复用面板 State）。
                    reloadToken: widget.groupId,
                  ),
                ),
                // 诊断 tab：仅在非发布构建展示。
                //
                // 面板内容含工具调用入参与 gate 决策明细，是开发/排查用的内部
                // 视图，不应随发布包分发。门控走 provider 而非直接判
                // `SpbEnv.isRelease`：后者是编译期常量，测试无法切换，也就无法
                // 验证「发布包里它真的消失了」。
                //
                // ## 删掉这个 tab 不会让侧边栏默认落到别的 tab
                //
                // `ChatSidebar` 用 `initialIndex`（默认 0，即「交付物」）初始化
                // `_index`，不依赖 tab 数量；且 `didUpdateWidget` 只在
                // `_index` 越界时才夹取。少一个尾部 tab 不影响任何既有索引。
                if (ref.watch(showDebugPanelProvider))
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
      ),
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
  /// ## 为什么这里**不**吞异常（与 [_resolveConfirmation] 不同）
  ///
  /// 确认卡失败后服务端会在同一个 turn 内回 `confirmation_resolved`/
  /// `confirmation_expired` 重新收敛，UI 不会卡在中间态。归属反馈没有这条
  /// 回路：回执是一次性 CAS，失败就是失败，必须把错误交给页面去提示。
  ///
  /// 此前这里 `.catchError(debugPrint)`，加上请求体键名错误，就变成了用户
  /// 报障的「点了没反应」（见 `ChatApi.resolveFeedback` 的说明）。
  ///
  /// busy 集合按 token 去重——页面内 busy 已有一层，这里是第二层（
  /// 与 [_resolvingConfirmations] 同样防止「两处可点」时的重复提交）。
  Future<void> _resolveFeedback(String token, bool correct) async {
    if (_resolvingFeedback.contains(token)) return;
    setState(() => _resolvingFeedback.add(token));
    try {
      await ref.read(chatApiProvider).resolveFeedback(token, correct: correct);
    } finally {
      if (mounted) setState(() => _resolvingFeedback.remove(token));
    }
  }

  /// 接受习惯建议。
  ///
  /// ## 为什么用 `HabitApi` 而不是 `ChatStreamController`
  ///
  /// 建议卡虽在对话里，但它的端点是 `/api/chat/habit-suggestions/:id/resolve`
  /// （属习惯域，不是发消息）。走发消息通道会把「接受建议」变成一条普通用户
  /// 消息——服务端不认这种回执，且会在时间线里多出一条毫无意义的用户气泡。
  ///
  /// 成功/失败都只记日志：**结果的权威呈现是 `habit_suggestion_resolved`
  /// 事件**（服务端 resolve 后会广播，归约器把卡片换成结果行）。在这里乐观
  /// 更新本地状态反而会与事件打架（重放/延迟到达时出现双重状态）。
  void _acceptHabit(HabitSuggestionItem s) {
    unawaited(
      ref
          .read(habitApiProvider)
          .resolveSuggestion(
            s.suggestionId,
            action: HabitSuggestionAction.accept,
          )
          .catchError((Object e) {
            debugPrint('接受习惯建议失败: $e');
            _showHabitError('接受失败，请重试');
            return const HabitSuggestionResolveResult(resolved: false);
          }),
    );
  }

  /// 就地编辑后接受（`action=edit_and_accept` + `pattern_patch`）。
  ///
  /// ## 为什么不做乐观更新
  ///
  /// 与 [_acceptHabit] 同约定：结果的权威来源是服务端随后推送的
  /// `habit_suggestion_resolved` 事件（归约器会原地更新卡片）。乐观更新会让
  /// 「patch 被服务端静默忽略」（如格式不对——`applyPatternPatch` 不报错）
  /// 的情况显示成「已按你的修改生效」。
  ///
  /// 失败只记日志 + 弹提示：事件不会到来，卡片会继续停在未处理态，用户可重试。
  void _editAndAcceptHabit(HabitSuggestionItem s, Map<String, dynamic> patch) {
    unawaited(
      ref
          .read(habitApiProvider)
          .resolveSuggestion(
            s.suggestionId,
            action: HabitSuggestionAction.editAndAccept,
            patternPatch: patch,
          )
          .catchError((Object e) {
            debugPrint('编辑并接受习惯建议失败: $e');
            _showHabitError('保存失败，请重试');
            return const HabitSuggestionResolveResult(resolved: false);
          }),
    );
  }

  /// 忽略习惯建议（服务端写 24h 冷却窗口）。
  void _dismissHabit(HabitSuggestionItem s) {
    unawaited(
      ref
          .read(habitApiProvider)
          .resolveSuggestion(
            s.suggestionId,
            action: HabitSuggestionAction.dismiss,
          )
          .catchError((Object e) {
            debugPrint('忽略习惯建议失败: $e');
            _showHabitError('操作失败，请重试');
            return const HabitSuggestionResolveResult(resolved: false);
          }),
    );
  }

  /// 稍后提醒。
  ///
  /// `snooze_until` 由 [HabitSnoozeOption.until] 算（UTC）——**不在本处手写
  /// 时间计算**：服务端解析失败会静默回退冷却时长（不报错），格式错了用户会
  /// 发现「明明选了 1 小时后，却要等一天」。
  void _snoozeHabit(HabitSuggestionItem s, HabitSnoozeOption option) {
    unawaited(
      ref
          .read(habitApiProvider)
          .resolveSuggestion(
            s.suggestionId,
            action: HabitSuggestionAction.snooze,
            snoozeUntil: option.until(DateTime.now()),
          )
          .catchError((Object e) {
            debugPrint('延后习惯建议失败: $e');
            _showHabitError('操作失败，请重试');
            return const HabitSuggestionResolveResult(resolved: false);
          }),
    );
  }

  void _showHabitError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 监听 controller.gateDecisions：更新诊断面板数据。
  void _onGateDecisionsChanged(List<GateDecision> decisions) {
    if (!mounted) return;
    setState(() => _gateDecisions = decisions);
  }

  /// 监听 controller.staleTurnIds：驱动对话页的超时兜底提示。
  ///
  /// 集合通常只有 0 或 1 个元素（同一 group 的 turn 串行执行）。
  void _onStaleTurnIdsChanged(Set<String> ids) {
    if (!mounted) return;
    setState(() => _staleTurnIds = ids);
  }

  /// 监听 controller.activities：驱动对话页的空窗期进度指示。
  void _onActivitiesChanged(Map<String, TurnActivitySnapshot> activities) {
    if (!mounted) return;
    setState(() => _activities = activities);
  }

  /// 监听 controller.contextUsage：驱动对话页顶部的用量读数。
  ///
  /// 快照可为 null（尚无数据），直接存下即可——页面按 `hasData` 决定是否渲染。
  void _onContextUsageChanged(ContextUsage? usage) {
    if (!mounted) return;
    setState(() => _contextUsage = usage);
  }

  /// 监听 controller.executionStatus：驱动对话页的等待/重试提示。
  void _onExecutionStatusChanged(ExecutionStatus? status) {
    if (!mounted) return;
    setState(() => _executionStatus = status);
  }

  /// 监听 controller.ttsStatus：驱动对话页的播报状态条。
  void _onTtsStatusChanged(TtsStatus? status) {
    if (!mounted) return;
    setState(() => _ttsStatus = status);
  }

  /// 监听 controller.goalUpdates：实时刷新本对话的目标快照。
  ///
  /// ## 为什么直接套快照而不重新拉 group
  ///
  /// 事件 payload 的 goal/tasks/progress 由与 `GET /goals/current` 完全
  /// 相同的 DTO 函数生成（Go `goalToDTO`/`taskToDTO`/`progressFromTasks`），
  /// 是服务端刻意的防漂移设计。重发 HTTP 只为拿已在手里的数据是白费一次
  /// 往返，且会打断设置面板里的草稿编辑。
  ///
  /// ## 三条守卫
  ///
  /// 1. **只处理本对话的变更**：SSE 是 user 级订阅，会收到别的 group 的
  ///    goal 变更（agent 可能在别处改任务）；套错会把本页目标改掉。
  /// 2. **_group 未就绪时忽略**：初始 `_loadGroup` 会拿到最新状态，此处
  ///    无事可做（也不能拿 null 去拼快照）。
  /// 3. **快照为 null 时忽略**：goal 字段缺失的异常载荷不得清空现有目标
  ///    （否则面板上的目标会凭空消失）。
  /// 监听 controller.groupUpdates：把 Goal Gate 自动停用的 metadata 套进 _group。
  ///
  /// ## 只处理 metadata 分支
  ///
  /// 本页不渲染 group 的标题/状态（那是列表页的事），`created`/`deleted`/
  /// `title` 等 op 对设置面板无影响，处理它们只会白费一次 setState。
  ///
  /// ## 三条守卫
  ///
  /// 1. **只处理本对话**：SSE 是 user 级订阅，会收到别的 group 的变更
  ///    （`groupUpdates` 刻意不过滤 group）。套错会把本页开关改掉。
  /// 2. **_group 未就绪时忽略**：初始 `_loadGroup` 会拿到最新 metadata。
  /// 3. **metadata 为 null 时忽略**：不得用空 map 覆盖现有值
  ///    （否则面板会显示假的「全部关闭」）。
  ///
  /// ## 为什么整体替换而不深合并
  ///
  /// payload 的 metadata 是**完整**的 `chat_groups.metadata`（Go
  /// `updateGroupMetadata` 返回整个 map）。服务端的删除语义是「把键移除」
  /// （关闭 tts 时整块删 `metadata.tts`），深合并会让「已关」的开关
  /// 继续显示为开。
  void _onGroupMetadataChanged(GroupUpdate update) {
    if (!mounted) return;
    final group = _group;
    if (group == null) return;
    // 判定逻辑在 GroupUpdate.applyTo（两端共用，见其文档）：
    // op 非 metadata / groupId 不匹配 / metadata 缺失时返回**原对象**，
    // 据此跳过无意义的 setState。
    final next = update.applyTo(group);
    if (identical(next, group)) return;
    setState(() => _group = next);
  }

  void _onGoalUpdated(GoalUpdate update) {
    if (!mounted) return;
    if (update.groupId != widget.groupId) return;
    final group = _group;
    if (group == null) return;
    final snapshot = update.snapshot;
    if (snapshot == null) return;
    setState(() => _group = group.withCurrentGoal(snapshot));
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

    // 待确认集合的身份（见 `_seenConfirmationIds` 的文档）。
    final confIds = <String>{
      for (final item in items)
        if (item is ConfirmationItem) '${item.confirmationId}:${item.resolved}',
    };
    final baseline = _seenConfirmationIds;
    _seenConfirmationIds = confIds;
    // 首次建基线不刷新（对话列表页本就在拉，再刷一次是重复请求）；
    // 之后只要集合有增/减/状态变化就刷新角标。
    final confirmationsChanged =
        baseline != null && !_setEquals(baseline, confIds);

    // 新确认卡到达时发 OS 通知（issue #21）。
    //
    // ## 为什么放在 `mounted` 检查之前、且不 await
    //
    // 通知是**副作用**，与本次 setState 无关：用户可能在页面已卸载（切走）
    // 时仍需收到通知——那正是通知存在的意义。await 会把它排进本帧之后，
    // 但判定本身是同步的（只有真正的 show 是异步），故不 await 即可。
    unawaited(ref.read(confirmationNotifierProvider).handleItems(items));

    if (!mounted) return;
    // 同一次 setState 里同时更新待办面板的数据与交付物刷新令牌：
    // items 流推送时两者都要变，分开 setState 会多一次重建。
    setState(() {
      _items = items;
      _toolCalls = items.whereType<ToolCallItem>().toList(growable: false);
      if (!isFirstSync && hasNew) _deliverablesReloadToken++;
    });

    // ## 为什么 invalidate 的是 `pendingConfirmationsProvider` 而不是 count
    //
    // count provider 的实现是 `await ref.watch(pendingConfirmationsProvider
    // .future)`——它的值**派生**自被依赖者。只 invalidate count 时，它重建
    // 后读到的仍是被缓存的 `pendingConfirmationsProvider` 结果，角标纹丝不动
    // （这正是本文件 :421 处那个失效调用的根因）。
    //
    // 刷新被依赖者则两条都生效：`pendingConfirmationsProvider` 重拉，count
    // 因 watch 依赖被自动重算。
    if (confirmationsChanged) {
      ref.invalidate(pendingConfirmationsProvider);
    }
  }

  /// 集合内容相等（`Set` 的 `==` 是**引用**相等，不能用）。
  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// 下载 agent 文件产物到本地（时间线卡片的「下载」按钮）。
  //
  // 落地路径由 [_ensureAgentFileLocal] 决定；本方法只丢掉路径（用户点「下载」
  // 后自己去找文件，与打开/定位不同）。
  Future<void> _downloadAgentFile(AgentFileItem file, String userId) async {
    await _ensureAgentFileLocal(file);
  }

  /// 用默认程序打开 agent 文件；本地没有则先下载再打开。
  //
  // ## 为什么是「先下载再打开」而不是「未下载就报错」
  //
  // 交付物面板靠**同步目录索引**判断可打开性（`resolveLocalPath`），而时间线
  // 卡不掌握那个索引（见 `AgentFileCard` 的类文档：**有意不接**
  // `resolveLocalPath`）。若因此要求「必须先手动点一次下载」，用户看到的就是
  // 一个永远报「无法打开文件」的菜单项。自动补下载让这个动作真正可用，
  // 且复用同一条下载链路（同一落地目录、同一路径穿越防御）。
  //
  // 返回 false = 未能发起（无 id / 已删除 / 下载不到字节 / 平台不支持），
  // 卡片据此给一句反馈，不静默无响应。
  Future<bool> _openAgentFile(AgentFileItem file) async {
    final path = await _ensureAgentFileLocal(file);
    if (path == null) return false;
    return ref.read(desktopCapabilitiesProvider).openFile(path);
  }

  /// 在文件管理器中定位 agent 文件（同样本地没有则先下载）。
  Future<bool> _revealAgentFile(AgentFileItem file) async {
    final path = await _ensureAgentFileLocal(file);
    if (path == null) return false;
    return ref.read(desktopCapabilitiesProvider).revealPath(path);
  }

  /// 确保文件已在本地，返回其绝对路径；不可用（无 id / 已删除 / 无字节）返回 null。
  ///
  /// ## 为什么每次都重新下载而不缓存路径
  ///
  /// 卡片是**无状态透传**的（不持有本地路径），且落地目录可能被清理计划动。
  /// 每次重拉由服务端 etag/304 与本地小文件写盘兑底，换来的是「不缓存就不会
  /// 指向一个已被删掉的位置」（与 `resolveLocalDeliverableProvider` 校验
  /// `existsSync` 同一理由）。
  ///
  /// ## 落地布局：`downloads/agent/{groupId}/<group 内相对路径>`
  ///
  /// ⚠️ **不是平铺**。修复前所有文件都写到 `downloads/agent/<文件名>`，于是
  /// 不同对话的同名交付物（每个对话都有 `QWEN.md` / `README.md`）**互相
  /// 覆盖**，而且文件与对话的对应关系在磁盘上完全消失——用户点「定位」
  /// 后看到的是一个分不清属于哪个对话的文件。
  ///
  /// 用 [AgentFileItem.relativePath]（已归一化、已剥掉 workspace 前缀）作
  /// 子路径，保留目录结构；与同步链路 / 交付物面板下载**同一个形状**
  /// （`{gid}/reports/a.md`），用户只需记一种布局。
  ///
  /// 具体口径在领域层（`agentFileDownloadRelPath`，纯函数、可无头单测）——
  /// 与移动端共用同一份，避免「桌面端改了移动端没改」。段级校验（穿越防御）
  /// 与退化规则见该函数的文档。
  Future<String?> _ensureAgentFileLocal(AgentFileItem file) async {
    final fileId = file.ufsFileId;
    if (fileId == null || fileId.isEmpty || file.isDeleted) return null;
    final ufs = ref.read(ufsApiProvider);
    final res = await ufs.download(fileId);
    if (res.notModified || res.bytes == null || res.bytes!.isEmpty) return null;
    final dir = await getApplicationSupportDirectory();
    final root = Directory(p.join(dir.path, 'downloads', 'agent'));

    final rel = _agentFileRelPath(file);
    final target = Directory(p.join(root.path, p.dirname(rel)));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    final out = p.join(root.path, rel);
    await File(out).writeAsBytes(res.bytes!, flush: true);
    return out;
  }

  /// 时间线交付物在下载目录内的相对路径：`{groupId}/<relativePath>`。
  ///
  /// 口径在领域层（`agentFileDownloadRelPath`，纯函数、可无头单测）——
  /// 两端的下载链路共用同一份，避免「桌面端改了移动端没改」的漂移。
  /// 段级校验（穿越防御）与退化规则见该函数的文档。
  String _agentFileRelPath(AgentFileItem file) =>
      agentFileDownloadRelPath(file, widget.groupId);

  /// 拉取 agent 文件缩略图（仅图片类）。
  //
  // 返回 null 表示「无缩略图可渲染」，卡片退化为图标。两种来源：
  // - 文件不可用（无 id / 已删除）—— 与 `_downloadAgentFile` 同一套前置判据；
  // - 服务端未启用缩略图能力（501）或返回 304 —— 由 `UfsApi.thumbnail` 归一。
  Future<List<int>?> _loadAgentFileThumbnail(AgentFileItem file) async {
    final fileId = file.ufsFileId;
    if (fileId == null || fileId.isEmpty || file.isDeleted) return null;
    return ref.read(ufsApiProvider).thumbnail(fileId);
  }

  /// 取文件**原始字节**供预览（text 解码 / image 渲染）。
  //
  // ## 为什么不复用 `_loadAgentFileThumbnail`
  //
  // 缩略图是 256px 的小图，是给**列表内联**用的；把它放大到全屏对话框会糊。
  // 预览是用户主动点开的单文件，要用原图。
  //
  // ## 为什么走 `download` 而 `_ensureAgentFileLocal`
  //
  // 后者会写盘（为了给系统「打开」一个真实路径）。预览只是看一眼，不应该
  // 在用户没要求时往磁盘留副本。`download` 直接返回内存字节。
  //
  // 返回 null = 取不到（无 id / 已删除 / 304 / 空字节），由对话框退化为
  // 「未能取到文件内容」提示。
  Future<List<int>?> _loadAgentFileBytes(AgentFileItem file) async {
    final fileId = file.ufsFileId;
    if (fileId == null || fileId.isEmpty || file.isDeleted) return null;
    final res = await ref.read(ufsApiProvider).download(fileId);
    if (res.notModified || res.bytes == null || res.bytes!.isEmpty) return null;
    return res.bytes;
  }

  /// 在系统浏览器中打开该文件的 UFS 预览页（external 类的唯一出路）。
  //
  // ## URL 拼接为什么在这里而不在页面
  //
  // 页面只收集意图（「预览这个文件」），它不掌握 UFS 基地址，也不该知道
  // 预览页的路由形状（`/preview.html?file_id=…`）。把拼接留在装配层，
  // 将来换部署/换路由只改这一处。
  //
  // ## 为什么用 `SpbEndpoints.current.ufsBaseUrl` 而不是某个 provider
  //
  // 基地址由启动探测决定（`--dart-define=SPB_UFS_BASE_URL` 是编译期默认值，
  // 探测可达时会被升级到 IPv6 源站域名，见 `spb_core` 的 `endpoints.dart`），
  // 但它在整个会话内**不变**，故直接读静态持有者即可，不必为它建一个 provider。
  Future<bool> _openAgentFileExternal(AgentFileItem file) async {
    final fileId = file.ufsFileId;
    if (fileId == null || fileId.isEmpty || file.isDeleted) return false;
    final url =
        '${SpbEndpoints.current.ufsBaseUrl}/preview.html'
        '?file_id=${Uri.encodeQueryComponent(fileId)}';
    try {
      await openInBrowser(url);
      return true;
    } on Object catch (e) {
      SpbLog.warn('打开 UFS 预览页失败', {'error': '$e'});
      return false;
    }
  }

  /// 在系统浏览器中打开高德地图的 marker 链接（map spec 地点行）。
  ///
  /// ## 为什么走 `openInBrowser` 而不引入 `url_launcher`
  ///
  /// 桌面端的 `openInBrowser` 已经三平台分派（`spb_platform` 的
  /// `spawnSystemOpen`），与 OIDC 登录、Markdown 链接、UFS 预览页共用同一条
  /// 路径。为这一个场景再引一个插件会多一份平台实现与一份依赖。
  ///
  /// ## URL 拼接为什么在这里
  ///
  /// 同 `_openAgentFileExternal`：页面只收集「用户点了这个地点」这个意图，
  /// 它不该知道高德的 URI 形状（`uri.amap.com/marker?position=…`）。
  Future<bool> _openMapMarker(MapMarker marker) async {
    try {
      await openInBrowser(amapMarkerUrl(marker));
      return true;
    } on Object catch (e) {
      SpbLog.warn('打开高德地图失败', {'error': '$e'});
      return false;
    }
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
      saveSettings: (settings) async {
        await ref.read(saveSyncSettingsProvider)(settings);
        // 新配置立即生效（不必等下次启动）。
        //
        // 失败在 `reconcileAutoSync` 内部降级（读不到偏好就 pause），
        // 故这里不额外 try：保存本身已成功，排程失败不该让用户看到
        // 「保存失败」——那会让他以为设置没落盘。
        await ref.read(reconcileAutoSyncProvider)();
      },
      loadGroups: ref.watch(loadSyncGroupsProvider),
      scanGroups: ref.watch(scanLocalGroupsProvider),
      executePrune: ref.watch(executePruneProvider),
      pickDirectory: () async {
        final caps = ref.read(desktopCapabilitiesProvider);
        return caps.pickDirectory(title: '选择交付物同步目录');
      },
      desktopInfo: DesktopIntegrationInfo(
        visible: ref.watch(desktopCapabilitiesProvider).isSupported,
        hotkeyLabel: HotkeyBinding.quickCapture.label,
      ),
      onOpenDirectory: (path) =>
          ref.read(desktopCapabilitiesProvider).revealPath(path),
      // 外观：选中即保存（不走 draft，见 SaveThemeMode 的说明）。
      loadThemeMode: ref.watch(loadThemeModeProvider),
      saveThemeMode: ref.watch(saveThemeModeProvider),
      // 个人偏好：昵称 / 头像 / 回复语言 / 默认 Agent。
      //
      // 昵称回落值取自 `/api/auth/me` 的 name（服务端已按
      // display_name → users.name → email 解析好），仅作输入框占位提示。
      // 用 `.value` 而非 `watch(future)`：本页是 ConsumerWidget，不该因
      // 「我是谁」重新加载而重建（会丢掉表单草稿）。
      loadPreferences: ref.watch(loadUserPreferencesProvider),
      savePreferences: ref.watch(saveUserPreferencesProvider),
      // 默认 Agent 下拉的候选项。
      //
      // 用 `.value ?? const []` 而非把 `AsyncValue` 喂进页面：本页是
      // ConsumerWidget，agent 列表晚到时只重建一次（下拉多出几项），
      // 而 `UserPreferencesCard` 的 State 一直存活，**用户已填的草稿不丢**。
      // 若在 loading 期间换成转圈占位，State 会被销毁重建，草稿全丢——
      // 与设置页「改动不即时落盘」的约定冲突。理由详见
      // `preferenceAgentOptionsProvider` 的文档。
      preferenceAgentOptions:
          ref.watch(preferenceAgentOptionsProvider).value ?? const [],
      preferenceFallbackDisplayName:
          ref.watch(currentUserProvider).value?.displayNameFallback ?? '',
      onOpenMyTurns: () => context.go(SpbRoutes.myTurns),
      // 诊断报告导出（issue #40）。
      //
      // ## 为什么不经过 provider
      //
      // 与 `pickDirectoryProvider` 不同，本入口不需要被测试 override——
      // 装配函数 `exportDiagnosticsReport` 已经是一行纯函数，而它的依赖
      // （能力实现）正是 `desktopCapabilitiesProvider`，测试直接 override
      // 那个即可，更接近真实接线。
      //
      // ## 移动端有意不接
      //
      // `file_selector` 的 `getSaveLocation` 在 Android/iOS 上**未实现**
      // （基类抛 `UnimplementedError`），接上只会得到「导出失败」。与
      // AGENTS.md §6.10「移动端不接 `onOpen`/`onReveal`」同一取舍：
      // 未注入 → 不展示入口（而非展示一个点了必失败的按钮）。
      onExportDiagnostics: () =>
          exportDiagnosticsReport(ref.read(desktopCapabilitiesProvider)),
      // 自动同步：**仅桌面端**渲染（移动端没有可靠的后台排程，见
      // `SettingsPage.showAutoSync` 的说明）。
      showAutoSync: true,
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
        // `push` 的 Future 在**目标路由 pop 时**才完成，不是导航完成时——
        // 等它会把本回调挂到用户返回为止。故显式 unawaited。
        if (context.mounted) unawaited(context.push(SpbRoutes.work(workId)));
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
